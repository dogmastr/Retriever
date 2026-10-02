--!strict
--[[
	Automatic player lifecycle: load when a player joins, release when they leave, flush on shutdown.

	Handles the mistakes that cause stuck sessions in practice (see the community failure digest, beginner mistakes 1, 7, 8):
	* players already in the server when the binding is created,
	* a player who leaves while their profile is still loading (the load is cancelled and any lock taken in the meantime is
	  released),
	* duplicate PlayerAdded events for the same player (one load per player),
	* a failed load: the player is told to rejoin; no default data is ever substituted,
	* a session that ends while the player is still here (ownership lost): the player is removed instead of playing on data
	  that will not be saved.
]]

local Errors = require(script.Parent.Errors)
local Internal = require(script.Parent.Internal)
local Profile = require(script.Parent.Profile)
local Store = require(script.Parent.Store)
local Types = require(script.Parent.Types)
local UserKey = require(script.Parent.UserKey)

type StoreImpl = Internal.StoreImpl
type ProfileImpl = Internal.ProfileImpl
type PlayerLike = Types.PlayerLike
type RetrieverError = Types.RetrieverError
type EndReason = Types.EndReason

export type Options<T> = {
	--- Called once the profile is ready. May yield.
	onLoaded: ((player: PlayerLike, profile: Types.Profile<T>) -> ())?,
	--- Called when the profile could not be loaded. Default: kick the player with a short message.
	onFailed: ((player: PlayerLike, err: RetrieverError) -> ())?,
	--- Called when the session ends while the player is still present. Default: kick the player.
	onEnded: ((player: PlayerLike, reason: EndReason, err: RetrieverError?) -> ())?,
	--- DataStore key for a player. Default: `Retriever.userKey(player)`, i.e. tostring(player.User.Id) when the engine has
	--- `Player.User`, else tostring(player.UserId) (the same number for returning players, so existing keys keep working).
	key: ((player: PlayerLike) -> string)?,
	--- Seconds to wait for a locked or unavailable profile. Default 90.
	timeout: number?,
	--- Associate the player's UserId with new profiles for GDPR. Default true.
	associateUserId: boolean?,
}

export type Binding<T> = {
	--- The loaded profile of `player`, if any.
	get: (self: Binding<T>, player: PlayerLike) -> Types.Profile<T>?,
	--- Yields until the player's profile is loaded; returns nil if loading failed or the player left.
	wait: (self: Binding<T>, player: PlayerLike) -> Types.Profile<T>?,
	--- Stops handling players (does not close loaded sessions; call store:closeAll() for that).
	disconnect: (self: Binding<T>) -> (),
}

local KICK_LOAD_FAILED = "Your data could not be loaded, so you were removed to protect it. Please rejoin."
local KICK_SESSION_ENDED = "Your session ended because your data is being used by another server. Please rejoin."

type Waiter = { thread: thread, parked: boolean, result: ProfileImpl?, settled: boolean }
type LoadingMap = { [number]: PlayerLike }
type WaitersMap = { [PlayerLike]: { Waiter } }

--- What other library modules (receipts) need from a binding. Not part of the public API.
export type Internals = {
	impl: StoreImpl,
	adapter: Types.PlayersAdapter,
	--- The present player with this id (`UserId` or `User.Id`), if any.
	playerOf: (userId: number) -> PlayerLike?,
	--- The loaded profile of the player with this `UserId`, if any.
	profileOf: (userId: number) -> ProfileImpl?,
}

local INTERNALS = "__retriever"

local Players = {}

