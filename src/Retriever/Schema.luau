--!strict
--[[
	Schema DSL: declares the shape of profile data once and derives everything else from it.

		local S = Retriever.schema
		local PlayerData = S.struct({
			coins = S.integer(0, { min = 0 }),
			name = S.string("", { maxLength = 20 }),
			items = S.array(S.string()),
			pets = S.map(S.struct({ level = S.integer(1, { min = 1, max = 100 }) })),
			settings = S.struct({ music = S.boolean(true), volume = S.number(0.5, { min = 0, max = 1 }) }),
			title = S.optional(S.string()),
			rank = S.enum({ "bronze", "silver", "gold" }),
		})

	A schema object implements `Types.Schema`, which is all the store needs:

	* `schema:defaults()` builds fresh default data (every call returns new tables, never shared ones).
	* `schema:fill(value)` reconciles stored data with the schema: adds missing fields (recursively, also inside array items
	  and map values that are records) and never replaces a value that is present, even one of the wrong type. Returns true
	  when it added anything. Called on every load after the migrations.
	* `schema:check(value)` validates and returns `false, "data.pets.cat.level: 120 is above the maximum 100"` for the first
	  problem it finds. Runs once per load and, in debug mode only, inside every save (Studio/tests); production saves do not
	  pay for it. `Schema.explain` returns the same problem with its path as a list for tooling.

	Mixed-version safety: records keep fields they do not declare (`extra = "keep"`, the default), so a server running older
	code round-trips fields a newer schema added. Use `extra = "reject"` only for records that are never shared across versions.

	Defaults: every node has one. Scalars default to the value given, else to the zero value (0 clamped into the range, "",
	false, the first enum value); arrays and maps to empty tables; records to the defaults of their fields; optional fields to
	absent. A default that violates its own constraints is a construction-time error, so a broken schema fails when the store
	is created, not when the first player joins.
]]

local Types = require(script.Parent.Types)
local Util = require(script.Parent.Util)

export type Schema = Types.Schema<any>

--- A validation problem. `path` lists the keys from the root (`{ "pets", "cat", "level" }`), `at` renders it
--- (`data.pets.cat.level`), `message` is the full text that `check` returns.
export type Issue = {
	path: { string | number },
	at: string,
	reason: string,
	message: string,
}

export type NumberOptions = {
	min: number?,
	max: number?,
	--- Only whole numbers (S.integer sets this).
	integer: boolean?,
}

export type StringOptions = {
	--- Length in characters (UTF-8 code points).
	minLength: number?,
	maxLength: number?,
	--- A Lua pattern the value must match (`string.find`); anchor it with ^...$ to match the whole string.
	pattern: string?,
}

export type ArrayOptions = {
	minLength: number?,
	maxLength: number?,
	--- Default array (deep-copied for every new profile). Default: empty.
	default: { any }?,
}

export type MapOptions = {
	--- Schema for the keys (they are always strings in a DataStore), for example S.string(nil, { pattern = "^%d+$" }).
	key: Schema?,
	maxSize: number?,
	--- Default map (deep-copied for every new profile). Default: empty.
	default: { [string]: any }?,
}

export type StructOptions = {
	--- Undeclared fields: "keep" (default: preserved and not checked, which is what keeps rolling updates safe) or "reject".
	extra: ("keep" | "reject")?,
}

type Kind =
	"number"
	| "string"
	| "boolean"
	| "literal"
	| "enum"
	| "array"
	| "map"
	| "struct"
	| "optional"
	| "any"
	| "refine"
	| "foreign"

