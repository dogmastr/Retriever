--!strict
--[[
	Escrow: recoverable two-party trades between two profiles of one store (`Retriever.escrow`, DESIGN.md §3.7 and §4.12).

	A trade is not one atomic write. Every step is an op-id'd idempotent write on ONE key, and an escrow record (its own
	DataStore, key = trade id) holds the single decision. Deterministic op ids per trade and side (`a`/`b`):
	  D = `~e:<name>/<id>:d<side>` debit (or fence), C = `...:c<side>` credit, X = `...:x<side>` abort settlement.

	Protocol (`escrow:trade`)
	1. Validate both sides (pure `validate`), then create the escrow record `pending` with both sides' items (confirmed
	   UpdateAsync; nothing is debited unless this is confirmed).
	2. In one synchronous step (no yield): re-validate, then `apply(D_a, debit)` on A and `apply(D_b, debit)` on B.
	3. `commit()` both profiles: the debits are durable.
	4. CAS the record `pending -> committed`. Only now can items move to the other side.
	5. Settle each side: `apply(C, credit with the other side's items)` directly when the profile is active on this server
	   (then `commit()`), else append an inbox command whose id is C (exactly-once through the shared ledger). When the
	   settlement of a side is durable its flag is set in the record (both flags = `completed`).
	On any failure before step 4: CAS `pending -> aborted`, then settle each side with X instead: if D is in that profile's
	ledger, credit its own items back; otherwise apply D as a no-op, which fences a debit that has not happened yet (a later
	`apply(D)` is a duplicate, and the debit step checks X first).

	Crash safety
	* The record moves only `pending -> committed | aborted` (CAS), so C and X are never both issued for one trade; every
	  effect is keyed by an op id stored in the same write as the effect, so retries, replays, Unknown outcomes and the
	  direct/inbox routes collapse to at most one effect per id. A profile's in-memory ledger is either persisted with its
	  effects or lost with them, so X decides from exactly the state that will (or did) persist.
	* `committed` requires both debits durable; a crash before it leaves `pending` (aborted by recovery), after it leaves
	  `committed` (credited by recovery). Recovery: when a profile of the store is activated, every D id in its ledger without
	  the matching C or X is a trade that still owes this profile something; it is driven from the record (a `pending` trade
	  is aborted: the profile was re-acquired, so the initiator can no longer confirm this side's debit and its CAS loses).
	  Both sides are settled (idempotent), so each debited profile heals itself on its next load.
	* Requirement: ledger retention (`StoreConfig.ledger`) must exceed the longest trade lifetime plus recovery delay (the
	  time until a debited player loads again), or a D/C/X id can be pruned and a step re-applied or skipped. Escrow records
	  are never deleted by the library (a missing record is never guessed at: it is logged and left alone).

	Requirements on the caller: create the escrow at startup on every server (it registers the inbox handler and the
	recovery hook). `validate`, `debit` and `credit` must be pure functions of their arguments, must not yield, and `debit`/
	`credit` must not throw for a side `validate` accepted (credit must always accept; an inventory limit is the game's
	business). Items must be storable in a DataStore.
]]

local Commands = require(script.Parent.Commands)
local Errors = require(script.Parent.Errors)
local Internal = require(script.Parent.Internal)
local Profile = require(script.Parent.Profile)
local Scheduler = require(script.Parent.Scheduler)
local Store = require(script.Parent.Store)
local Types = require(script.Parent.Types)
local Util = require(script.Parent.Util)
local Validate = require(script.Parent.Validate)

type StoreImpl = Internal.StoreImpl
type ProfileImpl = Internal.ProfileImpl
type RetrieverError = Types.RetrieverError

local Escrow = {}

local VERSION = 1
local MAX_NAME = 30 -- the inbox kind `retriever.escrow:<name>` must fit in 50 characters
local MAX_ID = 50 -- trade ids are DataStore keys
local TIMEOUT = 30
local LIFETIME = 300
local PRIO_TRADE = 2
local PRIO_RECOVER = 4

