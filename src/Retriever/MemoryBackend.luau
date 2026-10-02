--!strict
--[[
	In-memory DataStore provider.

	Used when Studio has no API access (so a beginner's first test run works and says why nothing persists), and by unit tests
	and examples that do not need the full simulator. It mirrors the engine behaviours the library relies on:

	* UpdateAsync runs the transform synchronously, never yields inside it, hands it a fresh deep copy of the stored value and
	  stores a deep copy of what it returns (so later mutation of the returned table cannot corrupt the store).
	* Returning nil from the transform cancels the write.
	* UserIds and metadata are cleared unless the transform returns them again.
	* Every write creates a new version; `listVersions`/`getVersion` read the history.
	* Values are checked with `Validate.storable`, so unstorable data fails here the way it fails live.

	It does not simulate latency, throttling or failures; the deterministic simulator in tests/ does.
]]

local Types = require(script.Parent.Types)
local Util = require(script.Parent.Util)
local Validate = require(script.Parent.Validate)

type Backend = Types.Backend
type KeyInfoLike = Types.KeyInfoLike
type TransformFn = Types.TransformFn

type Version = {
	value: any,
	version: number,
	created: number, -- first write of the key (ms)
	updated: number, -- this write (ms)
	userIds: { number },
	metadata: { [string]: any },
	deleted: boolean,
}

type Entry = {
	versions: { Version },
}

local MemoryBackend = {}

local function keyInfo(v: Version): KeyInfoLike
	local info: KeyInfoLike = {
		Version = string.format("%016x.%010d", 0, v.version),
		CreatedTime = v.created,
		UpdatedTime = v.updated,
		GetUserIds = function(_self: KeyInfoLike): { number }
			return table.clone(v.userIds)
		end,
		GetMetadata = function(_self: KeyInfoLike): { [string]: any }
			return Util.deepCopy(v.metadata)
		end,
	}
	return info
end

--- `time` returns wall-clock seconds. Returns a Provider with unlimited budgets.
function MemoryBackend.new(time: () -> number): Types.Provider
	local stores: { [string]: { [string]: Entry } } = {}

	local function open(name: string, scope: string?): Backend
		local id = name .. "\0" .. (scope or "global")
		local data: { [string]: Entry } = stores[id] or {}
		stores[id] = data

		local function latest(key: string): Version?
			local entry = data[key]
			if entry == nil then
				return nil
			end
			local v = entry.versions[#entry.versions]
			if v.deleted then
				return nil
			end
			return v
		end

		local function append(
			key: string,
			value: any,
			userIds: { number }?,
			metadata: { [string]: any }?,
			deleted: boolean
		): Version
			local entry = data[key]
			if entry == nil then
				entry = { versions = {} }
				data[key] = entry
			end
			local versions = (entry :: Entry).versions
			local previous = versions[#versions]
			local nowMs = math.floor(time() * 1000)
			local v: Version = {
				value = if deleted then nil else Util.deepCopy(value),
				version = #versions + 1,
				created = if previous ~= nil then previous.created else nowMs,
				updated = nowMs,
				userIds = if userIds ~= nil then table.clone(userIds) else {},
				metadata = if metadata ~= nil then Util.deepCopy(metadata) else {},
				deleted = deleted,
			}
			versions[#versions + 1] = v
			return v
		end

		local function checkKey(key: string)
			if type(key) ~= "string" or key == "" or #key > 50 then
				error("101: key name must be a non-empty string of at most 50 characters", 3)
			end
		end

		local function checkValue(value: any)
			local ok, message = Validate.storable(value)
			if not ok then
				error(`104: Cannot store value in data store: {message}`, 3)
			end
		end

		local backend: Backend = {
			update = function(key: string, transform: TransformFn): (any, KeyInfoLike?)
				checkKey(key)
				local current = latest(key)
				local old: any = if current ~= nil then Util.deepCopy(current.value) else nil
				local newValue, userIds, metadata = transform(old, if current ~= nil then keyInfo(current) else nil)
				if newValue == nil then
					return old, if current ~= nil then keyInfo(current) else nil
				end
				checkValue(newValue)
				local v = append(key, newValue, userIds, metadata, false)
				return Util.deepCopy(newValue), keyInfo(v)
			end,
			get = function(key: string, _useCache: boolean?): (any, KeyInfoLike?)
				checkKey(key)
				local current = latest(key)
				if current == nil then
					return nil, nil
				end
				return Util.deepCopy(current.value), keyInfo(current)
			end,
			set = function(key: string, value: any, userIds: { number }?, metadata: { [string]: any }?): string
				checkKey(key)
				checkValue(value)
				local v = append(key, value, userIds, metadata, false)
				return keyInfo(v).Version
			end,
			remove = function(key: string): (any, KeyInfoLike?)
				checkKey(key)
				local current = latest(key)
				if current == nil then
					return nil, nil
				end
				local old = current.value
				append(key, nil, nil, nil, true)
				return old, keyInfo(current)
			end,
			increment = function(key: string, delta: number?, userIds: { number }?): number
				checkKey(key)
				local current = latest(key)
				local base: number = 0
				if current ~= nil and type(current.value) == "number" then
					base = current.value :: number
				end
				local value = base + (delta or 1)
				append(key, value, userIds, nil, false)
				return value
			end,
			listKeys = function(prefix: string?, pageSize: number?, cursor: string?): Types.KeyPage
				local names: { string } = {}
				for key, entry in data do
					local last = entry.versions[#entry.versions]
					if not last.deleted and (prefix == nil or prefix == "" or string.sub(key, 1, #prefix) == prefix) then
						names[#names + 1] = key
					end
				end
				table.sort(names)
				local start = if cursor ~= nil then tonumber(cursor) or 0 else 0
				local size = pageSize or 100
				local page: { string } = {}
				for i = start + 1, math.min(start + size, #names) do
					page[#page + 1] = names[i]
				end
				local nextCursor: string? = if start + size < #names then tostring(start + size) else nil
				return { keys = page, cursor = nextCursor }
			end,
			listVersions = function(
				key: string,
				ascending: boolean?,
				minTime: number?,
				maxTime: number?,
				pageSize: number?,
				cursor: string?
			): Types.VersionPage
				-- times are milliseconds; 0 or nil means unbounded (as in ListVersionsAsync)
				local entry = data[key]
				local out: { Types.VersionEntry } = {}
				if entry == nil then
					return { versions = out, cursor = nil }
				end
				local low = if minTime ~= nil and minTime > 0 then minTime else -math.huge
				local high = if maxTime ~= nil and maxTime > 0 then maxTime else math.huge
				local list: { Version } = {}
				for _, v in entry.versions do
					if v.updated >= low and v.updated <= high then
						list[#list + 1] = v
					end
				end
				local n = #list
				local start = if cursor ~= nil then tonumber(cursor) or 0 else 0
				local size = pageSize or 100
				for i = start + 1, math.min(start + size, n) do
					local v = if ascending == false then list[n - i + 1] else list[i]
					out[#out + 1] = { version = keyInfo(v).Version, createdTime = v.updated, deleted = v.deleted }
				end
				local nextCursor: string? = if start + size < n then tostring(start + size) else nil
				return { versions = out, cursor = nextCursor }
			end,
			getVersion = function(key: string, version: string): (any, KeyInfoLike?)
				local entry = data[key]
				if entry == nil then
					error("404: key not found", 2)
				end
				for _, v in entry.versions do
					local info = keyInfo(v)
					if info.Version == version then
						return Util.deepCopy(v.value), info
					end
				end
				error("404: version not found", 2)
			end,
		}
		return backend
	end

	return {
		open = open,
		budget = function(_kind: Types.BudgetKind): number
			return 1e9
		end,
		isLive = function(): boolean
			return false -- nothing here reaches production data
		end,
	}
end

return MemoryBackend
