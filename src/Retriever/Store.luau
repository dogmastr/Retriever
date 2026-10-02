--!strict
--[[
	A store: one DataStore name (+scope) with its configuration, the sessions open on this server and the loader.

	Loading is a lane operation made of single attempts. Each attempt is one UpdateAsync whose callback (`Record.acquire`)
	atomically decides: create, acquire, report "locked", or refuse (corrupt / newer schema). Waiting for a lock never sleeps
	inside a worker: a locked or failed attempt arms the request's own heap entry and returns.
]]

local Dispatcher = require(script.Parent.Dispatcher)
local Classify = require(script.Parent.Classify)
local Commands = require(script.Parent.Commands)
local Errors = require(script.Parent.Errors)
local Events = require(script.Parent.Events)
local Handoff = require(script.Parent.Handoff)
local Internal = require(script.Parent.Internal)
local Lane = require(script.Parent.Lane)
local Histogram = require(script.Parent.Histogram)
local Migrate = require(script.Parent.Migrate)
local Patch = require(script.Parent.Patch)
local Profile = require(script.Parent.Profile)
local Record = require(script.Parent.Record)
local Scheduler = require(script.Parent.Scheduler)
local Types = require(script.Parent.Types)
local Validate = require(script.Parent.Validate)

type StoreImpl = Internal.StoreImpl
type ProfileImpl = Internal.ProfileImpl
type Runtime = Internal.Runtime
type RetrieverError = Types.RetrieverError
type LoadResult<T> = Types.LoadResult<T>

local Store = {}
Store.__index = Store

local POLL_DELAYS = { 0.5, 1, 2, 4, 8 }
local DEFAULT_LOAD_TIMEOUT = 90

------------------------------------------------------------------------------------------------------------------------
-- configuration
------------------------------------------------------------------------------------------------------------------------

local PRESETS: { [string]: Types.Durability } = {
	economy = { autosave = 300, lease = 1800, steal = 45 },
	balanced = { autosave = 60, lease = 900, steal = 45 },
	strict = { autosave = 15, lease = 600, steal = 45 },
}

local function fail(message: string): never
	error(`[Retriever] {message}`, 3)
end

