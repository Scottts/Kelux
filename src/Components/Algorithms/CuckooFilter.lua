-- Fan, Andersen, Kaminsky, and Mitzenmacher
-- DO NOT EDIT IF YOU DON'T KNOW WHAT YOU'RE DOING
local module = {}
module.__index = module

local BUCKET_SIZE = 4 
local FINGERPRINT_SIZE = 8 
local MAX_KICKS = 500 

local function hash(item, seed)
	seed = seed or 0
	local h = seed
	for i = 1, #item do
		h = (h * 31 + string.byte(item, i)) % 2147483647
	end
	return h
end

local function fingerprint(item)
	local fp = hash(item, 12345) % (2^FINGERPRINT_SIZE)
	return fp == 0 and 1 or fp
end

local function altHash(fp, i)
	return bit32.bxor(i, hash(tostring(fp), 54321))
end

function module.new(capacity)
	capacity = capacity or 1000
	local numBuckets = math.ceil(capacity / (0.95 * BUCKET_SIZE))
	numBuckets = 2^math.ceil(math.log(numBuckets) / math.log(2))
	local self = setmetatable({
		buckets = {},
		numBuckets = numBuckets,
		size = 0,
		capacity = capacity
	}, module)
	for i = 0, numBuckets - 1 do
		self.buckets[i] = {}
		for j = 1, BUCKET_SIZE do
			self.buckets[i][j] = 0 
		end
	end
	return self
end

function module:_getBucketIndex(hash_val)
	return hash_val % self.numBuckets
end

function module:_insertToBucket(bucketIndex, fp)
	local bucket = self.buckets[bucketIndex]
	for i = 1, BUCKET_SIZE do
		if bucket[i] == 0 then
			bucket[i] = fp
			return true
		end
	end
	return false 
end

function module:_deleteFromBucket(bucketIndex, fp)
	local bucket = self.buckets[bucketIndex]
	for i = 1, BUCKET_SIZE do
		if bucket[i] == fp then
			bucket[i] = 0
			return true
		end
	end
	return false 
end

function module:_lookupInBucket(bucketIndex, fp)
	local bucket = self.buckets[bucketIndex]
	for i = 1, BUCKET_SIZE do
		if bucket[i] == fp then
			return true
		end
	end
	return false
end

function module:Insert(item)
	local fp = fingerprint(item)
	local i1 = self:_getBucketIndex(hash(item))
	local i2 = self:_getBucketIndex(altHash(fp, i1))
	if self:_insertToBucket(i1, fp) then
		self.size = self.size + 1
		return true
	end
	if self:_insertToBucket(i2, fp) then
		self.size = self.size + 1
		return true
	end
	local i = math.random() < 0.5 and i1 or i2
	for kick = 1, MAX_KICKS do
		local entryIndex = math.random(1, BUCKET_SIZE)
		local bucket = self.buckets[i]
		local temp = bucket[entryIndex]
		bucket[entryIndex] = fp
		fp = temp
		i = self:_getBucketIndex(altHash(fp, i))
		if self:_insertToBucket(i, fp) then
			self.size = self.size + 1
			return true
		end
	end
	return false, "Unable to insert after maximum kicks"
end

function module:Lookup(item)
	local fp = fingerprint(item)
	local i1 = self:_getBucketIndex(hash(item))
	local i2 = self:_getBucketIndex(altHash(fp, i1))
	return self:_lookupInBucket(i1, fp) or self:_lookupInBucket(i2, fp)
end

function module:Delete(item)
	local fp = fingerprint(item)
	local i1 = self:_getBucketIndex(hash(item))
	local i2 = self:_getBucketIndex(altHash(fp, i1))
	if self:_deleteFromBucket(i1, fp) then
		self.size = self.size - 1
		return true
	end
	if self:_deleteFromBucket(i2, fp) then
		self.size = self.size - 1
		return true
	end
	return false 
end

function module:GetSize()
	return self.size
end

function module:GetCapacity()
	return self.capacity
end

function module:GetLoadFactor()
	return self.size / (self.numBuckets * BUCKET_SIZE)
end

function module:GetStats()
	local emptyBuckets = 0
	local fullBuckets = 0
	for i = 0, self.numBuckets - 1 do
		local bucket = self.buckets[i]
		local empty = 0
		local full = 0
		for j = 1, BUCKET_SIZE do
			if bucket[j] == 0 then
				empty = empty + 1
			else
				full = full + 1
			end
		end
		if empty == BUCKET_SIZE then
			emptyBuckets = emptyBuckets + 1
		elseif full == BUCKET_SIZE then
			fullBuckets = fullBuckets + 1
		end
	end
	return {
		size = self.size,
		capacity = self.capacity,
		numBuckets = self.numBuckets,
		loadFactor = self:GetLoadFactor(),
		emptyBuckets = emptyBuckets,
		fullBuckets = fullBuckets
	}
end

return module
