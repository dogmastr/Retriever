--!strict
--[[
	Structured events: observers (`Retriever.observe`) and bounded per-key histories (`Retriever.history`).

	Cost model
	* Nothing is allocated until someone observes or enables a history: call sites check `runtime.events ~= nil` first, so a
	  runtime without observers pays one nil check per notable event (events are never emitted on the hot save path).
	* Observers never run inside a library state transition. Emitting appends the event to a pending list and defers ONE
	  delivery thread per batch, so an observer that yields, raises or calls back into a profile cannot break the waiter
	  discipline. Observer errors are caught, counted and logged once per runtime.
	* A history keeps at most `perKey` events for each of at most `keys` keys (the key whose newest event is oldest is dropped
	  first) plus a store-wide ring of `capacity` events. Histories outlive sessions on purpose: they explain why a session
	  ended. They are bounded and opt-in, and `stop()` frees them.
]]

local Internal = require(script.Parent.Internal)
local Types = require(script.Parent.Types)

type Runtime = Internal.Runtime
type EventsState = Internal.EventsState
type EventRing = Internal.EventRing
type HistoryState = Internal.HistoryState
type Event = Types.Event

local Events = {}

local function stateOf(runtime: Runtime): EventsState
	local existing = runtime.events
	if existing ~= nil then
		return existing
	end
	local created: EventsState = {
		sinks = {},
		pending = nil,
		histories = {},
	}
	runtime.events = created
	return created
end

--- Drops the state again when nobody listens, so emitting returns to a single nil check.
local function release(runtime: Runtime)
	local state = runtime.events
	if state ~= nil and #state.sinks == 0 and next(state.histories) == nil and state.pending == nil then
		runtime.events = nil
	end
end

------------------------------------------------------------------------------------------------------------------------
-- rings
------------------------------------------------------------------------------------------------------------------------

local function newRing(capacity: number): EventRing
	return { items = {}, nextIndex = 1, count = 0, capacity = capacity, last = 0 }
end

local function push(ring: EventRing, event: Event)
	ring.items[ring.nextIndex] = event
	ring.nextIndex = if ring.nextIndex >= ring.capacity then 1 else ring.nextIndex + 1
	if ring.count < ring.capacity then
		ring.count += 1
	end
	ring.last = event.seq
end

