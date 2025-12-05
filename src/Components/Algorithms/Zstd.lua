-- Yann Collet
-- DO NOT EDIT IF YOU DON'T KNOW WHAT YOU'RE DOING
local module = {}

local bit32 = bit32
local band, bor, bnot, lshift, rshift = bit32.band, bit32.bor, bit32.bnot, bit32.lshift, bit32.rshift
local to_hex = string.format
local buffer_create = buffer.create
local buffer_writeu8 = buffer.writeu8
local buffer_writeu32 = buffer.writeu32
local buffer_readu8 = buffer.readu8
local buffer_readu32 = buffer.readu32
local buffer_copy = buffer.copy
local buffer_fill = buffer.fill
local buffer_len = buffer.len
local buffer_tostring = buffer.tostring

local BLOCK_SIZE = 65536
local MIN_MATCH_LENGTH = 4
local HASH_LOG = 12
local HASH_SIZE = 2^HASH_LOG
local MAGIC_NUMBER_VALUE = 0xFD2FB528
local MAGIC_BYTES = 4

local Huffman = {}

function Huffman.getFrequencies(data, pos, len)
	local frequencies = {}
	for i = pos, pos + len - 1 do
		local byte = buffer_readu8(data, i - 1)
		frequencies[byte] = (frequencies[byte] or 0) + 1
	end
	return frequencies
end

function Huffman.buildTree(frequencies)
	local nodes = {}
	for byte, freq in pairs(frequencies) do
		table.insert(nodes, {char = byte, freq = freq, leaf = true})
	end
	if #nodes == 0 then return nil end
	if #nodes == 1 then return {leaf = true, char = nodes[1].char} end
	while #nodes > 1 do
		table.sort(nodes, function(a, b) return a.freq < b.freq end)
		local left = table.remove(nodes, 1)
		local right = table.remove(nodes, 1)
		local parent = {freq = left.freq + right.freq, left = left, right = right, leaf = false}
		table.insert(nodes, parent)
	end
	return nodes[1]
end

function Huffman.buildEncodingTable(tree)
	local codes = {}
	local function traverse(node, code, length)
		if not node then return end
		if node.leaf then
			codes[node.char] = {code = code, length = length}
		else
			traverse(node.left, code, length + 1)
			traverse(node.right, code + (2^length), length + 1)
		end
	end
	if tree then
		if tree.leaf and not tree.left and not tree.right then
			codes[tree.char] = {code = 0, length = 1}
		else
			traverse(tree, 0, 0)
		end
	end
	return codes
end

function Huffman.serializeTable(codes)
	local tempBuffer = buffer_create(512)
	local writeOffset = 0
	for char, data in pairs(codes) do
		buffer_writeu8(tempBuffer, writeOffset, char)
		writeOffset = writeOffset + 1
		buffer_writeu8(tempBuffer, writeOffset, data.length)
		writeOffset = writeOffset + 1
	end
	local finalBuffer = buffer_create(writeOffset)
	buffer_copy(finalBuffer, 0, tempBuffer, 0, writeOffset)
	return finalBuffer
end

function Huffman.deserializeTable(data, pos, size)
	local tree = {}
	local codes = {}
	local maxLen = 0
	for _ = 1, size do
		local char = buffer_readu8(data, pos)
		pos = pos + 1
		local len = buffer_readu8(data, pos)
		pos = pos + 1
		codes[char] = len
		maxLen = math.max(maxLen, len)
	end
	local currentCode = 0
	for len = 1, maxLen do
		for char, codeLen in pairs(codes) do
			if codeLen == len then
				local node = tree
				for i = len - 1, 0, -1 do
					local bit = bit32.band(bit32.rshift(currentCode, i), 1)
					if not node[bit] then node[bit] = {} end
					node = node[bit]
				end
				node.char = char
				currentCode = currentCode + 1
			end
		end
		currentCode = bit32.lshift(currentCode, 1)
	end
	return tree, pos
