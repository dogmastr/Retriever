--!strict
--[[
	Shared documents (`Retriever.documents(store)`): records that no player session owns, such as guild data or server-wide
	settings, read and updated by any number of servers. See docs/DESIGN.md (3.7, 4.12).

	Consistency
	* One key is atomic: `update(key, fn)` runs `fn` inside UpdateAsync on the stored data, so concurrent updates from many
	  servers are serialized by the backend and none is lost. On contention the engine re-runs the callback on the newer
	  value, so `fn` must be a pure transform of its input: no yields, no side effects, same output for the same input.
	* The record revision (`r`) grows by one per write. `options.revision` turns an update into a compare-and-set: it is
	  applied only while the document is still at that revision, else the result is `Conflict` with the current revision.
	* Nothing is atomic across documents. A lost race simply retries (inside the engine); there is nothing to recover.
	* Every update carries an op id that is stored in the record's idempotency ledger in the same write. When an attempt fails
	  in a way that may have been applied, the retry finds the id and reports the write as done instead of applying `fn`
	  twice. Only when no later attempt could run is the result `Unknown` (retrying with the same `options.id` is then safe).

	Storage: documents use the store's record envelope (`v`, `r`, `d`, `sv`, `mr`, `o`), so the admin tools can inspect and
	edit them, and the store's template/schema/migrations apply: missing fields are filled, every new value is checked
	against the schema, and old data is migrated (outside the callback, then installed by a revision check). A document key
	that a live session holds as a profile is refused with `Locked`.

	Reads (`get`) are served from a small per-handle cache for `cacheTtl` seconds unless `fresh = true`. With `notify = true`
	every write publishes `{ k, r }` over MessagingService and other servers drop their cached copy: best effort, it only
	shortens staleness. Nothing is allocated until a handle is created, and the cache and subscription only on first use.
]]

local Commands = require(script.Parent.Commands)
local Errors = require(script.Parent.Errors)
local Internal = require(script.Parent.Internal)
local Migrate = require(script.Parent.Migrate)
local Record = require(script.Parent.Record)
local Scheduler = require(script.Parent.Scheduler)
local Schema = require(script.Parent.Schema)
local Store = require(script.Parent.Store)
local Types = require(script.Parent.Types)
local Util = require(script.Parent.Util)
local Validate = require(script.Parent.Validate)

type StoreImpl = Internal.StoreImpl
type RetrieverError = Types.RetrieverError
type KeyInfoLike = Types.KeyInfoLike
type Rec = Types.Record

export type DocumentsOptions = {
	--- Seconds `get` serves a cached copy (default 5; 0 disables the cache).
	cacheTtl: number?,
	--- Documents kept in the cache (default 256).
	cacheMax: number?,
	--- Publish a change notice after every write and drop cached copies when other servers write. Default false.
	notify: boolean?,
	--- Default seconds to keep retrying transient failures (default 30).
	timeout: number?,
}

export type GetOptions = {
	--- Skip the cache and the engine's read cache. Default false.
	fresh: boolean?,
	timeout: number?,
}

export type UpdateOptions = {
	--- Op id stored in the document's ledger (at most 100 characters). Default: a fresh guid. Reuse it to retry an update that
	--- returned `Unknown`: an update whose id is already stored is reported as done without running `fn` again.
	id: string?,
	--- Apply only while the document is at this revision (0 = does not exist yet); otherwise `Conflict`.
	revision: number?,
	--- Create the document from the store's defaults when it does not exist. Default true; false returns `NotFound`.
	create: boolean?,
	timeout: number?,
}

--- `data` is shared with the cache: treat it as read-only and change documents through `update`.
export type GetResult<T> = { ok: true, data: T, revision: number, exists: boolean } | { ok: false, error: RetrieverError }

--- `changed` is false when `fn` left the data as it was (nothing was written) or the op id was already stored.
export type UpdateResult<T> =
	{ ok: true, data: T, revision: number, changed: boolean, created: boolean }
	| { ok: false, error: RetrieverError }

--- Transform for `update`. Runs inside UpdateAsync and may run several times: no yields, no side effects. Change `data` in
--- place (return nothing) or return a replacement table. `revision` is the revision the data was read at.
export type UpdateFn<T> = (data: T, revision: number) -> T?