--- `"rejected"`: validation failed, nothing changed. `"failed"`: the trade could not start, nothing was debited.
--- `"pending"`: debits may exist, no decision yet (recovery or `resume` decides). `"committed"`: the trade happened, credits
--- are in flight. `"completed"`: both credits are durable. `"aborted"`: refunds are in flight. `"refunded"`: both sides are
--- settled after an abort. `"missing"`: no escrow record with this id.
export type TradeStatus = "rejected" | "failed" | "pending" | "committed" | "completed" | "aborted" | "refunded" | "missing"

export type TradeResult = {
	--- True when the trade happened (`committed` or `completed`).
	ok: boolean,
	id: string,
	status: TradeStatus,
	--- Why validation rejected or aborted the trade.
	reason: string?,
	error: RetrieverError?,
}

export type TradeOptions = {
	--- Trade id (DataStore key of the escrow record, at most 50 characters). Reuse it to retry the same trade. Default: a guid.
	id: string?,
	--- Seconds each step may take (record writes, commits). Default 30.
	timeout: number?,
}

export type Options<T, G> = {
	--- Distinguishes escrows on one store: letters, digits and `_`, at most 30 characters.
	name: string,
	--- True when `data` can give `give` now (pure, no yield). The second value explains a refusal.
	validate: (data: T, give: G) -> (boolean, string?),
	--- Removes `give` from `data`. Only called right after `validate` accepted it.
	debit: (data: T, give: G) -> (),
	--- Adds `receive` to `data` (the other side's items, or this side's own items on a refund). Must not fail.
	credit: (data: T, receive: G) -> (),
	--- DataStore holding the escrow records. Default `<store name>.escrow.<name>`.
	dataStore: string?,
	--- `resume` aborts a pending trade only when it is older than this many seconds. Default 300.
	lifetime: number?,
}

export type Escrow<T, G> = {
	name: string,
	--- Trades `giveA` from `a` against `giveB` from `b`. Both profiles must be active on this server. Yields.
	trade: (self: Escrow<T, G>, a: Types.Profile<T>, giveA: G, b: Types.Profile<T>, giveB: G, options: TradeOptions?) -> TradeResult,
	--- Reads the escrow record (no side effects). Yields.
	status: (self: Escrow<T, G>, id: string) -> TradeResult,
	--- Drives a trade forward: settles a decided trade, aborts a pending one older than `lifetime`. Yields.
	resume: (self: Escrow<T, G>, id: string) -> TradeResult,
	--- Starts recovery for `profile` now (also runs automatically on every activation). Returns how many trades it found.
	recover: (self: Escrow<T, G>, profile: Types.Profile<T>) -> number,
}

type Side = { k: string, g: any }
--- The stored escrow record. `s`: "p" pending, "c" committed, "x" aborted. `f`: sides whose settlement is durable.
type Rec = { v: number, n: string, s: string, t: number, u: number?, a: Side, b: Side, f: { [string]: boolean }? }

type State = {
	impl: StoreImpl,
	name: string,
	kind: string,
	prefix: string,
	backend: Types.Backend,
	validate: (data: any, give: any) -> (boolean, string?),
	debit: (data: any, give: any) -> (),
	credit: (data: any, receive: any) -> (),
	lifetime: number,
	running: { [string]: boolean },
}

type Ctx = {
	mode: "create" | "commit" | "abort" | "flag" | "read",
	new: Rec?,
	minAge: number,
	flags: { [string]: boolean }?,
	now: () -> number,
	rec: Rec?,
	corrupt: boolean,
}

local installed: { [StoreImpl]: { [string]: boolean } } = setmetatable({}, { __mode = "k" }) :: any

local function other(side: string): string
	return if side == "a" then "b" else "a"
end

local function opId(st: State, id: string, step: string, side: string): string
	return `{st.prefix}{id}:{step}{side}`
end

