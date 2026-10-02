--!strict
--[[
	Types shared by the implementation modules (Runtime, Store, Profile, ...). Not part of the public API.
	They live in one file because Luau resolves mutually recursive types only inside a single module.
]]

local Dispatcher = require(script.Parent.Dispatcher)
local Histogram = require(script.Parent.Histogram)
local Lane = require(script.Parent.Lane)
local Record = require(script.Parent.Record)
local Scheduler = require(script.Parent.Scheduler)
local Types = require(script.Parent.Types)

type Env = Types.Env
type Backend = Types.Backend
type RetrieverError = Types.RetrieverError
type EndReason = Types.EndReason
type ProfileState = Types.ProfileState
type OutboxEntry = Types.OutboxEntry

export type Messaging = Types.Messaging

--- Settings the runtime uses for every store unless a store overrides them.
export type RuntimeOptions = {
	--- Retry backoff in seconds: first delay and ceiling.
	backoffBase: number,
	backoffCap: number,
	--- Seconds the shutdown handler may spend (BindToClose allows 30).
	shutdownWindow: number,
	--- Fraction of `autosave` randomly subtracted from each autosave deadline to spread load.
	jitter: number,
	clockSkew: number,
	--- After a scheduled-restart notice: flush again this many seconds before the restart (0 = only flush at the notice).
	restartFlushLead: number,
}

export type Counters = {
	requestsGet: number,
	requestsUpdate: number,
	requestsSet: number,
	requestsList: number,
	requestsGetVersion: number,
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
}

--- A yielded commit/close caller. `parked` is false until the caller actually yielded: when the work finishes
--- synchronously (a backend that never yields) the result is stored in `result` and the caller returns it directly.
export type Waiter = {
	thread: thread,
	seq: number,
	deadline: number,
	parked: boolean,
	result: any,
}

--- Rarely used per-profile state. Allocated on first use, so sessions that never touch these features pay nothing.
export type ProfileExt = {
	ops: { [string]: number }?,
	opsCount: number,
	opsHorizon: number?,
	outbox: { OutboxEntry }?,
	consumed: { [string]: number }?,
	consumedSeq: number,
	ended: { (reason: EndReason, err: RetrieverError?) -> () }?,
	outboxSeq: { [string]: number }?,
	cmd: any?,
}

export type StoreConfigN = {
	template: any?,
	schema: Types.Schema<any>?,
	migrations: { Types.Migration<any> },
	schemaVersion: number,
	--- Highest breaking migration version (nil when there is none): the minimum reader of data in this version's shape.
	minReader: number?,
	autosave: number,
	lease: number,
	steal: number?, -- seconds of waiting before taking over; nil = never steal
	ledgerMax: number,
	ledgerRetention: number,
	debug: boolean,
	snapshot: "reference" | "copy",
	inboxMax: number,
	outboxMax: number,
}

--- Optional extension points. Features that need per-write or per-load work (inbox, outbox, metrics) install these; with none
--- installed the core pays one nil check per write.
export type Hooks = {
	afterActivate: ((profile: ProfileImpl, rec: Types.Record) -> ())?,
	afterWrite: ((profile: ProfileImpl, rec: Types.Record?) -> ())?,
	--- Called last when a session ended (any reason). Must not yield.
	afterEnd: ((profile: ProfileImpl) -> ())?,
}

export type StoreImpl = {
	name: string,
	scope: string?,
	runtime: Runtime,
	backend: Backend,
	config: StoreConfigN,
	profiles: { [string]: ProfileImpl },
	lanes: { [string]: Lane.Lane },
	policy: Record.WritePolicy,
	counters: Counters,
	sessions: number,
	pendingLoads: number,
	commandHandlers: { [string]: (profile: any, payload: any, id: string) -> () }?,
	hooks: Hooks?,
	waiting: { [string]: any }?, -- key -> LoadReq waiting for a lock (only while waiting)
}

export type Runtime = {
	env: Env,
	options: RuntimeOptions,
	scheduler: Scheduler.Scheduler,
	dispatcher: Dispatcher.Dispatcher,
	stores: { [string]: StoreImpl },
	closing: boolean,
	destroyed: boolean,
	handoff: {
		subscribed: boolean,
		released: (runtime: Runtime, waiterJob: string, storeName: string, key: string) -> (),
	},
	--- Scheduled-restart handling (only allocated when the env can signal restarts).
	restart: RestartState?,
	metrics: MetricsState,
	--- Observers and histories (Events.luau). Nil until something subscribes: emitting is then one nil check.
	events: EventsState?,
}

--- Always-on latency histograms (allocation-free to update).
export type MetricsState = {
	started: number, -- clock when the runtime was created
	load: Histogram.Histogram,
	commit: Histogram.Histogram,
	close: Histogram.Histogram,
	write: Histogram.Histogram,
	--- Event counters live here, not in `events`, so they survive the events state being dropped when nobody listens.
	eventSeq: number,
	eventsEmitted: number,
	observerErrors: number,
}

export type EventSink = {
	fn: (event: Types.Event) -> (),
	store: string?, -- nil: every store of the runtime
}

--- Fixed-capacity ring of events (oldest overwritten first).
export type EventRing = {
	items: { Types.Event },
	nextIndex: number,
	count: number,
	capacity: number,
	last: number, -- seq of the newest event
}

export type HistoryState = {
	perKey: number,
	maxKeys: number,
	recent: EventRing,
	keys: { [string]: EventRing },
	keyCount: number,
}

export type EventsState = {
	sinks: { EventSink },
	--- Events waiting for the deferred delivery to observers (observers never run inside a state transition).
	pending: { Types.Event }?,
	histories: { [string]: HistoryState },
}

export type RestartState = {
	disconnect: (() -> ())?,
	--- Second flush shortly before the restart (a scheduler timer; cancelled by shutdown/destroy).
	timer: Scheduler.Timer?,
	notices: number,
	flushed: number, -- sessions flushed because of restart notices
}

--- A live session. Doubles as a dispatcher Job and a scheduler Timer so saving and timers allocate nothing per call.
export type ProfileImpl = Record.WriteSubject & {
	-- Dispatcher.Job
	prio: number,
	kind: Types.BudgetKind,
	queued: boolean,
	run: (self: ProfileImpl) -> (),
	-- Scheduler.Timer
	due: number,
	heapIndex: number,
	fire: (self: ProfileImpl) -> (),
	thread: thread?,

	-- public surface
	key: string,
	store: any,
	state: ProfileState,

	-- internals
	impl: StoreImpl,
	lane: Lane.Lane,
	laneState: number, -- 0 not in the lane, 1 waiting in the lane queue, 2 owns the lane
	cb: (old: any, info: Types.KeyInfoLike?) -> (any, { number }?, { [string]: any }?),
	rev: number, -- revision of the last record this session knew to be persisted
	savedSeq: number, -- highest editSeq known persisted
	unknownSeq: number, -- highest editSeq in a write whose outcome is unknown
	dirty: boolean,
	dirtyDue: number,
	renewDue: number,
	retryAt: number?,
	retryThrottled: boolean, -- the pending retry is a throttle backoff: an explicit commit/close must not skip it
	attempt: number,
	wantSave: boolean,
	wantClose: boolean,
	writing: boolean,
	closeDeadline: number,
	endReason: EndReason,
	endError: RetrieverError?,
	waiters: { Waiter }?,
	leaseExpiry: number,
}

return {}
