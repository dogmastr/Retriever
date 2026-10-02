--!strict
--[[
	Pure-Luau compression for the built-in `lz` codec (Retriever.codec): plain data -> compact binary -> LZ77 -> text.

	Three stages, all on `buffer`:
	  1. `serialize`: a tagged binary encoding of plain data (nil-free tables, strings, numbers, booleans, buffers).
	  2. `deflate`: byte-oriented LZ77 (64 KiB window, 4-byte minimum match, one hash probe per position).
	  3. `toText`: basE91-style text over 91 printable ASCII characters without `"`, `\` and `'`, so the result is valid
	     UTF-8 and survives the JSON encoding DataStores apply without escaping (about 23% larger than the binary).

	Every function is pure and never yields: the encoder runs inside UpdateAsync callbacks and may be replayed. Module-level
	scratch state (the writer buffer, the hash table) is reset at the start of each call, which is safe because nothing in
	here yields or calls user code. Malformed input raises; callers pcall.
]]

local Compress = {}

------------------------------------------------------------------------------------------------------------------------
-- 1. Binary serialization
------------------------------------------------------------------------------------------------------------------------

local TAG_FALSE = 0
local TAG_TRUE = 1
local TAG_FLOAT = 2
local TAG_UINT = 3 -- non-negative integer, varint
local TAG_NINT = 4 -- negative integer n, varint of -n - 1
local TAG_STRING = 5
local TAG_TABLE = 6 -- varint array length, array values, then key/value pairs, then TAG_END
local TAG_BUFFER = 7
local TAG_END = 255

local MAX_DEPTH = 200
local MAX_SAFE = 2 ^ 53

local out: buffer = buffer.create(0)
local pos = 0

local function reserve(n: number)
	local need = pos + n
	local size = buffer.len(out)
	if need > size then
		local grown = buffer.create(math.max(need, size * 2, 256))
		buffer.copy(grown, 0, out, 0, pos)
		out = grown
	end
end

local function writeVarint(n: number)
	reserve(8)
	while n >= 128 do
		buffer.writeu8(out, pos, n % 128 + 128)
		pos += 1
		n = n // 128
	end
	buffer.writeu8(out, pos, n)
	pos += 1
end

local function writeTag(tag: number)
	reserve(1)
	buffer.writeu8(out, pos, tag)
	pos += 1
end

local function writeValue(value: any, depth: number)
	local t = type(value)
	if t == "string" then
		local n = #value
		writeTag(TAG_STRING)
		writeVarint(n)
		reserve(n)
		buffer.writestring(out, pos, value)
		pos += n
	elseif t == "number" then
		if value % 1 == 0 and value > -MAX_SAFE and value < MAX_SAFE and not (value == 0 and 1 / value < 0) then
			if value >= 0 then
				writeTag(TAG_UINT)
				writeVarint(value)
			else
				writeTag(TAG_NINT)
				writeVarint(-value - 1)
			end
		else
			writeTag(TAG_FLOAT)
			reserve(8)
			buffer.writef64(out, pos, value)
			pos += 8
		end
	elseif t == "boolean" then
		writeTag(if value then TAG_TRUE else TAG_FALSE)
	elseif t == "table" then
		if depth >= MAX_DEPTH then
			error(`data is nested deeper than {MAX_DEPTH} levels (a cycle?)`, 0)
		end
		local n = 0
		while value[n + 1] ~= nil do
			n += 1
		end
		writeTag(TAG_TABLE)
		writeVarint(n)
		for i = 1, n do
			writeValue(value[i], depth + 1)
		end
		for k, v in value do
			if type(k) == "number" and k >= 1 and k <= n and k % 1 == 0 then
				continue
			end
			local kt = type(k)
			if kt ~= "string" and kt ~= "number" then
				error(`cannot encode a table key of type {kt}`, 0)
			end
			writeValue(k, depth + 1)
			writeValue(v, depth + 1)
		end
		writeTag(TAG_END)
	elseif t == "buffer" then
		local n = buffer.len(value)
		writeTag(TAG_BUFFER)
		writeVarint(n)
		reserve(n)
		buffer.copy(out, pos, value, 0, n)
		pos += n
	else
		error(`cannot encode a value of type {typeof(value)}`, 0)
	end
end

--- Serializes plain data. Returns a buffer and the number of bytes used (the buffer is scratch space: copy what you keep).
function Compress.serialize(value: any): (buffer, number)
	pos = 0
	writeValue(value, 0)
	return out, pos
end

local src: buffer = buffer.create(0)
local rpos = 0
local rlen = 0

local function readVarint(): number
	local n = 0
	local scale = 1
	while true do
		local b = buffer.readu8(src, rpos)
		rpos += 1
		if b < 128 then
			return n + b * scale
		end
		n += (b - 128) * scale
		scale *= 128
		if scale > MAX_SAFE then
			error("corrupt data: varint too long", 0)
		end
	end
end