local function isRec(value: any): boolean
	return type(value) == "table" and value.v == VERSION and type(value.s) == "string" and type(value.a) == "table" and type(value.b) == "table"
end

--- The UpdateAsync transform for the escrow record. Pure apart from `ctx`; replay-safe because every transition is monotone
--- (`pending -> committed | aborted`, flags only added): a retry after an Unknown outcome sees its own effect and succeeds.
local function transform(ctx: Ctx, old: any): any
	ctx.rec = nil
	ctx.corrupt = false
	if old == nil then
		if ctx.mode == "create" then
			ctx.rec = ctx.new
			return Util.deepCopy(ctx.new)
		end
		return nil
	end
	if not isRec(old) then
		ctx.corrupt = true
		return nil
	end
	local rec = old :: Rec
	ctx.rec = rec
	local mode = ctx.mode
	if mode == "commit" and rec.s == "p" then
		rec.s = "c"
		rec.u = ctx.now()
		return rec
	elseif mode == "abort" and rec.s == "p" and ctx.now() - rec.t >= ctx.minAge then
		rec.s = "x"
		rec.u = ctx.now()
		return rec
	elseif mode == "flag" and rec.s ~= "p" then
		local flags = rec.f or {}
		local changed = false
		for side in ctx.flags :: { [string]: boolean } do
			if not flags[side] then
				flags[side] = true
				changed = true
			end
		end
		if changed then
			rec.f = flags
			return rec
		end
	end
	return nil
end

--- One escrow-record request with retries. Returns the record as the last transform saw it (nil: missing) or an error.
local function request(st: State, id: string, ctx: Ctx, prio: number, deadline: number, sleeper: Scheduler.Timer): (Rec?, RetrieverError?)
	local impl = st.impl
	local backend = st.backend
	local function fn(old: any, _info: Types.KeyInfoLike?): (any, { number }?, { [string]: any }?)
		return transform(ctx, old), nil, nil
	end
	local problem = Commands.retrying(impl, id, "update", prio, function()
		return backend.update(id, fn)
	end, function()
		return ctx.mode ~= "read"
	end, deadline, sleeper, nil)
	if problem ~= nil then
		return nil, problem
	end
	if ctx.corrupt then
		return nil, Errors.new("Corrupt", impl.name, id, nil, { what = "The escrow record is not in the expected format." })
	end
	return ctx.rec, nil
end

local function newCtx(st: State, mode: "create" | "commit" | "abort" | "flag" | "read"): Ctx
	return { mode = mode, new = nil, minAge = 0, flags = nil, now = st.impl.runtime.env.time, rec = nil, corrupt = false }
end

local function log(st: State, message: string)
	st.impl.runtime.env.log("error", `[Retriever] escrow "{st.name}" (store "{st.impl.name}"): {message}`)
end

--- The effect of a settlement (C or X) on one profile. Runs inside `apply(C or X)`, directly or from the inbox handler.
local function effect(st: State, profile: ProfileImpl, payload: any)
	local data = profile.data
	if payload.a == "c" then
		st.credit(data, payload.g)
	elseif payload.a == "x" then
		local ext = profile.ext
		local ops = if ext ~= nil then ext.ops else nil
		local debit = opId(st, payload.t, "d", payload.s)
		if ops ~= nil and ops[debit] ~= nil then
			st.credit(data, payload.g) -- refund
		else
			Profile.apply(profile, debit, function(_data: any) end) -- fence: a later debit of this trade is a duplicate
		end
	end
end

