--!strict
--[[
	Developer-product receipts granted exactly once, on top of `Retriever.players` and the idempotency ledger.

	    local receipts = Retriever.receipts(binding, {
	        [123456] = function(player, profile, receipt)
	            profile.data.coins += 100            -- runs inside profile:apply(receipt.PurchaseId, ...); must not yield
	        end,
	    })

	For every receipt Roblox delivers:
	1. Find the buyer on this server and wait (bounded) for their profile to finish loading.
	2. `apply(PurchaseId, grant)`: the effect and the purchase id are saved by the same write, so a redelivered receipt (another
	   poll, a rejoin, two servers at once, a crash and reload) finds the id and is never granted twice.
	3. Wait for a commit that contains the effect. Only a confirmed commit returns `PurchaseGranted`; on any doubt (the player is
	   not here or not loaded, the handler threw, the save failed, timed out, or its outcome is Unknown, the session was lost)
	   the answer is `NotProcessedYet`. Roblox keeps the purchase unresolved and delivers it again; the retry finds the id in the
	   ledger and only needs the commit.

	Timing: the whole decision is bounded by `timeout` (default 8 s). Roblox polls receipts every 10 s and reports "already being
	processed" when a handler is still running, so the helper answers before the next poll instead of waiting on a slow save.

	Installation happens synchronously inside `Retriever.receipts` (an unset ProcessReceipt auto-accepts and loses purchases, so
	call it at startup before anything yields). When the engine has `MarketplaceService:BindReceiptHandler`, the helper binds a
	handler filtered to its product ids and leaves the game's own ProcessReceipt slot alone; otherwise (or with
	`useProcessReceipt = true`, or when `otherwise` is given) it takes the ProcessReceipt slot.

	Limits: duplicate detection reaches as far back as the ledger (`StoreConfig.ledger`, default the last 200 ops within 30
	days). Refunds and chargebacks never reach ProcessReceipt.
]]

local Errors = require(script.Parent.Errors)
local Internal = require(script.Parent.Internal)
local Players = require(script.Parent.Players)
local Profile = require(script.Parent.Profile)
local Scheduler = require(script.Parent.Scheduler)
local Types = require(script.Parent.Types)

type ProfileImpl = Internal.ProfileImpl
type PlayerLike = Types.PlayerLike
type ReceiptInfo = Types.ReceiptInfo
type ReceiptDecision = Types.ReceiptDecision

--- Grants one developer product. Runs inside `profile:apply(receipt.PurchaseId, ...)`: change `profile.data` here, do not
--- yield, and validate before mutating (if it throws, the purchase is not recorded and is retried later).
export type Handler<T> = (player: PlayerLike, profile: Types.Profile<T>, receipt: ReceiptInfo) -> ()

export type Options = {
	--- Seconds one receipt may take in total (waiting for the profile to load plus the confirmed save). Default 8, below
	--- Roblox's 10 s receipt poll.
	timeout: number?,
	--- Decides receipts for products without a handler. Forces the ProcessReceipt slot (it must see every product).
	--- Default: such receipts stay unresolved (`NotProcessedYet`) and a warning is logged.
	otherwise: ((receipt: ReceiptInfo) -> ReceiptDecision)?,
	--- Take the classic ProcessReceipt slot even when BindReceiptHandler is available.
	useProcessReceipt: boolean?,
	--- false: install nothing; the game calls `receipts:process(info)` from its own receipt callback.
	install: boolean?,
	--- Called (in its own thread) after a purchase was granted and confirmed saved. Not called for redeliveries that were
	--- already confirmed earlier on another server.
	onGranted: ((player: PlayerLike, receipt: ReceiptInfo) -> ())?,
}

export type Stats = {
	--- Receipts answered with PurchaseGranted.
	granted: number,
	--- Deliveries whose purchase id was already in the ledger (redelivery; not granted again).
	duplicates: number,
	--- Receipts answered with NotProcessedYet (will be delivered again).
	deferred: number,
	--- Handler errors.
	failed: number,
}

