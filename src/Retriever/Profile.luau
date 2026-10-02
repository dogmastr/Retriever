--!strict
--[[
	A live session over one key: buffered edits, confirmed commits, automatic saves and the final release.

	Write model
	* One `Profile` is its own dispatcher Job and scheduler Timer. A save attempt is `Profile.run`: exactly one UpdateAsync.
	  Failure never sleeps inside the worker; it arms the profile's single heap entry (`retryAt`) and returns, so a worker is
	  busy only while a request is actually in flight.
	* The callback (`Record.write`) is created once per profile and reads the live fields at call time. It assigns the live
	  data table into the stored record by reference, and the engine serializes it synchronously right after the callback
	  returns. The callback also captures `editSeq`, so after a successful call we know exactly which edits that write
	  contains (`savedSeq`). That makes commit exact and needs no deep copy and no retained "last saved" snapshot.
	* Dirty tracking: edits bump `editSeq` and, on the first edit after a save, arm the autosave deadline. Clean sessions are
	  only written to renew the lease (every lease/2) and on close.
	* Outcomes: if the UpdateAsync call raised after our callback had produced a value, the write MAY have landed. We record
	  that as `unknownSeq`, retry (the next successful write contains everything), and report `Unknown` to waiters only if the
	  session ends or the commit times out before a later write succeeds.
]]

local Dispatcher = require(script.Parent.Dispatcher)
local Classify = require(script.Parent.Classify)
local Errors = require(script.Parent.Errors)
local Events = require(script.Parent.Events)
local Histogram = require(script.Parent.Histogram)
local Internal = require(script.Parent.Internal)
local Lane = require(script.Parent.Lane)
local Record = require(script.Parent.Record)
local Schema = require(script.Parent.Schema)
local Scheduler = require(script.Parent.Scheduler)
local Types = require(script.Parent.Types)
local Util = require(script.Parent.Util)
local Validate = require(script.Parent.Validate)

type ProfileImpl = Internal.ProfileImpl
type StoreImpl = Internal.StoreImpl
type Waiter = Internal.Waiter
type CommitResult = Types.CommitResult
type CloseResult = Types.CloseResult
type RetrieverError = Types.RetrieverError
type EndReason = Types.EndReason

local Profile = {}
Profile.__index = Profile

local INF = math.huge

------------------------------------------------------------------------------------------------------------------------
-- helpers
------------------------------------------------------------------------------------------------------------------------

local function now(self: ProfileImpl): number
	return self.impl.runtime.env.clock()
end

local function dispatcherOf(self: ProfileImpl): Dispatcher.Dispatcher
	return self.impl.runtime.dispatcher
end

local function err(self: ProfileImpl, kind: Types.ErrorKind, cause: string?, details: { [string]: any }?): RetrieverError
	return Errors.new(kind, self.impl.name, self.key, cause, details)
end

--- Hands a result to a waiter. If its caller has not yielded yet, the caller returns the stored result when it gets to `park`.
local function settle(waiter: Waiter, result: any)
	waiter.result = result
end

--- Resumes the parked callers in `list`. This MUST be the last thing a state transition does: `task.spawn` runs the resumed
--- code immediately, and that code may call straight back into this profile (edit, commit, close, load).
local function wake(self: ProfileImpl, list: { Waiter }?)
	if list == nil then
		return
	end
	local env = self.impl.runtime.env
	for i = 1, #list do
		local w = list[i]
		if w.parked then
			w.parked = false
			if coroutine.status(w.thread) == "suspended" then
				env.spawn(w.thread, w.result)
			end
		end
	end
end

--- Yields the calling thread until `waiter` is settled (returns at once when it already was).
local function park(waiter: Waiter): any
	local result = waiter.result
	if result ~= nil then
		return result
	end
	waiter.parked = true
	return coroutine.yield()
end

local function backoff(self: ProfileImpl, attempt: number, throttleScope: string?): number
	local runtime = self.impl.runtime
	local options = runtime.options
	local delay = math.min(options.backoffCap, options.backoffBase * 2 ^ (attempt - 1))
	if throttleScope == "experience" then
		delay = math.max(delay, 5) -- every server is throttled: do not come back all at once
	elseif throttleScope ~= nil then
		delay = math.max(delay, 2)
	end
	-- equal jitter: [delay/2, delay]
	return delay * (0.5 + 0.5 * runtime.env.random())
end

local function minWaiterDeadline(self: ProfileImpl): number
	local waiters = self.waiters
	if waiters == nil then
		return INF
	end
	local best = INF
	for i = 1, #waiters do
		local d = waiters[i].deadline
		if d < best then
			best = d
		end
	end
	return best
end

