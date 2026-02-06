--!native
--!optimize 2
-- DO NOT EDIT IF YOU DON'T KNOW WHAT YOU'RE DOING
local Base64 = {}

local CHARS = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local PADDING = "="

local encodeTable = {}
local decodeTable = {}

-- Precompute lookup tables
for i = 1, #CHARS do
	local char = CHARS:sub(i, i)
	encodeTable[i - 1] = char
	decodeTable[char:byte()] = i - 1
end

function Base64.encode(input: string): string
	local inputLen = #input
	if inputLen == 0 then return "" end
	local buf = buffer.fromstring(input)
	local output = table.create(math.ceil(inputLen / 3) * 4)
	-- Main Loop: Process blocks of 3 bytes
	local mainLen = inputLen - (inputLen % 3)
	for i = 0, mainLen - 1, 3 do
		-- NOTE: READ BYTES INDIVIDUALLY TO PRESERVE ENDIANNESS
		local b1 = buffer.readu8(buf, i)
		local b2 = buffer.readu8(buf, i + 1)
		local b3 = buffer.readu8(buf, i + 2)
		-- Combine into 24-bit word (Big Endian logic for stream)
		local val = bit32.bor(bit32.lshift(b1, 16), bit32.lshift(b2, 8), b3)
		-- Split 24 bits into four 6-bit chunks
		local c1 = bit32.rshift(val, 18)
		local c2 = bit32.band(bit32.rshift(val, 12), 63)
		local c3 = bit32.band(bit32.rshift(val, 6), 63)
		local c4 = bit32.band(val, 63)
		table.insert(output, CHARS:sub(c1 + 1, c1 + 1))
		table.insert(output, CHARS:sub(c2 + 1, c2 + 1))
		table.insert(output, CHARS:sub(c3 + 1, c3 + 1))
		table.insert(output, CHARS:sub(c4 + 1, c4 + 1))
	--	if i % 30000 == 0 then end
	end
	-- Remainder Logic
	local remainder = inputLen % 3
	if remainder == 2 then
		local b1 = buffer.readu8(buf, mainLen)
		local b2 = buffer.readu8(buf, mainLen + 1)
		local word = bit32.bor(bit32.lshift(b1, 10), bit32.lshift(b2, 2))
		local c1 = bit32.rshift(word, 12)
		local c2 = bit32.band(bit32.rshift(word, 6), 63)
		local c3 = bit32.band(word, 63)
		table.insert(output, CHARS:sub(c1 + 1, c1 + 1))
		table.insert(output, CHARS:sub(c2 + 1, c2 + 1))
		table.insert(output, CHARS:sub(c3 + 1, c3 + 1))
		table.insert(output, PADDING)
	elseif remainder == 1 then
		local b1 = buffer.readu8(buf, mainLen)
		local word = bit32.lshift(b1, 4)
		local c1 = bit32.rshift(word, 6)
		local c2 = bit32.band(word, 63)
		table.insert(output, CHARS:sub(c1 + 1, c1 + 1))
		table.insert(output, CHARS:sub(c2 + 1, c2 + 1))
		table.insert(output, PADDING)
		table.insert(output, PADDING)
	end
	return table.concat(output)
end

function Base64.decode(input: string): string
	input = string.gsub(input, "[^A-Za-z0-9+/]", "")
	local inputLen = #input
	if inputLen == 0 then return "" end
	local output = table.create(math.ceil(inputLen / 4) * 3)
	local mainLen = inputLen - (inputLen % 4)
	for i = 1, mainLen, 4 do
		local c1 = decodeTable[string.byte(input, i)]
		local c2 = decodeTable[string.byte(input, i + 1)]
		local c3 = decodeTable[string.byte(input, i + 2)]
		local c4 = decodeTable[string.byte(input, i + 3)]
		if not (c1 and c2 and c3 and c4) then continue end
		local packed = bit32.bor(
			bit32.lshift(c1, 18),
			bit32.lshift(c2, 12),
			bit32.lshift(c3, 6),
			c4
		)
		table.insert(output, string.char(bit32.rshift(packed, 16)))
		table.insert(output, string.char(bit32.band(bit32.rshift(packed, 8), 255)))
		table.insert(output, string.char(bit32.band(packed, 255)))
	--	if i % 10000 == 1 then end
	end
	local rem = inputLen % 4
	if rem == 3 then
		local c1 = decodeTable[string.byte(input, inputLen - 2)]
		local c2 = decodeTable[string.byte(input, inputLen - 1)]
		local c3 = decodeTable[string.byte(input, inputLen)]
		if c1 and c2 and c3 then
			local packed = bit32.bor(bit32.lshift(c1, 12), bit32.lshift(c2, 6), c3)
			table.insert(output, string.char(bit32.rshift(packed, 10)))
			table.insert(output, string.char(bit32.band(bit32.rshift(packed, 2), 255)))
		end
	elseif rem == 2 then
		local c1 = decodeTable[string.byte(input, inputLen - 1)]
		local c2 = decodeTable[string.byte(input, inputLen)]
		if c1 and c2 then
			local packed = bit32.bor(bit32.lshift(c1, 6), c2)
			table.insert(output, string.char(bit32.rshift(packed, 4)))
		end
	end
	return table.concat(output)
end

return Base64