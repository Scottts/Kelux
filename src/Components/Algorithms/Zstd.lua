--!native
--!optimize 2
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

function Huffman.getFrequencies(data: buffer, pos: number, len: number)
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
	table.sort(nodes, function(a, b) 
		if a.freq == b.freq then return a.char < b.char end
		return a.freq < b.freq 
	end)
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
	local lengths = {}
	local function traverse(node, length)
		if not node then return end
		if node.leaf then
			lengths[node.char] = length
		else
			traverse(node.left, length + 1)
			traverse(node.right, length + 1)
		end
	end
	if tree then
		if tree.leaf and not tree.left and not tree.right then
			lengths[tree.char] = 1
		else
			traverse(tree, 0)
		end
	end
	local sortedChars = {}
	for char, len in pairs(lengths) do
		table.insert(sortedChars, {char = char, len = len})
	end
	table.sort(sortedChars, function(a, b)
		if a.len == b.len then return a.char < b.char end
		return a.len < b.len
	end)
	local codes = {}
	local currentCode = 0
	local currentLen = sortedChars[1] and sortedChars[1].len or 0
	for _, item in ipairs(sortedChars) do
		while currentLen < item.len do
			currentCode = bit32.lshift(currentCode, 1)
			currentLen += 1
		end

		codes[item.char] = {code = currentCode, length = item.len}
		currentCode += 1
	end
	return codes
end

function Huffman.serializeTable(codes)
	local tempBuffer = buffer_create(1024)
	local writeOffset = 0
	for char, data in pairs(codes) do
		if writeOffset + 2 > buffer_len(tempBuffer) then
			local newBuf = buffer_create(buffer_len(tempBuffer) * 2)
			buffer_copy(newBuf, 0, tempBuffer, 0, writeOffset)
			tempBuffer = newBuf
		end
		buffer_writeu8(tempBuffer, writeOffset, char)
		writeOffset += 1
		buffer_writeu8(tempBuffer, writeOffset, data.length)
		writeOffset += 1
	end
	local finalBuffer = buffer_create(writeOffset)
	buffer_copy(finalBuffer, 0, tempBuffer, 0, writeOffset)
	return finalBuffer
end

function Huffman.deserializeTable(data: buffer, pos: number, size: number)
	local tree = {}
	local charLengths = {}
	for _ = 1, size / 2 do 
		local char = buffer_readu8(data, pos)
		pos += 1
		local len = buffer_readu8(data, pos)
		pos += 1
		table.insert(charLengths, {char = char, len = len})
	end
	table.sort(charLengths, function(a, b)
		if a.len == b.len then return a.char < b.char end
		return a.len < b.len
	end)
	local currentCode = 0
	local currentLen = charLengths[1] and charLengths[1].len or 0
	for _, item in ipairs(charLengths) do
		while currentLen < item.len do
			currentCode = bit32.lshift(currentCode, 1)
			currentLen += 1
		end
		local node = tree
		for i = item.len - 1, 0, -1 do
			local bit = bit32.band(bit32.rshift(currentCode, i), 1)
			if not node[bit] then node[bit] = {} end
			node = node[bit]
		end
		node.char = item.char
		currentCode += 1
	end
	return tree, pos
end

local function getRollingHash(s: buffer, start: number)
	local h = 0
	local prime = 31
	local len = buffer_len(s)
	for i = start, start + MIN_MATCH_LENGTH - 1 do
		if i > len then break end
		h = bit32.band(h * prime + buffer_readu8(s, i-1), HASH_SIZE - 1)
	end
	return h
end

