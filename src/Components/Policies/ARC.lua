-- N. Megiddo & D. Modha (IBM Research, 2003)
-- DO NOT EDIT IF YOU DON'T KNOW WHAT YOU'RE DOING
local ARC = {}
ARC.__index = ARC
local Debugger = require(script.Parent.Parent.Debugger)

local LinkedList = {}
LinkedList.__index = LinkedList

function LinkedList.new()
	return setmetatable({head = nil, tail = nil, size = 0}, LinkedList)
end

function LinkedList:pushFront(node)
	node.prev, node.next = nil, self.head
	if self.head then 
		self.head.prev = node 
	else
		self.tail = node
	end
	self.head = node
	self.size = self.size + 1
end

function LinkedList:pushBack(node)
	node.next, node.prev = nil, self.tail
	if self.tail then
		self.tail.next = node
	else
		self.head = node
	end
	self.tail = node
	self.size = self.size + 1
end

function LinkedList:popBack()
	if not self.tail then return nil end
	local node = self.tail
	self:remove(node)
	return node
end

function LinkedList:remove(node)
	if node.prev then 
		node.prev.next = node.next 
	else
		self.head = node.next
	end
	if node.next then 
		node.next.prev = node.prev 
	else
		self.tail = node.prev
	end
	node.prev, node.next = nil, nil
	self.size = self.size - 1
end

function LinkedList:isEmpty()
	return self.head == nil
end

function LinkedList:moveToFront(node)
	if self.head == node then return end
	self:remove(node)
	self:pushFront(node)
end

function ARC.new(maxSize, manager)
	maxSize = Debugger.Check(maxSize, "ARC")
	return setmetatable({
		_maxSize = maxSize,
		_manager = manager,
		_T1 = LinkedList.new(),
		_T2 = LinkedList.new(),  
		_B1 = LinkedList.new(),
		_B2 = LinkedList.new(),
		_T1_lookup = {},
		_T2_lookup = {},
		_B1_lookup = {},
		_B2_lookup = {},
		_p = 0,
		_cacheSize = 0,
	}, ARC)
end

local function replace(self, key)
	local victimKey = nil
	if not self._T1:isEmpty() and 
		(self._T1.size > self._p or 
			(self._B2_lookup[key] and self._T1.size == self._p)) then
		local victim = self._T1:popBack()
		if victim then
			self._T1_lookup[victim.key] = nil
			self._B1_lookup[victim.key] = victim
			self._B1:pushFront(victim)
			victimKey = victim.key
		end
	else
		local victim = self._T2:popBack()
		if victim then
			self._T2_lookup[victim.key] = nil
			self._B2_lookup[victim.key] = victim
			self._B2:pushFront(victim)
			victimKey = victim.key
		end
	end
	self._cacheSize = self._cacheSize - 1
	return victimKey
end

function ARC:access(key)
	local t1_node = self._T1_lookup[key]
	local t2_node = self._T2_lookup[key]
	if t1_node then
		self._T1:remove(t1_node)
		self._T1_lookup[key] = nil
		self._T2:pushFront(t1_node)
		self._T2_lookup[key] = t1_node
		return true
	elseif t2_node then
		self._T2:moveToFront(t2_node)
		return true
	end
	return false
end

function ARC:insert(key)
	if self:access(key) then
		return nil 
	end
	local evictedKey = nil
	local b1_node = self._B1_lookup[key]
	if b1_node then
		local delta = math.max(self._B2.size / self._B1.size, 1)
		self._p = math.min(self._p + delta, self._maxSize)
		self._B1:remove(b1_node)
		self._B1_lookup[key] = nil
		if self._cacheSize >= self._maxSize then
			evictedKey = replace(self, key)
		end
		local new_node = {key = key}
		self._T2:pushFront(new_node)
		self._T2_lookup[key] = new_node
		self._cacheSize = self._cacheSize + 1
		return evictedKey
	end
	local b2_node = self._B2_lookup[key]
	if b2_node then
		local delta = math.max(self._B1.size / self._B2.size, 1)
		self._p = math.max(self._p - delta, 0)
		self._B2:remove(b2_node)
		self._B2_lookup[key] = nil
		if self._cacheSize >= self._maxSize then
			evictedKey = replace(self, key)
		end
		local new_node = {key = key}
		self._T2:pushFront(new_node)
		self._T2_lookup[key] = new_node
		self._cacheSize = self._cacheSize + 1
		return evictedKey
	end
	-- L1 = T1 + B1, L2 = T2 + B2
	local L1_size = self._T1.size + self._B1.size
	local L2_size = self._T2.size + self._B2.size
	if L1_size == self._maxSize then
		if self._T1.size < self._maxSize then
			local lru_b1 = self._B1:popBack()
			if lru_b1 then
				self._B1_lookup[lru_b1.key] = nil
			end
			replace(self, key)
		else
			local lru_t1 = self._T1:popBack()
			if lru_t1 then
				self._T1_lookup[lru_t1.key] = nil
				self._cacheSize = self._cacheSize - 1
				evictedKey = lru_t1.key
			end
		end
	elseif L1_size < self._maxSize and L1_size + L2_size >= self._maxSize then
		if L1_size + L2_size == 2 * self._maxSize then
			local lru_b2 = self._B2:popBack()
			if lru_b2 then
				self._B2_lookup[lru_b2.key] = nil
			end
		end
		evictedKey = replace(self, key)
	end
	local new_node = {key = key}
	self._T1:pushFront(new_node)
	self._T1_lookup[key] = new_node
	self._cacheSize = self._cacheSize + 1
	return evictedKey