local function normalize(name: string, config: Types.StoreConfig<any>, isStudio: boolean): Internal.StoreConfigN
	if type(name) ~= "string" or name == "" then
		fail("store name must be a non-empty string, for example Retriever.store(\"PlayerData\", { template = { coins = 0 } })")
	end
	if #name > 50 then
		fail(`store name "{name}" is longer than 50 characters (DataStore limit)`)
	end

	local durability: Types.Durability
	local given = config.durability
	if type(given) == "string" then
		local preset = PRESETS[given]
		if preset == nil then
			fail(`unknown durability preset "{given}"; use "economy", "balanced", "strict" or a table like \{ autosave = 60, lease = 900 }`)
		end
		durability = preset
	elseif given == nil then
		durability = PRESETS.balanced
	else
		durability = given
	end

	local autosave = durability.autosave or 60
	local lease = durability.lease or 900
	local stealOption = durability.steal
	local steal: number? = 45
	if stealOption == false then
		steal = nil
	elseif type(stealOption) == "number" then
		steal = stealOption
	end
	if type(autosave) ~= "number" or autosave ~= autosave or autosave < 1 or autosave > 3600 then
		fail(`durability.autosave must be between 1 and 3600 seconds, got {tostring(autosave)}`)
	end
	if type(lease) ~= "number" or lease ~= lease or lease < 60 then
		fail(`durability.lease must be at least 60 seconds (it has to outlive clock skew and slow requests), got {tostring(lease)}`)
	end
	if steal ~= nil and (steal ~= steal or steal < 0) then
		fail(`durability.steal must be a number of seconds >= 0 or false (never steal), got {tostring(steal)}`)
	end

	local migrations = config.migrations or {}
	if type(migrations) ~= "table" then
		fail(`migrations must be a list of \{ version = 2, up = function(data) ... return data end }, got {typeof(migrations)}`)
	end
	for i, migration in migrations :: { any } do
		if type(migration) ~= "table" or type(migration.version) ~= "number" or type(migration.up) ~= "function" then
			fail(`migration #{i} must be a table \{ version = <number>, up = function(data) ... return data end }`)
		end
		local compat = migration.compat
		if compat ~= nil and compat ~= "breaking" and compat ~= "forward" then
			fail(`migration to version {migration.version}: compat must be "breaking" or "forward", got {tostring(compat)}`)
		end
	end
	local sorted = table.clone(migrations)
	table.sort(sorted, function(a: Types.Migration<any>, b: Types.Migration<any>)
		return a.version < b.version
	end)
	local schemaVersion = 1
	local minReader: number? = nil
	for i, migration in sorted do
		if migration.version ~= i + 1 then
			fail(`migrations must be consecutive starting at version 2; migration #{i} has version {migration.version}`)
		end
		schemaVersion = migration.version
		if migration.compat ~= "forward" then
			minReader = migration.version
		end
	end

	local schema = config.schema
	if schema ~= nil then
		local s = schema :: any
		if type(s) ~= "table" or type(s.check) ~= "function" or type(s.defaults) ~= "function" or type(s.fill) ~= "function" then
			fail("schema must be built with Retriever.schema (for example S.struct({ coins = S.integer(0) })) or implement check, defaults and fill")
		end
		if config.template ~= nil then
			fail("pass either template or schema, not both: the schema already provides the defaults (schema:defaults())")
		end
		local defaults = s:defaults()
		if type(defaults) ~= "table" then
			fail(`the schema must describe a table (S.struct, S.map or S.array): its defaults are a {typeof(defaults)}`)
		end
	end

	local snapshot = config.snapshot
	if snapshot == nil then
		snapshot = "reference"
	elseif snapshot ~= "reference" and snapshot ~= "copy" then
		fail(`snapshot must be "reference" or "copy", got {tostring(snapshot)}`)
	end
	local studio = config.studio
	if studio ~= nil and studio ~= "prefix" and studio ~= "live" then
		fail(`studio must be "prefix" or "live", got {tostring(studio)}`)
	end

	local commands = config.commands
	local inboxMax, outboxMax = 100, 100
	if commands ~= nil then
		if type(commands) ~= "table" then
			fail(`commands must be a table like \{ inboxMax = 100, outboxMax = 100 }, got {typeof(commands)}`)
		end
		local function limit(value: any, field: string, default: number): number
			if value == nil then
				return default
			end
			if type(value) ~= "number" or value ~= value or value < 1 or value > 1000 or value % 1 ~= 0 then
				fail(`commands.{field} must be a whole number between 1 and 1000, got {tostring(value)}`)
			end
			return value
		end
		inboxMax = limit(commands.inboxMax, "inboxMax", 100)
		outboxMax = limit(commands.outboxMax, "outboxMax", 100)
	end

	local ledger = config.ledger
	if ledger ~= nil then
		-- a ledger of size 0 would forget the id it just recorded, silently turning exactly-once into at-least-once
		if type(ledger) ~= "table" then
			fail(`ledger must be a table like \{ max = 200, retention = 2592000 }, got {typeof(ledger)}`)
		end
		local max, retention = ledger.max, ledger.retention
		if max ~= nil and (type(max) ~= "number" or max ~= max or max < 1 or max % 1 ~= 0) then
			fail(`ledger.max must be a whole number >= 1, got {tostring(max)}`)
		end
		if retention ~= nil and (type(retention) ~= "number" or retention ~= retention or retention <= 0) then
			fail(`ledger.retention must be a positive number of seconds, got {tostring(retention)}`)
		end
	end
	return {
		template = config.template,
		schema = config.schema,
		migrations = sorted,
		schemaVersion = schemaVersion,
		minReader = minReader,
		autosave = autosave,
		lease = lease,
		steal = steal,
		ledgerMax = if ledger ~= nil and ledger.max ~= nil then ledger.max else 200,
		ledgerRetention = if ledger ~= nil and ledger.retention ~= nil then ledger.retention else 30 * 86400,
		debug = if config.debug ~= nil then config.debug else isStudio,
		snapshot = snapshot :: "reference" | "copy",
		inboxMax = inboxMax,
		outboxMax = outboxMax,
	}
