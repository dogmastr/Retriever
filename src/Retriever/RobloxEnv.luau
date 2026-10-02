--!strict
--[[
	The real Roblox environment: adapters from engine services to the `Env` interface. Only this module touches `game`,
	`task`, `Enum` or `Instance`, and it is loaded lazily, so the rest of the library runs unchanged under the simulator
	and under plain Luau.
]]

local MemoryBackend = require(script.Parent.MemoryBackend)
local Types = require(script.Parent.Types)

type Env = Types.Env
type Backend = Types.Backend
type BudgetKind = Types.BudgetKind

local RobloxEnv = {}

--- The request budgets a kind of call consumes. Each component lists candidate `Enum.DataStoreRequestType` names, modern first;
--- the first that exists on this engine build wins (the legacy members are deprecated). `UpdateAsync` consumes BOTH a read and
--- a write unit, so its budget is the smaller of the two. Only the per-server budget is observable; the experience-level budget
--- shows up as `...ExperienceThrottled` errors, which the dispatcher reacts to.
local BUDGET_COMPONENTS: { [string]: { { string } } } = {
	get = { { "StandardRead", "GetAsync" } },
	update = { { "StandardRead", "GetAsync" }, { "StandardWrite", "SetIncrementAsync" } },
	set = { { "StandardWrite", "SetIncrementAsync" } },
	list = { { "StandardList", "ListAsync" } },
	getVersion = { { "StandardRead", "GetVersionAsync" } },
	removeVersion = { { "StandardRemove", "RemoveVersionAsync" } },
}

