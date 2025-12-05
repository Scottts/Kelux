--!optimize 2
--[[
	AUTHOR: Kel (@GudEveningBois)
	
	Created:
		5/1/25
		11:10 PM UTC+9
	
	The lite version of FullCache.
	Read documentation in LiteCache.Document
]]
local VERSION = "0.4.0 (BETA)"
-- Dependencies
local TypeDef = require(script.TypeDef)
local Mutex = require(script.Parent.Parent.Components.Mutex)
local Debugger = require(script.Parent.Parent.Components.Debugger)
local Signal = require(script.Parent.Parent.Components.KelSignal)
local TTL = require(script.Parent.Parent.Components.TTLService)

-- Algorithms
local Algorithms = script.Parent.Parent.Components.Algorithms
local Trie = require(Algorithms.Trie)

-- Cache Registry
local Cache = {}
local createMutex = Mutex.new()
local PolicyLocation = script.Parent.Parent.Components.Policies 
local Policies = {
	FIFO = require(PolicyLocation.FIFO),		-- First In, First Out
	LRU = require(PolicyLocation.LRU),			-- Least Recently Used
	LFU = require(PolicyLocation.LFU),			-- Least Frequently Used
	RR = require(PolicyLocation.RR),			-- Random Replacement
	ARC = require(PolicyLocation.ARC), 			-- Adaptive Replacement Cache
}

-- Default settings
local DefaultMax = 1000

local LiteCache = {}
LiteCache.__index = LiteCache

local tableIDs = setmetatable({}, {__mode = "k"})
local idToTable = {}
local nextID = 0

-- Helper functions ----------------------------------------------------------------------------------------

local function _dictSize(d)
	local n = 0
	for _ in pairs(d) do 
		n += 1
	end
	return n
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

-- Trie Helpers
local function stringToSequence(str)
	local seq = {}
	for i = 1, #str do
		table.insert(seq, string.sub(str, i, i))
	end
	return seq
end

-- [[Internal eviction/removal]]

function LiteCache:_RemoveInternal(key:string, expired:boolean)
	local entry = self._dict[key]
	if not entry then
		return
	end
	if type(key) == "string" then
		self._keyTrie:remove(key, stringToSequence(key))
	end
	self._metrics.evictions += 1

	if self._policy.remove then
		self._policy:remove(key)
	end
	self._dict[key] = nil
	self._ttl:invalidate(key)
	self._evictSignal:Fire({kind = "dict", key = key, value = entry.value, expired = expired})
end

-- [[Policy Internals]]

function LiteCache:_setPolicy(opts)
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
end

-- [[Internals]]
function LiteCache:_setInternal(key, value)
	local realKey = normalizeKey(key)
	-- No serialization, no memory checking. Pure storage.
	local entry = {value = value}

	self._dict[realKey] = entry
	local evictedKey = self._policy:insert(realKey)
	if evictedKey and evictedKey ~= realKey then
		self:_RemoveInternal(evictedKey, false)
	end
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
	self._dict = {}
	self._ttl:stop()

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

function LiteCache.Create<T>(CacheName:string, MaxObjects:number?, Opts:{Mode:string, Policy:string}?):LiteCache<T>
	createMutex:lock()
	local success, result = pcall(function()
		if typeof(CacheName) ~= "string" then
			Debugger:Throw("error","Create", ("invalid CacheName (%s); expected a string")
				:format(typeof(CacheName)))
		end
		if MaxObjects and typeof(MaxObjects) ~= "number" then
			Debugger:Throw("error","Create", ("invalid MaxObjects (%s); expected a positive integer")
				:format(CacheName, tostring(MaxObjects)))
		end

		local opts = Opts or {}
		local maxObjs = MaxObjects or DefaultMax

		-- Registry Check
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

			-- Evict until under the new limit
			while _dictSize(cache._dict) > maxObjs do
				local victim = cache._policy.evict and cache._policy:evict()
				if not victim then break end
				cache:_RemoveInternal(victim, false)
			end

			-- Restart policy and TTL
			cache:_setPolicy(opts)
			cache._ttl:start()
			return cache
		end

		-- Create new cache
		local self = setmetatable({
			_name  = CacheName,
			_dict = {},
			_mutex = Mutex.new(),
			_maxobj = maxObjs,
			_ttl = nil,
			_policy = nil,
			_metrics = {hits = 0, misses = 0, evictions = 0}, -- Renamed to _metrics to match internal usage
			_evictSignal = Signal.new(),
			_keyTrie = Trie.new(),
			_destroyed = false,
		}, LiteCache)

		Cache[CacheName] = self
		self._ttl = TTL.new(self)
		self:_setPolicy(opts)
		self._ttl:start()

		return self
	end)
	createMutex:unlock()
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
	self._mutex:lock()
	local success, result = pcall(function()
		self._ttl:stop()
	end)
	self._mutex:unlock()
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
	self._mutex:lock()
	local success, result = pcall(function()
		self._ttl:start()
	end)
	self._mutex:unlock()
	if not success then
		error(result)
	end
	return result
