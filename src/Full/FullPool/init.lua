--!optimize 2
--[[
	AUTHOR: Kel (@GudEveningBois)

	Created:
	6/18/25
	11:00 PM UTC+9
	
	Read documentary in FullPool.Documentary
]]
local VERSION = "0.1.725 (STABLE)"
-- Dependencies
local TypeDef = require(script.TypeDef)
local Signal = require(script.Parent.Parent.Components.KelSignal)
local Debugger = require(script.Parent.Parent.Components.Debugger).From(script.Name)
local Mutex = require(script.Parent.Parent.Components.Mutex)
local Serializer = require(script.Serializer)
-- Algorithms
local PairingHeap = require(script.Parent.Parent.Components.Algorithms.PairingHeap)
local Trie = require(script.Parent.Parent.Components.Algorithms.Trie)
local TBA = require(script.Parent.Parent.Components.Algorithms.TBA)

local FullPool = {}
FullPool.__index = FullPool

-- Services
local RunService = game:GetService("RunService")
local HttpService = game:GetService("HttpService")

local Pools = {
	_mutex = Mutex.new(),
	_trie = Trie.new(),
	_map = {}
}
local DEFAULT_MAX_SIZE = 100
local DEFAULT_INITIAL_SIZE = 10

-- Helper functions ----------------------------------------------------------------------------------------
-- Since these are helper functions, do not use any of these externally.
-- (The helper methods are "usually" named with an underscore, AKA '_')

local function _stringToSequence(str)
	local seq = {}
	for i = 1, #str do
		table.insert(seq, string.sub(str, i, i))
	end
	return seq
end

local function _getAllKeysFromNode(startNode)
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

local function _getActiveCount(activeInstances)
	local count = 0
	for _ in pairs(activeInstances) do
		count += 1
	end
	return count
end

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
			local keysFromNode = _getAllKeysFromNode(currentNode)
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

function FullPool.new(instanceType: string, config: TypeDef.PoolConfig?)
	config = config or {}
	local finalInstanceType = instanceType
	if not finalInstanceType and config.templateInstance then
		finalInstanceType = config.templateInstance.ClassName
	end
	if typeof(finalInstanceType) ~= "string" then
		Debugger:Throw("error", "new", "Could not determine a valid instanceType from the provided config.")
	end
	instanceType = finalInstanceType
	local success, _ = pcall(Instance.new, instanceType)
	if not success then
		Debugger:Throw("error", "new", ("Invalid instanceType: %q")
			:format(instanceType))
	end
	config = config or {}
	local self = setmetatable({}, FullPool)
	self._instanceType = instanceType
	self._templateInstance = config.templateInstance
	self._cleanupCallback = config.cleanupCallback
	self._validateCallback = config.validateCallback
	self._autoShrinkDelay = config.autoShrinkDelay
	self._lastReturnTime = 0
	if config.getsPerSecond and config.getsPerSecond > 0 then
		self._getRateLimiter = TBA.new(config.getsPerSecond, config.getsPerSecond)
	end
	self._lock = Mutex.new()
	self._leaseHeap = PairingHeap.new()
	self._maxSize = config.maxSize or DEFAULT_MAX_SIZE
	self._initialSize = config.initialSize or DEFAULT_INITIAL_SIZE
	self._isDestroyed = false
	self._isReadOnly = false
	self._isPaused = false
	self._name = config.name or ("FullPool<%s>:%s")
		:format(instanceType, HttpService:GenerateGUID(false))
	self.Name = self._name
	self.InstanceType = self._instanceType
	self.OnGet = Signal.new()
	self.OnReturn = Signal.new()
	self.OnCreate = Signal.new()
	self.OnDestroy = Signal.new()
	self.OnLeaseExpired = Signal.new()
	self.OnMemoryChanged = Signal.new()
	self.OnEvict = Signal.new()
	self.OnHit = Signal.new()
	self.OnMiss = Signal.new()
	self.OnInstanceAvailable = Signal.new()
	self._stats = {
		gets = 0, 
		hits = 0,
		misses = 0,
		creations = 0,
		returns = 0,
		evictions = 0,
		leaseExpirations = 0,
		pinnedCount = 0,
	}
	self._safeToRemove = nil
	self._activeMemoryUsage = 0
	self._idleMemoryUsage = 0
	self._lastLeaseCheck = 0
	self._leaseConnections = {}
	self._activeInstances = {}
	self._idleInstances = {}
	self._leaseServiceConnection = RunService.Heartbeat:Connect(function()
		if self._isPaused then return end 
		local now = os.clock()
		self:_leaseServiceLoop()
	end)
	self:_warmupPool(self._initialSize)
	if config.onReady then
		pcall(config.onReady)
	end
	return self
