-- DO NOT EDIT IF YOU DON'T KNOW WHAT YOU'RE DOING
local random = {}
random.__index = random
local Debugger = require(script.Parent.Parent.Debugger)

function random.new(maxSize, manager)
	maxSize = Debugger.Check(maxSize, "RR")
	return setmetatable({
		_maxSize = maxSize,
		_manager = manager,
		_keys = {},
		_keySet = {},
	}, random)
end

function random:insert(key)
--	self._manager:_pruneByMemory(0)
	if self._keySet[key] then
		return nil
	end
	table.insert(self._keys, key)
	self._keySet[key] = #self._keys
	if #self._keys > self._maxSize then
		local idx = math.random(1, #self._keys)
		local victim = self._keys[idx]
		local last = table.remove(self._keys)
		if idx <= #self._keys then
			self._keys[idx] = last
			self._keySet[last] = idx
		end
		self._keySet[victim] = nil
		return victim
	end
	return nil
end

function random:insertBatch(keysToInsert)
--	self._manager:_pruneByMemory(0)
	local evictedKeys = {}
	if #keysToInsert == 0 then
		return evictedKeys
	end
	local newKeysAdded = 0
	for _, key in ipairs(keysToInsert) do
		if not self._keySet[key] then
			table.insert(self._keys, key)
			self._keySet[key] = #self._keys
			newKeysAdded = newKeysAdded + 1
		end
	end
	if newKeysAdded == 0 and #self._keys <= self._maxSize then
		return evictedKeys
	end
	while #self._keys > self._maxSize do
		if #self._keys == 0 then break end
		local idx = math.random(1, #self._keys)
		local victimKey = self._keys[idx]
		local lastKeyInArray = table.remove(self._keys)
		if idx <= #self._keys then
			self._keys[idx] = lastKeyInArray
			self._keySet[lastKeyInArray] = idx
		end
		self._keySet[victimKey] = nil
		table.insert(evictedKeys, victimKey)
	end
	return evictedKeys
end

function random:access(key)
--	self._manager:_pruneByMemory(0)
	-- no-op
end

function random:remove(key)
	local idx = self._keySet[key]
	if not idx then return end
	local lastKey = table.remove(self._keys)
	if idx <= #self._keys then
		self._keys[idx] = lastKey
		self._keySet[lastKey] = idx
	end
	self._keySet[key] = nil
end

function random:clear()
	self._keys = {}
	self._keySet = {}
end

function random:snapshot()
	local keysCopy = {unpack(self._keys)}
	return {keys = keysCopy}
end

function random:restore(state)
	self._keys = {unpack(state.keys)}
	self._keySet = {}
	for i, key in ipairs(self._keys) do
		self._keySet[key] = i
	end
end

function random:evict()
	-- self._manager:_pruneByMemory(0)
	if #self._keys == 0 then return nil end
	local randomIndex = math.random(1, #self._keys)
	local victimKey = self._keys[randomIndex]
	local lastKey = self._keys[#self._keys]
	self._keys[randomIndex] = lastKey
	self._keySet[lastKey] = randomIndex
	table.remove(self._keys)
	self._keySet[victimKey] = nil
	return victimKey
end

return random