function Players.bind(impl: StoreImpl, options: Options<any>?): Binding<any>
	local runtime = impl.runtime
	local env = runtime.env
	local adapter = env.players
	if adapter == nil then
		error("[Retriever] Retriever.players needs a Players service. Pass an env with a `players` adapter when running outside Roblox.", 2)
	end
	local opts: Options<any> = options or {}
	local keyFor = opts.key or function(player: PlayerLike): string
		return UserKey.key(player)
	end

	local profiles: { [number]: ProfileImpl } = {}
	-- Keyed by UserId, holding the Player object whose load is in flight: a player who leaves and rejoins gets a new object
	-- with the same UserId, and the old load (still cancelling) must not swallow the rejoin.
	local loading: LoadingMap = {}
	local waiters: WaitersMap = {}
	local connected = true

	local function settle(player: PlayerLike, profile: ProfileImpl?)
		local list = waiters[player]
		if list == nil then
			return
		end
		waiters[player] = nil
		for _, w in list do
			w.settled = true
			if w.parked then
				if coroutine.status(w.thread) == "suspended" then
					env.spawn(w.thread, profile)
				end
			else
				w.result = profile
			end
		end
	end

	local function kick(player: PlayerLike, message: string)
		local ok = pcall(function()
			player:Kick(message)
		end)
		if not ok then
			env.log("warn", `[Retriever] could not kick {player.Name}`)
		end
	end

	local function handleAdded(player: PlayerLike)
		local userId = player.UserId
		if not connected or loading[userId] == player or profiles[userId] ~= nil then
			return
		end
		loading[userId] = player
		local ok, key = pcall(keyFor, player)
		if not ok or type(key) ~= "string" then
			if loading[userId] == player then
				loading[userId] = nil
			end
			env.log("error", `[Retriever] the key function passed to Retriever.players failed for {player.Name}: {tostring(key)}`)
			kick(player, KICK_LOAD_FAILED)
			settle(player, nil)
			return
		end

		local result = Store.load(impl, key, {
			timeout = opts.timeout,
			userIds = if opts.associateUserId ~= false then { userId } else nil,
			cancel = function()
				return not adapter.isPresent(player) or not connected
			end,
		})
		if loading[userId] == player then
			loading[userId] = nil
		end

		if not result.ok then
			local err = result.error
			settle(player, nil)
			if err.kind == "Cancelled" or err.kind == "ShuttingDown" then
				return
			end
			env.log("warn", Errors.format(err))
			if opts.onFailed ~= nil then
				opts.onFailed(player, err)
			else
				kick(player, KICK_LOAD_FAILED)
			end
			return
		end

		local profile = result.profile :: any
		if not adapter.isPresent(player) or not connected then
			Profile.close(profile, { timeout = 30 })
			settle(player, nil)
			return
		end
		profiles[userId] = profile
		Profile.onEnded(profile, function(reason, err)
			if profiles[userId] == profile then
				profiles[userId] = nil
			end
			if reason ~= "closed" and reason ~= "shutdown" and adapter.isPresent(player) then
				if err ~= nil then
					env.log("warn", Errors.format(err))
				end
				if opts.onEnded ~= nil then
					opts.onEnded(player, reason, err)
				else
					kick(player, KICK_SESSION_ENDED)
				end
			end
		end)
		settle(player, profile)

		local handler = opts.onLoaded
		if handler ~= nil then
			xpcall(handler, function(problem: any): any
				env.log("error", `[Retriever] onLoaded handler for {player.Name} failed: {tostring(problem)}`)
				return problem
			end, player, profile)
		end
	end

	local function handleRemoving(player: PlayerLike)
		local userId = player.UserId
		local profile = profiles[userId]
		if profile ~= nil then
			profiles[userId] = nil
			Profile.close(profile, { timeout = 60 })
		end
		settle(player, nil)
	end

	local disconnectAdded = adapter.onAdded(function(player)
		env.spawn(handleAdded, player)
	end)
	local disconnectRemoving = adapter.onRemoving(function(player)
		env.spawn(handleRemoving, player)
	end)
	for _, player in adapter.all() do
		env.spawn(handleAdded, player)
	end

	local binding: Binding<any> = {
		get = function(_self, player)
			return profiles[player.UserId] :: any
		end,
		wait = function(_self, player)
			local userId = player.UserId
			local existing = profiles[userId]
			if existing ~= nil then
				return existing :: any
			end
			if loading[userId] ~= player or not adapter.isPresent(player) then
				return nil
			end
			local waiter: Waiter = { thread = coroutine.running(), parked = false, result = nil, settled = false }
			local list = waiters[player]
			if list == nil then
				list = {}
				waiters[player] = list
			end
			list[#list + 1] = waiter
			if waiter.settled then
				return waiter.result :: any
			end
			waiter.parked = true
			return coroutine.yield() :: any
		end,
		disconnect = function(_self)
			connected = false
			disconnectAdded()
			disconnectRemoving()
		end,
	}
	local internals: Internals = {
		impl = impl,
		adapter = adapter,
		playerOf = function(userId: number): PlayerLike?
			-- an exact `UserId` match wins over a `User.Id` match, so ids from the two domains can never pick the wrong player
			local all = adapter.all()
			for _, player in all do
				if player.UserId == userId then
					return player
				end
			end
			for _, player in all do
				if UserKey.matches(player, userId) then
					return player
				end
			end
			return nil
		end,
		profileOf = function(userId: number): ProfileImpl?
			return profiles[userId]
		end,
	}
	local handle = binding :: any
	handle[INTERNALS] = internals
	return binding
end

--- The internals of a binding made by `Players.bind`, or nil for anything else.
function Players.internals(binding: any): Internals?
	if type(binding) ~= "table" then
		return nil
	end
	local internals = binding[INTERNALS]
	if type(internals) ~= "table" then
		return nil
	end
	return internals :: Internals
end

return Players
