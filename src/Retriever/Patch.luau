--!strict
--[[
	Declarative patches for admin edits: a list of operations on paths into the data, plain data themselves, so they can travel
	as an inbox command to the server that owns the key (`Retriever.admin(store):edit` on a live key) and be applied there by
	the built-in command handler, inside the owner's session, exactly once.

	    { { op = "set", path = "settings.music", value = false },
	      { op = "increment", path = "coins", by = 100 },
	      { op = "insert", path = "items", value = "sword" },          -- append (or `index = 1`)
	      { op = "remove", path = { "items", 3 } } }                    -- array index: removes and shifts

	Paths are dot-separated strings or arrays of segments. In a string path an all-digit segment addresses an array index
	when the container is a non-empty array and does not have that string key; use an array path ({ "items", 3 }) to be
	explicit. Every path except the last segment must exist. Patches are checked and applied to a copy first and validated
	(storable, schema); only then are they applied to the live data, so a bad patch never leaves a partial edit.
]]

local Internal = require(script.Parent.Internal)
local Events = require(script.Parent.Events)
local Util = require(script.Parent.Util)
local Validate = require(script.Parent.Validate)

export type Op = "set" | "remove" | "increment" | "insert"

export type PatchOp = {
	op: Op,
	path: string | { string | number },
	value: any?,
	by: number?,
	index: number?,
}

local Patch = {}

--- Command kind of admin patches routed to a live owner. Reserved: `store:onCommand` refuses it.
Patch.COMMAND = "retriever.admin"

local MAX_OPS = 100

