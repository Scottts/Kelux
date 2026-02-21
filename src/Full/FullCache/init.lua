--!optimize 2
--[[
	AUTHOR: Kel (@GudEveningBois)

	Created:
	4/20/25
	2:32 PM UTC+9
	
	Read documentary in FullCache.Documentary
	
	NOTE:[
		I highly recommend not using the KELP serialization format for the time being.
		It's heavily under-developed and experimental so stick with JSON.
		KELP's current usage is for lower byte sizes when absolutely necessary.
		
		Benchmark test:
		JSON: 1.2230 sec over 100 runs (avg 0.012230) in 250134 bytes
		KELP: 1.3157 sec over 100 runs (avg 0.013157) in 211929 bytes
		JSON decode: 0.7263 sec over 100 runs (avg 0.007263)
		KELP decode: 0.9589 sec over 100 runs (avg 0.009589)
		
		JSON is C++, while KELP is pure LuaU, this is to be expected.
	]
]]
local Version = "3.56.2 (STABLE)"
-- Dependencies
-- Adjust all of these positions if used elsewhere...
local TypeDef = require(script.TypeDef)
local Components = script.Parent.Parent.Components
local Debugger = require(Components.Debugger).From(script.Name)
local Signal = require(Components.KelSignal)
local TTL = require(Components.TTLService)
local Mutex = require(Components.Mutex)
local KELP = require(Components.Formats.kelPacker) -- Experimental (unstable)

-- Algorithms
local Algorithms = Components.Algorithms
local Trie = require(Algorithms.Trie)
local AhoCorasick = require(Algorithms.AhoCorasick)
local LZ4 = require(Algorithms.LZ4)
local Zstd = require(Algorithms.Zstd)

-- Cache is set to strong table as default
local Cache = {}
local createMutex = Mutex.new()
local PolicyLocation = Components.Policies
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
local DefaultFormat = "JSON"

local FullCache = {}
FullCache.__index = FullCache

-- Services
local RunService = game:GetService("RunService")
local HttpService = game:GetService("HttpService")

local tableIDs = setmetatable({}, {__mode = "k"})
local idToTable = setmetatable({}, {__mode = "v"})
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
		count = count + 1
	end
	return #t == count
end
function FullCache:_getTime()
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
		-- Pass strings and userdata (Instances) through directly
		return key
	elseif keyType == "table" then
		-- Only call tableKey for actual tables
		return tableKey(key)
	else
		Debugger:Log("error", "normalizeKey", ("expected key to be string, table, or userdata, got: %s")
			:format(keyType))
	end
end
-- Cloning
local function _deepClone(orig, seen)
	local origType = type(orig)
	if origType ~= "table" then
		return orig
	end
	seen = seen or {}
	if seen[orig] then
		return seen[orig]
	end
	local copy = {}
	seen[orig] = copy
	local k, v = next(orig)
	while k ~= nil do
		local keyClone = type(k) == "table" and _deepClone(k, seen) or k
		local valueClone = type(v) == "table" and _deepClone(v, seen) or v
		copy[keyClone] = valueClone
		k, v = next(orig, k)
	end
	local mt = getmetatable(orig)
	if mt then
		setmetatable(copy, type(mt) == "table" and _deepClone(mt, seen) or mt)
	end
	return copy
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
local function getAllKeysFromNode(startNode)
	local keys = {}
	local function recurse(node)
		if node.isTerminal and node.actionName then
			table.insert(keys, node.actionName)
		end
		for _, childNode in pairs(node.children) do
			recurse(childNode)
		end
	end
	recurse(startNode)
	return keys
end
-- Iterative Global Search
local function _splitString(str, sep)
	local parts = {}
	local pattern = string.format("([^%s]+)", sep)
	for part in string.gmatch(str, pattern) do
		table.insert(parts, part)
	end
	return parts
end
local function _findKeysByGlobIterative(trie, pattern)
	local results = {}
	local patternParts = _splitString(pattern, "*")
	local queue = {{node = trie.root, partIndex = 1}}
	local visited = {}
	while #queue > 0 do
		local current = table.remove(queue, 1)
		local currentNode = current.node
		local currentPartIndex = current.partIndex
		if currentPartIndex > #patternParts then
			local keysFromNode = getAllKeysFromNode(currentNode)
			for _, key in ipairs(keysFromNode) do
				table.insert(results, key)
			end
			continue
		end
		local part = patternParts[currentPartIndex]
		local function traversePart(startNode, partStr)
			local node = startNode
			for i = 1, #part do
				node = node:getChild(partStr:sub(i, i))
				if not node then return nil end
			end
			return node
		end
		if currentPartIndex == 1 then
			local nextNode = traversePart(currentNode, part)
			if nextNode then
				local stateKey = tostring(nextNode) .. ":" .. (currentPartIndex + 1)
				if not visited[stateKey] then
					table.insert(queue, {node = nextNode, partIndex = currentPartIndex + 1})
					visited[stateKey] = true
				end
			end
		else
			local searchQueue = {currentNode}
			local searchedNodes = {[currentNode] = true}
			while #searchQueue > 0 do
				local nodeToSearch = table.remove(searchQueue, 1)
				local matchedNode = traversePart(nodeToSearch, part)
				if matchedNode then
					local stateKey = tostring(matchedNode)..":"..(currentPartIndex + 1)
					if not visited[stateKey] then
						table.insert(queue, {node = matchedNode, partIndex = currentPartIndex + 1})
						visited[stateKey] = true
					end
				end
				for _, childNode in pairs(nodeToSearch.children) do
					if not searchedNodes[childNode] then
						table.insert(searchQueue, childNode)
						searchedNodes[childNode] = true
					end
				end
			end
		end
	end
	return results
end

-- [[Pruning & Budgeting]]
function FullCache:_pruneByMemory(newEntrySize)
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
function FullCache:_memoryUpdate()
	local info: TypeDef.MemoryChangeInfo = {
		used = self._memoryUsage,
		budget = self._memoryBudget,
		percentUsed = (self._memoryBudget == math.huge) and 0 or (self._memoryUsage / self._memoryBudget),
	}
	self:_queueEvent(self._memorySignal, info)
end
function FullCache:_chargeRemoval(entry, section)
	local size = entry._size or 0
	if section == "array" then
		self._arrayMemoryUsage = math.max(0, self._arrayMemoryUsage - size)
	elseif section == "dict" then
		self._dictMemoryUsage  = math.max(0, self._dictMemoryUsage  - size)
	end
	self._memoryUsage = self._arrayMemoryUsage + self._dictMemoryUsage
	self:_memoryUpdate()
end
function FullCache:_addMemoryUsage(size, section)
	if section == "array" then
		self._arrayMemoryUsage += size
	elseif section == "dict" then
		self._dictMemoryUsage += size
	end
	self._memoryUsage = self._arrayMemoryUsage + self._dictMemoryUsage
	self:_memoryUpdate()
end
function FullCache:_ensureMemoryForSize(additionalSize)
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
			Debugger:Log("warn", "_ensureMemoryForSize", "Failed to free memory; no eviction candidates found.")
			return false -- Explicitly fail
		end
	end
	return true
end

function FullCache:_pause()
	self._paused = true
	self._ttl:stop()
end
function FullCache:_resume()
	self._paused = false
	self._ttl:start()
end
function FullCache:_queueEvent(signal, ...)
	table.insert(self._eventQueue, {Signal = signal, Args = {...}})
end

-- [[Internal eviction/removal]]
function FullCache:_evictArrayOne()
	if self._arrayCount == 0 then
		return false
	end
	local entry = self._array[self._arrayHead]
	while not entry and self._arrayHead < self._arrayLogicalEnd do
		self._array[self._arrayHead] = nil
		self._arrayHead += 1
		entry = self._array[self._arrayHead]
		Debugger:Log("warn", "_evictArrayOne", "Correcting for nil entry at array head.")
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
	self:_queueEvent(self._evictSignal, {kind="array", value=entry.value, expired=false})
	if self._arrayHead > 1000 and self._arrayCount < (self._arrayLogicalEnd - self._arrayHead + 1) / 2 then
		self:_compactArray()
	end
	return true
end
function FullCache:_compactArray()
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
function FullCache:_forEachArrayEntry(callback)
	if self._arrayCount == 0 then return end
	local logicalIdx = 0
	for i = self._arrayHead, self._arrayLogicalEnd do
		local entry = self._array[i]
		if entry then
			logicalIdx = logicalIdx + 1
			callback(entry, logicalIdx) 
		end
	end
end
function FullCache:_RemoveInternal(key:string, expired:boolean)
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
	if expired then
		self:_queueEvent(self._expireSignal, key, entry.value)
	end
	local eventType = expired and "EXPIRE" or "EVICT"
	local eventInfo = {
		kind = "dict", 
		key = key, 
		value = entry.value, 
		expired = expired,
	}
	self:_queueEvent(self._evictSignal, eventInfo)
	self:_fireWatchEvent({
		event = eventType,
		key = key,
		value = entry.value,
		timestamp = self:_getTime()
	})
end
function FullCache:_fireWatchEvent(eventData)
	for id, queue in pairs(self._watchers) do
		table.insert(queue, eventData)
	end
end

