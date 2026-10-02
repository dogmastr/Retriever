--!strict
--[[
	Player identity and data keys.

	Roblox is rolling out domain-scoped user ids (2026): a player whose first visit to an experience happens after the rollout
	gets a per-experience id, returning players keep their global id. `Player.User` is the new standard handle, and the
	documentation says "for data store keys within a single game, use `user.Id` directly". `Player.UserId` remains, and for
	returning players both are the same global number, which is why the default key below is backwards compatible with keys
	made from `tostring(player.UserId)`.

	Documented default (used by `Retriever.players` when no `key` function is given):

	    key = prefix .. tostring(player.User.Id)     -- when the engine exposes Player.User
	    key = prefix .. tostring(player.UserId)      -- otherwise (older engines, fakes)

	with `prefix = ""`. Never use one experience's numeric ids to identify a player in another experience.
]]

local Types = require(script.Parent.Types)

type PlayerLike = Types.PlayerLike

export type KeyOptions = {
	--- Prepended to the id, e.g. "Player_". Default "" (keys look like "123456").
	prefix: string?,
	--- "user" (default): `Player.User.Id` when available, else `Player.UserId`. "userId": always `Player.UserId` (legacy).
	source: ("user" | "userId")?,
}

local UserKey = {}

--- The id used for data keys. Reading `Player.User` on an engine that does not have the property raises, so it is guarded.
function UserKey.id(player: PlayerLike, source: ("user" | "userId")?): number
	if source ~= "userId" then
		local ok, user = pcall(function(): any
			return (player :: any).User
		end)
		if ok and user ~= nil then
			local okId, id = pcall(function(): any
				return user.Id
			end)
			if okId and type(id) == "number" then
				return id
			end
		end
	end
	local userId = player.UserId
	if type(userId) ~= "number" then
		error(`[Retriever] userKey(player) needs a Player (or an object with a numeric UserId), got {typeof(player)}`, 3)
	end
	return userId
end

--- DataStore key for `player` (see the module comment for the documented default).
function UserKey.key(player: PlayerLike, options: KeyOptions?): string
	local prefix = ""
	local source: ("user" | "userId")? = nil
	if options ~= nil then
		prefix = options.prefix or ""
		source = options.source
		if source ~= nil and source ~= "user" and source ~= "userId" then
			error(`[Retriever] userKey option source must be "user" or "userId", got {tostring(source)}`, 2)
		end
	end
	local key = prefix .. string.format("%d", UserKey.id(player, source))
	if #key > 50 then
		error(`[Retriever] key "{key}" is longer than 50 characters (DataStore key limit); use a shorter prefix`, 2)
	end
	return key
end

--- True when `userId` (for example `ReceiptInfo.PlayerId`) identifies `player` under either id.
function UserKey.matches(player: PlayerLike, userId: number): boolean
	if player.UserId == userId then
		return true
	end
	return UserKey.id(player, "user") == userId
end

return UserKey
