--!strict
--[[
	Retriever shared types.

	Layering: `Env` is the only thing the library needs from Roblox. The real implementation lives in `RobloxEnv`; the
	deterministic simulator provides another. Everything below `-- Public API` is re-exported by `init.luau`.
]]

------------------------------------------------------------------------------------------------------------------------
-- Environment: everything injected so the library is testable without Roblox
------------------------------------------------------------------------------------------------------------------------

--- Which DataStore request budget a call consumes. Mapped to `Enum.DataStoreRequestType` by the Roblox adapter.
export type BudgetKind = "get" | "update" | "set" | "list" | "getVersion" | "removeVersion"

export type KeyInfoLike = {
	Version: string,
	CreatedTime: number,
	UpdatedTime: number,
	GetUserIds: (self: KeyInfoLike) -> { number },
	GetMetadata: (self: KeyInfoLike) -> { [string]: any },
}

--- UpdateAsync transform. Must not yield. May be invoked several times for one request. Returning nil cancels the write.
export type TransformFn = (old: any, info: KeyInfoLike?) -> (any, { number }?, { [string]: any }?)

export type KeyPage = { keys: { string }, cursor: string? }

export type VersionEntry = { version: string, createdTime: number, deleted: boolean }
export type VersionPage = { versions: { VersionEntry }, cursor: string? }

--- One DataStore (name + scope). Plain functions, no `self`, so adapters and the simulator stay trivial.
export type Backend = {
	update: (key: string, transform: TransformFn) -> (any, KeyInfoLike?),
	get: (key: string, useCache: boolean?) -> (any, KeyInfoLike?),
	set: (key: string, value: any, userIds: { number }?, metadata: { [string]: any }?) -> string,
	remove: (key: string) -> (any, KeyInfoLike?),
	increment: (key: string, delta: number?, userIds: { number }?) -> number,
	listKeys: (prefix: string?, pageSize: number?, cursor: string?) -> KeyPage,
	listVersions: (key: string, ascending: boolean?, minTime: number?, maxTime: number?, pageSize: number?, cursor: string?) -> VersionPage,
	getVersion: (key: string, version: string) -> (any, KeyInfoLike?),
}

export type Provider = {
	open: (name: string, scope: string?) -> Backend,
	--- Requests currently allowed for this kind (`GetRequestBudgetForRequestType`).
	budget: (kind: BudgetKind) -> number,
	--- False when stores opened by this provider cannot touch production data (an in-memory fallback). A provider without
	--- this function is treated as live, which is what the Studio live-data guard needs to stay safe by default.
	isLive: (() -> boolean)?,
}

export type Messaging = {
	publish: (topic: string, message: any) -> (),
	--- Returns a disconnect function.
	subscribe: (topic: string, handler: (message: any) -> ()) -> () -> (),
}

export type PlayerLike = {
	UserId: number,
	Name: string,
	Kick: (self: PlayerLike, message: string?) -> (),
	--- `Player.User` (scoped user ids). Optional: older engines and fakes do not have it.
	User: { Id: number }?,
}

export type PlayersAdapter = {
	all: () -> { PlayerLike },
	onAdded: (fn: (player: PlayerLike) -> ()) -> () -> (),
	onRemoving: (fn: (player: PlayerLike) -> ()) -> () -> (),
	--- true while the player is still in the game (used to cancel loads for players who already left)
	isPresent: (player: PlayerLike) -> boolean,
}

export type ReceiptInfo = {
	PurchaseId: string,
	PlayerId: number,
	ProductId: number,
	CurrencySpent: number,
	CurrencyType: any,
	PlaceIdWherePurchased: number,
}

export type ReceiptDecision = "granted" | "notProcessedYet"

export type MarketplaceAdapter = {
	--- Installs the (single) ProcessReceipt callback.
	setProcessReceipt: (callback: (info: ReceiptInfo) -> ReceiptDecision) -> (),
	--- `MarketplaceService:BindReceiptHandler(Enum.ReceiptType.DeveloperProduct, handler, productIds)` when the engine has it.
	--- Filtered handlers leave the game's own ProcessReceipt slot alone. Returns a disconnect function.
	bindReceiptHandler: ((productIds: { number }?, callback: (info: ReceiptInfo) -> ReceiptDecision) -> () -> ())?,
}

export type JsonCodec = {
	encode: (value: any) -> string,
	decode: (text: string) -> any,
}

export type LogLevel = "debug" | "info" | "warn" | "error"