--- Re-arms the profile's single heap entry from its current state.
local function reschedule(self: ProfileImpl)
	local scheduler = self.impl.runtime.scheduler
	local due = INF
	local retryAt = self.retryAt
	if retryAt ~= nil then
		due = retryAt
	elseif not (self.writing or self.queued or self.wantSave or self.wantClose or self.laneState ~= 0) then
		due = math.min(self.dirtyDue, self.renewDue)
	end
	local deadline = minWaiterDeadline(self)
	if deadline < due then
		due = deadline
	end
	if due == INF or self.state == "closed" or self.state == "lost" then
		Scheduler.cancel(scheduler, self :: any)
	else
		Scheduler.schedule(scheduler, self :: any, due)
	end
end

local function releaseLane(self: ProfileImpl)
	if self.laneState ~= 0 then
		self.laneState = 0
		Lane.release(self.lane, dispatcherOf(self))
	end
end

--- Queues a write attempt (no-op when one is queued, running or waiting out a backoff).
local function submit(self: ProfileImpl)
	if self.queued or self.writing or self.retryAt ~= nil then
		return
	end
	local state = self.state
	if state == "closed" or state == "lost" then
		return
	end
	local waiters = self.waiters
	self.prio = if self.wantClose then 0 elseif waiters ~= nil and #waiters > 0 then 2 else 3
	local ls = self.laneState
	if ls == 0 then
		self.laneState = 1
		Lane.submit(self.lane, dispatcherOf(self), self :: any)
	elseif ls == 2 then
		Dispatcher.submit(dispatcherOf(self), self :: any)
	end
	-- ls == 1: already waiting in the lane queue
end

------------------------------------------------------------------------------------------------------------------------
-- dirty tracking
------------------------------------------------------------------------------------------------------------------------

local function markDirty(self: ProfileImpl)
	self.editSeq += 1
	if self.dirtyDue == INF then
		local runtime = self.impl.runtime
		local jitter = runtime.options.jitter
		self.dirtyDue = runtime.env.clock() + self.impl.config.autosave * (1 - jitter * runtime.env.random())
		reschedule(self)
	end
end

------------------------------------------------------------------------------------------------------------------------
-- ending a session
------------------------------------------------------------------------------------------------------------------------