end

--- Validates a store configuration and fills in its defaults (also used by tools such as `Retriever.dryRun`).
Store.normalize = normalize

local STUDIO_PREFIX = "studio_"

--- Studio live-data guard: decides which scope a store really opens. Outside Studio, or when Studio runs on a provider that
--- cannot reach production (the in-memory fallback), the configured scope is used unchanged. In Studio with live access the
--- developer must choose: `studio = "prefix"` isolates test data in its own scope, `studio = "live"` uses production data.
local function effectiveScope(env: Types.Env, name: string, config: Types.StoreConfig<any>): string?
	local scope = config.scope
	if not env.isStudio then
		return scope
	end
	local isLive = env.provider.isLive
	if isLive ~= nil and not isLive() then
		return scope
	end
	local choice = config.studio
	if choice == "live" then
		env.log("warn", `[Retriever] store "{name}" uses LIVE production data in Studio (studio = "live"). Saves made in this play session overwrite real players' data.`)
		return scope
	elseif choice == "prefix" then
		local isolated = STUDIO_PREFIX .. (scope or "global")
		if #isolated > 50 then
			fail(`store "{name}": the Studio scope "{isolated}" is longer than 50 characters (DataStore limit); use a shorter scope`)
		end
		env.log("info", `[Retriever] store "{name}" uses the Studio test scope "{isolated}" instead of production data.`)
		return isolated
	end
	return fail(
		`store "{name}": refusing to open production data from Studio. A Studio play session would load and overwrite real players' saves. `
			.. `Pass studio = "prefix" to use an isolated test scope ("{STUDIO_PREFIX}{scope or "global"}"), studio = "live" to use production data on purpose, `
			.. `or turn off 'Studio Access to API Services' to run on an in-memory store.`
	)
end

local function newCounters(): Internal.Counters
	return {
		requestsGet = 0,
		requestsUpdate = 0,
		requestsSet = 0,
		requestsList = 0,
		requestsGetVersion = 0,
		retries = 0,
		failures = 0,
		savesWritten = 0,
		savesSkippedClean = 0,
		commitsConfirmed = 0,
		commitsUnknown = 0,
		coalesced = 0,
		ownershipLost = 0,
		sessionsOpened = 0,
		sessionsClosed = 0,
		loadsFailed = 0,
		handoffWaits = 0,
		steals = 0,
	}
end

function Store.new(runtime: Runtime, name: string, config: Types.StoreConfig<any>): StoreImpl
	local env = runtime.env
	local normalized = normalize(name, config, env.isStudio)
	local validate: ((data: any) -> (boolean, string?))? = nil
	if normalized.debug then
		local schema = normalized.schema
		validate = function(data: any): (boolean, string?)
			local ok, message = Validate.storable(data)
			if not ok then
				return false, message
			end
			if schema ~= nil then
				-- a custom schema that raises reports invalid data instead of failing the write as an engine error
				local called, valid, why = pcall(schema.check, schema, data)
				if not called then
					return false, `the schema raised an error: {tostring(valid)}`
				end
				return valid, why
			end
			return true, nil
		end
	end
	local codec = config.codec
	if codec ~= nil then
		local c = codec :: any
		if type(c) ~= "table" or type(c.id) ~= "string" or type(c.version) ~= "number" or type(c.encode) ~= "function" or type(c.decode) ~= "function" then
			fail("codec must be a codec such as Retriever.codec.lz or one returned by Retriever.codec.register({ id, version, encode, decode })")
		end
	end
	local scope = effectiveScope(env, name, config)
	local impl: StoreImpl = setmetatable({
		name = name,
		scope = scope,
		runtime = runtime,
		backend = env.provider.open(name, scope),
		config = normalized,
		profiles = {},
		lanes = {},
		policy = {
			jobId = env.jobId,
			lease = normalized.lease,
			now = env.time,
			schemaVersion = normalized.schemaVersion,
			validate = validate,
			copy = normalized.snapshot == "copy",
			codec = codec,
		},
		counters = newCounters(),
		sessions = 0,
		pendingLoads = 0,
		-- the built-in handler applies declarative admin patches routed to the owner (Retriever.admin(store):edit)
		commandHandlers = { [Patch.COMMAND] = Patch.handler },
		hooks = Commands.hooks, -- inbox consumption and outbox delivery; near-free while commands are unused
		waiting = nil,
	}, Store) :: any
	return impl