end

function FullPool:_createInstance(): Instance
	local instance
	if self._templateInstance then
		instance = self._templateInstance:Clone()
	else
		instance = Instance.new(self._instanceType)
	end
	instance.Parent = nil
	return instance
end

function FullPool:_destroyInstance(instance: Instance, reason: string)
	if typeof(instance) == "Instance" then
		instance:Destroy()
	end
	self._stats.evictions += 1
	pcall(function() self.OnDestroy:Fire(instance, reason) end)
end

function FullPool:_cleanupInstance(instance: Instance)
	instance.Parent = nil
	if self._cleanupCallback then
		self._cleanupCallback(instance)
	end
end

function FullPool:_warmupPool(count)
	if count <= 0 then return end
	for i = 1, count do
		if #self._idleInstances + #self._activeInstances >= self._maxSize then
			break
		end
		local instance = self:_createInstance()
		self._stats.creations += 1
		pcall(function() self.OnCreate:Fire(instance) end)
		table.insert(self._idleInstances, instance)
	end
end

function FullPool:_leaseServiceLoop(forceSweep: boolean?)
	if self._isDestroyed or (self._isPaused and not forceSweep) then 
		return 
	end
	local now = os.clock()
	while not self._leaseHeap:isEmpty() and self._leaseHeap:getMin().key <= now do
		local expiredNode = self._leaseHeap:extractMin()
		local instance = expiredNode.value
		local metadata = self._activeInstances[instance]
		if metadata and metadata.heapNode == expiredNode then
			metadata.heapNode = nil
			self._stats.leaseExpirations += 1
			pcall(function() self.OnLeaseExpired:Fire(instance, metadata.debugContext) end)
			self:Return(instance)
		end
	end
	if not forceSweep and self._autoShrinkDelay and self._lastReturnTime > 0 then
		if (now - self._lastReturnTime >= self._autoShrinkDelay) then
			if #self._idleInstances > self._initialSize then
				self:Shrink(self._initialSize)
			end
			self._lastReturnTime = 0
		end
	end
end

------------------------------------------------------------------------------------------------------------

-- Main Logic ----------------------------------------------------------------------------------------------

function FullPool.Create<T>(poolName: string, config: TypeDef.PoolConfig?):TypeDef.FullPool<T>
	if typeof(poolName) ~= "string" then
		Debugger:Throw("error", "Create", "poolName must be a string")
	end
	Pools._mutex:lock()
	config = config or {}
	config.name = poolName
	if Pools._map[poolName] and not Pools._map[poolName]._isDestroyed then
		local pool = Pools._map[poolName]
		if config.maxSize then pool:Resize(config.maxSize) end
		pool._templateInstance = config.templateInstance or pool._templateInstance
		pool._cleanupCallback = config.cleanupCallback or pool._cleanupCallback
		pool._validateCallback = config.validateCallback or pool._validateCallback
		pool._autoShrinkDelay = config.autoShrinkDelay or pool._autoShrinkDelay
		Pools._mutex:unlock()
		return pool
	end
	if not config.instanceType and not config.templateInstance then
		Pools._mutex:unlock()
		Debugger:Throw("error", "Create", "Either 'instanceType' or 'templateInstance' must be provided in the config for a new pool.")
	end
	local newPool = FullPool.new(config.instanceType, config)
	Pools._map[poolName] = newPool
	Pools._trie:insert(poolName, _stringToSequence(poolName), function() end)
	Pools._mutex:unlock()
	return newPool
