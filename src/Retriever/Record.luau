--!strict
--[[
	The stored record ("envelope") and the pure decision logic that runs inside UpdateAsync callbacks.

	Why this is a separate module: callbacks are the only place where ownership can be checked atomically with a write, they
	may be invoked several times for one request, and they must not yield or touch anything outside their inputs. Keeping the
	logic pure (inputs: stored value + a small context table; outputs: new value + outcome written into the context) makes
	it unit-testable without any DataStore and makes replay safety visible: every invocation starts from `outcome = nil`.

	Replay tolerance: every mutation made to `old` is either an idempotent assignment or a monotonic counter increment, so a
	callback re-run on the same table object or on a fresh copy produces an equivalent record.

	Fencing: `e` (epoch) is bumped by every successful acquire and never reset. A session writes only while `old.e` still
	equals the epoch it was issued, so a session that was superseded (stolen, expired) is rejected inside the same atomic
	read-modify-write that would have applied its data.
]]

local Types = require(script.Parent.Types)
local Util = require(script.Parent.Util)

type Record = Types.Record
type KeyInfoLike = Types.KeyInfoLike

local Record = {}

--- Envelope format version this build understands.
Record.VERSION = 1
--- Clock skew allowance (seconds) before treating another server's lease as expired.
Record.SKEW = 10

------------------------------------------------------------------------------------------------------------------------
-- Acquire
------------------------------------------------------------------------------------------------------------------------

export type AcquireOutcome =
	"acquired" -- we now own the record (also set when it was created)
	| "locked" -- another live session owns it; nothing was written
	| "marked" -- another live session owns it; a handoff request was written
	| "missing" -- no record and `create` is false; nothing was written
	| "corrupt" -- not a record; nothing was written
	| "envelopeTooNew"
	| "schemaTooNew"
	| "cancelled"

export type AcquireCtx = {
	-- inputs
	jobId: string,
	placeId: number,
	now: () -> number,
	lease: number,
	skew: number,
	schemaVersion: number, -- schema version of the running code
	create: boolean,
	userIds: { number }?, -- associated on creation only
	steal: boolean, -- take over a live-looking owner
	requestHandoff: boolean, -- ask the owner to release (writes a marker on first contact)
	isCancelled: (() -> boolean)?,
	-- outputs (reset at the start of every invocation)
	runs: number,
	outcome: AcquireOutcome?,
	created: boolean,
	epoch: number,
	rev: number,
	leaseExpiry: number,
	ownerJob: string?,
	ownerExpiry: number?,
	tookOver: string?, -- why a previous owner was displaced: "expired" | "stolen" | "released" | "same"
	recordSchema: number?,
	recordMinReader: number?,
}

function Record.newAcquireCtx(
	jobId: string,
	placeId: number,
	now: () -> number,
	lease: number,
	schemaVersion: number
): AcquireCtx
	return {
		jobId = jobId,
		placeId = placeId,
		now = now,
		lease = lease,
		skew = Record.SKEW,
		schemaVersion = schemaVersion,
		create = true,
		steal = false,
		requestHandoff = false,
		runs = 0,
		outcome = nil,
		created = false,
		epoch = 0,
		rev = 0,
		leaseExpiry = 0,
	}
end

--- True when `value` looks like a record this build can read structurally (not necessarily load).
function Record.isEnvelope(value: any): boolean
	if type(value) ~= "table" then
		return false
	end
	local v = value :: any
	return type(v.v) == "number" and type(v.r) == "number" and type(v.e) == "number"
end

--- Non-binding look at a record for lock polling. A waiting load reads with `GetAsync(UseCache = false)` (one read unit)
--- and only attempts the atomic acquire (a read AND a write unit) when this says the lock may be free. Never used for safety:
--- the acquire callback re-decides atomically.
function Record.lockedByOther(value: any, jobId: string, now: number, skew: number, steal: boolean): boolean
	if not Record.isEnvelope(value) then
		return false -- missing or corrupt: let the acquire report it precisely
	end
	local lock = (value :: Record).l
	if lock == nil or lock.j == jobId or steal then
		return false
	end
	return now < lock.x + skew
end

local function passThroughMeta(info: KeyInfoLike?): ({ number }?, { [string]: any }?)
	if info == nil then
		return nil, nil
	end
	return info:GetUserIds(), info:GetMetadata()
end