local function segments(path: any): ({ string | number }?, string?)
	if type(path) == "string" then
		if path == "" then
			return nil, "path is empty"
		end
		local out: { string | number } = {}
		for part in string.gmatch(path .. ".", "([^%.]*)%.") do
			if part == "" then
				return nil, `path "{path}" has an empty segment`
			end
			out[#out + 1] = part
		end
		return out, nil
	elseif type(path) == "table" then
		local list = path :: { any }
		if #list == 0 then
			return nil, "path is empty"
		end
		for i, part in list do
			if type(part) == "number" then
				if part < 1 or part % 1 ~= 0 then
					return nil, `path segment {i} must be a positive whole number, got {part}`
				end
			elseif type(part) ~= "string" or part == "" then
				return nil, `path segment {i} must be a non-empty string or a positive whole number, got {typeof(part)}`
			end
		end
		return list :: { string | number }, nil
	end
	return nil, `path must be a string like "settings.music" or an array of segments, got {typeof(path)}`
end

local function describe(path: any): string
	if type(path) == "string" then
		return path
	end
	local parts = {}
	for _, part in path :: { any } do
		parts[#parts + 1] = tostring(part)
	end
	return table.concat(parts, ".")
end

--- Checks the shape of a patch (not whether it applies to some data). Returns false and a message for the first problem.
function Patch.check(ops: any): (boolean, string?)
	if type(ops) ~= "table" or #ops == 0 then
		return false, "a patch is a non-empty list of operations like { op = \"set\", path = \"coins\", value = 10 }"
	end
	if #ops > MAX_OPS then
		return false, `a patch may hold at most {MAX_OPS} operations, got {#ops}`
	end
	for i, raw in ops :: { any } do
		if type(raw) ~= "table" then
			return false, `operation {i} must be a table, got {typeof(raw)}`
		end
		local op = raw.op
		if op ~= "set" and op ~= "remove" and op ~= "increment" and op ~= "insert" then
			return false, `operation {i}: op must be "set", "remove", "increment" or "insert", got {tostring(op)}`
		end
		local _, problem = segments(raw.path)
		if problem ~= nil then
			return false, `operation {i} ({op}): {problem}`
		end
		if op == "set" or op == "insert" then
			if raw.value == nil then
				return false, `operation {i} ({op} {describe(raw.path)}): value is missing` .. (if op == "set" then " (use op = \"remove\" to delete)" else "")
			end
			local storable, why = Validate.storable(raw.value)
			if not storable then
				return false, `operation {i} ({op} {describe(raw.path)}): the value cannot be stored: {why}`
			end
		end
		if op == "increment" then
			local by = raw.by
			if by ~= nil and (type(by) ~= "number" or by ~= by or by == math.huge or by == -math.huge) then
				return false, `operation {i} (increment {describe(raw.path)}): by must be a finite number, got {tostring(by)}`
			end
		end
		if op == "insert" and raw.index ~= nil then
			local index = raw.index
			if type(index) ~= "number" or index < 1 or index % 1 ~= 0 then
				return false, `operation {i} (insert {describe(raw.path)}): index must be a positive whole number, got {tostring(index)}`
			end
		end
	end
	return true, nil
end

local function resolve(container: { [any]: any }, part: string | number): string | number
	if type(part) == "string" and string.find(part, "^%d+$") ~= nil and container[part] == nil and #container > 0 then
		return tonumber(part) :: number
	end
	return part
end

--- Applies a checked patch to `data` in place. On failure `data` may be partly changed: apply to a copy first.
function Patch.apply(data: any, ops: { PatchOp }): (boolean, string?)
	if type(data) ~= "table" then
		return false, `the data is a {typeof(data)}, not a table`
	end
	for i, op in ops do
		local parts = segments(op.path) :: { string | number }
		local container: any = data
		for depth = 1, #parts - 1 do
			local key = resolve(container, parts[depth])
			local nextValue = container[key]
			if type(nextValue) ~= "table" then
				local walked = table.concat(table.move(parts :: { any }, 1, depth, 1, {}), ".")
				return false, `operation {i} ({op.op} {describe(op.path)}): "{walked}" is {if nextValue == nil then "missing" else "a " .. typeof(nextValue)}, not a table`
			end
			container = nextValue
		end
		local key = resolve(container, parts[#parts])
		local kind = op.op
		if kind == "set" then
			container[key] = Util.deepCopy(op.value)
		elseif kind == "remove" then
			if type(key) == "number" and key <= #container then
				table.remove(container, key)
			else
				container[key] = nil
			end
		elseif kind == "increment" then
			local current = container[key]
			if current == nil then
				current = 0
			end
			if type(current) ~= "number" then
				return false, `operation {i} (increment {describe(op.path)}): the value is a {typeof(current)}, not a number`
			end
			container[key] = current + (op.by or 1)
		else -- insert
			local list = container[key]
			if type(list) ~= "table" then
				return false, `operation {i} (insert {describe(op.path)}): the target is {if list == nil then "missing" else "a " .. typeof(list)}, not an array`
			end
			local length = #list
			if length == 0 and next(list) ~= nil then
				return false, `operation {i} (insert {describe(op.path)}): the target is a dictionary, not an array`
			end
			local index = op.index or length + 1
			if index > length + 1 then
				return false, `operation {i} (insert {describe(op.path)}): index {index} is beyond the end of the array (length {length})`
			end
			table.insert(list, index, Util.deepCopy(op.value))
		end
	end
	return true, nil
end

--- Whether `data` can be saved by `config`'s store: storable, and valid for its schema when it has one.
function Patch.validateData(config: Internal.StoreConfigN, data: any): (boolean, string?)
	local storable, why = Validate.storable(data)
	if not storable then
		return false, why
	end
	local schema = config.schema
	if schema ~= nil then
		local called, valid, message = pcall(schema.check, schema, data)
		if not called then
			return false, `the schema raised an error: {tostring(valid)}`
		end
		if not valid then
			return false, message or "does not match the schema"
		end
	end
	return true, nil
end

--- Applies `ops` to a copy of `data` and validates the result. Returns the patched copy, or nil and why it failed.
function Patch.preview(config: Internal.StoreConfigN, data: any, ops: { PatchOp }): (any, string?)
	local copy = Util.deepCopy(data)
	local ok, why = Patch.apply(copy, ops)
	if not ok then
		return nil, why
	end
	local valid, problem = Patch.validateData(config, copy)
	if not valid then
		return nil, problem
	end
	return copy, nil
end

--- The built-in handler for `Patch.COMMAND` (installed on every store). Runs inside the owner's session, through the
--- idempotency ledger like every command. A patch that no longer applies (the data changed since the admin checked it) or
--- would make the data invalid is dropped with an error log and an `admin` event: retrying it would fail the same way.
function Patch.handler(profile: any, payload: any, id: string)
	local impl: Internal.StoreImpl = profile.impl
	local runtime = impl.runtime
	local ops = if type(payload) == "table" then payload.ops else nil
	local ok, why = Patch.check(ops)
	if ok then
		local _, problem = Patch.preview(impl.config, profile.data, ops)
		ok, why = problem == nil, problem
	end
	if ok then
		Patch.apply(profile.data, ops) -- checked on a copy above: the same operations on the same state succeed
	else
		runtime.env.log(
			"error",
			`[Retriever] admin patch "{id}" for key "{profile.key}" (store "{impl.name}") was dropped: {why}`
		)
	end
	if runtime.events ~= nil then
		Events.emit(runtime, impl.name, profile.key, "admin", {
			reason = if ok then "patchApplied" else "patchRejected",
			cause = why,
			details = {
				id = id,
				reason = if type(payload) == "table" then payload.reason else nil,
				by = if type(payload) == "table" then payload.by else nil,
			},
		})
	end
end

return Patch
