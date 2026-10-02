--!strict
--[[
	A runtime owns everything that is shared between stores on one server: the scheduler, the dispatcher (queues, budget,
	worker pool), the store registry and the shutdown handler. There is no module-level mutable state anywhere in the
	library, so tests (and the simulator) can run several "servers" in one process, and `destroy` can prove nothing is left.
]]

local Dispatcher = require(script.Parent.Dispatcher)
local Errors = require(script.Parent.Errors)
local Handoff = require(script.Parent.Handoff)
local Events = require(script.Parent.Events)
local Internal = require(script.Parent.Internal)
local Metrics = require(script.Parent.Metrics)
local Profile = require(script.Parent.Profile)
local Scheduler = require(script.Parent.Scheduler)
local Store = require(script.Parent.Store)
local Types = require(script.Parent.Types)

type Runtime = Internal.Runtime
type StoreImpl = Internal.StoreImpl

export type ShutdownReport = {
	closed: number,
	failed: number,
	seconds: number,
}

local DEFAULT_OPTIONS: Internal.RuntimeOptions = {
	backoffBase = 1,
	backoffCap = 20,
	shutdownWindow = 25,
	jitter = 0.1,
	clockSkew = 10,
	restartFlushLead = 60,
}

local RuntimeModule = {}

function RuntimeModule.new(env: Types.Env, options: { [string]: number }?): Runtime
	local merged: Internal.RuntimeOptions = table.clone(DEFAULT_OPTIONS)
	if options ~= nil then
		for key, value in options do
			if (merged :: any)[key] == nil then
				error(`[Retriever] unknown runtime option "{key}"; valid options are backoffBase, backoffCap, shutdownWindow, jitter, clockSkew, restartFlushLead`, 2)
			end
			(merged :: any)[key] = value
		end
	end
	local scheduler = Scheduler.new(env)
	local runtime: Runtime
	local dispatcher = Dispatcher.new(env, scheduler, function(_job, err)
		env.log("error", `[Retriever] internal error in a request: {tostring(err)}`)
	end)
	runtime = {
		env = env,
		options = merged,
		scheduler = scheduler,
		dispatcher = dispatcher,
		stores = {},
		closing = false,
		destroyed = false,
		handoff = { subscribed = false, released = Handoff.notifyReleased },
		restart = nil :: Internal.RestartState?,
		metrics = Metrics.newState(env),
		events = nil :: Internal.EventsState?,
	}
	local bind = env.bindToClose
	if bind ~= nil then
		bind(function()
			RuntimeModule.shutdown(runtime)
		end)
	end
	local onRestart = env.onRestartScheduled
	if onRestart ~= nil then
		local state: Internal.RestartState = { disconnect = nil, timer = nil, notices = 0, flushed = 0 }
		runtime.restart = state
		local ok, disconnect = pcall(onRestart, function(restartTime: number?, source: string?)
			RuntimeModule.onRestartScheduled(runtime, restartTime, source)
		end)
		if ok and type(disconnect) == "function" then
			state.disconnect = disconnect
		elseif not ok then
			env.log("warn", `[Retriever] could not subscribe to scheduled-restart notices (shutdown still flushes): {tostring(disconnect)}`)
		end
	end
	return runtime
end