export type Receipts = {
	--- Decides one receipt (yields up to `timeout`). Use it from your own ProcessReceipt when `install = false`.
	process: (self: Receipts, receipt: ReceiptInfo) -> ReceiptDecision,
	--- Stops granting. In ProcessReceipt mode the slot stays taken and answers NotProcessedYet (an unset slot would auto-accept).
	disconnect: (self: Receipts) -> (),
	stats: (self: Receipts) -> Stats,
}

local DEFAULT_TIMEOUT = 8
--- A commit always gets at least this long, even when waiting for the load used up the budget (the effect is already applied).
local MIN_COMMIT_WAIT = 1

local GRANTED: ReceiptDecision = "granted"
local NOT_YET: ReceiptDecision = "notProcessedYet"

local Receipts = {}

local function describe(info: ReceiptInfo): string
	return `purchase {info.PurchaseId} (product {info.ProductId}, player {info.PlayerId})`
end

local function isValidReceipt(info: any): boolean
	if type(info) ~= "table" then
		return false
	end
	return type(info.PurchaseId) == "string" and info.PurchaseId ~= "" and type(info.PlayerId) == "number" and type(info.ProductId) == "number"
end

--- True when this session already applied `opId` (possibly not yet saved).
local function inLedger(profile: ProfileImpl, opId: string): boolean
	local ext = profile.ext
	if ext == nil then
		return false
	end
	local ops = ext.ops
	return ops ~= nil and ops[opId] ~= nil
end