end

------------------------------------------------------------------------------------------------------------------------
-- loading
------------------------------------------------------------------------------------------------------------------------

type LoadReq = {
	-- Dispatcher.Job
	prio: number,
	kind: Types.BudgetKind,
	queued: boolean,
	run: (self: LoadReq) -> (),
	-- Scheduler.Timer (retry / poll wake-up)
	due: number,
	heapIndex: number,
	fire: (self: LoadReq) -> (),
	thread: thread?,

	impl: StoreImpl,
	key: string,
	lane: Lane.Lane,
	options: Types.LoadOptions,
	ctx: Record.AcquireCtx,
	cb: Types.TransformFn,
	callerThread: thread,
	parked: boolean,
	result: LoadResult<any>?,
	startedAt: number,
	deadline: number,
	attempts: number, -- consecutive request failures
	polls: number, -- lock-held observations
	sawLocked: boolean,
	polling: boolean, -- true: the next attempt is a cheap GetAsync poll instead of an acquire
	released: boolean, -- a "released" message arrived while an attempt was in flight (Handoff): the next lock poll runs at once
	lastCause: string?,
	handedOver: boolean, -- lane ownership passed to a Profile
	finished: boolean,
}

local function loadError(req: LoadReq, kind: Types.ErrorKind, cause: string?, details: { [string]: any }?): LoadResult<any>
	return { ok = false, error = Errors.new(kind, req.impl.name, req.key, cause, details) }
end

local function finish(req: LoadReq, result: LoadResult<any>)
	if req.finished then
		return
	end
	req.finished = true
	local impl = req.impl
	local runtime = impl.runtime
	Scheduler.cancel(runtime.scheduler, req :: any)
	impl.pendingLoads -= 1
	local waiting = impl.waiting
	if waiting ~= nil and waiting[req.key] == req then
		waiting[req.key] = nil
		if next(waiting) == nil then
			impl.waiting = nil
		end
	end
	local seconds = runtime.env.clock() - req.startedAt
	if result.ok then
		Histogram.observe(runtime.metrics.load, seconds)
	else
		impl.counters.loadsFailed += 1
	end
	if runtime.events ~= nil then
		if result.ok then
			local ctx = req.ctx
			Events.emit(runtime, impl.name, req.key, "loaded", {
				seconds = seconds,
				revision = ctx.rev,
				details = { created = ctx.created, tookOver = ctx.tookOver, epoch = ctx.epoch },
			})
		else
			local problem = result.error
			Events.emit(runtime, impl.name, req.key, "loadFailed", { seconds = seconds, error = problem.kind, cause = problem.cause })
		end
	end
	if not req.handedOver then
		Lane.release(req.lane, runtime.dispatcher)
		if Lane.isIdle(req.lane) and impl.lanes[req.key] == req.lane then
			impl.lanes[req.key] = nil
		end
	end
	if req.parked then
		runtime.env.spawn(req.callerThread, result)
	else
		req.result = result
	end
end