end

function FullPool.GetPoolsByPattern(pattern: string): {FullPool}
	if typeof(pattern) ~= "string" then return {} end
	Pools._mutex:lock()
	local keys = _findKeysByGlobIterative(Pools._trie, pattern)
	local results = {}
	for _, key in ipairs(keys) do
		local pool = Pools._map[key]
		if pool and not pool._isDestroyed then
			table.insert(results, pool)
		end
	end
	Pools._mutex:unlock()
	return results
end

function FullPool.DestroyByPattern(pattern: string): number
	local poolsToDestroy = FullPool.GetPoolsByPattern(pattern)
	for _, pool in ipairs(poolsToDestroy) do
		pool:Destroy()
	end
	return #poolsToDestroy
end

function FullPool.PrefetchByPattern(pattern: string, countPerPool: number)
	local poolsToPrefetch = FullPool.GetPoolsByPattern(pattern)
	for _, pool in ipairs(poolsToPrefetch) do
		pool:Prefetch(countPerPool)
	end
	return #poolsToPrefetch
end

function FullPool.ShrinkByPattern(pattern: string, targetSize: number?)
	local poolsToShrink = FullPool.GetPoolsByPattern(pattern)
	for _, pool in ipairs(poolsToShrink) do
		pool:Shrink(targetSize)
	end
	return #poolsToShrink
end

function FullPool:Get(priority: TypeDef.PoolPriority?, debugContext: any?): Instance?
	if self._getRateLimiter and not self._getRateLimiter:consume() then
		Debugger:Throw("warn", "Get", ("Get() call rate-limited. Pool: %s")
			:format(self._name))
		return nil
	end
	if self._isDestroyed then
		Debugger:Throw("error", "Get", "Pool is destroyed.")
	end
	if self._isReadOnly then
		Debugger:Throw("error", "Get", "Pool is in read-only mode; operation ignored.")
	end
	priority = priority or "normal"
	self._lock:lock()
	local instance: Instance?
	while #self._idleInstances > 0 do
		instance = table.remove(self._idleInstances)
		local isValid = true
		if self._validateCallback then
			local success, result = pcall(self._validateCallback, instance)
			isValid = success and result
		end
		if isValid then
			self._stats.gets += 1
			self._stats.hits += 1
			pcall(function() self.OnHit:Fire(instance) end)
			break
		else
			self:_destroyInstance(instance, "ValidationFailed")
			instance = nil
		end
	end
	if not instance then
		local totalCount = #self._idleInstances + _getActiveCount(self._activeInstances)
		if totalCount < self._maxSize then
			instance = self:_createInstance()
			self._stats.gets += 1
			self._stats.misses += 1
			self._stats.creations += 1
			pcall(function() self.OnMiss:Fire() end)
			pcall(function() self.OnCreate:Fire(instance) end)
		else
			if priority == "low" then
				self._lock:unlock()
				return nil
			else
				self._lock:unlock()
				self.OnInstanceAvailable:Wait()
				return self:Get(priority, debugContext)
			end
		end
	end
	self._activeInstances[instance] = {
		retrievalTime = os.clock(), 
		isPinned = false, 
		debugContext = debugContext
	}
	pcall(function() self.OnGet:Fire(instance, debugContext) end)
	self._lock:unlock()
	return instance
end

