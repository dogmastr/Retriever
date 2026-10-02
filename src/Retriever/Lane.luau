--!strict
--[[
	Per-key ordering: at most one job per key runs at a time, in arrival order.

	A lane exists only while a key has a session or queued work. The queue (a ring buffer) is allocated on first contention,
	so an uncontended session costs one small table. Jobs are `Dispatcher.Job`s; a job calls `Lane.release` exactly once
	when its turn is over (a profile re-submits itself for retries instead of holding the lane while it sleeps... except
	loads, which keep ordering by staying "busy" across attempts).
]]

local Dispatcher = require(script.Parent.Dispatcher)
local Ring = require(script.Parent.Ring)

type Job = Dispatcher.Job

export type Lane = {
	key: string,
	busy: boolean,
	queue: Ring.Ring<Job>?,
	--- Number of live sessions or ops that need the lane to stay registered (the store drops idle lanes).
	holders: number,
}

local Lane = {}

function Lane.new(key: string): Lane
	return { key = key, busy = false, queue = nil, holders = 0 }
end

--- Runs `job` now when the lane is free, otherwise after the jobs already queued.
function Lane.submit(lane: Lane, dispatcher: Dispatcher.Dispatcher, job: Job)
	if lane.busy then
		local queue: Ring.Ring<Job>
		local existing = lane.queue
		if existing == nil then
			queue = Ring.new() :: Ring.Ring<Job>
			lane.queue = queue
		else
			queue = existing
		end
		Ring.push(queue, job)
	else
		lane.busy = true
		Dispatcher.submit(dispatcher, job)
	end
end

--- Marks the lane free and starts the next queued job. Called by the running job when its turn ends.
function Lane.release(lane: Lane, dispatcher: Dispatcher.Dispatcher)
	local queue = lane.queue
	local nextJob = if queue ~= nil then Ring.pop(queue) else nil
	if nextJob ~= nil then
		-- stays busy: ownership passes directly to the next job
		Dispatcher.submit(dispatcher, nextJob)
	else
		lane.busy = false
	end
end

function Lane.isIdle(lane: Lane): boolean
	if lane.busy or lane.holders > 0 then
		return false
	end
	local queue = lane.queue
	return queue == nil or queue.count == 0
end

return Lane
