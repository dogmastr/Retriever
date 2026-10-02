--!strict
--[[
	Retriever.codec: versioned codecs for the stored profile data (`d`).

	A store configured with `codec = ...` encodes its data at save time, inside the write callback (the one place a
	snapshot copy of the data is created), and records which codec wrote it: `cd` (id) and `cv` (version) next to `d`.
	A load decodes with exactly that codec, before migrations run. Because the id and version travel with the record, a
	format change is a new version and the old version's decoder stays registered for as long as records written with it
	may exist; a record whose codec is not registered on this server fails to load ("Corrupt", nothing modified) instead
	of being replaced by defaults.

	Built-in codecs:
	  - `Codec.lz` ("lz", version 1): pure-Luau binary serialization + LZ77 + JSON-safe text (see Compress.luau). Keeps
	    large profiles under the 4 MB per-key limit; supports tables, strings, numbers, booleans and buffers.
	  - `Codec.identity` ("identity", version 1): stores the data as it is (useful to mark records, or as a template).

	Encoders must be pure and must not yield: a callback may run several times for one write. Encode may raise to refuse
	the data (the save fails as invalid data and nothing is written).

	Nothing here runs or allocates per profile for stores without a codec: the core only reads `policy.codec` (nil) on
	save, and only consults this module on load when a record carries a codec id.
]]

local Compress = require(script.Parent.Compress)
local Types = require(script.Parent.Types)

export type Codec = Types.Codec

local Codec = {}

--- id -> version -> codec. Old versions are never removed: records written with them must stay readable.
local registry: { [string]: { [number]: Codec } } = {}

local function fail(message: string): never
	error(`[Retriever] {message}`, 3)
end

--- Registers a codec so records written with it can be decoded. Returns the codec (pass it as the store's `codec`
--- option). Registering the same table again is a no-op; a different codec under an existing id and version raises, since
--- a stored format must never change without a new version.
function Codec.register(codec: Codec): Codec
	if type(codec) ~= "table" then
		fail(`codec must be a table \{ id = "name", version = 1, encode = function(data) ... end, decode = function(stored) ... end }, got {typeof(codec)}`)
	end
	local id, version = codec.id, codec.version
	if type(id) ~= "string" or id == "" or #id > 32 then
		fail(`codec id must be a non-empty string of at most 32 characters, got {tostring(id)}`)
	end
	if type(version) ~= "number" or version < 1 or version % 1 ~= 0 then
		fail(`codec "{id}": version must be a whole number >= 1, got {tostring(version)}`)
	end
	if type(codec.encode) ~= "function" or type(codec.decode) ~= "function" then
		fail(`codec "{id}" version {version}: encode and decode must be functions`)
	end
	local versions = registry[id]
	if versions == nil then
		versions = {}
		registry[id] = versions
	end
	assert(versions)
	local existing = versions[version]
	if existing ~= nil and existing ~= codec then
		fail(`codec "{id}" version {version} is already registered; register a format change as a new version`)
	end
	versions[version] = codec
	return codec
end

--- The registered codec with this id and version (the highest registered version when `version` is nil).
function Codec.get(id: string, version: number?): Codec?
	local versions = registry[id]
	if versions == nil then
		return nil
	end
	if version ~= nil then
		return versions[version]
	end
	local best: Codec? = nil
	for v, codec in versions do
		if best == nil or v > best.version then
			best = codec
		end
	end
	return best
end

--- True when `value` has the shape of a codec (used to validate the store option).
function Codec.isCodec(value: any): boolean
	return type(value) == "table"
		and type(value.id) == "string"
		and type(value.version) == "number"
		and type(value.encode) == "function"
		and type(value.decode) == "function"
end

--- Decodes a stored payload written by codec `id`/`version`. `preferred` (the store's configured codec) is used directly
--- when it matches, so an unregistered custom codec can still read its own records. Returns `(true, data)` or
--- `(false, cause)`; never substitutes defaults.
function Codec.decode(id: any, version: any, stored: any, preferred: Codec?): (boolean, any)
	if type(id) ~= "string" or type(version) ~= "number" then
		return false, `the record's codec marker is malformed (id {tostring(id)}, version {tostring(version)})`
	end
	local codec: Codec? = nil
	if preferred ~= nil and preferred.id == id and preferred.version == version then
		codec = preferred
	else
		codec = Codec.get(id, version)
	end
	if codec == nil then
		return false,
			`the data was encoded with codec "{id}" version {version}, which is not registered on this server `
				.. `(register it with Retriever.codec.register before loading; old codec versions must stay registered)`
	end
	local ok, result = pcall(codec.decode, stored)
	if not ok then
		return false, `codec "{id}" version {version} failed to decode the data: {tostring(result)}`
	end
	if result == nil then
		return false, `codec "{id}" version {version} decoded the data to nil`
	end
	return true, result
end

------------------------------------------------------------------------------------------------------------------------
-- built-in codecs
------------------------------------------------------------------------------------------------------------------------

--- Stores the data unchanged.
Codec.identity = Codec.register({
	id = "identity",
	version = 1,
	encode = function(data: any): any
		return data
	end,
	decode = function(stored: any): any
		return stored
	end,
})

--- Compressed, JSON-safe text. Version 1 format: basE91-style text (alphabet: printable ASCII without `"`, `'`, `\`) of
--- LZ77 tokens over a tagged binary serialization. Never change this format in place: add version 2 and keep this one.
Codec.lz = Codec.register({
	id = "lz",
	version = 1,
	encode = function(data: any): any
		return Compress.pack(data)
	end,
	decode = function(stored: any): any
		if type(stored) ~= "string" then
			error(`expected a string, got {typeof(stored)}`, 0)
		end
		return Compress.unpack(stored)
	end,
})

return Codec