local function readLength(): number
	local n = readVarint()
	if rpos + n > rlen then
		error("corrupt data: length past the end", 0)
	end
	return n
end

local function readValue(tag: number, depth: number): any
	if tag == TAG_STRING then
		local n = readLength()
		local s = buffer.readstring(src, rpos, n)
		rpos += n
		return s
	elseif tag == TAG_UINT then
		return readVarint()
	elseif tag == TAG_NINT then
		return -readVarint() - 1
	elseif tag == TAG_TABLE then
		if depth >= MAX_DEPTH then
			error("corrupt data: nested too deeply", 0)
		end
		local n = readLength() -- every array value takes at least one byte
		local t: any = table.create(n)
		for i = 1, n do
			local vt = buffer.readu8(src, rpos)
			rpos += 1
			t[i] = readValue(vt, depth + 1)
		end
		while true do
			local kt = buffer.readu8(src, rpos)
			rpos += 1
			if kt == TAG_END then
				break
			end
			local k = readValue(kt, depth + 1)
			local vt = buffer.readu8(src, rpos)
			rpos += 1
			t[k] = readValue(vt, depth + 1)
		end
		return t
	elseif tag == TAG_FLOAT then
		local v = buffer.readf64(src, rpos)
		rpos += 8
		return v
	elseif tag == TAG_TRUE then
		return true
	elseif tag == TAG_FALSE then
		return false
	elseif tag == TAG_BUFFER then
		local n = readLength()
		local b = buffer.create(n)
		buffer.copy(b, 0, src, rpos, n)
		rpos += n
		return b
	end
	error(`corrupt data: unknown tag {tag}`, 0)
end

--- Inverse of `serialize`. Raises on malformed input.
function Compress.deserialize(data: buffer): any
	src = data
	rpos = 0
	rlen = buffer.len(data)
	local ok, result = pcall(function()
		local tag = buffer.readu8(src, 0)
		rpos = 1
		return readValue(tag, 0)
	end)
	local consumed = rpos
	src = buffer.create(0) -- do not keep the caller's buffer alive
	if not ok then
		error(result, 0)
	end
	if consumed ~= rlen then
		error("corrupt data: trailing bytes", 0)
	end
	return result
end

------------------------------------------------------------------------------------------------------------------------
-- 2. LZ77
--
-- Format: u32 original length, then tokens. Control byte c < 128: c + 1 literal bytes follow. c >= 128: a match of
-- length (c - 128) + 4 (4..131) at the u16 distance that follows (1..65535). Overlapping matches repeat (RLE).
------------------------------------------------------------------------------------------------------------------------

local MIN_MATCH = 4
local MAX_MATCH = 131
local MAX_LITERALS = 128
local WINDOW = 65535
local HASH_BITS = 15
local HASH_SHIFT = 2 ^ (32 - HASH_BITS)

local hashTable: buffer? = nil

