local module = {}
module.__index = module

-- Hash function using string hashing with salt
local function hash(str, salt)
	local h = salt or 0
	for i = 1, #str do
		h = (h * 31 + string.byte(str, i)) % 2147483647
	end
	return h
end

-- Generate hash salts for different hash functions
local function generateSalts(numHashes)
	local salts = {}
	local rng = Random.new()
	for i = 1, numHashes do
		salts[i] = rng:NextInteger(1, 2147483647)
	end
	return salts
end

function module.new(epsilon, delta)
	epsilon = epsilon or 0.01
	delta = delta or 0.01

	-- Calculate dimensions
	local width = math.ceil(math.exp(1) / epsilon)
	local depth = math.ceil(math.log(1 / delta))

	local self = setmetatable({
		width = width,
		depth = depth,
		epsilon = epsilon,
		delta = delta,
		table = {},
		salts = generateSalts(depth),
		totalCount = 0
	}, module)

	-- Initialize the 2D table
	for i = 1, depth do
		self.table[i] = {}
		for j = 1, width do
			self.table[i][j] = 0
		end
	end

	return self
end

function module:Add(item, count)
	count = count or 1
	if type(item) ~= "string" then
		item = tostring(item)
	end

	for i = 1, self.depth do
		local hashValue = hash(item, self.salts[i])
		local index = (hashValue % self.width) + 1
		self.table[i][index] = self.table[i][index] + count
	end

	self.totalCount = self.totalCount + count
end

function module:Estimate(item)
	if type(item) ~= "string" then
		item = tostring(item)
	end

	local minCount = math.huge

	for i = 1, self.depth do
		local hashValue = hash(item, self.salts[i])
		local index = (hashValue % self.width) + 1
		local count = self.table[i][index]
		minCount = math.min(minCount, count)
	end

	return minCount == math.huge and 0 or minCount
end

function module:GetTotalCount()
	return self.totalCount
end

function module:GetFrequency(item)
	if self.totalCount == 0 then
		return 0
	end
	return self:Estimate(item) / self.totalCount
end

function module:Clear()
	for i = 1, self.depth do
		for j = 1, self.width do
			self.table[i][j] = 0
		end
	end
	self.totalCount = 0
end

function module:GetStats()
	return {
		width = self.width,
		depth = self.depth,
		epsilon = self.epsilon,
		delta = self.delta,
		totalCount = self.totalCount,
		memoryUsage = self.width * self.depth
	}
end

function module:Merge(other)
	if self.width ~= other.width or self.depth ~= other.depth then
		warn("Cannot merge Count-Min Sketches with different dimensions")
		return false
	end
	for i = 1, self.depth do
		if self.salts[i] ~= other.salts[i] then
			warn("Cannot merge Count-Min Sketches generated with different hash salts.")
			return false
		end
	end
	for i = 1, self.depth do
		for j = 1, self.width do
			self.table[i][j] = self.table[i][j] + other.table[i][j]
		end
	end

	self.totalCount = self.totalCount + other.totalCount
	return true
end

function module:Serialize()
	return {
		width = self.width,
		depth = self.depth,
		epsilon = self.epsilon,
		delta = self.delta,
		table = self.table,
		salts = self.salts,
		totalCount = self.totalCount
	}
end

function module.Deserialize(data)
	local self = setmetatable({
		width = data.width,
		depth = data.depth,
		epsilon = data.epsilon,
		delta = data.delta,
		table = data.table,
		salts = data.salts,
		totalCount = data.totalCount
	}, module)

	return self
end

return module