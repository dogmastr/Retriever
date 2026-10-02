--!strict
--[[
	Durable commands: an inbox per record that any server (or an offline tool) appends to without holding the session lock,
	consumed exactly once by the owning session, and an outbox per session for commands that must be sent atomically with the
	sender's own edit.

	Inbox (target side)
	* `store:send(key, kind, payload, { id })` is one UpdateAsync on the target record (`Record.append`): duplicate ids (in the
	  inbox or the idempotency ledger) are reported as `duplicate`, a full inbox as `InboxFull`, a missing record becomes a stub.
	  Retrying a send that may have been applied is safe: the retry finds the id. A live owner is woken (MessagingService, or
	  directly when it lives on this server) so it saves and sees the entry.
	* Consumption is not done inside the UpdateAsync callback (callbacks must be pure and may be replayed). Instead, after a
	  load and after each write, the session runs the handler for every new entry through `profile:apply(entry.id, ...)`: the
	  effect and the ledger id change memory in one synchronous step and the entry is marked consumed. The next write then
	  stores the effect, the ledger id and the inbox removal together (`Record.write` drops consumed entries, idempotently, so
	  callback replay is harmless). A crash before that write loses all three, and the entry is consumed again by the next
	  owner; after it, the ledger and the removal both prevent a second effect.

	Outbox (sender side)
	* `profile:enqueue(...)` (Profile.luau) adds an entry in the same synchronous step as the caller's edit; the write that
	  persists the edit persists the entry. Nothing is delivered before that write is confirmed (`savedSeq` covers the
	  entry), so a sender that crashes never delivers a command whose cause it did not save.
	* A courier thread per session delivers confirmed entries with `Record.append` at background priority, in order per
	  target, and removes an entry from memory only after the target accepted it (appended or duplicate); the next write
	  persists the removal. A crash in between re-delivers, and the target reports `duplicate`.
	* When the session ends cleanly the courier finishes the confirmed entries and removes the delivered ones from the stored
	  outbox with one more write (`Record.ackOutbox`), but only while nobody holds the lock (a new owner delivers itself).
	  During a server shutdown nothing new is delivered: the entries wait in the record for the sender's next session or for
	  `store:deliverOutbox(key)`.

	Exactly-once holds while the target still remembers the id: in its inbox, or in its ledger (`StoreConfig.ledger`, default
	the last 200 ids within 30 days). Command ids and `apply` op ids share the ledger.
]]

local Classify = require(script.Parent.Classify)
local Dispatcher = require(script.Parent.Dispatcher)
local Errors = require(script.Parent.Errors)
local Events = require(script.Parent.Events)
local Handoff = require(script.Parent.Handoff)
local Internal = require(script.Parent.Internal)
local Profile = require(script.Parent.Profile)
local Record = require(script.Parent.Record)
local Scheduler = require(script.Parent.Scheduler)
local Types = require(script.Parent.Types)
local Util = require(script.Parent.Util)
local Validate = require(script.Parent.Validate)

type StoreImpl = Internal.StoreImpl
type ProfileImpl = Internal.ProfileImpl
type Runtime = Internal.Runtime
type RetrieverError = Types.RetrieverError
type InboxEntry = Types.InboxEntry
type OutboxEntry = Types.OutboxEntry
type SendResult = Types.SendResult
type DeliverResult = Types.DeliverResult

local Commands = {}

local MAX_ID = 100 -- ids live in inboxes and ledgers: keep them short
local MAX_KIND = 50
local SEND_TIMEOUT = 30 -- default for store:send
local DELIVERY_TIMEOUT = 30 -- per outbox entry and attempt round
local COURIER_BASE = 5 -- courier backoff after a failed round (seconds), doubling up to the cap
local COURIER_CAP = 300
local PRIO_SEND = 2
local PRIO_DELIVERY = 4