function module.compress(inputString: string)
	if type(inputString) ~= "string" or #inputString == 0 then
		return ""
	end
	local input = buffer.fromstring(inputString)
	local compressedBuffer = buffer_create(buffer_len(input) + 256)
	local writeOffset = 0
	buffer_writeu32(compressedBuffer, writeOffset, MAGIC_NUMBER_VALUE)
	writeOffset += MAGIC_BYTES
	local inputPos = 1
	while inputPos <= buffer_len(input) do
		local blockLen = math.min(buffer_len(input) - inputPos + 1, BLOCK_SIZE)
		local block = buffer_create(blockLen)
		buffer_copy(block, 0, input, inputPos - 1, blockLen)
		inputPos += blockLen
		local literals = {}
		local sequences = {}
		local hashTable = {}
		local pos = 1
		local anchor = 1
		while pos <= blockLen do
			if pos + MIN_MATCH_LENGTH > blockLen then break end
			local hash = getRollingHash(block, pos)
			local matchPos = hashTable[hash]
			local bestMatchLen = 0
			local bestMatchDist = 0
			if matchPos and pos - matchPos < 65535 then
				local matchLen = 0
				while pos + matchLen <= blockLen and
					matchPos + matchLen <= blockLen and
					buffer_readu8(block, pos + matchLen -1) == buffer_readu8(block, matchPos + matchLen - 1) do
					matchLen += 1
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
				pos += bestMatchLen
				anchor = pos
			else
				pos += 1
			end
		end
		if anchor <= blockLen then
			local literalLen = blockLen - anchor + 1
			table.insert(sequences, {litLen = literalLen, dist = 0, matchLen = 0})
			local litBlock = buffer_create(literalLen)
			buffer_copy(litBlock, 0, block, anchor - 1, literalLen)
			table.insert(literals, litBlock)
		end
		local totalLitLen = 0
		for _, litBuf in ipairs(literals) do totalLitLen += buffer_len(litBuf) end
		local literalsBuffer = buffer_create(totalLitLen)
		local litOffset = 0
		for _, litBuf in ipairs(literals) do
			buffer_copy(literalsBuffer, litOffset, litBuf, 0, buffer_len(litBuf))
			litOffset += buffer_len(litBuf)
		end
		local freqs = Huffman.getFrequencies(literalsBuffer, 1, buffer_len(literalsBuffer))
		local tree = Huffman.buildTree(freqs)
		local codes = Huffman.buildEncodingTable(tree)
		local serializedTable = Huffman.serializeTable(codes)
		local bitStreamBuffer = buffer_create(math.max(16, buffer_len(literalsBuffer)))
		local bitPosition = 0
		for i=1, buffer_len(literalsBuffer) do
			local byte = buffer_readu8(literalsBuffer, i - 1)
			local huffCode = codes[byte]
			if huffCode then
				for j = huffCode.length - 1, 0, -1 do
					local bit = bit32.band(bit32.rshift(huffCode.code, j), 1)
					local byteIndex = math.floor(bitPosition / 8)
					local bitInByte = bitPosition % 8
					if byteIndex >= buffer_len(bitStreamBuffer) then
						local newBuf = buffer_create(buffer_len(bitStreamBuffer) * 2)
						buffer_copy(newBuf, 0, bitStreamBuffer, 0, buffer_len(bitStreamBuffer))
						bitStreamBuffer = newBuf
					end
					local currentVal = buffer_readu8(bitStreamBuffer, byteIndex)
					buffer_writeu8(bitStreamBuffer, byteIndex, bit32.bor(currentVal, bit32.lshift(bit, bitInByte)))
					bitPosition += 1
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
			seqOffset += 12
		end
		local blockContentLen = 8 + buffer_len(serializedTable) + buffer_len(sequencesBuffer) + buffer_len(encodedLiterals)
		local compressedBlockContent = buffer_create(blockContentLen)
		local bccOffset = 0
		buffer_writeu32(compressedBlockContent, bccOffset, buffer_len(serializedTable))
		bccOffset += 4
		buffer_copy(compressedBlockContent, bccOffset, serializedTable, 0, buffer_len(serializedTable))
		bccOffset += buffer_len(serializedTable)
		buffer_writeu32(compressedBlockContent, bccOffset, #sequences)
		bccOffset += 4
		buffer_copy(compressedBlockContent, bccOffset, sequencesBuffer, 0, buffer_len(sequencesBuffer))
		bccOffset += buffer_len(sequencesBuffer)
		buffer_copy(compressedBlockContent, bccOffset, encodedLiterals, 0, buffer_len(encodedLiterals))
		if buffer_len(compressedBlockContent) < blockLen then
			buffer_writeu8(compressedBuffer, writeOffset, 1)
			buffer_writeu32(compressedBuffer, writeOffset + 1, buffer_len(compressedBlockContent))
			writeOffset += 5
			buffer_copy(compressedBuffer, writeOffset, compressedBlockContent, 0, buffer_len(compressedBlockContent))
			writeOffset += buffer_len(compressedBlockContent)
		else
			buffer_writeu8(compressedBuffer, writeOffset, 0)
			buffer_writeu32(compressedBuffer, writeOffset + 1, blockLen)
			writeOffset += 5
			buffer_copy(compressedBuffer, writeOffset, block, 0, blockLen)
			writeOffset += blockLen
		end
	end
	local finalBuffer = buffer_create(writeOffset)
	buffer_copy(finalBuffer, 0, compressedBuffer, 0, writeOffset)
	return buffer_tostring(finalBuffer)
end

function module.decompress(compressedString: string)
	if type(compressedString) ~= "string" or #compressedString < MAGIC_BYTES + 5 then
		error("Invalid or corrupted data")
	end
	local compressed = buffer.fromstring(compressedString)
	local readOffset = 0
	local magic = buffer_readu32(compressed, readOffset)
	if magic ~= MAGIC_NUMBER_VALUE then
		error(string.format("Invalid magic number. Expected FD2FB528, got %08X", magic))
	end
	readOffset += MAGIC_BYTES
	local output = {}
	while readOffset < buffer_len(compressed) do
		local flag = buffer_readu8(compressed, readOffset)
		local blockSize = buffer_readu32(compressed, readOffset + 1)
		readOffset += 5
		if flag == 0 then
			local rawBlock = buffer_create(blockSize)
			buffer_copy(rawBlock, 0, compressed, readOffset, blockSize)
			table.insert(output, rawBlock)
			readOffset += blockSize
		else
			local blockStart = readOffset
			readOffset += blockSize 
			local blockData = buffer_create(blockSize)
			buffer_copy(blockData, 0, compressed, blockStart, blockSize)
			local current = 0
			local tableSize = buffer_readu32(blockData, current)
			current += 4
			local decodingTree, nextPos = Huffman.deserializeTable(blockData, current, tableSize)
			current = nextPos
			local numSequences = buffer_readu32(blockData, current)
			current += 4
			local sequences = table.create(numSequences)
			local totalLitLen = 0
			local totalDecompressedSize = 0
			for i = 1, numSequences do
				if current + 12 > buffer_len(blockData) then
					error("Zstd: Corrupted Sequence Data (Buffer OOB)")
				end
				local litLen = buffer_readu32(blockData, current)
				local matchLen = buffer_readu32(blockData, current + 4)
				local dist = buffer_readu32(blockData, current + 8)
				current += 12
				sequences[i] = {litLen = litLen, matchLen = matchLen, dist = dist}
				totalLitLen += litLen
				totalDecompressedSize += (litLen + matchLen)
			end
			local literalStream = buffer_create(buffer_len(blockData) - current)
			buffer_copy(literalStream, 0, blockData, current, buffer_len(literalStream))
			local literalsBuffer = buffer_create(totalLitLen)
			local litWritePos = 0
			local bitPosition = 0
			local totalLitBits = buffer_len(literalStream) * 8
			local node = decodingTree
			for _ = 1, totalLitLen do
				while node and not node.char do
					if bitPosition >= totalLitBits then break end
					local byteIndex = math.floor(bitPosition / 8)
					local bitInByte = bitPosition % 8
					if byteIndex >= buffer_len(literalStream) then break end
					local byte = buffer_readu8(literalStream, byteIndex)
					local bit = bit32.band(bit32.rshift(byte, bitInByte), 1)
					bitPosition += 1
					node = node[bit]
				end
				if node and node.char then
					buffer_writeu8(literalsBuffer, litWritePos, node.char)
					litWritePos += 1
					node = decodingTree
				else
					break
				end
			end
			local finalBlockBuf = buffer_create(totalDecompressedSize)
			local writePos = 0
			local litReadPos = 0
			for _, seq in ipairs(sequences) do
				if seq.litLen > 0 then
					buffer_copy(finalBlockBuf, writePos, literalsBuffer, litReadPos, seq.litLen)
					writePos += seq.litLen
					litReadPos += seq.litLen
				end
				if seq.matchLen > 0 then
					local matchOffset = writePos - seq.dist
					if matchOffset < 0 then
						error("Zstd: Invalid match distance (buffer underflow)")
					end

					if seq.dist >= seq.matchLen then
						buffer_copy(finalBlockBuf, writePos, finalBlockBuf, matchOffset, seq.matchLen)
					else
						for i = 0, seq.matchLen - 1 do
							local byte = buffer_readu8(finalBlockBuf, matchOffset + (i % seq.dist))
							buffer_writeu8(finalBlockBuf, writePos + i, byte)
						end
					end
					writePos += seq.matchLen
				end
			end
			table.insert(output, finalBlockBuf)
		end
	end
	local totalLen = 0
	for _, buf in ipairs(output) do totalLen += buffer_len(buf) end
	local finalOutputBuffer = buffer_create(totalLen)
	local outOffset = 0
	for _, buf in ipairs(output) do
		buffer_copy(finalOutputBuffer, outOffset, buf, 0, buffer_len(buf))
		outOffset += buffer_len(buf)
	end
	return buffer_tostring(finalOutputBuffer)
end

return module