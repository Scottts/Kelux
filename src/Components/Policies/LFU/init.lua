-- DO NOT EDIT IF YOU DON'T KNOW WHAT YOU'RE DOING
local LFU = {}
LFU.__index = LFU
local Debugger = require(script.Parent.Parent.Debugger)
local CMS = require(script.CMS) -- Count-Min Sketch

-- simple doubly‑linked list for buckets
local LinkedList = {}
LinkedList.__index = LinkedList
function LinkedList.new()
	return setmetatable({head = nil, tail = nil}, LinkedList)
end
function LinkedList:pushFront(node)
	node.prev, node.next = nil, self.head
	if self.head then self.head.prev = node end
	self.head = node
	if not self.tail then self.tail = node end
end
function LinkedList:popBack()
	if not self.tail then return nil end
	local node = self.tail
	if node.prev then node.prev.next = nil end
	self.tail = node.prev
	node.prev, node.next = nil, nil
	return node
end
function LinkedList:remove(node)
	if node.prev then node.prev.next = node.next end
	if node.next then node.next.prev = node.prev end
	if self.head == node then self.head = node.next end
	if self.tail == node then self.tail = node.prev end
	node.prev, node.next = nil, nil
end
function LinkedList:isEmpty()
	return self.head == nil
end

function LFU.new(maxSize, manager, cmsEpsilon, cmsDelta)
	maxSize = Debugger.Check(maxSize, "LFU")
	return setmetatable({
		_maxSize   = maxSize,
		_manager = manager,
		_keyData   = {},
		_freqLists = {},
		_minFreq   = 0,
		_count = 0,
		_cms = CMS.new(cmsEpsilon, cmsDelta),
	}, LFU)
end

local function updateFrequency(self, key, entry)
	local node = entry.node
	local oldFreq = entry.freq
	local list = self._freqLists[oldFreq]
	list:remove(node)
	if list:isEmpty() then
		self._freqLists[oldFreq] = nil
		if self._minFreq == oldFreq then
			self._minFreq = oldFreq + 1
		end
	end
	entry.freq = oldFreq + 1
	local newList = self._freqLists[entry.freq] or LinkedList.new()
	newList:pushFront(node)
	self._freqLists[entry.freq] = newList
end

function LFU:access(key)
	--	self._manager:_pruneByMemory(0)
	self._cms:Add(key)
	local entry = self._keyData[key]
	if not entry then return end
	updateFrequency(self, key, entry)
end

function LFU:insert(key)
	local entry = self._keyData[key]
	if entry then
		self:access(key)
		return nil
	end
	self._cms:Add(key)
	local evictedKey = nil
	if self._count >= self._maxSize then
		local lfuList = self._freqLists[self._minFreq]
		local victimNode = lfuList and lfuList.tail
		if not victimNode then return nil end
		local victimKey = victimNode.key
		local victimEntry = self._keyData[victimKey]
		local candidateFreq = self._cms:Estimate(key)
		if not victimEntry or candidateFreq <= victimEntry.freq then
			return nil
		end
		lfuList:popBack()
		self._keyData[victimKey] = nil
		if lfuList:isEmpty() then
			self._freqLists[self._minFreq] = nil
		end
		self._count = self._count - 1
		evictedKey = victimKey
	end
	entry = {freq = 1, node = {key = key}}
	self._keyData[key] = entry
	local list = self._freqLists[1] or LinkedList.new()
	list:pushFront(entry.node)
	self._freqLists[1] = list
	self._minFreq = 1
	self._count = self._count + 1
	return evictedKey
end

