--!strict
--[[
	Operator tools for one store (`Retriever.admin(store)`): inspect a key, edit it without fighting a live session,
	export/import a record as JSON-safe data, preview and perform a restore from version history, and migrate keys with the
	store's own migration code.

	Safety rules (G14: an admin edit never silently overwrites a live owner's unsaved data)
	* Every write is a compare-and-set on the record's revision `r`, made inside one UpdateAsync: the tool reads the record,
	  computes the new content OUTSIDE the callback (migrations, patches and validation may be slow or raise), and the callback
	  only installs it when `r` is unchanged. Any write in between (a session starting, a save, an inbox append) makes it a
	  conflict, so nothing computed from stale data is ever written.
	* A live owner (lock not expired) is never overwritten silently. A declarative patch is routed to it as an inbox command
	  that the owner's session applies exactly once (Patch.luau); a function patch is refused with `Locked`; `force = true`
	  takes the key over instead (the owner's next write is fenced and it loses its unsaved edits).
	* Every admin write bumps the epoch `e` and clears an expired lock, so a session issued before the write (a frozen server
	  that wakes up later) is fenced out instead of overwriting the edit. A record created by an admin write (import or restore
	  into a missing key) starts at a wall-clock epoch instead of 1, above any epoch a deleted predecessor can have issued.
	* Every admin write appends an audit entry (`au`, the last 20) whose id also makes the write idempotent: a retry after an
	  ambiguous error that finds its own id knows the write landed.

	Version history (restore): since 2024-07-29 Roblox keeps only the FIRST write per key per UTC hour as a backup of the
	previous data, for 30 days after it stopped being current. A restore preview therefore warns when the current data has no
	backup of its own (the key was already written this hour): restoring would overwrite it permanently, so export it first.

	Requests go through the runtime's dispatcher (budgets, priorities, retries with backoff). The tools yield.
]]

local Codec = require(script.Parent.Codec)
local Commands = require(script.Parent.Commands)
local Diff = require(script.Parent.Diff)
local Errors = require(script.Parent.Errors)
local Events = require(script.Parent.Events)
local Internal = require(script.Parent.Internal)
local Migrate = require(script.Parent.Migrate)
local Patch = require(script.Parent.Patch)
local Record = require(script.Parent.Record)
local Scheduler = require(script.Parent.Scheduler)
local Schema = require(script.Parent.Schema)
local Types = require(script.Parent.Types)
local Util = require(script.Parent.Util)
local Validate = require(script.Parent.Validate)

type StoreImpl = Internal.StoreImpl
type RetrieverError = Types.RetrieverError
type KeyInfoLike = Types.KeyInfoLike
type Rec = Types.Record

export type PatchOp = Patch.PatchOp
export type Change = Diff.Change

export type Owner = {
	jobId: string,
	placeId: number?,
	--- Wall-clock seconds when the lease runs out.
	leaseExpiry: number,
	--- True while the lease (plus the clock-skew allowance) has not run out: a session may be writing this key.
	live: boolean,
	--- Job id of a server waiting for a handoff, if any.
	handoffRequestedBy: string?,
	--- The owner is this server.
	thisServer: boolean,
}

export type RecordStatus =
	"missing" -- no value under the key
	| "record" -- a Retriever record
	| "stub" -- created by an inbox send, never loaded: no data yet
	| "corrupt" -- not a Retriever record (see `raw`)
	| "envelopeTooNew" -- written by a newer Retriever storage format

export type Loadability = {
	--- Whether this server would load the record (`Retriever.dryRun` of it).
	ok: boolean,
	kind: Types.ErrorKind?,
	cause: string?,
	--- Schema version of the stored data and of this server.
	from: number,
	to: number,
	--- Migration steps a load would run.
	pending: number,
	--- True when a load would have to save (migrated or filled).
	changed: boolean,
}

export type Inspection = {
	store: string,
	key: string,
	status: RecordStatus,
	revision: number?,
	epoch: number?,
	envelope: number?,
	schemaVersion: number?,
	minReader: number?,
	--- Schema version this server runs.
	serverSchema: number,
	owner: Owner?,
	--- A session for the key is active on this server.
	loadedHere: boolean,
	ledger: { size: number, horizon: number? },
	inbox: { size: number, kinds: { [string]: number } },
	outbox: { size: number },
	created: number?,
	--- Deep copy of the stored data (nil for a stub or a missing key).
	data: any,
	--- Deep copy of the stored value when it is not a record.
	raw: any,
	--- Bytes of the JSON encoding of the stored value (when the environment has a JSON codec).
	bytes: number?,
	userIds: { number },
	metadata: { [string]: any },
	--- DataStore version id and time (wall-clock seconds) of the current value.
	version: string?,
	updatedTime: number?,
	loadable: Loadability?,
	audit: { Types.AuditEntry },
	--- Recent events for the key from `Retriever.history(store)`, when a history is enabled.
	events: { Types.Event }?,
}

export type InspectResult = { ok: true, inspection: Inspection } | { ok: false, error: RetrieverError }

export type EditOptions = {
	--- Recorded in the audit trail and in the `admin` event.
	reason: string?,
	--- Refuse with `Conflict` unless the stored revision is exactly this (from `inspect`).
	expectedRevision: number?,
	--- Live owner: take the key over (fences the owner, which loses its unsaved edits) instead of routing or refusing.
	force: boolean?,
	--- Idempotency id of the edit (default: a fresh guid). A direct write records it in the audit trail, a patch routed to a
	--- live owner uses it as its command id. An edit whose id the record already shows (audit trail, ledger or inbox) is not
	--- applied again (`duplicate = true`), so an edit that returned `Unknown` can be retried safely with the same id.
	id: string?,
	--- Seconds to keep retrying transient failures. Default 30.
	timeout: number?,
	--- Read-compute-write rounds when the record keeps changing (only without `expectedRevision`). Default 3.
	attempts: number?,
}

--- `direct`: written (no live owner). `takeover`: written with `force` over a live owner. `command`: routed to the live
--- owner's inbox (applied by its session; `changes` is a preview against the stored data). `unchanged`: nothing to write.
export type EditMode = "direct" | "takeover" | "command" | "unchanged"

export type EditResult = {
	ok: true,
	mode: EditMode,
	revision: number?,
	id: string?,
	duplicate: boolean?,
	changes: { Change },
	truncated: boolean,
} | { ok: false, error: RetrieverError }

export type ExportedRecord = {
	format: "retriever.record",
	formatVersion: number,
	store: string,
	key: string,
	--- Wall-clock seconds.
	exportedAt: number,
	revision: number,
	schemaVersion: number?,
	minReader: number?,
	data: any,
	ledger: { [string]: number }?,
	ledgerHorizon: number?,
	inbox: { Types.InboxEntry }?,
	outbox: { Types.OutboxEntry }?,
	created: number?,
	userIds: { number }?,
	metadata: { [string]: any }?,
}

export type ExportOptions = {
	--- Also encode the document with the environment's JSON codec (`result.json`).
	json: boolean?,
	timeout: number?,
}

export type ExportResult = { ok: true, record: ExportedRecord, json: string? } | { ok: false, error: RetrieverError }

export type ImportOptions = {
	--- Target key. Default: the exported key.
	key: string?,
	--- When the key already holds a record: "fail" (default, `Conflict`), "skip" (leave it) or "overwrite".
	onConflict: ("fail" | "skip" | "overwrite")?,
	--- With "overwrite": refuse unless the stored revision is exactly this.
	expectedRevision: number?,
	--- Overwrite even when a live session owns the key (fences it).
	force: boolean?,
	--- Leave out parts of the export. Default true for each. The ledger and the outbox belong to the data (an op id is in the
	--- ledger exactly when its effect is in the data), so only drop them knowingly.
	ledger: boolean?,
	inbox: boolean?,
	outbox: boolean?,
	reason: string?,
	timeout: number?,
}

export type ImportResult = {
	ok: true,
	--- Nil when skipped.
	revision: number?,
	created: boolean,
	skipped: boolean,
} | { ok: false, error: RetrieverError }

export type VersionInfo = {
	version: string,
	--- Wall-clock seconds when this version was written.
	time: number,
	deleted: boolean,
	--- UTC hour bucket (`math.floor(time / 3600)`): Roblox keeps one backup per key and hour.
	hour: number,
}

export type VersionsOptions = {
	--- Default 50 (at most 1000).
	limit: number?,
	--- Default true.
	newestFirst: boolean?,
	--- Only versions written at or after / at or before these wall-clock seconds.
	after: number?,
	before: number?,
	cursor: string?,
	timeout: number?,
}

export type VersionsResult = {
	ok: true,
	versions: { VersionInfo },
	cursor: string?,
	note: string,
} | { ok: false, error: RetrieverError }

export type WarningCode =
	"liveOwner" -- a session owns the key: restore needs `force` (the session is fenced and loses its unsaved edits)
	| "currentNotBackedUp" -- the key was already written this UTC hour: the restore overwrites the current data permanently
	| "schemaTooNew" -- the version needs a newer schema than this server runs: it cannot be restored from here
	| "migrationNeeded" -- the version is older than this server's schema: it is migrated when it next loads
	| "notARecord" -- the version is not a Retriever record: it cannot be restored
	| "deletedVersion" -- the version is a deletion marker (or no longer exists): nothing to restore
	| "inboxMerged" -- pending inbox commands of the current record are kept
	| "outboxReplaced" -- the current record's undelivered outbox entries are dropped (their cause is rolled back)
	| "missingCurrent" -- the key holds no record now: the restore recreates it

export type Warning = { code: WarningCode, message: string }

export type RestorePreview = {
	store: string,
	key: string,
	version: string,
	--- Wall-clock seconds the version was written.
	versionTime: number?,
	--- Revision the restore will compare against (the current record's `r`, 0 when missing).
	expectedRevision: number,
	restorable: boolean,
	current: { status: RecordStatus, revision: number?, schemaVersion: number?, updatedTime: number?, data: any },
	target: { status: RecordStatus, schemaVersion: number?, minReader: number?, data: any },
	changes: { Change },
	truncated: boolean,
	owner: Owner?,
	warnings: { Warning },
	notes: { string },
}

export type PreviewResult = { ok: true, preview: RestorePreview } | { ok: false, error: RetrieverError }

export type RestoreOptions = {
	--- Default: the preview's `expectedRevision`.
	expectedRevision: number?,
	force: boolean?,
	reason: string?,
	timeout: number?,
}

export type WriteResult = { ok: true, revision: number } | { ok: false, error: RetrieverError }

export type MigrateOptions = {
	--- Report what would happen without writing.
	dryRun: boolean?,
	reason: string?,
	timeout: number?,
}

export type MigrateResult = {
	ok: true,
	--- True when this call wrote the migrated data.
	migrated: boolean,
	--- Nothing to do: already at this server's version and filled (or a stub with no data yet).
	upToDate: boolean,
	revision: number?,
	report: Migrate.DryRunReport?,
} | { ok: false, error: RetrieverError, report: Migrate.DryRunReport? }

export type MigrateAllOptions = {
	prefix: string?,
	--- Resume token from the previous call's `cursor`. Persist it to resume a bulk migration after a restart.
	cursor: string?,
	--- Keys per call (one ListKeys page). Default 50, at most 500.
	limit: number?,
	dryRun: boolean?,
	reason: string?,
}

export type MigrateAllReport = {
	ok: true,
	scanned: number,
	migrated: number,
	upToDate: number,
	--- Keys owned by a live session (they migrate when they load).
	skipped: number,
	failed: { { key: string, error: RetrieverError } },
	--- Pass to the next call; nil when the listing is finished.
	cursor: string?,
	done: boolean,
} | { ok: false, error: RetrieverError }

export type KeysResult = { ok: true, keys: { string }, cursor: string? } | { ok: false, error: RetrieverError }

local Admin = {}
Admin.__index = Admin

type AdminImpl = { impl: StoreImpl }

local DEFAULT_TIMEOUT = 30
local PRIO = 2 -- interactive, like store:send
local PRIO_BULK = 4 -- migrateAll: background, keeps the reserve for live sessions
local AUDIT_MAX = 20
local CHANGE_LIMIT = 100

local HOURLY_NOTE = "Roblox keeps only the first write per key per UTC hour as a backup of the previous data, for 30 days after it "
	.. "stopped being current: versions are hourly snapshots, not a per-save history, and writes made later in the same hour are not recoverable."

------------------------------------------------------------------------------------------------------------------------
-- helpers
------------------------------------------------------------------------------------------------------------------------

local function fail(message: string, level: number?): never
	error(`[Retriever] admin: {message}`, (level or 2) + 1)
end

local function checkKey(key: any, what: string)
	if type(key) ~= "string" or key == "" or #key > 50 then
		fail(`{what} needs a non-empty key of at most 50 characters, got {typeof(key)} "{tostring(key)}"`, 3)
	end
end

local function problem(impl: StoreImpl, kind: Types.ErrorKind, key: string?, cause: string?, details: { [string]: any }?): RetrieverError
	return Errors.new(kind, impl.name, key, cause, details)
end

local function never(): boolean
	return false
end

local function timeoutOf(options: { timeout: number? }?): number
	return if options ~= nil and options.timeout ~= nil then options.timeout else DEFAULT_TIMEOUT
end

--- One backend request through the dispatcher, retried on transient errors. `call` returns one value (pack several).
local function request(
	impl: StoreImpl,
	key: string?,
	kind: Types.BudgetKind,
	prio: number,
	timeout: number,
	call: () -> any,
	produced: (() -> boolean)?
): (RetrieverError?, any)
	local runtime = impl.runtime
	if runtime.destroyed then
		return problem(impl, "ShuttingDown", key, "the runtime was destroyed"), nil
	end
	local err, _, value = Commands.retrying(
		impl,
		key or "",
		kind,
		prio,
		call,
		produced or never,
		runtime.env.clock() + timeout,
		Scheduler.newSleeper(runtime.scheduler),
		nil
	)
	return err, value
end

--- A copy of an envelope with its data decoded (codec marker cleared), so every admin tool sees plain data. Other values
--- pass through. Returns the reason when the record names a codec this server cannot decode.
local function decodeValue(impl: StoreImpl, value: any): (any, string?)
	if type(value) ~= "table" or not Record.isEnvelope(value) or (value :: Rec).cd == nil then
		return value, nil
	end
	local rec = value :: Rec
	local ok, result = Codec.decode(rec.cd, rec.cv, rec.d, impl.policy.codec)
	if not ok then
		return value, result
	end
	local copy = table.clone(rec)
	copy.d = result
	copy.cd = nil
	copy.cv = nil
	return copy, nil
end

type Read = { value: any, info: KeyInfoLike? }

--- Uncached read of the current value.
local function read(impl: StoreImpl, key: string, timeout: number, prio: number?): (RetrieverError?, Read?)
	local backend = impl.backend
	local err, packed = request(impl, key, "get", prio or PRIO, timeout, function(): any
		local value, info = backend.get(key, false)
		return { value = value, info = info } :: Read
	end)
	if err ~= nil then
		return err, nil
	end
	local decoded, why = decodeValue(impl, (packed :: Read).value)
	if why ~= nil then
		return problem(impl, "Corrupt", key, why), nil
	end
	return nil, { value = decoded, info = (packed :: Read).info }
end

local function statusOf(value: any): RecordStatus
	if value == nil then
		return "missing"
	elseif not Record.isEnvelope(value) then
		return "corrupt"
	end
	local rec = value :: Rec
	if rec.v > Record.VERSION then
		return "envelopeTooNew"
	elseif rec.e == 0 and rec.d == nil then
		return "stub"
	end
	return "record"
end

local function statusError(impl: StoreImpl, key: string, status: RecordStatus): RetrieverError?
	if status == "missing" then
		return problem(impl, "NotFound", key)
	elseif status == "corrupt" then
		return problem(impl, "Corrupt", key, nil, { what = "Inspect it with admin:inspect(key) (see inspection.raw)." })
	elseif status == "envelopeTooNew" then
		return problem(impl, "SchemaTooNew", key, "the record uses a newer storage format than this version of Retriever")
	end
	return nil
end

local function ownerOf(impl: StoreImpl, rec: Rec): Owner?
	local lock = rec.l
	if lock == nil then
		return nil
	end
	local runtime = impl.runtime
	local env = runtime.env
	return {
		jobId = lock.j,
		placeId = lock.p,
		leaseExpiry = lock.x,
		live = env.time() < lock.x + runtime.options.clockSkew,
		handoffRequestedBy = lock.q,
		thisServer = lock.j == env.jobId,
	}
end

local function userIdsOf(info: KeyInfoLike?): { number }
	if info == nil then
		return {}
	end
	local ok, ids = pcall(info.GetUserIds, info)
	return if ok and type(ids) == "table" then ids else {}
end

local function metadataOf(info: KeyInfoLike?): { [string]: any }
	if info == nil then
		return {}
	end
	local ok, meta = pcall(info.GetMetadata, info)
	return if ok and type(meta) == "table" then meta else {}
end

local function secondsOf(ms: any): number?
	return if type(ms) == "number" then ms / 1000 else nil
end

--- Schema version and minimum reader of data prepared for this server from a record at `rec.sv`/`rec.mr`: data from an
--- older version is now in this server's shape; newer, forward-compatible data keeps its own versions.
local function versionsAfter(impl: StoreImpl, rec: Rec): (number, number?)
	local config = impl.config
	local target = config.schemaVersion
	local from = if type(rec.sv) == "number" then rec.sv :: number else 1
	local sv = if from < target then target else from
	local mr = rec.mr
	if from <= target then
		local needed = Migrate.minReaderFor(config, target)
		if needed ~= nil and (mr == nil or needed > mr) then
			mr = needed
		end
	end
	return sv, mr
end

local function emitAdmin(impl: StoreImpl, key: string, action: string, revision: number?, details: { [string]: any })
	local runtime = impl.runtime
	if runtime.events ~= nil then
		Events.emit(runtime, impl.name, key, "admin", { reason = action, revision = revision, details = details })
	end
end

--- JSON cannot carry buffers (a DataStore can). Returns the path of the first one.
local function bufferPath(value: any, path: string, depth: number): string?
	if type(value) == "buffer" then
		return path
	end
	if type(value) ~= "table" or depth > 64 then
		return nil
	end
	for k, v in value do
		local found = bufferPath(v, `{path}.{tostring(k)}`, depth + 1)
		if found ~= nil then
			return found
		end
	end
	return nil
end

------------------------------------------------------------------------------------------------------------------------
-- the compare-and-set write
------------------------------------------------------------------------------------------------------------------------

type CasOutcome =
	"wrote" -- this invocation produced the new record
	| "landed" -- an earlier attempt of this operation already wrote it (found its audit id)
	| "conflict" -- the revision is not the expected one; nothing written
	| "owned" -- a live session owns the key and `allowLive` is false; nothing written
	| "corrupt" -- not a record (or a newer envelope); nothing written

type CasCtx = {
	-- inputs
	opId: string,
	action: string,
	reason: string?,
	jobId: string,
	expectRev: number, -- 0: the key must not exist
	allowLive: boolean,
	now: () -> number,
	skew: number,
	--- Installs the new content into `rec` (an existing record, or a fresh envelope). Pure; may run several times.
	apply: (rec: Rec) -> (),
	replaceMeta: boolean,
	userIds: { number }?,
	meta: { [string]: any }?,
	-- outputs (reset per invocation, except `produced`)
	runs: number,
	outcome: CasOutcome?,
	rev: number,
	ownerJob: string?,
	touched: any,
	produced: boolean,
}

local function metaFor(ctx: CasCtx, info: KeyInfoLike?): ({ number }?, { [string]: any }?)
	if ctx.replaceMeta then
		return ctx.userIds, ctx.meta
	end
	if info == nil then
		return nil, nil
	end
	return info:GetUserIds(), info:GetMetadata()
end

--- UpdateAsync transform: install the prepared content only if the record is still at `expectRev`. Replay-safe: a replay on
--- the table it already changed returns it again, and a replay on the committed value finds the audit id.
local function casTransform(old: any, info: KeyInfoLike?, ctx: CasCtx): (any, { number }?, { [string]: any }?)
	ctx.runs += 1
	if old ~= nil and old == ctx.touched then
		ctx.outcome = "wrote"
		return old, metaFor(ctx, info)
	end
	ctx.outcome = nil
	ctx.ownerJob = nil
	ctx.touched = nil
	local current = 0
	if old ~= nil then
		if not Record.isEnvelope(old) or (old :: Rec).v > Record.VERSION then
			ctx.outcome = "corrupt"
			return nil
		end
		local audit = (old :: Rec).au
		if audit ~= nil then
			for _, entry in audit do
				if entry.i == ctx.opId then
					ctx.outcome = "landed"
					ctx.rev = entry.rv or (old :: Rec).r
					return nil
				end
			end
		end
		current = (old :: Rec).r
	end
	if current ~= ctx.expectRev then
		ctx.outcome = "conflict"
		ctx.rev = current
		return nil
	end
	local now = ctx.now()
	local rec: Rec
	if old ~= nil then
		rec = old :: Rec
		local lock = rec.l
		if lock ~= nil and now < lock.x + ctx.skew and not ctx.allowLive then
			ctx.outcome = "owned"
			ctx.ownerJob = lock.j
			return nil
		end
		rec.e += 1 -- fences every session issued before this write
	else
		-- The key may have held a record before (deleted, then restored or imported): its epochs are unknown, and a session
		-- issued one of them may still be frozen mid-close. Epoch 1 would let such a session's replayed release ("our epoch,
		-- no lock") overwrite this write, so start above every epoch that can have been issued: the wall clock in ms
		-- (sessions add 1 per acquire; no key is acquired more than once per millisecond for its whole life).
		local fresh: Rec = { v = Record.VERSION, r = 0, e = math.max(1, math.floor(now * 1000)) }
		rec = fresh
	end
	rec.l = nil
	local before = rec.d
	ctx.apply(rec)
	if rec.d ~= before then
		-- admin tools write plain data (reads decode it); the owning session re-encodes on its next save
		rec.cd = nil
		rec.cv = nil
	end
	if rec.c == nil then
		rec.c = now
	end
	rec.r = ctx.expectRev + 1
	local audit = rec.au or {}
	audit[#audit + 1] = { i = ctx.opId, t = now, a = ctx.action, j = ctx.jobId, r = ctx.reason, rv = rec.r }
	while #audit > AUDIT_MAX do
		table.remove(audit, 1)
	end
	rec.au = audit
	ctx.outcome = "wrote"
	ctx.rev = rec.r
	ctx.touched = rec
	ctx.produced = true
	return rec, metaFor(ctx, info)
end

type CasRequest = {
	key: string,
	action: string,
	reason: string?,
	expectRev: number,
	allowLive: boolean,
	apply: (rec: Rec) -> (),
	replaceMeta: boolean?,
	userIds: { number }?,
	meta: { [string]: any }?,
	timeout: number,
	prio: number?,
}

--- Runs one compare-and-set. Returns the outcome (with the revision) or an error.
local function cas(impl: StoreImpl, opId: string, req: CasRequest): (RetrieverError?, CasCtx)
	local runtime = impl.runtime
	local env = runtime.env
	local ctx: CasCtx = {
		opId = opId,
		action = req.action,
		reason = req.reason,
		jobId = env.jobId,
		expectRev = req.expectRev,
		allowLive = req.allowLive,
		now = env.time,
		skew = runtime.options.clockSkew,
		apply = req.apply,
		replaceMeta = req.replaceMeta == true,
		userIds = req.userIds,
		meta = req.meta,
		runs = 0,
		outcome = nil,
		rev = 0,
		ownerJob = nil,
		touched = nil,
		produced = false,
	}
	local backend = impl.backend
	local key = req.key
	local function transform(old: any, info: KeyInfoLike?)
		return casTransform(old, info, ctx)
	end
	local err = request(impl, key, "update", req.prio or PRIO, req.timeout, function(): any
		ctx.runs = 0
		return (backend.update(key, transform))
	end, function(): boolean
		return ctx.runs > 0 and ctx.outcome == "wrote"
	end)
	if err == nil and ctx.outcome == nil then
		err = problem(impl, if ctx.produced then "Unknown" else "Unavailable", key, "UpdateAsync returned without running the transform callback")
	end
	return err, ctx
end

local function casError(impl: StoreImpl, key: string, ctx: CasCtx, expected: number): RetrieverError
	local outcome = ctx.outcome
	if outcome == "owned" then
		return problem(impl, "Locked", key, nil, {
			what = "A session started on the key while the admin tool was preparing the write.",
			ownerJob = ctx.ownerJob,
		})
	elseif outcome == "corrupt" then
		return problem(impl, "Corrupt", key)
	end
	return problem(impl, "Conflict", key, nil, { expectedRevision = expected, revision = ctx.rev })
end

------------------------------------------------------------------------------------------------------------------------
-- inspect
------------------------------------------------------------------------------------------------------------------------

function Admin.inspect(self: AdminImpl, key: string, options: { timeout: number? }?): InspectResult
	checkKey(key, "inspect(key)")
	local impl = self.impl
	local runtime = impl.runtime
	local env = runtime.env
	local err, got = read(impl, key, timeoutOf(options))
	if err ~= nil then
		return { ok = false, error = err }
	end
	local value = (got :: Read).value
	local info = (got :: Read).info
	local status: RecordStatus = statusOf(value)
	local loaded = impl.profiles[key]
	local inspection: Inspection = {
		store = impl.name,
		key = key,
		status = status,
		revision = nil,
		epoch = nil,
		envelope = nil,
		schemaVersion = nil,
		minReader = nil,
		serverSchema = impl.config.schemaVersion,
		owner = nil,
		loadedHere = loaded ~= nil and loaded.state == "active",
		ledger = { size = 0, horizon = nil },
		inbox = { size = 0, kinds = {} },
		outbox = { size = 0 },
		created = nil,
		data = nil,
		raw = nil,
		bytes = nil,
		userIds = userIdsOf(info),
		metadata = metadataOf(info),
		version = if info ~= nil then info.Version else nil,
		updatedTime = if info ~= nil then secondsOf(info.UpdatedTime) else nil,
		loadable = nil,
		audit = {},
		events = Events.historyFor(runtime, impl.name, key),
	}
	local json = env.json
	if json ~= nil and value ~= nil then
		local ok, text = pcall(json.encode, value)
		if ok and type(text) == "string" then
			inspection.bytes = #text
		end
	end
	if status == "corrupt" then
		inspection.raw = Util.deepCopy(value)
	elseif status == "record" or status == "stub" or status == "envelopeTooNew" then
		local rec = value :: Rec
		inspection.revision = rec.r
		inspection.epoch = rec.e
		inspection.envelope = rec.v
		inspection.schemaVersion = rec.sv
		inspection.minReader = rec.mr
		inspection.owner = ownerOf(impl, rec)
		inspection.created = rec.c
		inspection.data = Util.deepCopy(rec.d)
		local ops = rec.o
		if type(ops) == "table" then
			local size = 0
			for _ in ops do
				size += 1
			end
			inspection.ledger = { size = size, horizon = rec.oh }
		end
		local inbox = rec.ib
		if type(inbox) == "table" then
			inspection.inbox.size = #inbox
			for _, entry in inbox do
				local kind = if type(entry) == "table" and type(entry.k) == "string" then entry.k else "?"
				inspection.inbox.kinds[kind] = (inspection.inbox.kinds[kind] or 0) + 1
			end
		end
		local outbox = rec.ob
		if type(outbox) == "table" then
			inspection.outbox.size = #outbox
		end
		if type(rec.au) == "table" then
			inspection.audit = Util.deepCopy(rec.au)
		end
		if status == "record" then
			local report = Migrate.dryRun(impl.config, value, { record = true })
			inspection.loadable = {
				ok = report.ok,
				kind = report.kind,
				cause = report.cause,
				from = report.from,
				to = impl.config.schemaVersion,
				pending = #report.applied,
				changed = report.changed,
			}
		elseif status == "stub" then
			inspection.loadable = {
				ok = true,
				kind = nil,
				cause = nil,
				from = impl.config.schemaVersion,
				to = impl.config.schemaVersion,
				pending = 0,
				changed = true,
			}
		end
	end
	return { ok = true, inspection = inspection }
end

------------------------------------------------------------------------------------------------------------------------
-- edit
------------------------------------------------------------------------------------------------------------------------

type Prepared = { data: any, sv: number, mr: number? }

--- The data an edit starts from: the stored data as this server would load it (migrated and filled on a copy). Data that is
--- currently invalid is still returned (the edit may be what fixes it); a failing migration step or a newer minimum reader
--- is an error.
local function baseData(impl: StoreImpl, key: string, rec: Rec): (RetrieverError?, Prepared?)
	local report = Migrate.dryRun(impl.config, rec, { record = true })
	if not report.ok then
		local usable = report.data ~= nil and (report.kind == "InvalidData" or report.kind == "MigrationFailed")
		if not usable then
			local kind: Types.ErrorKind = report.kind or "InvalidData"
			return problem(impl, kind, key, report.cause, { step = report.step, path = report.path }), nil
		end
	end
	local sv, mr = versionsAfter(impl, rec)
	return nil, { data = report.data, sv = sv, mr = mr }
end

local function listHasId(list: any, id: string): boolean
	if type(list) == "table" then
		for _, entry in list do
			if type(entry) == "table" and entry.i == id then
				return true
			end
		end
	end
	return false
end

--- Whether `rec` already shows operation `id`: an admin write's audit entry, an applied command (ledger) or a pending one.
local function idSeen(rec: Rec, id: string): boolean
	if type(rec.o) == "table" and (rec.o :: { [string]: number })[id] ~= nil then
		return true
	end
	return listHasId(rec.au, id) or listHasId(rec.ib, id)
end

local function pathDetails(message: string?): { [string]: any }?
	local path = Schema.pathOf(message)
	return if path ~= nil then { path = path } else nil
end

--- Changes the data of `key`. `patch` is a function `(data) -> ()` that edits a copy in place (or returns a replacement
--- table; it must not yield and may run more than once), or a declarative patch (a list of `{ op, path, value }`, see
--- Patch.luau). Ownership-aware: see the module header.
function Admin.edit(self: AdminImpl, key: string, patch: ((data: any) -> any) | { PatchOp }, options: EditOptions?): EditResult
	checkKey(key, "edit(key, patch)")
	local impl = self.impl
	local runtime = impl.runtime
	local env = runtime.env
	local opts: EditOptions = options or {}
	local isFunction = type(patch) == "function"
	if not isFunction then
		local ok, why = Patch.check(patch)
		if not ok then
			fail(`edit(key, patch): {why}`)
		end
	end
	local id = opts.id
	if id ~= nil and (type(id) ~= "string" or id == "" or #id > 100) then
		fail(`edit: options.id must be a non-empty string of at most 100 characters, got {typeof(id)} "{tostring(id)}"`)
	end
	local timeout = timeoutOf(opts)
	local expected = opts.expectedRevision
	local rounds = if expected ~= nil then 1 else math.max(1, opts.attempts or 3)
	local opId = id or env.guid()
	local lastCtx: CasCtx? = nil

	for _ = 1, rounds do
		local err, got = read(impl, key, timeout)
		if err ~= nil then
			return { ok = false, error = err }
		end
		local value = (got :: Read).value
		local status: RecordStatus = statusOf(value)
		if status == "stub" then
			return {
				ok = false,
				error = problem(impl, "NotFound", key, nil, { what = "The key only holds pending inbox commands (a stub); it has no data until it is loaded." }),
			}
		end
		local bad = statusError(impl, key, status)
		if bad ~= nil then
			return { ok = false, error = bad }
		end
		local rec = value :: Rec
		if expected ~= nil and rec.r ~= expected then
			return { ok = false, error = problem(impl, "Conflict", key, nil, { expectedRevision = expected, revision = rec.r }) }
		end
		if id ~= nil and idSeen(rec, id) then
			-- an earlier call with this id landed (audit), was applied by the owner (ledger) or is waiting for it (inbox)
			return { ok = true, mode = "unchanged", revision = rec.r, id = id, duplicate = true, changes = {}, truncated = false }
		end
		local prepErr, prepared = baseData(impl, key, rec)
		if prepErr ~= nil then
			return { ok = false, error = prepErr }
		end
		local base = (prepared :: Prepared).data
		local owner = ownerOf(impl, rec)
		local live = owner ~= nil and owner.live
		local force = opts.force == true

		if live and not force then
			if isFunction then
				return {
					ok = false,
					error = problem(impl, "Locked", key, nil, {
						what = "A live session owns the key. Pass a declarative patch ({ { op = \"set\", path = ..., value = ... } }) to have the owner apply it, or force = true to take the key over (the owner loses its unsaved edits).",
						ownerJob = (owner :: Owner).jobId,
					}),
				}
			end
			local ops = patch :: { PatchOp }
			local preview, why = Patch.preview(impl.config, base, ops)
			if preview == nil then
				return { ok = false, error = problem(impl, "InvalidData", key, why, pathDetails(why)) }
			end
			local changes, truncated = Diff.compute(base, preview, CHANGE_LIMIT)
			local commandId = opId
			local entry: Types.InboxEntry = {
				i = commandId,
				t = env.time(),
				k = Patch.COMMAND,
				p = { ops = Util.deepCopy(ops), reason = opts.reason, by = env.jobId },
			}
			local sent = Commands.append(
				impl,
				key,
				entry,
				false,
				PRIO,
				env.clock() + timeout,
				Scheduler.newSleeper(runtime.scheduler),
				nil
			)
			if not sent.ok then
				return { ok = false, error = sent.error }
			end
			emitAdmin(impl, key, "command", nil, { id = commandId, reason = opts.reason, owner = (owner :: Owner).jobId, duplicate = sent.duplicate })
			return { ok = true, mode = "command", revision = nil, id = commandId, duplicate = sent.duplicate, changes = changes, truncated = truncated }
		end

		-- direct write (no live owner), or a forced takeover
		local newData: any
		if isFunction then
			local copy = Util.deepCopy(base)
			local called, returned = pcall(patch :: (data: any) -> any, copy)
			if not called then
				return { ok = false, error = problem(impl, "InvalidArgument", key, `the patch function raised: {tostring(returned)}`) }
			end
			newData = if returned ~= nil then returned else copy
			local valid, why = Patch.validateData(impl.config, newData)
			if not valid then
				return { ok = false, error = problem(impl, "InvalidData", key, why, pathDetails(why)) }
			end
		else
			local preview, why = Patch.preview(impl.config, base, patch :: { PatchOp })
			if preview == nil then
				return { ok = false, error = problem(impl, "InvalidData", key, why, pathDetails(why)) }
			end
			newData = preview
		end
		local changes, truncated = Diff.compute(rec.d, newData, CHANGE_LIMIT)
		if #changes == 0 then
			return { ok = true, mode = "unchanged", revision = rec.r, id = nil, duplicate = nil, changes = changes, truncated = false }
		end
		local sv, mr = (prepared :: Prepared).sv, (prepared :: Prepared).mr
		local action = if live then "takeover" else "edit"
		local casErr, ctx = cas(impl, opId, {
			key = key,
			action = action,
			reason = opts.reason,
			expectRev = rec.r,
			allowLive = force,
			apply = function(target: Rec)
				target.d = newData
				target.sv = sv
				target.mr = mr
			end,
			timeout = timeout,
		})
		if casErr ~= nil then
			return { ok = false, error = casErr }
		end
		local outcome = ctx.outcome
		if outcome == "wrote" or outcome == "landed" then
			emitAdmin(impl, key, action, ctx.rev, { id = opId, reason = opts.reason, owner = if owner ~= nil then owner.jobId else nil })
			return {
				ok = true,
				mode = if live then "takeover" else "direct",
				revision = ctx.rev,
				id = opId,
				duplicate = nil,
				changes = changes,
				truncated = truncated,
			}
		elseif outcome == "corrupt" or expected ~= nil then
			return { ok = false, error = casError(impl, key, ctx, rec.r) }
		end
		-- conflict or a session started meanwhile: read again and decide again
		lastCtx = ctx
	end
	local ctx = lastCtx :: CasCtx
	return {
		ok = false,
		error = problem(impl, "Conflict", key, nil, {
			what = `The record kept changing while the edit was prepared ({rounds} attempts); try again.`,
			revision = ctx.rev,
			ownerJob = ctx.ownerJob,
		}),
	}
end

------------------------------------------------------------------------------------------------------------------------
-- export / import
------------------------------------------------------------------------------------------------------------------------

local FORMAT = "retriever.record"
local FORMAT_VERSION = 1

local function emptyToNil<T>(list: { T }?): { T }?
	if list == nil or next(list) == nil then
		return nil
	end
	return list
end

--- A JSON-safe copy of the record under `key` (session state such as the lock and the epoch is left out).
function Admin.export(self: AdminImpl, key: string, options: ExportOptions?): ExportResult
	checkKey(key, "export(key)")
	local impl = self.impl
	local env = impl.runtime.env
	local opts: ExportOptions = options or {}
	local json = env.json
	if opts.json and json == nil then
		fail("export: options.json needs an environment with a JSON codec (env.json)")
	end
	local err, got = read(impl, key, timeoutOf(opts))
	if err ~= nil then
		return { ok = false, error = err }
	end
	local value = (got :: Read).value
	local info = (got :: Read).info
	local bad = statusError(impl, key, statusOf(value))
	if bad ~= nil then
		return { ok = false, error = bad }
	end
	local rec = value :: Rec
	local doc: ExportedRecord = {
		format = FORMAT :: "retriever.record",
		formatVersion = FORMAT_VERSION,
		store = impl.name,
		key = key,
		exportedAt = env.time(),
		revision = rec.r,
		schemaVersion = rec.sv,
		minReader = rec.mr,
		data = Util.deepCopy(rec.d),
		ledger = Util.deepCopy(rec.o),
		ledgerHorizon = rec.oh,
		inbox = Util.deepCopy(emptyToNil(rec.ib)),
		outbox = Util.deepCopy(emptyToNil(rec.ob)),
		created = rec.c,
		userIds = emptyToNil(userIdsOf(info)),
		metadata = if next(metadataOf(info)) ~= nil then metadataOf(info) else nil,
	}
	local where = bufferPath(doc, "record", 0)
	if where ~= nil then
		return {
			ok = false,
			error = problem(impl, "InvalidData", key, `{where} is a buffer, which JSON cannot represent`, { what = "The record cannot be exported as JSON." }),
		}
	end
	local text: string? = nil
	if opts.json and json ~= nil then
		local ok, encoded = pcall(json.encode, doc)
		if not ok then
			return { ok = false, error = problem(impl, "InvalidData", key, `JSON encoding failed: {tostring(encoded)}`) }
		end
		text = encoded
	end
	return { ok = true, record = doc, json = text }
end

local function checkDoc(doc: any): string?
	if type(doc) ~= "table" then
		return `an export is a table (or its JSON text), got {typeof(doc)}`
	end
	if doc.format ~= FORMAT then
		return `not a Retriever export (format is {tostring(doc.format)}, expected "{FORMAT}")`
	end
	if type(doc.formatVersion) ~= "number" or doc.formatVersion > FORMAT_VERSION then
		return `export format version {tostring(doc.formatVersion)} is not supported by this version of Retriever (it reads up to {FORMAT_VERSION})`
	end
	if type(doc.data) ~= "table" then
		return `the export has no data table (data is {typeof(doc.data)})`
	end
	for _, field in { "schemaVersion", "minReader", "ledgerHorizon", "created" } do
		local v = doc[field]
		if v ~= nil and type(v) ~= "number" then
			return `{field} must be a number, got {typeof(v)}`
		end
	end
	for _, field in { "ledger", "inbox", "outbox", "userIds", "metadata" } do
		local v = doc[field]
		if v ~= nil and type(v) ~= "table" then
			return `{field} must be a table, got {typeof(v)}`
		end
	end
	return nil
end

--- Merges inbox entries: `kept` first, then those of `extra` whose ids are new and not in `ledger`.
local function mergeInbox(kept: { Types.InboxEntry }?, extra: { Types.InboxEntry }?, ledger: { [string]: number }?): { Types.InboxEntry }?
	local out: { Types.InboxEntry } = {}
	local seen: { [string]: boolean } = {}
	local applied: { [string]: number } = ledger or {}
	local function add(list: { Types.InboxEntry }?)
		if list == nil then
			return
		end
		for _, entry in list do
			if type(entry) == "table" and type(entry.i) == "string" and not seen[entry.i] and applied[entry.i] == nil then
				seen[entry.i] = true
				out[#out + 1] = entry
			end
		end
	end
	add(kept)
	add(extra)
	return if #out > 0 then out else nil
end

--- Writes an exported record (from `export`, or its JSON text) under its key or `options.key`.
function Admin.import(self: AdminImpl, source: ExportedRecord | string, options: ImportOptions?): ImportResult
	local impl = self.impl
	local runtime = impl.runtime
	local env = runtime.env
	local opts: ImportOptions = options or {}
	local doc: any = source
	if type(source) == "string" then
		local json = env.json
		if json == nil then
			fail("import: JSON text needs an environment with a JSON codec (env.json); pass the decoded table instead")
		end
		local ok, decoded = pcall((json :: Types.JsonCodec).decode, source)
		if not ok then
			return { ok = false, error = problem(impl, "InvalidArgument", opts.key, `the export is not valid JSON: {tostring(decoded)}`) }
		end
		doc = decoded
	end
	local docProblem = checkDoc(doc)
	if docProblem ~= nil then
		return { ok = false, error = problem(impl, "InvalidArgument", opts.key, docProblem) }
	end
	local key = opts.key or doc.key
	checkKey(key, "import (options.key or the exported key)")
	local onConflict = opts.onConflict or "fail"
	if onConflict ~= "fail" and onConflict ~= "skip" and onConflict ~= "overwrite" then
		fail(`import: onConflict must be "fail", "skip" or "overwrite", got {tostring(onConflict)}`)
	end
	local timeout = timeoutOf(opts)

	local data = Util.deepCopy(doc.data)
	local ledger = if opts.ledger ~= false then Util.deepCopy(doc.ledger) else nil
	local horizon = if opts.ledger ~= false then doc.ledgerHorizon else nil
	local inbox = if opts.inbox ~= false then Util.deepCopy(doc.inbox) else nil
	local outbox = if opts.outbox ~= false then Util.deepCopy(emptyToNil(doc.outbox)) else nil
	local sv: number? = doc.schemaVersion
	local mr: number? = doc.minReader
	local candidate: Rec = { v = Record.VERSION, r = 0, e = 0, sv = sv, mr = mr, d = data, o = ledger, oh = horizon, ib = inbox, ob = outbox, c = doc.created }
	local storable, why = Validate.storable(candidate)
	if not storable then
		return { ok = false, error = problem(impl, "InvalidData", key, why, { what = "The export cannot be stored in a DataStore." }) }
	end
	local report = Migrate.dryRun(impl.config, candidate, { record = true })
	if not report.ok then
		local kind: Types.ErrorKind = report.kind or "InvalidData"
		return {
			ok = false,
			error = problem(impl, kind, key, report.cause, { what = "This server could not load the imported record.", step = report.step, path = report.path }),
		}
	end

	local err, got = read(impl, key, timeout)
	if err ~= nil then
		return { ok = false, error = err }
	end
	local value = (got :: Read).value
	local status: RecordStatus = statusOf(value)
	if status == "corrupt" or status == "envelopeTooNew" then
		return { ok = false, error = statusError(impl, key, status) :: RetrieverError }
	end
	local expectRev = 0
	local existing = status == "record"
	if value ~= nil then
		local rec = value :: Rec
		expectRev = rec.r
		if existing then
			if onConflict == "skip" then
				return { ok = true, revision = nil, created = false, skipped = true }
			elseif onConflict == "fail" then
				return {
					ok = false,
					error = problem(impl, "Conflict", key, nil, { what = "The key already holds a record; pass onConflict = \"overwrite\" or \"skip\".", revision = rec.r }),
				}
			end
			if opts.expectedRevision ~= nil and rec.r ~= opts.expectedRevision then
				return { ok = false, error = problem(impl, "Conflict", key, nil, { expectedRevision = opts.expectedRevision, revision = rec.r }) }
			end
		end
		local owner = ownerOf(impl, rec)
		if owner ~= nil and owner.live and opts.force ~= true then
			return {
				ok = false,
				error = problem(impl, "Locked", key, nil, { what = "A live session owns the key; close it first or pass force = true.", ownerJob = owner.jobId }),
			}
		end
	end

	local opId = env.guid()
	local created = doc.created
	local casErr, ctx = cas(impl, opId, {
		key = key,
		action = "import",
		reason = opts.reason,
		expectRev = expectRev,
		allowLive = opts.force == true,
		apply = function(target: Rec)
			target.d = data
			target.sv = sv
			target.mr = mr
			target.o = ledger
			target.oh = horizon
			target.ob = outbox
			-- commands sent to the key since the export stay pending (unless the imported ledger already applied them)
			target.ib = mergeInbox(target.ib, inbox, ledger)
			if target.c == nil then
				target.c = created
			end
		end,
		replaceMeta = true,
		userIds = emptyToNil(doc.userIds),
		meta = if doc.metadata ~= nil and next(doc.metadata) ~= nil then doc.metadata else nil,
		timeout = timeout,
	})
	if casErr ~= nil then
		return { ok = false, error = casErr }
	end
	if ctx.outcome ~= "wrote" and ctx.outcome ~= "landed" then
		return { ok = false, error = casError(impl, key, ctx, expectRev) }
	end
	emitAdmin(impl, key, "import", ctx.rev, { id = opId, reason = opts.reason, from = doc.key })
	return { ok = true, revision = ctx.rev, created = not existing, skipped = false }
end

------------------------------------------------------------------------------------------------------------------------
-- versions and restore
------------------------------------------------------------------------------------------------------------------------

--- Lists the stored versions (backups) of `key`.
function Admin.versions(self: AdminImpl, key: string, options: VersionsOptions?): VersionsResult
	checkKey(key, "versions(key)")
	local impl = self.impl
	local opts: VersionsOptions = options or {}
	local limit = opts.limit or 50
	if type(limit) ~= "number" or limit < 1 or limit > 1000 or limit % 1 ~= 0 then
		fail(`versions: limit must be a whole number between 1 and 1000, got {tostring(limit)}`)
	end
	local ascending = opts.newestFirst == false
	local minMs = if opts.after ~= nil then math.floor(opts.after * 1000) else nil
	local maxMs = if opts.before ~= nil then math.floor(opts.before * 1000) else nil
	local backend = impl.backend
	local err, page = request(impl, key, "list", PRIO, timeoutOf(opts), function(): any
		return backend.listVersions(key, ascending, minMs, maxMs, limit, opts.cursor)
	end)
	if err ~= nil then
		return { ok = false, error = err }
	end
	local versions: { VersionInfo } = {}
	for _, entry in (page :: Types.VersionPage).versions do
		local seconds = entry.createdTime / 1000
		versions[#versions + 1] = {
			version = entry.version,
			time = seconds,
			deleted = entry.deleted,
			hour = math.floor(seconds / 3600),
		}
	end
	return { ok = true, versions = versions, cursor = (page :: Types.VersionPage).cursor, note = HOURLY_NOTE }
end

local function isNotFound(text: string): boolean
	local lower = string.lower(text)
	return string.find(lower, "not found", 1, true) ~= nil
		or string.find(lower, "notfound", 1, true) ~= nil
		or string.find(lower, "invalidversion", 1, true) ~= nil
end

type VersionRead = { value: any, info: KeyInfoLike?, missing: boolean }

local function readVersion(impl: StoreImpl, key: string, version: string, timeout: number): (RetrieverError?, VersionRead?)
	local backend = impl.backend
	local err, packed = request(impl, key, "getVersion", PRIO, timeout, function(): any
		local ok, value, info = pcall(backend.getVersion, key, version)
		if not ok then
			local text = tostring(value)
			if isNotFound(text) then
				return { value = nil, info = nil, missing = true } :: VersionRead
			end
			error(text, 0)
		end
		return { value = value, info = info, missing = false } :: VersionRead
	end)
	if err ~= nil then
		return err, nil
	end
	local decoded, why = decodeValue(impl, (packed :: VersionRead).value)
	if why ~= nil then
		return problem(impl, "Corrupt", key, `version {version}: {why}`), nil
	end
	return nil, { value = decoded, info = (packed :: VersionRead).info, missing = (packed :: VersionRead).missing }
end

--- What restoring `version` would change, with warnings. Pass the preview to `restore`.
function Admin.previewRestore(self: AdminImpl, key: string, version: string, options: { timeout: number? }?): PreviewResult
	checkKey(key, "previewRestore(key, version)")
	if type(version) ~= "string" or version == "" then
		fail(`previewRestore(key, version) needs a version id from admin:versions(key), got {typeof(version)} "{tostring(version)}"`)
	end
	local impl = self.impl
	local env = impl.runtime.env
	local timeout = timeoutOf(options)
	local err, got = read(impl, key, timeout)
	if err ~= nil then
		return { ok = false, error = err }
	end
	local verErr, ver = readVersion(impl, key, version, timeout)
	if verErr ~= nil then
		return { ok = false, error = verErr }
	end
	local current = (got :: Read).value
	local currentInfo = (got :: Read).info
	local target = (ver :: VersionRead).value
	local targetInfo = (ver :: VersionRead).info

	local currentStatus: RecordStatus = statusOf(current)
	local targetStatus: RecordStatus = statusOf(target)
	if currentStatus == "corrupt" or currentStatus == "envelopeTooNew" then
		return { ok = false, error = statusError(impl, key, currentStatus) :: RetrieverError }
	end
	local warnings: { Warning } = {}
	local function warn(code: WarningCode, message: string)
		warnings[#warnings + 1] = { code = code, message = message }
	end
	local restorable = true

	local currentRec: Rec? = if currentStatus == "record" or currentStatus == "stub" then current :: Rec else nil
	local targetRec: Rec? = if targetStatus == "record" then target :: Rec else nil
	local owner = if currentRec ~= nil then ownerOf(impl, currentRec) else nil

	if (ver :: VersionRead).missing or targetStatus == "missing" then
		restorable = false
		warn("deletedVersion", "This version is a deletion marker or no longer exists: there is nothing to restore.")
	elseif targetStatus == "stub" then
		restorable = false
		warn("deletedVersion", "This version holds no data (a stub with pending commands only): there is nothing to restore.")
	elseif targetStatus ~= "record" then
		restorable = false
		warn("notARecord", `This version is not a Retriever record ({targetStatus}); it cannot be restored with the admin tools.`)
	end
	if targetRec ~= nil then
		local mr = targetRec.mr
		if mr ~= nil and mr > impl.config.schemaVersion then
			restorable = false
			warn("schemaTooNew", `This version needs schema version {mr} or newer; this server runs {impl.config.schemaVersion}. Restore it from a newer server.`)
		elseif (targetRec.sv or 1) < impl.config.schemaVersion then
			warn("migrationNeeded", `This version has schema version {targetRec.sv or 1}; it is migrated to {impl.config.schemaVersion} when it next loads.`)
		end
	end
	if owner ~= nil and owner.live then
		warn("liveOwner", `A live session (server {owner.jobId}) owns the key. Restoring needs force = true: that session is fenced and loses its unsaved edits.`)
	end
	local updatedTime = if currentInfo ~= nil then secondsOf(currentInfo.UpdatedTime) else nil
	if currentRec == nil then
		warn("missingCurrent", "The key holds no record now; the restore creates it.")
	elseif updatedTime ~= nil and math.floor(updatedTime / 3600) == math.floor(env.time() / 3600) then
		warn(
			"currentNotBackedUp",
			"The key was already written this UTC hour, so the restore write will not keep a backup of the current data: it is overwritten permanently. Export it first (admin:export) if you may need it."
		)
	end
	if currentRec ~= nil then
		if currentRec.ib ~= nil and #currentRec.ib > 0 then
			warn("inboxMerged", `{#currentRec.ib} pending inbox command(s) of the current record are kept and applied at the next load.`)
		end
		if currentRec.ob ~= nil and #currentRec.ob > 0 then
			warn("outboxReplaced", `{#currentRec.ob} undelivered outbox command(s) of the current record are dropped (the data that caused them is rolled back).`)
		end
	end

	local currentData = if currentRec ~= nil then currentRec.d else nil
	local targetData = if targetRec ~= nil then targetRec.d else nil
	local changes, truncated = Diff.compute(currentData, targetData, CHANGE_LIMIT)
	local preview: RestorePreview = {
		store = impl.name,
		key = key,
		version = version,
		versionTime = if targetInfo ~= nil then secondsOf(targetInfo.UpdatedTime) else nil,
		expectedRevision = if currentRec ~= nil then currentRec.r else 0,
		restorable = restorable,
		current = {
			status = currentStatus,
			revision = if currentRec ~= nil then currentRec.r else nil,
			schemaVersion = if currentRec ~= nil then currentRec.sv else nil,
			updatedTime = updatedTime,
			data = Util.deepCopy(currentData),
		},
		target = {
			status = targetStatus,
			schemaVersion = if targetRec ~= nil then targetRec.sv else nil,
			minReader = if targetRec ~= nil then targetRec.mr else nil,
			data = Util.deepCopy(targetData),
		},
		changes = changes,
		truncated = truncated,
		owner = owner,
		warnings = warnings,
		notes = { HOURLY_NOTE },
	}
	return { ok = true, preview = preview }
end

--- Restores the version a preview describes: its data with its schema versions, ledger and outbox (they belong together),
--- keeping the commands currently pending in the inbox. Compare-and-set against the preview's revision: if the record
--- changed since the preview, nothing is written (`Conflict`); preview again.
function Admin.restore(self: AdminImpl, preview: RestorePreview, options: RestoreOptions?): WriteResult
	if type(preview) ~= "table" or type(preview.key) ~= "string" or type(preview.version) ~= "string" then
		fail("restore(preview) needs the preview returned by admin:previewRestore(key, version)")
	end
	local impl = self.impl
	local env = impl.runtime.env
	local key = preview.key
	checkKey(key, "restore(preview)")
	local opts: RestoreOptions = options or {}
	local expected = opts.expectedRevision or preview.expectedRevision
	if type(expected) ~= "number" then
		fail("restore: the preview has no expectedRevision; pass options.expectedRevision")
	end
	local timeout = timeoutOf(opts)
	-- read the version again: the preview is the caller's table, the restore writes exactly what is stored
	local verErr, ver = readVersion(impl, key, preview.version, timeout)
	if verErr ~= nil then
		return { ok = false, error = verErr }
	end
	local target = (ver :: VersionRead).value
	if (ver :: VersionRead).missing or statusOf(target) ~= "record" then
		return {
			ok = false,
			error = problem(impl, "NotFound", key, nil, { what = `Version {preview.version} holds no restorable record.`, version = preview.version }),
		}
	end
	local rec = target :: Rec
	if rec.mr ~= nil and rec.mr > impl.config.schemaVersion then
		return {
			ok = false,
			error = problem(impl, "SchemaTooNew", key, `version needs schema {rec.mr}, this server runs {impl.config.schemaVersion}`),
		}
	end
	local opId = env.guid()
	local casErr, ctx = cas(impl, opId, {
		key = key,
		action = "restore",
		reason = opts.reason,
		expectRev = expected,
		allowLive = opts.force == true,
		apply = function(current: Rec)
			current.d = rec.d
			current.sv = rec.sv
			current.mr = rec.mr
			current.o = rec.o
			current.oh = rec.oh
			current.ob = rec.ob
			current.ib = mergeInbox(current.ib, rec.ib, rec.o)
			if current.c == nil then
				current.c = rec.c
			end
		end,
		timeout = timeout,
	})
	if casErr ~= nil then
		return { ok = false, error = casErr }
	end
	if ctx.outcome ~= "wrote" and ctx.outcome ~= "landed" then
		return { ok = false, error = casError(impl, key, ctx, expected) }
	end
	emitAdmin(impl, key, "restore", ctx.rev, { id = opId, reason = opts.reason, version = preview.version })
	return { ok = true, revision = ctx.rev }
end

------------------------------------------------------------------------------------------------------------------------
-- migration
------------------------------------------------------------------------------------------------------------------------

local function migrateKey(self: AdminImpl, key: string, opts: MigrateOptions, prio: number): MigrateResult
	local impl = self.impl
	local env = impl.runtime.env
	local timeout = timeoutOf(opts)
	local opId = env.guid()
	for _ = 1, 3 do
		local err, got = read(impl, key, timeout, prio)
		if err ~= nil then
			return { ok = false, error = err, report = nil }
		end
		local value = (got :: Read).value
		local status: RecordStatus = statusOf(value)
		if status == "stub" then
			return { ok = true, migrated = false, upToDate = true, revision = (value :: Rec).r, report = nil }
		end
		local bad = statusError(impl, key, status)
		if bad ~= nil then
			return { ok = false, error = bad, report = nil }
		end
		local rec = value :: Rec
		local report = Migrate.dryRun(impl.config, rec, { record = true })
		if not report.ok then
			local kind: Types.ErrorKind = report.kind or "MigrationFailed"
			return { ok = false, error = problem(impl, kind, key, report.cause, { step = report.step, path = report.path }), report = report }
		end
		if not report.changed then
			return { ok = true, migrated = false, upToDate = true, revision = rec.r, report = report }
		end
		local owner = ownerOf(impl, rec)
		if owner ~= nil and owner.live then
			return {
				ok = false,
				error = problem(impl, "Locked", key, nil, { what = "A live session owns the key; it migrates when it loads.", ownerJob = owner.jobId }),
				report = report,
			}
		end
		if opts.dryRun then
			return { ok = true, migrated = false, upToDate = false, revision = rec.r, report = report }
		end
		local sv, mr = versionsAfter(impl, rec)
		local data = report.data
		local casErr, ctx = cas(impl, opId, {
			key = key,
			action = "migrate",
			reason = opts.reason,
			expectRev = rec.r,
			allowLive = false,
			apply = function(target: Rec)
				target.d = data
				target.sv = sv
				target.mr = mr
			end,
			timeout = timeout,
			prio = prio,
		})
		if casErr ~= nil then
			return { ok = false, error = casErr, report = report }
		end
		if ctx.outcome == "wrote" or ctx.outcome == "landed" then
			emitAdmin(impl, key, "migrate", ctx.rev, { id = opId, reason = opts.reason, from = report.from, to = sv })
			return { ok = true, migrated = true, upToDate = false, revision = ctx.rev, report = report }
		elseif ctx.outcome == "corrupt" then
			return { ok = false, error = casError(impl, key, ctx, rec.r), report = report }
		end
		-- conflict or a session started: read again (a live owner is then reported as Locked)
	end
	return { ok = false, error = problem(impl, "Conflict", key, nil, { what = "The record kept changing; try again." }), report = nil }
end

--- Migrates the stored data of `key` to this server's schema version with the store's migrations (and fills/validates it),
--- without loading a session. Keys owned by a live session are refused (`Locked`): they migrate when they load.
function Admin.migrate(self: AdminImpl, key: string, options: MigrateOptions?): MigrateResult
	checkKey(key, "migrate(key)")
	return migrateKey(self, key, options or {}, PRIO)
end

--- One page of keys (ListKeysAsync).
export type KeysOptions = { prefix: string?, cursor: string?, limit: number?, timeout: number? }

function Admin.keys(self: AdminImpl, options: KeysOptions?): KeysResult
	local impl = self.impl
	local opts: KeysOptions = options or {}
	local limit = opts.limit or 50
	if type(limit) ~= "number" or limit < 1 or limit > 500 or limit % 1 ~= 0 then
		fail(`keys: limit must be a whole number between 1 and 500, got {tostring(limit)}`)
	end
	local backend = impl.backend
	local err, page = request(impl, nil, "list", PRIO, timeoutOf(opts), function(): any
		return backend.listKeys(opts.prefix, limit, opts.cursor)
	end)
	if err ~= nil then
		return { ok = false, error = err }
	end
	local result = page :: Types.KeyPage
	return { ok = true, keys = table.clone(result.keys), cursor = result.cursor }
end

--- Migrates one page of keys at background priority. Call it again with the returned cursor until `done`; persist the
--- cursor to resume after a restart. Failures are reported per key and do not stop the page.
function Admin.migrateAll(self: AdminImpl, options: MigrateAllOptions?): MigrateAllReport
	local impl = self.impl
	local opts: MigrateAllOptions = options or {}
	local limit = opts.limit or 50
	if type(limit) ~= "number" or limit < 1 or limit > 500 or limit % 1 ~= 0 then
		fail(`migrateAll: limit must be a whole number between 1 and 500, got {tostring(limit)}`)
	end
	local backend = impl.backend
	local err, page = request(impl, nil, "list", PRIO_BULK, DEFAULT_TIMEOUT, function(): any
		return backend.listKeys(opts.prefix, limit, opts.cursor)
	end)
	if err ~= nil then
		return { ok = false, error = err }
	end
	local listing = page :: Types.KeyPage
	local report = { scanned = 0, migrated = 0, upToDate = 0, skipped = 0, failed = {} :: { { key: string, error: RetrieverError } } }
	for _, key in listing.keys do
		report.scanned += 1
		local result = migrateKey(self, key, { dryRun = opts.dryRun, reason = opts.reason }, PRIO_BULK)
		if result.ok then
			if result.upToDate then
				report.upToDate += 1
			elseif result.migrated or opts.dryRun then
				report.migrated += 1 -- in a dry run: would be migrated
			end
		elseif result.error.kind == "Locked" then
			report.skipped += 1
		else
			table.insert(report.failed, { key = key, error = result.error })
		end
	end
	return {
		ok = true,
		scanned = report.scanned,
		migrated = report.migrated,
		upToDate = report.upToDate,
		skipped = report.skipped,
		failed = report.failed,
		cursor = listing.cursor,
		done = listing.cursor == nil,
	}
end

------------------------------------------------------------------------------------------------------------------------

export type AdminHandle = {
	inspect: (self: AdminHandle, key: string, options: { timeout: number? }?) -> InspectResult,
	edit: (self: AdminHandle, key: string, patch: ((data: any) -> any) | { PatchOp }, options: EditOptions?) -> EditResult,
	export: (self: AdminHandle, key: string, options: ExportOptions?) -> ExportResult,
	import: (self: AdminHandle, source: ExportedRecord | string, options: ImportOptions?) -> ImportResult,
	versions: (self: AdminHandle, key: string, options: VersionsOptions?) -> VersionsResult,
	previewRestore: (self: AdminHandle, key: string, version: string, options: { timeout: number? }?) -> PreviewResult,
	restore: (self: AdminHandle, preview: RestorePreview, options: RestoreOptions?) -> WriteResult,
	migrate: (self: AdminHandle, key: string, options: MigrateOptions?) -> MigrateResult,
	migrateAll: (self: AdminHandle, options: MigrateAllOptions?) -> MigrateAllReport,
	keys: (self: AdminHandle, options: KeysOptions?) -> KeysResult,
}

function Admin.new(impl: StoreImpl): AdminHandle
	local handle: AdminImpl = { impl = impl }
	return setmetatable(handle, Admin) :: any
end

return Admin