--- Per-session command state (`ext.cmd`).
type CmdState = {
	running: boolean, -- a courier thread exists for this session
	attempt: number, -- consecutive failed delivery rounds
	sleeper: Scheduler.Timer, -- the courier's backoff and retry sleeps (woken when the session ends)
	failed: { [string]: boolean }?, -- inbox ids whose handler threw in this session (retried by the next session)
	--- `savedSeq` of the last confirmed write that stored the data (and so the outbox). A close that releases without the
	--- data (`skipData`) still advances `savedSeq`, but it stored no outbox entry and none of the edits that caused them.
	dataSeq: number,
	--- Outbox ids delivered and removed from memory whose removal no confirmed write has stored yet (id -> `editSeq` at the
	--- removal). Acknowledged against the record after the session ends, so they are not re-delivered forever.
	unacked: { [string]: number }?,
}

------------------------------------------------------------------------------------------------------------------------
-- requests
------------------------------------------------------------------------------------------------------------------------

--- One request through the shared dispatcher (budget, priorities, concurrency caps). The calling thread yields until it ran.
type Attempt = {
	prio: number,
	kind: Types.BudgetKind,
	queued: boolean,
	run: (job: Attempt) -> (),
	call: () -> (any, any),
	env: Types.Env,
	thread: thread,
	parked: boolean,
	done: boolean,
	ok: boolean,
	value: any,
}

local function runAttempt(job: Attempt)
	local ok, value = pcall(job.call)
	job.ok = ok
	job.value = value
	job.done = true
	if job.parked then
		job.parked = false
		job.env.spawn(job.thread)
	end
end

local function attempt(impl: StoreImpl, kind: Types.BudgetKind, prio: number, call: () -> (any, any)): (boolean, any)
	local runtime = impl.runtime
	local counters = impl.counters
	if kind == "get" then
		counters.requestsGet += 1
	elseif kind == "list" then
		counters.requestsList += 1
	elseif kind == "getVersion" then
		counters.requestsGetVersion += 1
	elseif kind == "set" then
		counters.requestsSet += 1
	else
		counters.requestsUpdate += 1
	end
	local job: Attempt = {
		prio = prio,
		kind = kind,
		queued = false,
		run = runAttempt,
		call = call,
		env = runtime.env,
		thread = coroutine.running(),
		parked = false,
		done = false,
		ok = false,
		value = nil,
	}
	Dispatcher.submit(runtime.dispatcher, job :: any)
	if not job.done then
		job.parked = true
		coroutine.yield()
	end
	return job.ok, job.value
end

--- Error classes that will fail the same way on every retry.
local DEFINITIVE: { [string]: Types.ErrorKind } = {
	access = "StudioApiDisabled",
	shutdown = "ShuttingDown",
	tooLarge = "TooLarge",
	invalidData = "InvalidData",
	permanent = "InvalidData",
}

local function backoff(runtime: Runtime, attempts: number): number
	local options = runtime.options
	local delay = math.min(options.backoffCap, options.backoffBase * 2 ^ (attempts - 1))
	return delay * (0.5 + 0.5 * runtime.env.random())
end

