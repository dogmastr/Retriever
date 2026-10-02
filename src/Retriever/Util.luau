--!strict
--[[
	Small shared helpers. Everything here is allocation-conscious and has no dependency on the rest of the library.
]]

local Util = {}

--- Deep copy of plain data (tables, strings, numbers, booleans, buffers are shared). No cycle detection by design:
--- stored data cannot contain cycles.
function Util.deepCopy<T>(value: T): T
	if type(value) ~= "table" then
		return value :: any
	end
	local source = value :: any
	local copy: any = table.create(#source)
	for k, v in source do
		if type(v) == "table" then
			copy[k] = Util.deepCopy(v)
		else
			copy[k] = v
		end
	end
	return copy
end

--- Adds fields missing from `target` using `template` (recursively for nested dictionaries). Never overwrites existing
--- values. Returns true when anything was added. Copies template tables so profiles never alias the template.
function Util.fill(target: any, template: any): boolean
	local changed = false
	for k, v in template do
		if type(k) == "string" then
			local existing = target[k]
			if existing == nil then
				target[k] = Util.deepCopy(v)
				changed = true
			elseif type(existing) == "table" and type(v) == "table" and not Util.isArray(v) then
				if Util.fill(existing, v) then
					changed = true
				end
			end
		end
	end
	return changed
end

--- True for a non-empty sequence table.
function Util.isArray(value: any): boolean
	if type(value) ~= "table" then
		return false
	end
	local n = #value
	return n > 0 and next(value, n) == nil
end

--- Structural equality for plain data.
function Util.deepEqual(a: any, b: any): boolean
	if a == b then
		return true
	end
	if type(a) ~= "table" or type(b) ~= "table" then
		return false
	end
	for k, v in a do
		if not Util.deepEqual(v, b[k]) then
			return false
		end
	end
	for k in b do
		if a[k] == nil then
			return false
		end
	end
	return true
end

--- Short random-looking suffix source that does not need a service (deterministic given `env.random`).
function Util.randomId(random: () -> number, length: number): string
	local alphabet = "0123456789abcdefghijklmnopqrstuvwxyz"
	local parts = table.create(length)
	for i = 1, length do
		local index = math.floor(random() * #alphabet) + 1
		parts[i] = string.sub(alphabet, index, index)
	end
	return table.concat(parts)
end

return Util