function Receipts.bind<T>(binding: any, handlers: { [number]: Handler<T> }, options: Options?): Receipts
	local internals = Players.internals(binding)
	if internals == nil then
		error("[Retriever] Retriever.receipts(binding, handlers) needs the binding returned by Retriever.players(store, ...)", 3)
	end
	local bound = internals :: Players.Internals
	if type(handlers) ~= "table" then
		error("[Retriever] Retriever.receipts handlers must be a table { [productId] = function(player, profile, receipt) ... end }", 3)
	end
	local productIds: { number } = {}
	for productId, handler in handlers do
		if type(productId) ~= "number" or type(handler) ~= "function" then
			error(`[Retriever] Retriever.receipts handlers must map product ids (numbers) to functions; got [{tostring(productId)}] = {typeof(handler)}`, 3)
		end
		table.insert(productIds, productId)
	end
	table.sort(productIds)
	if #productIds == 0 and (options == nil or options.otherwise == nil) then
		-- a bound handler with an empty filter could act as a catch-all and hold back every other product's receipts
		error("[Retriever] Retriever.receipts needs at least one product handler (or an `otherwise` callback)", 3)
	end
	local opts: Options = options or {}
	local timeout = opts.timeout or DEFAULT_TIMEOUT
	if type(timeout) ~= "number" or timeout <= 0 then
		error(`[Retriever] Retriever.receipts timeout must be a positive number of seconds, got {tostring(timeout)}`, 3)
	end

	local impl = bound.impl
	local runtime = impl.runtime
	local env = runtime.env
	local connected = true
	local stats: Stats = { granted = 0, duplicates = 0, deferred = 0, failed = 0 }

	local function defer(info: ReceiptInfo, why: string): ReceiptDecision
		stats.deferred += 1
		env.log("info", `[Retriever] {describe(info)} not processed yet: {why}. Roblox will deliver it again.`)
		return NOT_YET
	end

	--- The player's profile, waiting for an ongoing load until `deadline`. Never waits past the deadline.
	local function profileFor(player: PlayerLike, deadline: number): ProfileImpl?
		local profile = bound.profileOf(player.UserId)
		if profile ~= nil or runtime.destroyed then
			return profile
		end
		local scheduler = runtime.scheduler
		local sleeper = Scheduler.newSleeper(scheduler)
		local done = false
		env.spawn(function()
			binding:wait(player) -- returns at once when nothing is loading
			done = true
			Scheduler.wake(scheduler, sleeper)
		end)
		if not done then
			local remaining = deadline - env.clock()
			if remaining > 0 then
				Scheduler.sleepOn(scheduler, sleeper, remaining)
			end
		end
		return bound.profileOf(player.UserId)
	end

	local function grant(info: ReceiptInfo, player: PlayerLike, firstTime: boolean): ReceiptDecision
		stats.granted += 1
		local onGranted = opts.onGranted
		if onGranted ~= nil and firstTime then
			env.spawn(function()
				local ok, problem = pcall(function(): any
					onGranted(player, info)
					return nil
				end)
				if not ok then
					env.log("error", `[Retriever] receipts onGranted failed for {describe(info)}: {tostring(problem)}`)
				end
			end)
		end
		return GRANTED
	end

	local function process(info: ReceiptInfo): ReceiptDecision
		if not isValidReceipt(info) then
			env.log("warn", `[Retriever] ignoring a malformed receipt: {tostring(info)}`)
			stats.deferred += 1
			return NOT_YET
		end
		if not connected then
			return defer(info, "the receipt helper was disconnected")
		end
		local found = handlers[info.ProductId]
		if found == nil then
			local otherwise = opts.otherwise
			if otherwise ~= nil then
				local ok, decision = pcall(otherwise, info)
				if ok and (decision == GRANTED or decision == NOT_YET) then
					return decision
				end
				env.log("error", `[Retriever] receipts \`otherwise\` failed or returned an invalid decision for {describe(info)}: {tostring(decision)}`)
				return NOT_YET
			end
			env.log("warn", `[Retriever] no receipt handler for product {info.ProductId}; {describe(info)} stays unresolved`)
			stats.deferred += 1
			return NOT_YET
		end

		local handler: Handler<T> = found
		local deadline = env.clock() + timeout
		local player = bound.playerOf(info.PlayerId)
		if player == nil then
			return defer(info, "the buyer is not in this server")
		end
		local profile = profileFor(player, deadline)
		if profile == nil then
			return defer(info, "the buyer's profile is not loaded")
		end

		local opId = info.PurchaseId
		local firstTime = false
		if inLedger(profile, opId) then
			-- applied earlier (by a previous delivery or another poll) but not confirmed yet: only the commit is missing
			stats.duplicates += 1
		else
			if profile.state ~= "active" then
				return defer(info, `the buyer's session is {profile.state}`)
			end
			local ok, result = pcall(Profile.apply, profile, opId, function(_data: any)
				handler(player, profile :: any, info)
			end)
			if not ok then
				stats.failed += 1
				env.log("error", `[Retriever] receipt handler for {describe(info)} failed (the purchase was not recorded and will be retried): {tostring(result)}`)
				stats.deferred += 1
				return NOT_YET
			end
			if result == "duplicate" then
				stats.duplicates += 1
			else
				firstTime = true
			end
		end

		local state = profile.state
		if state == "closed" then
			-- ended between the wait and now: a clean close means its final write contained everything, including this id,
			-- unless that write released the lock without the data (`skipData`: the data had become unwritable)
			local endError = profile.endError
			if endError == nil and not profile.skipData then
				return grant(info, player, firstTime)
			end
			return defer(info, if endError ~= nil then Errors.format(endError) else "the session closed without saving its data")
		end
		local committed = Profile.commit(profile, { timeout = math.max(deadline - env.clock(), MIN_COMMIT_WAIT) })
		if committed.ok then
			return grant(info, player, firstTime)
		end
		local problem = (committed :: any).error :: Types.RetrieverError
		return defer(info, `the save was not confirmed ({problem.kind}: {problem.cause or problem.message})`)
	end

	local receipts: Receipts = {
		process = function(_self, info)
			return process(info)
		end,
		disconnect = function(_self)
			connected = false
		end,
		stats = function(_self)
			return table.clone(stats)
		end,
	}

	if opts.install ~= false then
		local market = env.marketplace
		if market == nil then
			error("[Retriever] Retriever.receipts needs a MarketplaceService adapter (env.marketplace). Pass install = false to call receipts:process yourself.", 3)
		end
		local marketplace = market :: Types.MarketplaceAdapter
		local bindHandler = marketplace.bindReceiptHandler
		if bindHandler ~= nil and opts.useProcessReceipt ~= true and opts.otherwise == nil then
			local unbind = bindHandler(productIds, process)
			receipts.disconnect = function(_self)
				connected = false
				unbind()
			end
		else
			marketplace.setProcessReceipt(process)
		end
	end
	return receipts
end

return Receipts
