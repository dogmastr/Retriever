--!strict
--[[
	Request pipeline shared by every store: priority queues, budget gating and a pool of worker threads.

	Design points
	* A job is anything with `prio`, `kind` and `run`. Profiles are jobs themselves (their save/close work is `run`), so a
	  steady-state save allocates nothing here.
	* Budget awareness is event-driven. The budget is read at most once per `BUDGET_TTL` per kind and decremented locally for
	  each dispatch; when a queue is blocked the dispatcher arms ONE scheduler timer instead of polling every frame.
	* Priorities protect what matters under pressure: 0 close/release, 1 load, 2 commit, 3 autosave/heartbeat,
	  4 background (outbox, projections, migration tools). Priorities 3 and 4 may only start while the remaining budget stays
	  above a reserve (a fraction of the largest budget ever observed), so a burst of autosaves cannot starve the releases
	  a shutdown needs.
	* Concurrency is capped per kind below the engine's own queue limit, so we never overflow the engine queue.
	* Workers are pooled coroutines. A worker that finishes a job takes the next startable job directly, without a yield
	  or a spawn, and only parks when the queues have nothing it may start.
]]

local Histogram = require(script.Parent.Histogram)
local Ring = require(script.Parent.Ring)
local Scheduler = require(script.Parent.Scheduler)
local Types = require(script.Parent.Types)

type Env = Types.Env
type BudgetKind = Types.BudgetKind

export type Job = {
	--- 0 (most urgent) .. 4. Set by the owner before `submit`.
	prio: number,
	kind: BudgetKind,
	--- Executes the request on a worker thread. May yield.
	run: (job: Job) -> (),
	queued: boolean,
}

export type DispatcherStats = {
	submitted: number,
	started: number,
	budgetWaits: number,
	queueDepth: number,
	maxQueueDepth: number,
	workersCreated: number,
}

export type Dispatcher = {
	env: Env,
	scheduler: Scheduler.Scheduler,
	queues: { Ring.Ring<Job> },
	inflight: { [string]: number },
	maxInflight: { [string]: number },
	budget: { [string]: number }, -- locally tracked remaining budget
	budgetAt: { [string]: number }, -- clock when `budget` was read
	budgetMax: { [string]: number }, -- largest budget ever observed
	reserve: { number }, -- per priority: fraction of budgetMax that must stay untouched
	coolUntil: { [string]: number }, -- per kind: priority 3-4 work is held until this clock time (throttle feedback)
	free: { thread }, -- parked worker threads
	wake: Scheduler.Timer, -- re-pump timer for blocked queues
	waiting: boolean, -- true while a re-pump is armed
	stats: DispatcherStats,
	closed: boolean,
	onError: (job: Job, err: any) -> (),
	--- Jobs still queued right after each submission (metrics). Updating it allocates nothing.
	depthHistogram: Histogram.Histogram,
}

local BUDGET_TTL = 0.1
local REPUMP_DELAY = 0.5
local MAX_FREE_WORKERS = 64
local PRIORITY_COUNT = 5

local Dispatcher = {}

local function readBudget(self: Dispatcher, kind: BudgetKind, now: number): number
	local at = self.budgetAt[kind]
	if at ~= nil and now - at < BUDGET_TTL then
		return self.budget[kind] :: number
	end
	local ok, value = pcall(self.env.provider.budget, kind)
	local budget = if ok and type(value) == "number" then value else 1e9 -- no budget information: do not gate
	self.budget[kind] = budget
	self.budgetAt[kind] = now
	local seen = self.budgetMax[kind]
	if seen == nil or budget > seen then
		self.budgetMax[kind] = budget
	end
	return budget
end

--- Pops the most urgent job that concurrency, budget and reserves allow right now. Arms the re-pump timer when something
--- stays queued because of the budget.
local function startNext(self: Dispatcher): Job?
	local stats = self.stats
	if stats.queueDepth == 0 then
		return nil
	end
	local now = self.env.clock()
	local budgetBlocked = false
	local coolDue = math.huge
	for p = 1, PRIORITY_COUNT do
		local queue = self.queues[p]
		if queue.count > 0 then
			local job = Ring.peek(queue) :: Job
			local kind: BudgetKind = job.kind
			local cool = self.coolUntil[kind]
			if p >= 4 and cool ~= nil and now < cool then
				-- The platform throttled this kind of request: hold autosaves and background work, keep releases, loads and
				-- commits flowing (they have their own backoff).
				if cool < coolDue then
					coolDue = cool
				end
			elseif self.inflight[kind] < self.maxInflight[kind] then
				local budget = readBudget(self, kind, now)
				local reserve = (self.budgetMax[kind] or 0) * self.reserve[p]
				if budget >= 1 and (p <= 3 or budget > reserve) then
					Ring.pop(queue)
					job.queued = false
					stats.queueDepth -= 1
					stats.started += 1
					self.budget[kind] = budget - 1
					self.inflight[kind] += 1
					return job
				end
				budgetBlocked = true
			end
		end
	end
	if budgetBlocked or coolDue < math.huge then
		if budgetBlocked then
			stats.budgetWaits += 1
		end
		if not self.waiting then
			self.waiting = true
			local due = now + REPUMP_DELAY
			if not budgetBlocked then
				due = coolDue
			elseif coolDue < due then
				due = coolDue
			end
			Scheduler.schedule(self.scheduler, self.wake, due)
		end
	end
	return nil