--- Makes the settlement of `side` durable: direct apply + commit when the profile is active here, else an inbox command
--- with the same op id (accepted by the target = durable; its owner applies it exactly once).
local function settleSide(st: State, id: string, rec: Rec, side: string, deadline: number, sleeper: Scheduler.Timer): (boolean, RetrieverError?)
	local impl = st.impl
	local env = impl.runtime.env
	local committed = rec.s == "c"
	local step = if committed then "c" else "x"
	local own = (rec :: any)[side] :: Side
	local items = if committed then ((rec :: any)[other(side)] :: Side).g else own.g
	local payload = { t = id, s = side, a = step, g = Util.deepCopy(items) }
	local op = opId(st, id, step, side)
	local profile = impl.profiles[own.k]
	if profile ~= nil and profile.state == "active" then
		local ok, problem = pcall(Profile.apply, profile, op, function(_data: any)
			effect(st, profile, payload)
		end)
		if not ok then
			log(st, `settling trade "{id}" on "{own.k}" raised: {tostring(problem)}; retried when the profile loads again`)
			return false, Errors.new("InvalidData", impl.name, own.k, tostring(problem))
		end
		local remaining = math.max(1, deadline - env.clock())
		local result = Profile.commit(profile, { timeout = remaining }) :: any
		return result.ok == true, result.error
	end
	local entry: Types.InboxEntry = { i = op, t = env.time(), k = st.kind, p = payload }
	local sent = Commands.append(impl, own.k, entry, true, PRIO_TRADE, deadline, sleeper, nil) :: any
	return sent.ok == true, sent.error
end

local function statusOf(rec: Rec?): TradeStatus
	if rec == nil then
		return "missing"
	end
	local flags = rec.f
	local both = flags ~= nil and flags.a == true and flags.b == true
	if rec.s == "c" then
		return if both then "completed" else "committed"
	elseif rec.s == "x" then
		return if both then "refunded" else "aborted"
	end
	return "pending"
end

local function result(id: string, status: TradeStatus, reason: string?, problem: RetrieverError?): TradeResult
	return { ok = status == "committed" or status == "completed", id = id, status = status, reason = reason, error = problem }
end

--- Settles every unflagged side of a decided trade and records which settlements are durable.
local function settleAll(st: State, id: string, rec: Rec, deadline: number, sleeper: Scheduler.Timer, reason: string?): TradeResult
	if rec.s == "p" then
		return result(id, "pending", reason)
	end
	local flags = rec.f or {}
	local done: { [string]: boolean } = {}
	local any = false
	local firstError: RetrieverError? = nil
	for _, side in { "a", "b" } do
		if not flags[side] then
			local durable, problem = settleSide(st, id, rec, side, deadline, sleeper)
			if durable then
				done[side] = true
				any = true
			elseif firstError == nil then
				firstError = problem
			end
		end
	end
	if not any then
		return result(id, statusOf(rec), reason, firstError)
	end
	local ctx = newCtx(st, "flag")
	ctx.flags = done
	local updated, problem = request(st, id, ctx, PRIO_TRADE, deadline, sleeper)
	return result(id, statusOf(updated or rec), reason, firstError or problem)
end

--- Aborts the trade if it is still pending (and at least `minAge` seconds old), then settles whatever was decided.
local function drive(st: State, id: string, minAge: number, prio: number, timeout: number, reason: string?): TradeResult
	local runtime = st.impl.runtime
	local deadline = runtime.env.clock() + timeout
	local sleeper = Scheduler.newSleeper(runtime.scheduler)
	local ctx = newCtx(st, "abort")
	ctx.minAge = minAge
	local rec, problem = request(st, id, ctx, prio, deadline, sleeper)
	if problem ~= nil then
		return result(id, "pending", reason, problem)
	end
	if rec == nil then
		return result(id, "missing", reason)
	end
	return settleAll(st, id, rec, deadline, sleeper, reason)
end

------------------------------------------------------------------------------------------------------------------------
-- recovery
------------------------------------------------------------------------------------------------------------------------