--- Compresses `n` bytes of `input`. Returns a new buffer holding exactly the compressed bytes.
function Compress.deflate(input: buffer, n: number): buffer
	local ht = hashTable
	if ht == nil then
		ht = buffer.create(4 * 2 ^ HASH_BITS)
		hashTable = ht
	else
		buffer.fill(ht, 0, 0)
	end
	assert(ht)
	local dst = buffer.create(n + n // MAX_LITERALS + 16)
	buffer.writeu32(dst, 0, n)
	local o = 4

	local function literals(from: number, to: number)
		while from < to do
			local count = math.min(to - from, MAX_LITERALS)
			buffer.writeu8(dst, o, count - 1)
			buffer.copy(dst, o + 1, input, from, count)
			o += count + 1
			from += count
		end
	end

	local i = 0
	local litStart = 0
	local last = n - MIN_MATCH
	while i <= last do
		local x = buffer.readu32(input, i)
		local slot = (x * 0x9E3779B1) % 4294967296 // HASH_SHIFT * 4
		local cand = buffer.readu32(ht, slot) - 1
		buffer.writeu32(ht, slot, i + 1)
		if cand >= 0 and i - cand <= WINDOW and buffer.readu32(input, cand) == x then
			local len = MIN_MATCH
			local maxLen = n - i
			while len < maxLen and buffer.readu8(input, cand + len) == buffer.readu8(input, i + len) do
				len += 1
			end
			literals(litStart, i)
			local dist = i - cand
			local remaining = len
			while remaining >= MIN_MATCH do
				local l = math.min(remaining, MAX_MATCH)
				local rest = remaining - l
				if rest > 0 and rest < MIN_MATCH then
					l -= MIN_MATCH - rest -- leave a tail that is still a valid match
				end
				buffer.writeu8(dst, o, 128 + l - MIN_MATCH)
				buffer.writeu16(dst, o + 1, dist)
				o += 3
				remaining -= l
			end
			i += len - remaining
			litStart = i
		else
			i += 1
		end
	end
	literals(litStart, n)

	local result = buffer.create(o)
	buffer.copy(result, 0, dst, 0, o)
	return result
end

--- Inverse of `deflate`. Raises on malformed input.
function Compress.inflate(input: buffer): buffer
	local n = buffer.len(input)
	local size = buffer.readu32(input, 0)
	-- The header is untrusted (it comes out of a DataStore): a match token is 3 bytes and expands to at most MAX_MATCH, a
	-- literal run never expands, so a longer declared length is corrupt. Refuse it before allocating up to 4 GiB.
	if size > (n - 4) * math.ceil(MAX_MATCH / 3) then
		error("corrupt data: declared length is larger than the input can expand to", 0)
	end
	local dst = buffer.create(size)
	local p = 4
	local o = 0
	while p < n do
		local c = buffer.readu8(input, p)
		p += 1
		if c < 128 then
			local count = c + 1
			buffer.copy(dst, o, input, p, count)
			o += count
			p += count
		else
			local len = c - 128 + MIN_MATCH
			local dist = buffer.readu16(input, p)
			p += 2
			local s = o - dist
			if dist == 0 or s < 0 then
				error("corrupt data: bad match distance", 0)
			end
			if dist >= len then
				buffer.copy(dst, o, dst, s, len)
			else
				for j = 0, len - 1 do
					buffer.writeu8(dst, o + j, buffer.readu8(dst, s + j))
				end
			end
			o += len
		end
	end
	if o ~= size then
		error("corrupt data: length mismatch", 0)
	end
	return dst
end

------------------------------------------------------------------------------------------------------------------------
-- 3. Text (basE91 algorithm, JSON-safe alphabet)
------------------------------------------------------------------------------------------------------------------------

local ENCODE = buffer.create(91)
local DECODE = buffer.create(256)
do
	buffer.fill(DECODE, 0, 255)
	local k = 0
	for c = 0x21, 0x7E do
		if c ~= 0x22 and c ~= 0x27 and c ~= 0x5C then
			buffer.writeu8(ENCODE, k, c)
			buffer.writeu8(DECODE, c, k)
			k += 1
		end
	end
end

--- Encodes bytes as printable ASCII without `"`, `\` or `'`.
function Compress.toText(input: buffer): string
	local n = buffer.len(input)
	local dst = buffer.create(math.ceil(n * 16 / 13) + 2)
	local o = 0
	local b = 0
	local bits = 0
	for i = 0, n - 1 do
		b += bit32.lshift(buffer.readu8(input, i), bits)
		bits += 8
		if bits > 13 then
			local v = bit32.band(b, 8191)
			if v > 88 then
				b = bit32.rshift(b, 13)
				bits -= 13
			else
				v = bit32.band(b, 16383)
				b = bit32.rshift(b, 14)
				bits -= 14
			end
			buffer.writeu8(dst, o, buffer.readu8(ENCODE, v % 91))
			buffer.writeu8(dst, o + 1, buffer.readu8(ENCODE, v // 91))
			o += 2
		end
	end
	if bits > 0 then
		buffer.writeu8(dst, o, buffer.readu8(ENCODE, b % 91))
		o += 1
		if bits > 7 or b > 90 then
			buffer.writeu8(dst, o, buffer.readu8(ENCODE, b // 91))
			o += 1
		end
	end
	return buffer.readstring(dst, 0, o)
end

--- Inverse of `toText`. Raises on a character outside the alphabet.
function Compress.fromText(text: string): buffer
	local n = #text
	local input = buffer.fromstring(text)
	local dst = buffer.create(math.ceil(n * 14 / 16) + 1)
	local o = 0
	local v = -1
	local b = 0
	local bits = 0
	for i = 0, n - 1 do
		local c = buffer.readu8(DECODE, buffer.readu8(input, i))
		if c == 255 then
			error("corrupt data: invalid character", 0)
		end
		if v < 0 then
			v = c
		else
			v += c * 91
			b += bit32.lshift(v, bits)
			bits += if bit32.band(v, 8191) > 88 then 13 else 14
			repeat
				buffer.writeu8(dst, o, bit32.band(b, 255))
				o += 1
				b = bit32.rshift(b, 8)
				bits -= 8
			until bits <= 7
			v = -1
		end
	end
	if v >= 0 then
		buffer.writeu8(dst, o, bit32.band(b + bit32.lshift(v, bits), 255))
		o += 1
	end
	local result = buffer.create(o)
	buffer.copy(result, 0, dst, 0, o)
	return result
end

------------------------------------------------------------------------------------------------------------------------

--- Plain data -> compressed JSON-safe text.
function Compress.pack(value: any): string
	local bytes, n = Compress.serialize(value)
	return Compress.toText(Compress.deflate(bytes, n))
end

--- Compressed text -> plain data. Raises on malformed input.
function Compress.unpack(text: string): any
	return Compress.deserialize(Compress.inflate(Compress.fromText(text)))
end

return Compress