export type Documents<T> = {
	--- Reads a document (defaults with `exists = false` when it does not exist). Yields on a cache miss.
	get: (self: Documents<T>, key: string, options: GetOptions?) -> GetResult<T>,
	--- The cached copy, if any, without yielding or checking its age.
	peek: (self: Documents<T>, key: string) -> (T?, number?),
	--- Atomically transforms a document. Yields.
	update: (self: Documents<T>, key: string, fn: UpdateFn<T>, options: UpdateOptions?) -> UpdateResult<T>,
	--- Drops the cached copy of `key`.
	invalidate: (self: Documents<T>, key: string) -> (),
	--- Calls `fn(key, revision)` after a write by this handle and, with `notify`, when another server reports one (best
	--- effort). Must not yield. Returns a disconnect function.
	onChanged: (self: Documents<T>, fn: (key: string, revision: number) -> ()) -> () -> (),
	--- Drops the cache and the subscription. Later calls return `ShuttingDown`.
	destroy: (self: Documents<T>) -> (),
}

type CacheEntry = { data: any, revision: number, exists: boolean, at: number }

type Handle = {
	impl: StoreImpl,
	ttl: number,
	cacheMax: number,
	notify: boolean,
	timeout: number,
	topic: string,
	cache: { [string]: CacheEntry }?,
	cacheCount: number,
	listeners: { (key: string, revision: number) -> () }?,
	subscribed: boolean,
	unsubscribe: (() -> ())?,
	destroyed: boolean,
}

type Outcome =
	"wrote"
	| "unchanged"
	| "landed"
	| "conflict"
	| "notFound"
	| "locked"
	| "corrupt"
	| "tooNew"
	| "migrate"
	| "invalid"
	| "raised"

type UpdateCtx = {
	fn: (data: any, revision: number) -> any,
	config: Internal.StoreConfigN,
	opId: string,
	expect: number?,
	create: boolean,
	now: () -> number,
	skew: number,
	debug: boolean,
	-- data migrated outside the callback, valid while the record is still at `baseRev`
	base: any,
	baseRev: number,
	-- per run
	runs: number,
	outcome: Outcome?,
	rev: number,
	data: any,
	created: boolean,
	produced: boolean,
	ownerJob: string?,
	failKind: Types.ErrorKind?,
	cause: string?,
	path: string?,
	-- the record that needs migrating (outcome "migrate")
	pending: any,
	pendingSv: number?,
}

local DEFAULT_TTL = 5
local DEFAULT_CACHE_MAX = 256
local DEFAULT_TIMEOUT = 30
local PRIO = 2
local MAX_ID = 100
local MIGRATE_ROUNDS = 3

local Documents = {}
Documents.__index = Documents

local function fail(message: string, level: number?): never
	error(`[Retriever] documents: {message}`, (level or 2) + 1)
end

local function checkKey(key: any, what: string)
	if type(key) ~= "string" or key == "" or #key > 50 then
		fail(`{what} needs a non-empty key of at most 50 characters, got {typeof(key)} "{tostring(key)}"`, 3)
	end
end

local function never(): boolean
	return false
end

local function problem(self: Handle, kind: Types.ErrorKind, key: string, cause: string?, details: { [string]: any }?): RetrieverError
	return Errors.new(kind, self.impl.name, key, cause, details)
end

local function timeoutOf(self: Handle, options: { timeout: number? }?): number
	return if options ~= nil and options.timeout ~= nil then options.timeout else self.timeout
end

------------------------------------------------------------------------------------------------------------------------
-- cache and notifications
------------------------------------------------------------------------------------------------------------------------

