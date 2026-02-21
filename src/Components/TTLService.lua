-- DO NOT EDIT IF YOU DON'T KNOW WHAT YOU'RE DOING
local TTL = {}
TTL.__index = TTL
local BloomFilter = script.Parent.Algorithms.BloomFilter
local CuckooFilter = require(script.Parent.Algorithms.CuckooFilter)

local BloomFilterAdapter = {}
BloomFilterAdapter.__index = BloomFilterAdapter
function BloomFilterAdapter.new(capacity, errorRate)
	local self = setmetatable({}, BloomFilterAdapter)
	self.filter = BloomFilter.new(capacity, errorRate)
	return self
end
function BloomFilterAdapter:Lookup(key)
	return self.filter:Contains(key)
end
function BloomFilterAdapter:Insert(key)
	self.filter:Add(key)
end
function BloomFilterAdapter:Delete(key)
	-- unsupported
end

local function heap_swap(h, i, j, idx)
	h[i], h[j] = h[j], h[i]
	idx[h[i].key] = i
	idx[h[j].key] = j
end

local function heapify_up(h, i, idx)
	while i > 1 do
		local p = math.floor(i/2)
		if h[p].expires <= h[i].expires then break end
		heap_swap(h, p, i, idx)
		i = p
	end
end

local function heapify_down(h, i, idx)
	local n = #h
	while true do
		local l, r = 2*i, 2*i+1
		local smallest = i
		if l <= n and h[l].expires < h[smallest].expires then
			smallest = l
		end
		if r <= n and h[r].expires < h[smallest].expires then
			smallest = r
		end
		if smallest == i then break end
		heap_swap(h, i, smallest, idx)
		i = smallest
	end
end

function TTL.new(manager, capacity:number?, filterType:string?, onExpireCallback)
	local filter
	local capacity = capacity or 10000
	local errorRate = 0.01
	if filterType == "cuckoo" or filterType == "cuckoofilter" then
		filter = CuckooFilter.new(capacity)
	else -- default to bloom
		filterType = "bloom"
		filter = BloomFilterAdapter.new(capacity, errorRate)
	end
	local self = setmetatable({
		_manager = manager,
		_heap = {},
		_originalTTLs = {},
		_index = {},
		_timer = nil,
		_scheduled = false,
		_filter = filter,
		_filterType = filterType,
		_onExpireCallback = onExpireCallback,
	}, TTL)
	return self
end

function TTL:setOriginalTTL(key, duration)
	self._originalTTLs[key] = duration
end

function TTL:getOriginalTTL(key)
	return self._originalTTLs[key]
end

function TTL:push(key, expires)
	local keyExists = self._filter:Lookup(key)
	if keyExists and self._index[key] then
		self:invalidate(key)
	end
	local node = { key = key, expires = expires }
	table.insert(self._heap, node)
	self._filter:Insert(key)
	local i = #self._heap
	self._index[key] = i
	heapify_up(self._heap, i, self._index)
	if self._index[key] == 1 then
		if self._timer then
			task.cancel(self._timer)
			self._timer = nil
		end
		if not self._scheduled then
			self:start()
		else
			self:_scheduleNext()
		end
	end
end

function TTL:peek()
	return self._heap[1]
end

function TTL:pop()
	if #self._heap == 0 then return nil end
	local root = self._heap[1]
	self._index[root.key] = nil
	self._originalTTLs[root.key] = nil
	if self._filterType == "cuckoo" or 
		self._filterType == "cuckoofilter" 
	then
		self._filter:Delete(root.key)
	end
	local last = table.remove(self._heap)
	if #self._heap > 0 then
		self._heap[1] = last
		self._index[last.key] = 1
		heapify_down(self._heap, 1, self._index)
	end
	return root
end

function TTL:invalidate(key)
	local i = self._index[key]
	if not i then return end
	self._originalTTLs[key] = nil
	self._filter:Delete(key)
	local lastIdx = #self._heap
	if i ~= lastIdx then
		heap_swap(self._heap, i, lastIdx, self._index)
	end
	table.remove(self._heap, lastIdx)
	self._index[key] = nil
	if i <= #self._heap then
		local p = math.floor(i/2)
		if i > 1 and self._heap[i].expires < self._heap[p].expires then
			heapify_up(self._heap, i, self._index)
		else
			heapify_down(self._heap, i, self._index)
		end
	end
end

function TTL:_expireLoop()
	local now = self._manager:_getTime()
	while true do
		local nextNode = self:peek()
		if not nextNode or nextNode.expires > now then break end
		local node = self:pop()
		if self._onExpireCallback then
			self._onExpireCallback(node.key)
		else
			local entry = self._manager._dict[node.key]
			if entry then
				self._manager:_RemoveInternal(node.key, true)
			end
		end
	end
end

function TTL:_scheduleNext()
	self._timer = nil
	local nextNode = self:peek()
	if not nextNode then
		self._scheduled = false
		return
	end
	local now = self._manager:_getTime()
	local waitTime = nextNode.expires - now
	if waitTime <= 0 then
		self:_expireLoop()
		task.defer(function()
			self:_scheduleNext()
		end)
	else
		self._timer = task.delay(waitTime, function()
			self:_expireLoop()
			self:_scheduleNext()
		end)
	end
end

function TTL:start()
	if self._scheduled then return end
	self._scheduled = true
	self:_scheduleNext()
end

function TTL:stop()
	if self._timer then
		task.cancel(self._timer)
		self._timer = nil
	end
	self._scheduled = false
end

return TTL