--- Trade ids whose debit of this profile is in its ledger without the matching credit or abort settlement.
local function unsettled(st: State, profile: ProfileImpl): { string }
	local found: { string } = {}
	local ext = profile.ext
	local ops = if ext ~= nil then ext.ops else nil
	if ops == nil then
		return found
	end
	local prefix = st.prefix
	local n = #prefix
	for op in ops do
		if string.sub(op, 1, n) == prefix and #op > n + 3 then
			local tail = string.sub(op, -3)
			if tail == ":da" or tail == ":db" then
				local side = string.sub(tail, 3, 3)
				local id = string.sub(op, n + 1, -4)
				if ops[opId(st, id, "c", side)] == nil and ops[opId(st, id, "x", side)] == nil then
					found[#found + 1] = id
				end
			end
		end
	end
	return found
end

local function recover(st: State, profile: ProfileImpl): number
	local ids = unsettled(st, profile)
	local count = 0
	local runtime = st.impl.runtime
	for _, id in ids do
		if not st.running[id] then
			count += 1
			st.running[id] = true
			runtime.env.defer(function()
				-- the profile was (re)acquired here, so whoever started the trade can no longer confirm its debit: abort pending
				local ok, outcome = pcall(drive, st, id, 0, PRIO_RECOVER, TIMEOUT, nil)
				st.running[id] = nil
				if not ok then
					log(st, `recovering trade "{id}" raised: {tostring(outcome)}`)
				elseif outcome.status == "missing" then
					log(st, `trade "{id}" debited "{profile.key}" but its escrow record is missing; left for an operator`)
				elseif outcome.error ~= nil then
					log(st, `recovering trade "{id}" is incomplete ({outcome.status}): {Errors.format(outcome.error)}; retried on the next load`)
				end
			end)
		end
	end
	return count
end

------------------------------------------------------------------------------------------------------------------------
-- trading
------------------------------------------------------------------------------------------------------------------------

local function checkProfile(st: State, value: any, what: string): ProfileImpl
	if getmetatable(value) ~= Profile or (value :: ProfileImpl).impl ~= st.impl then
		error(`[Retriever] escrow:trade: {what} must be a profile of store "{st.impl.name}"`, 4)
	end
	return value :: ProfileImpl
end

local function trade(st: State, a: ProfileImpl, giveA: any, b: ProfileImpl, giveB: any, options: TradeOptions?): TradeResult
	local impl = st.impl
	local runtime = impl.runtime
	local env = runtime.env
	if a.key == b.key then
		error("[Retriever] escrow:trade needs two different profiles", 3)
	end
	local id = if options ~= nil and options.id ~= nil then options.id else env.guid()
	if type(id) ~= "string" or id == "" or #id > MAX_ID then
		error(`[Retriever] escrow:trade: options.id must be a non-empty string of at most {MAX_ID} characters`, 3)
	end
	local timeout = if options ~= nil and options.timeout ~= nil then options.timeout else TIMEOUT
	for _, give in { giveA, giveB } do
		local storable, why = Validate.storable(give)
		if not storable then
			error(`[Retriever] escrow:trade: the items cannot be stored in a DataStore: {why}`, 3)
		end
	end
	if runtime.closing then
		return result(id, "failed", nil, Errors.new("ShuttingDown", impl.name, a.key))
	end
	if a.state ~= "active" or b.state ~= "active" then
		local which = if a.state ~= "active" then a else b
		return result(id, "failed", nil, Errors.new("Closed", impl.name, which.key))
	end
	-- a side already debited by this trade (a retry with the same id) is not validated again
	local function debited(profile: ProfileImpl, side: string): boolean
		local ext = profile.ext
		local ops = if ext ~= nil then ext.ops else nil
		return ops ~= nil and ops[opId(st, id, "d", side)] ~= nil
	end
	local function refusal(): string?
		for _, side in { "a", "b" } do
			local profile = if side == "a" then a else b
			if not debited(profile, side) then
				local ok, why = st.validate(profile.data, if side == "a" then giveA else giveB)
				if not ok then
					return `{side}: {why or "refused"}`
				end
			end
		end
		return nil
	end
	local refused = refusal()
	if refused ~= nil then
		return result(id, "rejected", refused)
	end

	-- 1. the escrow record (nothing is debited unless it is confirmed)
	local deadline = env.clock() + timeout
	local sleeper = Scheduler.newSleeper(runtime.scheduler)
	local ctx = newCtx(st, "create")
	local now = env.time()
	ctx.new = { v = VERSION, n = st.name, s = "p", t = now, a = { k = a.key, g = Util.deepCopy(giveA) }, b = { k = b.key, g = Util.deepCopy(giveB) } }
	local rec, problem = request(st, id, ctx, PRIO_TRADE, deadline, sleeper)
	if problem ~= nil or rec == nil then
		return result(id, "failed", nil, problem or Errors.new("Unavailable", impl.name, id))
	end
	if rec.a.k ~= a.key or rec.b.k ~= b.key or not Util.deepEqual(rec.a.g, giveA) or not Util.deepEqual(rec.b.g, giveB) then
		return result(id, "failed", nil, Errors.new("Conflict", impl.name, id, nil, { what = "The trade id is already used by a different trade." }))
	end
	if rec.s ~= "p" then
		return settleAll(st, id, rec, deadline, sleeper, nil) -- a retry of a decided trade
	end

	-- 2. both debits in one synchronous step (validation still holds: nothing yields in between)
	local reason: string? = nil
	local xa, xb = opId(st, id, "x", "a"), opId(st, id, "x", "b")
	local opsA = Profile.ensureExt(a).ops
	local opsB = Profile.ensureExt(b).ops
	if a.state ~= "active" or b.state ~= "active" then
		reason = "a profile closed while the escrow record was written"
	elseif (opsA ~= nil and opsA[xa] ~= nil) or (opsB ~= nil and opsB[xb] ~= nil) then
		reason = "the trade was already aborted"
	else
		reason = refusal()
		if reason == nil then
			local function debit(profile: ProfileImpl, give: any, side: string): boolean
				local ok, raised = pcall(Profile.apply, profile, opId(st, id, "d", side), function(data: any)
					st.debit(data, give)
				end)
				if not ok then
					reason = `debit of {side} raised: {tostring(raised)}`
					log(st, `trade "{id}": {reason}`)
				end
				return ok
			end
			local _ = debit(a, giveA, "a") and debit(b, giveB, "b")
		end
	end

	-- 3. both debits durable
	if reason == nil then
		for _, profile in { a, b } do
			local saved = Profile.commit(profile, { timeout = math.max(1, deadline - env.clock()) }) :: any
			if not saved.ok then
				reason = `the debit of "{profile.key}" was not confirmed`
				problem = saved.error
				break
			end
		end
	end

	-- 4. the decision; 5. settlement
	local decision = newCtx(st, if reason == nil then "commit" else "abort")
	deadline = env.clock() + timeout
	local decided, decideProblem = request(st, id, decision, PRIO_TRADE, deadline, sleeper)
	if decideProblem ~= nil or decided == nil then
		-- undecided: still pending. Recovery (next load of a debited profile) or `resume` finishes it.
		return result(id, "pending", reason, decideProblem or problem)
	end
	local outcome = settleAll(st, id, decided, deadline, sleeper, reason)
	if outcome.error == nil then
		outcome.error = problem
	end
	return outcome
end

------------------------------------------------------------------------------------------------------------------------
-- construction
------------------------------------------------------------------------------------------------------------------------

--- `Retriever.escrow(store, options)`: registers the escrow `options.name` on `store` (inbox handler and recovery hook) and
--- returns its handle. Call once per store and name, at startup, on every server.
function Escrow.new<T, G>(store: any, options: Options<T, G>): Escrow<T, G>
	if getmetatable(store) ~= Store then
		error(`[Retriever] Retriever.escrow needs a store created with Retriever.store or runtime:store, got {typeof(store)}`, 2)
	end
	local impl = store :: StoreImpl
	if type(options) ~= "table" then
		error("[Retriever] Retriever.escrow(store, options) needs options { name, validate, debit, credit }", 2)
	end
	local name = options.name
	if type(name) ~= "string" or name == "" or #name > MAX_NAME or string.find(name, "[^%w_]") ~= nil then
		error(`[Retriever] Retriever.escrow: options.name must be 1-{MAX_NAME} letters, digits or underscores`, 2)
	end
	for _, field in { "validate", "debit", "credit" } do
		if type((options :: any)[field]) ~= "function" then
			error(`[Retriever] Retriever.escrow: options.{field} must be a function`, 2)
		end
	end
	local dataStore = options.dataStore or `{impl.name}.escrow.{name}`
	if #dataStore > 50 then
		error(`[Retriever] Retriever.escrow: the DataStore name "{dataStore}" is longer than 50 characters; pass options.dataStore`, 2)
	end
	local names = installed[impl]
	if names == nil then
		names = {}
		installed[impl] = names
	end
	if (names :: { [string]: boolean })[name] then
		error(`[Retriever] Retriever.escrow: an escrow named "{name}" already exists on store "{impl.name}"`, 2)
	end
	(names :: { [string]: boolean })[name] = true

	local st: State = {
		impl = impl,
		name = name,
		kind = `retriever.escrow:{name}`,
		prefix = `~e:{name}/`,
		backend = impl.runtime.env.provider.open(dataStore, impl.scope),
		validate = options.validate :: any,
		debit = options.debit :: any,
		credit = options.credit :: any,
		lifetime = options.lifetime or LIFETIME,
		running = {},
	}

	-- inbox route for settlements of profiles owned elsewhere (called inside `apply(command id)`, which is the C or X id)
	local handlers = impl.commandHandlers
	if handlers == nil then
		handlers = {}
		impl.commandHandlers = handlers
	end
	(handlers :: { [string]: (profile: any, payload: any, id: string) -> () })[st.kind] = function(profile: any, payload: any, _id: string)
		if type(payload) ~= "table" or type(payload.t) ~= "string" or (payload.s ~= "a" and payload.s ~= "b") then
			error(`malformed escrow command`)
		end
		effect(st, profile :: ProfileImpl, payload)
	end

	-- recovery on activation, chained after the hooks already installed (inbox consumption runs first)
	local previous = impl.hooks
	local previousActivate = if previous ~= nil then previous.afterActivate else nil
	impl.hooks = {
		afterActivate = function(profile: ProfileImpl, rec: Types.Record)
			if previousActivate ~= nil then
				previousActivate(profile, rec)
			end
			if profile.state == "active" and not impl.runtime.closing then
				recover(st, profile)
			end
		end,
		afterWrite = if previous ~= nil then previous.afterWrite else nil,
		afterEnd = if previous ~= nil then previous.afterEnd else nil,
	}
	-- sessions already loaded may owe settlements
	for _, profile in impl.profiles do
		if profile.state == "active" then
			recover(st, profile)
		end
	end

	local handle = {
		name = name,
		trade = function(_self: any, a: any, giveA: any, b: any, giveB: any, tradeOptions: TradeOptions?): TradeResult
			return trade(st, checkProfile(st, a, "a"), giveA, checkProfile(st, b, "b"), giveB, tradeOptions)
		end,
		status = function(_self: any, id: string): TradeResult
			local runtime = impl.runtime
			local rec, problem = request(st, id, newCtx(st, "read"), PRIO_TRADE, runtime.env.clock() + TIMEOUT, Scheduler.newSleeper(runtime.scheduler))
			if problem ~= nil then
				return result(id, "pending", nil, problem)
			end
			return result(id, statusOf(rec))
		end,
		resume = function(_self: any, id: string): TradeResult
			return drive(st, id, st.lifetime, PRIO_TRADE, TIMEOUT, nil)
		end,
		recover = function(_self: any, profile: any): number
			local p = checkProfile(st, profile, "profile")
			return if p.state == "active" then recover(st, p) else 0
		end,
	}
	return handle :: any
end

return Escrow
