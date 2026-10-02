--!strict
--[[
	Structural diff of two plain-data values (what an admin edit, import or restore would change). Paths use the same
	rendering as validation errors (`data.items[3]`, `data["item:sword"]`), keys are visited in a deterministic order, and
	the list is capped so a diff of two unrelated large records stays cheap.
]]

local Util = require(script.Parent.Util)

export type Change = {
	path: string,
	--- nil when the value was added.
	before: any,
	--- nil when the value was removed.
	after: any,
}

local Diff = {}

local function segment(key: any): string
	if type(key) == "number" then
		return `[{key}]`
	elseif type(key) == "string" and string.find(key, "^[%a_][%w_]*$") ~= nil then
		return `.{key}`
	end
	return string.format("[%q]", tostring(key))
end

local function keyRank(key: any): number
	return if type(key) == "number" then 0 elseif type(key) == "string" then 1 else 2
end

local function sortedKeys(a: { [any]: any }, b: { [any]: any }): { any }
	local seen: { [any]: boolean } = {}
	local keys: { any } = {}
	for k in a do
		seen[k] = true
		keys[#keys + 1] = k
	end
	for k in b do
		if not seen[k] then
			keys[#keys + 1] = k
		end
	end
	table.sort(keys, function(x: any, y: any): boolean
		local rx, ry = keyRank(x), keyRank(y)
		if rx ~= ry then
			return rx < ry
		end
		if rx == 2 then
			return tostring(x) < tostring(y)
		end
		return x < y
	end)
	return keys
end

local function walk(before: any, after: any, path: string, out: { Change }, limit: number): boolean
	if before == after then
		return true
	end
	if type(before) == "table" and type(after) == "table" then
		for _, k in sortedKeys(before, after) do
			if not walk(before[k], after[k], path .. segment(k), out, limit) then
				return false
			end
		end
		return true
	end
	if before ~= before and after ~= after then
		return true -- NaN on both sides: not a change worth reporting
	end
	if #out >= limit then
		return false
	end
	out[#out + 1] = { path = path, before = Util.deepCopy(before), after = Util.deepCopy(after) }
	return true
end

--- Changes from `before` to `after`, at most `limit` (default 100). The second value is true when the list was cut short.
function Diff.compute(before: any, after: any, limit: number?): ({ Change }, boolean)
	local out: { Change } = {}
	local complete = walk(before, after, "data", out, limit or 100)
	return out, not complete
end

return Diff