function FullPool:Return(instance: Instance)
	if self._isDestroyed then
		Debugger:Throw("error", "Return", "Pool is destroyed.")
		return
	end
	if not instance then
		Debugger:Throw("warn", "Return", "Attempted to return a nil instance to the pool.")
		return
	end
	self._lock:lock()
	local meta = self._activeInstances[instance]
	if not meta then
		Debugger:Throw("warn", "Return", ("Attempted to return instance %s which is not active. It may have been returned already or was never properly leased.")
			:format(tostring(instance)))
		self._lock:unlock()
		return
	end
	if meta.heapNode then
		self._leaseHeap:delete(meta.heapNode)
		meta.heapNode = nil
	end
	if meta.isPinned then
		meta.isPinned = false
		self._stats.pinnedCount -= 1
	end
	self._activeInstances[instance] = nil
	self._stats.returns += 1
	local success, err = pcall(self._cleanupInstance, self, instance)
	if not success then
		Debugger:Throw("warn", "Return", ("Cleanup failed for instance %s: %s. Destroying instance.")
			:format(tostring(instance), tostring(err)))
		self:_destroyInstance(instance, "CleanupFailed")
		self._lock:unlock()
		return
	end
	local totalCount = #self._idleInstances + _getActiveCount(self._activeInstances)
	if totalCount >= self._maxSize then
		self:_destroyInstance(instance, "PoolAtCapacity")
	else
		table.insert(self._idleInstances, instance)
	end
	pcall(function() self.OnReturn:Fire(instance) end)
	self.OnInstanceAvailable:Fire()
	if self._autoShrinkDelay then
		self._lastReturnTime = os.clock()
	end
	self._lock:unlock()
end

function FullPool:ReturnBy(predicate: (instance: Instance) -> boolean):number
	if self._isDestroyed then 
		Debugger:Throw("error", "ReturnBy", "Pool is destroyed.") 
		return 0
	end
	if typeof(predicate) ~= "function" then
		Debugger:Throw("warn", "ReturnBy", ("Expected a function predicate, got: %s")
			:format(typeof(predicate)))
		return 0
	end
	local instancesToReturn = {}
	for instance, _ in pairs(self._activeInstances) do
		if predicate(instance) then
			table.insert(instancesToReturn, instance)
		end
	end
	if #instancesToReturn > 0 then
		self:BulkReturn(instancesToReturn)
	end
	return #instancesToReturn
end

function FullPool:GetWithLease(ttl: number, priority: PoolPriority?, debugContext: any?): Instance?
	if self._isDestroyed then 
		Debugger:Throw("error", "GetWithLease", "Pool is destroyed.") 
	end
	if self._isReadOnly then 
		Debugger:Throw("error", "GetWithLease", "Pool is in read-only mode; operation ignored.") 
	end
	if not (typeof(ttl) == "number" and ttl > 0) then
		Debugger:Throw("error", "GetWithLease", "ttl must be a positive number")
	end
	local instance = self:Get(priority, debugContext)
	if not instance then
		return nil
	end
	local metadata = self._activeInstances[instance]
	if metadata then
		metadata.leaseExpiry = os.clock() + ttl
		metadata.originalTTL = ttl
		metadata.heapNode = self._leaseHeap:insert(metadata.leaseExpiry, instance)
	end
	return instance
end

function FullPool:TryGet(): Instance?
	if self._getRateLimiter and not self._getRateLimiter:consume() then
		Debugger:Throw("warn", "TryGet", ("TryGet() call rate-limited. Pool: %s")
			:format(self._name))
		return nil
	end
	if self._isDestroyed then 
		Debugger:Throw("error", "TryGet", "Pool is destroyed.") 
	end
	if self._isReadOnly then
		Debugger:Throw("warn", "TryGet", "Pool is in read-only mode; operation ignored.")
	end
	self._lock:lock()
	local instance: Instance?
	while #self._idleInstances > 0 do
		instance = table.remove(self._idleInstances)
		local isValid = true
		if self._validateCallback then
			local success, result = pcall(self._validateCallback, instance)
			isValid = success and result
		end
		if isValid then
			self._stats.gets += 1
			self._stats.hits += 1
			pcall(function() self.OnHit:Fire(instance) end)
			break
		else
			self:_destroyInstance(instance, "ValidationFailed")
			instance = nil
		end
	end
	if instance then
		self._activeInstances[instance] = {retrievalTime = os.clock(), isPinned = false}
		pcall(function() self.OnGet:Fire(instance) end)
		self._lock:unlock()
		return instance
	end
	self._lock:unlock()
	return nil
end