--- UpdateAsync transform for starting a session. Returns the engine contract `(newValue, userIds, metadata)`;
--- returning nil writes nothing. The outcome is reported through `ctx`.
function Record.acquire(old: any, info: KeyInfoLike?, ctx: AcquireCtx): (any, { number }?, { [string]: any }?)
	ctx.runs += 1
	ctx.outcome = nil
	ctx.created = false
	ctx.ownerJob = nil
	ctx.ownerExpiry = nil
	ctx.tookOver = nil

	local isCancelled = ctx.isCancelled
	if isCancelled ~= nil and isCancelled() then
		ctx.outcome = "cancelled"
		return nil
	end

	local now = ctx.now()
	local lock: Types.Lock = { j = ctx.jobId, p = ctx.placeId, x = now + ctx.lease }

	if old == nil then
		if not ctx.create then
			ctx.outcome = "missing"
			return nil
		end
		local fresh: Record = {
			v = Record.VERSION,
			sv = ctx.schemaVersion,
			r = 1,
			e = 1,
			c = now,
			l = lock,
		}
		ctx.outcome = "acquired"
		ctx.created = true
		ctx.epoch = 1
		ctx.rev = 1
		ctx.leaseExpiry = lock.x
		return fresh, ctx.userIds, nil
	end

	if not Record.isEnvelope(old) then
		ctx.outcome = "corrupt"
		return nil
	end
	local rec = old :: Record

	if rec.v > Record.VERSION then
		ctx.outcome = "envelopeTooNew"
		return nil
	end
	local minReader = rec.mr
	if minReader ~= nil and minReader > ctx.schemaVersion then
		ctx.outcome = "schemaTooNew"
		ctx.recordSchema = rec.sv
		ctx.recordMinReader = minReader
		return nil
	end

	-- A stub (created by an inbox send before the key was ever loaded) has no data and was never owned: it counts as missing
	-- for `create = false`, and the first load associates its user ids like a creation would.
	local stub = rec.e == 0 and rec.d == nil
	if stub and not ctx.create then
		ctx.outcome = "missing"
		return nil
	end

	local current = rec.l
	local tookOver: string? = nil
	if current ~= nil then
		if current.j == ctx.jobId then
			tookOver = "same"
		elseif now >= current.x + ctx.skew then
			tookOver = "expired"
		elseif ctx.steal then
			tookOver = "stolen"
		else
			ctx.ownerJob = current.j
			ctx.ownerExpiry = current.x
			if ctx.requestHandoff and current.q ~= ctx.jobId then
				-- First contact: leave a marker the owner sees on its next write or wake-up, then keep waiting.
				current.q = ctx.jobId
				rec.r += 1
				ctx.outcome = "marked"
				ctx.rev = rec.r
				return rec, passThroughMeta(info)
			end
			ctx.outcome = "locked"
			return nil
		end
	else
		tookOver = "released"
	end

	rec.e += 1
	rec.r += 1
	rec.l = lock
	ctx.outcome = "acquired"
	ctx.epoch = rec.e
	ctx.rev = rec.r
	ctx.leaseExpiry = lock.x
	ctx.tookOver = tookOver
	ctx.recordSchema = rec.sv
	ctx.recordMinReader = rec.mr
	ctx.created = stub
	if stub then
		local _, meta = passThroughMeta(info)
		return rec, ctx.userIds, meta
	end
	return rec, passThroughMeta(info)
end

------------------------------------------------------------------------------------------------------------------------
-- Owner writes: save, heartbeat, close and release all go through `Record.write`
------------------------------------------------------------------------------------------------------------------------

export type WriteOutcome =
	"wrote" -- the record was updated
	| "lost" -- epoch/owner mismatch: this session was superseded; nothing was written
	| "missing" -- the record was deleted; nothing was written
	| "corrupt" -- the stored value is no longer a record; nothing was written
	| "invalid" -- validation failed; nothing was written
	| "schemaTooNew" -- the record's minimum reader is above this server's schema version; nothing was written

--- Per-store settings the write callback reads. Shared by every session of the store, so a session holds one pointer.
export type WritePolicy = {
	jobId: string,
	lease: number,
	now: () -> number,
	schemaVersion: number,
	--- Called inside the callback when set (debug mode). Must be pure and fast.
	validate: ((data: any) -> (boolean, string?))?,
	--- `snapshot = "copy"`: hand UpdateAsync deep copies taken at callback time instead of the live tables.
	copy: boolean?,
	--- Store `codec` option (Retriever.codec): `d` is written as `codec.encode(data)` with the codec id and version.
	codec: Types.Codec?,
}