local function pollDelay(runtime: Runtime, polls: number): number
	local base = POLL_DELAYS[math.min(polls + 1, #POLL_DELAYS)]
	return base * (0.75 + 0.25 * runtime.env.random())
end

local function backoffDelay(runtime: Runtime, attempts: number): number
	local options = runtime.options
	local delay = math.min(options.backoffCap, options.backoffBase * 2 ^ (attempts - 1))
	return delay * (0.5 + 0.5 * runtime.env.random())
end

local function armRetry(req: LoadReq, delay: number)
	local runtime = req.impl.runtime
	local clock = runtime.env.clock()
	local due = math.min(clock + delay, req.deadline)
	Scheduler.schedule(runtime.scheduler, req :: any, due)
end

--- Schedules the next lock poll: after the usual poll delay, or at once when the owner announced its release meanwhile.
local function armPoll(req: LoadReq)
	local delay = pollDelay(req.impl.runtime, req.polls)
	if req.released then
		req.released = false
		delay = 0
	end
	armRetry(req, delay)
end

local function cancelled(req: LoadReq): boolean
	local check = req.options.cancel
	return check ~= nil and check() == true
end

--- Releases a lock we just acquired but cannot use (cancelled, shutting down, migration failed). Hands lane ownership to a
--- throw-away session that writes only the release, so the player is never locked out by a failed load.
local function releaseUnused(req: LoadReq, rec: Types.Record?, userIds: { number }?, meta: { [string]: any }?, then_: LoadResult<any>)
	local impl = req.impl
	local profile = Profile.new(impl, req.key, req.lane, req.ctx, nil, false, rec, userIds, meta, nil)
	req.handedOver = true
	profile.endReason = "closed"
	-- Start the release first (the throw-away session becomes "closing" before anyone can look at it), then finish the original
	-- request: the caller must not wait for the release, and a load it makes right away queues behind it in the lane.
	impl.runtime.env.spawn(function()
		Profile.close(profile, { timeout = 30 })
	end)
	finish(req, then_)
end

local function normalizeList(list: { number }?): { number }?
	if list ~= nil and #list == 0 then
		return nil
	end
	return list
end

local function normalizeMap(map: { [string]: any }?): { [string]: any }?
	if map ~= nil and next(map) == nil then
		return nil
	end
	return map
end

local function onAcquired(req: LoadReq, returned: any, info: Types.KeyInfoLike?)
	local impl = req.impl
	local runtime = impl.runtime
	local ctx = req.ctx

	local userIds = if info ~= nil then normalizeList(info:GetUserIds()) else nil
	local meta = if info ~= nil then normalizeMap(info:GetMetadata()) else nil
	local rec = if type(returned) == "table" then returned :: Types.Record else nil

	if cancelled(req) then
		releaseUnused(req, rec, userIds, meta, loadError(req, "Cancelled"))
		return
	end
	if runtime.closing then
		releaseUnused(req, rec, userIds, meta, loadError(req, "ShuttingDown"))
		return
	end
	if rec == nil then
		-- UpdateAsync returned a non-table although our callback returned a record: treat as a failed attempt
		req.lastCause = "UpdateAsync returned no value after acquiring the lock"
		req.attempts += 1
		armRetry(req, backoffDelay(runtime, req.attempts))
		return
	end

	local stored = rec.d
	if rec.cd ~= nil and stored ~= nil then
		-- Encoded with a codec (Retriever.codec): decode with exactly the one that wrote it, or fail the load. The module is
		-- required only here, so stores whose records were never encoded do not load it.
		local Codec = require(script.Parent.Codec)
		local ok, decoded = Codec.decode(rec.cd, rec.cv, stored, impl.policy.codec)
		if not ok then
			releaseUnused(req, rec, userIds, meta, loadError(req, "Corrupt", decoded, { codec = rec.cd, codecVersion = rec.cv }))
			return
		end
		stored = decoded
	end
	local prepared = Migrate.prepare(impl.config, stored, rec.sv)
	if not prepared.ok then
		local details: { [string]: any }? = nil
		if prepared.step ~= nil or prepared.path ~= nil then
			details = { step = prepared.step, cause = prepared.cause, path = prepared.path }
		end
		local kind: Types.ErrorKind = prepared.kind
		local result = loadError(req, kind, prepared.cause, details)
		releaseUnused(req, rec, userIds, meta, result)
		return
	end

	local minReader = prepared.minReader
	if rec.mr ~= nil and (minReader == nil or rec.mr > minReader) then
		minReader = rec.mr
	end
	local profile = Profile.new(impl, req.key, req.lane, ctx, prepared.data, prepared.changed, rec, userIds, meta, minReader)
	req.handedOver = true
	Profile.activate(profile)
	if ctx.tookOver == "stolen" then
		impl.counters.steals += 1
	end
	Handoff.ensureSubscribed(runtime) -- once per server: contenders wake us through our own topic
	local hooks = impl.hooks
	if hooks ~= nil and hooks.afterActivate ~= nil then
		hooks.afterActivate(profile, rec)
	end
	finish(req, { ok = true, profile = profile :: any })
end

local function onLocked(req: LoadReq)
	local impl = req.impl
	local runtime = impl.runtime
	local ctx = req.ctx
	local clock = runtime.env.clock()
	req.sawLocked = true
	req.polls += 1
	impl.counters.handoffWaits += 1

	-- Register so a "released" message can end our wait early, and nudge the owner on first contact.
	local waiting: { [string]: any }
	local existingWaiting = impl.waiting
	if existingWaiting == nil then
		waiting = {}
		impl.waiting = waiting
	else
		waiting = existingWaiting
	end
	waiting[req.key] = req
	local ownerJob = ctx.ownerJob
	if ctx.outcome == "marked" and ownerJob ~= nil then
		Handoff.wakeOwner(runtime, ownerJob, impl.name, req.key)
	else
		Handoff.ensureSubscribed(runtime)
	end

	local stealAfter = impl.config.steal
	if stealAfter ~= nil and clock - req.startedAt >= stealAfter then
		ctx.steal = true
	end
	-- from now on poll with uncached reads (one read unit) and only try the acquire when the lock looks free
	req.polling = true
	req.kind = "get"
	armPoll(req)
end

--- A poll attempt: one uncached read. Either schedules the next poll or switches back to an acquire attempt.
local function runPoll(req: LoadReq)
	local impl = req.impl
	local runtime = impl.runtime
	local ctx = req.ctx
	impl.counters.requestsGet += 1
	local ok, value = pcall(impl.backend.get, req.key, false)
	if req.finished then
		return
	end
	if not ok then
		local text = tostring(value)
		req.lastCause = text
		impl.counters.failures += 1
		impl.counters.retries += 1
		req.attempts += 1
		local class = Classify.error(text)
		local delay = backoffDelay(runtime, req.attempts)
		if class.kind == "throttled" then
			Dispatcher.noteThrottle(runtime.dispatcher, "get", class.scope)
			delay = math.max(delay, if class.scope == "experience" then 5 else 2)
		elseif class.kind == "access" or class.kind == "shutdown" then
			finish(req, loadError(req, if class.kind == "access" then "StudioApiDisabled" else "ShuttingDown", text))
			return
		end
		armRetry(req, delay)
		return
	end
	req.attempts = 0

	local clock = runtime.env.clock()
	local stealAfter = impl.config.steal
	if stealAfter ~= nil and clock - req.startedAt >= stealAfter then
		ctx.steal = true
	end
	if Record.lockedByOther(value, runtime.env.jobId, runtime.env.time(), runtime.options.clockSkew, ctx.steal) then
		req.polls += 1
		impl.counters.handoffWaits += 1
		armPoll(req)
		return
	end
	-- the lock looks free (or the record is missing/odd): attempt the real acquire through the dispatcher again
	req.released = false
	req.polling = false
	req.kind = "update"
	Dispatcher.submit(runtime.dispatcher, req :: any)
end

--- One load attempt (dispatcher job).
local function runLoad(req: LoadReq)
	local impl = req.impl
	local runtime = impl.runtime
	local clock = runtime.env.clock()

	if req.finished then
		return
	end
	if cancelled(req) then
		finish(req, loadError(req, "Cancelled"))
		return
	end
	if runtime.closing then
		finish(req, loadError(req, "ShuttingDown"))
		return
	end
	if clock >= req.deadline then
		if req.sawLocked then
			finish(req, loadError(req, "Locked", req.lastCause, { ownerJob = req.ctx.ownerJob, ownerExpiry = req.ctx.ownerExpiry }))
		else
			finish(req, loadError(req, "Unavailable", req.lastCause))
		end
		return
	end

	if req.polling then
		runPoll(req)
		return
	end

	local ctx = req.ctx
	ctx.runs = 0
	impl.counters.requestsUpdate += 1
	local ok, returned, info = pcall(impl.backend.update, req.key, req.cb)
	if req.finished then
		return
	end

	if not ok then
		local text = tostring(returned)
		req.lastCause = text
		impl.counters.failures += 1
		local class = Classify.error(text)
		if class.kind == "access" then
			finish(req, loadError(req, "StudioApiDisabled", text))
		elseif class.kind == "shutdown" then
			finish(req, loadError(req, "ShuttingDown", text))
		elseif class.kind == "invalidData" or class.kind == "tooLarge" or class.kind == "permanent" then
			finish(req, loadError(req, "Corrupt", text))
		else
			req.attempts += 1
			impl.counters.retries += 1
			local delay = backoffDelay(runtime, req.attempts)
			if class.kind == "throttled" then
				Dispatcher.noteThrottle(runtime.dispatcher, req.kind, class.scope)
				delay = math.max(delay, if class.scope == "experience" then 5 else 2)
			end
			armRetry(req, delay)
		end
		return
	end
	req.attempts = 0

	local outcome = ctx.outcome
	if outcome == "acquired" then
		onAcquired(req, returned, info)
	elseif outcome == "locked" or outcome == "marked" then
		onLocked(req)
	elseif outcome == "missing" then
		finish(req, loadError(req, "NotFound"))
	elseif outcome == "corrupt" then
		finish(req, loadError(req, "Corrupt"))
	elseif outcome == "envelopeTooNew" then
		finish(req, loadError(req, "SchemaTooNew", "the record uses a newer storage format than this version of Retriever"))
	elseif outcome == "schemaTooNew" then
		finish(
			req,
			loadError(req, "SchemaTooNew", `record schema version {ctx.recordSchema}, minimum reader {ctx.recordMinReader}, this server runs {impl.config.schemaVersion}`, {
				recordSchema = ctx.recordSchema,
				minReader = ctx.recordMinReader,
				serverSchema = impl.config.schemaVersion,
			})
		)
	elseif outcome == "cancelled" then
		finish(req, loadError(req, "Cancelled"))
	else
		req.lastCause = "UpdateAsync returned without running the transform callback"
		req.attempts += 1
		armRetry(req, backoffDelay(runtime, req.attempts))
	end
end

local function fireLoad(req: LoadReq)
	if req.finished then
		return
	end
	Dispatcher.submit(req.impl.runtime.dispatcher, req :: any)
end

--- Starts a session for `key`. Yields until it is ready or definitively failed.
function Store.load(impl: StoreImpl, key: string, options: Types.LoadOptions?): LoadResult<any>
	if type(key) ~= "string" or key == "" then
		fail(`store:load(key) needs a non-empty string key, got {typeof(key)} "{tostring(key)}". Use tostring(player.UserId) for player data.`)
	end
	if #key > 50 then
		fail(`key "{key}" is longer than 50 characters (DataStore key limit)`)
	end
	local runtime = impl.runtime
	local env = runtime.env
	if runtime.closing then
		return { ok = false, error = Errors.new("ShuttingDown", impl.name, key) }
	end
	local existing = impl.profiles[key]
	if existing ~= nil and existing.state == "active" then
		return { ok = false, error = Errors.new("AlreadyLoaded", impl.name, key) }
	end

	local lane = impl.lanes[key]
	if lane == nil then
		lane = Lane.new(key)
		impl.lanes[key] = lane
	end

	local opts: Types.LoadOptions = options or {}
	local clock = env.clock()
	local ctx = Record.newAcquireCtx(env.jobId, env.placeId, env.time, impl.config.lease, impl.config.schemaVersion)
	ctx.create = opts.create ~= false
	ctx.userIds = opts.userIds
	ctx.requestHandoff = true
	ctx.isCancelled = opts.cancel
	ctx.skew = runtime.options.clockSkew

	local req: LoadReq
	req = {
		prio = 1,
		kind = "update",
		queued = false,
		run = runLoad,
		due = 0,
		heapIndex = 0,
		fire = fireLoad,
		thread = nil,

		impl = impl,
		key = key,
		lane = lane,
		options = opts,
		ctx = ctx,
		cb = function(old: any, info: Types.KeyInfoLike?)
			return Record.acquire(old, info, ctx)
		end,
		callerThread = coroutine.running(),
		parked = false,
		result = nil,
		startedAt = clock,
		deadline = clock + (opts.timeout or DEFAULT_LOAD_TIMEOUT),
		attempts = 0,
		polls = 0,
		sawLocked = false,
		polling = false,
		released = false,
		lastCause = nil,
		handedOver = false,
		finished = false,
	}
	impl.pendingLoads += 1
	Lane.submit(lane, runtime.dispatcher, req :: any)

	local immediate = req.result
	if immediate ~= nil then
		return immediate
	end
	req.parked = true
	return coroutine.yield() :: LoadResult<any>
end

------------------------------------------------------------------------------------------------------------------------
-- other store API
------------------------------------------------------------------------------------------------------------------------

function Store.get(impl: StoreImpl, key: string): ProfileImpl?
	return impl.profiles[key]
end

--- Closes every session on this server concurrently and yields until they finished or `timeout` passed.
function Store.closeAll(impl: StoreImpl, timeout: number?)
	local runtime = impl.runtime
	local env = runtime.env
	local list: { ProfileImpl } = {}
	for _, profile in impl.profiles do
		list[#list + 1] = profile
	end
	local pending = #list
	if pending == 0 then
		return
	end
	local caller = coroutine.running()
	local waiting = false
	for _, profile in list do
		env.spawn(function()
			Profile.close(profile, { timeout = timeout or 60 })
			pending -= 1
			if pending == 0 and waiting then
				env.spawn(caller)
			end
		end)
	end
	if pending > 0 then
		waiting = true
		coroutine.yield()
	end
end

function Store.stats(impl: StoreImpl): Types.StoreStats
	local c = impl.counters
	local dispatcher = impl.runtime.dispatcher
	return {
		sessions = impl.sessions,
		requests = { get = c.requestsGet, update = c.requestsUpdate, set = c.requestsSet, list = c.requestsList, getVersion = c.requestsGetVersion },
		retries = c.retries,
		failures = c.failures,
		savesWritten = c.savesWritten,
		savesSkippedClean = c.savesSkippedClean,
		commitsConfirmed = c.commitsConfirmed,
		commitsUnknown = c.commitsUnknown,
		coalesced = c.coalesced,
		ownershipLost = c.ownershipLost,
		budgetWaits = dispatcher.stats.budgetWaits,
		queueDepth = dispatcher.stats.queueDepth,
	}
end

--- Durable commands (see Commands.luau).
Store.onCommand = Commands.onCommand
Store.send = Commands.send
Store.deliverOutbox = Commands.deliverOutbox

--- True when nothing is loaded, loading, or queued for this store (used by tests to prove cleanup).
function Store.isIdle(impl: StoreImpl): boolean
	return next(impl.profiles) == nil and next(impl.lanes) == nil and impl.pendingLoads == 0
end

return Store