local function resolveBudgetEnums(): { [string]: { any } }
	local byName: { [string]: any } = {}
	for _, item in Enum.DataStoreRequestType:GetEnumItems() do
		byName[item.Name] = item
	end
	local resolved: { [string]: { any } } = {}
	for kind, components in BUDGET_COMPONENTS do
		local items: { any } = {}
		for _, candidates in components do
			for _, name in candidates do
				if byName[name] ~= nil then
					items[#items + 1] = byName[name]
					break
				end
			end
		end
		resolved[kind] = items
	end
	return resolved
end

local function realBackend(dataStore: DataStore): Backend
	local uncached = Instance.new("DataStoreGetOptions")
	uncached.UseCache = false

	local backend: Backend = {
		update = function(key: string, transform: Types.TransformFn): (any, Types.KeyInfoLike?)
			local value, info = dataStore:UpdateAsync(key, transform :: any)
			return value, info :: any
		end,
		get = function(key: string, useCache: boolean?): (any, Types.KeyInfoLike?)
			local value, info
			if useCache == false then
				value, info = dataStore:GetAsync(key, uncached)
			else
				value, info = dataStore:GetAsync(key)
			end
			return value, info :: any
		end,
		set = function(key: string, value: any, userIds: { number }?, metadata: { [string]: any }?): string
			local options: DataStoreSetOptions? = nil
			if metadata ~= nil then
				local created = Instance.new("DataStoreSetOptions")
				created:SetMetadata(metadata)
				options = created
			end
			return dataStore:SetAsync(key, value, userIds, options)
		end,
		remove = function(key: string): (any, Types.KeyInfoLike?)
			local value, info = dataStore:RemoveAsync(key)
			return value, info :: any
		end,
		increment = function(key: string, delta: number?, userIds: { number }?): number
			local value = dataStore:IncrementAsync(key, delta, userIds)
			return value
		end,
		listKeys = function(prefix: string?, pageSize: number?, cursor: string?): Types.KeyPage
			local pages = dataStore:ListKeysAsync(prefix or "", pageSize, cursor)
			local keys: { string } = {}
			for _, item in pages:GetCurrentPage() do
				keys[#keys + 1] = item.KeyName
			end
			local nextCursor: string? = nil
			if not pages.IsFinished then
				nextCursor = (pages :: any).Cursor
			end
			return { keys = keys, cursor = nextCursor }
		end,
		listVersions = function(
			key: string,
			ascending: boolean?,
			minTime: number?,
			maxTime: number?,
			pageSize: number?,
			cursor: string?
		): Types.VersionPage
			-- DataStoreVersionPages has no Cursor property, so the cursor is the time (ms) of the last version returned and the
			-- next page narrows the time window past it. Versions are at most one per key and hour, so ties do not occur.
			local isAscending = ascending ~= false
			local direction = if isAscending then Enum.SortDirection.Ascending else Enum.SortDirection.Descending
			local low, high = minTime or 0, maxTime or 0
			local after = if cursor ~= nil then tonumber(cursor) else nil
			if after ~= nil then
				if isAscending then
					low = math.max(low, after + 1)
				else
					high = if high > 0 then math.min(high, after - 1) else after - 1
				end
			end
			local pages = dataStore:ListVersionsAsync(key, direction, low, high, pageSize or 0)
			local versions: { Types.VersionEntry } = {}
			local last: number? = nil
			for _, item in pages:GetCurrentPage() do
				versions[#versions + 1] = { version = item.Version, createdTime = item.CreatedTime, deleted = item.IsDeleted }
				last = item.CreatedTime
			end
			local nextCursor: string? = nil
			if not pages.IsFinished and last ~= nil then
				nextCursor = tostring(last)
			end
			return { versions = versions, cursor = nextCursor }
		end,
		getVersion = function(key: string, version: string): (any, Types.KeyInfoLike?)
			local value, info = dataStore:GetVersionAsync(key, version)
			return value, info :: any
		end,
	}
	return backend
end

local function wallTime(): number
	return os.time()
end

local function realProvider(useMemoryFallback: () -> boolean): Types.Provider
	local DataStoreService = game:GetService("DataStoreService")
	local budgetEnums = resolveBudgetEnums()
	local memory: Types.Provider? = nil

	return {
		open = function(name: string, scope: string?): Backend
			if useMemoryFallback() then
				local provider = memory
				if provider == nil then
					provider = MemoryBackend.new(wallTime)
					memory = provider
				end
				return (provider :: Types.Provider).open(name, scope)
			end
			return realBackend(DataStoreService:GetDataStore(name, scope))
		end,
		budget = function(kind: Types.BudgetKind): number
			local items = budgetEnums[kind]
			if items == nil or #items == 0 then
				return 1e9
			end
			local smallest = 1e9
			for _, item in items do
				local value = DataStoreService:GetRequestBudgetForRequestType(item)
				if value < smallest then
					smallest = value
				end
			end
			return smallest
		end,
		isLive = function(): boolean
			return not useMemoryFallback()
		end,
	}
end

--- `MarketplaceService:BindReceiptHandler` is new (2026) and missing from older engines and type definitions, so it is looked
--- up dynamically; when it is absent the adapter only offers the classic ProcessReceipt slot.
local function marketplaceAdapter(MarketplaceService: MarketplaceService): Types.MarketplaceAdapter
	local adapter: Types.MarketplaceAdapter = {
		setProcessReceipt = function(callback)
			MarketplaceService.ProcessReceipt = function(info)
				local decision = callback(info :: any)
				if decision == "granted" then
					return Enum.ProductPurchaseDecision.PurchaseGranted
				end
				return Enum.ProductPurchaseDecision.NotProcessedYet
			end
		end,
	}
	local service = MarketplaceService :: any
	local ok, bind = pcall(function()
		return service.BindReceiptHandler
	end)
	local enums = Enum :: any
	local okEnums, receiptType, receiptDecision = pcall(function()
		return enums.ReceiptType.DeveloperProduct, enums.ReceiptDecision
	end)
	if ok and type(bind) == "function" and okEnums and receiptType ~= nil and receiptDecision ~= nil then
		adapter.bindReceiptHandler = function(productIds: { number }?, callback: (info: Types.ReceiptInfo) -> Types.ReceiptDecision): () -> ()
			local connection = service:BindReceiptHandler(receiptType, function(info: any): any
				local decision = callback(info)
				if decision == "granted" then
					return receiptDecision.Processed
				end
				return receiptDecision.NotProcessedYet
			end, productIds)
			return function()
				connection:Disconnect()
			end
		end
	end
	return adapter
end

type RestartSubscribe = (callback: (restartTime: number?, source: string?) -> ()) -> () -> ()

--- `DataModel.ServerRestartScheduled(restartTime: DateTime, source: Enum.CloseReason, attributes)` (2026). Best effort and
--- absent on older engines, so it is optional: BindToClose stays the real shutdown path.
local function restartSignal(): RestartSubscribe?
	local ok, signal = pcall(function()
		return (game :: any).ServerRestartScheduled
	end)
	if not ok or signal == nil then
		return nil
	end
	local subscribe: RestartSubscribe = function(callback)
		local connection = signal:Connect(function(restartTime: any, source: any)
			local at: number? = nil
			if typeof(restartTime) == "DateTime" then
				at = restartTime.UnixTimestampMillis / 1000
			elseif type(restartTime) == "number" then
				at = restartTime
			end
			local sourceName: string? = if typeof(source) == "EnumItem" then source.Name else nil
			callback(at, sourceName)
		end)
		return function()
			connection:Disconnect()
		end
	end
	return subscribe
end

--- Builds the environment for this server. `forceMemory` runs against an in-memory store (for Studio sessions without API
--- access, or when the developer wants a sandbox).
function RobloxEnv.create(forceMemory: boolean?): Env
	local HttpService = game:GetService("HttpService")
	local RunService = game:GetService("RunService")
	local Players = game:GetService("Players")
	local MessagingService = game:GetService("MessagingService")
	local MarketplaceService = game:GetService("MarketplaceService")

	local isStudio = RunService:IsStudio()
	local jobId = game.JobId
	if jobId == "" then
		jobId = "studio-" .. HttpService:GenerateGUID(false)
	end
	local rng = Random.new()

	local memoryFallback = forceMemory == true
	if isStudio and not memoryFallback then
		-- Studio without API access: probe once (this yields briefly) and fall back to memory with a clear message.
		local ok, problem = pcall(function()
			game:GetService("DataStoreService"):GetDataStore("__retriever_probe"):GetAsync("probe")
		end)
		if not ok then
			memoryFallback = true
			warn(
				"[Retriever] DataStores are not available in this Studio session ("
					.. tostring(problem)
					.. "). Data will NOT persist. Enable 'Studio Access to API Services' in Game Settings > Security (and publish the place) to test real saving."
			)
		end
	end

	local env: Env = {
		jobId = jobId,
		placeId = game.PlaceId,
		isStudio = isStudio,
		time = wallTime,
		clock = os.clock,
		random = function()
			return rng:NextNumber()
		end,
		guid = function()
			return HttpService:GenerateGUID(false)
		end,
		spawn = task.spawn :: any,
		defer = task.defer :: any,
		wait = task.wait,
		cancel = task.cancel,
		provider = realProvider(function()
			return memoryFallback
		end),
		messaging = {
			publish = function(topic, message)
				MessagingService:PublishAsync(topic, message)
			end,
			subscribe = function(topic, handler)
				local connection = MessagingService:SubscribeAsync(topic, function(packet)
					handler(packet.Data)
				end)
				return function()
					connection:Disconnect()
				end
			end,
		},
		players = {
			all = function()
				return Players:GetPlayers() :: any
			end,
			onAdded = function(fn)
				local connection = Players.PlayerAdded:Connect(fn :: any)
				return function()
					connection:Disconnect()
				end
			end,
			onRemoving = function(fn)
				local connection = Players.PlayerRemoving:Connect(fn :: any)
				return function()
					connection:Disconnect()
				end
			end,
			isPresent = function(player)
				return (player :: any).Parent == Players
			end,
		},
		marketplace = marketplaceAdapter(MarketplaceService),
		json = {
			encode = function(value)
				return HttpService:JSONEncode(value)
			end,
			decode = function(text)
				return HttpService:JSONDecode(text)
			end,
		},
		bindToClose = function(callback)
			game:BindToClose(callback)
		end,
		onRestartScheduled = restartSignal(),
		log = function(level, message)
			if level == "warn" or level == "error" then
				warn(message)
			else
				print(message)
			end
		end,
	}

	return env
end

return RobloxEnv