function FullPool:Prefetch(count: number, onComplete: (() -> ())?)
	if self._isDestroyed then 
		Debugger:Throw("error", "Prefetch", "Pool is destroyed.") 
	end
	if self._isReadOnly then
		Debugger:Throw("warn", "Prefetch", "Pool is in read-only mode; operation ignored.")
	end
	if not (typeof(count) == "number" and count > 0) then
		Debugger:Throw("error", "Prefetch", "prefetch count must be a positive number")
	end
	task.spawn(function()
		local success, err = pcall(function()
			if self._isDestroyed or self._isReadOnly then return end
			for i = 1, count do
				if self._isDestroyed or self._isReadOnly then break end
				if #self._idleInstances + _getActiveCount(self._activeInstances) >= self._maxSize then break end
				local instance = self:_createInstance()
				self._stats.creations += 1
				pcall(function() self.OnCreate:Fire(instance) end)
				table.insert(self._idleInstances, instance)
				if i % 10 == 0 then
					task.wait()
				end
			end
		end)
		if not success then
			Debugger:Throw("warn", "Prefetch", ("Prefetch coroutine failed: %s")
				:format(tostring(err)))
		end
		if onComplete then
			pcall(onComplete)
		end
	end)
end

function FullPool:BulkGet(count: number, priority: TypeDef.PoolPriority?): {Instance}
	if self._isDestroyed then
		Debugger:Throw("error", "BulkGet", "Pool is destroyed.")
	end
	if self._isReadOnly then
		Debugger:Throw("error", "BulkGet", "Pool is in read-only mode; operation ignored.")
	end
	if not (typeof(count) == "number" and count > 0) then
		Debugger:Throw("error", "BulkGet", "BulkGet count must be a positive number")
	end
	local instances = {}
	for i = 1, count do
		local instance = self:Get(priority)
		if not instance then
			break
		end
		table.insert(instances, instance)
	end
	return instances
end

function FullPool:BulkReturn(instances:{Instance})
	if self._isDestroyed then
		Debugger:Throw("error", "BulkReturn", "Pool is destroyed.")
		return
	end
	if self._isDestroyed then
		for _, instance in ipairs(instances) do
			if typeof(instance) == "Instance" then
				instance:Destroy()
			end
		end
		return
	end
	self:Pause()
	local returnedCount = 0
	for _, instance in ipairs(instances) do
		local meta = self._activeInstances[instance]
		if meta then
			if meta.isPinned then
				meta.isPinned = false
				self._stats.pinnedCount -= 1
			end
			self._activeInstances[instance] = nil
			local success, err = pcall(self._cleanupInstance, self, instance)
			if not success then
				Debugger:Throw("warn", "BulkReturn", ("Cleanup failed for instance %s: %s. Destroying instance.")
					:format(tostring(instance), tostring(err)))
				self:_destroyInstance(instance, "CleanupFailed")
			else
				local totalCount = #self._idleInstances + _getActiveCount(self._activeInstances)
				if totalCount < self._maxSize then
					table.insert(self._idleInstances, instance)
				else
					self:_destroyInstance(instance, "PoolAtCapacity")
				end
				pcall(function() self.OnReturn:Fire(instance) end)
				returnedCount += 1
			end
		end
	end
	self._stats.returns += returnedCount
	self:Resume()
	for _ = 1, returnedCount do
		self.OnInstanceAvailable:Fire()
	end
	if self._autoShrinkDelay and returnedCount > 0 then
		self._lastReturnTime = os.clock()
	end
end

function FullPool:Resize(newMaxSize: number)
	if self._isDestroyed then 
		Debugger:Throw("error", "Resize", "Pool is destroyed.") 
	end
	if self._isReadOnly then 
		Debugger:Throw("error", "Resize", "Pool is in read-only mode; operation ignored.") 
	end
	if not (typeof(newMaxSize) == "number" and newMaxSize > 0) then
		Debugger:Throw("error","Resize", ("expected newMaxSize to be a positive number, got: %q %s")
			:format(typeof(newMaxSize),tostring(newMaxSize)))
	end
	local activeCount = _getActiveCount(self._activeInstances)
	if newMaxSize < activeCount then
		Debugger:Throw("error", "Resize", ("Cannot resize pool to %d, which is smaller than the current number of active instances (%d).")
			:format(newMaxSize, activeCount))
		return
	end
	self._maxSize = newMaxSize or DEFAULT_MAX_SIZE
	while #self._idleInstances + activeCount > newMaxSize do
		local instanceToDestroy = table.remove(self._idleInstances, 1)
		if instanceToDestroy then
			self:_destroyInstance(instanceToDestroy, "Resize")
		else
			break
		end
	end