export type Env = {
	jobId: string,
	placeId: number,
	isStudio: boolean,

	--- Wall-clock seconds (UTC). Stored in records, so it must be comparable across servers.
	time: () -> number,
	--- Monotonic seconds for timers and backoff.
	clock: () -> number,
	--- Uniform [0, 1). Deterministic in the simulator.
	random: () -> number,
	guid: () -> string,

	--- `task.spawn` semantics: accepts a function or a suspended thread.
	spawn: (fn: any, ...any) -> thread,
	defer: (fn: any, ...any) -> thread,
	wait: (seconds: number?) -> number,
	cancel: (thread: thread) -> (),

	provider: Provider,
	messaging: Messaging?,
	players: PlayersAdapter?,
	marketplace: MarketplaceAdapter?,
	json: JsonCodec?,
	--- Registers a shutdown callback (`game:BindToClose`).
	bindToClose: ((callback: () -> ()) -> ())?,
	--- Subscribes to scheduled-restart notices (`DataModel.ServerRestartScheduled`). The callback receives the restart time
	--- (wall-clock seconds, if known) and the source (`Enum.CloseReason` name). Returns a disconnect function.
	onRestartScheduled: ((callback: (restartTime: number?, source: string?) -> ()) -> () -> ())?,
	log: (level: LogLevel, message: string) -> (),
}

------------------------------------------------------------------------------------------------------------------------
-- Stored record (the "envelope"). Short keys keep the serialized size and the engine's encode/decode work small.
------------------------------------------------------------------------------------------------------------------------

--- Ownership. `j` job id, `p` place id, `x` lease expiry (wall-clock seconds), `q` handoff request (job id of a waiter).
export type Lock = {
	j: string,
	p: number?,
	x: number,
	q: string?,
}

export type InboxEntry = {
	i: string, -- command id (also the idempotency id)
	t: number, -- time sent
	k: string, -- command kind
	p: any, -- payload
}

export type OutboxEntry = {
	i: string, -- command id
	to: string, -- target key
	s: string?, -- target store name (nil = same store)
	k: string,
	p: any,
	t: number,
}

export type Record = {
	v: number, -- envelope format version
	sv: number?, -- schema (migration) version of `d`
	mr: number?, -- minimum schema version allowed to load this record
	d: any, -- user data; nil for a stub created by an inbox send before the first load
	r: number, -- revision: +1 on every write by anyone
	e: number, -- last issued session epoch (fencing token)
	l: Lock?,
	o: { [string]: number }?, -- idempotency ledger: op id -> time applied
	oh: number?, -- ledger horizon: ops older than this may have been pruned
	ib: { InboxEntry }?,
	ob: { OutboxEntry }?,
	c: number?, -- created at
	au: { AuditEntry }?, -- admin writes (bounded, newest last); absent until an admin tool wrote the record
	cd: string?, -- id of the codec that encoded `d` (Retriever.codec); absent when `d` is stored as plain data
	cv: number?, -- version of that codec
}

--- One admin write (Retriever.admin). `i` also makes the write idempotent: a retry that finds its own id knows it landed.
export type AuditEntry = {
	i: string, -- operation id
	t: number, -- wall-clock time
	a: string, -- action: "edit" | "takeover" | "import" | "restore" | "migrate"
	j: string, -- job id of the server that wrote it
	r: string?, -- reason given by the operator
	rv: number?, -- revision the write produced
}

------------------------------------------------------------------------------------------------------------------------
-- Public API
------------------------------------------------------------------------------------------------------------------------

export type ErrorKind =
	"Locked" -- another live session owns the key and did not release in time
	| "Unavailable" -- DataStore errors or throttling exhausted the retry budget; safe to retry later
	| "Corrupt" -- stored value is not a Retriever record; it was NOT modified
	| "SchemaTooNew" -- written by newer game code than this server runs (rolling update); NOT modified
	| "MigrationFailed" -- a migration threw or its output failed validation; NOT modified
	| "InvalidData" -- data failed schema validation or is not serializable (see details.path)
	| "TooLarge" -- serialized value exceeds the DataStore limit
	| "Cancelled" -- the caller cancelled (player left)
	| "ShuttingDown"
	| "AlreadyLoaded"
	| "NotFound"
	| "OwnershipLost" -- another server took the session over, or the record was deleted
	| "Closed" -- the profile is closing or closed
	| "Conflict" -- revision precondition failed
	| "InboxFull"
	| "Unknown" -- outcome unknown: the write may or may not have been applied
	| "InvalidArgument"
	| "StudioApiDisabled"

