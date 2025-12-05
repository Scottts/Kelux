-- Yann Collet
-- DO NOT EDIT IF YOU DON'T KNOW WHAT YOU'RE DOING
local module = {}

local bit32 = bit32
local buffer_create = buffer.create
local buffer_writeu8 = buffer.writeu8
local buffer_readu8 = buffer.readu8
local buffer_len = buffer.len

local b32_lrotate = bit32.lrotate
local b32_bxor = bit32.bxor
local b32_band = bit32.band
local b32_rshift = bit32.rshift

local PRIME32_1 = 0x9E3779B1
local PRIME32_2 = 0x85EBCA77
local PRIME32_3 = 0xC2B2AE3D
local PRIME32_4 = 0x27D4EB2F
local PRIME32_5 = 0x165667B1

local function readu32le_manual(buf, offset)
	local b1 = buffer_readu8(buf, offset)
	local b2 = buffer_readu8(buf, offset + 1)
	local b3 = buffer_readu8(buf, offset + 2)
	local b4 = buffer_readu8(buf, offset + 3)
	return (b4 * 16777216) + (b3 * 65536) + (b2 * 256) + b1
end

local function multiply32(a, b)
	local p = a * b
	return p - (math.floor(p / 2^32) * 2^32)
end
local function add32(a, b)
	return b32_band(a + b, 0xFFFFFFFF)
end

function module.hash32(data, seed)
	seed = seed or 0
	local dataBuffer
	if type(data) == "string" then
		dataBuffer = buffer_create(#data)
		for i = 1, #data do
			buffer_writeu8(dataBuffer, i - 1, string.byte(data, i))
		end
	elseif type(data) == "buffer" then
		dataBuffer = data
	else
		local str = tostring(data)
		dataBuffer = buffer_create(#str)
		for i = 1, #str do
			buffer_writeu8(dataBuffer, i - 1, string.byte(str, i))
		end
	end
	local len = buffer_len(dataBuffer)
	local h32
	local p = 0
	if len >= 16 then
		local v1 = add32(seed, PRIME32_1)
		v1 = add32(v1, PRIME32_2)
		local v2 = add32(seed, PRIME32_2)
		local v3 = seed
		local v4 = add32(seed, -PRIME32_1)
		while p <= len - 16 do
			local lane1 = readu32le_manual(dataBuffer, p)
			local lane2 = readu32le_manual(dataBuffer, p + 4)
			local lane3 = readu32le_manual(dataBuffer, p + 8)
			local lane4 = readu32le_manual(dataBuffer, p + 12)
			v1 = multiply32(b32_lrotate(add32(v1, multiply32(lane1, PRIME32_2)), 13), PRIME32_1)
			v2 = multiply32(b32_lrotate(add32(v2, multiply32(lane2, PRIME32_2)), 13), PRIME32_1)
			v3 = multiply32(b32_lrotate(add32(v3, multiply32(lane3, PRIME32_2)), 13), PRIME32_1)
			v4 = multiply32(b32_lrotate(add32(v4, multiply32(lane4, PRIME32_2)), 13), PRIME32_1)
			p = p + 16
		end
		h32 = add32(b32_lrotate(v1, 1), b32_lrotate(v2, 7))
		h32 = add32(h32, b32_lrotate(v3, 12))
		h32 = add32(h32, b32_lrotate(v4, 18))
	else
		h32 = add32(seed, PRIME32_5)
	end
	h32 = add32(h32, len)
	while p <= len - 4 do
		local k1 = readu32le_manual(dataBuffer, p)
		k1 = multiply32(k1, PRIME32_3)
		k1 = b32_lrotate(k1, 17)
		k1 = multiply32(k1, PRIME32_4)
		h32 = add32(h32, k1)
		h32 = b32_lrotate(h32, 17)
		h32 = multiply32(h32, PRIME32_1)
		p = p + 4
	end
	while p < len do
		local k1 = buffer_readu8(dataBuffer, p)
		k1 = multiply32(k1, PRIME32_5)
		k1 = b32_lrotate(k1, 11)
		k1 = multiply32(k1, PRIME32_1)
		h32 = b32_bxor(h32, k1)
		h32 = b32_lrotate(h32, 11)
		h32 = multiply32(h32, PRIME32_1)
		p = p + 1
	end
	h32 = b32_bxor(h32, b32_rshift(h32, 15))
	h32 = multiply32(h32, PRIME32_2)
	h32 = b32_bxor(h32, b32_rshift(h32, 13))
	h32 = multiply32(h32, PRIME32_3)
	h32 = b32_bxor(h32, b32_rshift(h32, 16))
	return h32
end

function module.hash32Hex(data, seed)
	local hash = module.hash32(data, seed)
	return string.format("%08x", hash)
end

return module
