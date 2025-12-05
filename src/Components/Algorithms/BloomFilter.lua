-- Burton Howard Bloom
-- DO NOT EDIT IF YOU DON'T KNOW WHAT YOU'RE DOING
local module = {}
module.__index = module

local function bounded_hash(str, size, seed)
	local hash = seed % size
	for i = 1, #str do
		hash = (hash * 33 + string.byte(str, i)) % size
	end
	return hash + 1
end

local function calculateOptimalParameters(expectedItems, falsePositiveRate)
	local m = math.ceil(-(expectedItems * math.log(falsePositiveRate)) / (math.log(2) ^ 2))
	local k = math.ceil((m / expectedItems) * math.log(2))
	return m, k
end

function module.new(expectedItems, falsePositiveRate)
	expectedItems = expectedItems or 1000
	falsePositiveRate = falsePositiveRate or 0.01
	expectedItems = tonumber(expectedItems) or 1000
	if expectedItems <= 0 then
		expectedItems = 1
		warn("BloomFilter expectedItems ≤ 0; defaulting to 1")
	end
	falsePositiveRate = tonumber(falsePositiveRate) or 0.01
	if falsePositiveRate <= 0 or falsePositiveRate >= 1 then
		falsePositiveRate = 0.01
		warn("BloomFilter falsePositiveRate invalid; defaulting to 0.01")
	end
	
	local m, k = calculateOptimalParameters(expectedItems, falsePositiveRate)
	local self = setmetatable({}, module)
	self.bitArray = {}
	self.size = m
	self.numHashFunctions = k
	self.expectedItems = expectedItems
	self.falsePositiveRate = falsePositiveRate
	self.itemCount = 0
	
	for i = 1, m do
		self.bitArray[i] = false
	end
	self.hashFunctions = {}
	for i = 1, k do
		local seed = 5381 + (i * 31)
		self.hashFunctions[i] = function(item, size)
			return bounded_hash(item, size, seed)
		end
	end
	return self
end

function module:Add(item)
	if type(item) ~= "string" then
		item = tostring(item)
	end
	for i = 1, self.numHashFunctions do
		local index = self.hashFunctions[i](item, self.size)
		if index ~= index or index < 1 or index > self.size then
			error(("BloomFilter:Add computed invalid index %s (size=%s)")
				:format(tostring(index), tostring(self.size)))
		end
		self.bitArray[index] = true
	end
	self.itemCount = self.itemCount + 1
end

function module:Contains(item)
	if type(item) ~= "string" then
		item = tostring(item)
	end
	for i = 1, self.numHashFunctions do
		local index = self.hashFunctions[i](item, self.size)
		if not self.bitArray[index] then
			return false
		end
	end
	return true
end

function module:Clear()
	for i = 1, self.size do
		self.bitArray[i] = false
	end
	self.itemCount = 0
end

function module:GetSize()
	return self.size
end

function module:GetItemCount()
	return self.itemCount
end

function module:GetNumHashFunctions()
	return self.numHashFunctions
end

function module:GetExpectedFalsePositiveRate()
	return self.falsePositiveRate
end

function module:GetCurrentFalsePositiveRate()
	if self.itemCount == 0 then
		return 0
	end
	local k = self.numHashFunctions
	local n = self.itemCount
	local m = self.size
	local rate = (1 - math.exp(-k * n / m)) ^ k
	return rate
end

function module:GetMemoryUsage()
	return self.size
end

function module:GetStats()
	return {
		size = self.size,
		itemCount = self.itemCount,
		expectedItems = self.expectedItems,
		numHashFunctions = self.numHashFunctions,
		expectedFalsePositiveRate = self.falsePositiveRate,
		currentFalsePositiveRate = self:GetCurrentFalsePositiveRate(),
		memoryUsageBits = self:GetMemoryUsage(),
		loadFactor = self.itemCount / self.expectedItems
	}
end

function module:Union(other)
	if self.size ~= other.size or self.numHashFunctions ~= other.numHashFunctions then
		error("Cannot union Bloom Filters with different parameters")
	end
	local result = module.new(self.expectedItems, self.falsePositiveRate)
	result.size = self.size
	result.numHashFunctions = self.numHashFunctions
	for i = 1, self.size do
		result.bitArray[i] = self.bitArray[i] or other.bitArray[i]
	end
	result.itemCount = self.itemCount + other.itemCount
	return result
end

function module:Intersection(other)
	if self.size ~= other.size or self.numHashFunctions ~= other.numHashFunctions then
		error("Cannot intersect Bloom Filters with different parameters")
	end
	local result = module.new(self.expectedItems, self.falsePositiveRate)
	result.size = self.size
	result.numHashFunctions = self.numHashFunctions
	for i = 1, self.size do
		result.bitArray[i] = self.bitArray[i] and other.bitArray[i]
	end
	result.itemCount = math.min(self.itemCount, other.itemCount)
	return result
end

return module