--- Internal node. One flat shape for every kind keeps the checker a single recursive function with no closures.
type Node = {
	kind: Kind,
	--- True when `fill` can change a value of this node (records, and containers or wrappers of records).
	needsFill: boolean,
	--- True when the value may be absent (S.optional, S.any, and S.refine around either).
	optional: boolean,
	--- Scalar default, literal value, or the default table of an array/map/any (copied on use).
	value: any,
	min: number?,
	max: number?,
	integer: boolean,
	minLength: number?,
	maxLength: number?,
	pattern: string?,
	item: Node?,
	key: Node?,
	fields: { [string]: Node }?,
	names: { string }?,
	reject: boolean,
	set: { [any]: boolean }?,
	list: { any }?,
	inner: Node?,
	predicate: ((value: any) -> boolean)?,
	message: string?,
	foreign: Schema?,
}

local Schema = {}

local Meta = {}
Meta.__index = Meta

local function fail(message: string): never
	error(`[Retriever.schema] {message}`, 3)
end

local function newNode(kind: Kind): Node
	return {
		kind = kind,
		needsFill = false,
		optional = kind == "optional" or kind == "any",
		value = nil,
		min = nil,
		max = nil,
		integer = false,
		minLength = nil,
		maxLength = nil,
		pattern = nil,
		item = nil,
		key = nil,
		fields = nil,
		names = nil,
		reject = false,
		set = nil,
		list = nil,
		inner = nil,
		predicate = nil,
		message = nil,
		foreign = nil,
	}
end

--- Accepts our nodes and any other object that implements Types.Schema (wrapped, so custom schemas can be nested).
local function asNode(value: any, where: string): Node
	if type(value) == "table" then
		if getmetatable(value) == Meta then
			return value :: Node
		end
		if type(value.check) == "function" and type(value.defaults) == "function" and type(value.fill) == "function" then
			local node = newNode("foreign")
			node.foreign = value :: Schema
			node.needsFill = true
			return node
		end
	end
	return fail(`{where}: expected a schema such as S.number() or S.string(), got {typeof(value)} {tostring(value)}`)
end

------------------------------------------------------------------------------------------------------------------------
-- rendering
------------------------------------------------------------------------------------------------------------------------

local function renderKey(key: string | number): string
	if type(key) == "number" then
		return `[{key}]`
	end
	if string.find(key, "^[%a_][%w_]*$") ~= nil then
		return "." .. key
	end
	return string.format("[%q]", key)
end

local function render(stack: { string | number }, depth: number): string
	if depth == 0 then
		return "data"
	end
	local parts = table.create(depth + 1)
	parts[1] = "data"
	for i = 1, depth do
		parts[i + 1] = renderKey(stack[i])
	end
	return table.concat(parts)
end

local function show(value: any): string
	local t = type(value)
	if t == "string" then
		if #value > 40 then
			return string.format("%q", string.sub(value, 1, 37) .. "...")
		end
		return string.format("%q", value)
	elseif t == "number" or t == "boolean" then
		return tostring(value)
	elseif t == "nil" then
		return "nil"
	end
	return typeof(value)
end

