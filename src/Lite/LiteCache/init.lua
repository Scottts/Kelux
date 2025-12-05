--[[
	AUTHOR: Kel (@GudEveningBois)

	Created:
	5/1/25
	11:10 PM UTC+9
	
	The lite version of LiteCache.
	Read documentary in LiteCache.Documentary
	
	NOTE:[
		LiteCache offers 15 methods compared FullCache's 60 methods.
		Additionally, LiteCache only has 2 algorithms compared
		to FullCache's 7 algorithms.
	]
]]
local VERSION = "0.3.06 (STABLE)"
-- Dependencies
-- Adjust all of these positions if used elsewhere...
local TypeDef = require(script.TypeDef)
local Debugger = require(script.Parent.Parent.Components.Debugger)
local Signal = require(script.Parent.Parent.Components.KelSignal)
local TTL = require(script.Parent.Parent.Components.TTLService)

-- Algorithms
local Algorithms = script.Parent.Parent.Components.Algorithms
local Trie = require(Algorithms.Trie)
local xxHash = require(Algorithms.xxHash)

-- Cache is set to strong table as default
local Cache = {}
local createMutex = {isLocked = false, queue = {}}
local PolicyLocation = script.Parent.Parent.Components.Policies -- Adjust position if used elsewhere
local Policies = {
	FIFO = require(PolicyLocation.FIFO),		-- First In, First Out
	LRU = require(PolicyLocation.LRU),			-- Least Recently Used
	LFU = require(PolicyLocation.LFU),			-- Least Frequently Used
	RR = require(PolicyLocation.RR),			-- Random Replacement
	ARC = require(PolicyLocation.ARC), 			-- Adaptive Replacement Cache
	-- Add your own custom policy here too 
	-- [instructions for creating your own policy hasn't been created yet]
}

-- Default settings
local DefaultMax = 1000
local DefaultMemoryBudget = math.huge
local DefaultSerializedSize = math.huge

local LiteCache = {}
LiteCache.__index = LiteCache

-- Services
local RunService = game:GetService("RunService")
local HttpService = game:GetService("HttpService")

local tableIDs = setmetatable({}, {__mode = "k"})
local idToTable = {}
local nextID = 0

-- Helper functions ----------------------------------------------------------------------------------------
-- Since these are helper functions, do not use any of these externally.
-- (The helper methods are "usually" named with an underscore, AKA '_')

-- Table size & shape
local function _dictSize(d)
	local n = 0
	for _ in pairs(d) do 
		n += 1
	end
	return n
end
local function _isArray(t)
	if type(t) ~= "table" then return false end
	local count = 0
	for k,_ in pairs(t) do
		if type(k) ~= "number" or k < 1 or k % 1 ~= 0 then
			return false
		end
		count += 1
	end
	return #t == count
end
function LiteCache:_getTime()
	if self._ttlUseClock then
		return os.clock()
	else
		return os.time()
	end
end
-- Key normalization
local function tableKey(t)
	local id = tableIDs[t]
	if not id then
		nextID += 1
		id = "__TBL_"..tostring(nextID)
		tableIDs[t] = id
		idToTable[id] = t
	end
	return id
end
local function normalizeKey(key)
	local keyType = type(key)
	if keyType == "string" or keyType == "userdata" then
		return key
	elseif keyType == "table" then
		return tableKey(key)
	else
		Debugger:Throw("error", "normalizeKey", ("expected key to be string, table, or userdata, got: %s")
			:format(keyType))
	end
end
-- Trie
local function stringToSequence(str)
	local seq = {}
	for i = 1, #str do
		table.insert(seq, string.sub(str, i, i))
	end
	return seq
end
local function getKeysFromNode(node)
	local keys = {}
	local function recurse(currentNode)
		if currentNode.isTerminal and currentNode.actionName then
			table.insert(keys, currentNode.actionName)
		end
		for _, childNode in pairs(currentNode.children) do
			recurse(childNode)
		end
	end
	recurse(node)
	return keys
end

-- [[Pruning & Budgeting]]

function LiteCache:_pruneByMemory(newEntrySize)
	if not self._memoryBudget or self._memoryBudget == math.huge then
		return
	end
	while (self._memoryUsage + newEntrySize > self._memoryBudget) do
		local victimKey = self._policy.evict and self._policy:evict()
		if not victimKey then
			break
		end
		self:_RemoveInternal(victimKey, false)
		self:_memoryUpdate()
	end
end

-- [[Usage Updates]]

function LiteCache:_memoryUpdate()
	local info: TypeDef.MemoryChangeInfo = {
		used = self._memoryUsage,
		budget = self._memoryBudget,
		percentUsed = (self._memoryBudget == math.huge) and 0 or (self._memoryUsage / self._memoryBudget),
	}
end
function LiteCache:_chargeRemoval(entry, section)
	local size = entry._size or 0
	if section == "array" then
		self._arrayMemoryUsage = math.max(0, self._arrayMemoryUsage - size)
	elseif section == "dict" then
		self._dictMemoryUsage  = math.max(0, self._dictMemoryUsage  - size)
	end
	self._memoryUsage = self._arrayMemoryUsage + self._dictMemoryUsage
	self:_memoryUpdate()
end
function LiteCache:_addMemoryUsage(size, section)
	if section == "array" then
		self._arrayMemoryUsage += size
	elseif section == "dict" then
		self._dictMemoryUsage += size
	end
	self._memoryUsage = self._arrayMemoryUsage + self._dictMemoryUsage
	self:_memoryUpdate()
end
function LiteCache:_ensureMemoryForSize(additionalSize)
	if not self._memoryBudget or self._memoryBudget == math.huge or additionalSize <= 0 then
		return true
	end
	while (self._memoryUsage + additionalSize > self._memoryBudget) do
		local freedMemoryInIteration = false
		if _dictSize(self._dict) > 0 then
			local victimKey = self._policy.evict and self._policy:evict()
			if victimKey then
				local entry = self._dict[victimKey]
				local victimSize = entry and entry._size or 0
				if victimSize > 0 then
					self:_RemoveInternal(victimKey, false)
					freedMemoryInIteration = true
				end
			end
		end
		if not freedMemoryInIteration and self._arrayCount > 0 then
			if self:_evictArrayOne() then
				freedMemoryInIteration = true
			end
		end
		if not freedMemoryInIteration then
			Debugger:Throw("warn", "_ensureMemoryForSize", "Failed to free memory; no eviction candidates found.")
			return false -- Explicitly fail
		end
	end
	return true
end

-- [[Internal eviction/removal]]

function LiteCache:_evictArrayOne()
	if self._arrayCount == 0 then
		return false
	end
	local entry = self._array[self._arrayHead]
	while not entry and self._arrayHead < self._arrayLogicalEnd do
		self._array[self._arrayHead] = nil
		self._arrayHead += 1
		entry = self._array[self._arrayHead]
		Debugger:Throw("warn", "_evictArrayOne", "Correcting for nil entry at array head.")
		self._arrayCount = math.max(0, self._arrayCount - 1)
	end
	if not entry then
		self._arrayCount = 0
		return false
	end
	self._array[self._arrayHead] = nil
	self._arrayHead += 1
	self._arrayCount -= 1
	self:_chargeRemoval(entry, "array")
	self._evictSignal:Fire({kind="array", value=entry.value, expired=false})
	if self._arrayHead > 1000 and self._arrayCount < (self._arrayLogicalEnd - self._arrayHead + 1) / 2 then
		self:_compactArray()
	end
	return true
end
function LiteCache:_compactArray()
	if self._arrayCount == 0 then
		self._array = {}
		self._arrayHead = 1
		self._arrayLogicalEnd = 0
		return
	end
	local newArray = {}
	local currentNewIndex = 0
	for i = self._arrayHead, self._arrayLogicalEnd do
		local entry = self._array[i]
		if entry then
			currentNewIndex += 1
			newArray[currentNewIndex] = entry
		end
	end
	self._array = newArray
	self._arrayHead = 1
	self._arrayLogicalEnd = currentNewIndex
	self._arrayCount = currentNewIndex
end
function LiteCache:_RemoveInternal(key:string, expired:boolean)
	local entry = self._dict[key]
	if not entry then
		return
	end
	if type(key) == "string" then
		self._keyTrie:remove(key, stringToSequence(key))
	end
	self._metrics.evictions += 1
	self:_chargeRemoval(entry, "dict")
	if self._policy.remove then
		self._policy:remove(key)
	end
	self._dict[key] = nil
	self._ttl:invalidate(key)
	self._evictSignal:Fire({kind = "dict", key = key, value = entry.value, expired = expired,})
end

-- [[Policy & Serialization Internals]]

function LiteCache:_setPolicy(opts)
	-- Policy selection, the only available ones are: FIFO, LRU, LFU
	local Policy = nil
	local policyModule = nil
	if opts.Policy and typeof(opts.Policy) == "string" then
		policyModule = Policies[opts.Policy:upper()]
		if not policyModule then
			local policyNames = {}
			for name in pairs(Policies) do
				table.insert(policyNames, name)
			end
			table.sort(policyNames)
			local valid = table.concat(policyNames, ", ")
			Debugger:Throw("error","SetPolicy", ("unrecognized policy %q; valid options: %s")
				:format(opts.Policy, valid))
		end	
		Policy = policyModule.new(self._maxobj, self)
	elseif typeof(opts.Policy) == "table" and opts.Policy.insert then
		Policy = opts.Policy
	else
		Policy = Policies.FIFO.new(self._maxobj, self)
	end

	self._policy = Policy
	self._policyName = string.upper(opts.Policy or "FIFO")
	self._policyModule  = policyModule

	-- Apply weak/strong table to the data bases
	local Mode = opts.Mode or nil
	if Mode and (string.lower(Mode) == "weak"
		or string.lower(Mode) == "kv"
		or string.lower(Mode) == "k"
		or string.lower(Mode) == "v")
	then
		local wk = { __mode = Mode }
		setmetatable(self._array, wk)
		setmetatable(self._dict, wk)
	elseif Mode and Mode ~= "strong" then
		Debugger:Throw("warn","Create", ("invalid Mode %q; supported modes: \"strong\", \"k\", \"v\", \"kv\"")
			:format(Mode))
	end
end
function LiteCache:_encodeEntry(value, existingEntry)
	local entry = existingEntry or {value = value}
	local isNewEntry = not entry._size
	local oldSize = isNewEntry and 0 or entry._size

	if isNewEntry then
		local success, encodedValueString
		local calculatedSize = 0
		local jsonRepresentation = ""

		if self._estimateSizeFn then
			local customSizeSuccess, customSize = pcall(self._estimateSizeFn, value)
			if customSizeSuccess and type(customSize) == "number" then
				calculatedSize = customSize
				success = true
				local jsonSuccessPcall, jsonEncodedStrPcall = pcall(HttpService.JSONEncode, HttpService, value)
				if jsonSuccessPcall then
					jsonRepresentation = jsonEncodedStrPcall
				else
					jsonRepresentation = ""
				end
			else
				success = false
				Debugger:Throw("warn", "_encodeEntry", "Custom EstimateSizeFunction failed or returned non-number. Falling back.")
			end
		end

		if not success then
			if type(value) == "string" then 
				success = true
				calculatedSize = #value
				local jsonSuccess, jsonEncodedStr = pcall(HttpService.JSONEncode, HttpService, value)
				if jsonSuccess then
					jsonRepresentation = jsonEncodedStr
				else
					jsonRepresentation = ""
				end
			end
		end
		if success then
			entry._size = calculatedSize
			entry._json = jsonRepresentation
		else
			entry._size = 0
			entry._json = ""
			Debugger:Throw("warn", "_encodeEntry", ("Failed to serialize or size value. Type: %s")
				:format(type(value)))
		end
	end
	if entry._size > self._maxEntrySizeBytes then
		Debugger:Throw("error","encodeEntry", ("exceeds MaxSerializedSize (%d > %d)")
			:format(entry._size, self._maxEntrySizeBytes))
	end
	local sizeDelta = entry._size - oldSize
	if sizeDelta > 0 then
		if not self:_ensureMemoryForSize(sizeDelta) then
			Debugger:Throw("error", "_encodeEntry", "Not enough memory to store entry after pruning attempts.")
		end
	end
	return entry
end

--[[Mutex Locking]]
local function lockCreate()
	if createMutex.isLocked then
		local waiterSignal = Signal.new()
		table.insert(createMutex.queue, waiterSignal)
		waiterSignal:Wait()
	end
	createMutex.isLocked = true
end
local function unlockCreate()
	if #createMutex.queue > 0 then
		local nextWaiter = table.remove(createMutex.queue, 1)
		nextWaiter:Fire()
	else
		createMutex.isLocked = false
	end
end
function LiteCache:_lock()
	local threadId = coroutine.running()
	if self._isLocked and self._lockOwner ~= threadId then
		local waiterSignal = Signal.new()
		table.insert(self._lockQueue, waiterSignal)
		waiterSignal:Wait()
	end
	self._isLocked = true
	self._lockOwner = threadId
	self._lockCount = self._lockCount + 1
end
function LiteCache:_unlock()
	local threadId = coroutine.running()
	if not self._isLocked or self._lockOwner ~= threadId then
		return
	end
	self._lockCount = self._lockCount - 1
	if self._lockCount == 0 then
		self._isLocked = false
		self._lockOwner = nil
		if #self._lockQueue > 0 then
			local nextWaiter = table.remove(self._lockQueue, 1)
			nextWaiter:Fire()
		end
	end
end

-- [[Internals]]
function LiteCache:_setInternal(key, value)
	local realKey = normalizeKey(key)
	local existingEntry = self._dict[realKey]
	local entry = self:_encodeEntry(value, existingEntry)
	if existingEntry then
		self:_chargeRemoval(existingEntry, "dict")
	end
	self:_addMemoryUsage(entry._size, "dict")
	self._dict[realKey] = entry
	local evictedKey = self._policy:insert(realKey)
	if evictedKey and evictedKey ~= realKey then
		self:_RemoveInternal(evictedKey, false)
	end
	self:_memoryUpdate()
	return value
end
function LiteCache:_getInternal(key, skipExpire)
	if skipExpire ~= true then
		self._ttl:_expireLoop()
	end
	local realKey = normalizeKey(key)
	local entry = self._dict[realKey]
	if not entry then
		self._metrics.misses = (self._metrics.misses or 0) + 1
		return nil
	end

	self._metrics.hits = (self._metrics.hits or 0) + 1
	self._policy:access(realKey)
	return entry.value
end
function LiteCache:_insertSingleInternal(item)
	if self._arrayCount >= self._maxobj then
		self:_evictArrayOne()
	end
	local entry = self:_encodeEntry(item) 
	if not entry then
		Debugger:Throw("error", "InsertSingle", "Failed to encode or secure memory for item.")
	end
	self._arrayLogicalEnd += 1
	self._array[self._arrayLogicalEnd] = entry
	self._arrayCount += 1
	self:_addMemoryUsage(entry._size, "array")
	return item
end
function LiteCache:_insertBatchInternal(items)
	if #items == 0 then return {} end
	self:Pause() -- Pausing TTL service is part of the core logic
	local preparedEntries, totalNewSize, successfulItems = {}, 0, {}

	for _, itemValue in ipairs(items) do
		local entry = self:_encodeEntry(itemValue)
		if entry and entry._size <= self._maxEntrySizeBytes then
			table.insert(preparedEntries, entry)
			totalNewSize += entry._size
			table.insert(successfulItems, itemValue)
		else
			Debugger:Throw("warn", "InsertBatch", ("Item skipped: too large or failed to prepare. Value: %s"):
				format(tostring(itemValue)))
		end
	end
	if #preparedEntries == 0 then
		self:Resume()
		return {}
	end
	local numToEvictForMaxObj = #preparedEntries - (self._maxobj - self._arrayCount)
	if numToEvictForMaxObj > 0 then
		for _ = 1, numToEvictForMaxObj do
			if self._arrayCount == 0 then break end
			self:_evictArrayOne()
		end
	end
	if not self:_ensureMemoryForSize(totalNewSize) then
		self:Resume()
		Debugger:Throw("error", "InsertBatch", "Not enough memory for batch after pruning attempts. Batch aborted.")
		return {}
	end
	for _, entryData in ipairs(preparedEntries) do
		self._arrayLogicalEnd += 1
		self._array[self._arrayLogicalEnd] = entryData
		self._arrayCount += 1
		self:_addMemoryUsage(entryData._size, "array")
	end
	self:Resume()
	return successfulItems
end
function LiteCache:_hasInternal(key)
	self._ttl:_expireLoop()
	local realKey = normalizeKey(key)
	local entry = self._dict[realKey]
	if entry and entry.expires and os.time() > entry.expires then
		self:_RemoveInternal(realKey, true)
		return false
	end
	return entry ~= nil
end
function LiteCache:_clearInternal()
	self._dict, self._array = {}, {}
	self._arrayHead, self._arrayLogicalEnd, self._arrayCount = 1, 0, 0
	self._ttl:stop()
	self._memoryUsage, self._arrayMemoryUsage, self._dictMemoryUsage = 0, 0, 0
	self:_memoryUpdate()
	if self._policy.clear then
		self._policy:clear()
	else
		local module = self._policyModule or Policies.FIFO
		self._policy = module.new(self._maxobj, self)
	end
	if self._policyModule and self._policyModule.__name then
		self._policyName = self._policyModule.__name:upper()
	else
		self._policyName = "FIFO"
	end
	self._ttl = TTL.new(self)
	self._ttl:start()
end

------------------------------------------------------------------------------------------------------------

-- Main Logic ----------------------------------------------------------------------------------------------

function LiteCache.Create<T>(CacheName:string, MaxObjects:number?,
	Opts:{Mode:string, Policy:string, MemoryBudget:number, MaxSerializedSize:number}?):LiteCache<T>
	lockCreate()
	local success, result = pcall(function()
		-- Asserts are slow...
		if typeof(CacheName) ~= "string" then
			Debugger:Throw("error","Create", ("invalid CacheName (%s); expected a string")
				:format(typeof(CacheName)))
		end
		if MaxObjects and typeof(MaxObjects) ~= "number" then
			Debugger:Throw("error","Create", ("invalid MaxObjects (%s); expected a positive integer")
				:format(CacheName, tostring(MaxObjects)))
		end
		-- Return to default settings if these are nil
		local opts = Opts or {}
		local maxObjs = MaxObjects or DefaultMax
		local memoryBudget = opts.MemoryBudget or DefaultMemoryBudget
		local serializedSizeBudget = opts.MaxSerializedSize or DefaultSerializedSize
		-- Make sure that it's not already registered
		if Cache[CacheName] then
			local cache = Cache[CacheName]
			cache._ttl:stop()
			cache._ttl = TTL.new(cache)
			for k,entry in pairs(cache._dict) do
				if entry.expires then
					cache._ttl:push(k, entry.expires)
				end
			end
			-- Reset limits
			cache._policy._maxSize = maxObjs
			cache._maxobj = maxObjs
			cache._memoryBudget = memoryBudget
			cache._maxEntrySizeBytes = serializedSizeBudget
			-- Reset memory counters
			cache._arrayMemoryUsage = 0
			cache._dictMemoryUsage  = 0
			-- Evict until under the new limit
			while _dictSize(cache._dict) > maxObjs do
				local victim = cache._policy.evict and cache._policy:evict()
				if not victim then break end
				cache:_RemoveInternal(victim, false)
			end
			while #cache._array > maxObjs do
				cache._evictArrayOne()
			end
			-- Recalculate memory usage for survivors
			for _, entry in ipairs(cache._array) do
				cache._arrayMemoryUsage += (entry._size or 0)
			end
			for _, entry in pairs(cache._dict) do
				cache._dictMemoryUsage += (entry._size or 0)
			end
			cache._memoryUsage = cache._arrayMemoryUsage + cache._dictMemoryUsage
			cache:_memoryUpdate()
			-- Restart policy and TTL
			cache:_setPolicy(opts)
			cache._ttl:start()
			return cache
		end
		-- Create new cache
		local self = setmetatable({
			_name  = CacheName,
			_destroyed = false,
			_isLocked = false,
			_lockOwner = nil,
			_lockCount = 0,
			_lockQueue = {},
			_metrics = {
				hits = 0,
				misses = 0,
				evictions = 0,
			},
			_evictSignal = Signal.new(),
			_array = {},
			_dict = {},
			_maxEntrySizeBytes = serializedSizeBudget,
			_memoryBudget = memoryBudget,
			_memoryUsage = 0,
			_maxobj = maxObjs,
		}, LiteCache)
		Cache[CacheName] = self
		-- Sectionized memory counters
		self._arrayMemoryUsage = 0
		self._dictMemoryUsage = 0
		self._keyTrie = Trie.new()
		-- Initiate policy and TTL cleaning service
		self._ttl = TTL.new(self)
		self:_setPolicy(opts)
		self._ttl:start()
		-- Check if eviction is needed after TTL cleared out expired entries
		while _dictSize(self._dict) > self._maxobj do
			local victim = self._policy.evict and self._policy:evict()
			if not victim then
				break
			end
			self:_RemoveInternal(victim, false)
		end
		return self
	end)
	unlockCreate()
	if not success then
		error(result)
	end
	return result
end

function LiteCache:InsertSingle(item:T): T
	if self._destroyed then
		Debugger:Throw("error", "InsertSingle", "Attempt to use a destroyed cache instance.")
		return
	end
	self:_lock()
	local success, result = pcall(self._insertSingleInternal, self, item)
	self:_unlock()
	if not success then
		error(result)
	end
	return result
end

function LiteCache:InsertBatch(items:{T}): {T}
	if self._destroyed then
		Debugger:Throw("error", "InsertBatch", "Attempt to use a destroyed cache instance.")
		return
	end
	self:_lock()
	local success, result = pcall(self._insertBatchInternal, self, items)
	self:_unlock()
	if not success then
		error(result)
	end
	return result
end

function LiteCache:Cleanup(): ()
	if self._destroyed then
		Debugger:Throw("error", "Cleanup", "Attempt to use a destroyed cache instance.")
		return
	end
	self:_lock()
	local success, result = pcall(function()
		self:_compactArray()
	end)
	self:_unlock()
	if not success then
		error(result)
	end
	return result
end

function LiteCache:Pause()
	if self._destroyed then
		Debugger:Throw("error", "Pause", "Attempt to use a destroyed cache instance.")
		return
	end
	self:_lock()
	local success, result = pcall(function()
		self._ttl:stop()
	end)
	self:_unlock()
	if not success then
		error(result)
	end
	return result
end

function LiteCache:Resume()
	if self._destroyed then
		Debugger:Throw("error", "Resume", "Attempt to use a destroyed cache instance.")
		return
	end
	self:_lock()
	local success, result = pcall(function()
		self._ttl:start()
	end)
	self:_unlock()
	if not success then
		error(result)
	end
	return result
end
------------------------------------------------------------------------------------------------------------

-- Key Access (Map Methods) --------------------------------------------------------------------------------

function LiteCache:Set(key:string|{any}, value:T):T
	if self._destroyed then
		Debugger:Throw("error", "Set", "Attempt to use a destroyed cache instance.")
		return
	end
	self:_lock()
	local success, result = pcall(self._setInternal, self, key, value)
	self:_unlock()
	if not success then
		error(result)
	end
	return result
end

function LiteCache:Get(key:string|{any}, SkipExpire:bool?):T?
	if self._destroyed then
		Debugger:Throw("error", "Get", "Attempt to use a destroyed cache instance.")
		return
	end
	self:_lock()
	local success, result = pcall(self._getInternal, self, key, SkipExpire)
	self:_unlock()
	if not success then
		error(result)
	end
	return result
end

function LiteCache:Has(key:string|{any}):boolean
	if self._destroyed then
		Debugger:Throw("error", "Has", "Attempt to use a destroyed cache instance.")
		return
	end
	self:_lock()
	local success, result = pcall(self._hasInternal, self, key)
	self:_unlock()
	if not success then
		error(result)
	end
	return result
end

function LiteCache:Remove(key:string|{any}):()
	if self._destroyed then
		Debugger:Throw("error", "Remove", "Attempt to use a destroyed cache instance.")
		return
	end
	self:_lock()
	local success, result = pcall(function()
		self._ttl:_expireLoop()
		local realKey = normalizeKey(key)
		self:_RemoveInternal(realKey, false)
	end)
	self:_unlock()
	if not success then
		error(result)
	end
	return result
end

function LiteCache:Clear():()
	if self._destroyed then
		Debugger:Throw("error", "Clear", "Attempt to use a destroyed cache instance.")
		return
	end
	self:_lock()
	local success, result = pcall(self._clearInternal, self)
	self:_unlock()
	if not success then
		error(result)
	end
	return result
end

function LiteCache:Destroy()
	if self._destroyed then
		Debugger:Throw("error", "Destroy", "Attempt to use a destroyed cache instance.")
		return
	end
	self:_lock()
	local success, result = pcall(function()
		self._destroyed = true
		if self._ttl and self._ttl.stop then
			self._ttl:stop()
		end
		local allKeys = {}
		for k in pairs(self._dict) do 
			table.insert(allKeys, k) 
		end
		for _, internalID in ipairs(allKeys) do
			if idToTable[internalID] then
				tableIDs[idToTable[internalID]] = nil
				idToTable[internalID] = nil
			end
		end
		if Cache[self._name] == self then
			Cache[self._name] = nil
		end
		self._array = nil
		self._dict = nil
		self._policy = nil
		self._metrics = nil
	end)
	self:_unlock()
	if success then
		setmetatable(self, nil)
	else
		error(result)
	end
end

--[[TTL]]

function LiteCache:SetWithTTL(key:string|{any}, value:T, ttl:number):T
	if self._destroyed then
		Debugger:Throw("error", "SetWithTTL", "Attempt to use a destroyed cache instance.")
		return
	end
	self:_lock()
	local success, result = pcall(function()
		local realKey = normalizeKey(key)
		local entry = self:_encodeEntry(value)
		entry.expires = os.time() + ttl
		self._dict[realKey] = entry
		self._ttl:push(realKey, entry.expires)
		local evicted = self._policy:insert(realKey)
		if evicted then self:_RemoveInternal(evicted, false) end
		self:_addMemoryUsage(entry._size, "dict")
		self:_memoryUpdate()
		return value
	end)
	self:_unlock()
	if not success then
		error(result)
	end
	return result
end

function LiteCache:TTLRemaining(key):number?
	if self._destroyed then
		Debugger:Throw("error", "TTLRemaining", "Attempt to use a destroyed cache instance.")
		return
	end
	self:_lock()
	local success, result = pcall(function()
		local realKey = normalizeKey(key)
		local entry = self._dict[realKey]
		if entry and entry.expires then
			return math.max(0, entry.expires - os.time())
		end
		return nil
	end)
	self:_unlock()
	if not success then
		error(result)
	end
	return result
end

-- [[INTROSPECTION AND ITERATION]]

function LiteCache:Peek(key:string|{any}):T?
	if self._destroyed then
		Debugger:Throw("error", "Peek", "Attempt to use a destroyed cache instance.")
		return
	end
	self:_lock()
	local success, result = pcall(function()
		local realKey = normalizeKey(key)
		local entry = self._dict[realKey]
		if entry and (not entry.expires or os.time() <= entry.expires) then
			return entry.value
		end
		return nil
	end)
	self:_unlock()
	if not success then
		error(result)
	end
	return result
end

function LiteCache:Keys():{string|{any}}
	if self._destroyed then
		Debugger:Throw("error", "Keys", "Attempt to use a destroyed cache instance.")
		return
	end
	self:_lock()
	local success, result = pcall(function()
		self._ttl:_expireLoop()
		local out = {}
		for internalID, entry in pairs(self._dict) do
			if not entry.expires or os.time() <= entry.expires then
				local origKey = idToTable[internalID] or internalID
				table.insert(out, origKey)
			end
		end
		return out
	end)
	self:_unlock()
	if not success then
		error(result)
	end
	return result
end

function LiteCache:Values():{T}
	if self._destroyed then
		Debugger:Throw("error", "Values", "Attempt to use a destroyed cache instance.")
		return
	end
	self:_lock()
	local success, result = pcall(function()
		self._ttl:_expireLoop()
		local out = {}
		for _, entry in ipairs(self._array) do
			table.insert(out, entry.value)
		end
		for internalID, entry in pairs(self._dict) do
			if not entry.expires or os.time() <= entry.expires then
				table.insert(out, entry.value)
			end
		end
		return out
	end)
	self:_unlock()
	if not success then
		error(result)
	end
	return result
end
LiteCache.Version = VERSION
------------------------------------------------------------------------------------------------------------
return LiteCache :: TypeDef.Static