--- Runs a request until it completes without an engine error, fails definitively, `abort()` says stop, or `deadline` passes.
--- `produced()` tells whether the callback of the attempt that just raised had produced a value (so the write may have
--- landed). Returns nil on success, else the error; the second value is true when some attempt may have been applied.
local function retrying(
	impl: StoreImpl,
	key: string,
	kind: Types.BudgetKind,
	prio: number,
	call: () -> (any, any),
	produced: () -> boolean,
	deadline: number,
	sleeper: Scheduler.Timer,
	abort: (() -> boolean)?
): (RetrieverError?, boolean, any)
	local runtime = impl.runtime
	local env = runtime.env
	local attempts = 0
	local ambiguous = false
	while true do
		local ok, value = attempt(impl, kind, prio, call)
		if ok then
			return nil, ambiguous, value
		end
		local text = tostring(value)
		impl.counters.failures += 1
		local class = Classify.error(text)
		if class.maybeApplied and produced() then
			ambiguous = true
		end
		local definitive = DEFINITIVE[class.kind]
		if definitive ~= nil then
			if ambiguous then
				return Errors.new("Unknown", impl.name, key, text), true, nil
			end
			return Errors.new(definitive :: Types.ErrorKind, impl.name, key, text), false, nil
		end
		attempts += 1
		impl.counters.retries += 1
		local delay = backoff(runtime, attempts)
		if class.kind == "throttled" then
			Dispatcher.noteThrottle(runtime.dispatcher, kind, class.scope)
			delay = math.max(delay, if class.scope == "experience" then 5 else 2)
		end
		local stop = runtime.destroyed or (abort ~= nil and abort()) or env.clock() + delay >= deadline
		if not stop then
			Scheduler.sleepOn(runtime.scheduler, sleeper, delay)
			stop = runtime.destroyed or (abort ~= nil and abort())
		end
		if stop then
			return Errors.new(if ambiguous then "Unknown" else "Unavailable", impl.name, key, text), ambiguous, nil
		end
	end
end

--- Prompts a live owner to save so it sees a new inbox entry: directly when it is this server, else over MessagingService.
local function wakeOwner(impl: StoreImpl, key: string, ownerJob: string?)
	if ownerJob == nil then
		return
	end
	local runtime = impl.runtime
	if ownerJob == runtime.env.jobId then
		local profile = impl.profiles[key]
		if profile ~= nil and profile.state == "active" then
			Profile.requestSave(profile)
		end
	else
		Handoff.wakeOwner(runtime, ownerJob, impl.name, key)
	end
end

--- Appends `entry` to `key`'s inbox in `impl`, retrying transient failures. Safe to retry: the id makes it idempotent.
local function append(
	impl: StoreImpl,
	key: string,
	entry: InboxEntry,
	create: boolean,
	prio: number,
	deadline: number,
	sleeper: Scheduler.Timer,
	abort: (() -> boolean)?
): SendResult
	local runtime = impl.runtime
	local env = runtime.env
	local ctx = Record.newAppendCtx(entry, impl.config.inboxMax, create, env.time, runtime.options.clockSkew)
	local backend = impl.backend
	local function transform(old: any, info: Types.KeyInfoLike?)
		return Record.append(old, info, ctx)
	end
	local problem, ambiguous = retrying(impl, key, "update", prio, function()
		ctx.runs = 0
		return backend.update(key, transform)
	end, function()
		return ctx.runs > 0 and ctx.outcome == "appended"
	end, deadline, sleeper, abort)
	if problem ~= nil then
		return { ok = false, error = problem }
	end
	local outcome = ctx.outcome
	if outcome == "appended" then
		wakeOwner(impl, key, ctx.ownerJob)
		return { ok = true, id = entry.i, duplicate = false }
	elseif outcome == "duplicate" then
		return { ok = true, id = entry.i, duplicate = true }
	elseif outcome == "full" then
		return {
			ok = false,
			error = Errors.new("InboxFull", impl.name, key, nil, { what = `It holds {impl.config.inboxMax} unconsumed commands.`, max = impl.config.inboxMax }),
		}
	elseif outcome == "missing" then
		return { ok = false, error = Errors.new("NotFound", impl.name, key, nil, { what = "Pass create = true to create a stub that the first load turns into a profile." }) }
	elseif outcome == "corrupt" then
		return { ok = false, error = Errors.new("Corrupt", impl.name, key) }
	elseif outcome == "envelopeTooNew" then
		return { ok = false, error = Errors.new("SchemaTooNew", impl.name, key, "the record uses a newer storage format than this version of Retriever") }
	end
	return { ok = false, error = Errors.new(if ambiguous then "Unknown" else "Unavailable", impl.name, key, "UpdateAsync returned without running the transform callback") }
end

--- Shared with the admin tools: one request through the dispatcher with retries (see `retrying`).
Commands.retrying = retrying
--- Shared with the admin tools: appends an inbox entry (see `append`).
Commands.append = append

