--!optimize 2
-- DO NOT EDIT IF YOU DON'T KNOW WHAT YOU'RE DOING
local Base64 = {}

local CHARS = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local PADDING = "="

local encodeTable = {}
local decodeTable = {}

for i = 1, #CHARS do
	local char = CHARS:sub(i, i)
	encodeTable[i - 1] = char
	decodeTable[char:byte()] = i - 1
end

function Base64.encode(input: string): string
	if type(input) ~= "string" then
		error("Base64.encode expects a string argument")
	end
	local output = {}
	local index = 1
	for i = 1, #input, 3 do
		local b1 = input:byte(i)
		local b2 = input:byte(i + 1)
		local b3 = input:byte(i + 2)
		output[index] = encodeTable[bit32.rshift(b1, 2)]
		index += 1
		if b2 then
			output[index] = encodeTable[bit32.bor(
				bit32.lshift(bit32.band(b1, 0x03), 4),
				bit32.rshift(b2, 4)
			)]
			index += 1
			if b3 then
				output[index] = encodeTable[bit32.bor(
					bit32.lshift(bit32.band(b2, 0x0F), 2),
					bit32.rshift(b3, 6)
				)]
				index += 1
				output[index] = encodeTable[bit32.band(b3, 0x3F)]
				index += 1
			else
				output[index] = encodeTable[bit32.lshift(bit32.band(b2, 0x0F), 2)]
				index += 1
				output[index] = PADDING
				index += 1
			end
		else
			output[index] = encodeTable[bit32.lshift(bit32.band(b1, 0x03), 4)]
			index += 1
			output[index] = PADDING
			index += 1
			output[index] = PADDING
			index += 1
		end
	end
	return table.concat(output)
end

function Base64.decode(input: string): string
	if type(input) ~= "string" then
		error("Base64.decode expects a string argument")
	end
	input = input:gsub("%s+", "")
	if #input % 4 ~= 0 then
		error("Invalid Base64 string length")
	end
	local output = {}
	local index = 1
	for i = 1, #input, 4 do
		local c1 = input:byte(i)
		local c2 = input:byte(i + 1)
		local c3 = input:byte(i + 2)
		local c4 = input:byte(i + 3)
		local v1 = decodeTable[c1]
		local v2 = decodeTable[c2]
		local v3 = decodeTable[c3]
		local v4 = decodeTable[c4]
		if not v1 or not v2 then
			error("Invalid Base64 character")
		end
		output[index] = string.char(bit32.bor(
			bit32.lshift(v1, 2),
			bit32.rshift(v2, 4)
			))
		index += 1
		if c3 ~= PADDING:byte() then
			if not v3 then
				error("Invalid Base64 character")
			end
			output[index] = string.char(bit32.bor(
				bit32.lshift(bit32.band(v2, 0x0F), 4),
				bit32.rshift(v3, 2)
				))
			index += 1
			if c4 ~= PADDING:byte() then
				if not v4 then
					error("Invalid Base64 character")
				end
				output[index] = string.char(bit32.bor(
					bit32.lshift(bit32.band(v3, 0x03), 6),
					v4
					))
				index += 1
			end
		end
	end
	return table.concat(output)
end

return Base64