--- Oldest first. Events are shallow-copied (and their details too), so callers cannot change what the history keeps.
local function list(ring: EventRing, limit: number?): { Event }
	local count = ring.count
	local take = if limit ~= nil then math.clamp(math.floor(limit), 0, count) else count
	local out: { Event } = {}
	local start = ring.nextIndex - count -- index of the oldest kept event (may wrap)
	for i = count - take + 1, count do
		local index = start + i - 1
		if index < 1 then
			index += ring.capacity
		end
		local event = table.clone(ring.items[index])
		local details = event.details
		if details ~= nil then
			event.details = table.clone(details)
		end
		out[#out + 1] = event
	end
	return out
end

local function record(history: HistoryState, event: Event)
	push(history.recent, event)
	local key = event.key
	if key == nil then
		return
	end
	local ring = history.keys[key]
	if ring == nil then
		if history.keyCount >= history.maxKeys then
			-- drop the key that has been quiet the longest (a scan, but only when a new key appears and the map is full)
			local oldestKey: string? = nil
			local oldest = math.huge
			for k, r in history.keys do
				if r.last < oldest then
					oldest = r.last
					oldestKey = k
				end
			end
			if oldestKey ~= nil then
				history.keys[oldestKey] = nil
				history.keyCount -= 1
			end
		end
		ring = newRing(history.perKey)
		history.keys[key] = ring
		history.keyCount += 1
	end
	push(ring :: EventRing, event)
end

------------------------------------------------------------------------------------------------------------------------
-- emitting
------------------------------------------------------------------------------------------------------------------------

local function deliver(runtime: Runtime)
	local state = runtime.events
	if state == nil then
		return
	end
	local batch = state.pending
	state.pending = nil
	if batch == nil or runtime.destroyed then
		release(runtime)
		return
	end
	local sinks = table.clone(state.sinks) -- an observer may disconnect (itself or others) while we iterate
	for _, event in batch do
		for _, sink in sinks do
			if sink.store == nil or sink.store == event.store then
				local ok: boolean, problem: any = pcall(sink.fn :: any, event)
				if not ok then
					local metrics = runtime.metrics
					metrics.observerErrors += 1
					if metrics.observerErrors == 1 then
						runtime.env.log("warn", `[Retriever] an event observer raised (further observer errors are only counted): {tostring(problem)}`)
					end
				end
			end
		end
	end
	release(runtime)
end

--- Records an event. Call only when `runtime.events ~= nil` (the caller checks, so a quiet runtime allocates nothing).
function Events.emit(
	runtime: Runtime,
	store: string,
	key: string?,
	eventType: Types.EventType,
	fields: {
		reason: string?,
		error: Types.ErrorKind?,
		cause: string?,
		seconds: number?,
		revision: number?,
		details: { [string]: any }?,
	}?
)
	local state = runtime.events
	if state == nil or runtime.destroyed then
		return
	end
	local history = state.histories[store]
	local observed = false
	for _, sink in state.sinks do
		if sink.store == nil or sink.store == store then
			observed = true
			break
		end
	end
	if history == nil and not observed then
		return
	end
	local metrics = runtime.metrics
	metrics.eventSeq += 1
	metrics.eventsEmitted += 1
	local event: Event = {
		type = eventType,
		seq = metrics.eventSeq,
		store = store,
		key = key,
		time = runtime.env.time(),
	}
	if fields ~= nil then
		event.reason = fields.reason
		event.error = fields.error
		event.cause = fields.cause
		event.seconds = fields.seconds
		event.revision = fields.revision
		local details = fields.details
		if details ~= nil then
			-- a fresh table from the call site; frozen so no observer can change what others and the history see
			event.details = if table.isfrozen(details) then details else table.freeze(details)
		end
	end
	-- One event object is shared by every observer and the history rings: freeze it so an observer cannot rewrite it.
	table.freeze(event :: any) -- cast: the new solver types a frozen table as read-only, which no longer matches Event
	if history ~= nil then
		record(history, event)
	end
	if observed then
		local pending = state.pending
		if pending == nil then
			state.pending = { event }
			runtime.env.defer(deliver, runtime)
		else
			pending[#pending + 1] = event
		end
	end
end

------------------------------------------------------------------------------------------------------------------------
-- public API
------------------------------------------------------------------------------------------------------------------------

--- Calls `fn(event)` for every event of `store` (every store of the runtime when `store` is nil), in order, from a deferred
--- thread. Returns a disconnect function. Events (and their `details`) are frozen: copy one to annotate it. Observers should
--- not yield: a yielding observer delays the rest of its batch, and a later batch may be delivered meanwhile.
function Events.observe(runtime: Runtime, store: string?, fn: (event: Event) -> ()): () -> ()
	if type(fn) ~= "function" then
		error("[Retriever] observe needs a function (event) -> ()", 3)
	end
	local state = stateOf(runtime)
	local sink: Internal.EventSink = { fn = fn, store = store }
	table.insert(state.sinks, sink)
	return function()
		local current = runtime.events
		if current == nil then
			return
		end
		local index = table.find(current.sinks, sink)
		if index ~= nil then
			table.remove(current.sinks, index)
		end
		release(runtime)
	end
end

local function limitOption(value: any, name: string, default: number): number
	if value == nil then
		return default
	end
	if type(value) ~= "number" or value ~= value or value < 1 or value > 100000 or value % 1 ~= 0 then
		error(`[Retriever] history option {name} must be a whole number between 1 and 100000, got {tostring(value)}`, 4)
	end
	return value
end

local History = {}
History.__index = History

type HistoryHandle = {
	runtime: Runtime,
	store: string,
	state: HistoryState?,
}

--- Starts (or returns the running) history for `store`. Calling it again with other limits replaces the history.
function Events.history(runtime: Runtime, store: string, options: Types.HistoryOptions?): Types.History
	local opts: Types.HistoryOptions = options or {}
	local perKey = limitOption(opts.perKey, "perKey", 32)
	local maxKeys = limitOption(opts.keys, "keys", 256)
	local capacity = limitOption(opts.capacity, "capacity", 256)
	local state = stateOf(runtime)
	local existing = state.histories[store]
	local history: HistoryState
	if existing ~= nil and existing.perKey == perKey and existing.maxKeys == maxKeys and existing.recent.capacity == capacity then
		history = existing
	else
		history = { perKey = perKey, maxKeys = maxKeys, recent = newRing(capacity), keys = {}, keyCount = 0 }
		state.histories[store] = history
	end
	local handle: HistoryHandle = { runtime = runtime, store = store, state = history }
	return setmetatable(handle, History) :: any
end

--- The history recorded for `key` of `store`, or nil when no history is enabled (used by admin:inspect).
function Events.historyFor(runtime: Runtime, store: string, key: string): { Event }?
	local state = runtime.events
	local history = if state ~= nil then state.histories[store] else nil
	if history == nil then
		return nil
	end
	local ring = history.keys[key]
	return if ring ~= nil then list(ring, nil) else {}
end

--- The live history state behind a handle (nil once stopped or replaced).
local function live(self: HistoryHandle): HistoryState?
	local state = self.runtime.events
	local current = if state ~= nil then state.histories[self.store] else nil
	if current ~= nil and current == self.state then
		return current
	end
	return nil
end

function History.get(self: HistoryHandle, key: string): { Event }
	local history = live(self)
	local ring = if history ~= nil then history.keys[key] else nil
	return if ring ~= nil then list(ring, nil) else {}
end

function History.recent(self: HistoryHandle, limit: number?): { Event }
	local history = live(self)
	return if history ~= nil then list(history.recent, limit) else {}
end

function History.clear(self: HistoryHandle)
	local history = live(self)
	if history ~= nil then
		history.recent = newRing(history.recent.capacity)
		history.keys = {}
		history.keyCount = 0
	end
end

function History.stop(self: HistoryHandle)
	local history = live(self)
	if history ~= nil then
		local state = self.runtime.events :: EventsState
		state.histories[self.store] = nil
		release(self.runtime)
	end
	self.state = nil
end

--- Counters for `runtime:metrics()`.
function Events.stats(runtime: Runtime): { emitted: number, observers: number, observerErrors: number }
	local state = runtime.events
	local metrics = runtime.metrics
	return {
		emitted = metrics.eventsEmitted,
		observers = if state ~= nil then #state.sinks else 0,
		observerErrors = metrics.observerErrors,
	}
end

return Events