-- [[Policy & Serialization Internals]]
function FullCache:_setPolicy(opts)
	-- Policy selection, the only available ones are: FIFO, LRU, LFU, RR
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
			Debugger:Log("error","SetPolicy", ("unrecognized policy %q; valid options: %s")
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
		local wk = {__mode = Mode}
		setmetatable(self._array, wk)
		setmetatable(self._dict, wk)
	elseif Mode and Mode ~= "strong" then
		Debugger:Log("warn","Create", ("invalid Mode %q; supported modes: \"strong\", \"k\", \"v\", \"kv\"")
			:format(Mode))
	end
end
function FullCache:_encodeEntry(value, existingEntry)
	local entry = self:_prepareEntry(value, existingEntry)
	if not entry then return nil end
	local oldSize = existingEntry and existingEntry._size or 0
	local sizeDelta = entry._size - oldSize
	if sizeDelta > 0 then
		if not self:_ensureMemoryForSize(sizeDelta) then
			Debugger:Log("error", "_encodeEntry", "Not enough memory to store entry after pruning attempts.")
			return nil
		end
	end
	return entry
end
function FullCache:_getReadOnly(realKey)
	local entry = self._dict[realKey]
	if not entry then
		return nil
	end
	if entry.expires and self:_getTime() >= entry.expires then
		return nil
	end
	-- Decompress & Decode
	local valueToProcess = entry.value
	if entry.compressionType and type(valueToProcess) == "string" then
		local decompressor
		if entry.compressionType == "zstd" then
			decompressor = Zstd.decompress
		elseif entry.compressionType == "lz4" then
			decompressor = LZ4.decompress
		end
		if decompressor then
			local success, decompressedStr = pcall(decompressor, valueToProcess)
			if success then
				valueToProcess = decompressedStr
			else
				return nil
			end
		end
	end
	local dataFormat = entry.originalFormat or self._formatType
	local finalValue
	if dataFormat == "KELP" then
		local success, unpacked = pcall(KELP.unpack, valueToProcess)
		finalValue = success and unpacked or nil
	else -- JSON by default
		if type(valueToProcess) == "string" and (entry.compressionType or entry.originalFormat) then
			local success, decoded = pcall(HttpService.JSONDecode, HttpService, valueToProcess)
			finalValue = success and decoded or nil
		else
			finalValue = valueToProcess
		end
	end
	return finalValue
end
function FullCache:_prepareEntry(value, existingEntry)
	local format = self._formatType
	local entry = {value = value}
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
			Debugger:Log("warn", "_prepareEntry", "Custom EstimateSizeFunction failed or returned non-number. Falling back.")
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
		elseif format == "KELP" then
			success, encodedValueString = pcall(KELP.pack, value)
			if success and type(encodedValueString) == "string" then
				calculatedSize = #encodedValueString
				entry.value = encodedValueString
				entry.originalFormat = "KELP"
				local jsonSuccess, jsonEncodedStr = pcall(HttpService.JSONEncode, HttpService, value)
				if jsonSuccess then
					jsonRepresentation = jsonEncodedStr
				else
					jsonRepresentation = ""
				end
			else
				success = false
			end
		else -- Default to JSON
			success, encodedValueString = pcall(HttpService.JSONEncode, HttpService, value)
			if success and type(encodedValueString) == "string" then
				calculatedSize = #encodedValueString
				jsonRepresentation = encodedValueString
			else
				success = false
			end
		end
	end
	if success then
		entry._size = calculatedSize
		entry._json = jsonRepresentation
		if self._memoryBudget and entry._size > self._memoryBudget then
			Debugger:Log("warn", "_prepareEntry", ("Entry size (%d) exceeds total memory budget (%d).")
				:format(entry._size, self._memoryBudget))
			return nil
		end
		if self._useCompression then
			local dataToCompress
			if format == "KELP" then
				local success, packed = pcall(KELP.pack, value)
				if success then dataToCompress = packed end
			else -- Default to JSON
				local success, encoded = pcall(HttpService.JSONEncode, HttpService, value)
				if success then dataToCompress = encoded end
			end
			if dataToCompress then
				local compressor
				if self._useCompression == "zstd" then
					compressor = Zstd.compress
				elseif self._useCompression == "lz4" then
					compressor = LZ4.compress
				end
				if compressor then
					local success, result = pcall(compressor, dataToCompress)
					if success and type(result) == "string" and #result > 0 then
						entry.value = result 
						entry.compressionType = self._useCompression
						entry.originalFormat = format
						entry._size = #result
					else
						entry._size = 0
						entry._json = ""
						Debugger:Log("warn", "_prepareEntry", ("Failed to serialize or size value. Type: %s")
							:format(type(value)))
					end
				end
			end
		end
	end
	if not entry._size then
		entry._size = 0
		entry._json = ""
		Debugger:Log("warn", "_prepareEntry", ("Failed to serialize or size value. Type: %s")
			:format(type(value)))
	end
	if entry._size > self._maxEntrySizeBytes then
		Debugger:Log("warn","_prepareEntry", ("Entry for value exceeds MaxSerializedSize (%d > %d) and will be skipped.")
			:format(entry._size, self._maxEntrySizeBytes))
		return nil
	end
	return entry
end

-- [[ Multi-Threading ]
function FullCache:_executeParallel(taskItems, taskFn, workerCount)
	if type(workerCount) ~= "number" then
		Debugger:Log("error", "_executeParallel",("expected workerCount to be number, got: %q")
			:format(type(workerCount)))
	end
	local numItems = #taskItems
	if numItems < workerCount then
		workerCount = numItems
	end
	if workerCount == 0 or numItems == 0 then
		return {}
	end
	local chunks = {}
	local chunkSize = math.ceil(numItems / workerCount)
	for i = 1, workerCount do
		local startIndex = ((i - 1) * chunkSize) + 1
		local endIndex = math.min(i * chunkSize, numItems)
		if startIndex > endIndex then break end
		local chunk = {}
		for j = startIndex, endIndex do
			table.insert(chunk, taskItems[j])
		end
		table.insert(chunks, chunk)
	end
	local resultsFromWorkers = {}
	local workersCompleted = 0
	local completionSignal = Signal.new()
	for i, chunk in ipairs(chunks) do
		task.spawn(function()
			resultsFromWorkers[i] = taskFn(self, chunk)
			workersCompleted = workersCompleted + 1
			if workersCompleted == #chunks then
				completionSignal:Fire()
			end
		end)
	end
	if workersCompleted < #chunks then
		completionSignal:Wait()
	end
	return resultsFromWorkers
end

-- [[Internals]]
function FullCache:_internalSetEncoded(key, entryData)
	local realKey = normalizeKey(key)
	local existingEntry = self._dict[realKey]
	if existingEntry then
		self:_chargeRemoval(existingEntry, "dict")
	end
	self:_addMemoryUsage(entryData._size, "dict")
	self._dict[realKey] = entryData
	local evictedKey = self._policy:insert(realKey)
	if evictedKey and evictedKey ~= realKey then
		self:_RemoveInternal(evictedKey, false)
	end
	while _dictSize(self._dict) > self._maxobj do
		local victimKey = self._policy.evict and self._policy:evict()
		if victimKey then
			self:_RemoveInternal(victimKey, false)
		else
			break
		end
	end
	if self._dict[realKey] and type(realKey) == "string" then
		self._keyTrie:insert(realKey, stringToSequence(realKey), function() end)
	end
	if self._dict[realKey] then
		self:_fireWatchEvent({
			event = "SET",
			key = key,
			value = entryData.value,
			timestamp = self:_getTime()
		})
	end
end
function FullCache:_getInternal(key:string|{any}, SkipExpire:bool?):T?
	local realKey = normalizeKey(key)
	local computeFn = self._virtuals[realKey]
	if computeFn then
		self._virtuals[realKey] = nil
		local success, value = pcall(computeFn)
		if not success then
			Debugger:Log("error", "Get", ("Virtual computeFn for key %q failed: %s")
				:format(tostring(key), tostring(value)))
			return nil
		end
		self:_setInternal(key, value)
		return value
	end
	if SkipExpire ~= true and not self._paused then
		self._ttl:_expireLoop()
	end
	local finalValue = self:_getReadOnly(realKey)
	if finalValue ~= nil then
		self._metrics.hits += 1
		self:_queueEvent(self._hitSignal, realKey, finalValue)
		self._policy:access(realKey)

		local entry = self._dict[realKey]
		if entry and entry.expires and self._ttlMode == "sliding" then
			local originalTTL = self._ttl:getOriginalTTL(realKey)
			if originalTTL then
				local newExpires = self:_getTime() + originalTTL
				entry.expires = newExpires
				self._ttl:push(realKey, newExpires)
			end
		end
	else
		self._metrics.misses += 1
		self:_queueEvent(self._missSignal, realKey)
	end
	return finalValue
end
function FullCache:_setInternal(key, value)
	local realKey = normalizeKey(key)
	local existingEntry = self._dict[realKey]
	local entry = self:_encodeEntry(value, existingEntry)
	if not entry then
		Debugger:Log("warn", "Set", "Failed to encode entry or not enough memory after pruning attempts.")
		return
	end
	if entry._size > self._memoryBudget then
		Debugger:Log("warn", "Set", ("Entry for key '%s' is larger (%d bytes) than the total cache budget (%d bytes) and cannot be stored.")
			:format(tostring(key), entry._size, self._memoryBudget))
		return
	end
	--[[
	if not self._paused then 
		self._ttl:_expireLoop()
	end
	]]
	if existingEntry then
		self:_chargeRemoval(existingEntry, "dict")
	end
	self:_addMemoryUsage(entry._size, "dict")
	self._dict[realKey] = entry
	local evictedKey = self._policy:insert(realKey)
	if evictedKey and evictedKey ~= realKey then
		self:_RemoveInternal(evictedKey, false)
	end
	while _dictSize(self._dict) > self._maxobj do
		local victimKey = self._policy.evict and self._policy:evict()
		if victimKey then
			self:_RemoveInternal(victimKey, false)
		else
			break
		end
	end
	if self._dict[realKey] and type(realKey) == "string" then
		self._keyTrie:insert(realKey, stringToSequence(realKey), function() end)
	end
	self:_memoryUpdate()
	if self._dict[realKey] then
		self:_fireWatchEvent({
			event = "SET", 
			key = key, 
			value = value, 
			timestamp = self:_getTime()
		})
	end
	return value
end
function FullCache:_setWithTTLInternal(key, value, ttl)
	local realKey = normalizeKey(key)
	local existingEntry = self._dict[realKey]
	if existingEntry then
		self:_chargeRemoval(existingEntry, "dict")
	end
	local entry = self:_encodeEntry(value)
	entry.expires = self:_getTime() + ttl
	self._dict[realKey] = entry
	self:_addMemoryUsage(entry._size, "dict")
	self._ttl:push(realKey, entry.expires)
	self._ttl:setOriginalTTL(realKey, ttl)
	local evicted = self._policy:insert(realKey)
	if evicted and evicted ~= realKey then 
		self:_RemoveInternal(evicted, false)
	end
	if self._dict[realKey] and type(realKey) == "string" then
		self._keyTrie:insert(realKey, stringToSequence(realKey), function() end)
	end
	self:_memoryUpdate()
	return value
end

------------------------------------------------------------------------------------------------------------

-- Main Logic ----------------------------------------------------------------------------------------------

function FullCache.Create<T>(CacheName:string, MaxObjects:number?, Opts:CreateOpts?):FullCache<T>
	createMutex:lock()
	local success, result = pcall(function()
		-- Asserts are slow...
		if typeof(CacheName) ~= "string" then
			Debugger:Log("error","Create", ("invalid CacheName (%s); expected a string")
				:format(typeof(CacheName)))
		end
		if MaxObjects and typeof(MaxObjects) ~= "number" then
			Debugger:Log("error","Create", ("invalid MaxObjects (%s); expected a positive integer")
				:format(tostring(MaxObjects)))
		end
		-- Return to default settings if these are nil
		local opts = Opts or {}
		local maxObjs = MaxObjects or DefaultMax
		local memoryBudget = opts.MemoryBudget or DefaultMemoryBudget
		local serializedSizeBudget = opts.MaxSerializedSize or DefaultSerializedSize
		local useCompression = opts.UseCompression and string.lower(opts.UseCompression)
		local ttlFilter = opts.TTLFilter and string.lower(opts.TTLFilter)
		local ttlMode = opts.TTLMode and string.lower(opts.TTLMode)
		local ttlUseClock = opts.TTLUseClock or false
		local estimateSizeFn = opts.EstimateSizeFunction
		local readOnly = opts.ReadOnly or false
		local ttlCapacity = opts.TTLCapacity

		-- Serialization mode (JSON or KELP)
		local FormatType = DefaultFormat
		if opts.FormatType and typeof(opts.FormatType) == "string" then
			FormatType = string.upper(opts.FormatType)
			if FormatType ~= DefaultFormat 
				and FormatType ~= "JSON" 
				and FormatType ~= "KELP" 
			then
				Debugger:Log("warn","Create", ("expected valid format, got: %s \nUsing JSON as fallback...")
					:format(FormatType))
				FormatType = DefaultFormat
			end
		elseif opts.FormatType then
			Debugger:Log("warn","Create", ("expected FormatType to be string, got: %s \nUsing JSON as fallback...")
				:format(typeof(opts.FormatType)))
		end

		-- Make sure that it's not already registered
		if Cache[CacheName] then
			local cache = Cache[CacheName]
			cache._useCompression = useCompression
			cache._formatType = FormatType
			cache._ttlMode = ttlMode
			cache._ttlUseClock = ttlUseClock
			cache._ttlCapacity = ttlCapacity
			cache._ttlFilter = ttlFilter
			cache._ttl:stop()
			cache._ttl = TTL.new(cache, cache._ttlCapacity, cache._ttlFilter)
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
			cache._memoryBudget = memoryBudget
			cache._estimateSizeFn = estimateSizeFn
			cache._metrics = {
				hits = 0,
				misses = 0,
				evictions = 0,
				startTime = cache:_getTime(),
			}
			-- Reset memory counters
			cache._arrayMemoryUsage = 0
			cache._dictMemoryUsage  = 0
			-- Enforce the new memory budget immediately
			if cache._memoryUsage > cache._memoryBudget then
				cache:_pruneByMemory(0)
			end
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
			return cache::FullCache
		end

		-- Create new cache
		local self = setmetatable({
			_name  = CacheName,
			_paused = false,
			_eventQueue = {},
			_mutex = Mutex.new(),
			-- Array
			_array = {},
			_arrayHead = 1,
			_arrayLogicalEnd = 0,
			_arrayCount = 0,
			-- Dictionary
			_dict = {},
			_virtuals = {},
			_loading = {},
			_loadSignals = {},
			-- Memory
			_maxEntrySizeBytes = serializedSizeBudget,
			_estimateSizeFn = estimateSizeFn,
			_useCompression = useCompression,
			_memoryBudget = memoryBudget,
			_memoryUsage = 0,
			_maxobj = maxObjs,
			_formatType = FormatType,
			-- TTL
			_ttlCapacity = ttlCapacity,
			_ttlFilter = ttlFilter,
			_ttlMode = ttlMode,
			_ttlUseClock = ttlUseClock,
			_keyTrie = Trie.new(),
			_watchers = {},
			-- Signalis
			_watchSignal = Signal.new(),
			_evictSignal = Signal.new(),
			_memorySignal = Signal.new(),
			_hitSignal = Signal.new(),
			_missSignal = Signal.new(),
			_expireSignal = Signal.new(),
		}, FullCache)
		Cache[CacheName] = self
		-- Metrics for tryhards
		self._metrics = {
			hits = 0,
			misses = 0,
			evictions = 0,
			startTime = self:_getTime(),
		}
		-- Sectionized memory counters
		self._arrayMemoryUsage = 0
		self._dictMemoryUsage = 0	
		-- Initiate policy and TTL cleaning service
		self._ttl = TTL.new(self, self._ttlCapacity, self._ttlFilter)
		self:_setPolicy(opts)
		self._ttl:start()
		-- Check if readOnly
		if readOnly == true then
			self:ReadOnly(true)
		elseif type(readOnly) ~= "boolean" then
			Debugger:Log("warn", "FullCache", ("Invalid 'readOnly' argument, expected boolean, got: %q")
				:format(type(readOnly)))
		end
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
	createMutex:unlock()
	if not success then
		Debugger:Log("error", "Create", ("Internal failure: %s\n%s")
			:format(tostring(result), debug.traceback(nil, 2)))
		return nil
	end
	return result
end

function FullCache:Destroy()
	if self._destroyed then
		Debugger:Log("error", "Destroy", "Attempt to use a destroyed cache instance.")
		return nil
	end
	self._mutex:lock()
	local success, result = pcall(function()
		self._readOnly = true
		self._destroyed = true
		self._ttl:stop()
		local allKeys = {}
		for k in pairs(self._dict) do 
			table.insert(allKeys, k) 
		end
		for k in pairs(self._virtuals) do 
			table.insert(allKeys, k) 
		end
		for k in pairs(self._loading) do 
			table.insert(allKeys, k) 
		end
		for _, internalID in ipairs(allKeys) do
			if idToTable[internalID] then
				tableIDs[idToTable[internalID]] = nil
				idToTable[internalID] = nil
			end
		end
		self._evictSignal:DisconnectAll()
		self._memorySignal:DisconnectAll()
		self._hitSignal:DisconnectAll()
		self._missSignal:DisconnectAll()
		self._expireSignal:DisconnectAll()
		self._watchSignal:DisconnectAll()
		Cache[self._name] = nil
		self._array = nil
		self._dict = nil
		self._virtuals = nil
		self._keyTrie = nil
		self._policy = nil
		self._watchers = nil
		self._metrics = nil
	end)
	local eventsToFire
	if #self._eventQueue > 0 then
		eventsToFire = self._eventQueue
		self._eventQueue = {}
	end
	self._mutex:unlock()
	if success then
		setmetatable(self, nil)
	end
	if eventsToFire then
		for _, event in ipairs(eventsToFire) do
			pcall(event.Signal.Fire, event.Signal, unpack(event.Args))
		end
	end
	if not success then
		Debugger:Log("error", "Destroy", ("Internal failure: %s\n%s")
			:format(tostring(result), debug.traceback(nil, 2)))
		return nil
	end
	return result
end

function FullCache:InsertSingle<T>(item:T):T
	if self._destroyed then
		Debugger:Log("error", "InsertSingle", "Attempt to use a destroyed cache instance.")
		return nil
	end
	if self._readOnly then
		Debugger:Log("warn", "InsertSingle", "Cache is in read-only mode; operation ignored.")
		return
	end
	self._mutex:lock()
	local success, result = pcall(function()
		if self._arrayCount >= self._maxobj then
			self:_evictArrayOne()
		end
		local entry = self:_encodeEntry(item) 
		if not entry then
			Debugger:Log("error", "InsertSingle", "Failed to encode or secure memory for item.")
		end
		self._arrayLogicalEnd += 1
		self._array[self._arrayLogicalEnd] = entry
		self._arrayCount += 1
		self:_addMemoryUsage(entry._size, "array")
		return item
	end)
	local eventsToFire
	if #self._eventQueue > 0 then
		eventsToFire = self._eventQueue
		self._eventQueue = {}
	end
	self._mutex:unlock()
	if eventsToFire then
		for _, event in ipairs(eventsToFire) do
			pcall(event.Signal.Fire, event.Signal, unpack(event.Args))
		end
	end
	if not success then
		Debugger:Log("error", "InsertSingle", ("Internal failure: %s\n%s")
			:format(tostring(result), debug.traceback(nil, 2)))
		return nil
	end
	return result
end

function FullCache:InsertBatch(items:{T}):{T}
	if self._destroyed then
		Debugger:Log("error", "InsertBatch", "Attempt to use a destroyed cache instance.")
		return nil
	end
	if self._readOnly then
		Debugger:Log("warn", "InsertBatch", "Cache is in read-only mode; operation ignored.")
		return
	end
	self._mutex:lock()
	local success, result = pcall(function()
		if #items == 0 then return {} end
		self:_pause()
		local preparedEntries = {}
		local totalNewSize = 0
		local successfulItems = {}
		for _, itemValue in ipairs(items) do
			local entry = self:_prepareEntry(itemValue)
			if entry and entry._size <= self._maxEntrySizeBytes then
				table.insert(preparedEntries, entry)
				totalNewSize += entry._size
				table.insert(successfulItems, itemValue)
			else
				Debugger:Log("warn", "InsertBatch", ("Item skipped: too large or failed to prepare. Value: %s")
					:format(tostring(itemValue)))
			end
		end
		if #preparedEntries == 0 then
			self:_resume()
			return {}
		end
		local numCanAddBeforeMaxObj = self._maxobj - self._arrayCount
		local numToEvictForMaxObj = #preparedEntries - numCanAddBeforeMaxObj
		if numToEvictForMaxObj > 0 then
			for _ = 1, numToEvictForMaxObj do
				if self._arrayCount == 0 then break end
				self:_evictArrayOne()
			end
		end
		if not self:_ensureMemoryForSize(totalNewSize) then
			self:_resume()
			Debugger:Log("error", "InsertBatch", "Not enough memory for batch after pruning attempts. Batch aborted.")
			return {}
		end
		for _, entryData in ipairs(preparedEntries) do
			self._arrayLogicalEnd += 1
			self._array[self._arrayLogicalEnd] = entryData
			self._arrayCount += 1
			self:_addMemoryUsage(entryData._size, "array")
		end
		self:_resume()
		return successfulItems
	end)
	local eventsToFire
	if #self._eventQueue > 0 then
		eventsToFire = self._eventQueue
		self._eventQueue = {}
	end
	self._mutex:unlock()
	if eventsToFire then
		for _, event in ipairs(eventsToFire) do
			pcall(event.Signal.Fire, event.Signal, unpack(event.Args))
		end
	end
	if not success then
		Debugger:Log("error", "InsertBatch", ("Internal failure: %s\n%s")
			:format(tostring(result), debug.traceback(nil, 2)))
		return nil
	end
	return result
end

function FullCache:Cleanup():()
	if self._readOnly then
		Debugger:Log("warn", "Cleanup", "Cache is in read-only mode; operation ignored.")
		return
	end
	self._mutex:lock()
	local success, result = pcall(function()
		self:_compactArray()
	end)
	local eventsToFire
	if #self._eventQueue > 0 then
		eventsToFire = self._eventQueue
		self._eventQueue = {}
	end
	self._mutex:unlock()
	if eventsToFire then
		for _, event in ipairs(eventsToFire) do
			pcall(event.Signal.Fire, event.Signal, unpack(event.Args))
		end
	end
	if not success then
		Debugger:Log("error", "Cleanup", ("Internal failure: %s\n%s")
			:format(tostring(result), debug.traceback(nil, 2)))
		return nil
	end
	return result
end

function FullCache:SetMetadata(key:string|{any}, data:object):boolean
	if self._readOnly then
		Debugger:Log("warn", "SetMetadata", "Cache is in read-only mode; operation ignored.")
		return false
	end
	self._mutex:lock()
	local success, result = pcall(function()
		if type(data) ~= "table" then
			Debugger:Log("error", "SetMetadata", ("Expected data to be a table, got: %s")
				:format(type(data)))
			return false
		end
		local realKey = normalizeKey(key)
		local entry = self._dict[realKey]
		if not entry then
			return false
		end
		local oldMetaSize = 0
		if entry._metadata then
			local _, oldJson = pcall(HttpService.JSONEncode, HttpService, entry._metadata)
			oldMetaSize = oldJson and #oldJson or 0
		end
		local success, newJson = pcall(HttpService.JSONEncode, HttpService, data)
		if not success then
			Debugger:Log("error", "SetMetadata", ("Failed to serialize metadata to JSON: %s")
				:format(tostring(newJson)))
			return false
		end
		local newMetaSize = #newJson
		local sizeDelta = newMetaSize - oldMetaSize
		if sizeDelta > 0 then
			if not self:_ensureMemoryForSize(sizeDelta) then
				Debugger:Log("warn", "SetMetadata", "Not enough memory to set metadata after pruning attempts.")
				return false
			end
		end
		entry._metadata = _deepClone(data)
		entry._size = (entry._size or 0) + sizeDelta
		self._dictMemoryUsage = self._dictMemoryUsage + sizeDelta
		self._memoryUsage = self._arrayMemoryUsage + self._dictMemoryUsage
		self:_memoryUpdate()
		return true
	end)
	local eventsToFire
	if #self._eventQueue > 0 then
		eventsToFire = self._eventQueue
		self._eventQueue = {}
	end
	self._mutex:unlock()
	if eventsToFire then
		for _, event in ipairs(eventsToFire) do
			pcall(event.Signal.Fire, event.Signal, unpack(event.Args))
		end
	end
	if not success then
		Debugger:Log("error", "SetMetadata", ("Internal failure: %s\n%s")
			:format(tostring(result), debug.traceback(nil, 2)))
		return nil
	end
	return result
end

function FullCache:GetMetadata(key:string|{any}):object?
	local realKey = normalizeKey(key)
	local entry = self._dict[realKey]
	if entry and entry._metadata then
		return _deepClone(entry._metadata)
	end
	Debugger:Log("warn", "GetMetaData", ("%q metadata does not exist.")
		:format(key))
	return nil
end
------------------------------------------------------------------------------------------------------------

-- Key Access (Map Methods) --------------------------------------------------------------------------------

function FullCache:Set(key:string|{any}, value:T):T
	if self._destroyed then
		Debugger:Log("error", "Set", "Attempt to use a destroyed cache instance.")
	end
	if self._readOnly then
		Debugger:Log("warn", "Set", "Cache is in read-only mode; operation ignored.")
		return
	end
	self._mutex:lock()
	local eventsToFire
	local success, result = pcall(self._setInternal, self, key, value)
	local eventsToFire
	if #self._eventQueue > 0 then
		eventsToFire = self._eventQueue
		self._eventQueue = {}
	end
	self._mutex:unlock()
	if eventsToFire then
		for _, event in ipairs(eventsToFire) do
			pcall(event.Signal.Fire, event.Signal, unpack(event.Args))
		end
	end
	if not success then
		Debugger:Log("error", "Set", ("Internal cache operation failed.\nKey: %s\nValue: %s\nError: %s")
			:format(tostring(key), tostring(value), tostring(result)))
		return nil
	end
	return result
end

function FullCache:Update(key: string|{any}, updaterFn: (currentValue: T) -> T)
	if self._destroyed then
		Debugger:Log("error", "Update", "Attempt to use a destroyed cache instance.")
		return
	end
	if self._readOnly then
		Debugger:Log("warn", "Update", "Cache is in read-only mode; operation ignored.")
		return
	end
	self._mutex:lock()
	local eventsToFire
	local success, result = pcall(function()
		local realKey = normalizeKey(key)
		local currentValue = self:_getInternal(realKey, true)
		local newValue = updaterFn(currentValue)
		if newValue ~= nil then
			self:_setInternal(realKey, newValue)
		else
			self:_RemoveInternal(realKey, false)
		end
		return newValue
	end)
	local eventsToFire
	if #self._eventQueue > 0 then
		eventsToFire = self._eventQueue
		self._eventQueue = {}
	end
	self._mutex:unlock()
	if eventsToFire then
		for _, event in ipairs(eventsToFire) do
			pcall(event.Signal.Fire, event.Signal, unpack(event.Args))
		end
	end
	if not success then
		Debugger:Log("error", "Update", ("Internal failure: %s\n%s")
			:format(tostring(result), debug.traceback(nil, 2)))
		return nil
	end
	return result
end

function FullCache:Pin(key:string|{any}): boolean
	if self._destroyed then
		Debugger:Log("error", "Pin", "Attempt to use a destroyed cache instance.")
		return nil
	end
	self._mutex:lock()
	local success, result = pcall(function()
		if self._readOnly then
			Debugger:Log("warn", "Pin", "Cache is in read-only mode; operation ignored.")
			return
		end
		local realKey = normalizeKey(key)
		local entry = self._dict[realKey]
		if not entry or entry.pinned then
			return false
		end
		entry.pinned = true
		if self._policy.remove then
			self._policy:remove(realKey)
		end
		return true
	end)
	local eventsToFire
	if #self._eventQueue > 0 then
		eventsToFire = self._eventQueue
		self._eventQueue = {}
	end
	self._mutex:unlock()
	if eventsToFire then
		for _, event in ipairs(eventsToFire) do
			pcall(event.Signal.Fire, event.Signal, unpack(event.Args))
		end
	end
	if not success then
		Debugger:Log("error", "Pin", ("Internal failure: %s\n%s")
			:format(tostring(result), debug.traceback(nil, 2)))
		return nil
	end
	return result
end

function FullCache:Unpin(key:string|{any}): boolean
	if self._readOnly then
		Debugger:Log("warn", "Unpin", "Cache is in read-only mode; operation ignored.")
		return
	end
	self._mutex:lock()
	local success, result = pcall(function()
		local realKey = normalizeKey(key)
		local entry = self._dict[realKey]
		if not entry or not entry.pinned then
			return false
		end
		entry.pinned = false
		if self._policy.insert then
			self._policy:insert(realKey)
		end
	end)
	local eventsToFire
	if #self._eventQueue > 0 then
		eventsToFire = self._eventQueue
		self._eventQueue = {}
	end
	self._mutex:unlock()
	if eventsToFire then
		for _, event in ipairs(eventsToFire) do
			pcall(event.Signal.Fire, event.Signal, unpack(event.Args))
		end
	end
	if not success then
		Debugger:Log("error", "Unpin", ("Internal failure: %s\n%s")
			:format(tostring(result), debug.traceback(nil, 2)))
		return nil
	end
	return result
end

function FullCache:Get(key:string|{any}, SkipExpire:bool?):T?
	if self._destroyed then
		Debugger:Log("error", "Get", "Attempt to use a destroyed cache instance.")
		return nil
	end
	self._mutex:lock()
	local eventsToFire
	local success, result = pcall(function()
		return self:_getInternal(key, SkipExpire)
	end)
	local eventsToFire
	if #self._eventQueue > 0 then
		eventsToFire = self._eventQueue
		self._eventQueue = {}
	end
	self._mutex:unlock()
	if eventsToFire then
		for _, event in ipairs(eventsToFire) do
			pcall(event.Signal.Fire, event.Signal, unpack(event.Args))
		end
	end
	if not success then
		Debugger:Log("error", "Get", ("Internal failure: %s\n%s")
			:format(tostring(result), debug.traceback(nil, 2)))
		return nil
	end
	return result
end

function FullCache:GetOrLoad(key:string|{any}, loader:()->T, ttl: number?)
	if self._destroyed then
		Debugger:Log("error", "GetOrLoad", "Attempt to use a destroyed cache instance.")
		return nil
	end
	self._mutex:lock()
	local existing = self:_getInternal(key)
	if existing ~= nil then
		self._mutex:unlock()
		return existing
	end
	local realKey = normalizeKey(key)
	if self._loading[realKey] then
		local loadSignal = self._loadSignals[realKey]
		self._mutex:unlock()
		if loadSignal then
			loadSignal:Wait()
		end
		return self:Get(key)
	end
	self._loading[realKey] = true
	local loadSignal = Signal.new()
	self._loadSignals[realKey] = loadSignal
	self._mutex:unlock()
	local success, res = pcall(loader, key)
	self._mutex:lock()
	if success then
		if ttl then
			self:_setWithTTLInternal(key, res, ttl)
		else
			self:_setInternal(key, res)
		end
	else
		Debugger:Log("error", "GetOrLoad", ("loader() threw: %s\n→ Check that your loader always returns a value, key: %q")
			:format(res, key))
		res = nil
	end
	self._loading[realKey] = nil
	self._loadSignals[realKey] = nil
	local eventsToFire
	local eventsToFire
	if #self._eventQueue > 0 then
		eventsToFire = self._eventQueue
		self._eventQueue = {}
	end
	self._mutex:unlock()
	loadSignal:Fire()
	loadSignal:DisconnectAll()
	if eventsToFire then
		for _, event in ipairs(eventsToFire) do
			pcall(event.Signal.Fire, event.Signal, unpack(event.Args))
		end
	end
	return res
end

function FullCache:Prefetch(key:string|{any}, loader:()->T, ttl:number?)
	if self._destroyed then
		Debugger:Log("error", "Prefetch", "Attempt to use a destroyed cache instance.")
		return nil
	end
	if self:Has(key) then
		return
	end
	task.spawn(function()
		if self:Has(key) then
			return
		end
		local success, result = pcall(loader, key)
		if not success then
			Debugger:Log("error", "Prefetch", ("loader() threw: %s\n→ Check that your loader always returns a value, key: %q")
				:format(result, key))
			return
		end
		if ttl and type(ttl) == "number" and ttl > 0 then
			self:SetWithTTL(key, result, ttl)
		else
			self:Set(key, result)
		end
	end)
end

function FullCache:DefineVirtual(key:string|{any}, computeFn:()->T)
	if self._destroyed then
		Debugger:Log("error", "DefineVirtual", "Attempt to use a destroyed cache instance.")
		return nil
	end
	if self._readOnly then
		Debugger:Log("warn", "DefineVirtual", "Cache is in read-only mode; operation ignored.")
		return
	end
	self._mutex:lock()
	local success, result = pcall(function()
		if type(computeFn) ~= "function" then
			Debugger:Log("error", "DefineVirtual", ("expected computeFn to be a function, got: %s")
				:format(type(computeFn)))
			return
		end
		local realKey = normalizeKey(key)
		if self._dict[realKey] or self._virtuals[realKey] then
			Debugger:Log("warn", "DefineVirtual", ("Key %q already exists in the cache or as a virtual key. Definition ignored.")
				:format(tostring(key)))
			return
		end
		self._virtuals[realKey] = computeFn
	end)
	local eventsToFire
	if #self._eventQueue > 0 then
		eventsToFire = self._eventQueue
		self._eventQueue = {}
	end
	self._mutex:unlock()
	if eventsToFire then
		for _, event in ipairs(eventsToFire) do
			pcall(event.Signal.Fire, event.Signal, unpack(event.Args))
		end
	end
	if not success then
		Debugger:Log("error", "DefineVirtual", ("Internal failure: %s\n%s")
			:format(tostring(result), debug.traceback(nil, 2)))
		return nil
	end
	return result
end

function FullCache:Has(key:string|{any}):boolean
	if self._destroyed then
		Debugger:Log("error", "Has", "Attempt to use a destroyed cache instance.")
		return nil
	end
	self._mutex:lock()
	local success, result = pcall(function()
		if not self._paused then 
			self._ttl:_expireLoop()
		end
		local realKey = normalizeKey(key)
		return self._dict[realKey] ~= nil 
			or self._virtuals[realKey] ~= nil
	end)
	local eventsToFire
	if #self._eventQueue > 0 then
		eventsToFire = self._eventQueue
		self._eventQueue = {}
	end
	self._mutex:unlock()
	if eventsToFire then
		for _, event in ipairs(eventsToFire) do
			pcall(event.Signal.Fire, event.Signal, unpack(event.Args))
		end
	end
	if not success then
		Debugger:Log("error", "Has", ("Internal failure: %s\n%s")
			:format(tostring(result), debug.traceback(nil, 2)))
		return nil
	end
	return result
end

function FullCache:Remove(key:string|{any}):()
	if self._destroyed then
		Debugger:Log("error", "Remove", "Attempt to use a destroyed cache instance.")
		return nil
	end
	if self._readOnly then
		Debugger:Log("warn", "Remove", "Cache is in read-only mode; operation ignored.")
		return
	end
	self._mutex:lock()
	local success, result = pcall(function()
		if not self._paused then 
			self._ttl:_expireLoop()
		end
		local realKey = normalizeKey(key)
		local entry = self._dict[realKey]
		if entry then
			self:_fireWatchEvent({
				event = "REMOVE", 
				key = key, 
				value = entry.value, 
				timestamp = self:_getTime()
			})
		end
		if self._virtuals[realKey] then
			self._virtuals[realKey] = nil
		end
		self:_RemoveInternal(realKey, false)
	end)
	local eventsToFire
	if #self._eventQueue > 0 then
		eventsToFire = self._eventQueue
		self._eventQueue = {}
	end
	self._mutex:unlock()
	if eventsToFire then
		for _, event in ipairs(eventsToFire) do
			pcall(event.Signal.Fire, event.Signal, unpack(event.Args))
		end
	end
	if not success then
		Debugger:Log("error", "Remove", ("Internal failure: %s\n%s")
			:format(tostring(result), debug.traceback(nil, 2)))
		return nil
	end
	return result
end

function FullCache:Size(): number
	if self._destroyed then
		Debugger:Log("error", "Size", "Attempt to use a destroyed cache instance.")
		return nil
	end
	self._mutex:lock()
	local success, result = pcall(function()
		if not self._paused then 
			self._ttl:_expireLoop()
		end
		return self._arrayCount + _dictSize(self._dict)
	end)
	local eventsToFire
	if #self._eventQueue > 0 then
		eventsToFire = self._eventQueue
		self._eventQueue = {}
	end
	self._mutex:unlock()
	if eventsToFire then
		for _, event in ipairs(eventsToFire) do
			pcall(event.Signal.Fire, event.Signal, unpack(event.Args))
		end
	end
	if not success then
		Debugger:Log("error", "Size", ("Internal failure: %s\n%s")
			:format(tostring(result), debug.traceback(nil, 2)))
		return nil
	end
	return result
end

function FullCache:Clear():()
	if self._destroyed then
		Debugger:Log("error", "Clear", "Attempt to use a destroyed cache instance.")
		return nil
	end
	if self._readOnly then
		Debugger:Log("warn", "Clear", "Cache is in read-only mode; operation ignored.")
		return
	end
	self._mutex:lock()
	local success, result = pcall(function()
		self._dict, self._array = {}, {}
		self._virtuals = {}
		self._watchers = {}
		self._arrayHead = 1
		self._arrayLogicalEnd = 0
		self._arrayCount = 0
		self._ttl:stop()
		self._memoryUsage = 0
		self._arrayMemoryUsage = 0
		self._dictMemoryUsage = 0
		self._metrics = {
			hits = 0,
			misses = 0,
			evictions = 0,
			startTime = self:_getTime(),
		}
		self._watchSignal = Signal.new()
		self._evictSignal = Signal.new()
		self._memorySignal = Signal.new()
		self._hitSignal  = Signal.new()
		self._missSignal = Signal.new()
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
		self._ttl = TTL.new(self, self._ttlCapacity, self._ttlFilter)
		self._ttl:start()
	end)
	local eventsToFire
	if #self._eventQueue > 0 then
		eventsToFire = self._eventQueue
		self._eventQueue = {}
	end
	self._mutex:unlock()
	if eventsToFire then
		for _, event in ipairs(eventsToFire) do
			pcall(event.Signal.Fire, event.Signal, unpack(event.Args))
		end
	end
	if not success then
		Debugger:Log("error", "Clear", ("Internal failure: %s\n%s")
			:format(tostring(result), debug.traceback(nil, 2)))
		return nil
	end
	return result
end

function FullCache:GetAll():{T}
	if self._destroyed then
		Debugger:Log("error", "GetAll", "Attempt to use a destroyed cache instance.")
		return nil
	end
	self._mutex:lock()
	local success, result = pcall(function()
		if not self._paused then 
			self._ttl:_expireLoop()
		end
		local res = {}
		self:_forEachArrayEntry(function(entry, logicalIdx)
			table.insert(res, entry.value)
		end)
		for _, entryInDict in pairs(self._dict) do
			table.insert(res, entryInDict.value)
		end
		return res
	end)
	local eventsToFire
	if #self._eventQueue > 0 then
		eventsToFire = self._eventQueue
		self._eventQueue = {}
	end
	self._mutex:unlock()
	if eventsToFire then
		for _, event in ipairs(eventsToFire) do
			pcall(event.Signal.Fire, event.Signal, unpack(event.Args))
		end
	end
	if not success then
		Debugger:Log("error", "GetAll", ("Internal failure: %s\n%s")
			:format(tostring(result), debug.traceback(nil, 2)))
		return nil
	end
	return result
end

function FullCache:ReadOnly(state:boolean)
	if self._destroyed then
		Debugger:Log("error", "ReadOnly", "Attempt to use a destroyed cache instance.")
		return nil
	end
	self._mutex:lock()
	local success, result = pcall(function()
		if type(state) == "boolean" then
			if state == true then
				self._readOnly = true
				self._ttl:stop()
			else
				self._readOnly = false
				self._ttl:start()
			end
		else
			Debugger:Log("error", "ReadOnly", ("Expected state to be a boolean value, got type: %q")
				:format(type(state)))
		end
	end)
	local eventsToFire
	if #self._eventQueue > 0 then
		eventsToFire = self._eventQueue
		self._eventQueue = {}
	end
	self._mutex:unlock()
	if eventsToFire then
		for _, event in ipairs(eventsToFire) do
			pcall(event.Signal.Fire, event.Signal, unpack(event.Args))
		end
	end
	if not success then
		Debugger:Log("error", "ReadOnly", ("Internal failure: %s\n%s")
			:format(tostring(result), debug.traceback(nil, 2)))
		return nil
	end
	return result
end

function FullCache:Pause()
	if self._destroyed then
		Debugger:Log("error", "Pause", "Attempt to use a destroyed cache instance.")
		return nil
	end
	if self._readOnly then
		Debugger:Log("warn", "Pause", "Cache is in read-only mode; operation ignored.")
		return
	end
	self._mutex:lock()
	local success, result = pcall(function()
		self:_pause()
	end)
	local eventsToFire
	if #self._eventQueue > 0 then
		eventsToFire = self._eventQueue
		self._eventQueue = {}
	end
	self._mutex:unlock()
	if eventsToFire then
		for _, event in ipairs(eventsToFire) do
			pcall(event.Signal.Fire, event.Signal, unpack(event.Args))
		end
	end
	if not success then
		Debugger:Log("error", "Pause", ("Internal failure: %s\n%s")
			:format(tostring(result), debug.traceback(nil, 2)))
		return nil
	end
	return result
end

function FullCache:Resume()
	if self._destroyed then
		Debugger:Log("error", "Resume", "Attempt to use a destroyed cache instance.")
		return nil
	end
	if self._readOnly then
		Debugger:Log("warn", "Resume", "Cache is in read-only mode; operation ignored.")
		return
	end
	self._mutex:lock()
	local success, result = pcall(function()
		self:_resume()
	end)
	local eventsToFire
	if #self._eventQueue > 0 then
		eventsToFire = self._eventQueue
		self._eventQueue = {}
	end
	self._mutex:unlock()
	if eventsToFire then
		for _, event in ipairs(eventsToFire) do
			pcall(event.Signal.Fire, event.Signal, unpack(event.Args))
		end
	end
	if not success then
		Debugger:Log("error", "Resume", ("Internal failure: %s\n%s")
			:format(tostring(result), debug.traceback(nil, 2)))
		return nil
	end
	return result
end

-- [[FORMAT]]

function FullCache:ToJSON(format:string?): string
	if self._destroyed then
		Debugger:Log("error", "ToJSON", "Attempt to use a destroyed cache instance.")
		return nil
	end
	format = format and string.upper(format) or self._formatType
	local snapshotForSerialization = self:Snapshot("auto")
	if format == "JSON" then
		return HttpService:JSONEncode(snapshotForSerialization)
	elseif format == "KELP" then
		return KELP.pack(snapshotForSerialization)
	else
		Debugger:Log("error","ToJSON", ("unknown format %q; expected 'JSON' or 'KELP'")
			:format(format))
	end
end

function FullCache:FromJSON(String:string, format:string?)
	if self._destroyed then
		Debugger:Log("error", "FromJSON", "Attempt to use a destroyed cache instance.")
		return nil
	end
	if self._readOnly then
		Debugger:Log("warn", "FromJSON", "Cache is in read-only mode; operation ignored.")
		return
	end
	if not String then
		Debugger:Log("error","FromJSON", "expected serialized string, got: nil")
	end
	local Format = format or self._formatType
	if Format == "JSON" then
		self:Restore(HttpService:JSONDecode(String))
	elseif Format == "KELP" then
		self:Restore(KELP.unpack(String))
	end
end

--[[TTL]]

function FullCache:SetWithTTL(key:string|{any}, value:T, ttl:number):T
	if self._destroyed then
		Debugger:Log("error", "SetWithTTL", "Attempt to use a destroyed cache instance.")
		return nil
	end
	if self._readOnly then
		Debugger:Log("warn", "SetWithTTL", "Cache is in read-only mode; operation ignored.")
		return
	end
	self._mutex:lock()
	local eventsToFire
	local success, result = pcall(self._setWithTTLInternal, self, key, value, ttl)
	local eventsToFire
	if #self._eventQueue > 0 then
		eventsToFire = self._eventQueue
		self._eventQueue = {}
	end
	self._mutex:unlock()
	if eventsToFire then
		for _, event in ipairs(eventsToFire) do
			pcall(event.Signal.Fire, event.Signal, unpack(event.Args))
		end
	end
	if not success then
		Debugger:Log("error", "SetWithTTL", ("Internal failure: %s\n%s")
			:format(tostring(result), debug.traceback(nil, 2)))
		return nil
	end
	return result
end

function FullCache:TTLRemaining(key):number?
	if self._destroyed then
		Debugger:Log("error", "TTLRemaining", "Attempt to use a destroyed cache instance.")
		return nil
	end
	local realKey = normalizeKey(key)
	local entry = self._dict[realKey]
	if entry and entry.expires then
		return math.max(0, entry.expires - self:_getTime())
	end
	return nil
end

function FullCache:RefreshTTL(key, extraSeconds)
	if self._destroyed then
		Debugger:Log("error", "RefreshTTL", "Attempt to use a destroyed cache instance.")
		return nil
	end
	if self._readOnly then
		Debugger:Log("warn", "RefreshTTL", "Cache is in read-only mode; operation ignored.")
		return
	end
	self._mutex:lock()
	local success, result = pcall(function()
		if not self._paused then 
			self._ttl:_expireLoop()
		end
		local realKey = normalizeKey(key)
		local entry = self._dict[realKey]
		if not entry or not entry.expires then
			return false
		end
		local newExpire = entry.expires + extraSeconds
		entry.expires = newExpire
		self._ttl:push(realKey, newExpire)
		return true
	end)
	local eventsToFire
	if #self._eventQueue > 0 then
		eventsToFire = self._eventQueue
		self._eventQueue = {}
	end
	self._mutex:unlock()
	if eventsToFire then
		for _, event in ipairs(eventsToFire) do
			pcall(event.Signal.Fire, event.Signal, unpack(event.Args))
		end
	end
	if not success then
		Debugger:Log("error", "RefreshTTL", ("Internal failure: %s\n%s")
			:format(tostring(result), debug.traceback(nil, 2)))
		return nil
	end
	return result
end

function FullCache:Touch(key:string|{any}, timeBoost:number?):boolean
	if self._destroyed then
		Debugger:Log("error", "Touch", "Attempt to use a destroyed cache instance.")
		return nil
	end
	if self._readOnly then
		Debugger:Log("warn", "Touch", "Cache is in read-only mode; operation ignored.")
		return false
	end
	self._mutex:lock()
	local success, result = pcall(function()
		if not self._paused then
			self._ttl:_expireLoop()
		end
		local realKey = normalizeKey(key)
		local entry = self._dict[realKey]
		if not entry or not entry.expires then
			return false
		end
		local originalTTL = self._ttl:getOriginalTTL(realKey)
		if originalTTL then
			local boost = timeBoost or 0
			local newExpires = self:_getTime() + originalTTL + boost
			entry.expires = newExpires
			self._ttl:push(realKey, newExpires)
			return true
		else
			local remaining = entry.expires - self:_getTime()
			if remaining > 0 then
				local boost = timeBoost or 0
				return self:RefreshTTL(key, boost + remaining - remaining)
			end
			return false
		end
	end)
	local eventsToFire
	if #self._eventQueue > 0 then
		eventsToFire = self._eventQueue
		self._eventQueue = {}
	end
	self._mutex:unlock()
	if eventsToFire then
		for _, event in ipairs(eventsToFire) do
			pcall(event.Signal.Fire, event.Signal, unpack(event.Args))
		end
	end
	if not success then
		Debugger:Log("error", "Touch", ("Internal failure: %s\n%s")
			:format(tostring(result), debug.traceback(nil, 2)))
		return nil
	end
	return result
end

function FullCache:ClearExpired()
	if self._destroyed then
		Debugger:Log("error", "ClearExpired", "Attempt to use a destroyed cache instance.")
		return nil
	end
	if self._readOnly then
		Debugger:Log("warn", "ClearExpired", "Cache is in read-only mode; operation ignored.")
		return
	end
	self._mutex:lock()
	local success, result = pcall(function()
		local now = self:_getTime()
		local removed = 0
		local keysToRemove = {}
		for internalKey, entry in pairs(self._dict) do
			if entry.expires and now >= entry.expires then
				table.insert(keysToRemove, internalKey)
			end
		end
		if #keysToRemove > 0 then
			for _, key in ipairs(keysToRemove) do
				self:_RemoveInternal(key, true)
				removed += 1
			end
			self:_compactArray()
		end
		self:_compactArray()
		return removed
	end)
	local eventsToFire
	if #self._eventQueue > 0 then
		eventsToFire = self._eventQueue
		self._eventQueue = {}
	end
	self._mutex:unlock()
	if eventsToFire then
		for _, event in ipairs(eventsToFire) do
			pcall(event.Signal.Fire, event.Signal, unpack(event.Args))
		end
	end
	if not success then
		Debugger:Log("error", "ClearExpired", ("Internal failure: %s\n%s")
			:format(tostring(result), debug.traceback(nil, 2)))
		return nil
	end
	return result
end

-- [[INTROSPECTION AND ITERATION]]

function FullCache:Peek(key:string|{any}):T?
	if self._destroyed then
		Debugger:Log("error", "Peek", "Attempt to use a destroyed cache instance.")
		return nil
	end
	local realKey = normalizeKey(key)
	local entry = self._dict[realKey]
	if entry and (not entry.expires or self:_getTime() <= entry.expires) then
		return entry.value
	end
	return nil
end

function FullCache:Keys():{string|{any}}
	if self._destroyed then
		Debugger:Log("error", "Keys", "Attempt to use a destroyed cache instance.")
		return nil
	end
	self._mutex:lock()
	local success, result = pcall(function()
		if not self._paused then
			self._ttl:_expireLoop()
		end
		local out = {}
		for internalID, entry in pairs(self._dict) do
			if not entry.expires or self:_getTime() <= entry.expires then
				local originalKey = idToTable[internalID] or internalID
				table.insert(out, originalKey)
			end
		end
		return out
	end)
	local eventsToFire
	if #self._eventQueue > 0 then
		eventsToFire = self._eventQueue
		self._eventQueue = {}
	end
	self._mutex:unlock()
	if eventsToFire then
		for _, event in ipairs(eventsToFire) do
			pcall(event.Signal.Fire, event.Signal, unpack(event.Args))
		end
	end
	if not success then
		Debugger:Log("error", "Keys", ("Internal failure: %s\n%s")
			:format(tostring(result), debug.traceback(nil, 2)))
		return nil
	end
	return result
end

function FullCache:Values():{T}
	if self._destroyed then
		Debugger:Log("error", "Values", "Attempt to use a destroyed cache instance.")
		return nil
	end
	self._mutex:lock()
	local success, result = pcall(function()
		if not self._paused then 
			self._ttl:_expireLoop()
		end
		local out = {}
		self:_forEachArrayEntry(function(entry)
			table.insert(out, entry.value)
		end)
		for internalID, entry in pairs(self._dict) do
			if not entry.expires or self:_getTime() <= entry.expires then
				table.insert(out, entry.value)
			end
		end
		return out
	end)
	local eventsToFire
	if #self._eventQueue > 0 then
		eventsToFire = self._eventQueue
		self._eventQueue = {}
	end
	self._mutex:unlock()
	if eventsToFire then
		for _, event in ipairs(eventsToFire) do
			pcall(event.Signal.Fire, event.Signal, unpack(event.Args))
		end
	end
	if not success then
		Debugger:Log("error", "Values", ("Internal failure: %s\n%s")
			:format(tostring(result), debug.traceback(nil, 2)))
		return nil
	end
	return result
end

function FullCache:ForEach(fn:(key,value)->())
	if self._destroyed then
		Debugger:Log("error", "ForEach", "Attempt to use a destroyed cache instance.")
		return nil
	end
	self._mutex:lock()
	local success, result = pcall(function()
		if not self._paused then 
			self._ttl:_expireLoop()
		end
		self:_forEachArrayEntry(function(entry, logicalIdx)
			fn(logicalIdx, entry.value)
		end)
		for internalID, entry in pairs(self._dict) do
			if not entry.expires or self:_getTime() <= entry.expires then
				local origKey = idToTable[internalID] or internalID
				fn(origKey, entry.value)
			end
		end
	end)
	local eventsToFire
	if #self._eventQueue > 0 then
		eventsToFire = self._eventQueue
		self._eventQueue = {}
	end
	self._mutex:unlock()
	if eventsToFire then
		for _, event in ipairs(eventsToFire) do
			pcall(event.Signal.Fire, event.Signal, unpack(event.Args))
		end
	end
	if not success then
		Debugger:Log("error", "ForEach", ("Internal failure: %s\n%s")
			:format(tostring(result), debug.traceback(nil, 2)))
		return nil
	end
	return result
end

-- [[BULK OPERATIONS]]

function FullCache:BulkSet(entries:{[string|{any}]:T}, options:{parallel:number?})
	if self._destroyed then
		Debugger:Log("error", "BulkSet", "Attempt to use a destroyed cache instance.")
		return nil
	end
	if self._readOnly then
		Debugger:Log("warn", "BulkSet", "Cache is in read-only mode; operation ignored.")
		return
	end
	self._mutex:lock()
	local success, result = pcall(function()
		-- multi-threaded
		if options and options.parallel and RunService:IsClient() then
			local entryList = {}
			for key, value in pairs(entries) do
				table.insert(entryList, {key = key, value = value})
			end
			local function encodeTask(cache, entryChunk)
				local encoded = {}
				for _, item in ipairs(entryChunk) do
					local existingEntry = cache._dict[normalizeKey(item.key)]
					local entryData = cache:_prepareEntry(item.value, existingEntry)
					if entryData and entryData._size <= cache._maxEntrySizeBytes then
						table.insert(encoded, {key = item.key, entryData = entryData})
					end
				end
				return encoded
			end
			local resultsByWorker = self:_executeParallel(entryList, encodeTask, options.parallel)
			self:_pause()
			for _, workerChunk in ipairs(resultsByWorker) do
				if workerChunk then
					for _, itemData in ipairs(workerChunk) do
						self:_internalSetEncoded(itemData.key, itemData.entryData)
					end
				end
			end
			self:_memoryUpdate()
			self:_resume()
			return
		end
		-- single-threaded
		self:_pause()
		local preparedDictEntriesMap = {}
		local keysForPolicyBatchInsert = {}
		local totalNewOrUpdatedSize = 0
		local actualOldSizeOfUpdatedItems = 0
		for key, value in pairs(entries) do
			local realKey = normalizeKey(key)
			local existingEntry = self._dict[realKey]
			local entryData = self:_prepareEntry(value, existingEntry)
			if entryData and entryData._size <= self._maxEntrySizeBytes then
				if existingEntry then
					actualOldSizeOfUpdatedItems += (existingEntry._size or 0)
				else
					table.insert(keysForPolicyBatchInsert, realKey)
				end
				preparedDictEntriesMap[realKey] = {entry = entryData, originalKey = key}
				totalNewOrUpdatedSize += entryData._size
			else
				Debugger:Log("warn", "BulkSet", ("Entry for key %s skipped: too large or failed to prepare.")
					:format(tostring(key)))
			end
		end
		if #keysForPolicyBatchInsert == 0 and actualOldSizeOfUpdatedItems == 0 then
			self:_resume()
			return
		end
		local netSizeIncrease = totalNewOrUpdatedSize - actualOldSizeOfUpdatedItems
		if not self:_ensureMemoryForSize(netSizeIncrease) then
			self:_resume()
			Debugger:Log("error", "BulkSet", "Not enough memory for bulk set after pruning. Operation aborted.")
			return
		end
		for realKey, itemData in pairs(preparedDictEntriesMap) do
			local entryData = itemData.entry
			local existingEntry = self._dict[realKey]
			if existingEntry then
				self:_chargeRemoval(existingEntry, "dict")
			end
			self._dict[realKey] = entryData
			self:_addMemoryUsage(entryData._size, "dict")
			if type(realKey) == "string" then
				self._keyTrie:insert(realKey, stringToSequence(realKey), function() end)
			end
		end
		if self._policy.insertBatch then
			local evictedKeysFromPolicy = self._policy:insertBatch(keysForPolicyBatchInsert)
			for _, evictedKey in ipairs(evictedKeysFromPolicy) do
				if evictedKey and self._dict[evictedKey] then
					self:_RemoveInternal(evictedKey, false)
				end
			end
		else
			for _, realKey in ipairs(keysForPolicyBatchInsert) do
				local evictedKey = self._policy:insert(realKey)
				if evictedKey and evictedKey ~= realKey then
					self:_RemoveInternal(evictedKey, false)
				end
			end
		end
		self:_memoryUpdate()
		self:_resume()
	end)
	local eventsToFire
	if #self._eventQueue > 0 then
		eventsToFire = self._eventQueue
		self._eventQueue = {}
	end
	self._mutex:unlock()
	if eventsToFire then
		for _, event in ipairs(eventsToFire) do
			pcall(event.Signal.Fire, event.Signal, unpack(event.Args))
		end
	end
	if not success then
		Debugger:Log("error", "BulkSet", ("Internal failure: %s\n%s")
			:format(tostring(result), debug.traceback(nil, 2)))
		return nil
	end
	return result
end

function FullCache:BulkRemove(keys:{string|{any}})
	if self._destroyed then
		Debugger:Log("error", "BulkRemove", "Attempt to use a destroyed cache instance.")
		return nil
	end
	if self._readOnly then
		Debugger:Log("warn", "BulkRemove", "Cache is in read-only mode; operation ignored.")
		return
	end
	self._mutex:lock()
	local success, result = pcall(function()
		self:_pause()
		for _, key in ipairs(keys) do
			local realKey = normalizeKey(key)
			local entry = self._dict[realKey]
			if entry then
				self:_fireWatchEvent({
					event = "REMOVE",
					key = key,
					value = entry.value,
					timestamp = self:_getTime()
				})
			end
			if self._virtuals[realKey] then
				self._virtuals[realKey] = nil
			end
			self:_RemoveInternal(realKey, false)
		end
		self:_resume()
	end)
	local eventsToFire
	if #self._eventQueue > 0 then
		eventsToFire = self._eventQueue
		self._eventQueue = {}
	end
	self._mutex:unlock()
	if eventsToFire then
		for _, event in ipairs(eventsToFire) do
			pcall(event.Signal.Fire, event.Signal, unpack(event.Args))
		end
	end
	if not success then
		Debugger:Log("error", "BulkRemove", ("Internal failure: %s\n%s")
			:format(tostring(result), debug.traceback(nil, 2)))
		return nil
	end
	return result
end

function FullCache:BulkGet(keys:{string|{any}}, options:{parallel:number?}):{T?}
	if self._destroyed then
		Debugger:Log("error", "BulkGet", "Attempt to use a destroyed cache instance.")
		return nil
	end
	self._mutex:lock()
	local success, result = pcall(function()
		if not self._paused then
			self._ttl:_expireLoop()
		end
		if options and options.parallel and RunService:IsClient() then
			local indexedKeys = {}
			for i, key in ipairs(keys) do
				table.insert(indexedKeys, {key = key, index = i})
			end
			local function getTask(cache, indexedKeyChunk)
				local results = {}
				for _, item in ipairs(indexedKeyChunk) do
					local value = cache:_getReadOnly(normalizeKey(item.key))
					table.insert(results, {value = value, index = item.index, key = normalizeKey(item.key)})
				end
				return results
			end
			local resultsByWorker = self:_executeParallel(indexedKeys, getTask, options.parallel)
			local finalResults = {}
			local accessedKeys = {}
			for _, workerResults in ipairs(resultsByWorker) do
				if workerResults then
					for _, singleResult in ipairs(workerResults) do
						finalResults[singleResult.index] = singleResult.value
						if singleResult.value ~= nil then
							table.insert(accessedKeys, singleResult.key)
						end
					end
				end
			end
			if #accessedKeys > 0 then
				self._metrics.hits += #accessedKeys
				if self._policy.accessBatch then
					self._policy:accessBatch(accessedKeys)
				else
					for _, accessedKey in ipairs(accessedKeys) do
						self._policy:access(accessedKey)
					end
				end
			end
			self._metrics.misses += (#keys - #accessedKeys)

			return finalResults
		end
		-- Single-Threaded Path
		local results = {}
		local accessedKeys = {}
		for i, key in ipairs(keys) do
			local realKey = normalizeKey(key)
			local value = self:_getReadOnly(realKey)
			results[i] = value
			if value ~= nil then
				table.insert(accessedKeys, realKey)
			end
		end
		if #accessedKeys > 0 then
			self._metrics.hits += #accessedKeys
			if self._policy.accessBatch then
				self._policy:accessBatch(accessedKeys)
			else
				for _, accessedKey in ipairs(accessedKeys) do
					self._policy:access(accessedKey)
				end
			end
		end
		self._metrics.misses += (#keys - #accessedKeys)
		return results
	end)
	local eventsToFire
	if #self._eventQueue > 0 then
		eventsToFire = self._eventQueue
		self._eventQueue = {}
	end
	self._mutex:unlock()
	if eventsToFire then
		for _, event in ipairs(eventsToFire) do
			pcall(event.Signal.Fire, event.Signal, unpack(event.Args))
		end
	end
	if not success then
		Debugger:Log("error", "BulkGet", ("Internal failure: %s\n%s")
			:format(tostring(result), debug.traceback(nil, 2)))
		return nil
	end
	return result
end

-- [[MEMORY]]

function FullCache:GetMemoryUsage(): number
	if self._destroyed then
		Debugger:Log("error", "GetMemoryUsage", "Attempt to use a destroyed cache instance.")
		return nil
	end
	return self._arrayMemoryUsage + self._dictMemoryUsage
end

function FullCache:GetMemoryUsageByType():{T}
	if self._destroyed then
		Debugger:Log("error", "GetMemoryUsageByType", "Attempt to use a destroyed cache instance.")
		return nil
	end
	return {
		array = self._arrayMemoryUsage,
		dict = self._dictMemoryUsage
	}
end

function FullCache:GetRemainingMemory():number
	if self._destroyed then
		Debugger:Log("error", "GetRemainingMemory", "Attempt to use a destroyed cache instance.")
		return nil
	end
	if not self._memoryBudget then
		return math.huge
	end
	return math.max(0, self._memoryBudget - self:GetMemoryUsage())
end

function FullCache:GetMemoryInfo():{T}
	if self._destroyed then
		Debugger:Log("error", "GetMemoryInfo", "Attempt to use a destroyed cache instance.")
		return nil
	end
	local used = self:GetMemoryUsage()
	local budget = self._memoryBudget or math.huge
	local percentUsed = (used / budget) * 100

	return {
		used = used,
		budget = budget,
		percentUsed = percentUsed
	}
end

function FullCache:IsNearMemoryBudget(threshold:number):boolean
	if self._destroyed then
		Debugger:Log("error", "IsNearMemoryBudget", "Attempt to use a destroyed cache instance.")
		return nil
	end
	threshold = threshold or 0.9
	if not self._memoryBudget then
		return false
	end
	return self:GetMemoryUsage() >= self._memoryBudget * threshold
end

-- [[DYNAMIC CONFIGURATIONS]]

function FullCache:Resize(newMax:number)
	if self._destroyed then
		Debugger:Log("error", "Resize", "Attempt to use a destroyed cache instance.")
		return nil
	end
	if self._readOnly then
		Debugger:Log("warn", "Resize", "Cache is in read-only mode; operation ignored.")
		return
	end
	self._mutex:lock()
	local success, result = pcall(function()
		if typeof(newMax) ~= "number" or newMax <= 0 then
			Debugger:Log("error","Resize", ("expected newMax to be a positive number, got: %q %s")
				:format(typeof(newMax),newMax))
		end
		self._maxobj = newMax
		if self._policy and self._policy._maxSize then
			self._policy._maxSize = newMax
		end
		while _dictSize(self._dict) > newMax do
			local victim = self._policy.evict and self._policy:evict()
			if not victim then break end
			self:_RemoveInternal(victim, false)
		end
		while #self._array > newMax do
			self:_evictArrayOne()
		end
	end)
	local eventsToFire
	if #self._eventQueue > 0 then
		eventsToFire = self._eventQueue
		self._eventQueue = {}
	end
	self._mutex:unlock()
	if eventsToFire then
		for _, event in ipairs(eventsToFire) do
			pcall(event.Signal.Fire, event.Signal, unpack(event.Args))
		end
	end
	if not success then
		Debugger:Log("error", "Resize", ("Internal failure: %s\n%s")
			:format(tostring(result), debug.traceback(nil, 2)))
		return nil
	end
	return result
end

function FullCache:SetPolicy(policyName: string)
	if self._destroyed then
		Debugger:Log("error", "SetPolicy", "Attempt to use a destroyed cache instance.")
		return nil
	end
	if self._readOnly then
		Debugger:Log("warn", "SetPolicy", "Cache is in read-only mode; operation ignored.")
		return
	end
	self._mutex:lock()
	local success, result = pcall(function()
		if typeof(policyName) ~= "string" then
			Debugger:Log("error", "SetPolicy", ("expected policyName to be a string, got: %s")
				:format(typeof(policyName)))
		end
		local up = policyName:upper()
		if up == self._policyName then
			return
		end
		local module = Policies[up]
		if not module then
			Debugger:Log("error", "SetPolicy", ("invalid policy: %s")
				:format(policyName))
		end
		self._policy = module.new(self._maxobj, self)
		self._policyName = up
		self._policyModule = module
		if self._policy.insertBatch then
			local existingKeys = {}
			for key, _ in pairs(self._dict) do
				table.insert(existingKeys, key)
			end
			self._policy:insertBatch(existingKeys)
		else
			for key, _ in pairs(self._dict) do
				self._policy:insert(key)
			end
		end
	end)
	local eventsToFire
	if #self._eventQueue > 0 then
		eventsToFire = self._eventQueue
		self._eventQueue = {}
	end
	self._mutex:unlock()
	if eventsToFire then
		for _, event in ipairs(eventsToFire) do
			pcall(event.Signal.Fire, event.Signal, unpack(event.Args))
		end
	end
	if not success then
		Debugger:Log("error", "SetPolicy", ("Internal failure: %s\n%s")
			:format(tostring(result), debug.traceback(nil, 2)))
		return nil
	end
	return result
end

function FullCache:SetMemoryBudget(budget:number)
	if self._destroyed then
		Debugger:Log("error", "SetMemoryBudget", "Attempt to use a destroyed cache instance.")
		return nil
	end
	if self._readOnly then
		Debugger:Log("warn", "SetMemoryBudget", "Cache is in read-only mode; operation ignored.")
		return
	end
	self._mutex:lock()
	local success, result = pcall(function()
		if typeof(budget) ~= "number" or budget <= 0 then
			Debugger:Log("error","SetMemoryBudget", ("expected memoryBudget to be a positive number, got: %q %s")
				:format(typeof(budget),budget))
		end
		self._memoryBudget = budget
		self:_pruneByMemory(0)
	end)
	local eventsToFire
	if #self._eventQueue > 0 then
		eventsToFire = self._eventQueue
		self._eventQueue = {}
	end
	self._mutex:unlock()
	if eventsToFire then
		for _, event in ipairs(eventsToFire) do
			pcall(event.Signal.Fire, event.Signal, unpack(event.Args))
		end
	end
	if not success then
		Debugger:Log("error", "SetMemoryBudget", ("Internal failure: %s\n%s")
			:format(tostring(result), debug.traceback(nil, 2)))
		return nil
	end
	return result
end

-- [[EVENTS]]

function FullCache:Watch():(() -> TypeDef.WatchEvent<T>?, () -> ())
	if self._destroyed then
		Debugger:Log("error", "Watch", "Attempt to use a destroyed cache instance.")
		return function() end, function() end
	end
	self._mutex:lock()
	local eventsToFire
	local success, result = pcall(function()
		local eventQueue = {}
		local id = HttpService:GenerateGUID(false)
		self._watchers[id] = eventQueue
		local iterator = function()
			if #eventQueue > 0 then
				return table.remove(eventQueue, 1)
			end
			return nil
		end
		local cleanup = function()
			self._watchers[id] = nil
		end
		return {iterator, cleanup} 
	end)
	local eventsToFire
	if #self._eventQueue > 0 then
		eventsToFire = self._eventQueue
		self._eventQueue = {}
	end
	self._mutex:unlock()
	if eventsToFire then
		for _, event in ipairs(eventsToFire) do
			pcall(event.Signal.Fire, event.Signal, unpack(event.Args))
		end
	end
	if not success then
		Debugger:Log("error", "Watch", "Failed to create watcher: " .. tostring(result))
		return function() end, function() end
	end
	return result[1], result[2]
end

function FullCache:OnEvict(fn:(info: TypeDef.EvictionInfo<T>)->()):number
	if self._destroyed then
		Debugger:Log("error", "OnEvict", "Attempt to use a destroyed cache instance.")
		return nil
	end
	return self._evictSignal:Connect(fn)
end

function FullCache:OnHit(fn:(key, value)->())
	if self._destroyed then
		Debugger:Log("error", "OnHit", "Attempt to use a destroyed cache instance.")
		return nil
	end
	return self._hitSignal:Connect(fn)
end

function FullCache:OnMiss(fn:(key)->())
	if self._destroyed then
		Debugger:Log("error", "OnMiss", "Attempt to use a destroyed cache instance.")
		return nil
	end
	return self._missSignal:Connect(fn)
end

function FullCache:OnExpire(fn:(key, value)->())
	if self._destroyed then
		Debugger:Log("error", "OnExpire", "Attempt to use a destroyed cache instance.")
		return nil
	end
	return self._expireSignal:Connect(fn)
end

function FullCache:OnMemoryChanged(fn:(info: TypeDef.MemoryChangeInfo<T>)->()):number
	if self._destroyed then
		Debugger:Log("error", "OnMemoryChanged", "Attempt to use a destroyed cache instance.")
		return nil
	end
	return self._memorySignal:Connect(fn)
end

-- [[METRICS]]

function FullCache:ResetMetrics()
	if self._destroyed then
		Debugger:Log("error", "ResetMetrics", "Attempt to use a destroyed cache instance.")
		return nil
	end
	self._mutex:lock()
	local success, result = pcall(function()
		if self._readOnly then
			Debugger:Log("warn", "ResetMetrics", "Cache is in read-only mode; operation ignored.")
			return
		end
		self._metrics.hits = 0
		self._metrics.misses = 0
		self._metrics.evictions = 0
		self._metrics.startTime = self:_getTime()
	end)
	local eventsToFire
	if #self._eventQueue > 0 then
		eventsToFire = self._eventQueue
		self._eventQueue = {}
	end
	self._mutex:unlock()
	if eventsToFire then
		for _, event in ipairs(eventsToFire) do
			pcall(event.Signal.Fire, event.Signal, unpack(event.Args))
		end
	end
	if not success then
		Debugger:Log("error", "ResetMetrics", ("Internal failure: %s\n%s")
			:format(tostring(result), debug.traceback(nil, 2)))
		return nil
	end
	return result
end

function FullCache:GetStats():{T}
	if self._destroyed then
		Debugger:Log("error", "GetStats", "Attempt to use a destroyed cache instance.")
		return nil
	end
	local uptime = self:_getTime() - self._metrics.startTime
	local total  = self._metrics.hits + self._metrics.misses
	local hitRate = (total > 0) and (self._metrics.hits / total) or 0
	return {
		hits = self._metrics.hits,
		misses = self._metrics.misses,
		evictions = self._metrics.evictions,
		uptime = uptime,
		hitRate = hitRate,
	}
end

-- [[MISCELLANEOUS]]

function FullCache:RemoveByPattern(patOrFn:string|{string}|((key:string|any) -> boolean))
	if self._destroyed then
		Debugger:Log("error", "RemoveByPattern", "Attempt to use a destroyed cache instance.")
		return nil
	end
	if self._readOnly then
		Debugger:Log("warn", "RemoveByPattern", "Cache is in read-only mode; operation ignored.")
		return 0
	end
	self._mutex:lock()
	local success, result = pcall(function()
		local toRemove = {}
		local patType = type(patOrFn)
		if patType == "function" then
			-- Handle predicate function
			for internalID, _ in pairs(self._dict) do
				local origKey = idToTable[internalID] or internalID
				local success, res = pcall(patOrFn, origKey)
				if success and res == true then
					table.insert(toRemove, internalID)
				end
			end
		elseif patType == "string" then
			local hasGlob = patOrFn:find("*", 1, true)
			if hasGlob then
				local isSimplePrefix = patOrFn:sub(-1) == "*" and not patOrFn:sub(1, -2):find("*", 1, true)
				if isSimplePrefix then
					local prefix = patOrFn:sub(1, -2)
					return self:RemoveNamespace(prefix)
				end
				toRemove = _findKeysByGlobIterative(self._keyTrie, patOrFn)
			else
				-- Fallback for non-glob string patterns to slower iteration
				Debugger:Log("warn", "RemoveByPattern", "Complex pattern detected. Falling back to slower iteration method. For high performance, use glob patterns with '*' (e.g. 'user:*' or 'user:*:config').")
				for internalID, entry in pairs(self._dict) do
					local key = entry.key or internalID
					if type(key) == "string" then
						local success, matchResult = pcall(string.match, key, patOrFn)
						if success and matchResult then
							table.insert(toRemove, internalID)
						end
					end
				end
			end
		elseif patType == "table" then
			local patterns = patOrFn
			if #patterns == 0 then return 0 end
			-- Determine which algorithm to use by checking for wildcards
			local hasGlobPatterns = false
			for _, pattern in ipairs(patterns) do
				if type(pattern) == "string" and string.find(pattern, "*", 1, true) then
					hasGlobPatterns = true
					break
				end
			end
			if hasGlobPatterns then
				-- Trie-Based search for glob patterns
			--	Debugger:Log("print", "RemoveByPattern", "Glob patterns detected. Using Trie search.")
				local keysFound = {} -- Use a dictionary to prevent adding duplicate keys.
				for _, pattern in ipairs(patterns) do
					if type(pattern) == "string" then
						local resultsForPattern = _findKeysByGlobIterative(self._keyTrie, pattern)
						for _, key in ipairs(resultsForPattern) do
							if not keysFound[key] then
								table.insert(toRemove, key)
								keysFound[key] = true
							end
						end
					end
				end
			else
				-- Fallback to Aho-Corasick for non-glob patterns
			--	Debugger:Log("print", "RemoveByPattern", "No glob patterns found. Using high-performance Aho-Corasick.")
				local automaton = AhoCorasick.new(patterns)
				automaton:Build()
				for internalID, _ in pairs(self._dict) do
					if type(internalID) == "string" then
						if automaton:Contains(internalID) then
							table.insert(toRemove, internalID)
						end
					end
				end
			end
		else
			Debugger:Log("error", "RemoveByPattern", ("expected string, table of strings, or a function, got: %q")
				:format(patType))
			return 0
		end
		if #toRemove > 0 then
			self:BulkRemove(toRemove)
			return #toRemove
		end
		return 0
	end)
	local eventsToFire
	if #self._eventQueue > 0 then
		eventsToFire = self._eventQueue
		self._eventQueue = {}
	end
	self._mutex:unlock()
	if eventsToFire then
		for _, event in ipairs(eventsToFire) do
			pcall(event.Signal.Fire, event.Signal, unpack(event.Args))
		end
	end
	if not success then
		Debugger:Log("error", "RemoveByPattern", ("Internal failure: %s\n%s")
			:format(tostring(result), debug.traceback(nil, 2)))
		return nil
	end
	return result
end

function FullCache:RemoveNamespace(prefix:string):number
	if self._destroyed then
		Debugger:Log("error", "RemoveNamespace", "Attempt to use a destroyed cache instance.")
		return nil
	end
	if self._readOnly then
		Debugger:Log("warn", "RemoveNamespace", "Cache is in read-only mode; operation ignored.")
		return 0
	end
	self._mutex:lock()
	local success, result = pcall(function()
		if type(prefix) ~= "string" or prefix == "" then
			Debugger:Log("error", "RemoveNamespace", ("expected a non-empty string for prefix, got: %s")
				:format(type(prefix)))
			return 0
		end
		local sequence = stringToSequence(prefix)
		local startNode = self._keyTrie:search(sequence)
		if not startNode then
			return 0
		end
		local keysToRemove = getAllKeysFromNode(startNode)
		if #keysToRemove > 0 then
			self:BulkRemove(keysToRemove)
			return #keysToRemove
		end
		return 0
	end)
	local eventsToFire
	if #self._eventQueue > 0 then
		eventsToFire = self._eventQueue
		self._eventQueue = {}
	end
	self._mutex:unlock()
	if eventsToFire then
		for _, event in ipairs(eventsToFire) do
			pcall(event.Signal.Fire, event.Signal, unpack(event.Args))
		end
	end
	if not success then
		Debugger:Log("error", "RemoveNamespace", ("Internal failure: %s\n%s")
			:format(tostring(result), debug.traceback(nil, 2)))
		return nil
	end
	return result
end

function FullCache:ManualSweep(options:{expireOnly:boolean?, enforceMemory:boolean?})
	if self._destroyed then
		Debugger:Log("error", "ManualSweep", "Attempt to use a destroyed cache instance.")
		return nil
	end
	if self._readOnly then
		Debugger:Log("warn", "ManualSweep", "Cache is in read-only mode; operation ignored.")
		return
	end
	self._mutex:lock()
	local success, result = pcall(function()
		local opts = options or {}
		local expireOnly = opts.expireOnly or false
		local enforceMemoryOnly = opts.enforceMemory or false
		local shouldClearExpired = not enforceMemoryOnly
		local shouldEnforceLimits = not expireOnly
		if shouldClearExpired then
			self:ClearExpired()
		end
		if shouldEnforceLimits then
			self:_pruneByMemory(0)
			while _dictSize(self._dict) > self._maxobj do
				local victimKey = self._policy.evict and self._policy:evict()
				if not victimKey then
					break
				end
				self:_RemoveInternal(victimKey, false)
			end
			while self._arrayCount > self._maxobj do
				self:_evictArrayOne()
			end
		end
	end)
	local eventsToFire
	if #self._eventQueue > 0 then
		eventsToFire = self._eventQueue
		self._eventQueue = {}
	end
	self._mutex:unlock()
	if eventsToFire then
		for _, event in ipairs(eventsToFire) do
			pcall(event.Signal.Fire, event.Signal, unpack(event.Args))
		end
	end
	if not success then
		Debugger:Log("error", "ManualSweep", ("Internal failure: %s\n%s")
			:format(tostring(result), debug.traceback(nil, 2)))
		return nil
	end
	return result
end

function FullCache:Snapshot(keyOrOption:string?): TypeDef.SnapshotData<T>
	if self._destroyed then
		Debugger:Log("error", "Snapshot", "Attempt to use a destroyed cache instance.")
		return nil
	end
	local optionType = type(keyOrOption)
	if (optionType == "string" or optionType == "table") then
		local isOption = (optionType == "string" and (string.lower(keyOrOption) == "auto" 
			or string.lower(keyOrOption) == "shallow" or string.lower(keyOrOption) == "deep"))
		if not isOption then
			local realKey = normalizeKey(keyOrOption)
			local entry = self._dict[realKey]
			if entry then
				return {
					partial_dict = {
						[realKey] = _deepClone(entry)
					},
					formatType = self._formatType,
					timestamp = self:_getTime(),
				}
			else
				return nil
			end
		end
	end
	local mode = (optionType == "string" and keyOrOption 
		and string.lower(keyOrOption)) or "shallow"
	local serArray = {}
	self:_forEachArrayEntry(function(entry, logicalIdx)
		local clonedEntry
		if mode == "deep" then
			clonedEntry = _deepClone(entry)
		elseif mode == "auto" and type(entry.value) == "table" then
			clonedEntry = _deepClone(entry)
		else -- shallow
			clonedEntry = table.clone(entry)
		end
		table.insert(serArray, clonedEntry)
	end)
	local dictCopy = {}
	for k, entryInDict in pairs(self._dict) do
		local clonedEntry
		if mode == "deep" then
			clonedEntry = _deepClone(entryInDict)
		elseif mode == "auto" and type(entryInDict.value) == "table" then
			clonedEntry = _deepClone(entryInDict)
		else
			clonedEntry = table.clone(entryInDict)
		end
		dictCopy[k] = clonedEntry
	end
	return {
		array = serArray,
		dict = dictCopy,
		maxobj = self._maxobj,
		policyName = self._policyName,
		policyState = _deepClone(self._policy:snapshot()),
		memoryBudget = self._memoryBudget,
		memoryUsage = self._memoryUsage,
		arrayMemoryUsage = self._arrayMemoryUsage,
		dictMemoryUsage = self._dictMemoryUsage,
		maxEntrySizeBytes = self._maxEntrySizeBytes,
		formatType = self._formatType,
		timestamp = self:_getTime(),
		arrayHead = self._arrayHead,
		arrayLogicalEnd = self._arrayLogicalEnd,
		arrayCount = self._arrayCount,
		ttlCapacity = self._ttlCapacity,
		ttlFilter = self._ttlFilter
	}
end

function FullCache:Restore(snapshot:TypeDef.SnapshotData<T>)
	if self._destroyed then
		Debugger:Log("error", "Restore", "Attempt to use a destroyed cache instance.")
		return nil
	end
	if self._readOnly then
		Debugger:Log("warn", "Restore", "Cache is in read-only mode; operation ignored.")
		return
	end
	self._mutex:lock()
	local success, result = pcall(function()
		if not snapshot or type(snapshot) ~= "table" then
			Debugger:Log("error", "Restore", "Invalid or malformed snapshot provided.")
			return
		end
		-- Partial restore
		if snapshot.partial_dict and type(snapshot.partial_dict) == "table" then
			local success, err = pcall(function()
				self:_pause()
				local netSizeChange = 0
				local itemsToRestore = {}
				for key, entry in pairs(snapshot.partial_dict) do
					local oldSize = 0
					if self._dict[key] then
						oldSize = self._dict[key]._size or 0
					end
					netSizeChange = netSizeChange + ((entry._size or 0) - oldSize)
					table.insert(itemsToRestore, {key = key, entry = entry})
				end
				if netSizeChange > 0 then
					if not self:_ensureMemoryForSize(netSizeChange) then
						error("Not enough memory to restore partial snapshot after pruning attempts.")
					end
				end
				for _, item in ipairs(itemsToRestore) do
					local key, newEntryData = item.key, item.entry
					if self._dict[key] then
						self:_RemoveInternal(key, false)
					end
					local newEntry = _deepClone(newEntryData)
					self._dict[key] = newEntry
					self:_addMemoryUsage(newEntry._size, "dict")
					self._policy:insert(key)
					if type(key) == "string" then
						self._keyTrie:insert(key, stringToSequence(key), function() end)
					end
					if newEntry.expires then
						self._ttl:push(key, newEntry.expires)
					end
				end
				self:_memoryUpdate()
				self:_resume()
			end)
			if not success then
				self:_resume()
				Debugger:Log("error", "Restore", ("Partial restore failed: %s. Cache may be in an inconsistent state.")
					:format(err))
			end
			return
		end
		if not (snapshot and snapshot.dict and snapshot.policyName) then
			Debugger:Log("error", "Restore", "Invalid or malformed full snapshot provided.")
		end
		-- Save the current state to enable rollback on failure
		local oldState = {
			_array = self._array,
			_dict = self._dict,
			_keyTrie = self._keyTrie,
			_maxobj = self._maxobj,
			_policy = self._policy,
			_policyName = self._policyName,
			_policyModule = self._policyModule,
			_memoryUsage = self._memoryUsage,
			_arrayMemoryUsage = self._arrayMemoryUsage,
			_dictMemoryUsage = self._dictMemoryUsage,
			_memoryBudget = self._memoryBudget,
			_maxEntrySizeBytes = self._maxEntrySizeBytes,
			_formatType = self._formatType,
			_arrayHead = self._arrayHead,
			_arrayLogicalEnd = self._arrayLogicalEnd,
			_arrayCount = self._arrayCount,
			_ttlCapacity = self._ttlCapacity,
			_ttlFilter = self._ttlFilter,
			_ttl = self._ttl
		}
		local success, err = pcall(function()
			self._ttl:stop()
			-- Restore raw state from snapshot
			self._array = _deepClone(snapshot.array)
			self._dict = _deepClone(snapshot.dict)
			self._keyTrie:clear()
			for key, _ in pairs(self._dict) do
				if type(key) == "string" then
					self._keyTrie:insert(key, stringToSequence(key), function() end)
				end
			end
			self._maxobj = snapshot.maxobj
			self._memoryUsage = snapshot.memoryUsage
			self._arrayMemoryUsage = snapshot.arrayMemoryUsage
			self._dictMemoryUsage = snapshot.dictMemoryUsage
			self._memoryBudget = snapshot.memoryBudget or DefaultMemoryBudget
			self._maxEntrySizeBytes = snapshot.maxEntrySizeBytes
			self._formatType = snapshot.formatType
			self._arrayHead = snapshot.arrayHead
			self._arrayLogicalEnd = snapshot.arrayLogicalEnd
			self._arrayCount = snapshot.arrayCount
			self._ttlCapacity = snapshot.ttlCapacity
			self._ttlFilter = snapshot.ttlFilter
			-- Restore Policy
			self._policyName = snapshot.policyName or "FIFO"
			local policyModule = Policies[self._policyName]
			if not policyModule then
				error(("Policy %q from snapshot not found.")
					:format(self._policyName), 0)
			end
			self._policyModule = policyModule
			self._policy = policyModule.new(self._maxobj, self)
			if snapshot.policyState and self._policy.restore then
				self._policy:restore(snapshot.policyState)
			end
			self._ttl = TTL.new(self, self._ttlCapacity, self._ttlFilter)
			for key, entry in pairs(self._dict) do
				if entry.expires then
					self._ttl:push(key, entry.expires)
				end
			end
			self._ttl:start()
		end)
		if not success then
			for k, v in pairs(oldState) do
				self[k] = v
			end
			if oldState._ttl then
				oldState._ttl:start()
			end
			Debugger:Log("error", "Restore", ("Restore failed and was rolled back: %s")
				:format(err))
		end
	end)
	local eventsToFire
	if #self._eventQueue > 0 then
		eventsToFire = self._eventQueue
		self._eventQueue = {}
	end
	self._mutex:unlock()
	if eventsToFire then
		for _, event in ipairs(eventsToFire) do
			pcall(event.Signal.Fire, event.Signal, unpack(event.Args))
		end
	end
	if not success then
		Debugger:Log("error", "Restore", ("Internal failure: %s\n%s")
			:format(tostring(result), debug.traceback(nil, 2)))
		return nil
	end
	return result
end

function FullCache:GetMetrics()
	if self._destroyed then
		Debugger:Log("error", "GetMetrics", "Attempt to use a destroyed cache instance.")
		return nil
	end
	local uptime = self:_getTime() - self._metrics.startTime
	local ratio = (self._metrics.hits == 0) and 0
		or (self._metrics.hits / (self._metrics.hits + self._metrics.misses))
	return {
		hits = self._metrics.hits,
		misses = self._metrics.misses,
		evictions = self._metrics.evictions,
		uptime = uptime,
		hitMissRatio = ratio,
	}
end

-- [[Atomic Operations]]
function FullCache:Transaction(transactionFn: (cache: TypeDef.FullCache) -> any)
	if self._destroyed then
		Debugger:Log("error", "Transaction", "Attempt to use a destroyed cache instance.")
		return
	end
	if self._readOnly then
		Debugger:Log("warn", "Transaction", "Cache is in read-only mode; operation ignored.")
		return
	end
	local journal = {}
	local txCache = {}
	function txCache:Get(key)
		local realKey = normalizeKey(key)
		if journal[realKey] then
			if journal[realKey].__REMOVED then
				return nil
			else
				return journal[realKey].value
			end
		end
		return self:_getInternal(key, true)
	end
	function txCache:Set(key, value)
		local realKey = normalizeKey(key)
		journal[realKey] = journal[realKey] or {}
		journal[realKey].op = "SET"
		journal[realKey].value = value
		return value
	end
	function txCache:SetMetadata(key, data)
		local realKey = normalizeKey(key)
		journal[realKey] = journal[realKey] or {}
		journal[realKey].metadata = data
	end
	function txCache:Remove(key)
		local realKey = normalizeKey(key)
		journal[realKey] = {
			op = "REMOVE",
			__REMOVED = true
		}
	end
	function txCache:Update(key, updaterFn)
		local currentValue = txCache:Get(key)
		local newValue = updaterFn(currentValue)
		if newValue ~= nil then
			txCache:Set(key, newValue)
		else
			txCache:Remove(key)
		end
		return newValue
	end
	function txCache:Has(key)
		local val = txCache:Get(key)
		return val ~= nil
	end
	setmetatable(txCache, { __index = self })
	self._mutex:lock()
	local eventsToFire
	local success, results = pcall(transactionFn, txCache)
	if success then
		for key, change in pairs(journal) do
			if change.op == "SET" then
				self:_setInternal(key, change.value)
			elseif change.op == "REMOVE" then
				self:_RemoveInternal(key, false)
			end
			if change.metadata then
				self:SetMetadata(key, change.metadata)
			end
		end
	end
	local eventsToFire
	if #self._eventQueue > 0 then
		eventsToFire = self._eventQueue
		self._eventQueue = {}
	end
	self._mutex:unlock()
	if eventsToFire then
		for _, event in ipairs(eventsToFire) do
			pcall(event.Signal.Fire, event.Signal, unpack(event.Args))
		end
	end
	if not success then
		Debugger:Log("error", "ResetMetrics", ("Internal failure: %s\n%s")
			:format(tostring(results), debug.traceback(nil, 2)))
		return nil
	end
	if type(results) == "table" and #results > 0 then
		return unpack(results)
	end
	return results
end
FullCache.new = FullCache.Create
FullCache.Version = Version; FullCache.Registry = Cache
------------------------------------------------------------------------------------------------------------
return Debugger:Profile(FullCache, "Create", script) :: TypeDef.Static