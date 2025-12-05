-- DO NOT EDIT IF YOU DON'T KNOW WHAT YOU'RE DOING
local LRU = {}
LRU.__index = LRU
local Debugger = require(script.Parent.Parent.Debugger)

function LRU.new(maxSize, manager)
	maxSize = Debugger.Check(maxSize, "LRU")
	return setmetatable({
		_maxSize = maxSize,
		_manager = manager,
		_head = nil,
		_tail = nil,
		_nodes = {},
		_count = 0,
	}, LRU)
end

local function unlink(self, node)
	-- detach pointers only; do NOT touch self._count here
	if node.prev then node.prev.next = node.next end
	if node.next then node.next.prev = node.prev end
	if self._head == node then self._head = node.next end
	if self._tail == node then self._tail = node.prev end
	node.prev, node.next = nil, nil
end

local function linkHead(self, node)
	node.next = self._head
	if self._head then self._head.prev = node end
	self._head = node
	if not self._tail then self._tail = node end
	self._count = self._count + 1
end

function LRU:access(key)
--	self._manager:_pruneByMemory(0)
	local node = self._nodes[key]
	if not node then return end
	unlink(self, node)
	self._count = self._count - 1
	linkHead(self, node)
end

function LRU:insert(key)
--	self._manager:_pruneByMemory(0)
	if self._nodes[key] then
		self:access(key)
		return nil
	end

	local node = {key = key}
	self._nodes[key] = node
	linkHead(self, node)

	if self._count > self._maxSize then
		local old = self._tail
		unlink(self, old)
		self._nodes[old.key] = nil
		self._count = self._count - 1
		return old.key
	end
	return nil
end

function LRU:insertBatch(keysToInsert)
--	self._manager:_pruneByMemory(0)
	local evictedKeys = {}
	if #keysToInsert == 0 then
		return evictedKeys
	end
	local nodesToRelinkInOrder = {}
	for _, key in ipairs(keysToInsert) do
		local node = self._nodes[key]
		if node then
			unlink(self, node)
			self._count = self._count - 1
		else
			node = {key = key}
			self._nodes[key] = node
		end
		table.insert(nodesToRelinkInOrder, node)
	end
	for _, nodeToLink in ipairs(nodesToRelinkInOrder) do
		linkHead(self, nodeToLink)
	end
	while self._count > self._maxSize do
		local old = self._tail
		if not old then break end
		unlink(self, old)
		self._nodes[old.key] = nil
		self._count = self._count - 1
		table.insert(evictedKeys, old.key)
	end
	return evictedKeys
end

function LRU:evict()
--	self._manager:_pruneByMemory(0)
	if not self._tail then return nil end
	local old = self._tail
	unlink(self, old)
	self._nodes[old.key] = nil
	self._count = self._count - 1
	return old.key
end

function LRU:clear()
	self._head = nil
	self._tail = nil
	self._nodes = {}
	self._count = 0
end

function LRU:remove(key)
	local node = self._nodes[key]
	if not node then return end
	unlink(self, node)
	self._nodes[key] = nil
	self._count = self._count - 1
end

function LRU:snapshot()
	local order = {}
	local node = self._head
	while node do
		table.insert(order, node.key)
		node = node.next
	end
	return {order = order}
end

function LRU:restore(state)
	self:clear()
	for _, key in ipairs(state.order) do
		local node = {key = key}
		self._nodes[key] = node
		linkHead(self, node)
	end
end

return LRU
