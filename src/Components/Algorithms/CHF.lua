-- (Cryptographic Hash Functions)
-- DO NOT EDIT IF YOU DON'T KNOW WHAT YOU'RE DOING
local CHF = {}

local function rotateLeft(value,bits)
	return bit32.lrotate(value,bits)
end

local function rotateRight(value,bits)
	return bit32.rrotate(value,bits)
end

local function toHex(num)
	return string.format("%08x",num)
end

local function stringToBytes(str)
	local bytes = {}
	for i = 1,#str do
		table.insert(bytes,string.byte(str,i))
	end
	return bytes
end

local function bytesToString(bytes)
	local chars = {}
	for i = 1,#bytes do
		table.insert(chars,string.char(bytes[i]))
	end
	return table.concat(chars)
end

function CHF.SHA256(input)
	local K = {
		0x428a2f98,0x71374491,0xb5c0fbcf,0xe9b5dba5,
		0x3956c25b,0x59f111f1,0x923f82a4,0xab1c5ed5,
		0xd807aa98,0x12835b01,0x243185be,0x550c7dc3,
		0x72be5d74,0x80deb1fe,0x9bdc06a7,0xc19bf174,
		0xe49b69c1,0xefbe4786,0x0fc19dc6,0x240ca1cc,
		0x2de92c6f,0x4a7484aa,0x5cb0a9dc,0x76f988da,
		0x983e5152,0xa831c66d,0xb00327c8,0xbf597fc7,
		0xc6e00bf3,0xd5a79147,0x06ca6351,0x14292967,
		0x27b70a85,0x2e1b2138,0x4d2c6dfc,0x53380d13,
		0x650a7354,0x766a0abb,0x81c2c92e,0x92722c85,
		0xa2bfe8a1,0xa81a664b,0xc24b8b70,0xc76c51a3,
		0xd192e819,0xd6990624,0xf40e3585,0x106aa070,
		0x19a4c116,0x1e376c08,0x2748774c,0x34b0bcb5,
		0x391c0cb3,0x4ed8aa4a,0x5b9cca4f,0x682e6ff3,
		0x748f82ee,0x78a5636f,0x84c87814,0x8cc70208,
		0x90befffa,0xa4506ceb,0xbef9a3f7,0xc67178f2
	}
	local H = {
		0x6a09e667,0xbb67ae85,0x3c6ef372,0xa54ff53a,
		0x510e527f,0x9b05688c,0x1f83d9ab,0x5be0cd19
	}
	local bytes = stringToBytes(input)
	local originalLength = #bytes
	table.insert(bytes,0x80)
	while (#bytes % 64) ~= 56 do
		table.insert(bytes,0x00)
	end
	local lengthBits = originalLength * 8
	for i = 7,0,-1 do
		table.insert(bytes,bit32.band(bit32.rshift(lengthBits,i * 8),0xff))
	end
	for chunkStart = 1,#bytes,64 do
		local W = {}
		for i = 0,15 do
			local wordStart = chunkStart + i * 4
			W[i] = bit32.bor(
				bit32.lshift(bytes[wordStart],24),
				bit32.lshift(bytes[wordStart + 1],16),
				bit32.lshift(bytes[wordStart + 2],8),
				bytes[wordStart + 3]
			)
		end
		for i = 16,63 do
			local s0 = bit32.bxor(
				rotateRight(W[i - 15],7),
				rotateRight(W[i - 15],18),
				bit32.rshift(W[i - 15],3)
			)
			local s1 = bit32.bxor(
				rotateRight(W[i - 2],17),
				rotateRight(W[i - 2],19),
				bit32.rshift(W[i - 2],10)
			)
			W[i] = bit32.band(W[i - 16] + s0 + W[i - 7] + s1,0xffffffff)
		end
		local a,b,c,d,e,f,g,h = H[1],H[2],H[3],H[4],H[5],H[6],H[7],H[8]
		for i = 0,63 do
			local S1 = bit32.bxor(rotateRight(e,6),rotateRight(e,11),rotateRight(e,25))
			local ch = bit32.bxor(bit32.band(e,f),bit32.band(bit32.bnot(e),g))
			local temp1 = bit32.band(h + S1 + ch + K[i + 1] + W[i],0xffffffff)
			local S0 = bit32.bxor(rotateRight(a,2),rotateRight(a,13),rotateRight(a,22))
			local maj = bit32.bxor(bit32.band(a,b),bit32.band(a,c),bit32.band(b,c))
			local temp2 = bit32.band(S0 + maj,0xffffffff)
			h = g
			g = f
			f = e
			e = bit32.band(d + temp1,0xffffffff)
			d = c
			c = b
			b = a
			a = bit32.band(temp1 + temp2,0xffffffff)
		end
		H[1] = bit32.band(H[1] + a,0xffffffff)
		H[2] = bit32.band(H[2] + b,0xffffffff)
		H[3] = bit32.band(H[3] + c,0xffffffff)
		H[4] = bit32.band(H[4] + d,0xffffffff)
		H[5] = bit32.band(H[5] + e,0xffffffff)
		H[6] = bit32.band(H[6] + f,0xffffffff)
		H[7] = bit32.band(H[7] + g,0xffffffff)
		H[8] = bit32.band(H[8] + h,0xffffffff)
	end
	return toHex(H[1])..toHex(H[2])..toHex(H[3])..toHex(H[4])..
		toHex(H[5])..toHex(H[6])..toHex(H[7])..toHex(H[8])
end

function CHF.MD5(input)
	local bytes = stringToBytes(input)
	local originalLength = #bytes
	local s = {
		7,12,17,22,7,12,17,22,7,12,17,22,7,12,17,22,
		5,9,14,20,5,9,14,20,5,9,14,20,5,9,14,20,
		4,11,16,23,4,11,16,23,4,11,16,23,4,11,16,23,
		6,10,15,21,6,10,15,21,6,10,15,21,6,10,15,21
	}
	local K = {}
	for i = 1,64 do
		K[i] = math.floor(math.abs(math.sin(i)) * 2^32)
	end
	local h = {0x67452301,0xEFCDAB89,0x98BADCFE,0x10325476}
	table.insert(bytes,0x80)
	while (#bytes % 64) ~= 56 do
		table.insert(bytes,0x00)
	end
	local lengthBits = originalLength * 8
	for i = 0,7 do
		table.insert(bytes,bit32.band(bit32.rshift(lengthBits,i * 8),0xff))
	end
	for chunkStart = 1,#bytes,64 do
		local w = {}
		for i = 0,15 do
			local wordStart = chunkStart + i * 4
			w[i] = bit32.bor(
				bytes[wordStart],
				bit32.lshift(bytes[wordStart + 1],8),
				bit32.lshift(bytes[wordStart + 2],16),
				bit32.lshift(bytes[wordStart + 3],24)
			)
		end
		local a,b,c,d = h[1],h[2],h[3],h[4]
		for i = 0,63 do
			local f,g
			if i < 16 then
				f = bit32.bor(bit32.band(b,c),bit32.band(bit32.bnot(b),d))
				g = i
			elseif i < 32 then
				f = bit32.bor(bit32.band(d,b),bit32.band(bit32.bnot(d),c))
				g = (5 * i + 1) % 16
			elseif i < 48 then
				f = bit32.bxor(b,c,d)
				g = (3 * i + 5) % 16
			else
				f = bit32.bxor(c,bit32.bor(b,bit32.bnot(d)))
				g = (7 * i) % 16
			end
			local temp = d
			d = c
			c = b
			b = bit32.band(b + rotateLeft(bit32.band(a + f + K[i + 1] + w[g],0xffffffff),s[i + 1]),0xffffffff)
			a = temp
		end
		h[1] = bit32.band(h[1] + a,0xffffffff)
		h[2] = bit32.band(h[2] + b,0xffffffff)
		h[3] = bit32.band(h[3] + c,0xffffffff)
		h[4] = bit32.band(h[4] + d,0xffffffff)
	end
	local result = ""
	for i = 1,4 do
		local val = h[i]
		for j = 0,3 do
			result = result..string.format("%02x",bit32.band(bit32.rshift(val,j * 8),0xff))
		end
	end
	return result
end

function CHF.SimpleHash(input)
	local hash = 0
	for i = 1,#input do
		hash = bit32.band((hash * 31) + string.byte(input,i),0xffffffff)
	end
	return string.format("%08x",hash)
end

function CHF.HMAC(key,message,hashFunction)
	hashFunction = hashFunction or CHF.SHA256
	local blockSize = 64 
	local keyBytes = stringToBytes(key)
	if #keyBytes > blockSize then
		local hashedKey = hashFunction(key)
		keyBytes = {}
		for i = 1,#hashedKey,2 do
			table.insert(keyBytes,tonumber(hashedKey:sub(i,i+1),16))
		end
	end
	while #keyBytes < blockSize do
		table.insert(keyBytes,0)
	end
	local innerPad = {}
	local outerPad = {}
	for i = 1,blockSize do
		table.insert(innerPad,bit32.bxor(keyBytes[i],0x36))
		table.insert(outerPad,bit32.bxor(keyBytes[i],0x5c))
	end
	local innerHash = hashFunction(bytesToString(innerPad)..message)
	local outerInput = bytesToString(outerPad)..innerHash
	return hashFunction(outerInput)
end

function CHF.VerifyHash(input,expectedHash,hashFunction)
	hashFunction = hashFunction or CHF.SHA256
	local actualHash = hashFunction(input)
	return actualHash:lower() == expectedHash:lower()
end

function CHF.SecureCompare(hash1,hash2)
	if #hash1 ~= #hash2 then
		return false
	end
	local result = 0
	for i = 1,#hash1 do
		result = bit32.bor(result,bit32.bxor(string.byte(hash1,i),string.byte(hash2,i)))
	end
	return result == 0
end

function CHF.GenerateSalt(length)
	length = length or 16
	local salt = ""
	local chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789"
	for i = 1,length do
		local randIndex = math.random(1,#chars)
		salt = salt..chars:sub(randIndex,randIndex)
	end
	return salt
end

function CHF.HashPassword(password,salt)
	salt = salt or CHF.GenerateSalt()
	local hash = CHF.SHA256(salt..password)
	return {
		hash = hash,
		salt = salt
	}
end

function CHF.VerifyPassword(password,salt,expectedHash)
	local hash = CHF.SHA256(salt..password)
	return CHF.SecureCompare(hash,expectedHash)
end

return CHF