local function remember(self: Handle, key: string, data: any, revision: number, exists: boolean)
	if self.ttl <= 0 then
		return
	end
	local cache = self.cache
	if cache == nil then
		cache = {}
		self.cache = cache
	end
	local map = cache :: { [string]: CacheEntry }
	local entry = map[key]
	if entry ~= nil then
		if revision < entry.revision then
			return -- a newer copy is already cached
		end
		entry.data = data
		entry.revision = revision
		entry.exists = exists
		entry.at = self.impl.runtime.env.clock()
		return
	end
	if self.cacheCount >= self.cacheMax then
		-- evict the oldest entry (linear scan; the cache is small)
		local oldestKey, oldestAt = nil :: string?, math.huge
		for k, e in map do
			if e.at < oldestAt then
				oldestKey, oldestAt = k, e.at
			end
		end
		if oldestKey ~= nil then
			map[oldestKey] = nil
			self.cacheCount -= 1
		end
	end
	map[key] = { data = data, revision = revision, exists = exists, at = self.impl.runtime.env.clock() }
	self.cacheCount += 1
end

local function forget(self: Handle, key: string, below: number?)
	local cache = self.cache
	local entry = if cache ~= nil then cache[key] else nil
	if entry ~= nil and (below == nil or entry.revision < below) then
		(cache :: { [string]: CacheEntry })[key] = nil
		self.cacheCount -= 1
	end
end

local function fire(self: Handle, key: string, revision: number)
	local listeners = self.listeners
	if listeners == nil then
		return
	end
	local env = self.impl.runtime.env
	for _, fn in table.clone(listeners) do
		local ok, err = pcall(fn :: any, key, revision)
		if not ok then
			env.log("warn", `[Retriever] documents onChanged listener raised: {tostring(err)}`)
		end
	end
end

local function onMessage(self: Handle, message: any)
	if self.destroyed or type(message) ~= "table" then
		return
	end
	local msg = message :: any
	-- MessagingService wraps the payload in { Data, Sent }; fakes may deliver it bare
	if type(msg.Data) == "table" then
		msg = msg.Data
	end
	local key, revision = msg.k, msg.r
	if type(key) ~= "string" or type(revision) ~= "number" or msg.j == self.impl.runtime.env.jobId then
		return
	end
	forget(self, key, revision)
	fire(self, key, revision)
end

local function ensureSubscribed(self: Handle)
	if not self.notify or self.subscribed or self.destroyed then
		return
	end
	local env = self.impl.runtime.env
	local messaging = env.messaging
	if messaging == nil then
		return
	end
	self.subscribed = true
	env.spawn(function()
		local ok, result = pcall(messaging.subscribe, self.topic, function(message: any)
			onMessage(self, message)
		end)
		if not ok then
			self.subscribed = false -- try again on the next call
			env.log("warn", `[Retriever] documents could not subscribe to change notices (reads rely on cacheTtl): {tostring(result)}`)
		elseif self.destroyed then
			pcall(result)
		else
			self.unsubscribe = result
		end
	end)
end

local function announce(self: Handle, key: string, revision: number)
	if self.notify then
		local env = self.impl.runtime.env
		local messaging = env.messaging
		if messaging ~= nil then
			local payload = { k = key, r = revision, j = env.jobId }
			env.spawn(function()
				xpcall(messaging.publish, function(err: any): any
					env.log("debug", `[Retriever] documents change notice failed (other servers rely on cacheTtl): {tostring(err)}`)
					return err
				end, self.topic, payload)
			end)
		end
	end
	fire(self, key, revision)
end

------------------------------------------------------------------------------------------------------------------------
-- read
------------------------------------------------------------------------------------------------------------------------

--- Decodes a stored value into (error, data, revision, exists). Migrates and fills a copy; never touches the record.
local function decode(self: Handle, key: string, value: any): (RetrieverError?, any, number, boolean)
	local config = self.impl.config
	if value == nil then
		return nil, Migrate.defaults(config), 0, false
	end
	if not Record.isEnvelope(value) or (value :: Rec).v > Record.VERSION then
		return problem(self, "Corrupt", key), nil, 0, false
	end
	local rec = value :: Rec
	if rec.mr ~= nil and rec.mr > config.schemaVersion then
		return problem(self, "SchemaTooNew", key, nil, { minReader = rec.mr, schemaVersion = config.schemaVersion }), nil, 0, false
	end
	if rec.d == nil then
		return nil, Migrate.defaults(config), rec.r, false
	end
	local prepared = Migrate.prepare(config, Util.deepCopy(rec.d), rec.sv)
	if prepared.ok == false then
		return problem(self, prepared.kind, key, prepared.cause, { step = prepared.step, path = prepared.path }), nil, 0, false
	end
	return nil, prepared.data, rec.r, true