export type RetrieverError = {
	kind: ErrorKind,
	--- What happened, with store and key.
	message: string,
	--- What to do about it.
	hint: string,
	--- True when trying again later can succeed.
	retryable: boolean,
	store: string,
	key: string?,
	--- Underlying DataStore error text, if any.
	cause: string?,
	details: { [string]: any }?,
}

export type ProfileState = "active" | "closing" | "closed" | "lost"

--- Why a session ended.
export type EndReason = "closed" | "shutdown" | "ownershipLost" | "released" | "faulted"

export type CommitOptions = {
	--- Give up waiting after this many seconds and return an `Unknown` error (the write may still land). Default 30.
	timeout: number?,
}

export type CommitResult = { ok: true, revision: number } | { ok: false, error: RetrieverError }

export type CloseOptions = {
	--- Seconds to keep retrying the final save. Default 60 (shutdown uses the remaining shutdown window).
	timeout: number?,
}

export type CloseResult = { ok: true, revision: number } | { ok: false, error: RetrieverError }

export type ApplyResult = "applied" | "duplicate"

export type Profile<T> = {
	--- The live data table. Change it inside `edit`/`apply`, or call `touch()` after writing to it directly.
	data: T,
	key: string,
	store: Store<T>,
	state: ProfileState,

	--- Buffered edit: changes memory immediately and is saved automatically within the durability target.
	--- `fn` must not yield.
	edit: (self: Profile<T>, fn: (data: T) -> ()) -> (),
	--- Marks the profile dirty without a callback (for hot paths that write `profile.data` directly).
	touch: (self: Profile<T>) -> (),
	--- Idempotent edit: runs `fn` once per `opId`, persisting the id and the effect atomically.
	apply: (self: Profile<T>, opId: string, fn: (data: T) -> ()) -> ApplyResult,
	--- Yields until everything edited before this call is durably saved (or reports why it could not be).
	commit: (self: Profile<T>, options: CommitOptions?) -> CommitResult,
	--- Final save and lock release. Idempotent.
	close: (self: Profile<T>, options: CloseOptions?) -> CloseResult,
	--- Called once when the session ends for any reason. Returns a disconnect function.
	onEnded: (self: Profile<T>, fn: (reason: EndReason, err: RetrieverError?) -> ()) -> () -> (),
	isActive: (self: Profile<T>) -> boolean,
	isDirty: (self: Profile<T>) -> boolean,
	--- Revision of the last record this session knew to be persisted.
	revision: (self: Profile<T>) -> number,
	addUserId: (self: Profile<T>, userId: number) -> (),
	removeUserId: (self: Profile<T>, userId: number) -> (),
	--- Queues a durable command for another key (outbox). The entry is persisted by this session's next write, together with
	--- whatever this session edited before it, and delivered to the target's inbox in the background after that write is
	--- confirmed. Returns the command id. Must be called while the session is active; does not yield.
	enqueue: (self: Profile<T>, targetKey: string, kind: string, payload: any, options: EnqueueOptions?) -> string,
}

export type EnqueueOptions = {
	--- Command id (the idempotency id at the target). Default: a fresh guid. Reuse the same id for the same logical command.
	id: string?,
	--- Name of the target store (created on this runtime). Default: this profile's store.
	store: string?,
}

--- Runs inside the target owner's session, once per command id: change `profile.data` here, do not yield. Throwing leaves the
--- command in the inbox (it is retried by the next session) and keeps any partial edit in memory: validate before mutating.
export type CommandHandler<T> = (profile: Profile<T>, payload: any, id: string) -> ()

export type SendOptions = {
	--- Command id, used for duplicate protection at the target (inbox and idempotency ledger). Default: a fresh guid.
	id: string?,
	--- Create a stub record when the target key does not exist yet. Default true; false returns `NotFound` instead.
	create: boolean?,
	--- Seconds to keep retrying transient failures. Default 30.
	timeout: number?,
}

--- `duplicate`: the target already had this command id (in its inbox or its idempotency ledger); nothing was appended.
export type SendResult = { ok: true, id: string, duplicate: boolean } | { ok: false, error: RetrieverError }

export type DeliverResult = { ok: true, delivered: number, remaining: number } | { ok: false, error: RetrieverError }