--- Rarely used per-session state. Allocated on first use, so sessions that never touch these features pay nothing.
export type Ext = {
	ops: { [string]: number }?, -- idempotency ledger: op id -> time applied
	opsCount: number,
	opsHorizon: number?,
	outbox: { Types.OutboxEntry }?,
	consumed: { [string]: number }?, -- inbox entry id -> consumption sequence
	consumedSeq: number,
	ended: { (reason: Types.EndReason, err: Types.RetrieverError?) -> () }?,
	--- outbox id -> `editSeq` when it was enqueued in this session (in memory only). An entry is delivered only once a write
	--- containing it is confirmed (`savedSeq >= seq`); entries loaded from the record are already persisted.
	outboxSeq: { [string]: number }?,
	--- Per-session state owned by Commands.luau (outbox courier, failed handlers). Opaque here to avoid a module cycle.
	cmd: any?,
}

--- The fields of a session that `Record.write` reads and writes. `Profile` implements this shape directly, so a save
--- allocates nothing: the callback is created once per profile and reads the live fields at call time.
export type WriteSubject = {
	policy: WritePolicy,
	epoch: number,
	closing: boolean, -- true: release the lock in this write
	-- payload. `skipData` (or nil data) leaves the stored `d` untouched: used to release a lock without writing, for
	-- example after a failed migration or when the data cannot be serialized.
	data: any,
	skipData: boolean,
	userIds: { number }?,
	meta: { [string]: any }?,
	minReader: number?,
	editSeq: number,
	ext: Ext?,
	-- outputs, reset on every invocation
	cbRuns: number,
	cbOutcome: WriteOutcome?,
	cbSeq: number, -- editSeq captured by the invocation that produced the final value
	cbConsumedSeq: number,
	cbError: string?,
	cbRev: number,
	cbReleaseRequested: string?, -- job id that asked for a handoff
}

--- UpdateAsync transform for every write made by the owning session. Atomic with the fencing check.
function Record.write(old: any, _info: KeyInfoLike?, s: WriteSubject): (any, { number }?, { [string]: any }?)
	s.cbRuns += 1
	s.cbOutcome = nil
	s.cbError = nil
	s.cbReleaseRequested = nil
	s.cbConsumedSeq = 0

	if old == nil then
		s.cbOutcome = "missing"
		return nil
	end
	if not Record.isEnvelope(old) then
		s.cbOutcome = "corrupt"
		return nil
	end
	local rec = old :: Record
	local lock = rec.l
	local policy = s.policy
	-- Our epoch with no lock can only be our own release: every acquire bumps `e`. That happens when a closing callback is
	-- replayed on the table it already changed or on the committed value (an engine retry of an applied write); treating it
	-- as lost would end a cleanly released session with OwnershipLost. Re-running the release on it is safe.
	local released = s.closing and lock == nil and rec.e == s.epoch
	if not released and (rec.e ~= s.epoch or lock == nil or lock.j ~= policy.jobId) then
		s.cbOutcome = "lost"
		return nil
	end
	local data = s.data
	if s.skipData then
		data = nil
	end
	local recordMinReader = rec.mr
	if data ~= nil and recordMinReader ~= nil and recordMinReader > policy.schemaVersion then
		-- Defence in depth for mixed-version safety: data a newer schema produced is never overwritten by older code, even if
		-- something outside the session protocol raised `mr` while we held the lock. A write that leaves `d` untouched (a
		-- release after the data became unwritable) is still allowed: it only frees the lock for the newer server.
		s.cbOutcome = "schemaTooNew"
		return nil
	end
	local validate = policy.validate
	if validate ~= nil and data ~= nil then
		local ok, message = validate(data)
		if not ok then
			s.cbOutcome = "invalid"
			s.cbError = message
			return nil
		end
	end

	local copy = policy.copy == true
	local codec = policy.codec
	local stored = data
	if codec ~= nil and data ~= nil then
		-- Encoded before anything in `rec` changes, so a refused encode writes nothing. The encoder is pure: a replay
		-- re-encodes the same live data.
		local ok, encoded = pcall(codec.encode, data)
		if not ok or encoded == nil then
			s.cbOutcome = "invalid"
			s.cbError = `codec "{codec.id}" failed to encode the data: {if ok then "it returned nil" else tostring(encoded)}`
			return nil
		end
		stored = encoded
	end
	if data ~= nil then
		-- The schema version and minimum reader describe `d`, so they only move when `d` is written. When the stored `d` is
		-- absent (a stub or a brand-new record), our data was created in this server's shape and the fields describe it
		-- entirely; otherwise they only ever move forward (a server may save data from a newer, compatible version).
		local fresh = rec.d == nil
		rec.d = if copy then Util.deepCopy(stored) else stored
		-- The codec marker describes `d` too (cleared when the store no longer encodes).
		if codec ~= nil then
			rec.cd = codec.id
			rec.cv = codec.version
		elseif rec.cd ~= nil then
			rec.cd = nil
			rec.cv = nil
		end
		local sv = rec.sv
		if fresh or sv == nil or sv < policy.schemaVersion then
			rec.sv = policy.schemaVersion
		end
		local minReader = s.minReader
		if fresh then
			rec.mr = minReader
		elseif minReader ~= nil then
			local mr = rec.mr
			if mr == nil or mr < minReader then
				rec.mr = minReader
			end
		end
	end

	if lock ~= nil then
		if lock.q ~= nil then
			s.cbReleaseRequested = lock.q
		end
		if s.closing then
			rec.l = nil
		else
			lock.x = policy.now() + policy.lease
		end
	end

	-- Everything below costs nothing unless a session uses ops, the outbox or the inbox.
	-- The ledger, the outbox and inbox consumption describe effects on `d`, so they are written only together with `d`: a
	-- write that leaves `d` untouched (`skipData`, e.g. a close after the data became unwritable) must not record an op id
	-- (or drop a consumed command) whose effect it did not store, or a redelivered purchase would be skipped as a duplicate.
	local ext = if data ~= nil then s.ext else nil
	local inbox = rec.ib
	if ext ~= nil then
		local ops = ext.ops
		if ops ~= nil then
			rec.o = if copy then table.clone(ops) else ops
			rec.oh = ext.opsHorizon
		end
		local outbox = ext.outbox
		if outbox ~= nil then
			rec.ob = if #outbox == 0 then nil elseif copy then Util.deepCopy(outbox) else outbox
		end
		local consumed = ext.consumed
		if consumed ~= nil then
			if inbox ~= nil then
				-- Drop entries this session has consumed. Idempotent, so callback replay is harmless.
				local keep = 0
				local n = #inbox
				for i = 1, n do
					local entry = inbox[i]
					if consumed[entry.i] == nil then
						keep += 1
						inbox[keep] = entry
					end
				end
				for i = keep + 1, n do
					inbox[i] = nil :: any
				end
			end
			s.cbConsumedSeq = ext.consumedSeq
		end
	end
	if inbox ~= nil and #inbox == 0 then
		rec.ib = nil
	end

	rec.r += 1
	s.cbRev = rec.r
	s.cbSeq = s.editSeq
	s.cbOutcome = "wrote"
	if copy then
		local userIds = s.userIds
		local meta = s.meta
		return rec, if userIds ~= nil then table.clone(userIds) else nil, if meta ~= nil then Util.deepCopy(meta) else nil
	end
	return rec, s.userIds, s.meta