end

function Documents.get(self: Handle, key: string, options: GetOptions?): GetResult<any>
	checkKey(key, "get(key)")
	if self.destroyed or self.impl.runtime.destroyed then
		return { ok = false, error = problem(self, "ShuttingDown", key, "the documents handle was destroyed") }
	end
	ensureSubscribed(self)
	local runtime = self.impl.runtime
	local env = runtime.env
	local fresh = options ~= nil and options.fresh == true
	if not fresh then
		local cache = self.cache
		local entry = if cache ~= nil then cache[key] else nil
		if entry ~= nil and env.clock() - entry.at < self.ttl then
			return { ok = true, data = entry.data, revision = entry.revision, exists = entry.exists }
		end
	end
	local backend = self.impl.backend
	local err, _, packed = Commands.retrying(self.impl, key, "get", PRIO, function(): any
		local value = backend.get(key, not fresh)
		return { value = value }
	end, never, env.clock() + timeoutOf(self, options), Scheduler.newSleeper(runtime.scheduler), nil)
	if err ~= nil then
		return { ok = false, error = err }
	end
	local decodeErr, data, revision, exists = decode(self, key, (packed :: any).value)
	if decodeErr ~= nil then
		return { ok = false, error = decodeErr }
	end
	remember(self, key, data, revision, exists)
	return { ok = true, data = data, revision = revision, exists = exists }
end

function Documents.peek(self: Handle, key: string): (any, number?)
	local cache = self.cache
	local entry = if cache ~= nil then cache[key] else nil
	if entry == nil then
		return nil, nil
	end
	return entry.data, entry.revision
end

function Documents.invalidate(self: Handle, key: string)
	forget(self, key, nil)
end

------------------------------------------------------------------------------------------------------------------------
-- update
------------------------------------------------------------------------------------------------------------------------

local function passThroughMeta(info: KeyInfoLike?): ({ number }?, { [string]: any }?)
	if info == nil then
		return nil, nil
	end
	return info:GetUserIds(), info:GetMetadata()
end

--- The ledger with `opId` added, pruned by age and size. A new table: `old` is never modified, so replays are harmless.
local function ledgerWith(old: { [string]: number }?, opId: string, now: number, config: Internal.StoreConfigN): ({ [string]: number }, number?)
	local ledger: { [string]: number } = {}
	local count = 0
	local horizon: number? = nil
	local cutoff = now - config.ledgerRetention
	if old ~= nil then
		for id, t in old do
			if t >= cutoff then
				ledger[id] = t
				count += 1
			elseif horizon == nil or t > horizon then
				horizon = t
			end
		end
	end
	while count >= config.ledgerMax do
		local oldestId, oldestT = nil :: string?, math.huge
		for id, t in ledger do
			if t < oldestT then
				oldestId, oldestT = id, t
			end
		end
		if oldestId == nil then
			break
		end
		ledger[oldestId] = nil
		count -= 1
		if horizon == nil or oldestT > horizon then
			horizon = oldestT
		end
	end
	ledger[opId] = now
	return ledger, horizon
end

local function maxOf(a: number?, b: number?): number?
	if a == nil then
		return b
	elseif b == nil then
		return a
	end
	return math.max(a, b)
end

