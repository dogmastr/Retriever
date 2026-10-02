--!strict
--[[
	Fixed-bucket histograms for latencies and queue depths. Observing a value is allocation-free (a short linear scan over the
	bucket bounds plus four field updates), so they are always on. Percentiles in a snapshot are bucket upper bounds (the
	smallest bound below which the given share of observations falls), clamped to the observed maximum: exact enough to see a
	regression, cheap enough to run on every write.
]]

local Types = require(script.Parent.Types)

export type Histogram = {
	--- Upper bounds (inclusive), ascending. One extra overflow bucket counts values above the last bound.
	bounds: { number },
	counts: { number },
	count: number,
	sum: number,
	min: number,
	max: number,
}

export type Bucket = Types.HistogramBucket
export type Snapshot = Types.HistogramSnapshot

local Histogram = {}

--- Seconds: from a fast in-memory request to a request that ran out of retries.
Histogram.LATENCY = { 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5, 10, 30, 60 }
--- Jobs waiting in the dispatcher queues.
Histogram.DEPTH = { 0, 1, 2, 5, 10, 20, 50, 100, 200, 500, 1000 }

function Histogram.new(bounds: { number }): Histogram
	local counts = table.create(#bounds + 1, 0)
	return { bounds = bounds, counts = counts, count = 0, sum = 0, min = math.huge, max = -math.huge }
end

function Histogram.observe(self: Histogram, value: number)
	if value ~= value then
		return -- NaN carries no information and would poison the sum
	end
	local bounds = self.bounds
	local n = #bounds
	local index = n + 1
	for i = 1, n do
		if value <= bounds[i] then
			index = i
			break
		end
	end
	self.counts[index] += 1
	self.count += 1
	self.sum += value
	if value < self.min then
		self.min = value
	end
	if value > self.max then
		self.max = value
	end
end

function Histogram.reset(self: Histogram)
	table.clear(self.counts)
	for i = 1, #self.bounds + 1 do
		self.counts[i] = 0
	end
	self.count = 0
	self.sum = 0
	self.min = math.huge
	self.max = -math.huge
end

local function quantile(self: Histogram, q: number): number
	if self.count == 0 then
		return 0
	end
	local target = math.max(1, math.ceil(self.count * q))
	local seen = 0
	local bounds = self.bounds
	for i, c in self.counts do
		seen += c
		if seen >= target then
			local bound = bounds[i]
			if bound == nil or bound > self.max then
				return self.max
			end
			return math.max(bound, self.min)
		end
	end
	return self.max
end

--- A copy safe to hand to callers and to keep.
function Histogram.snapshot(self: Histogram): Snapshot
	local buckets: { Bucket } = {}
	for i, c in self.counts do
		buckets[i] = { le = self.bounds[i] or math.huge, count = c }
	end
	local empty = self.count == 0
	return {
		count = self.count,
		sum = self.sum,
		min = if empty then 0 else self.min,
		max = if empty then 0 else self.max,
		mean = if empty then 0 else self.sum / self.count,
		p50 = quantile(self, 0.5),
		p90 = quantile(self, 0.9),
		p99 = quantile(self, 0.99),
		buckets = buckets,
	}
end

return Histogram