--- Starts a save for every active session with unsaved edits, without waiting for it. Clean sessions are skipped (their data
--- is already persisted; the lease is renewed on its own schedule). Returns how many saves were requested.
function RuntimeModule.flush(runtime: Runtime): number
	if runtime.destroyed then
		return 0
	end
	-- collect first: a save can complete synchronously and resume user code that loads or closes profiles, and the registry
	-- must not change while it is being traversed
	local dirty: { Internal.ProfileImpl } = {}
	for _, store in runtime.stores do
		for _, profile in store.profiles do
			if profile.state == "active" and Profile.isDirty(profile) then
				dirty[#dirty + 1] = profile
			end
		end
	end
	for _, profile in dirty do
		Profile.requestSave(profile)
	end
	return #dirty
end

local function cancelRestartTimer(runtime: Runtime)
	local state = runtime.restart
	if state ~= nil and state.timer ~= nil then
		Scheduler.cancel(runtime.scheduler, state.timer)
		state.timer = nil
	end
end

--- `ServerRestartScheduled`: flush every dirty session now (planned restarts usually give minutes of notice, so the final
--- shutdown has almost nothing left to write), and once more `restartFlushLead` seconds before the restart for edits made
--- in between. BindToClose still runs the real shutdown; this only makes it cheap. Must not yield (runs on the engine's
--- signal thread).
function RuntimeModule.onRestartScheduled(runtime: Runtime, restartTime: number?, source: string?)
	local state = runtime.restart
	if state == nil or runtime.destroyed or runtime.closing then
		return
	end
	local env = runtime.env
	state.notices += 1
	local flushed = RuntimeModule.flush(runtime)
	state.flushed += flushed
	env.log("info", `[Retriever] server restart scheduled ({source or "unknown source"}): flushing {flushed} unsaved session(s) early`)

	local lead = runtime.options.restartFlushLead
	cancelRestartTimer(runtime)
	if restartTime ~= nil and lead > 0 then
		local secondsLeft = restartTime - env.time()
		if secondsLeft > lead then
			local timer: Scheduler.Timer = {
				due = 0,
				heapIndex = 0,
				thread = nil,
				fire = function(_timer: Scheduler.Timer)
					local current = runtime.restart
					if current == nil or runtime.destroyed or runtime.closing then
						return
					end
					current.timer = nil
					current.flushed += RuntimeModule.flush(runtime)
				end,
			}
			state.timer = timer
			Scheduler.schedule(runtime.scheduler, timer, env.clock() + secondsLeft - lead)
		end
	end
end

function RuntimeModule.store(runtime: Runtime, name: string, config: Types.StoreConfig<any>?): StoreImpl
	if runtime.destroyed then
		error("[Retriever] this runtime was destroyed", 2)
	end
	if runtime.stores[name] ~= nil then
		error(`[Retriever] a store named "{name}" already exists on this runtime; create it once and share the object`, 2)
	end
	local impl = Store.new(runtime, name, config or {})
	runtime.stores[name] = impl
	return impl
end

--- Closes every session on every store, concurrently, within `window` seconds (default: `shutdownWindow`).
function RuntimeModule.shutdown(runtime: Runtime, window: number?): ShutdownReport
	local env = runtime.env
	local started = env.clock()
	local budget = window or runtime.options.shutdownWindow
	runtime.closing = true
	cancelRestartTimer(runtime)

	local all: { Internal.ProfileImpl } = {}
	for _, store in runtime.stores do
		for _, profile in store.profiles do
			all[#all + 1] = profile
		end
	end

	local report: ShutdownReport = { closed = 0, failed = 0, seconds = 0 }
	local pending = #all
	if pending > 0 then
		local caller = coroutine.running()
		local waiting = false
		for _, profile in all do
			env.spawn(function()
				local result = Profile.closeForShutdown(profile, budget)
				if result.ok then
					report.closed += 1
				else
					report.failed += 1
				end
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

	-- loads that were in flight finish by themselves (they see `closing` and release anything they acquire); wait for them
	local deadline = started + budget
	local poller = Scheduler.newSleeper(runtime.scheduler)
	while env.clock() < deadline do
		local busy = false
		for _, store in runtime.stores do
			if store.pendingLoads > 0 then
				busy = true
			end
		end
		if not busy and Dispatcher.inflightTotal(runtime.dispatcher) == 0 then
			break
		end
		Scheduler.sleepOn(runtime.scheduler, poller, 0.1)
	end
	report.seconds = env.clock() - started
	return report
end

--- Stops background activity and drops every reference. After this the runtime must not be used.
function RuntimeModule.destroy(runtime: Runtime)
	runtime.destroyed = true
	runtime.closing = true
	cancelRestartTimer(runtime)
	local restart = runtime.restart
	if restart ~= nil and restart.disconnect ~= nil then
		local disconnect = restart.disconnect
		restart.disconnect = nil
		pcall(disconnect)
	end
	Dispatcher.destroy(runtime.dispatcher)
	Scheduler.destroy(runtime.scheduler)
	table.clear(runtime.stores)
	runtime.events = nil
end

--- `runtime:metrics()`.
RuntimeModule.metrics = Metrics.snapshot

--- `runtime:observe(fn)`: every event of every store on this runtime.
function RuntimeModule.observe(runtime: Runtime, fn: (event: Types.Event) -> ()): () -> ()
	return Events.observe(runtime, nil, fn)
end

--- Counts what is still registered; zero everywhere means every session, lane and timer was released.
function RuntimeModule.leaks(runtime: Runtime): { [string]: number }
	local profiles, lanes, loads = 0, 0, 0
	for _, store in runtime.stores do
		for _ in store.profiles do
			profiles += 1
		end
		for _ in store.lanes do
			lanes += 1
		end
		loads += store.pendingLoads
	end
	return {
		profiles = profiles,
		lanes = lanes,
		loads = loads,
		timers = Scheduler.pending(runtime.scheduler),
		queued = Dispatcher.pending(runtime.dispatcher),
		inflight = Dispatcher.inflightTotal(runtime.dispatcher),
	}
end

-- reference to keep the error module loaded for error construction by callers of the runtime
RuntimeModule.Errors = Errors

return RuntimeModule