end

function FullPool:ReadOnly(state: boolean)
	if self._isDestroyed then
		Debugger:Throw("error", "ReadOnly", "Pool is destroyed.")
	end
	if typeof(state) ~= "boolean" then
		Debugger:Throw("error", "ReadOnly", ("Expected state to be a boolean value, got type: %q")
			:format(typeof(state)))
	end
	self._isReadOnly = state
	if state then
		self:Pause()
	else
		self:Resume()
	end
end

function FullPool:Pause()
	if self._isDestroyed then
		Debugger:Throw("error", "Pause", "Pool is destroyed.")
		return
	end
	if self._isPaused then return end
	self._isPaused = true
end

function FullPool:Resume()
	if self._isDestroyed then
		Debugger:Throw("error", "Resume", "Pool is destroyed.")
		return
	end
	if not self._isPaused then 
		return
	end
	self._isPaused = false
end

function FullPool:Touch(instance: Instance, timeBoost: number?): boolean
	if self._isDestroyed then
		Debugger:Throw("error", "Return", "Pool is destroyed.")
		return
	end
	if self._isDestroyed or self._isReadOnly then 
		return false 
	end
	local metadata = self._activeInstances[instance]
	if not (metadata and metadata.originalTTL) then
		return false
	end
	if metadata.heapNode then
		self._leaseHeap:delete(metadata.heapNode)
	end
	metadata.leaseExpiry = os.clock() + metadata.originalTTL + (timeBoost or 0)
	metadata.heapNode = self._leaseHeap:insert(metadata.leaseExpiry, instance)
	return true
end

function FullPool:LeaseRemaining(instance: Instance): number?
	if self._isDestroyed or not self._activeInstances[instance] then
		return nil
	end
	local metadata = self._activeInstances[instance]
	if metadata and metadata.leaseExpiry then
		return math.max(0, metadata.leaseExpiry - os.clock())
	end
	return nil
end

function FullPool:Pin(instance: Instance): boolean
	if self._isDestroyed then
		Debugger:Throw("error", "Return", "Pool is destroyed.")
		return
	end
	if self._isReadOnly then
		Debugger:Throw("error", "Pin", "Pool is in read-only mode; operation ignored.")
	end
	local metadata = self._activeInstances[instance]
	if not metadata or metadata.isPinned then
		return false
	end
	if metadata.heapNode then
		self._leaseHeap:delete(metadata.heapNode)
		metadata.heapNode = nil
	end
	metadata.isPinned = true
	self._stats.pinnedCount += 1
	return true
end

function FullPool:Unpin(instance: Instance): boolean
	if self._isDestroyed then
		Debugger:Throw("error", "Return", "Pool is destroyed.")
		return
	end
	if self._isReadOnly then
		Debugger:Throw("error", "Unpin", "Pool is in read-only mode; operation ignored.")
	end
	local metadata = self._activeInstances[instance]
	if not metadata or not metadata.isPinned then
		return false
	end
	metadata.isPinned = false
	self._stats.pinnedCount -= 1
	if metadata.leaseExpiry then
		metadata.heapNode = self._leaseHeap:insert(metadata.leaseExpiry, instance)
	end
	return true
end

function FullPool:GetStats(): TypeDef.PoolStats
	if self._isDestroyed then 
		Debugger:Throw("error", "GetStats", "Pool is destroyed.") 
	end
	local totalGets = self._stats.gets
	local totalHits = self._stats.hits
	local idleCount = #self._idleInstances
	local activeCount = _getActiveCount(self._activeInstances)
	return {
		name = self._name,
		instanceType = self._instanceType,
		pooledCount = idleCount,
		activeCount = activeCount,
		pinnedCount = self._stats.pinnedCount,
		totalCount = idleCount + activeCount,
		maxSize = self._maxSize,
		memoryUsage = 0,
		memoryBudget = 0,
		memoryUsagePercent = 0,
		gets = totalGets,
		hits = totalHits,
		misses = self._stats.misses,
		hitRate = if totalGets > 0 then totalHits / totalGets else 0,
		creations = self._stats.creations,
		returns = self._stats.returns,
		evictions = self._stats.evictions,
		leaseExpirations = self._stats.leaseExpirations,
	}