------------------------------------------------------------------------------------------------------------------------
-- consuming the inbox
------------------------------------------------------------------------------------------------------------------------

local function stateOf(profile: ProfileImpl): CmdState
	local ext = Profile.ensureExt(profile)
	local existing = ext.cmd
	if existing ~= nil then
		return existing :: CmdState
	end
	local st: CmdState = {
		running = false,
		attempt = 0,
		sleeper = Scheduler.newSleeper(profile.impl.runtime.scheduler),
		failed = nil,
		dataSeq = if profile.skipData then 0 else profile.savedSeq,
		unacked = nil,
	}
	ext.cmd = st
	return st
end

--- Runs the handlers for the entries of `inbox` this session has not consumed yet. Returns true when an entry was consumed
--- (the profile must be saved to persist the effect and the removal).
local function consume(profile: ProfileImpl, inbox: { InboxEntry }?): boolean
	if inbox == nil or #inbox == 0 or profile.state ~= "active" then
		return false
	end
	local impl = profile.impl
	local handlers = impl.commandHandlers
	if handlers == nil then
		return false
	end
	local any = false
	for _, entry in inbox do
		if profile.state ~= "active" then
			break -- a handler closed the profile
		end
		local id = entry.i
		local handler = handlers[entry.k]
		if handler ~= nil and type(id) == "string" then
			local ext = Profile.ensureExt(profile)
			local consumed = ext.consumed
			local cmd = ext.cmd :: CmdState?
			local failed = if cmd ~= nil then cmd.failed else nil
			if (consumed == nil or consumed[id] == nil) and (failed == nil or not failed[id]) then
				local payload = entry.p
				local ok, problem = pcall(Profile.apply, profile, id, function(_data: any)
					handler(profile, payload, id)
				end)
				if ok then
					-- applied now, or already in the ledger (a duplicate that raced the ledger write): either way remove it
					local map: { [string]: number }
					if consumed == nil then
						map = {}
						ext.consumed = map
					else
						map = consumed
					end
					ext.consumedSeq += 1
					map[id] = ext.consumedSeq
					any = true
				else
					local st = stateOf(profile)
					local set = st.failed
					if set == nil then
						set = {}
						st.failed = set
					end
					(set :: { [string]: boolean })[id] = true
					local runtime = impl.runtime
					if runtime.events ~= nil then
						Events.emit(runtime, impl.name, profile.key, "commandFailed", {
							cause = tostring(problem),
							details = { id = id, kind = entry.k },
						})
					end
					runtime.env.log(
						"error",
						`[Retriever] command handler "{entry.k}" failed for command "{id}" (store "{impl.name}", key "{profile.key}"); the command stays in the inbox and is retried by the next session: {tostring(problem)}`
					)
				end
			end
		end
	end
	return any
end

------------------------------------------------------------------------------------------------------------------------
-- delivering the outbox
------------------------------------------------------------------------------------------------------------------------

--- True when a confirmed write stored `entry` together with the data (entries loaded from the record are).
local function confirmed(profile: ProfileImpl, entry: OutboxEntry): boolean
	local ext = profile.ext
	local seqs = if ext ~= nil then ext.outboxSeq else nil
	local seq = if seqs ~= nil then seqs[entry.i] else nil
	if seq == nil then
		return true
	end
	local upTo = profile.savedSeq
	if profile.skipData then
		-- releasing without the data: only writes made before it stored the outbox (and the edits behind its entries)
		local st = if ext ~= nil then ext.cmd :: CmdState? else nil
		upTo = if st ~= nil then st.dataSeq else 0
	end
	return seq <= upTo
end

