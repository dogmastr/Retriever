--!strict
--[[
	Checks that a value can be stored in a DataStore and explains the first problem it finds, with the path to it.

	This is the debug-mode guard against the failures that silently or loudly break saves in production (see the
	community failure digest, FM-04): NaN/inf, invalid UTF-8, Roblox datatypes and Instances, sparse arrays, mixed tables,
	non-string dictionary keys, functions and cycles. Production paths do not run it; they rely on the engine's own check and
	call it only after a save fails, to turn "104: Cannot store ..." into "data.inventory[3].position: Vector3 is not storable".
]]

local MAX_DEPTH = 64

local Validate = {}

local function render(stack: { string | number }, depth: number): string
	local parts = { "data" }
	for i = 1, depth do
		local key = stack[i]
		if type(key) == "number" then
			parts[#parts + 1] = `[{key}]`
		elseif string.find(key, "^[%a_][%w_]*$") ~= nil then
			parts[#parts + 1] = `.{key}`
		else
			-- same rendering as Schema: keys that are not identifiers are quoted, so Schema.pathOf can parse the path
			parts[#parts + 1] = string.format("[%q]", key)
		end
	end
	return table.concat(parts)
end

local function check(value: any, stack: { string | number }, depth: number): string?
	local t = type(value)
	if t == "number" then
		if value ~= value then
			return `{render(stack, depth)}: NaN cannot be stored (division by zero or math.acos(2) produce it)`
		elseif value == math.huge or value == -math.huge then
			return `{render(stack, depth)}: infinite numbers cannot be stored`
		end
		return nil
	elseif t == "string" then
		if utf8.len(value) == nil then
			return `{render(stack, depth)}: string is not valid UTF-8 (store binary data in a buffer or encode it first)`
		end
		return nil
	elseif t == "boolean" then
		return nil
	elseif t == "table" then
		if depth >= MAX_DEPTH then
			return `{render(stack, depth)}: nesting deeper than {MAX_DEPTH} levels (is there a cycle?)`
		end
		local tbl = value :: { [any]: any }
		local length = #tbl
		local count = 0
		local hasString, hasNumber = false, false
		for k in tbl do
			count += 1
			local kt = type(k)
			if kt == "string" then
				hasString = true
			elseif kt == "number" then
				hasNumber = true
			else
				return `{render(stack, depth)}: dictionary keys must be strings or numbers, got {typeof(k)}`
			end
		end
		if hasString and hasNumber then
			return `{render(stack, depth)}: mixes string and number keys; only one kind is allowed per table`
		end
		if hasNumber and count ~= length then
			return `{render(stack, depth)}: array has gaps or non-sequential indexes; use string keys (tostring(id)) instead`
		end
		for k, v in tbl do
			stack[depth + 1] = k
			local problem = check(v, stack, depth + 1)
			if problem ~= nil then
				return problem
			end
		end
		return nil
	elseif t == "buffer" then
		return nil
	end
	return render(stack, depth)
		.. ": "
		.. typeof(value)
		.. " cannot be stored (convert Roblox datatypes to tables, numbers and strings, for example {x, y, z} for a Vector3)"
end

--- Returns `true`, or `false` plus a message that names the offending path.
function Validate.storable(value: any): (boolean, string?)
	local problem = check(value, {}, 0)
	if problem == nil then
		return true, nil
	end
	return false, problem
end

return Validate
