--!optimize 2
--[[
	AUTHOR: Kel (@GudEveningBois)

	Created:
	6/23/25
	6:40 PM UTC+9
	
	No documentary yet
]]
local VERSION = "0.0.1 (BETA)"
-- Dependencies
local TypeDef = require(script.TypeDef)
local Signal = require(script.Parent.Parent.Components.KelSignal) 
local Debugger = require(script.Parent.Parent.Components.Debugger).From(script.Name)

local LitePool = {}
LitePool.__index = LitePool

-- Services
local HttpService = game:GetService("HttpService")

local Pools = {}
local DEFAULT_MAX_SIZE = 50
local DEFAULT_INITIAL_SIZE = 5
local DEFAULT_POLICY = "LRU"

-- Helper functions ----------------------------------------------------------------------------------------
-- Since these are helper functions, do not use any of these externally.
-- (The helper methods are "usually" named with an underscore, AKA '_')

function LitePool:lock()
	while self._lock.isLocked do
		local thread = coroutine.running()
		table.insert(self._lock.queue, thread)
		coroutine.yield()
	end
	self._lock.isLocked = true
end
function LitePool:unlock()
	if #self._lock.queue > 0 then
		task.spawn(table.remove(self._lock.queue, 1))
	else
		self._lock.isLocked = false
	end
end

function LitePool.new(instanceType: string, config: TypeDef.PoolConfig?): TypeDef.LitePool
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
	local self = setmetatable({}, LitePool)
	self._instanceType = instanceType
	self._templateInstance = config.templateInstance
	self._cleanupCallback = config.cleanupCallback
	self._lock = {isLocked = false, queue = {}}
	self._maxSize = config.maxSize or DEFAULT_MAX_SIZE
	self._initialSize = config.initialSize or DEFAULT_INITIAL_SIZE
	self._isDestroyed = false
	self._name = config.name or ("LitePool<%s>:%s")
		:format(instanceType, HttpService:GenerateGUID(false))
	self.Name = self._name
	self.InstanceType = self._instanceType
	self.OnGet = Signal.new()
	self.OnReturn = Signal.new()
	self.OnCreate = Signal.new()
	self.OnDestroy = Signal.new()
	self.OnInstanceAvailable = Signal.new()
	self._activeInstances = {}
	self._idleInstances = {}
	self._activeCount = 0
	self:_warmupPool(self._initialSize)
	return self
end

function LitePool:_createInstance(): Instance
	local instance
	if self._templateInstance then
		instance = self._templateInstance:Clone()
	else
		instance = Instance.new(self._instanceType)
	end
	instance.Parent = nil
	self.OnCreate:Fire(instance)
	return instance
end

function LitePool:_destroyInstance(instance: Instance, reason: string)
	if typeof(instance) == "Instance" and instance.Parent then
		instance:Destroy()
	end
	self.OnDestroy:Fire(instance, reason)
end

function LitePool:_cleanupInstance(instance: Instance)
	instance.Parent = nil
	if self._cleanupCallback then
		pcall(self._cleanupCallback, instance)
	end
end

function LitePool:_warmupPool(count)
	if count <= 0 then return end
	for i = 1, count do
		if self._activeCount + #self._idleInstances >= self._maxSize then
			break
		end
		local instance = self:_createInstance()
		table.insert(self._idleInstances, instance)
	end
end

------------------------------------------------------------------------------------------------------------

-- Main Logic ----------------------------------------------------------------------------------------------

function LitePool.Create<T>(poolName: string, config: TypeDef.PoolConfig?):TypeDef.LitePool<T>
	if typeof(poolName) ~= "string" then
		Debugger:Throw("error", "Create", "poolName must be a string")
	end
	config = config or {}
	config.name = poolName
	if Pools[poolName] and not Pools[poolName]._isDestroyed then
		local pool = Pools[poolName]
		if config.maxSize then 
			pool._maxSize = config.maxSize
		end
		return pool
	end
	if not config.instanceType and not config.templateInstance then
		Debugger:Throw("error", "Create", "Either 'instanceType' or 'templateInstance' must be provided in the config for a new pool.")
	end
	local newPool = LitePool.new(config.instanceType, config)
	Pools[poolName] = newPool
	return newPool
end

function LitePool:Get(): Instance
	if self._isDestroyed then
		Debugger:Throw("error", "Get", "Pool is destroyed.")
	end
	self:lock()
	local instance: Instance?
	local totalCount = self._activeCount + #self._idleInstances
	if #self._idleInstances > 0 then
		instance = table.remove(self._idleInstances)
	elseif totalCount < self._maxSize then
		instance = self:_createInstance()
	else
		self:unlock()
		self.OnInstanceAvailable:Wait()
		return self:Get()
	end
	self._activeInstances[instance] = true
	self._activeCount += 1
	pcall(function() self.OnGet:Fire(instance) end)
	self:unlock()
	return instance
end

function LitePool:Return(instance: Instance)
	if self._isDestroyed then
		if typeof(instance) == "Instance" then
			self:_destroyInstance(instance, "PoolDestroyed")
		end
		return
	end
	self:lock()
	if not self._activeInstances[instance] then
		Debugger:Throw("warn", "Return", "Attempted to return an instance that was not active or does not belong to this pool.")
		self:unlock()
		return
	end
	self._activeInstances[instance] = nil
	self._activeCount -= 1
	self:_cleanupInstance(instance)
	if self._activeCount + #self._idleInstances >= self._maxSize then
		self:_destroyInstance(instance, "PoolAtCapacity")
	else
		table.insert(self._idleInstances, instance)
	end
	pcall(function() self.OnReturn:Fire(instance) end)
	self.OnInstanceAvailable:Fire()
	self:unlock()
end

function LitePool:Destroy()
	if self._isDestroyed then return end
	self._isDestroyed = true
	for instance, _ in pairs(self._activeInstances) do
		self:_destroyInstance(instance, "PoolDestroyed")
	end
	for _, instance in ipairs(self._idleInstances) do
		self:_destroyInstance(instance, "PoolDestroyed")
	end
	table.clear(self._activeInstances)
	table.clear(self._idleInstances)
	self._activeCount = 0
	if Pools[self._name] then
		Pools[self._name] = nil
	end
	self.OnGet:DisconnectAll()
	self.OnReturn:DisconnectAll()
	self.OnCreate:DisconnectAll()
	self.OnDestroy:DisconnectAll()
	self.OnInstanceAvailable:DisconnectAll()
	table.clear(self)
	setmetatable(self, nil)
end
LitePool.Version = VERSION
LitePool.new = LitePool.Create
------------------------------------------------------------------------------------------------------------
return LitePool :: TypeDef.Static