--- UpdateAsync transform. Pure apart from `ctx` (reset on every run) and `ctx.fn`, which must be pure itself.
local function transform(old: any, info: KeyInfoLike?, ctx: UpdateCtx): (any, { number }?, { [string]: any }?)
	ctx.runs += 1
	ctx.outcome = nil
	ctx.data = nil
	ctx.created = false
	ctx.ownerJob = nil
	ctx.failKind = nil
	ctx.cause = nil
	ctx.path = nil
	ctx.pending = nil
	local config = ctx.config
	local now = ctx.now()
	local rec = old :: Rec?
	local rev = 0
	if rec ~= nil then
		if not Record.isEnvelope(rec) or rec.v > Record.VERSION then
			ctx.outcome = "corrupt"
			return nil
		end
		local ledger = rec.o
		if ledger ~= nil and ledger[ctx.opId] ~= nil then
			ctx.outcome = "landed"
			ctx.rev = rec.r
			ctx.data = rec.d
			return nil
		end
		if rec.mr ~= nil and rec.mr > config.schemaVersion then
			ctx.outcome = "tooNew"
			ctx.rev = rec.mr
			return nil
		end
		local lock = rec.l
		if lock ~= nil and now < lock.x + ctx.skew then
			ctx.outcome = "locked"
			ctx.ownerJob = lock.j
			return nil
		end
		rev = rec.r
	end
	ctx.rev = rev
	if ctx.expect ~= nil and rev ~= ctx.expect then
		ctx.outcome = "conflict"
		return nil
	end

	local data: any
	local stored = if rec ~= nil then rec.d else nil
	if stored == nil then
		if not ctx.create then
			ctx.outcome = "notFound"
			return nil
		end
		data = Migrate.defaults(config)
		ctx.created = true
	elseif ctx.base ~= nil and ctx.baseRev == rev then
		data = Util.deepCopy(ctx.base)
	else
		local sv = (rec :: Rec).sv
		if (sv or 1) < config.schemaVersion then
			-- migrations may be slow and must never be replayed by the engine: run them outside, then come back
			ctx.outcome = "migrate"
			ctx.pending = stored
			ctx.pendingSv = sv
			return nil
		end
		-- no migration step runs here: only fill and schema check on a copy (both pure)
		local prepared = Migrate.prepare(config, Util.deepCopy(stored), sv)
		if prepared.ok == false then
			ctx.outcome = "invalid"
			ctx.failKind = prepared.kind
			ctx.cause = prepared.cause
			ctx.path = prepared.path
			return nil
		end
		data = prepared.data
	end

	local ok, result = pcall(ctx.fn, data, rev)
	if not ok then
		ctx.outcome = "raised"
		ctx.cause = tostring(result)
		return nil
	end
	if result == nil then
		result = data
	elseif type(result) ~= "table" then
		ctx.outcome = "raised"
		ctx.cause = `the update function must change the table in place or return a table, got {typeof(result)}`
		return nil
	end
	local schema = config.schema
	if schema ~= nil then
		local called, valid, message = pcall(schema.check, schema, result)
		if not called or not valid then
			local text = if called then message or "does not match the schema" else `the schema raised an error: {tostring(valid)}`
			ctx.outcome = "invalid"
			ctx.failKind = "InvalidData"
			ctx.cause = text
			ctx.path = Schema.pathOf(text)
			return nil
		end
	end
	if ctx.debug then
		local storable, why = Validate.storable(result)
		if not storable then
			ctx.outcome = "invalid"
			ctx.failKind = "InvalidData"
			ctx.cause = why
			ctx.path = Schema.pathOf(why)
			return nil
		end
	end
	if not ctx.created and Util.deepEqual(result, stored) then
		ctx.outcome = "unchanged"
		ctx.data = result
		return nil
	end

	local fresh: Rec
	if rec ~= nil then
		fresh = table.clone(rec)
		if rec.l ~= nil then
			-- an expired lease: fence the session that held it so its late release cannot overwrite this write
			fresh.l = nil
			fresh.e = rec.e + 1
		end
	else
		-- see Admin.casTransform: a key that existed before may have issued any epoch, so start above all of them
		fresh = { v = Record.VERSION, r = 0, e = math.max(1, math.floor(now * 1000)) } :: any
	end
	fresh.d = result
	fresh.r = rev + 1
	fresh.sv = math.max(if rec ~= nil and rec.sv ~= nil then rec.sv else 1, config.schemaVersion)
	fresh.mr = maxOf(if rec ~= nil then rec.mr else nil, config.minReader)
	local horizon
	fresh.o, horizon = ledgerWith(if rec ~= nil then rec.o else nil, ctx.opId, now, config)
	if horizon ~= nil then
		fresh.oh = maxOf(fresh.oh, horizon)
	end
	if fresh.c == nil then
		fresh.c = now
	end
	ctx.outcome = "wrote"
	ctx.rev = fresh.r
	ctx.data = result
	ctx.produced = true
	return fresh, passThroughMeta(info)
