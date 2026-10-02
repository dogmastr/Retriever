--!strict
--[[
	Classifies DataStore error text using the official error table (docs/research/roblox-datastore-semantics.md, Q7).

	Two questions decide retry policy and the Unknown outcome:
	  * is it worth retrying (transient / throttled) or will it fail the same way again (invalid data, too large, access)?
	  * could the backend have applied the write even though an error came back (`maybeApplied`)?

	`maybeApplied` only matters for an UpdateAsync whose callback already produced a value. Errors Roblox raises before it sends
	the write (validation 101-107/511-513, serialization 103-105, throttling 301-306 and the `...Throttled` family, shutdown
	401/402, Studio/RCC 403/509) are definitive "not applied". Anything that can happen after the request left the server
	(501-505, HTTP 5xx, ConnectFail, timeouts, unrecognized text) is ambiguous. The leading number is NOT guaranteed, so the
	parser accepts `"104: ..."`, `"DataStoreService: CantStoreValue: ..."` and falls back to substrings.
]]

export type Scope = "experience" | "server" | "key"

export type ErrorClass = {
	kind: "throttled" | "transient" | "invalidData" | "tooLarge" | "access" | "shutdown" | "permanent",
	--- True when the backend may have applied the write even though an error was raised.
	maybeApplied: boolean,
	retryable: boolean,
	--- For throttles: who is throttled (experience-wide throttles hit every server, so back off harder).
	scope: Scope?,
	code: number?,
	name: string?,
}

local Classify = {}

local function has(text: string, pattern: string): boolean
	return string.find(text, pattern, 1, true) ~= nil
end

local function codeOf(text: string): number?
	local digits = string.match(text, "^%s*(%d%d%d):")
	if digits == nil then
		digits = string.match(text, "^DataStoreService:%s*[%w_/]+:%s*(%d%d%d):")
	end
	return if digits ~= nil then tonumber(digits) else nil
end

local function nameOf(text: string): string?
	return string.match(text, "^DataStoreService:%s*([%w_]+):")
end

local VALIDATION = { [101] = true, [102] = true, [103] = true, [106] = true, [107] = true, [511] = true, [512] = true, [513] = true }
local VALIDATION_NAMES = {
	KeyNameEmpty = true,
	KeyNameLimit = true,
	ValueNotAllowed = true,
	MaxValueInvalid = true,
	MinValueInvalid = true,
	PageSizeGreater = true,
	PageSizeLesser = true,
	MinMaxOrderInvalid = true,
	AttributeSizeTooLarge = true,
	UserIdLimitExceeded = true,
	AttributeFormatError = true,
	InvalidTimestamp = true,
	InvalidUserIds = true,
	InvalidExclusiveStartKey = true,
	InvalidTarget = true,
}

function Classify.error(text: string): ErrorClass
	local code = codeOf(text)
	local name = nameOf(text)

	-- the callback yielded: a bug in game code, retrying cannot help
	if has(text, "cannot yield") or has(text, "yield across") then
		return { kind = "permanent", maybeApplied = false, retryable = false, code = code, name = name }
	end

	-- value problems, definitely not applied
	if code == 104 or name == "CantStoreValue" or has(text, "Cannot store") or has(text, "Can't store") then
		return { kind = "invalidData", maybeApplied = false, retryable = false, code = code, name = name }
	end
	if code == 105 or name == "ValueTooLarge" or has(text, "exceeds max size") or has(text, "Serialized value") then
		return { kind = "tooLarge", maybeApplied = false, retryable = false, code = code, name = name }
	end
	if (code ~= nil and VALIDATION[code]) or (name ~= nil and VALIDATION_NAMES[name]) then
		return { kind = "permanent", maybeApplied = false, retryable = false, code = code, name = name }
	end

	-- server is going away: the DataModel/WebService is no longer accessible
	if code == 401 or code == 402 or name == "DataModelNoAccess" or name == "LuaWebSrvsNoAccess" then
		return { kind = "shutdown", maybeApplied = false, retryable = false, code = code, name = name }
	end

	-- environment: Studio without API access, unpublished place, personal RCC
	if
		code == 403
		or code == 509
		or name == "StudioAccessToApisNotAllowed"
		or name == "OperationNotAllowed"
		or has(text, "must publish")
		or has(text, "API access is not enabled")
	then
		return { kind = "access", maybeApplied = false, retryable = false, code = code, name = name }
	end

	-- throttling: rejected before it was applied
	if has(text, "ExperienceThrottled") then
		return { kind = "throttled", maybeApplied = false, retryable = true, scope = "experience", code = code, name = name }
	end
	if has(text, "KeyThrottled") or has(text, "DatastoreThrottled") then
		return { kind = "throttled", maybeApplied = false, retryable = true, scope = "key", code = code, name = name }
	end
	if
		(code ~= nil and code >= 301 and code <= 306)
		or has(text, "GameServerThrottled")
		or has(text, "Throttle")
		or has(text, "request was added to queue")
		or has(text, "throttled")
		or has(text, "HTTP 429")
	then
		return { kind = "throttled", maybeApplied = false, retryable = true, scope = "server", code = code, name = name }
	end

	-- 501-505, 502 (HTTP 500 / access forbidden during incidents), InternalServerError, ConnectFail, timeouts, unknown:
	-- retry, and the write may have landed
	return { kind = "transient", maybeApplied = true, retryable = true, code = code, name = name }
end

return Classify
