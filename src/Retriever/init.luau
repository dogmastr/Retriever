--!strict
--[[
	Retriever: session-locked player data with explicit durability.

	Quick start:

		local Retriever = require(game.ServerScriptService.Retriever)

		type Data = { coins: number, items: { string } }
		local template: Data = { coins = 0, items = {} }

		local store = Retriever.store("PlayerData", { template = template, studio = "prefix" })

		Retriever.players(store, {
			onLoaded = function(player, profile)
				profile:edit(function(data)
					data.coins += 10 -- buffered: saved automatically
				end)
				local saved = profile:commit() -- optional: wait until it is durably saved
				print(player.Name, saved.ok)
			end,
		})

	Loading, saving, releasing on leave and flushing on shutdown are automatic. See README.md for usage.
]]

local Admin = require(script.Admin)
local Errors = require(script.Errors)
local Events = require(script.Events)
local Internal = require(script.Internal)
local MemoryBackend = require(script.MemoryBackend)
local Migrate = require(script.Migrate)
local Players = require(script.Players)
local Profile = require(script.Profile)
local Receipts = require(script.Receipts)
local Runtime = require(script.Runtime)
local Schema = require(script.Schema)
local Store = require(script.Store)
local Types = require(script.Types)
local UserKey = require(script.UserKey)
local Validate = require(script.Validate)

export type Env = Types.Env
export type Key = string
export type ErrorKind = Types.ErrorKind
export type RetrieverError = Types.RetrieverError
export type ProfileState = Types.ProfileState
export type EndReason = Types.EndReason
export type CommitOptions = Types.CommitOptions
export type CommitResult = Types.CommitResult
export type CloseOptions = Types.CloseOptions
export type CloseResult = Types.CloseResult
export type ApplyResult = Types.ApplyResult
export type Profile<T> = Types.Profile<T>
export type LoadOptions = Types.LoadOptions
export type LoadResult<T> = Types.LoadResult<T>
export type Durability = Types.Durability
export type DurabilityPreset = Types.DurabilityPreset
export type Migration<T> = Types.Migration<T>
export type StoreConfig<T> = Types.StoreConfig<T>
export type Schema<T> = Types.Schema<T>
export type StoreStats = Types.StoreStats
export type EnqueueOptions = Types.EnqueueOptions
export type CommandHandler<T> = Types.CommandHandler<T>
export type SendOptions = Types.SendOptions
export type SendResult = Types.SendResult
export type DeliverResult = Types.DeliverResult
export type Store<T> = Types.Store<T>
export type PlayersOptions<T> = Players.Options<T>
export type PlayersBinding<T> = Players.Binding<T>
export type ShutdownReport = Runtime.ShutdownReport
export type ReceiptInfo = Types.ReceiptInfo
export type ReceiptDecision = Types.ReceiptDecision
export type ReceiptHandler<T> = Receipts.Handler<T>
export type ReceiptsOptions = Receipts.Options
export type ReceiptsStats = Receipts.Stats
export type ReceiptsBinding = Receipts.Receipts
export type UserKeyOptions = UserKey.KeyOptions
export type SchemaIssue = Schema.Issue
export type DryRunOptions = Migrate.DryRunOptions
export type DryRunReport = Migrate.DryRunReport
export type Event = Types.Event
export type EventType = Types.EventType
export type History = Types.History
export type HistoryOptions = Types.HistoryOptions
export type HistogramSnapshot = Types.HistogramSnapshot
export type RuntimeMetrics = Types.RuntimeMetrics
export type AuditEntry = Types.AuditEntry
export type Admin = Admin.AdminHandle
export type AdminOwner = Admin.Owner
export type AdminInspection = Admin.Inspection
export type AdminInspectResult = Admin.InspectResult
export type AdminPatchOp = Admin.PatchOp
export type AdminChange = Admin.Change
export type AdminEditOptions = Admin.EditOptions
export type AdminEditResult = Admin.EditResult
export type AdminExportedRecord = Admin.ExportedRecord
export type AdminExportOptions = Admin.ExportOptions
export type AdminExportResult = Admin.ExportResult
export type AdminImportOptions = Admin.ImportOptions
export type AdminImportResult = Admin.ImportResult
export type AdminVersionInfo = Admin.VersionInfo
export type AdminVersionsOptions = Admin.VersionsOptions
export type AdminVersionsResult = Admin.VersionsResult
export type AdminRestorePreview = Admin.RestorePreview
export type AdminPreviewResult = Admin.PreviewResult
export type AdminRestoreOptions = Admin.RestoreOptions
export type AdminWarning = Admin.Warning
export type AdminWriteResult = Admin.WriteResult
export type AdminMigrateOptions = Admin.MigrateOptions
export type AdminMigrateResult = Admin.MigrateResult
export type AdminMigrateAllOptions = Admin.MigrateAllOptions
export type AdminMigrateAllReport = Admin.MigrateAllReport