end

local function outcomeError(self: Handle, key: string, ctx: UpdateCtx): RetrieverError
	local outcome = ctx.outcome
	if outcome == "conflict" then
		return problem(self, "Conflict", key, nil, { expectedRevision = ctx.expect, revision = ctx.rev })
	elseif outcome == "notFound" then
		return problem(self, "NotFound", key, nil, { what = "Pass create = true (the default for documents) to create it." })
	elseif outcome == "locked" then
		return problem(self, "Locked", key, nil, {
			what = "A player session holds this key; shared documents must use keys that are never loaded as profiles.",
			ownerJob = ctx.ownerJob,
		})
	elseif outcome == "corrupt" then
		return problem(self, "Corrupt", key)
	elseif outcome == "tooNew" then
		return problem(self, "SchemaTooNew", key, nil, { minReader = ctx.rev, schemaVersion = ctx.config.schemaVersion })
	elseif outcome == "raised" then
		return problem(self, "InvalidArgument", key, ctx.cause, { what = "The update function raised or returned a bad value; it must not yield." })
	end
	return problem(self, ctx.failKind or "InvalidData", key, ctx.cause, { path = ctx.path })
end

function Documents.update(self: Handle, key: string, fn: UpdateFn<any>, options: UpdateOptions?): UpdateResult<any>
	checkKey(key, "update(key, fn)")
	if type(fn) ~= "function" then
		fail(`update("{key}", fn) needs a function (data, revision) -> data?`)
	end
	local opts: UpdateOptions = options or {}
	local id = opts.id
	if id ~= nil and (type(id) ~= "string" or id == "" or #id > MAX_ID) then
		fail(`update: options.id must be a non-empty string of at most {MAX_ID} characters, got {typeof(id)} "{tostring(id)}"`)
	end
	local expect = opts.revision
	if expect ~= nil and (type(expect) ~= "number" or expect < 0 or expect % 1 ~= 0) then
		fail(`update: options.revision must be a non-negative integer, got {tostring(expect)}`)
	end
	local impl = self.impl
	local runtime = impl.runtime
	if self.destroyed or runtime.destroyed then
		return { ok = false, error = problem(self, "ShuttingDown", key, "the documents handle was destroyed") }
	end
	ensureSubscribed(self)
	local env = runtime.env
	local config = impl.config
	local ctx: UpdateCtx = {
		fn = fn,
		config = config,
		opId = if id ~= nil then id else env.guid(),
		expect = expect,
		create = opts.create ~= false,
		now = env.time,
		skew = runtime.options.clockSkew,
		debug = config.debug,
		base = nil,
		baseRev = -1,
		runs = 0,
		outcome = nil,
		rev = 0,
		data = nil,
		created = false,
		produced = false,
		ownerJob = nil,
		failKind = nil,
		cause = nil,
		path = nil,
		pending = nil,
		pendingSv = nil,
	}
	local backend = impl.backend
	local function callback(old: any, info: KeyInfoLike?)
		return transform(old, info, ctx)
	end
	local function call(): any
		ctx.runs = 0
		return (backend.update(key, callback))
	end
	local function produced(): boolean
		return ctx.runs > 0 and ctx.outcome == "wrote"
	end
	local deadline = env.clock() + timeoutOf(self, opts)
	local sleeper = Scheduler.newSleeper(runtime.scheduler)
	for _ = 1, MIGRATE_ROUNDS do
		local err = Commands.retrying(impl, key, "update", PRIO, call, produced, deadline, sleeper, nil)
		if err ~= nil then
			return { ok = false, error = err }
		end
		local outcome = ctx.outcome
		if outcome == nil then
			return {
				ok = false,
				error = problem(self, if ctx.produced then "Unknown" else "Unavailable", key, "UpdateAsync returned without running the transform callback"),
			}
		end
		if outcome == "migrate" then
			local prepared = Migrate.prepare(config, Util.deepCopy(ctx.pending), ctx.pendingSv)
			ctx.pending = nil
			if prepared.ok == false then
				return { ok = false, error = problem(self, prepared.kind, key, prepared.cause, { step = prepared.step, path = prepared.path }) }
			end
			ctx.base = prepared.data
			ctx.baseRev = ctx.rev
		elseif outcome == "wrote" or outcome == "landed" or outcome == "unchanged" then
			local data = ctx.data
			if outcome == "landed" then
				-- an earlier attempt of this update was applied: report the current document
				local decodeErr, decoded, revision = decode(self, key, { v = Record.VERSION, r = ctx.rev, e = 0, sv = config.schemaVersion, d = data })
				if decodeErr == nil then
					data = decoded
					ctx.rev = revision
				end
			end
			remember(self, key, data, ctx.rev, true)
			if outcome ~= "unchanged" then
				announce(self, key, ctx.rev)
			end
			return { ok = true, data = data, revision = ctx.rev, changed = outcome == "wrote", created = ctx.created }
		else
			return { ok = false, error = outcomeError(self, key, ctx) }
		end
	end
	return {
		ok = false,
		error = problem(self, "Conflict", key, nil, { what = "The document kept changing while its migration ran; try again.", revision = ctx.rev }),
	}
end

------------------------------------------------------------------------------------------------------------------------
-- lifecycle
------------------------------------------------------------------------------------------------------------------------

function Documents.onChanged(self: Handle, fn: (key: string, revision: number) -> ()): () -> ()
	if type(fn) ~= "function" then
		fail("onChanged(fn) needs a function (key, revision) -> ()")
	end
	local listeners = self.listeners
	if listeners == nil then
		listeners = {}
		self.listeners = listeners
	end
	table.insert(listeners :: { (key: string, revision: number) -> () }, fn)
	ensureSubscribed(self)
	return function()
		local list = self.listeners
		if list == nil then
			return
		end
		local index = table.find(list, fn)
		if index ~= nil then
			table.remove(list, index)
		end
		if #list == 0 then
			self.listeners = nil
		end
	end
end

function Documents.destroy(self: Handle)
	if self.destroyed then
		return
	end
	self.destroyed = true
	self.cache = nil
	self.cacheCount = 0
	self.listeners = nil
	local unsubscribe = self.unsubscribe
	self.unsubscribe = nil
	if unsubscribe ~= nil then
		pcall(unsubscribe)
	end
end

local Module = {}

--- `Retriever.documents(store, options)`: a handle for shared documents stored in `store`'s DataStore. Use keys that are
--- never loaded as player profiles (a separate store is simplest). Create one handle per store and share it.
function Module.new<T>(store: Types.Store<T>, options: DocumentsOptions?): Documents<T>
	if getmetatable(store :: any) ~= Store then
		error(`[Retriever] Retriever.documents(store) needs a store created with Retriever.store or runtime:store, got {typeof(store)}`, 3)
	end
	local impl = (store :: any) :: StoreImpl
	local opts: DocumentsOptions = options or {}
	local ttl = if opts.cacheTtl ~= nil then opts.cacheTtl else DEFAULT_TTL
	local cacheMax = if opts.cacheMax ~= nil then opts.cacheMax else DEFAULT_CACHE_MAX
	local timeout = if opts.timeout ~= nil then opts.timeout else DEFAULT_TIMEOUT
	if type(ttl) ~= "number" or ttl < 0 then
		fail(`options.cacheTtl must be a non-negative number of seconds, got {tostring(ttl)}`)
	end
	if type(cacheMax) ~= "number" or cacheMax < 1 then
		fail(`options.cacheMax must be at least 1, got {tostring(cacheMax)}`)
	end
	if type(timeout) ~= "number" or timeout <= 0 then
		fail(`options.timeout must be a positive number of seconds, got {tostring(timeout)}`)
	end
	local handle: Handle = {
		impl = impl,
		ttl = ttl,
		cacheMax = cacheMax,
		notify = opts.notify == true,
		timeout = timeout,
		topic = string.sub(`RD:{impl.name}:{impl.scope or ""}`, 1, 80),
		cache = nil,
		cacheCount = 0,
		listeners = nil,
		subscribed = false,
		unsubscribe = nil,
		destroyed = false,
	}
	return setmetatable(handle :: any, Documents) :: any
end

return Module