end

------------------------------------------------------------------------------------------------------------

-- Key Access (Map Methods) --------------------------------------------------------------------------------

function LiteCache:Set(key: string, value: any, ttl: number?)
	self._mutex:lock()
	local realKey = normalizeKey(key)
	local entry = {value = value}
	if ttl then
		entry.expires = os.time() + ttl
		self._ttl:push(realKey, entry.expires)
	end
	self._dict[realKey] = entry
	local evicted = self._policy:insert(realKey)
	if evicted then 
		self:_RemoveInternal(evicted, false) 
	end
	self._mutex:unlock()
end

function LiteCache:Get(key: string | {any}): any?
	self._mutex:lock()
	self._ttl:_expireLoop() 
	local realKey = normalizeKey(key)
	local entry = self._dict[realKey]
	if not entry then
		self._metrics.misses = (self._metrics.misses or 0) + 1
		self._mutex:unlock()
		return nil
	end
	if entry.expires and os.time() > entry.expires then
		self:_RemoveInternal(realKey, true)
		self._metrics.misses = (self._metrics.misses or 0) + 1
		self._mutex:unlock()
		return nil
	end
	self._metrics.hits = (self._metrics.hits or 0) + 1
	self._policy:access(realKey)
	self._mutex:unlock()
	return entry.value
end

function LiteCache:GetOrSet(key: string, callback: () -> any, ttl: number?): any
	self._mutex:lock()
	self._ttl:_expireLoop()
	local realKey = normalizeKey(key)
	local entry = self._dict[realKey]
	if entry and (not entry.expires or os.time() <= entry.expires) then
		self._metrics.hits = (self._metrics.hits or 0) + 1
		self._policy:access(realKey)
		self._mutex:unlock()
		return entry.value
	end
	self._metrics.misses = (self._metrics.misses or 0) + 1
	local success, newValue = pcall(callback)
	if not success then
		self._mutex:unlock()
		error(newValue)
	end
	local newEntry = {value = newValue}
	if ttl then
		newEntry.expires = os.time() + ttl
		self._ttl:push(realKey, newEntry.expires)
	end
	self._dict[realKey] = newEntry
	local evicted = self._policy:insert(realKey)
	if evicted then 
		self:_RemoveInternal(evicted, false) 
	end
	self._mutex:unlock()
	return newValue
end

function LiteCache:Has(key:string|{any}):boolean
	if self._destroyed then
		Debugger:Throw("error", "Has", "Attempt to use a destroyed cache instance.")
		return
	end
	self._mutex:lock()
	local success, result = pcall(self._hasInternal, self, key)
	self._mutex:unlock()
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
	self._mutex:lock()
	local success, result = pcall(function()
		self._ttl:_expireLoop()
		local realKey = normalizeKey(key)
		self:_RemoveInternal(realKey, false)
	end)
	self._mutex:unlock()
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
	self._mutex:lock()
	local success, result = pcall(self._clearInternal, self)
	self._mutex:unlock()
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
	self._mutex:lock()
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
		self._dict = nil
		self._policy = nil
		self._metrics = nil
	end)
	self._mutex:unlock()
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
	self._mutex:lock()
	local success, result = pcall(function()
		local realKey = normalizeKey(key)
		-- Raw Storage
		local entry = {value = value}

		entry.expires = os.time() + ttl
		self._dict[realKey] = entry
		self._ttl:push(realKey, entry.expires)

		local evicted = self._policy:insert(realKey)
		if evicted then self:_RemoveInternal(evicted, false) end

		return value
	end)
	self._mutex:unlock()
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
	self._mutex:lock()
	local success, result = pcall(function()
		local realKey = normalizeKey(key)
		local entry = self._dict[realKey]
		if entry and entry.expires then
			return math.max(0, entry.expires - os.time())
		end
		return nil
	end)
	self._mutex:unlock()
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
	self._mutex:lock()
	local success, result = pcall(function()
		local realKey = normalizeKey(key)
		local entry = self._dict[realKey]
		if entry and (not entry.expires or os.time() <= entry.expires) then
			return entry.value
		end
		return nil
	end)
	self._mutex:unlock()
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
	self._mutex:lock()
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
	self._mutex:unlock()
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
	self._mutex:lock()
	local success, result = pcall(function()
		self._ttl:_expireLoop()
		local out = {}
		for internalID, entry in pairs(self._dict) do
			if not entry.expires or os.time() <= entry.expires then
				table.insert(out, entry.value)
			end
		end
		return out
	end)
	self._mutex:unlock()
	if not success then
		error(result)
	end
	return result
end
LiteCache.Version = VERSION
------------------------------------------------------------------------------------------------------------
return LiteCache :: TypeDef.Static