local function describe(node: Node): string
	local kind = node.kind
	if kind == "number" then
		return if node.integer then "an integer" else "a number"
	elseif kind == "string" then
		return "a string"
	elseif kind == "boolean" then
		return "a boolean"
	elseif kind == "literal" then
		return show(node.value)
	elseif kind == "enum" then
		local list = node.list :: { any }
		local shown = table.create(#list)
		for i, v in list do
			shown[i] = show(v)
		end
		return "one of " .. table.concat(shown, ", ")
	elseif kind == "array" then
		return "an array"
	elseif kind == "map" then
		return "a map (string keys)"
	elseif kind == "struct" then
		return "a record (table)"
	elseif kind == "optional" or kind == "refine" then
		return describe(node.inner :: Node)
	end
	return "a value"
end

local function got(value: any): string
	local t = type(value)
	if t == "number" or t == "boolean" or t == "string" then
		return `{t} {show(value)}`
	end
	return typeof(value)
end

------------------------------------------------------------------------------------------------------------------------
-- check: returns the problem (without its path) and the depth of the path it applies to; the path is in stack[1..depth]
------------------------------------------------------------------------------------------------------------------------

local check: (node: Node, value: any, stack: { string | number }, depth: number) -> (string?, number)

local function checkNumber(node: Node, value: any, depth: number): (string?, number)
	if type(value) ~= "number" then
		return `expected {describe(node)}, got {got(value)}`, depth
	end
	if value ~= value then
		return "NaN cannot be stored (division by zero or math.acos(2) produce it)", depth
	end
	if value == math.huge or value == -math.huge then
		return "infinite numbers cannot be stored", depth
	end
	if node.integer and math.floor(value) ~= value then
		return `expected an integer, got {value}`, depth
	end
	local min = node.min
	if min ~= nil and value < min then
		return `{value} is below the minimum {min}`, depth
	end
	local max = node.max
	if max ~= nil and value > max then
		return `{value} is above the maximum {max}`, depth
	end
	return nil, depth
end

local function checkString(node: Node, value: any, depth: number): (string?, number)
	if type(value) ~= "string" then
		return `expected a string, got {got(value)}`, depth
	end
	local minLength, maxLength = node.minLength, node.maxLength
	if minLength ~= nil or maxLength ~= nil then
		local length = utf8.len(value)
		if length == nil then
			return "string is not valid UTF-8", depth
		end
		if minLength ~= nil and length < minLength then
			return `string of {length} characters is shorter than the minimum length {minLength}`, depth
		end
		if maxLength ~= nil and length > maxLength then
			return `string of {length} characters is longer than the maximum length {maxLength}`, depth
		end
	end
	local pattern = node.pattern
	if pattern ~= nil and string.find(value, pattern) == nil then
		return `{show(value)} does not match the pattern {pattern}`, depth
	end
	return nil, depth
end

local function checkArray(node: Node, value: any, stack: { string | number }, depth: number): (string?, number)
	if type(value) ~= "table" then
		return `expected an array, got {got(value)}`, depth
	end
	local tbl = value :: { [any]: any }
	local length = #tbl
	-- n distinct keys that are all whole numbers in [1, n] are exactly 1..n: a proper sequence. Counting matters: `#` of a
	-- table with a hole ({ 1, nil, 3 }) may report 3 although only two keys exist.
	local count = 0
	for k in tbl do
		if type(k) ~= "number" or k < 1 or k > length or math.floor(k) ~= k then
			return `expected an array (a sequence 1..n without gaps), found the key {show(k)}`, depth
		end
		count += 1
	end
	if count ~= length then
		return `expected an array (a sequence 1..n without gaps), {length - count} of the indexes 1..{length} are missing`, depth
	end
	local minLength, maxLength = node.minLength, node.maxLength
	if minLength ~= nil and length < minLength then
		return `array has {length} items, the minimum is {minLength}`, depth
	end
	if maxLength ~= nil and length > maxLength then
		return `array has {length} items, the maximum is {maxLength}`, depth
	end
	local item = node.item :: Node
	if item.kind ~= "any" then
		for i = 1, length do
			stack[depth + 1] = i
			local problem, at = check(item, tbl[i], stack, depth + 1)
			if problem ~= nil then
				return problem, at
			end
		end
	end
	return nil, depth
end

--- Rank for ordering keys of mixed types: numbers, then strings, then everything else.
local function keyRank(k: any): number
	local t = type(k)
	return if t == "number" then 1 elseif t == "string" then 2 else 3
end

--- The keys of `tbl` in a deterministic order (numbers ascending, strings ascending, then other keys by type name). Only used
--- on the failure path, so reports do not depend on hash-table iteration order.
local function sortedKeys(tbl: { [any]: any }): { any }
	local keys = {}
	for k in tbl do
		table.insert(keys, k)
	end
	table.sort(keys, function(a: any, b: any): boolean
		local ra, rb = keyRank(a), keyRank(b)
		if ra ~= rb then
			return ra < rb
		elseif ra == 3 then
			return typeof(a) < typeof(b)
		end
		return a < b
	end)
	return keys
end

local function checkMapEntry(node: Node, k: any, v: any, stack: { string | number }, depth: number): (string?, number)
	if type(k) ~= "string" then
		return `map keys must be strings (use tostring(id)), found the key {got(k)}`, depth
	end
	local keyNode = node.key
	if keyNode ~= nil then
		local problem = check(keyNode, k, stack, depth)
		if problem ~= nil then
			return `key {show(k)}: {problem}`, depth
		end
	end
	local item = node.item :: Node
	if item.kind ~= "any" then
		stack[depth + 1] = k
		return check(item, v, stack, depth + 1)
	end
	return nil, depth
end

local function checkMap(node: Node, value: any, stack: { string | number }, depth: number): (string?, number)
	if type(value) ~= "table" then
		return `expected a map, got {got(value)}`, depth
	end
	local tbl = value :: { [any]: any }
	local count = 0
	for k, v in tbl do
		count += 1
		local problem = checkMapEntry(node, k, v, stack, depth)
		if problem ~= nil then
			-- Slow path, failures only: report the first problem in key order so the message is deterministic.
			for _, key in sortedKeys(tbl) do
				local first, at = checkMapEntry(node, key, tbl[key], stack, depth)
				if first ~= nil then
					return first, at
				end
			end
			return checkMapEntry(node, k, v, stack, depth) -- unreachable for pure checks
		end
	end
	local maxSize = node.maxLength
	if maxSize ~= nil and count > maxSize then
		return `map has {count} entries, the maximum is {maxSize}`, depth
	end
	return nil, depth
end

local function checkStruct(node: Node, value: any, stack: { string | number }, depth: number): (string?, number)
	if type(value) ~= "table" then
		return `expected a record (table), got {got(value)}`, depth
	end
	local fields = node.fields :: { [string]: Node }
	for _, name in node.names :: { string } do
		local field = fields[name]
		local v = value[name]
		stack[depth + 1] = name
		if v == nil then
			if not field.optional then
				return `required field is missing (expected {describe(field)})`, depth + 1
			end
		else
			local problem, at = check(field, v, stack, depth + 1)
			if problem ~= nil then
				return problem, at
			end
		end
	end
	if node.reject then
		for k in value :: { [any]: any } do
			if type(k) ~= "string" or fields[k] == nil then
				-- failure path: report the first undeclared key in a deterministic order
				local first: any = k
				for _, key in sortedKeys(value) do
					if type(key) ~= "string" or fields[key] == nil then
						first = key
						break
					end
				end
				stack[depth + 1] = if type(first) == "number" or type(first) == "string" then first else tostring(first)
				return "unknown field (not declared in the schema, which rejects extra fields)", depth + 1
			end
		end
	end
	return nil, depth
end

check = function(node: Node, value: any, stack: { string | number }, depth: number): (string?, number)
	local kind = node.kind
	if kind == "struct" then
		return checkStruct(node, value, stack, depth)
	elseif kind == "number" then
		return checkNumber(node, value, depth)
	elseif kind == "string" then
		return checkString(node, value, depth)
	elseif kind == "boolean" then
		if type(value) ~= "boolean" then
			return `expected a boolean, got {got(value)}`, depth
		end
		return nil, depth
	elseif kind == "array" then
		return checkArray(node, value, stack, depth)
	elseif kind == "map" then
		return checkMap(node, value, stack, depth)
	elseif kind == "optional" then
		if value == nil then
			return nil, depth
		end
		return check(node.inner :: Node, value, stack, depth)
	elseif kind == "literal" then
		if value ~= node.value then
			return `expected {show(node.value)}, got {got(value)}`, depth
		end
		return nil, depth
	elseif kind == "enum" then
		if (node.set :: { [any]: boolean })[value] == nil then
			return `expected {describe(node)}, got {got(value)}`, depth
		end
		return nil, depth
	elseif kind == "refine" then
		if value == nil and node.optional then
			return nil, depth -- an absent optional value is not passed to the predicate
		end
		local problem, at = check(node.inner :: Node, value, stack, depth)
		if problem ~= nil then
			return problem, at
		end
		local ok, result = pcall(node.predicate :: (any) -> boolean, value)
		if not ok then
			return `custom check raised: {tostring(result)}`, depth
		elseif not result then
			return node.message or "failed the custom check", depth
		end
		return nil, depth
	elseif kind == "foreign" then
		local ok, message = (node.foreign :: Schema):check(value)
		if not ok then
			return message or "does not match the custom schema", depth
		end
		return nil, depth
	end
	return nil, depth -- any
end

------------------------------------------------------------------------------------------------------------------------
-- defaults and fill
------------------------------------------------------------------------------------------------------------------------

local function defaultOf(node: Node): any
	local kind = node.kind
	if kind == "struct" then
		local fields = node.fields :: { [string]: Node }
		local out = {}
		for _, name in node.names :: { string } do
			local field = fields[name]
			if field.kind ~= "optional" then
				out[name] = defaultOf(field)
			end
		end
		return out
	elseif kind == "array" or kind == "map" or kind == "any" then
		local value = node.value
		if type(value) == "table" then
			return Util.deepCopy(value)
		end
		return if value == nil and kind ~= "any" then {} else value
	elseif kind == "optional" then
		return nil
	elseif kind == "refine" then
		return defaultOf(node.inner :: Node)
	elseif kind == "foreign" then
		return (node.foreign :: Schema):defaults()
	end
	return node.value
end

local function fill(node: Node, value: any): boolean
	local kind = node.kind
	if kind == "struct" then
		if type(value) ~= "table" then
			return false
		end
		local changed = false
		local fields = node.fields :: { [string]: Node }
		for _, name in node.names :: { string } do
			local field = fields[name]
			local v = value[name]
			if v == nil then
				if field.kind ~= "optional" then
					local default = defaultOf(field)
					if default ~= nil then
						value[name] = default
						changed = true
					end
				end
			elseif field.needsFill and fill(field, v) then
				changed = true
			end
		end
		return changed
	elseif kind == "array" then
		local item = node.item :: Node
		if type(value) ~= "table" or not item.needsFill then
			return false
		end
		local changed = false
		for i = 1, #value do
			if fill(item, value[i]) then
				changed = true
			end
		end
		return changed
	elseif kind == "map" then
		local item = node.item :: Node
		if type(value) ~= "table" or not item.needsFill then
			return false
		end
		local changed = false
		for _, v in value :: { [any]: any } do
			if fill(item, v) then
				changed = true
			end
		end
		return changed
	elseif kind == "optional" or kind == "refine" then
		if value == nil then
			return false
		end
		return fill(node.inner :: Node, value)
	elseif kind == "foreign" then
		return (node.foreign :: Schema):fill(value)
	end
	return false
end

------------------------------------------------------------------------------------------------------------------------
-- Types.Schema methods
------------------------------------------------------------------------------------------------------------------------

function Meta.check(self: any, value: any): (boolean, string?)
	local stack = {}
	local problem, depth = check(self :: Node, value, stack, 0)
	if problem == nil then
		return true, nil
	end
	return false, `{render(stack, depth)}: {problem}`
end

function Meta.defaults(self: any): any
	return defaultOf(self :: Node)
end

function Meta.fill(self: any, value: any): boolean
	return fill(self :: Node, value)
end

local function finish(node: Node, where: string): Schema
	local schema: Schema = setmetatable(node :: any, Meta) :: any
	local default = defaultOf(node)
	if default ~= nil then
		local stack = {}
		local problem, depth = check(node, default, stack, 0)
		if problem ~= nil then
			fail(`{where}: the default value is invalid: {render(stack, depth)}: {problem}`)
		end
	end
	return schema
end

local function checkBound(value: any, name: string, where: string): number?
	if value == nil then
		return nil
	end
	if type(value) ~= "number" or value ~= value then
		return fail(`{where}: {name} must be a number, got {typeof(value)}`)
	end
	return value
end

local function checkLength(value: any, name: string, where: string): number?
	local n = checkBound(value, name, where)
	if n ~= nil and (n < 0 or math.floor(n) ~= n) then
		fail(`{where}: {name} must be a whole number >= 0, got {n}`)
	end
	return n
end

------------------------------------------------------------------------------------------------------------------------
-- constructors
------------------------------------------------------------------------------------------------------------------------

--- A finite number. Default: `default`, else 0 clamped into [min, max].
function Schema.number(default: number?, options: NumberOptions?): Schema
	local node = newNode("number")
	local where = if options ~= nil and options.integer then "S.integer" else "S.number"
	if default ~= nil and type(default) ~= "number" then
		fail(`{where}: the default must be a number, got {typeof(default)}`)
	end
	if options ~= nil then
		node.min = checkBound(options.min, "min", where)
		node.max = checkBound(options.max, "max", where)
		node.integer = options.integer == true
	end
	local min, max = node.min, node.max
	if min ~= nil and max ~= nil and min > max then
		fail(`{where}: min ({min}) is greater than max ({max})`)
	end
	if default == nil then
		local zero = 0
		if min ~= nil and zero < min then
			zero = if node.integer then math.ceil(min) else min
		elseif max ~= nil and zero > max then
			zero = if node.integer then math.floor(max) else max
		end
		default = zero
	end
	node.value = default
	return finish(node, where)
end

--- A whole number. Same options as `S.number`.
function Schema.integer(default: number?, options: NumberOptions?): Schema
	local opts: NumberOptions = { integer = true }
	if options ~= nil then
		opts.min = options.min
		opts.max = options.max
	end
	return Schema.number(default, opts)
end

--- A string. Default: `default`, else "" (give a default when `minLength` > 0 or a pattern rejects "").
function Schema.string(default: string?, options: StringOptions?): Schema
	local node = newNode("string")
	if default ~= nil and type(default) ~= "string" then
		fail(`S.string: the default must be a string, got {typeof(default)}`)
	end
	if options ~= nil then
		node.minLength = checkLength(options.minLength, "minLength", "S.string")
		node.maxLength = checkLength(options.maxLength, "maxLength", "S.string")
		local pattern = options.pattern
		if pattern ~= nil then
			if type(pattern) ~= "string" then
				fail(`S.string: pattern must be a string, got {typeof(pattern)}`)
			end
			local ok, problem = pcall(function()
				return string.find("", pattern)
			end)
			if not ok then
				fail(`S.string: invalid pattern {pattern}: {tostring(problem)}`)
			end
			node.pattern = pattern
		end
	end
	node.value = if default ~= nil then default else ""
	return finish(node, "S.string")
end

--- A boolean. Default: `default`, else false.
function Schema.boolean(default: boolean?): Schema
	local node = newNode("boolean")
	if default ~= nil and type(default) ~= "boolean" then
		fail(`S.boolean: the default must be a boolean, got {typeof(default)}`)
	end
	node.value = default == true
	return finish(node, "S.boolean")
end

--- Exactly `value` (a string, number or boolean). Useful for tagged records: `kind = S.literal("sword")`.
function Schema.literal(value: string | number | boolean): Schema
	local t = type(value)
	if t ~= "string" and t ~= "number" and t ~= "boolean" then
		fail(`S.literal: the value must be a string, number or boolean, got {typeof(value)}`)
	end
	if value ~= value then
		fail("S.literal: the value cannot be NaN (it is not equal to itself)")
	end
	local node = newNode("literal")
	node.value = value
	return finish(node, "S.literal")
end

--- One of `values` (strings, numbers or booleans). Default: `default`, else the first value.
function Schema.enum(values: { string | number | boolean }, default: (string | number | boolean)?): Schema
	if type(values) ~= "table" or #values == 0 then
		fail("S.enum: needs a non-empty list of values, for example S.enum({ \"bronze\", \"silver\", \"gold\" })")
	end
	local set: { [any]: boolean } = {}
	local list = table.create(#values)
	for i, v in values do
		local t = type(v)
		if t ~= "string" and t ~= "number" and t ~= "boolean" then
			fail(`S.enum: value #{i} must be a string, number or boolean, got {typeof(v)}`)
		end
		if v ~= v then
			fail(`S.enum: value #{i} cannot be NaN (it is not equal to itself)`)
		end
		set[v] = true
		list[i] = v
	end
	local node = newNode("enum")
	node.set = set
	node.list = list
	node.value = if default ~= nil then default else list[1]
	return finish(node, "S.enum")
end

--- A sequence (1..n, no gaps) whose items all match `item`. Default: `options.default`, else empty.
function Schema.array(item: Schema, options: ArrayOptions?): Schema
	local node = newNode("array")
	local itemNode = asNode(item, "S.array")
	if itemNode.optional and itemNode.kind ~= "any" then
		fail("S.array: items cannot be optional (arrays must not have gaps); use S.map for sparse collections")
	end
	node.item = itemNode
	node.needsFill = itemNode.needsFill
	if options ~= nil then
		node.minLength = checkLength(options.minLength, "minLength", "S.array")
		node.maxLength = checkLength(options.maxLength, "maxLength", "S.array")
		local default = options.default
		if default ~= nil and type(default) ~= "table" then
			fail(`S.array: default must be a table, got {typeof(default)}`)
		end
		node.value = if default ~= nil then Util.deepCopy(default) else nil
	end
	return finish(node, "S.array")
end

--- A dictionary with string keys whose values all match `value`. Default: `options.default`, else empty.
function Schema.map(value: Schema, options: MapOptions?): Schema
	local node = newNode("map")
	local valueNode = asNode(value, "S.map")
	if valueNode.optional and valueNode.kind ~= "any" then
		fail("S.map: values cannot be optional (a nil value is an absent key); use the inner schema")
	end
	node.item = valueNode
	node.needsFill = valueNode.needsFill
	if options ~= nil then
		if options.key ~= nil then
			node.key = asNode(options.key, "S.map key")
		end
		node.maxLength = checkLength(options.maxSize, "maxSize", "S.map")
		local default = options.default
		if default ~= nil and type(default) ~= "table" then
			fail(`S.map: default must be a table, got {typeof(default)}`)
		end
		node.value = if default ~= nil then Util.deepCopy(default) else nil
	end
	return finish(node, "S.map")
end

--- A record with the declared fields. Undeclared fields are kept (see `StructOptions.extra`).
function Schema.struct(fields: { [string]: Schema }, options: StructOptions?): Schema
	if type(fields) ~= "table" then
		fail(`S.struct: expected a table of field schemas, got {typeof(fields)}`)
	end
	local node = newNode("struct")
	local nodes: { [string]: Node } = {}
	local names: { string } = {}
	for name, field in fields :: { [any]: any } do
		if type(name) ~= "string" then
			fail(`S.struct: field names must be strings, got {typeof(name)} {tostring(name)}`)
		end
		nodes[name] = asNode(field, `S.struct field "{name}"`)
		table.insert(names, name)
	end
	table.sort(names) -- deterministic defaults and error reports
	node.fields = nodes
	node.names = names
	node.needsFill = #names > 0
	if options ~= nil then
		local extra = options.extra
		if extra ~= nil and extra ~= "keep" and extra ~= "reject" then
			fail(`S.struct: extra must be "keep" or "reject", got {tostring(extra)}`)
		end
		node.reject = extra == "reject"
	end
	return finish(node, "S.struct")
end

--- A record field that may be absent. Never added by `fill`; checked only when present.
function Schema.optional(inner: Schema): Schema
	local node = newNode("optional")
	local innerNode = asNode(inner, "S.optional")
	if innerNode.kind == "optional" then
		return inner
	end
	node.inner = innerNode
	node.needsFill = innerNode.needsFill
	return finish(node, "S.optional")
end

--- Anything (including absent). Storability is still checked by debug-mode validation. `default` is deep-copied.
function Schema.any(default: any?): Schema
	local node = newNode("any")
	node.value = if type(default) == "table" then Util.deepCopy(default) else default
	return finish(node, "S.any")
end

--- `inner` plus a custom predicate, for rules the DSL cannot express. The predicate must be pure and fast.
function Schema.refine(inner: Schema, predicate: (value: any) -> boolean, message: string?): Schema
	if type(predicate) ~= "function" then
		fail(`S.refine: predicate must be a function, got {typeof(predicate)}`)
	end
	local node = newNode("refine")
	local innerNode = asNode(inner, "S.refine")
	node.inner = innerNode
	node.needsFill = innerNode.needsFill
	node.optional = innerNode.optional
	node.predicate = predicate
	node.message = message
	return finish(node, "S.refine")
end

------------------------------------------------------------------------------------------------------------------------
-- tools
------------------------------------------------------------------------------------------------------------------------

--- True for schemas built with this module.
function Schema.is(value: any): boolean
	return type(value) == "table" and getmetatable(value) == Meta
end

--- The first problem in `value`, with its path, or nil when it is valid. Works on any `Types.Schema` (other implementations
--- report their message with an empty path).
function Schema.explain(schema: Schema, value: any): Issue?
	if not Schema.is(schema) then
		local ok, message = schema:check(value)
		if ok then
			return nil
		end
		local text = message or "does not match the schema"
		return { path = {}, at = "data", reason = text, message = text }
	end
	local node: Node = schema :: any
	local stack: { string | number } = {}
	local problem, depth = check(node, value, stack, 0)
	if problem == nil then
		return nil
	end
	local path: { string | number } = {}
	for i = 1, depth do
		path[i] = stack[i]
	end
	local at = render(stack, depth)
	return { path = path, at = at, reason = problem, message = `{at}: {problem}` }
end

--- The path prefix (`data.items[3]`, `data.inv["item:sword"]`) of a message produced by `check` or `Validate.storable`, or
--- nil. Parses the rendered path (identifiers, `[n]` indexes and `%q`-quoted keys), so keys containing ":" or "]" are kept.
function Schema.pathOf(message: string?): string?
	if type(message) ~= "string" or string.sub(message, 1, 4) ~= "data" then
		return nil
	end
	local i = 5
	local n = #message
	while i <= n do
		local c = string.sub(message, i, i)
		if c == ":" then
			return string.sub(message, 1, i - 1)
		elseif c == "." then
			local _, stop = string.find(message, "^[%a_][%w_]*", i + 1)
			if stop == nil then
				return nil
			end
			i = stop + 1
		elseif c == "[" then
			if string.sub(message, i + 1, i + 1) == '"' then
				-- %q-quoted key: ends at the first quote not preceded by a backslash escape, then "]"
				local j = i + 2
				while true do
					local d = string.sub(message, j, j)
					if d == "" then
						return nil
					elseif d == "\\" then
						j += 2
					elseif d == '"' then
						break
					else
						j += 1
					end
				end
				if string.sub(message, j + 1, j + 1) ~= "]" then
					return nil
				end
				i = j + 2
			else
				local _, stop = string.find(message, "^[^%]]+%]", i + 1)
				if stop == nil then
					return nil
				end
				i = stop + 1
			end
		else
			return nil
		end
	end
	return nil
end

return Schema
