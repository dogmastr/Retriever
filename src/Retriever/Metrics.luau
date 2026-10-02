--!strict
--[[
	`runtime:metrics()`: one snapshot of everything a dashboard needs. The counters already exist per store (`store:stats()`);
	this sums them, adds the latency histograms (load, commit, close, write; always on, allocation-free to update) and the
	dispatcher's queue state. A snapshot is a fresh table, safe to keep, encode or diff against the next one.
]]

local Events = require(script.Parent.Events)
local Histogram = require(script.Parent.Histogram)
local Internal = require(script.Parent.Internal)
local Store = require(script.Parent.Store)
local Types = require(script.Parent.Types)

type Runtime = Internal.Runtime

local Metrics = {}

function Metrics.newState(env: Types.Env): Internal.MetricsState
	return {
		started = env.clock(),
		load = Histogram.new(Histogram.LATENCY),
		commit = Histogram.new(Histogram.LATENCY),
		close = Histogram.new(Histogram.LATENCY),
		write = Histogram.new(Histogram.LATENCY),
		eventSeq = 0,
		eventsEmitted = 0,
		observerErrors = 0,
	}
end

function Metrics.snapshot(runtime: Runtime): Types.RuntimeMetrics
	local env = runtime.env
	local state = runtime.metrics
	local dispatcher = runtime.dispatcher
	local dstats = dispatcher.stats

	local requests = { get = 0, update = 0, set = 0, list = 0, getVersion = 0, total = 0 }
	local totals = {
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
	local sessions, loading = 0, 0
	local stores: { [string]: Types.StoreStats } = {}
	for name, impl in runtime.stores do
		local c = impl.counters
		requests.get += c.requestsGet
		requests.update += c.requestsUpdate
		requests.set += c.requestsSet
		requests.list += c.requestsList
		requests.getVersion += c.requestsGetVersion
		for field in totals do
			totals[field] += (c :: any)[field]
		end
		sessions += impl.sessions
		loading += impl.pendingLoads
		stores[name] = Store.stats(impl)
	end
	requests.total = requests.get + requests.update + requests.set + requests.list + requests.getVersion

	return {
		time = env.time(),
		uptime = env.clock() - state.started,
		sessions = sessions,
		loading = loading,
		requests = requests,
		retries = totals.retries,
		failures = totals.failures,
		savesWritten = totals.savesWritten,
		savesSkippedClean = totals.savesSkippedClean,
		commitsConfirmed = totals.commitsConfirmed,
		commitsUnknown = totals.commitsUnknown,
		coalesced = totals.coalesced,
		ownershipLost = totals.ownershipLost,
		sessionsOpened = totals.sessionsOpened,
		sessionsClosed = totals.sessionsClosed,
		loadsFailed = totals.loadsFailed,
		handoffWaits = totals.handoffWaits,
		steals = totals.steals,
		latency = {
			load = Histogram.snapshot(state.load),
			commit = Histogram.snapshot(state.commit),
			close = Histogram.snapshot(state.close),
			write = Histogram.snapshot(state.write),
		},
		queue = {
			depth = dstats.queueDepth,
			maxDepth = dstats.maxQueueDepth,
			submitted = dstats.submitted,
			started = dstats.started,
			budgetWaits = dstats.budgetWaits,
			workers = dstats.workersCreated,
			inflight = table.clone(dispatcher.inflight),
			waiting = Histogram.snapshot(dispatcher.depthHistogram),
		},
		events = Events.stats(runtime),
		stores = stores,
	}
end

return Metrics
