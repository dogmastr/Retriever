--!strict
--[[
	Handoff acceleration over MessagingService. Purely an optimization: correctness never depends on a message arriving.

	One subscription per SERVER (topic "RT:<jobId>"), not one per profile (ProfileStore subscribes per active profile and hits
	the per-server subscription quota). Two message kinds, both tiny:

	  wake    {t="wake",    s=<store>, k=<key>}  sent by a server that wants a profile this server owns: "save now, you will see
	                                              my marker and release". The owner turns it into an immediate save.
	  release {t="release", s=<store>, k=<key>}  sent by the owner after it released a profile someone asked for: the waiter's
	                                              load retries right away instead of waiting out its poll delay.

	Every publish/subscribe call runs in its own thread under pcall: MessagingService calls can yield for a long time or throw,
	and the library must never wait on them.
]]

local Internal = require(script.Parent.Internal)
local Profile = require(script.Parent.Profile)
local Scheduler = require(script.Parent.Scheduler)

type Runtime = Internal.Runtime

local Handoff = {}

local function topicFor(jobId: string): string
	return "RT:" .. jobId
end

local function onMessage(runtime: Runtime, message: any)
	if type(message) ~= "table" then
		return
	end
	local msg = message :: { t: any, s: any, k: any }
	local store = runtime.stores[msg.s]
	local key = msg.k
	if store == nil or type(key) ~= "string" then
		return
	end
	if msg.t == "wake" then
		local profile = store.profiles[key]
		if profile ~= nil and profile.state == "active" then
			Profile.requestSave(profile)
		end
	elseif msg.t == "release" then
		local waiting = store.waiting
		local req = if waiting ~= nil then waiting[key] else nil
		if req ~= nil then
			if req.heapIndex > 0 then
				-- asleep between attempts: fire the waiting load's retry now
				Scheduler.schedule(runtime.scheduler, req :: any, runtime.env.clock())
			else
				-- An attempt is on the wire or queued. Scheduling the request now would start a SECOND attempt next to it (two
				-- acquires of one lock bump the epoch twice, and the session could end up one epoch behind the record). Leave a
				-- note instead: the attempt's own re-arm reads it and retries at once.
				req.released = true
			end
		end
	end
end

--- Subscribes this server's topic once. Safe to call repeatedly.
function Handoff.ensureSubscribed(runtime: Runtime)
	local state = runtime.handoff
	if state.subscribed or runtime.env.messaging == nil then
		return
	end
	state.subscribed = true
	local env = runtime.env
	local messaging = env.messaging :: Internal.Messaging
	env.spawn(function()
		local ok, problem = pcall(messaging.subscribe, topicFor(env.jobId), function(message: any)
			onMessage(runtime, message)
		end)
		if not ok then
			state.subscribed = false -- try again on the next contention
			env.log("warn", `[Retriever] could not subscribe to the handoff topic (handoff falls back to polling): {tostring(problem)}`)
		end
	end)
end

local function publish(runtime: Runtime, jobId: string, payload: { t: string, s: string, k: string })
	local env = runtime.env
	local messaging = env.messaging
	if messaging == nil then
		return
	end
	env.spawn(function()
		xpcall(messaging.publish, function(problem: any): any
			env.log("debug", `[Retriever] handoff publish failed (polling will cover it): {tostring(problem)}`)
			return problem
		end, topicFor(jobId), payload)
	end)
end

--- Asks `ownerJob` to save (and so notice our marker and release) `key`.
function Handoff.wakeOwner(runtime: Runtime, ownerJob: string, storeName: string, key: string)
	Handoff.ensureSubscribed(runtime)
	publish(runtime, ownerJob, { t = "wake", s = storeName, k = key })
end

--- Tells `waiterJob` that we released `key`.
function Handoff.notifyReleased(runtime: Runtime, waiterJob: string, storeName: string, key: string)
	publish(runtime, waiterJob, { t = "release", s = storeName, k = key })
end

return Handoff
