--!strict
--[[
	One shared timer wheel for the whole runtime: a binary min-heap plus a single loop thread.

	* No per-profile or per-request timers: a profile owns at most one heap entry (its next autosave / lease renewal /
	  retry), and a pending `sleep` owns one short-lived entry.
	* No polling: with an empty heap the loop thread parks on `coroutine.yield()` and costs nothing. With entries it sleeps
	  exactly until the earliest deadline. Inserting an earlier deadline wakes it (cancel + restart, only for sleeps longer
	  than `WAKE_EPSILON`).
	* Handlers run on the loop thread, inside pcall, and must not yield.
]]

local Heap = require(script.Parent.Heap)
local Types = require(script.Parent.Types)

type Env = Types.Env

export type Timer = {
	due: number,
	heapIndex: number,
	--- Called on the scheduler thread when `due` passes. Must not yield.
	fire: (timer: Timer) -> (),
	--- Used by `sleep` entries.
	thread: thread?,
}

export type Scheduler = {
	env: Env,
	heap: Heap.Heap,
	thread: thread,
	mode: "running" | "parked" | "sleeping",
	wakeAt: number,
	destroyed: boolean,
	loopStarts: number, -- diagnostics: how many loop threads were started (early wakes restart the loop)
	fires: number,
}

local WAKE_EPSILON = 0.02

local Scheduler = {}

local function loop(self: Scheduler)
	local env = self.env
	local heap = self.heap
	local function onHandlerError(err: any): any
		env.log("error", `[Retriever] scheduler handler failed: {tostring(err)}`)
		return err
	end
	while not self.destroyed do
		local now = env.clock()
		while true do
			local top = Heap.peek(heap)
			if top == nil or top.due > now then
				break
			end
			Heap.pop(heap)
			self.fires += 1
			local timer = top :: Timer
			xpcall(timer.fire, onHandlerError, timer)
		end
		local nextTimer = Heap.peek(heap)
		if nextTimer == nil then
			self.mode = "parked"
			coroutine.yield()
		else
			self.mode = "sleeping"
			self.wakeAt = nextTimer.due
			env.wait(math.max(0, nextTimer.due - now))
		end
		self.mode = "running"
	end
end

local function start(self: Scheduler)
	self.loopStarts += 1
	self.mode = "running"
	local thread = coroutine.create(loop)
	self.thread = thread
	self.env.spawn(thread, self)
end

function Scheduler.new(env: Env): Scheduler
	local self: Scheduler = {
		env = env,
		heap = Heap.new(),
		thread = coroutine.create(loop), -- replaced on first start
		mode = "parked",
		wakeAt = math.huge,
		destroyed = false,
		loopStarts = 0,
		fires = 0,
	}
	start(self)
	return self
end

local function notify(self: Scheduler, due: number)
	local mode = self.mode
	if mode == "parked" then
		self.mode = "running"
		self.env.spawn(self.thread)
	elseif mode == "sleeping" and due < self.wakeAt - WAKE_EPSILON then
		self.env.cancel(self.thread)
		start(self)
	end
end

--- Schedules (or moves) `timer` to fire at monotonic time `due`.
function Scheduler.schedule(self: Scheduler, timer: Timer, due: number)
	if self.destroyed then
		return
	end
	Heap.reschedule(self.heap, timer, due)
	notify(self, due)
end

function Scheduler.cancel(self: Scheduler, timer: Timer)
	Heap.remove(self.heap, timer)
end

function Scheduler.isScheduled(timer: Timer): boolean
	return timer.heapIndex > 0
end

--- A reusable sleep handle. Create one per waiter, `sleepOn` it, and `wake` it from another thread to end the sleep early.
function Scheduler.newSleeper(self: Scheduler): Timer
	local env = self.env
	return {
		due = 0,
		heapIndex = 0,
		thread = nil,
		fire = function(timer: Timer)
			local thread = timer.thread
			timer.thread = nil
			if thread ~= nil and coroutine.status(thread) == "suspended" then
				env.spawn(thread, true)
			end
		end,
	}
end

--- Yields the calling thread for `seconds` through the shared heap. Returns true when the time elapsed, false when `wake`
--- ended the sleep early. For slow paths (retry backoff, lock polling): it parks the thread instead of using a per-waiter timer.
function Scheduler.sleepOn(self: Scheduler, sleeper: Timer, seconds: number): boolean
	sleeper.thread = coroutine.running()
	Scheduler.schedule(self, sleeper, self.env.clock() + seconds)
	return coroutine.yield() == true
end

function Scheduler.sleep(self: Scheduler, seconds: number): boolean
	return Scheduler.sleepOn(self, Scheduler.newSleeper(self), seconds)
end

--- Ends a `sleepOn` early. The sleeping thread resumes with `false`. No-op when nobody is sleeping on `sleeper`.
function Scheduler.wake(self: Scheduler, sleeper: Timer)
	local thread = sleeper.thread
	if thread == nil then
		return
	end
	sleeper.thread = nil
	Heap.remove(self.heap, sleeper)
	if coroutine.status(thread) == "suspended" then
		self.env.spawn(thread, false)
	end
end

function Scheduler.pending(self: Scheduler): number
	return self.heap.size
end

--- Stops the loop and drops every entry. Used by tests to prove nothing is left behind.
function Scheduler.destroy(self: Scheduler)
	self.destroyed = true
	Heap.clear(self.heap)
	if self.mode == "sleeping" then
		self.env.cancel(self.thread)
	end
	self.mode = "parked"
end

return Scheduler