end

local function worker(self: Dispatcher, first: Job)
	local job: Job = first
	local function onError(err: any): any
		self.onError(job, err)
		return err
	end
	while true do
		local startedKind: BudgetKind = job.kind -- a job may change `kind` for its next attempt while it runs
		xpcall(job.run, onError, job)
		self.inflight[startedKind] -= 1
		local nextJob = startNext(self)
		if nextJob ~= nil then
			job = nextJob
		else
			local free = self.free
			if self.closed or #free >= MAX_FREE_WORKERS then
				return
			end
			free[#free + 1] = coroutine.running()
			job = coroutine.yield() :: Job
		end
	end
end

local function launch(self: Dispatcher, job: Job)
	local free = self.free
	local n = #free
	if n > 0 then
		local thread = free[n]
		free[n] = nil :: any
		self.env.spawn(thread, job)
	else
		self.stats.workersCreated += 1
		self.env.spawn(coroutine.create(worker), self, job)
	end
end

--- Starts as many queued jobs as concurrency, budget and reserves allow. Cheap when nothing is queued.
function Dispatcher.pump(self: Dispatcher)
	while true do
		local job = startNext(self)
		if job == nil then
			return
		end
		launch(self, job)
	end
end

function Dispatcher.new(env: Env, scheduler: Scheduler.Scheduler, onError: (job: Job, err: any) -> ()): Dispatcher
	local queues: { Ring.Ring<Job> } = {}
	for i = 1, PRIORITY_COUNT do
		queues[i] = Ring.new() :: Ring.Ring<Job>
	end
	local self: Dispatcher
	self = {
		env = env,
		scheduler = scheduler,
		queues = queues,
		inflight = { get = 0, update = 0, set = 0, list = 0, getVersion = 0, removeVersion = 0 },
		maxInflight = { get = 16, update = 20, set = 16, list = 4, getVersion = 4, removeVersion = 4 },
		budget = {},
		budgetAt = {},
		budgetMax = {},
		reserve = { 0, 0, 0.05, 0.2, 0.5 },
		coolUntil = {},
		free = {},
		wake = {
			due = 0,
			heapIndex = 0,
			fire = function()
				self.waiting = false
				Dispatcher.pump(self)
			end,
		},
		waiting = false,
		stats = { submitted = 0, started = 0, budgetWaits = 0, queueDepth = 0, maxQueueDepth = 0, workersCreated = 0 },
		closed = false,
		onError = onError,
		depthHistogram = Histogram.new(Histogram.DEPTH),
	}
	return self
end

--- Reports that the platform throttled a request of `kind`. Experience-wide throttles (every server is throttled) hold background
--- work longer than a single server's queue overflowing. Releases, loads and commits are never held.
function Dispatcher.noteThrottle(self: Dispatcher, kind: BudgetKind, scope: string?)
	local now = self.env.clock()
	local pause = if scope == "experience" then 10 else 3
	pause *= 0.75 + 0.5 * self.env.random()
	local current = self.coolUntil[kind]
	if current == nil or now + pause > current then
		self.coolUntil[kind] = now + pause
	end
	-- the budget we believed in was wrong: forget it so the next pump re-reads
	self.budgetAt[kind] = nil
end

--- Queues `job` (a no-op when it is already queued) and starts it right away when the budget allows.
function Dispatcher.submit(self: Dispatcher, job: Job)
	if job.queued or self.closed then
		return
	end
	job.queued = true
	Ring.push(self.queues[job.prio + 1], job)
	local stats = self.stats
	stats.submitted += 1
	stats.queueDepth += 1
	if stats.queueDepth > stats.maxQueueDepth then
		stats.maxQueueDepth = stats.queueDepth
	end
	Dispatcher.pump(self)
	Histogram.observe(self.depthHistogram, stats.queueDepth)
end

--- Removes a queued job (for example a save superseded by a close). Safe when the job is not queued.
function Dispatcher.remove(self: Dispatcher, job: Job)
	if not job.queued then
		return
	end
	-- Rare path: rebuild the one queue without the job.
	local queue = self.queues[job.prio + 1]
	for _ = 1, queue.count do
		local item = Ring.pop(queue) :: Job
		if item ~= job then
			Ring.push(queue, item)
		end
	end
	job.queued = false
	self.stats.queueDepth -= 1
end

function Dispatcher.pending(self: Dispatcher): number
	return self.stats.queueDepth
end

function Dispatcher.inflightTotal(self: Dispatcher): number
	local total = 0
	for _, n in self.inflight do
		total += n
	end
	return total
end

--- Drops queued jobs and parked workers. In-flight jobs finish on their own threads.
function Dispatcher.destroy(self: Dispatcher)
	self.closed = true
	for _, queue in self.queues do
		while queue.count > 0 do
			local job = Ring.pop(queue) :: Job
			job.queued = false
		end
	end
	self.stats.queueDepth = 0
	Scheduler.cancel(self.scheduler, self.wake)
	table.clear(self.free)
end

return Dispatcher