function LFU:insertBatch(keysToInsert)
	--	self._manager:_pruneByMemory(0)
	local evictedKeys = {}
	local newKeysCount = 0
	if #keysToInsert == 0 then
		return evictedKeys
	end
	for _, key in ipairs(keysToInsert) do
		local entry = self._keyData[key]
		if entry then
			updateFrequency(self, key, entry)
		else
			self._cms:Add(key)
			entry = {freq = 1, node = {key = key}}
			self._keyData[key] = entry
			local list = self._freqLists[1] or LinkedList.new()
			list:pushFront(entry.node)
			self._freqLists[1] = list

			self._count = self._count + 1
			newKeysCount = newKeysCount + 1
		end
	end
	if newKeysCount > 0 then
		self._minFreq = 1
	end
	while self._count > self._maxSize do
		if self._minFreq == 0 then break end
		local lfuList = self._freqLists[self._minFreq]
		if not lfuList or lfuList:isEmpty() then
			self._freqLists[self._minFreq] = nil
			local newMin = math.huge
			for freq in pairs(self._freqLists) do
				if freq < newMin then
					newMin = freq
				end
			end
			self._minFreq = (newMin == math.huge) and 0 or newMin
			if self._minFreq == 0 then break end
			lfuList = self._freqLists[self._minFreq]
			if not lfuList or lfuList:isEmpty() then break end
		end
		local victimNode = lfuList:popBack()
		if not victimNode then
			warn("LFU list for minFreq was empty during eviction.")
			break
		end
		local victimKey = victimNode.key
		self._keyData[victimKey] = nil
		self._count = self._count - 1
		table.insert(evictedKeys, victimKey)
		if lfuList:isEmpty() then
			self._freqLists[self._minFreq] = nil
			local newMin = math.huge
			for freq in pairs(self._freqLists) do
				if freq < newMin then
					newMin = freq
				end
			end
			self._minFreq = (newMin == math.huge) and 0 or newMin
		end
	end
	return evictedKeys
end

function LFU:evict()
	--	self._manager:_pruneByMemory(0)
	if self._minFreq == 0 then return nil end
	local list = self._freqLists[self._minFreq]
	if not list then return nil end
	local victim = list:popBack()
	local key = victim.key
	self._keyData[key] = nil
	self._count = self._count - 1
	if list:isEmpty() then
		self._freqLists[self._minFreq] = nil
		local newMin = math.huge
		for freq in pairs(self._freqLists) do
			if freq < newMin then
				newMin = freq
			end
		end
		self._minFreq = (newMin == math.huge) and 0 or newMin
	end
	return key
end

function LFU:clear()
	self._keyData   = {}
	self._freqLists = {}
	self._minFreq   = 0
	self._count = 0
	if self._cms then self._cms:Clear() end
end

function LFU:remove(key)
	local entry = self._keyData[key]
	if not entry then return end
	local freq = entry.freq
	local list = self._freqLists[freq]
	if list then
		list:remove(entry.node)
		if list:isEmpty() then
			self._freqLists[freq] = nil
			if self._minFreq == freq then
				local newMin = math.huge
				for f in pairs(self._freqLists) do
					if f < newMin then newMin = f end
				end
				self._minFreq = (newMin == math.huge) and 0 or newMin
			end
		end
	end
	self._keyData[key] = nil
	self._count = self._count - 1
end

function LFU:snapshot()
	local state = {freqMap = {}, minFreq = self._minFreq}
	for freq, list in pairs(self._freqLists) do
		state.freqMap[freq] = {}
		local node = list.head
		while node do
			table.insert(state.freqMap[freq], node.key)
			node = node.next
		end
	end
	if self._cms then
		state.cms = self._cms:Serialize()
	end
	return state
end

function LFU:restore(state)
	self:clear()
	self._minFreq = state.minFreq or 0
	for freq, keys in pairs(state.freqMap) do
		local list = LinkedList.new()
		for _, key in ipairs(keys) do
			local node = {key = key}
			list:pushFront(node)
			self._keyData[key] = {freq = freq, node = node}
			self._count = self._count + 1
		end
		self._freqLists[freq] = list
	end
	if state.cms then
		self._cms = CMS.Deserialize(state.cms)
	end
end

return LFU