end

------------------------------------------------------------------------------------------------------------------------
-- Durable commands: inbox append (any server, no lock) and outbox acknowledgement (after the sender released)
------------------------------------------------------------------------------------------------------------------------

export type AppendOutcome =
	"appended" -- the entry was added (a stub record was created when the key did not exist)
	| "duplicate" -- the id is already in the inbox or the idempotency ledger; nothing was written
	| "full" -- the inbox is at its limit; nothing was written
	| "missing" -- no record and `create` is false; nothing was written
	| "corrupt" -- not a record; nothing was written
	| "envelopeTooNew" -- written by a newer Retriever envelope format; nothing was written

export type AppendCtx = {
	-- inputs
	entry: Types.InboxEntry,
	max: number,
	create: boolean,
	now: () -> number,
	skew: number,
	-- outputs (reset at the start of every invocation)
	runs: number,
	outcome: AppendOutcome?,
	created: boolean,
	rev: number,
	ownerJob: string?, -- job id of a live owner (to wake it), nil when unowned or expired
	--- NOT reset: true once any invocation (of this request or an earlier attempt of the same send) produced a value with the
	--- entry. Finding the id afterwards means our own write landed (a replay on the committed value, or a retry after an
	--- ambiguous error), so the outcome stays `appended` instead of `duplicate`.
	produced: boolean,
}

function Record.newAppendCtx(entry: Types.InboxEntry, max: number, create: boolean, now: () -> number, skew: number): AppendCtx
	return {
		entry = entry,
		max = max,
		create = create,
		now = now,
		skew = skew,
		runs = 0,
		outcome = nil,
		created = false,
		rev = 0,
		ownerJob = nil,
		produced = false,
	}
end