--- An independent runtime (its own scheduler, queues and stores). The default runtime behind `Retriever.store` uses the
--- real Roblox environment; create your own to run against a fake environment in tests.
export type RuntimeHandle = {
	store: <T>(self: RuntimeHandle, name: string, config: StoreConfig<T>?) -> Store<T>,
	shutdown: (self: RuntimeHandle, window: number?) -> ShutdownReport,
	--- Starts a save for every session with unsaved edits now (does not wait). Returns how many saves were requested. Called
	--- automatically when the engine announces a scheduled restart.
	flush: (self: RuntimeHandle) -> number,
	destroy: (self: RuntimeHandle) -> (),
	--- Counts of everything still registered; all zeros means nothing leaked.
	leaks: (self: RuntimeHandle) -> { [string]: number },
	--- Counters of every store, latency histograms (load, commit, close, write) and queue state. A fresh table each call.
	metrics: (self: RuntimeHandle) -> RuntimeMetrics,
	--- Calls `fn(event)` for every event of every store on this runtime (from a deferred thread). Returns a disconnect function.
	observe: (self: RuntimeHandle, fn: (event: Event) -> ()) -> () -> (),
}

local Retriever = {}

--- Ready-made durability settings for `StoreConfig.durability`.
Retriever.Durability = {
	economy = { autosave = 300, lease = 1800, steal = 45 } :: Types.Durability,
	balanced = { autosave = 60, lease = 900, steal = 45 } :: Types.Durability,
	strict = { autosave = 15, lease = 600, steal = 45 } :: Types.Durability,
}

local function wrap(runtime: Internal.Runtime): RuntimeHandle
	local handle: RuntimeHandle = {
		store = function(_self, name, config)
			return Runtime.store(runtime, name, config :: any) :: any
		end,
		shutdown = function(_self, window)
			return Runtime.shutdown(runtime, window)
		end,
		flush = function(_self)
			return Runtime.flush(runtime)
		end,
		destroy = function(_self)
			Runtime.destroy(runtime)
		end,
		leaks = function(_self)
			return Runtime.leaks(runtime)
		end,
		metrics = function(_self)
			return Runtime.metrics(runtime)
		end,
		observe = function(_self, fn)
			return Runtime.observe(runtime, fn)
		end,
	}
	return handle
end

local defaultHandle: RuntimeHandle? = nil

local function default(): RuntimeHandle
	local existing = defaultHandle
	if existing == nil then
		local RobloxEnv = require(script.RobloxEnv)
		existing = wrap(Runtime.new(RobloxEnv.create()))
		defaultHandle = existing
	end
	return existing :: RuntimeHandle
end

--- Creates (or returns) the store named `name` on the default runtime. Create each store once and share the object.
function Retriever.store<T>(name: string, config: StoreConfig<T>?): Store<T>
	return default():store(name, config)
end

--- Loads a profile for every player who joins, releases it when they leave and flushes everything on shutdown.
function Retriever.players<T>(store: Store<T>, options: PlayersOptions<T>?): PlayersBinding<T>
	return Players.bind(store :: any, options :: any) :: any
end

--- Grants developer products exactly once per PurchaseId and answers PurchaseGranted only after a confirmed save. Call it at
--- startup (it installs the receipt callback synchronously). See Receipts.luau for the full contract.
function Retriever.receipts<T>(binding: PlayersBinding<T>, handlers: { [number]: ReceiptHandler<T> }, options: ReceiptsOptions?): ReceiptsBinding
	return Receipts.bind(binding, handlers, options)
end