export type LoadOptions = {
	--- Return `Cancelled` as soon as this returns true (for example when the player has left).
	cancel: (() -> boolean)?,
	--- Total seconds to wait for a locked or unavailable profile. Default 90.
	timeout: number?,
	--- Create the profile when the key does not exist. Default true.
	create: boolean?,
	--- User ids to associate on first creation (GDPR). Ignored for existing profiles.
	userIds: { number }?,
}

export type LoadResult<T> = { ok: true, profile: Profile<T> } | { ok: false, error: RetrieverError }

export type DurabilityPreset = "economy" | "balanced" | "strict"

export type Durability = {
	--- Longest a dirty profile waits before an automatic save (seconds). Default 60.
	autosave: number?,
	--- Ownership lease in seconds; renewed on every write. Default 900.
	lease: number?,
	--- Take over an owner that has not released after this many seconds of waiting. `false` waits for lease expiry.
	steal: (number | boolean)?,
}

export type Migration<T> = {
	--- Target version. Versions are consecutive starting at 2 (version 1 is the initial shape).
	version: number,
	name: string?,
	--- Transform old data into the new shape. Runs after the session lock is held, never inside a DataStore callback.
	up: (data: any) -> any,
	--- "breaking" (default): servers older than `version` must not load migrated data.
	--- "forward": older servers may still read and write it (additive changes only).
	compat: ("breaking" | "forward")?,
}

export type StoreConfig<T> = {
	--- Default data for new profiles. Missing fields in existing profiles are filled from it on load.
	template: T?,
	schema: Schema<T>?,
	migrations: { Migration<T> }?,
	durability: (Durability | DurabilityPreset)?,
	--- Maximum entries kept in the idempotency ledger (default 200) and how long they are kept (default 30 days).
	ledger: { max: number?, retention: number? }?,
	--- Extra checks in Studio/tests: `validate` data on every save, detect edits made without `edit`. Default: Studio only.
	debug: boolean?,
	scope: string?,
	--- How a save captures the data. "reference" (default): the live table is handed to UpdateAsync, which serializes it
	--- synchronously when the callback returns. "copy": the callback deep-copies the data (and the ledger/outbox) first, so a
	--- later edit can never leak into an in-flight write even if serialization were deferred. Costs one copy per write.
	snapshot: ("reference" | "copy")?,
	--- Studio live-data guard. In Studio with DataStore access, opening the production DataStore is refused unless you pick
	--- one: "prefix" uses scope "studio_<scope or global>" (isolated test data), "live" uses production data on purpose.
	--- Ignored outside Studio and when Studio runs on the in-memory fallback.
	studio: ("prefix" | "live")?,
	--- Durable commands: maximum entries waiting in a record's inbox (default 100; a full inbox rejects sends with `InboxFull`)
	--- and in a session's outbox (default 100; `enqueue` raises when it is full).
	commands: { inboxMax: number?, outboxMax: number? }?,
	--- Encodes the data at save time and decodes it at load (Retriever.codec), for example `Retriever.codec.lz` to keep
	--- large profiles under the 4 MB per-key limit. Records keep the codec id and version, so they stay readable after the
	--- option changes as long as the codec stays registered.
	codec: Codec?,
}

--- A versioned data codec (Retriever.codec). `encode` runs inside the save callback: it must be pure, must not yield and
--- may raise to refuse the data. `decode` runs at load, before migrations.
export type Codec = {
	id: string,
	version: number,
	encode: (data: any) -> any,
	decode: (stored: any) -> any,
}

export type Schema<T> = {
	kind: string,
	check: (self: Schema<T>, value: any) -> (boolean, string?),
	defaults: (self: Schema<T>) -> T,
	fill: (self: Schema<T>, value: any) -> boolean,
}

export type StoreStats = {
	sessions: number,
	requests: { get: number, update: number, set: number, list: number, getVersion: number },
	retries: number,
	failures: number,
	savesWritten: number,
	savesSkippedClean: number,
	commitsConfirmed: number,
	commitsUnknown: number,
	coalesced: number,
	ownershipLost: number,
	budgetWaits: number,
	queueDepth: number,
}