end

function FullPool:PeekAllActive(): {Instance}
	if self._isDestroyed then 
		Debugger:Throw("warn", "Shrink", "Pool is destroyed.") 
		return {}
	end
	local active = {}
	for instance, _ in pairs(self._activeInstances) do
		table.insert(active, instance)
	end
	return active
end

function FullPool:PeekAllPooled(): {Instance}
	if self._isDestroyed then 
		Debugger:Throw("warn", "Shrink", "Pool is destroyed.")
		return {}
	end
	local pooled = {}
	for _, inst in ipairs(self._idleInstances) do
		table.insert(pooled, inst)
	end
	return pooled
end

function FullPool:Shrink(targetSize: number?)
	if self._isDestroyed then 
		Debugger:Throw("error", "Shrink", "Pool is destroyed.") 
	end
	targetSize = targetSize or self._initialSize
	if typeof(targetSize) ~= "number" then
		Debugger:Throw("error", "Shrink", "targetSize must be a number")
	end
	while #self._idleInstances > targetSize do
		local instanceToDestroy = table.remove(self._idleInstances)
		if instanceToDestroy then
			self:_destroyInstance(instanceToDestroy, "Shrink")
		else
			break
		end
	end
end

function FullPool:ManualSweep(options: {expireLeasesOnly: boolean?})
	if self._isDestroyed then 
		Debugger:Throw("error", "ManualSweep", "Pool is destroyed.")
	end
	if self._isReadOnly then
		Debugger:Throw("warn", "ManualSweep", "Pool is in read-only mode; operation ignored.")
		return 
	end
	options = options or {}
	self:_leaseServiceLoop(true)
	if not options.expireLeasesOnly then
		self:Shrink()
	end
end

function FullPool:Destroy()
	if self._isDestroyed then 
		Debugger:Throw("error", "Destroy", "Pool is destroyed.")
	end
	self._isDestroyed = true
	if self._leaseServiceConnection then
		self._leaseServiceConnection:Disconnect()
		self._leaseServiceConnection = nil
	end
	for instance, _ in pairs(self._activeInstances) do
		if typeof(instance) == "Instance" then
			instance:Destroy()
		end
	end
	for _, instance in ipairs(self._idleInstances) do
		if typeof(instance) == "Instance" then
			instance:Destroy()
		end
	end
	table.clear(self._activeInstances)
	table.clear(self._idleInstances)
	Pools._mutex:lock()
	if Pools._map[self._name] then
		Pools._map[self._name] = nil
		Pools._trie:remove(self._name, _stringToSequence(self._name))
	end
	Pools._mutex:unlock()
	self.OnGet:DisconnectAll()
	self.OnReturn:DisconnectAll()
	self.OnCreate:DisconnectAll()
	self.OnDestroy:DisconnectAll()
	self.OnLeaseExpired:DisconnectAll()
	self.OnMemoryChanged:DisconnectAll()
	self.OnInstanceAvailable:DisconnectAll()
	self.OnEvict:DisconnectAll()
	self.OnHit:DisconnectAll()
	self.OnMiss:DisconnectAll()
end