--- The DataStore key for a player. Default: tostring(player.User.Id) when the engine has `Player.User` (scoped user ids),
--- else tostring(player.UserId); both are the same number for returning players. Options: `prefix`, `source = "userId"`.
function Retriever.userKey(player: Types.PlayerLike, options: UserKeyOptions?): string
	return UserKey.key(player, options)
end

--- Advanced: a runtime over a custom environment (tests, simulators, tools).
function Retriever.runtime(env: Env, options: { [string]: number }?): RuntimeHandle
	return wrap(Runtime.new(env, options))
end

--- Schema DSL (`S.struct`, `S.integer`, `S.array`, ...): declares the data shape and derives defaults, reconcile (fill) and
--- validation with paths. Pass the result as `StoreConfig.schema`. See Schema.luau.
Retriever.schema = Schema

--- Simulates loading `value` (a stored record, or plain data with `options.version`) with the configuration of `target` (a
--- store or a store config), without touching any DataStore: the minimum-reader check, every migration step on a deep copy,
--- reconcile and validation. Returns a report with the migrated copy, the steps applied, the resulting `sv`/`mr` and, on
--- failure, the error kind, cause, failing step and path. `options.to` stops after a given version (step-by-step tests).
function Retriever.dryRun<T>(target: Store<T> | StoreConfig<T>, value: any, options: DryRunOptions?): DryRunReport
	local config: Internal.StoreConfigN
	if getmetatable(target :: any) == Store then
		config = (target :: any).config
	else
		config = Store.normalize("dryRun", target :: any, false)
	end
	return Migrate.dryRun(config, value, options)
end

local function storeImpl(store: any, what: string): Internal.StoreImpl
	if getmetatable(store) ~= Store then
		error(`[Retriever] {what} needs a store created with Retriever.store or runtime:store, got {typeof(store)}`, 3)
	end
	return store :: Internal.StoreImpl
end

--- Operator tools for one store: inspect, ownership-aware edit, export/import, version history and restore, key migration.
--- See Admin.luau. Every call yields (it makes DataStore requests through the store's runtime).
function Retriever.admin<T>(store: Store<T>): Admin
	return Admin.new(storeImpl(store, "Retriever.admin(store)"))
end

--- Calls `fn(event)` for every structured event of `store` (loads, failed writes, handoffs, session ends, command and admin
--- activity), in order, from a deferred thread: never inside a library state transition. Returns a disconnect function.
function Retriever.observe<T>(store: Store<T>, fn: (event: Event) -> ()): () -> ()
	local impl = storeImpl(store, "Retriever.observe(store, fn)")
	return Events.observe(impl.runtime, impl.name, fn)
end

--- Keeps a bounded in-memory history of `store`'s events, per key and store-wide (allocated only when enabled).
function Retriever.history<T>(store: Store<T>, options: HistoryOptions?): History
	local impl = storeImpl(store, "Retriever.history(store)")
	return Events.history(impl.runtime, impl.name, options)
end

--- `runtime:metrics()` of the default runtime.
function Retriever.metrics(): RuntimeMetrics
	return default():metrics()
end

--- Pure checks, exposed for tests and tooling: explains why a value cannot be stored in a DataStore.
--- Optional extensions. Each module loads on first use and allocates nothing until then.

--- Shared documents (guild/clan data, server settings): per-key atomic updates with revision-CAS. See Documents.luau.
function Retriever.documents<T>(store: Store<T>, options: any?): any
	return require(script.Documents).new(store, options)
end

--- Recoverable two-party trades between two profiles of one store. See Escrow.luau. Create once per store and name at startup.
function Retriever.escrow<T>(store: Store<T>, options: any): any
	return require(script.Escrow).new(store, options)
end

--- Versioned codecs and compression for stored data (`Retriever.store(name, { codec = Retriever.codec.lz })`). See Codec.luau.
Retriever.codec = require(script.Codec)

Retriever.validate = Validate.storable

--- In-memory DataStore provider (same behaviour the library relies on, no persistence).
Retriever.memoryProvider = MemoryBackend.new

Retriever.formatError = Errors.format

-- Methods are provided through the metatables of the implementation objects; this keeps the public surface in one place.
Retriever._internal = { Store = Store, Profile = Profile }

return Retriever