end

function ARC:insertBatch(keysToInsert)
	local evictedKeys = {}
	if #keysToInsert == 0 then
		return evictedKeys
	end
	for _, key in ipairs(keysToInsert) do
		local evicted = self:insert(key)
		if evicted then
			table.insert(evictedKeys, evicted)
		end
	end
	return evictedKeys
end

function ARC:evict()
	if self._cacheSize == 0 then return nil end
	local evictedKey = nil
	if not self._T1:isEmpty() and self._T1.size > self._p then
		local victim = self._T1:popBack()
		if victim then
			self._T1_lookup[victim.key] = nil
			self._B1_lookup[victim.key] = victim
			self._B1:pushFront(victim)
			evictedKey = victim.key
		end
	elseif not self._T2:isEmpty() then
		local victim = self._T2:popBack()
		if victim then
			self._T2_lookup[victim.key] = nil
			self._B2_lookup[victim.key] = victim
			self._B2:pushFront(victim)
			evictedKey = victim.key
		end
	end
	if evictedKey then
		self._cacheSize = self._cacheSize - 1
	end
	return evictedKey
end

function ARC:clear()
	self._T1 = LinkedList.new()
	self._T2 = LinkedList.new()
	self._B1 = LinkedList.new()
	self._B2 = LinkedList.new()
	self._T1_lookup = {}
	self._T2_lookup = {}
	self._B1_lookup = {}
	self._B2_lookup = {}
	self._p = 0
	self._cacheSize = 0
end

function ARC:remove(key)
	local t1_node = self._T1_lookup[key]
	if t1_node then
		self._T1:remove(t1_node)
		self._T1_lookup[key] = nil
		self._cacheSize = self._cacheSize - 1
		return
	end
	local t2_node = self._T2_lookup[key]
	if t2_node then
		self._T2:remove(t2_node)
		self._T2_lookup[key] = nil
		self._cacheSize = self._cacheSize - 1
		return
	end
	local b1_node = self._B1_lookup[key]
	if b1_node then
		self._B1:remove(b1_node)
		self._B1_lookup[key] = nil
		return
	end
	local b2_node = self._B2_lookup[key]
	if b2_node then
		self._B2:remove(b2_node)
		self._B2_lookup[key] = nil
		return
	end
end

function ARC:snapshot()
	local function listToArray(list)
		local arr = {}
		local node = list.head
		while node do
			table.insert(arr, node.key)
			node = node.next
		end
		return arr
	end
	return {
		T1 = listToArray(self._T1),
		T2 = listToArray(self._T2),
		B1 = listToArray(self._B1),
		B2 = listToArray(self._B2),
		p = self._p,
		cacheSize = self._cacheSize
	}
end

function ARC:restore(state)
	self:clear()
	self._p = state.p or 0
	self._cacheSize = state.cacheSize or 0
	local function arrayToList(arr, list, lookup)
		for i = #arr, 1, -1 do 
			local key = arr[i]
			local node = {key = key}
			list:pushFront(node)
			lookup[key] = node
		end
	end
	arrayToList(state.T1 or {}, self._T1, self._T1_lookup)
	arrayToList(state.T2 or {}, self._T2, self._T2_lookup) 
	arrayToList(state.B1 or {}, self._B1, self._B1_lookup)
	arrayToList(state.B2 or {}, self._B2, self._B2_lookup)
end

function ARC:getStats()
	return {
		maxSize = self._maxSize,
		cacheSize = self._cacheSize,
		T1_size = self._T1.size,
		T2_size = self._T2.size,
		B1_size = self._B1.size,
		B2_size = self._B2.size,
		target_T1_size = self._p,
		L1_size = self._T1.size + self._B1.size,
		L2_size = self._T2.size + self._B2.size
	}
end

return ARC