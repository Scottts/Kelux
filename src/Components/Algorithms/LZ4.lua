-- Yann Collet
-- DO NOT EDIT IF YOU DON'T KNOW WHAT YOU'RE DOING
local module = {}

local buffer_create = buffer.create
local buffer_writeu8 = buffer.writeu8
local buffer_writeu16 = buffer.writeu16
local buffer_readu8 = buffer.readu8
local buffer_readu16 = buffer.readu16
local buffer_readu32 = buffer.readu32
local buffer_copy = buffer.copy
local buffer_len = buffer.len
local buffer_tostring = buffer.tostring

local b32_lshift = bit32.lshift
local b32_rshift = bit32.rshift
local b32_band = bit32.band

local MIN_MATCH = 4
local MAX_DISTANCE = 65535
local ML_BITS = 4
local ML_MASK = b32_lshift(1, ML_BITS) - 1
local RUN_BITS = 8 - ML_BITS
local RUN_MASK = b32_lshift(1, RUN_BITS) - 1

local HASH_LOG = 12
local HASH_SIZE = b32_lshift(1, HASH_LOG)
local HASH_MASK = HASH_SIZE - 1
local KNUTH_MULTIPLIER = 2654435761

local function getHash(data, pos)
	local val = buffer_readu32(data, pos - 1)
	return b32_rshift(val * KNUTH_MULTIPLIER, 32 - HASH_LOG)
end

function module.compress(inputString)
	if type(inputString) ~= "string" then
		error("Input must be a string.")
	end
	if #inputString == 0 then
		return ""
	end
	local input = buffer.create(#inputString)
	for i = 1, #inputString do
		buffer_writeu8(input, i - 1, string.byte(inputString, i))
	end
	local inputLen = buffer_len(input)
	local output = buffer_create(inputLen + math.floor(inputLen / 255) + 16)
	local writePos = 0
	local hashTable = {}
	local pos = 1
	local anchor = 1
	while pos <= inputLen do
		local hash = 0
		if pos + MIN_MATCH -1 <= inputLen then
			hash = getHash(input, pos)
		end
		local matchPos = hashTable[hash]
		local distance, matchLen = 0, 0
		if matchPos and pos - matchPos <= MAX_DISTANCE then
			local start = matchPos
			local p = pos
			while p <= inputLen - 3 and buffer_readu32(input, p-1) == buffer_readu32(input, start-1) do
				p = p + 4
				start = start + 4
			end
			while p <= inputLen and buffer_readu8(input, p-1) == buffer_readu8(input, start-1) do
				p = p + 1
				start = start + 1
			end
			matchLen = (p - pos)
			if matchLen >= MIN_MATCH then
				distance = pos - matchPos
			else
				matchLen = 0
			end
		end
		hashTable[hash] = pos
		if matchLen > 0 then
			local literalLen = pos - anchor
			local token = b32_lshift(math.min(literalLen, RUN_MASK), ML_BITS) + math.min(matchLen - MIN_MATCH, ML_MASK)
			buffer_writeu8(output, writePos, token)
			writePos = writePos + 1
			if literalLen >= RUN_MASK then
				local len = literalLen - RUN_MASK
				while len >= 255 do
					buffer_writeu8(output, writePos, 255)
					writePos = writePos + 1
					len = len - 255
				end
				buffer_writeu8(output, writePos, len)
				writePos = writePos + 1
			end
			if literalLen > 0 then
				buffer_copy(output, writePos, input, anchor - 1, literalLen)
				writePos = writePos + literalLen
			end
			buffer_writeu16(output, writePos, distance)
			writePos = writePos + 2
			if matchLen - MIN_MATCH >= ML_MASK then
				local len = matchLen - MIN_MATCH - ML_MASK
				while len >= 255 do
					buffer_writeu8(output, writePos, 255)
					writePos = writePos + 1
					len = len - 255
				end
				buffer_writeu8(output, writePos, len)
				writePos = writePos + 1
			end
			pos = pos + matchLen
			anchor = pos
		else
			pos = pos + 1
		end
	end
	local literalLen = inputLen - anchor + 1
	if literalLen > 0 then
		local token = b32_lshift(math.min(literalLen, RUN_MASK), ML_BITS)
		buffer_writeu8(output, writePos, token)
		writePos = writePos + 1
		if literalLen >= RUN_MASK then
			local len = literalLen - RUN_MASK
			while len >= 255 do
				buffer_writeu8(output, writePos, 255)
				writePos = writePos + 1
				len = len - 255
			end
			buffer_writeu8(output, writePos, len)
			writePos = writePos + 1
		end
		buffer_copy(output, writePos, input, anchor - 1, literalLen)
		writePos = writePos + literalLen
	end
	local finalBuffer = buffer_create(writePos)
	buffer_copy(finalBuffer, 0, output, 0, writePos)
	return buffer_tostring(finalBuffer)
end

function module.decompress(compressedString)
	if type(compressedString) ~= "string" or #compressedString == 0 then
		return ""
	end
	local compressed = buffer_create(#compressedString)
	for i=1, #compressedString do buffer_writeu8(compressed, i-1, string.byte(compressedString, i)) end
	local compressedLen = buffer_len(compressed)
	local output = buffer_create(compressedLen * 3)
	local writePos = 0
	local readPos = 0
	while readPos < compressedLen do
		local token = buffer_readu8(compressed, readPos)
		readPos = readPos + 1
		local literalLen = b32_rshift(token, ML_BITS)
		if literalLen == RUN_MASK then
			local byte
			repeat
				byte = buffer_readu8(compressed, readPos)
				readPos = readPos + 1
				literalLen = literalLen + byte
			until byte ~= 255
		end
		if literalLen > 0 then
			buffer_copy(output, writePos, compressed, readPos, literalLen)
			writePos = writePos + literalLen
			readPos = readPos + literalLen
		end
		if readPos >= compressedLen then break end
		local offset = buffer_readu16(compressed, readPos)
		readPos = readPos + 2
		local matchLen = b32_band(token, ML_MASK)
		if matchLen == ML_MASK then
			local byte
			repeat
				byte = buffer_readu8(compressed, readPos)
				readPos = readPos + 1
				matchLen = matchLen + byte
			until byte ~= 255
		end
		matchLen = matchLen + MIN_MATCH
		local matchStart = writePos - offset
		if offset >= matchLen then
			buffer_copy(output, writePos, output, matchStart, matchLen)
			writePos = writePos + matchLen
		else
			for i = 0, matchLen - 1 do
				local byte = buffer_readu8(output, matchStart + i)
				buffer_writeu8(output, writePos + i, byte)
			end
			writePos = writePos + matchLen
		end
	end
	local finalBuffer = buffer_create(writePos)
	buffer_copy(finalBuffer, 0, output, 0, writePos)
	return buffer_tostring(finalBuffer)
end

function module.getCompressionRatio(original, compressed)
	if #original == 0 then return 0 end
	return (1 - (#compressed / #original)) * 100
end

return module