local function pushWaiter(self: ProfileImpl, waiter: Waiter)
	local list: { Waiter }
	local existing = self.waiters
	if existing == nil then
		list = {}
		self.waiters = list
	else
		list = existing
	end
	list[#list + 1] = waiter
end

--- Settles every waiter with an error and returns them; the caller wakes them as its LAST step.
--- Fails the waiters. With `keepClose`, close waiters (seq == INF) stay parked: the close continues and settles them.
local function failWaiters(
	self: ProfileImpl,
	kindIfKnown: Types.ErrorKind,
	cause: string?,
	keepClose: boolean?,
	details: { [string]: any }?
): { Waiter }?
	local waiters = self.waiters
	if waiters == nil then
		return nil
	end
	local failed: { Waiter } = {}
	local kept: { Waiter } = {}
	for i = 1, #waiters do
		local w = waiters[i]
		if keepClose and w.seq == INF then
			table.insert(kept, w)
		else
			local kind: Types.ErrorKind = kindIfKnown
			if self.unknownSeq >= w.seq and w.seq ~= INF then
				kind = "Unknown" -- a write that included this waiter's edits may have landed
			end
			settle(w, { ok = false, error = err(self, kind, cause, details) })
			table.insert(failed, w)
		end
	end
	self.waiters = if #kept > 0 then kept else nil
	return if #failed > 0 then failed else nil
end

local function okWaiters(self: ProfileImpl): { Waiter }?
	local waiters = self.waiters
	if waiters == nil then
		return nil
	end
	self.waiters = nil
	for i = 1, #waiters do
		settle(waiters[i], { ok = true, revision = self.rev })
	end
	return waiters
end

--- Ends the session: cleanup first, then wake whoever waits, then notify. Always the last thing its caller does.
local function endSession(self: ProfileImpl, reason: EndReason, problem: RetrieverError?)
	local state = self.state
	if state == "closed" or state == "lost" then
		return
	end
	local impl = self.impl
	local runtime = impl.runtime
	local lost = reason == "ownershipLost" or reason == "faulted"
	self.state = if lost then "lost" else "closed"
	self.endReason = reason
	self.endError = problem

	Scheduler.cancel(runtime.scheduler, self :: any)
	Dispatcher.remove(runtime.dispatcher, self :: any)
	self.retryAt = nil

	local resolved = if problem == nil then okWaiters(self) else failWaiters(self, problem.kind, problem.cause)

	impl.profiles[self.key] = nil
	impl.sessions -= 1
	impl.counters.sessionsClosed += 1
	if lost then
		impl.counters.ownershipLost += 1
	end

	local data = self.data
	if type(data) == "table" and not table.isfrozen(data) then
		table.freeze(data)
	end
	if runtime.events ~= nil then
		Events.emit(runtime, impl.name, self.key, "ended", {
			reason = reason :: string,
			error = if problem ~= nil then problem.kind else nil,
			cause = if problem ~= nil then problem.cause else nil,
			revision = self.rev,
		})
	end

	local ext = self.ext
	local callbacks = if ext ~= nil then ext.ended else nil
	if ext ~= nil then
		ext.ended = nil
	end
	local lane = self.lane
	lane.holders -= 1
	self.cb = nil :: any -- break the profile <-> callback cycle
	releaseLane(self) -- may start the next queued job for this key
	if Lane.isIdle(lane) and impl.lanes[self.key] == lane then
		impl.lanes[self.key] = nil
	end

	wake(self, resolved)
	if callbacks ~= nil then
		for i = 1, #callbacks do
			runtime.env.spawn(callbacks[i], reason, problem)
		end
	end
	local hooks = impl.hooks
	if hooks ~= nil and hooks.afterEnd ~= nil then
		hooks.afterEnd(self) -- after everything else: it may resume other threads (the outbox courier)
	end
end

------------------------------------------------------------------------------------------------------------------------
-- write outcomes
------------------------------------------------------------------------------------------------------------------------

--- Records a successful write. Returns the commit waiters to wake (the caller wakes them last), or nil.
local function onWritten(self: ProfileImpl, returned: any): { Waiter }?
	local impl = self.impl
	local counters = impl.counters
	local t = now(self)
	counters.savesWritten += 1
	self.rev = self.cbRev
	if self.cbSeq > self.savedSeq then
		self.savedSeq = self.cbSeq
	end
	self.attempt = 0
	self.retryAt = nil
	self.renewDue = t + impl.policy.lease / 2

	if self.editSeq > self.savedSeq then
		-- edited while the write was in flight: a fresh autosave window starts now
		local runtime = impl.runtime
		self.dirtyDue = t + impl.config.autosave * (1 - runtime.options.jitter * runtime.env.random())
	else
		self.dirtyDue = INF
	end

	local ext = self.ext
	if ext ~= nil then
		local consumed = ext.consumed
		if consumed ~= nil then
			local upTo = self.cbConsumedSeq
			for id, seq in consumed do
				if seq <= upTo then
					consumed[id] = nil
				end
			end
		end
	end

	local waiterJob = self.cbReleaseRequested
	if self.closing then
		-- everything (commit and close waiters) is satisfied by the final write, unless that write released the lock without
		-- the data (`skipData`): then commits made while closing were NOT saved and must not be told otherwise
		local unsaved: { Waiter }? = nil
		if self.skipData then
			unsaved = failWaiters(self, "InvalidData", "the data could not be saved; the session closed without it", true)
		end
		endSession(self, self.endReason, nil)
		if waiterJob ~= nil then
			-- someone is waiting for this profile: tell them it is free instead of letting them wait out a poll delay
			impl.runtime.handoff.released(impl.runtime, waiterJob, impl.name, self.key)
		end
		return unsaved
	end

	-- commit waiters whose edits are covered by this write; the others need another round
	local resolved: { Waiter } = {}
	local waiters = self.waiters
	if waiters ~= nil then
		local keep: { Waiter } = {}
		for i = 1, #waiters do
			local w = waiters[i]
			if w.seq <= self.savedSeq then
				counters.commitsConfirmed += 1
				settle(w, { ok = true, revision = self.rev })
				resolved[#resolved + 1] = w
			else
				keep[#keep + 1] = w
			end
		end
		self.waiters = if #keep > 0 then keep else nil
		if #keep > 0 then
			self.wantSave = true -- someone committed after this write's snapshot: another round
		end
	end

	local hooks = impl.hooks
	if hooks ~= nil then
		local after = hooks.afterWrite
		if after ~= nil then
			after(self, if type(returned) == "table" then returned :: Types.Record else nil)
		end
	end

	if waiterJob ~= nil and self.endReason ~= "released" then
		-- another server asked for this profile: end the session so it can proceed
		self.endReason = "released"
		if impl.runtime.events ~= nil then
			Events.emit(impl.runtime, impl.name, self.key, "handoffRequested", { revision = self.rev, details = { by = waiterJob } })
		end
		impl.runtime.env.spawn(function()
			Profile.close(self, { timeout = 30 })
		end)
	end
	return if #resolved > 0 then resolved else nil
end

--- The data cannot be written (invalid/too large/forbidden). Waiters learn why; the session stays alive so game code can fix the
--- data, and a close releases the lock without the unwritable data so the player is not locked out.
local function onUnwritable(self: ProfileImpl, kind: Types.ErrorKind, cause: string?): { Waiter }?
	local runtime = self.impl.runtime
	if runtime.events ~= nil then
		Events.emit(runtime, self.impl.name, self.key, "unwritable", { error = kind, cause = cause, details = { closing = self.wantClose } })
	end
	self.attempt += 1
	self.retryThrottled = false
	if self.wantClose then
		if not self.skipData then
			-- the only trace of a player losing this session's progress in a production server (events are opt-in)
			runtime.env.log(
				"error",
				`[Retriever] store "{self.impl.name}", key "{self.key}": the data cannot be saved ({kind}: {tostring(cause)}). The session is closing, so its lock is released WITHOUT the data and this session's unsaved changes are lost.`
			)
		end
		self.skipData = true
		self.retryAt = now(self) + backoff(self, 1, nil)
	else
		self.retryAt = now(self) + math.max(self.impl.config.autosave, 5)
	end
	-- a closing session keeps going with skipData and settles its close waiters itself; only commits fail here
	local path = Schema.pathOf(cause)
	return failWaiters(self, kind, cause, self.wantClose, if path ~= nil then { path = path } else nil)
end

local function onRejected(self: ProfileImpl): { Waiter }?
	local outcome = self.cbOutcome
	if outcome == "invalid" then
		self.impl.counters.failures += 1
		return onUnwritable(self, "InvalidData", self.cbError)
	end
	local what = if outcome == "missing"
		then "the record was deleted"
		elseif outcome == "corrupt" then "the record was overwritten with a non-Retriever value"
		elseif outcome == "schemaTooNew" then "the record now requires a newer schema version than this server runs"
		else "another server holds a newer epoch"
	endSession(self, "ownershipLost", err(self, "OwnershipLost", what))
	return nil
end

local function onFailed(self: ProfileImpl, raised: any): { Waiter }?
	local impl = self.impl
	local counters = impl.counters
	counters.failures += 1
	local text = tostring(raised)
	local class = Classify.error(text)
	local producedValue = self.cbRuns > 0 and self.cbOutcome == "wrote"

	if class.maybeApplied and producedValue then
		if self.cbSeq > self.unknownSeq then
			self.unknownSeq = self.cbSeq
		end
	end

	local kind = class.kind
	if impl.runtime.events ~= nil then
		Events.emit(impl.runtime, impl.name, self.key, "writeFailed", {
			cause = text,
			details = {
				attempt = self.attempt + 1,
				throttled = kind == "throttled",
				maybeApplied = class.maybeApplied and producedValue,
				closing = self.wantClose,
			},
		})
	end
	if kind == "shutdown" then
		-- the DataModel is going away; no further request can succeed on this server
		endSession(self, self.endReason, err(self, "Unavailable", text, { what = "The server is shutting down; the lock expires on its own." }))
		return nil
	end
	if kind == "invalidData" or kind == "tooLarge" or kind == "access" or kind == "permanent" then
		local errorKind: Types.ErrorKind = if kind == "tooLarge" then "TooLarge" elseif kind == "access" then "StudioApiDisabled" else "InvalidData"
		local cause = text
		if errorKind == "InvalidData" and Schema.pathOf(text) == nil and self.data ~= nil then
			-- The engine says "104: Cannot store ..." without naming the value. Debug mode validates every save, production does
			-- not, so find the offender now (once per failed write) and report its path, as the README promises.
			local storable, found = Validate.storable(self.data)
			if not storable and found ~= nil then
				cause = found
			end
		end
		return onUnwritable(self, errorKind, cause)
	end

	counters.retries += 1
	self.attempt += 1
	self.retryThrottled = kind == "throttled"
	if kind == "throttled" then
		Dispatcher.noteThrottle(dispatcherOf(self), "update", class.scope)
	end
	self.retryAt = now(self) + backoff(self, self.attempt, if kind == "throttled" then (class.scope or "server") else nil)
	return nil
end

------------------------------------------------------------------------------------------------------------------------
-- Job and Timer entry points
------------------------------------------------------------------------------------------------------------------------

--- Dispatcher job: one write attempt.
function Profile.run(self: ProfileImpl)
	self.laneState = 2
	local state = self.state
	if state == "closed" or state == "lost" then
		releaseLane(self)
		return
	end
	local impl = self.impl
	local closing = self.wantClose
	if not closing and not self.wantSave and self.editSeq <= self.savedSeq and self.dirtyDue == INF and self.renewDue > now(self) then
		-- nothing left to do (the request was already satisfied by an earlier write)
		impl.counters.savesSkippedClean += 1
		releaseLane(self)
		reschedule(self)
		return
	end

	self.wantSave = false
	self.closing = closing
	self.writing = true
	self.cbRuns = 0
	impl.counters.requestsUpdate += 1
	local runtime = impl.runtime
	local started = runtime.env.clock()
	local ok, raised = pcall(impl.backend.update, self.key, self.cb)
	self.writing = false
	Histogram.observe(runtime.metrics.write, runtime.env.clock() - started)

	if self.state == "closed" or self.state == "lost" then
		return -- ended while the request was in flight (for example by shutdown); endSession already cleaned up
	end

	local resolved: { Waiter }? = nil
	if ok then
		local outcome = self.cbOutcome
		if outcome == "wrote" then
			resolved = onWritten(self, raised)
		elseif outcome == nil then
			resolved = onFailed(self, "UpdateAsync returned without running the transform callback") -- should not happen; retry
		else
			resolved = onRejected(self)
		end
	else
		resolved = onFailed(self, raised)
	end

	local after = self.state
	if after == "closed" or after == "lost" then
		wake(self, resolved) -- commits the final write could not cover (see onWritten); nil otherwise
		return
	end
	if self.retryAt ~= nil then
		reschedule(self)
	elseif self.wantClose or self.wantSave then
		submit(self)
	else
		releaseLane(self)
		reschedule(self)
	end
	wake(self, resolved) -- last: resumed code may call straight back into this profile
end

--- Scheduler timer: autosave / lease renewal / retry / commit deadline.
function Profile.fire(self: ProfileImpl)
	local state = self.state
	if state == "closed" or state == "lost" then
		return
	end
	local t = now(self)

	-- commit / close deadlines
	local expired: { Waiter } = {}
	local waiters = self.waiters
	if waiters ~= nil then
		local keep: { Waiter } = {}
		for i = 1, #waiters do
			local w = waiters[i]
			if w.deadline <= t then
				local kind: Types.ErrorKind = if self.unknownSeq >= w.seq and w.seq ~= INF then "Unknown" else "Unavailable"
				if kind == "Unknown" then
					self.impl.counters.commitsUnknown += 1
				end
				settle(w, { ok = false, error = err(self, kind, "timed out waiting for the save to be confirmed") })
				expired[#expired + 1] = w
			else
				keep[#keep + 1] = w
			end
		end
		if #expired > 0 then
			self.waiters = if #keep > 0 then keep else nil
		end
	end

	if self.wantClose and self.closeDeadline <= t then
		-- the final save could not complete in time: end locally; the lease expires on its own
		endSession(self, self.endReason, err(self, "Unknown", "the final save did not complete before the close timeout"))
		wake(self, expired)
		return
	end

	local retryAt = self.retryAt
	if retryAt ~= nil then
		if retryAt <= t then
			self.retryAt = nil
			submit(self)
		end
	elseif not (self.writing or self.queued or self.wantSave or self.wantClose or self.laneState ~= 0) then
		if self.dirtyDue <= t or self.renewDue <= t then
			self.wantSave = true
			submit(self)
		end
	end
	reschedule(self)
	wake(self, expired)
end

------------------------------------------------------------------------------------------------------------------------
-- construction
------------------------------------------------------------------------------------------------------------------------

--- Builds a session that already holds the lock. `laneState` is 2 when the caller owned the lane and hands it over.
function Profile.new(
	impl: StoreImpl,
	key: string,
	lane: Lane.Lane,
	ctx: Record.AcquireCtx,
	data: any,
	dirty: boolean,
	rec: Types.Record?,
	userIds: { number }?,
	meta: { [string]: any }?,
	minReader: number?
): ProfileImpl
	local runtime = impl.runtime
	local env = runtime.env
	local t = env.clock()

	local ext: Record.Ext? = nil
	if rec ~= nil and (rec.o ~= nil or rec.ob ~= nil) then
		local ops = rec.o
		local count = 0
		if ops ~= nil then
			for _ in ops do
				count += 1
			end
		end
		ext = {
			ops = ops,
			opsCount = count,
			opsHorizon = rec.oh,
			outbox = rec.ob,
			consumed = nil,
			consumedSeq = 0,
			ended = nil,
			outboxSeq = nil,
			cmd = nil,
		}
	end

	local self = setmetatable({
		prio = 3,
		kind = "update",
		queued = false,
		due = 0,
		heapIndex = 0,
		thread = nil,

		key = key,
		store = impl,
		state = "active",
		data = data,
		skipData = data == nil,

		impl = impl,
		lane = lane,
		laneState = 2,
		policy = impl.policy,
		epoch = ctx.epoch,
		closing = false,
		userIds = userIds,
		meta = meta,
		minReader = minReader,
		editSeq = if dirty then 1 else 0,
		ext = ext,
		cbRuns = 0,
		cbOutcome = nil,
		cbSeq = 0,
		cbConsumedSeq = 0,
		cbError = nil,
		cbRev = 0,
		cbReleaseRequested = nil,

		cb = nil,
		rev = ctx.rev,
		savedSeq = 0,
		unknownSeq = 0,
		dirtyDue = if dirty then t + math.min(impl.config.autosave, 10) else INF,
		renewDue = t + impl.policy.lease / 2,
		retryAt = nil,
		retryThrottled = false,
		attempt = 0,
		wantSave = false,
		wantClose = false,
		writing = false,
		closeDeadline = INF,
		endReason = "closed",
		endError = nil,
		waiters = nil,
		leaseExpiry = ctx.leaseExpiry,
	}, Profile) :: any
	local profile = self :: ProfileImpl
	profile.cb = function(old: any, info: Types.KeyInfoLike?)
		return Record.write(old, info, profile)
	end

	impl.profiles[key] = profile
	impl.sessions += 1
	lane.holders += 1
	impl.counters.sessionsOpened += 1
	return profile
end

--- Called by the loader once the session is visible to the caller: gives the lane back and arms timers.
function Profile.activate(self: ProfileImpl)
	releaseLane(self)
	reschedule(self)
end

------------------------------------------------------------------------------------------------------------------------
-- public API
------------------------------------------------------------------------------------------------------------------------

local function checkEditable(self: ProfileImpl, what: string): boolean
	local state = self.state
	if state == "active" then
		return true
	end
	if state == "lost" then
		return false
	end
	error(`[Retriever] {what}() on profile "{self.key}" (store "{self.impl.name}") after close() was called. Do not edit a profile once you started closing it.`, 3)
end

--- Asks for a save as soon as possible (handoff wake-ups, inbox processing). No-op unless the session is active.
function Profile.requestSave(self: ProfileImpl)
	if self.state ~= "active" then
		return
	end
	self.wantSave = true
	submit(self)
end

function Profile.edit(self: ProfileImpl, fn: (data: any) -> ())
	if not checkEditable(self, "edit") then
		return -- session lost: edits can no longer be persisted; onEnded already told the owner of this profile
	end
	markDirty(self)
	fn(self.data)
end

function Profile.touch(self: ProfileImpl)
	if checkEditable(self, "touch") then
		markDirty(self)
	end
end

--- Drops ledger entries older than the retention window, then the oldest entries beyond the size limit minus `room`. The
--- horizon records the newest time that was forgotten, so callers can tell how far back duplicate detection reaches. `apply`
--- prunes BEFORE it records its own id and asks for one slot of room, so the id it is about to record can never be the one
--- evicted (op times have a resolution of one second, so many entries tie for "oldest").
local function pruneLedger(self: ProfileImpl, t: number, room: number)
	local ext = self.ext
	if ext == nil or ext.ops == nil then
		return
	end
	local ops = ext.ops :: { [string]: number }
	local config = self.impl.config
	local limit = config.ledgerMax - room
	local cutoff = t - config.ledgerRetention
	local horizon = ext.opsHorizon or 0
	for id, applied in ops do
		if applied < cutoff then
			ops[id] = nil
			ext.opsCount -= 1
			if applied > horizon then
				horizon = applied
			end
		end
	end
	if ext.opsCount > limit then
		local entries: { { id: string, t: number } } = {}
		for id, applied in ops do
			entries[#entries + 1] = { id = id, t = applied }
		end
		table.sort(entries, function(a: { id: string, t: number }, b: { id: string, t: number })
			if a.t ~= b.t then
				return a.t < b.t
			end
			return a.id < b.id -- a total order: which of several same-second entries goes first must not depend on hash order
		end)
		for i = 1, ext.opsCount - limit do
			local entry = entries[i]
			ops[entry.id] = nil
			if entry.t > horizon then
				horizon = entry.t
			end
		end
		ext.opsCount = limit
	end
	if horizon > 0 then
		ext.opsHorizon = horizon
	end
end

--- Runs `fn` at most once per `opId`. The id and the effect are saved by the same write, so after a crash, a retry or a
--- repeated callback (for example Roblox calling ProcessReceipt again) the effect is never applied twice. `fn` must not yield
--- and should validate before it mutates: if it throws, the id is not recorded and a partial effect stays in memory.
function Profile.apply(self: ProfileImpl, opId: string, fn: (data: any) -> ()): Types.ApplyResult
	if type(opId) ~= "string" or opId == "" then
		error("[Retriever] profile:apply(opId, fn) needs a non-empty string op id, for example the PurchaseId of a receipt", 2)
	end
	local state = self.state
	if state ~= "active" then
		error(`[Retriever] apply() on profile "{self.key}" (store "{self.impl.name}") which is {state}; the effect would not be saved. Check profile:isActive() first.`, 2)
	end
	local ext = Profile.ensureExt(self)
	local ops: { [string]: number }
	local existingOps = ext.ops
	if existingOps == nil then
		ops = {}
		ext.ops = ops
	else
		ops = existingOps
	end
	if ops[opId] ~= nil then
		return "duplicate"
	end
	markDirty(self)
	fn(self.data)
	local t = self.impl.runtime.env.time()
	if ext.opsCount >= self.impl.config.ledgerMax then
		pruneLedger(self, t, 1) -- make room first: the id recorded below must survive its own pruning
	end
	ops[opId] = t
	ext.opsCount += 1
	return "applied"
end

--- Adds a command for another key to this session's outbox (see Types.Profile.enqueue). Validates everything before it
--- changes anything, so a call that raises leaves the profile untouched: call it before mutating `data` inside `apply`.
function Profile.enqueue(self: ProfileImpl, targetKey: string, kind: string, payload: any, options: Types.EnqueueOptions?): string
	if type(targetKey) ~= "string" or targetKey == "" or #targetKey > 50 then
		error(`[Retriever] profile:enqueue(targetKey, kind, payload) needs a non-empty key of at most 50 characters, got {typeof(targetKey)} "{tostring(targetKey)}"`, 2)
	end
	if type(kind) ~= "string" or kind == "" or #kind > 50 then
		error(`[Retriever] profile:enqueue: the command kind must be a non-empty string of at most 50 characters, got {typeof(kind)} "{tostring(kind)}"`, 2)
	end
	local impl = self.impl
	local state = self.state
	if state ~= "active" then
		error(`[Retriever] enqueue() on profile "{self.key}" (store "{impl.name}") which is {state}; the command would not be saved. Check profile:isActive() first.`, 2)
	end
	local id: string? = nil
	local storeName: string? = nil
	if options ~= nil then
		id = options.id
		storeName = options.store
	end
	if id ~= nil and (type(id) ~= "string" or id == "" or #id > 100) then
		error(`[Retriever] profile:enqueue: options.id must be a non-empty string of at most 100 characters, got {typeof(id)} "{tostring(id)}"`, 2)
	end
	if storeName ~= nil then
		if type(storeName) ~= "string" or impl.runtime.stores[storeName] == nil then
			error(`[Retriever] profile:enqueue: options.store "{tostring(storeName)}" is not a store on this runtime; create it with Retriever.store before enqueueing commands for it`, 2)
		end
		if storeName == impl.name then
			storeName = nil
		end
	end
	local storable, why = true, nil
	if payload ~= nil then
		storable, why = Validate.storable(payload)
	end
	if not storable then
		error(`[Retriever] profile:enqueue: the payload cannot be stored in a DataStore: {why}`, 2)
	end
	local ext = Profile.ensureExt(self)
	local outbox: { Types.OutboxEntry }
	local existing = ext.outbox
	if existing == nil then
		outbox = {}
	else
		outbox = existing
	end
	local commandId: string = if id ~= nil then id else impl.runtime.env.guid()
	for i = 1, #outbox do
		if outbox[i].i == commandId then
			return commandId -- already queued: enqueueing the same id twice is one command
		end
	end
	if #outbox >= impl.config.outboxMax then
		error(`[Retriever] profile:enqueue: the outbox of "{self.key}" (store "{impl.name}") is full ({impl.config.outboxMax} undelivered commands). Deliveries are failing (targets' inboxes full or DataStore errors); raise StoreConfig.commands.outboxMax or retry later.`, 2)
	end

	markDirty(self)
	ext.outbox = outbox
	outbox[#outbox + 1] = {
		i = commandId,
		to = targetKey,
		s = storeName,
		k = kind,
		p = Util.deepCopy(payload),
		t = impl.runtime.env.time(),
	}
	local seqs = ext.outboxSeq
	if seqs == nil then
		seqs = {}
		ext.outboxSeq = seqs
	end
	(seqs :: { [string]: number })[commandId] = self.editSeq
	return commandId
end

function Profile.isActive(self: ProfileImpl): boolean
	return self.state == "active"
end

function Profile.isDirty(self: ProfileImpl): boolean
	return self.editSeq > self.savedSeq
end

function Profile.revision(self: ProfileImpl): number
	return self.rev
end

function Profile.onEnded(self: ProfileImpl, fn: (reason: EndReason, err: RetrieverError?) -> ()): () -> ()
	local state = self.state
	if state == "closed" or state == "lost" then
		self.impl.runtime.env.spawn(fn, self.endReason, self.endError)
		return function() end
	end
	local ext = Profile.ensureExt(self)
	local list: { (reason: EndReason, err: RetrieverError?) -> () }
	local existing = ext.ended
	if existing == nil then
		list = {}
		ext.ended = list
	else
		list = existing
	end
	list[#list + 1] = fn
	return function()
		local current = if self.ext ~= nil then self.ext.ended else nil
		if current ~= nil then
			local index = table.find(current, fn)
			if index ~= nil then
				table.remove(current, index)
			end
		end
	end
end

--- Allocates the rarely used per-session state on first use.
function Profile.ensureExt(self: ProfileImpl): Record.Ext
	local ext = self.ext
	if ext ~= nil then
		return ext
	end
	local created: Record.Ext = {
		ops = nil,
		opsCount = 0,
		opsHorizon = nil,
		outbox = nil,
		consumed = nil,
		consumedSeq = 0,
		ended = nil,
		outboxSeq = nil,
		cmd = nil,
	}
	self.ext = created
	return created
end

function Profile.addUserId(self: ProfileImpl, userId: number)
	local ids: { number }
	local existing = self.userIds
	if existing == nil then
		ids = {}
		self.userIds = ids
	else
		ids = existing
	end
	if table.find(ids, userId) == nil then
		table.insert(ids, userId)
		markDirty(self)
	end
end

function Profile.removeUserId(self: ProfileImpl, userId: number)
	local ids = self.userIds
	if ids ~= nil then
		local index = table.find(ids, userId)
		if index ~= nil then
			table.remove(ids, index)
			if #ids == 0 then
				self.userIds = nil
			end
			markDirty(self)
		end
	end
end

function Profile.commit(self: ProfileImpl, options: Types.CommitOptions?): CommitResult
	local state = self.state
	if state == "lost" then
		return { ok = false, error = self.endError or err(self, "OwnershipLost") }
	elseif state == "closed" then
		return { ok = false, error = err(self, "Closed") }
	end
	local target = self.editSeq
	if target <= self.savedSeq and not self.wantClose then
		return { ok = true, revision = self.rev } -- everything edited so far is already persisted
	end
	local timeout = if options ~= nil and options.timeout ~= nil then options.timeout else 30
	local started = now(self)
	local waiter: Waiter = { thread = coroutine.running(), seq = target, deadline = started + timeout, parked = false, result = nil }
	pushWaiter(self, waiter)
	self.wantSave = true
	if self.retryAt ~= nil and not self.retryThrottled then
		self.retryAt = nil -- an explicit request is worth an immediate attempt (throttle delays are kept)
	end
	submit(self)
	reschedule(self)
	local result = park(waiter) :: CommitResult
	Histogram.observe(self.impl.runtime.metrics.commit, now(self) - started)
	return result
end

function Profile.close(self: ProfileImpl, options: Types.CloseOptions?): CloseResult
	local state = self.state
	if state == "closed" then
		if self.endError ~= nil then
			return { ok = false, error = self.endError }
		end
		return { ok = true, revision = self.rev }
	elseif state == "lost" then
		return { ok = false, error = self.endError or err(self, "OwnershipLost") }
	end

	local t = now(self)
	local timeout = if options ~= nil and options.timeout ~= nil then options.timeout else 60
	local deadline = t + timeout
	if state == "active" then
		self.closeDeadline = deadline
	elseif deadline > self.closeDeadline then
		self.closeDeadline = deadline
	end

	-- Register the waiter BEFORE starting the work: a backend that never yields completes the close synchronously, and the
	-- result must find somebody to hand it to.
	local waiter: Waiter = { thread = coroutine.running(), seq = INF, deadline = self.closeDeadline, parked = false, result = nil }
	pushWaiter(self, waiter)

	if state == "active" then
		self.state = "closing"
		self.wantClose = true
		if self.endReason ~= "released" and self.endReason ~= "shutdown" then
			self.endReason = "closed"
		end
		local data = self.data
		if type(data) == "table" and not table.isfrozen(data) then
			table.freeze(data) -- catches accidental top-level writes after close()
		end
		if self.retryAt ~= nil and not self.retryThrottled then
			self.retryAt = nil -- releasing the lock is urgent
		end
		submit(self)
	end
	reschedule(self)
	local result = park(waiter) :: CloseResult
	if state == "active" then
		-- the call that started the close measures it (later calls only join the same write)
		Histogram.observe(self.impl.runtime.metrics.close, now(self) - t)
	end
	return result
end

--- Marks the session as ending because the server is shutting down (affects the reported reason only).
function Profile.closeForShutdown(self: ProfileImpl, timeout: number): CloseResult
	if self.state == "active" then
		self.endReason = "shutdown"
	end
	return Profile.close(self, { timeout = timeout })
end

return Profile
