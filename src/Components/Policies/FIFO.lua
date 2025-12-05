-- Peter J. Denning (1968)
-- DO NOT EDIT IF YOU DON'T KNOW WHAT YOU'RE DOING
local FIFO = {}
FIFO.__index = FIFO
local Debugger = require(script.Parent.Parent.Debugger)

function FIFO.new(maxSize, manager)
	maxSize = Debugger.Check(maxSize, "FIFO")
	return setmetatable({
		_maxSize = maxSize,
		_manager = manager,
		_queue   = {},
	}, FIFO)
end

function FIFO:access(key)
--	self._manager:_pruneByMemory(0)
	-- no‑op for FIFO
end

function FIFO:insert(key)
--	self._manager:_pruneByMemory(0)
	for i = #self._queue, 1, -1 do
		if self._queue[i] == key then
			table.remove(self._queue, i)
		end
	end
	table.insert(self._queue, key)
	if #self._queue > self._maxSize then
		return table.remove(self._queue, 1)
	end
	return nil
end

function FIFO:insertBatch(keysToInsert)
--	self._manager:_pruneByMemory(0)
	local evictedKeys = {}
	if #keysToInsert == 0 then
		return evictedKeys
	end
	local keysToInsertSet = {}
	for _, key in ipairs(keysToInsert) do
		keysToInsertSet[key] = true
	end
	for i = #self._queue, 1, -1 do
		if keysToInsertSet[self._queue[i]] then
			table.remove(self._queue, i)
		end
	end
	for _, keyToAdd in ipairs(keysToInsert) do
		table.insert(self._queue, keyToAdd)
	end
	local numToEvict = #self._queue - self._maxSize
	if numToEvict > 0 then
		local newQueueSlice = {}
		for i = 1, numToEvict do
			local evicted = self._queue[i]
			if evicted then
				table.insert(evictedKeys, evicted)
			end
		end
		for i = numToEvict + 1, #self._queue do
			table.insert(newQueueSlice, self._queue[i])
		end
		self._queue = newQueueSlice
	end
	return evictedKeys
end

function FIFO:evict()
--	self._manager:_pruneByMemory(0)
	if #self._queue == 0 then 
		return nil
	end
	return table.remove(self._queue, 1)
end

function FIFO:clear()
	self._queue = {}
end

function FIFO:remove(key)
	for i = #self._queue, 1, -1 do
		if self._queue[i] == key then
			table.remove(self._queue, i)
			break
		end
	end
end

function FIFO:snapshot()
	local q = {}
	for i, key in ipairs(self._queue) do
		q[i] = key
	end
	return {queue = q}
end

function FIFO:restore(state)
	if type(state) ~= "table" or type(state.queue) ~= "table" then
		error("invalid state, skipping restore")
	end
	self._queue = {}
	for _, key in ipairs(state.queue) do
		table.insert(self._queue, key)
	end
end

return FIFO