function FullPool:Snapshot(includeDescendants: boolean?): string?
	if self._isDestroyed then
		Debugger:Throw("error", "Snapshot", "Pool is destroyed.")
		return nil
	end
	local shouldIncludeDescendants = includeDescendants or false
	local snapshotData = {
		isFullState = shouldIncludeDescendants,
		instanceType = self._instanceType,
		maxSize = self._maxSize,
		initialSize = self._initialSize,
		getsPerSecond = self._getRateLimiter and self._getRateLimiter:getInfo().refillRate or nil,
		autoShrinkDelay = self._autoShrinkDelay,
		templateData = nil,
		serializedInstances = nil
	}
	if self._templateInstance then
		local templateSuccess, templateSerialized = pcall(Serializer.SerializeInstance, self._templateInstance, true)
		if templateSuccess and templateSerialized then
			snapshotData.templateData = templateSerialized
		else
			Debugger:Throw("warn", "Snapshot", ("Failed to serialize template instance %s: %s")
				:format(tostring(self._templateInstance), tostring(templateSerialized)))
		end
	end
	if shouldIncludeDescendants then
		snapshotData.serializedInstances = {}
		local idleInstances = self:PeekAllPooled()
		for _, instance in ipairs(idleInstances) do
			local success, serializedData = pcall(Serializer.SerializeInstance, instance, true)
			if success and serializedData then
				table.insert(snapshotData.serializedInstances, serializedData)
			else
				Debugger:Throw("warn", "Snapshot", ("Failed to serialize pooled instance %s: %s")
					:format(tostring(instance), tostring(serializedData)))
			end
		end
	end
	local encodeSuccess, jsonData = pcall(HttpService.JSONEncode, HttpService, snapshotData)
	if encodeSuccess then
		return jsonData
	else
		Debugger:Throw("error", "Snapshot", ("Failed to JSONEncode snapshot data: %s")
			:format(tostring(jsonData)))
		return nil
	end
end

function FullPool.FromSnapshot(snapshotString: string): TypeDef.FullPool?
	local success, data = pcall(HttpService.JSONDecode, HttpService, snapshotString)
	if not success or typeof(data) ~= "table" then
		Debugger:Throw("error", "FromSnapshot", ("Invalid or corrupt snapshot string: %s")
			:format(tostring(data)))
		return nil
	end
	local templateInstance: Instance?
	if data.templateData then
		local templateSuccess, deserializedTemplate = pcall(Serializer.DeserializeInstance, data.templateData)
		if templateSuccess and deserializedTemplate then
			templateInstance = deserializedTemplate
		else
			Debugger:Throw("warn", "FromSnapshot", ("Failed to deserialize template instance from snapshot: %s")
				:format(tostring(deserializedTemplate)))
		end
	end
	local config: TypeDef.PoolConfig = {
		maxSize = data.maxSize,
		initialSize = 0,
		instanceType = templateInstance and templateInstance.ClassName or data.instanceType,
		templateInstance = templateInstance,
		getsPerSecond = data.getsPerSecond,
		autoShrinkDelay = data.autoShrinkDelay,
	}
	if not config.instanceType then
		Debugger:Throw("error", "FromSnapshot", "Could not determine instanceType from snapshot data or template.")
		return nil
	end
	local poolName = ("Pool-FromSnapshot-%s")
		:format(HttpService:GenerateGUID(false))
	local newPool = FullPool.Create(poolName, config)
	if not newPool then
		Debugger:Throw("error", "FromSnapshot", "Failed to create new pool instance during restoration.")
		return nil
	end
	if data.isFullState and data.serializedInstances then
		newPool:Pause()
		local restoredCount = 0
		for _, instanceData in ipairs(data.serializedInstances) do
			if _getActiveCount(newPool._activeInstances) + #newPool._idleInstances >= newPool._maxSize then
				Debugger:Throw("warn", "FromSnapshot", "Reached maxSize during instance restoration. Skipping remaining instances.")
				break
			end
			local instanceSuccess, instance = pcall(Serializer.DeserializeInstance, instanceData)
			if instanceSuccess and instance then
				table.insert(newPool._idleInstances, instance)
				restoredCount += 1
			else
				Debugger:Throw("warn", "FromSnapshot", ("Failed to deserialize an instance from data: %s")
					:format(tostring(instance)))
			end
		end
		newPool:Resume()
		Debugger:Throw("print", "FromSnapshot", ("Restored %d idle instances into pool '%s'")
			:format(restoredCount, poolName))
	end
	return newPool
end
FullPool.Version = VERSION; FullPool.Registry = Pools._map
------------------------------------------------------------------------------------------------------------
return Debugger:Profile(FullPool, "Create", script) :: TypeDef.Static