export type Store<T> = {
	name: string,
	--- Starts a session: acquires the lock, migrates, validates. Yields. Never returns default data on failure.
	load: (self: Store<T>, key: string, options: LoadOptions?) -> LoadResult<T>,
	--- The profile loaded on this server for `key`, if any.
	get: (self: Store<T>, key: string) -> Profile<T>?,
	--- Ends every session on this server (yields until done or the timeout passes).
	closeAll: (self: Store<T>, timeout: number?) -> (),
	stats: (self: Store<T>) -> StoreStats,
	--- Registers the handler for one command kind. Register before loading profiles: entries of a kind without a handler stay
	--- in the inbox (forward compatibility) until a session that has one consumes them.
	onCommand: (self: Store<T>, kind: string, handler: CommandHandler<T>) -> (),
	--- Appends a command to `key`'s inbox without taking its lock (works for offline and online targets). Yields.
	send: (self: Store<T>, key: string, kind: string, payload: any, options: SendOptions?) -> SendResult,
	--- Delivers the outbox of a record that is not loaded anywhere (for example a sender that closed during a shutdown and has
	--- not been back since). Delivered entries are removed only while the record is unlocked. Yields.
	deliverOutbox: (self: Store<T>, key: string) -> DeliverResult,
}

------------------------------------------------------------------------------------------------------------------------
-- Observability: events, history, metrics
------------------------------------------------------------------------------------------------------------------------

export type EventType =
	"loaded" -- a session started (seconds = load latency; details.created, details.tookOver)
	| "loadFailed" -- a load returned an error (error, cause, seconds)
	| "writeFailed" -- one write attempt raised (cause; details.attempt, details.throttled, details.maybeApplied); it is retried
	| "unwritable" -- the data cannot be written (error = InvalidData | TooLarge, cause)
	| "handoffRequested" -- another server asked for this key; the session releases it (details.by = its job id)
	| "ended" -- the session ended (reason = EndReason; error/cause when it ended with an error)
	| "commandFailed" -- an inbox command handler raised (details.id, details.kind, cause); the command stays in the inbox
	| "admin" -- an admin tool changed the key (reason = action; details.reason, details.revision, details.id)

--- A structured event. Only `type`, `seq`, `store` and `time` are always present.
export type Event = {
	type: EventType,
	--- Increases by one per event on a runtime (events of all stores share the sequence).
	seq: number,
	store: string,
	key: string?,
	--- Wall-clock seconds.
	time: number,
	reason: string?,
	error: ErrorKind?,
	cause: string?,
	seconds: number?,
	revision: number?,
	details: { [string]: any }?,
}

export type HistoryOptions = {
	--- Events kept per key (default 32).
	perKey: number?,
	--- Keys kept; the key whose latest event is the oldest is dropped first (default 256).
	keys: number?,
	--- Store-wide ring of the most recent events (default 256).
	capacity: number?,
}

export type History = {
	--- Recent events for `key`, oldest first (empty when nothing was recorded). Copies; safe to keep.
	get: (self: History, key: string) -> { Event },
	--- The most recent events of the store, oldest first. `limit` defaults to all that are kept.
	recent: (self: History, limit: number?) -> { Event },
	clear: (self: History) -> (),
	--- Stops recording and frees the memory.
	stop: (self: History) -> (),
}

export type HistogramBucket = { le: number, count: number }

--- Latencies in seconds. Percentiles are bucket upper bounds clamped to the observed range.
export type HistogramSnapshot = {
	count: number,
	sum: number,
	min: number,
	max: number,
	mean: number,
	p50: number,
	p90: number,
	p99: number,
	buckets: { HistogramBucket },
}

--- `runtime:metrics()`: counters summed over every store, latency histograms and the dispatcher's queues.
export type RuntimeMetrics = {
	--- Wall-clock time of the snapshot and seconds since the runtime started.
	time: number,
	uptime: number,
	sessions: number,
	loading: number,
	requests: { get: number, update: number, set: number, list: number, getVersion: number, total: number },
	retries: number,
	failures: number,
	savesWritten: number,
	savesSkippedClean: number,
	commitsConfirmed: number,
	commitsUnknown: number,
	coalesced: number,
	ownershipLost: number,
	sessionsOpened: number,
	sessionsClosed: number,
	loadsFailed: number,
	handoffWaits: number,
	steals: number,
	--- load: successful loads, from the call to the session being ready; commit/close: from the call to its result;
	--- write: one UpdateAsync of a session (save, renewal or release).
	latency: { load: HistogramSnapshot, commit: HistogramSnapshot, close: HistogramSnapshot, write: HistogramSnapshot },
	queue: {
		depth: number,
		maxDepth: number,
		submitted: number,
		started: number,
		budgetWaits: number,
		workers: number,
		inflight: { [string]: number },
		--- Jobs still waiting right after each submission (0 when the request could start at once).
		waiting: HistogramSnapshot,
	},
	events: { emitted: number, observers: number, observerErrors: number },
	stores: { [string]: StoreStats },
}

return {}