--- UpdateAsync transform that appends a command to a record's inbox without touching its lock, epoch or data, so it is safe
--- against a live owner: the owner's next write keeps every entry it has not consumed. Replay-safe: a replay on the same table
--- object finds `ctx.entry` itself (by identity) and reports `appended` again instead of mistaking it for a duplicate.
function Record.append(old: any, info: KeyInfoLike?, ctx: AppendCtx): (any, { number }?, { [string]: any }?)
	ctx.runs += 1
	ctx.outcome = nil
	ctx.created = false
	ctx.ownerJob = nil
	local entry = ctx.entry
	local now = ctx.now()

	if old == nil then
		if not ctx.create then
			ctx.outcome = "missing"
			return nil
		end
		-- A stub: no data, never owned (`e = 0`). The first load turns it into a profile and consumes the inbox.
		local stub: Record = { v = Record.VERSION, r = 1, e = 0, c = now, ib = { entry } }
		ctx.outcome = "appended"
		ctx.created = true
		ctx.rev = 1
		ctx.produced = true
		return stub, nil, nil
	end
	if not Record.isEnvelope(old) then
		ctx.outcome = "corrupt"
		return nil
	end
	local rec = old :: Record
	if rec.v > Record.VERSION then
		ctx.outcome = "envelopeTooNew"
		return nil
	end

	local lock = rec.l
	if lock ~= nil and now < lock.x + ctx.skew then
		ctx.ownerJob = lock.j
	end

	local id = entry.i
	local inbox = rec.ib
	if inbox ~= nil then
		for i = 1, #inbox do
			local existing = inbox[i]
			if existing == entry then
				-- replayed on the table this callback already changed
				ctx.outcome = "appended"
				ctx.rev = rec.r
				return rec, passThroughMeta(info)
			end
			if existing.i == id then
				ctx.outcome = if ctx.produced then "appended" else "duplicate"
				ctx.rev = rec.r
				return nil
			end
		end
	end
	local ops = rec.o
	if ops ~= nil and ops[id] ~= nil then
		ctx.outcome = if ctx.produced then "appended" else "duplicate"
		ctx.rev = rec.r
		return nil
	end
	if inbox ~= nil and #inbox >= ctx.max then
		ctx.outcome = "full"
		ctx.rev = rec.r
		return nil
	end

	if inbox == nil then
		rec.ib = { entry }
	else
		inbox[#inbox + 1] = entry
	end
	rec.r += 1
	ctx.outcome = "appended"
	ctx.rev = rec.r
	ctx.produced = true
	return rec, passThroughMeta(info)
end

export type AckOutcome =
	"removed" -- at least one delivered entry was removed from the outbox
	| "none" -- none of the ids is in the outbox any more; nothing was written
	| "locked" -- a live session owns the record; it delivers and removes its outbox itself; nothing was written
	| "missing"
	| "corrupt"

export type AckCtx = {
	-- inputs
	ids: { [string]: boolean },
	now: () -> number,
	skew: number,
	-- outputs (reset at the start of every invocation)
	runs: number,
	outcome: AckOutcome?,
	removed: number,
	remaining: number,
	touched: any, -- the table the last invocation changed (replay detection)
}

--- UpdateAsync transform that removes delivered entries from the outbox of a record nobody owns. A live owner holds the
--- outbox in memory and writes it back, so the record is left alone while it is locked (the owner re-delivers; the target
--- de-duplicates by id). An expired lock counts as unowned: whoever takes over next reads the outbox after this write.
function Record.ackOutbox(old: any, info: KeyInfoLike?, ctx: AckCtx): (any, { number }?, { [string]: any }?)
	ctx.runs += 1
	if old ~= nil and old == ctx.touched then
		-- replayed on the table this callback already changed: the removal is already in it
		ctx.outcome = "removed"
		return old, passThroughMeta(info)
	end
	ctx.outcome = nil
	ctx.removed = 0
	ctx.remaining = 0
	ctx.touched = nil
	if old == nil then
		ctx.outcome = "missing"
		return nil
	end
	if not Record.isEnvelope(old) or (old :: Record).v > Record.VERSION then
		ctx.outcome = "corrupt"
		return nil
	end
	local rec = old :: Record
	local lock = rec.l
	if lock ~= nil and ctx.now() < lock.x + ctx.skew then
		ctx.outcome = "locked"
		return nil
	end
	local outbox = rec.ob
	if outbox == nil then
		ctx.outcome = "none"
		return nil
	end
	local keep = 0
	local n = #outbox
	for i = 1, n do
		local entry = outbox[i]
		if not ctx.ids[entry.i] then
			keep += 1
			outbox[keep] = entry
		end
	end
	for i = keep + 1, n do
		outbox[i] = nil :: any
	end
	ctx.remaining = keep
	if keep == n then
		ctx.outcome = "none"
		return nil
	end
	ctx.removed = n - keep
	if keep == 0 then
		rec.ob = nil
	end
	rec.r += 1
	ctx.outcome = "removed"
	ctx.touched = rec
	return rec, passThroughMeta(info)
end

return Record
