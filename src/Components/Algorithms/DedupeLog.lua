--!optimize 2
local HttpService = game:GetService("HttpService")
local xxHash = require(script.Parent.xxHash)

local DedupeLog = {}
DedupeLog.__index = DedupeLog

local function getTime()
	return os.clock()
end

function DedupeLog.new(maxSize: number, maxAge: number)
	local self = setmetatable({
		_maxSize = maxSize or 100,
		_maxAge = maxAge or 1,
		_log = {},
		_head = nil,
		_tail = nil,
		_size = 0,
	}, DedupeLog)

	return self
end

function DedupeLog:CheckAndAdd(action: any): boolean
	local hash = self:_hashAction(action)
	local existing = self._log[hash]
	if existing then
		local now = getTime()
		if now - existing.timestamp <= self._maxAge then
			self:_moveToFront(existing)
			existing.timestamp = now
			return true 
		else
			self:_moveToFront(existing)
			existing.timestamp = now
			return false
		end
	end
	local node = {
		hash = hash,
		timestamp = getTime(),
		prev = nil,
		next = self._head,
	}
	self._log[hash] = node
	if self._head then
		self._head.prev = node
	end
	self._head = node
	if not self._tail then
		self._tail = node
	end
	self._size = self._size + 1
	self:_prune()
	return false
end

function DedupeLog:_prune()
	if self._size > self._maxSize then
		local tail = self._tail
		if tail then
			self._log[tail.hash] = nil
			self._tail = tail.prev
			if self._tail then
				self._tail.next = nil
			else
				self._head = nil
			end
			self._size = self._size - 1
		end
	end
	local now = getTime()
	local tail = self._tail
	while tail and (now - tail.timestamp > self._maxAge) do
		self._log[tail.hash] = nil
		self._tail = tail.prev
		if self._tail then
			self._tail.next = nil
		else
			self._head = nil
		end
		self._size = self._size - 1
		tail = self._tail
	end
end

function DedupeLog:_hashAction(action: any): string
	local ok, jsonStr = pcall(HttpService.JSONEncode, HttpService, action)
	if not ok then
		return tostring(action)
	end
	return xxHash.hash32Hex(jsonStr)
end

function DedupeLog:_moveToFront(node)
	if node == self._head then return end
	if node.prev then
		node.prev.next = node.next
	end
	if node.next then
		node.next.prev = node.prev
	end
	if node == self._tail then
		self._tail = node.prev
	end
	node.next = self._head
	node.prev = nil
	if self._head then
		self._head.prev = node
	end
	self._head = node
end

return DedupeLog
