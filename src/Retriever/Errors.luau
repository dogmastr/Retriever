--!strict
--[[
	Typed, actionable errors. Failures that callers are expected to handle are returned as plain tables (no metatable, so
	creating one costs a single allocation); programmer mistakes (bad arguments, use after close in strict contexts) are
	raised with `error(string)` and a message that says how to fix the call.
]]

local Types = require(script.Parent.Types)

type ErrorKind = Types.ErrorKind
type RetrieverError = Types.RetrieverError

type Entry = {
	retryable: boolean,
	message: string,
	hint: string,
}

-- `%s` placeholders are filled from `details.what` when present. Keep hints short and imperative.
local ENTRIES: { [ErrorKind]: Entry } = {
	Locked = {
		retryable = true,
		message = "The profile is locked by another server that did not release it in time.",
		hint = "If the player just teleported this resolves by itself. If it persists, a server is not calling profile:close() when players leave, or it crashed; the lock expires on its own after the lease.",
	},
	Unavailable = {
		retryable = true,
		message = "DataStore requests kept failing or were throttled until the retry budget ran out.",
		hint = "Nothing was changed. Ask the player to rejoin, or retry later. Check Roblox's DataStore status and the request budget in store:stats().",
	},
	Corrupt = {
		retryable = false,
		message = "The stored value is not a valid Retriever record.",
		hint = "The record was left untouched. Inspect it with Retriever.admin(store):inspect(key); restore from a version or reset it explicitly. It was not replaced with defaults.",
	},
	SchemaTooNew = {
		retryable = true,
		message = "The record was written by newer game code than this server is running.",
		hint = "This is expected during a rolling update. Send the player to a server running the newer version. The record was left untouched.",
	},
	MigrationFailed = {
		retryable = false,
		message = "A migration failed, so the profile was not loaded.",
		hint = "The record was left untouched and the lock released. Fix the migration (see details.step and details.cause) and publish again.",
	},
	InvalidData = {
		retryable = false,
		message = "The data does not satisfy the schema or cannot be stored in a DataStore.",
		hint = "Fix the value at details.path. Only tables, strings, finite numbers and booleans can be stored; arrays must be sequences; table keys must be strings.",
	},
	TooLarge = {
		retryable = false,
		message = "The serialized profile exceeds the DataStore value size limit.",
		hint = "Shrink the data (prune history, move large collections to their own keys) or enable a compression codec.",
	},
	Cancelled = {
		retryable = false,
		message = "The operation was cancelled before it completed.",
		hint = "Usually the player left while the profile was loading. Nothing needs to be done; any lock taken in the meantime is released.",
	},
	ShuttingDown = {
		retryable = false,
		message = "The server is shutting down.",
		hint = "No new sessions are started during shutdown. Existing sessions are being saved and released.",
	},
	AlreadyLoaded = {
		retryable = false,
		message = "This key already has a session on this server.",
		hint = "Use store:get(key) to fetch the loaded profile, or close it first. Two sessions for one key would fight over the lock.",
	},
	NotFound = {
		retryable = false,
		message = "No record exists for this key.",
		hint = "Pass create = true (the default for load) to create it.",
	},
	OwnershipLost = {
		retryable = false,
		message = "This session no longer owns the profile; another server took over or the record was deleted.",
		hint = "Edits made after the last successful save are not persisted. Kick the player or reload the profile.",
	},
	Closed = {
		retryable = false,
		message = "The profile is closing or closed.",
		hint = "Do not edit a profile after close() was called or after onEnded fired.",
	},
	Conflict = {
		retryable = true,
		message = "The record changed since it was read (revision mismatch).",
		hint = "Re-read the record and apply the change again.",
	},
	InboxFull = {
		retryable = true,
		message = "The target's inbox is full.",
		hint = "The target has not processed earlier commands (offline for long, or a handler keeps failing). Retry later or raise the inbox limit.",
	},
	Unknown = {
		retryable = true,
		message = "The outcome of the write is unknown: it may or may not have been applied.",
		hint = "Retrying is safe for idempotent operations (apply with an op id). Calling commit() again resolves it.",
	},
	InvalidArgument = {
		retryable = false,
		message = "An argument is invalid.",
		hint = "See details.what.",
	},
	StudioApiDisabled = {
		retryable = false,
		message = "DataStore access is disabled in Studio.",
		hint = "Enable 'Studio Access to API Services' in Game Settings > Security (and publish the place), or run with the in-memory backend.",
	},
}

local Errors = {}

--- Builds an error value. `details.what` can add a short specific explanation to the message.
function Errors.new(
	kind: ErrorKind,
	store: string,
	key: string?,
	cause: string?,
	details: { [string]: any }?
): RetrieverError
	local entry = ENTRIES[kind]
	local message = entry.message
	local what = details and details.what
	if type(what) == "string" then
		message = message .. " " .. what
	end
	local where = if key ~= nil then ` (store "{store}", key "{key}")` else ` (store "{store}")`
	return {
		kind = kind,
		message = message .. where,
		hint = entry.hint,
		retryable = entry.retryable,
		store = store,
		key = key,
		cause = cause,
		details = details,
	}
end

--- One-line rendering for logs.
function Errors.format(err: RetrieverError): string
	local text = `[Retriever:{err.kind}] {err.message} Hint: {err.hint}`
	if err.cause ~= nil then
		text ..= ` Cause: {err.cause}`
	end
	return text
end

function Errors.isRetryable(kind: ErrorKind): boolean
	return ENTRIES[kind].retryable
end

return Errors