end

local function getRollingHash(s, start)
	local h = 0
	local prime = 31
	for i = start, start + MIN_MATCH_LENGTH - 1 do
		if i > buffer_len(s) then break end
		h = bit32.band(h * prime + buffer_readu8(s, i-1), HASH_SIZE - 1)
	end
	return h
end

function module.compress(inputString)
	if type(inputString) ~= "string" or #inputString == 0 then
		return ""
	end
	local input = buffer_create(#inputString)
	for i = 1, #inputString do
		buffer_writeu8(input, i - 1, string.byte(inputString, i))
	end
	local compressedBuffer = buffer_create(buffer_len(input) + 100)
	local writeOffset = 0
	buffer_writeu32(compressedBuffer, writeOffset, MAGIC_NUMBER_VALUE)
	writeOffset = writeOffset + MAGIC_BYTES
	local inputPos = 1
	while inputPos <= buffer_len(input) do
		local block = buffer_create(math.min(buffer_len(input) - inputPos + 1, BLOCK_SIZE))
		buffer_copy(block, 0, input, inputPos - 1, buffer_len(block))
		inputPos = inputPos + buffer_len(block)
		local literals = {}
		local sequences = {}
		local hashTable = {}
		local pos = 1
		local anchor = 1
		while pos <= buffer_len(block) do
			if pos + MIN_MATCH_LENGTH > buffer_len(block) then break end
			local hash = getRollingHash(block, pos)
			local matchPos = hashTable[hash]
			local bestMatchLen = 0
			local bestMatchDist = 0
			if matchPos and pos - matchPos < 65535 then
				local matchLen = 0
				while pos + matchLen <= buffer_len(block) and
					matchPos + matchLen <= buffer_len(block) and
					buffer_readu8(block, pos + matchLen -1) == buffer_readu8(block, matchPos + matchLen - 1) do
					matchLen = matchLen + 1
				end
				if matchLen >= MIN_MATCH_LENGTH then
					bestMatchLen = matchLen
					bestMatchDist = pos - matchPos
				end
			end
			hashTable[hash] = pos
			if bestMatchLen > 0 then
				local literalLen = pos - anchor
				table.insert(sequences, {litLen = literalLen, dist = bestMatchDist, matchLen = bestMatchLen})
				if literalLen > 0 then
					local litBlock = buffer_create(literalLen)
					buffer_copy(litBlock, 0, block, anchor - 1, literalLen)
					table.insert(literals, litBlock)
				end
				pos = pos + bestMatchLen
				anchor = pos
			else
				pos = pos + 1
			end
		end
		if anchor <= buffer_len(block) then
			local literalLen = buffer_len(block) - anchor + 1
			table.insert(sequences, {litLen = literalLen, dist = 0, matchLen = 0})
			local litBlock = buffer_create(literalLen)
			buffer_copy(litBlock, 0, block, anchor - 1, literalLen)
			table.insert(literals, litBlock)
		end
		local totalLitLen = 0
		for _, litBuf in ipairs(literals) do totalLitLen = totalLitLen + buffer_len(litBuf) end
		local literalsBuffer = buffer_create(totalLitLen)
		local litOffset = 0
		for _, litBuf in ipairs(literals) do
			buffer_copy(literalsBuffer, litOffset, litBuf, 0, buffer_len(litBuf))
			litOffset = litOffset + buffer_len(litBuf)
		end
		local freqs = Huffman.getFrequencies(literalsBuffer, 1, buffer_len(literalsBuffer))
		local tree = Huffman.buildTree(freqs)
		local codes = Huffman.buildEncodingTable(tree)
		local serializedTable = Huffman.serializeTable(codes)
		local bitStreamBuffer = buffer_create(buffer_len(literalsBuffer))
		local bitPosition = 0
		for i=1, buffer_len(literalsBuffer) do
			local byte = buffer_readu8(literalsBuffer, i - 1)
			local huffCode = codes[byte]
			if huffCode then
				for j = 0, huffCode.length - 1 do
					local bit = bit32.band(bit32.rshift(huffCode.code, j), 1)
					local byteIndex = math.floor(bitPosition / 8)
					local bitInByte = bitPosition % 8
					local currentVal = buffer_readu8(bitStreamBuffer, byteIndex) or 0
					buffer_writeu8(bitStreamBuffer, byteIndex, bit32.bor(currentVal, bit32.lshift(bit, bitInByte)))
					bitPosition = bitPosition + 1
				end
			end
		end
		local encodedLiteralsLen = math.ceil(bitPosition / 8)
		local encodedLiterals = buffer_create(encodedLiteralsLen)
		buffer_copy(encodedLiterals, 0, bitStreamBuffer, 0, encodedLiteralsLen)
		local sequencesBuffer = buffer_create(#sequences * 12)
		local seqOffset = 0
		for _, seq in ipairs(sequences) do
			buffer_writeu32(sequencesBuffer, seqOffset, seq.litLen)
			buffer_writeu32(sequencesBuffer, seqOffset + 4, seq.matchLen)
			buffer_writeu32(sequencesBuffer, seqOffset + 8, seq.dist)
			seqOffset = seqOffset + 12
		end
		local blockContentLen = 4 + buffer_len(serializedTable) + 4 + buffer_len(sequencesBuffer) + buffer_len(encodedLiterals)
		local compressedBlockContent = buffer_create(blockContentLen)
		local bccOffset = 0
		buffer_writeu32(compressedBlockContent, bccOffset, buffer_len(serializedTable)); bccOffset = bccOffset + 4
		buffer_copy(compressedBlockContent, bccOffset, serializedTable, 0, buffer_len(serializedTable)); bccOffset = bccOffset + buffer_len(serializedTable)
		buffer_writeu32(compressedBlockContent, bccOffset, #sequences); bccOffset = bccOffset + 4
		buffer_copy(compressedBlockContent, bccOffset, sequencesBuffer, 0, buffer_len(sequencesBuffer)); bccOffset = bccOffset + buffer_len(sequencesBuffer)
		buffer_copy(compressedBlockContent, bccOffset, encodedLiterals, 0, buffer_len(encodedLiterals))
		if buffer_len(compressedBlockContent) < buffer_len(block) then
			buffer_writeu8(compressedBuffer, writeOffset, 1)
			buffer_writeu32(compressedBuffer, writeOffset + 1, buffer_len(compressedBlockContent))
			writeOffset = writeOffset + 5
			buffer_copy(compressedBuffer, writeOffset, compressedBlockContent, 0, buffer_len(compressedBlockContent))
			writeOffset = writeOffset + buffer_len(compressedBlockContent)
		else
			buffer_writeu8(compressedBuffer, writeOffset, 0)
			buffer_writeu32(compressedBuffer, writeOffset + 1, buffer_len(block))
			writeOffset = writeOffset + 5
			buffer_copy(compressedBuffer, writeOffset, block, 0, buffer_len(block))
			writeOffset = writeOffset + buffer_len(block)
		end
	end
	local finalBuffer = buffer_create(writeOffset)
	buffer_copy(finalBuffer, 0, compressedBuffer, 0, writeOffset)
	return buffer_tostring(finalBuffer)
end

function module.decompress(compressedString)
	if type(compressedString) ~= "string" or #compressedString < MAGIC_BYTES + 5 then
		error("Invalid or corrupted data")
	end
	local compressed = buffer_create(#compressedString)
	for i = 1, #compressedString do
		buffer_writeu8(compressed, i - 1, string.byte(compressedString, i))
	end
	local readOffset = 0
	if buffer_readu32(compressed, readOffset) ~= MAGIC_NUMBER_VALUE then
		error("Invalid or corrupted data: missing magic number")
	end
	readOffset = readOffset + MAGIC_BYTES
	local output = {}
	while readOffset < buffer_len(compressed) do
		local flag = buffer_readu8(compressed, readOffset)
		local blockSize = buffer_readu32(compressed, readOffset + 1)
		readOffset = readOffset + 5
		if flag == 0 then
			local rawBlock = buffer_create(blockSize)
			buffer_copy(rawBlock, 0, compressed, readOffset, blockSize)
			table.insert(output, rawBlock)
			readOffset = readOffset + blockSize
		else
			local blockData = buffer_create(blockSize)
			buffer_copy(blockData, 0, compressed, readOffset, blockSize)
			readOffset = readOffset + blockSize
			local current = 0
			local tableSize = buffer_readu32(blockData, current); current = current + 4
			local decodingTree, nextPos = Huffman.deserializeTable(blockData, current, tableSize)
			current = nextPos
			local numSequences = buffer_readu32(blockData, current); current = current + 4
			local sequences = {}
			for i = 1, numSequences do
				local litLen = buffer_readu32(blockData, current)
				local matchLen = buffer_readu32(blockData, current + 4)
				local dist = buffer_readu32(blockData, current + 8)
				current = current + 12
				table.insert(sequences, {litLen = litLen, matchLen = matchLen, dist = dist})
			end
			local literalStream = buffer_create(buffer_len(blockData) - current)
			buffer_copy(literalStream, 0, blockData, current, buffer_len(literalStream))
			local literals = {}
			local bitPosition = 0
			local totalLitLen = 0
			local totalLitBits = buffer_len(literalStream) * 8
			for _, seq in ipairs(sequences) do totalLitLen = totalLitLen + seq.litLen end
			local node = decodingTree
			for _ = 1, totalLitLen do
				while node and not node.char do
					if bitPosition >= totalLitBits then
						break 
					end
					local byteIndex = math.floor(bitPosition / 8)
					local bitInByte = bitPosition % 8
					if byteIndex >= buffer_len(literalStream) then 
						break 
					end
					local byte = buffer_readu8(literalStream, byteIndex)
					local bit = bit32.band(bit32.rshift(byte, bitInByte), 1)
					bitPosition = bitPosition + 1
					node = node[bit]
				end
				if node and node.char then
					table.insert(literals, string.char(node.char))
					node = decodingTree
				else
					break
				end
			end
			local literalsString = table.concat(literals)
			local litRead = 1
			local blockOutput = {}
			for _, seq in ipairs(sequences) do
				if seq.litLen > 0 then
					table.insert(blockOutput, string.sub(literalsString, litRead, litRead + seq.litLen - 1))
					litRead = litRead + seq.litLen
				end
				if seq.matchLen > 0 then
					local matchStart = #table.concat(blockOutput) - seq.dist
					local currentString = table.concat(blockOutput)
					for i = 1, seq.matchLen do
						local char = string.sub(currentString, matchStart + i - 1, matchStart + i - 1)
						table.insert(blockOutput, char)
					end
				end
			end
			local finalBlockStr = table.concat(blockOutput)
			local finalBlockBuf = buffer_create(#finalBlockStr)
			for i=1, #finalBlockStr do buffer_writeu8(finalBlockBuf, i-1, string.byte(finalBlockStr, i)) end
			table.insert(output, finalBlockBuf)
		end
	end
	local totalLen = 0
	for _, buf in ipairs(output) do totalLen = totalLen + buffer_len(buf) end
	local finalOutputBuffer = buffer_create(totalLen)
	local outOffset = 0
	for _, buf in ipairs(output) do
		buffer_copy(finalOutputBuffer, outOffset, buf, 0, buffer_len(buf))
		outOffset = outOffset + buffer_len(buf)
	end
	return buffer_tostring(finalOutputBuffer)
end

return module