local function confirmedEntries(profile: ProfileImpl): { OutboxEntry }
	local list: { OutboxEntry } = {}
	local ext = profile.ext
	local outbox = if ext ~= nil then ext.outbox else nil
	if outbox ~= nil then
		for _, entry in outbox do
			if confirmed(profile, entry) then
				list[#list + 1] = entry
			end
		end
	end
	return list
end

local function targetOf(impl: StoreImpl, entry: OutboxEntry): StoreImpl?
	local name = entry.s
	if name == nil then
		return impl
	end
	return impl.runtime.stores[name]
end

--- Delivers `entries` in order, skipping later entries for a target whose earlier entry failed (per-target order). Returns
--- the ids that the targets accepted and whether something failed.
local function deliverAll(
	impl: StoreImpl,
	entries: { OutboxEntry },
	sleeper: Scheduler.Timer,
	abort: () -> boolean,
	onDelivered: ((entry: OutboxEntry) -> ())?
): ({ [string]: boolean }, number, boolean)
	local runtime = impl.runtime
	local env = runtime.env
	local delivered: { [string]: boolean } = {}
	local count = 0
	local failedAny = false
	local blocked: { [string]: boolean } = {}
	for _, entry in entries do
		if abort() then
			failedAny = true
			break
		end
		local route = (entry.s or "") .. "\0" .. entry.to
		if not blocked[route] then
			local target = targetOf(impl, entry)
			local result: SendResult
			if target == nil then
				result = {
					ok = false,
					error = Errors.new("InvalidArgument", impl.name, entry.to, nil, { what = `The outbox targets store "{entry.s}", which does not exist on this server.` }),
				}
			else
				local inboxEntry: InboxEntry = { i = entry.i, t = entry.t, k = entry.k, p = entry.p }
				result = append(target, entry.to, inboxEntry, true, PRIO_DELIVERY, env.clock() + DELIVERY_TIMEOUT, sleeper, abort)
			end
			if result.ok then
				delivered[entry.i] = true
				count += 1
				if onDelivered ~= nil then
					onDelivered(entry)
				end
			elseif abort() then
				failedAny = true
				break -- stopped (session ended or shutdown), not a delivery problem
			else
				blocked[route] = true
				failedAny = true
				env.log("warn", `[Retriever] outbox delivery of command "{entry.i}" to "{entry.to}" (store "{entry.s or impl.name}") failed; it stays queued and is retried: {Errors.format(result.error)}`)
			end
		end
	end
	return delivered, count, failedAny
end

--- Removes delivered entries from the stored outbox of a record nobody holds. Best effort: a failure only means the entries
--- are delivered again later (and reported as duplicates by the target).
local function acknowledge(impl: StoreImpl, key: string, ids: { [string]: boolean }, sleeper: Scheduler.Timer): (Record.AckCtx, RetrieverError?)
	local runtime = impl.runtime
	local env = runtime.env
	local ctx: Record.AckCtx = {
		ids = ids,
		now = env.time,
		skew = runtime.options.clockSkew,
		runs = 0,
		outcome = nil,
		removed = 0,
		remaining = 0,
		touched = nil,
	}
	local backend = impl.backend
	local function transform(old: any, info: Types.KeyInfoLike?)
		return Record.ackOutbox(old, info, ctx)
	end
	local problem = retrying(impl, key, "update", PRIO_DELIVERY, function()
		ctx.runs = 0
		return backend.update(key, transform)
	end, function()
		return false -- removing already-delivered entries twice is harmless; nothing to report
	end, env.clock() + DELIVERY_TIMEOUT, sleeper, function()
		return runtime.closing
	end)
	return ctx, problem
end

local function removeEntry(profile: ProfileImpl, id: string)
	local ext = profile.ext
	if ext == nil then
		return
	end
	local outbox = ext.outbox
	if outbox ~= nil then
		for i = 1, #outbox do
			if outbox[i].i == id then
				table.remove(outbox, i)
				break
			end
		end
	end
	local seqs = ext.outboxSeq
	if seqs ~= nil then
		seqs[id] = nil
	end
	-- Remember it until a write stores the removal: if the session ends first (the delivery was in flight during the final
	-- write, or that write released without the data), the stored outbox still has it and finishAfterEnd acknowledges it.
	local st = stateOf(profile)
	local unacked = st.unacked
	if unacked == nil then
		unacked = {}
		st.unacked = unacked
	end
	if profile.state == "active" then
		Profile.touch(profile) -- persist the removal with the next write (a crash before it only re-delivers)
	end
	(unacked :: { [string]: number })[id] = if profile.state == "active" then profile.editSeq else math.huge
end

--- After a clean end: deliver what the final write confirmed and remove it from the stored outbox while it is unlocked.
local function finishAfterEnd(profile: ProfileImpl, st: CmdState)
	local impl = profile.impl
	local runtime = impl.runtime
	if runtime.closing or runtime.destroyed or profile.state ~= "closed" then
		return -- shutdown: the entries wait in the record; ownership lost: the new owner delivers them
	end
	local entries = confirmedEntries(profile)
	-- delivered earlier, but the final write did not store the removal (it ran first, or it released without the data)
	local stale: { [string]: boolean }? = nil
	local unacked = st.unacked
	st.unacked = nil
	if unacked ~= nil then
		for id, seq in unacked do
			if profile.skipData or seq > profile.savedSeq then
				if stale == nil then
					stale = {}
				end
				(stale :: { [string]: boolean })[id] = true
			end
		end
	end
	if #entries == 0 and stale == nil then
		return
	end
	local function abort(): boolean
		return runtime.closing or runtime.destroyed
	end
	local delivered, count = deliverAll(impl, entries, st.sleeper, abort, nil)
	if stale ~= nil then
		for id in stale do
			delivered[id] = true
			count += 1
		end
	end
	if count > 0 and not abort() then
		acknowledge(impl, profile.key, delivered, st.sleeper)
	end
end

local function courier(profile: ProfileImpl, st: CmdState)
	local impl = profile.impl
	local runtime = impl.runtime
	local function abort(): boolean
		return profile.state ~= "active" or runtime.closing or runtime.destroyed
	end
	while not abort() do
		local entries = confirmedEntries(profile)
		if #entries == 0 then
			break
		end
		local _, _, failedAny = deliverAll(impl, entries, st.sleeper, abort, function(entry: OutboxEntry)
			removeEntry(profile, entry.i)
		end)
		if failedAny then
			if abort() then
				break
			end
			st.attempt += 1
			local delay = math.min(COURIER_CAP, COURIER_BASE * 2 ^ (st.attempt - 1)) * (0.75 + 0.25 * runtime.env.random())
			Scheduler.sleepOn(runtime.scheduler, st.sleeper, delay)
		else
			st.attempt = 0
		end
	end
	st.running = false
	if profile.state == "closed" then
		finishAfterEnd(profile, st)
	end
end

--- Starts the courier when confirmed entries wait and none is running. A running courier rescans after every round.
local function kick(profile: ProfileImpl)
	local ext = profile.ext
	if ext == nil or profile.state ~= "active" then
		return
	end
	local outbox = ext.outbox
	if outbox == nil or #outbox == 0 then
		return
	end
	local runtime = profile.impl.runtime
	if runtime.closing or runtime.destroyed then
		return
	end
	local st = stateOf(profile)
	if st.running then
		return
	end
	local ready = false
	for _, entry in outbox do
		if confirmed(profile, entry) then
			ready = true
			break
		end
	end
	if ready then
		st.running = true
		runtime.env.spawn(courier, profile, st)
	end
end

------------------------------------------------------------------------------------------------------------------------
-- hooks (installed on every store; each costs a couple of field reads when commands are not used)
------------------------------------------------------------------------------------------------------------------------

local function afterActivate(profile: ProfileImpl, rec: Types.Record)
	if consume(profile, rec.ib) then
		Profile.requestSave(profile)
	end
	kick(profile)
end

local function afterWrite(profile: ProfileImpl, rec: Types.Record?)
	local ext = profile.ext
	if ext ~= nil and not profile.skipData and (ext.outboxSeq ~= nil or ext.cmd ~= nil) then
		-- this write stored the data and the outbox: entries up to `savedSeq` are durable, and so are removals before it
		local st = stateOf(profile)
		st.dataSeq = profile.savedSeq
		local unacked = st.unacked
		if unacked ~= nil then
			for id, seq in unacked do
				if seq <= profile.savedSeq then
					unacked[id] = nil
				end
			end
			if next(unacked) == nil then
				st.unacked = nil
			end
		end
	end
	if rec ~= nil and rec.ib ~= nil and consume(profile, rec.ib) then
		profile.wantSave = true -- Profile.run submits another round
	end
	if profile.ext ~= nil then
		kick(profile)
	end
end

local function afterEnd(profile: ProfileImpl)
	local ext = profile.ext
	if ext == nil then
		return
	end
	local outbox = ext.outbox
	local st = ext.cmd :: CmdState?
	if st ~= nil and st.running then
		-- the courier finishes its request (or its sleep ends now), sees the end and takes care of the rest
		Scheduler.wake(profile.impl.runtime.scheduler, st.sleeper)
		return
	end
	if (outbox == nil or #outbox == 0) and (st == nil or st.unacked == nil) or profile.state ~= "closed" then
		return
	end
	local runtime = profile.impl.runtime
	if runtime.closing or runtime.destroyed then
		return
	end
	local state = stateOf(profile)
	state.running = true
	runtime.env.defer(function()
		finishAfterEnd(profile, state)
		state.running = false
	end)
end

Commands.hooks = {
	afterActivate = afterActivate,
	afterWrite = afterWrite,
	afterEnd = afterEnd,
} :: Internal.Hooks

------------------------------------------------------------------------------------------------------------------------
-- public API (installed as Store methods)
------------------------------------------------------------------------------------------------------------------------

local function checkKind(kind: any, level: number)
	if type(kind) ~= "string" or kind == "" or #kind > MAX_KIND then
		error(`[Retriever] the command kind must be a non-empty string of at most {MAX_KIND} characters, got {typeof(kind)} "{tostring(kind)}"`, level + 1)
	end
end

--- `store:onCommand(kind, handler)`.
function Commands.onCommand(impl: StoreImpl, kind: string, handler: (profile: any, payload: any, id: string) -> ())
	checkKind(kind, 2)
	if type(handler) ~= "function" then
		error(`[Retriever] store:onCommand("{kind}", handler) needs a function (profile, payload, id) -> ()`, 2)
	end
	local handlers = impl.commandHandlers
	if handlers == nil then
		handlers = {}
		impl.commandHandlers = handlers
	end
	local map = handlers :: { [string]: (profile: any, payload: any, id: string) -> () }
	if string.sub(kind, 1, 10) == "retriever." then
		error(`[Retriever] command kinds starting with "retriever." are reserved for the library (got "{kind}")`, 2)
	end
	if map[kind] ~= nil then
		error(`[Retriever] a handler for command "{kind}" is already registered on store "{impl.name}"`, 2)
	end
	map[kind] = handler
	-- Sessions loaded before the handler existed may hold such entries: a save returns the current record and consumes them.
	local active: { ProfileImpl } = {}
	for _, profile in impl.profiles do
		if profile.state == "active" then
			active[#active + 1] = profile
		end
	end
	for _, profile in active do
		Profile.requestSave(profile)
	end
end

--- `store:send(key, kind, payload, options)`.
function Commands.send(impl: StoreImpl, key: string, kind: string, payload: any, options: Types.SendOptions?): SendResult
	if type(key) ~= "string" or key == "" or #key > 50 then
		error(`[Retriever] store:send(key, kind, payload) needs a non-empty key of at most 50 characters, got {typeof(key)} "{tostring(key)}"`, 2)
	end
	checkKind(kind, 2)
	local opts: Types.SendOptions = options or {}
	local id = opts.id
	if id ~= nil and (type(id) ~= "string" or id == "" or #id > MAX_ID) then
		error(`[Retriever] store:send: options.id must be a non-empty string of at most {MAX_ID} characters, got {typeof(id)} "{tostring(id)}"`, 2)
	end
	local runtime = impl.runtime
	local env = runtime.env
	if runtime.closing then
		return { ok = false, error = Errors.new("ShuttingDown", impl.name, key) }
	end
	if payload ~= nil then
		local storable, why = Validate.storable(payload)
		if not storable then
			return { ok = false, error = Errors.new("InvalidData", impl.name, key, why, { what = "The command payload cannot be stored in a DataStore." }) }
		end
	end
	local entry: InboxEntry = {
		i = if id ~= nil then id else env.guid(),
		t = env.time(),
		k = kind,
		p = Util.deepCopy(payload),
	}
	local timeout = if opts.timeout ~= nil then opts.timeout else SEND_TIMEOUT
	return append(impl, key, entry, opts.create ~= false, PRIO_SEND, env.clock() + timeout, Scheduler.newSleeper(runtime.scheduler), nil)
end

--- `store:deliverOutbox(key)`: delivers the stored outbox of a record nobody owns.
function Commands.deliverOutbox(impl: StoreImpl, key: string): DeliverResult
	if type(key) ~= "string" or key == "" or #key > 50 then
		error(`[Retriever] store:deliverOutbox(key) needs a non-empty key of at most 50 characters, got {typeof(key)} "{tostring(key)}"`, 2)
	end
	local runtime = impl.runtime
	local env = runtime.env
	if runtime.closing then
		return { ok = false, error = Errors.new("ShuttingDown", impl.name, key) }
	end
	local loaded = impl.profiles[key]
	if loaded ~= nil and loaded.state == "active" then
		-- this server owns it: its courier delivers (start it now in case it is idle)
		kick(loaded)
		local outbox = if loaded.ext ~= nil then loaded.ext.outbox else nil
		return { ok = true, delivered = 0, remaining = if outbox ~= nil then #outbox else 0 }
	end
	local sleeper = Scheduler.newSleeper(runtime.scheduler)
	local backend = impl.backend
	local problem, _, value = retrying(impl, key, "get", PRIO_SEND, function()
		return backend.get(key, false)
	end, function()
		return false
	end, env.clock() + SEND_TIMEOUT, sleeper, nil)
	if problem ~= nil then
		return { ok = false, error = problem }
	end
	if value == nil then
		return { ok = false, error = Errors.new("NotFound", impl.name, key) }
	end
	if not Record.isEnvelope(value) then
		return { ok = false, error = Errors.new("Corrupt", impl.name, key) }
	end
	local rec = value :: Types.Record
	if rec.v > Record.VERSION then
		-- a newer envelope format may store the outbox differently: deliver nothing rather than guess
		return { ok = false, error = Errors.new("SchemaTooNew", impl.name, key, "the record uses a newer storage format than this version of Retriever") }
	end
	local lock = rec.l
	if lock ~= nil and env.time() < lock.x + runtime.options.clockSkew then
		return {
			ok = false,
			error = Errors.new("Locked", impl.name, key, nil, { what = "Its owner delivers the outbox itself.", ownerJob = lock.j }),
		}
	end
	local entries = rec.ob
	if entries == nil or #entries == 0 then
		return { ok = true, delivered = 0, remaining = 0 }
	end
	local function abort(): boolean
		return runtime.closing or runtime.destroyed
	end
	local delivered, count = deliverAll(impl, entries, sleeper, abort, nil)
	if count == 0 then
		return { ok = true, delivered = 0, remaining = #entries }
	end
	local ctx, ackProblem = acknowledge(impl, key, delivered, sleeper)
	if ackProblem ~= nil then
		return { ok = false, error = ackProblem }
	end
	local remaining = if ctx.outcome == "removed" or ctx.outcome == "none" then ctx.remaining else #entries - count
	return { ok = true, delivered = count, remaining = remaining }
end

return Commands
