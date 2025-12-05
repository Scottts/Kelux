--!optimize 2
--[[
	AUTHOR: Kel (@GudEveningBois)

	Created:
	10/25/25
	7:36 PM UTC+9
	
	Read documentary in FullBus.Documentary
]]
local VERSION = "VERSION: 0.1.758 (STABLE)"
-- Dependencies
-- Adjust all of these positions if used elsewhere...
local TypeDef = require(script.TypeDef)
local HttpService = game:GetService("HttpService")
local Components = script.Parent.Parent.Components
local Debugger = require(Components.Debugger).From(script.Name)
local Signal = require(Components.KelSignal)

-- Algorithms
local Mutex = require(Components.Mutex)
local BPlusTree = require(Components.Algorithms.BplusTree)
local RadixTree = require(Components.Algorithms.RadixTree)
local HyperLogLog = require(Components.Algorithms.HyperLogLog)
local IntervalTree = require(Components.Algorithms.IntervalTree)
local LazyPropagation = require(Components.Algorithms.LazyPropagation)
local TokenBucket = require(Components.Algorithms.TBA)
local SplayTree = require(Components.Algorithms.SplayTree)
local MerkleTree = require(Components.Algorithms.MerkleTree)
local BloomFilter = require(Components.Algorithms.BloomFilter)
local xxHash = require(Components.Algorithms.xxHash)
local LZ4 = require(Components.Algorithms.LZ4)

local Buses = {}
local createMutex = Mutex.new()

local FullBus = {}
FullBus.__index = FullBus

-- Default settings
local DefaultConfig = {
	EnableDebug = false,
	MaxListenersPerEvent = 100,
	EnableWildcards = true,
	AsyncByDefault = true,
	StatsPrecision = 12,
	TimelineSize = 1000,
	HistoryTreeOrder = 5,
	EnableDeduplication = false,
	DeduplicationCacheSize = 100,
	DeduplicationCmsEpsilon = 0.01,
	DeduplicationCmsDelta = 0.001,
}

-- Helper functions ----------------------------------------------------------------------------------------

local function _debugLog(self:FullBus, method:string, message:string)
	if self._config.EnableDebug then
		Debugger:Throw("warn", method, message)
	end
end

local function _matchesPattern(self:FullBus, pattern:string, eventName:string):boolean
	if not self._config.EnableWildcards or pattern == eventName then
		return pattern == eventName
	end
	local luaPattern = "^"..pattern:gsub("%.", "%%."):gsub("%*", ".*").."$"
	return eventName:match(luaPattern) ~= nil
end

local function _sortByPriority(connections:{Connection})
	table.sort(connections, function(a, b)
		return a.Priority > b.Priority
	end)
end

local function _safeCall(self:FullBus, callback:Callback, eventName:string, ...:any)
	local args = {...}
	local success, err = pcall(function() callback(table.unpack(args)) end)
	if not success then
		local errStr = tostring(err)
		Debugger:Throw("warn","SafeCall", ("Error in subscriber for '%s':%s")
			:format(eventName, errStr))
		self:_queueEvent(self._errorSignal, eventName, callback, errStr, args)
	end
end

local function _tryCallMethod(obj, names, ...)
	if type(obj) ~= "table" then return false end
	local args = {...}
	for _, name in ipairs(names) do
		local fn = obj[name]
		if type(fn) == "function" then
			local ok = pcall(function() 
				fn(obj, table.unpack(args)) end)
			if ok then
				return true
			end
			ok = pcall(function() fn(table.unpack(args)) end)
			if ok then
				return true
			end
		end
	end
	return false
end

local LOCK_NAMES = {"lock", "Lock", "acquire", "Acquire"}
local UNLOCK_NAMES = {"unlock", "Unlock", "release", "Release"}

function FullBus:_acquireLock()
	_tryCallMethod(self._lock, LOCK_NAMES)
end

function FullBus:_releaseLock()
	_tryCallMethod(self._lock, UNLOCK_NAMES) 
	if #self._eventQueue > 0 then
		local eventsToFire = self._eventQueue
		self._eventQueue = {}
		for _, eventData in ipairs(eventsToFire) do
			pcall(eventData.Signal.Fire, eventData.Signal, table.unpack(eventData.Args))
		end
	end
end

local function _serializeEvent(eventName:string, args:{any}):string
	local parts = {eventName}
	for _, v in ipairs(args) do
		table.insert(parts, tostring(v))
	end
	local rawKey = table.concat(parts, "::")
	return xxHash.hash32Hex(rawKey)
end

function FullBus:_getSecondsToday()
	local t = os.date("*t")
	return t.hour * 3600 + t.min * 60 + t.sec
end

local function _disconnectInternal(connection:Connection)
	if not connection.Connected then return end
	connection.Connected = false
	local eventSubs = connection._bus._subscribers[connection.EventName]
	if eventSubs then
		for i = #eventSubs, 1, -1 do
			if eventSubs[i] == connection then
				table.remove(eventSubs, i)
				_debugLog(connection._bus, "Disconnect", ("Disconnected from '%s'")
					:format(connection.EventName))
				if connection._bus._config.EnableWildcards then
					connection._bus._wildcardMatchCache:Clear()
				end
				connection._bus:_queueEvent(connection._bus._disconnectSignal, connection.EventName, connection)
				break
			end
		end
		if #eventSubs == 0 then
			connection._bus._subscribers[connection.EventName] = nil
		end
	end
end

function FullBus:_serializeArgs(args:{any}):string?
	local jsonString
	local ok, err = pcall(function()
		jsonString = HttpService:JSONEncode(args)
	end)
	if not ok then
		Debugger:Throw("warn", "_serializeArgs", "Failed to JSONEncode arguments: "..tostring(err))
		return nil
	end
	local compressedString
	local ok, compressErr = pcall(function()
		compressedString = LZ4.compress(jsonString)
	end)
	if not ok then
		Debugger:Throw("warn", "_serializeArgs", "Failed to LZ4 compress arguments: "..tostring(compressErr))
		return nil
	end
	return compressedString
end

function FullBus:_deserializeArgs(compressedString:string):{any}?
	local jsonString
	local ok, decompressErr = pcall(function()
		jsonString = LZ4.decompress(compressedString)
	end)
	if not ok then
		Debugger:Throw("warn", "_deserializeArgs", "Failed to LZ4 decompress arguments: "..tostring(decompressErr))
		return nil
	end
	local args
	local ok, decodeErr = pcall(function()
		args = HttpService:JSONDecode(jsonString)
	end)
	if not ok then
		Debugger:Throw("warn", "_deserializeArgs", "Failed to JSONDecode arguments: "..tostring(decodeErr))
		return nil
	end
	return args
end

function FullBus:_queueEvent(signalInstance, ...)
	if not self._destroyed then
		table.insert(self._eventQueue, {Signal = signalInstance, Args = {...}})
	end
end

-- Main Logic ----------------------------------------------------------------------------------------------

function FullBus.Create(BusName:string, Opts:CreateOpts?):FullBus
	createMutex:lock()
	local opts = Opts or {}
	if type(BusName) == "table" and Opts == nil then
		opts = BusName
		BusName = "Unnamed_Bus_"..HttpService:GenerateGUID(false)
	elseif type(BusName) ~= "string" then
		BusName = "Unnamed_Bus_"..HttpService:GenerateGUID(false)
	end
	if Buses[BusName] and not Buses[BusName]._destroyed then
		createMutex:unlock()
		return Buses[BusName]
	end
	local lockObj
	local ok, res = pcall(function()
		if Mutex and type(Mutex.new) == "function" then
			return Mutex.new()
		end
		return nil
	end)
	if ok and res then
		lockObj = res
	else
		lockObj = {
			lock = function() end,
			unlock = function() end,
			destroy = function() end,
		}
	end
	-- Apply default configs
	local config = {
		EnableDebug = if opts.EnableDebug ~= nil then
			opts.EnableDebug else DefaultConfig.EnableDebug,
		MaxListenersPerEvent = opts.MaxListenersPerEvent or
			DefaultConfig.MaxListenersPerEvent,
		EnableWildcards = if opts.EnableWildcards ~= nil then
			opts.EnableWildcards else DefaultConfig.EnableWildcards,
		AsyncByDefault = if opts.AsyncByDefault ~= nil then
			opts.AsyncByDefault else DefaultConfig.AsyncByDefault,
		StatsPrecision = opts.StatsPrecision or DefaultConfig.StatsPrecision,
		TimelineSize = opts.TimelineSize or DefaultConfig.TimelineSize,
		HistoryTreeOrder = opts.HistoryTreeOrder or DefaultConfig.HistoryTreeOrder,
		EnableDeduplication = if opts.EnableDeduplication ~= nil then
			opts.EnableDeduplication else DefaultConfig.EnableDeduplication,
		DeduplicationCacheSize = opts.DeduplicationCacheSize or
			DefaultConfig.DeduplicationCacheSize,
		DeduplicationCmsEpsilon = opts.DeduplicationCmsEpsilon or
			DefaultConfig.DeduplicationCmsEpsilon,
		DeduplicationCmsDelta = opts.DeduplicationCmsDelta or
			DefaultConfig.DeduplicationCmsDelta,
	}
	local self = setmetatable({
		_name = BusName,
		-- State
		_subscribers = {},
		_middleware = {},
		_eventHistory = {},
		_destroyed = false,
		_readOnly = false,
		_stickyCache = {},
		_allSubscribers = {},
		_childBuses = {},
		_replyCounter = 0,
		-- Config
		_config = config,
		_lock = lockObj,
		_wildcardMatchCache = SplayTree.new(),
		_wildcardPatternsDirty = false,
		_eventHistoryLog = BPlusTree.new(config.HistoryTreeOrder),
		_prefixSubscribers = RadixTree.new(),
		_hllUniqueEvents = HyperLogLog.new(config.StatsPrecision),
		_intervalSubscribers = {},
		_eventCountTimeline = LazyPropagation.new(table.create(config.TimelineSize, 0), "sum"),
		_timelineTick = 0,
		_rateLimiters = {},
		_eventAuditLog = {},
		_lastAuditTree = nil,
		_deduplicationFilter = BloomFilter.new(
			config.DeduplicationCacheSize,
			config.DeduplicationCmsEpsilon
		),
		_eventQueue = {},
		_publishSignal = Signal.new(),
		_subscribeSignal = Signal.new(),
		_disconnectSignal = Signal.new(),
		_errorSignal = Signal.new(),
	}, FullBus)
	Buses[BusName] = self
	createMutex:unlock()
	_debugLog(self, "Create", "FullBus instance created: "..BusName)
	if config.EnableDeduplication then
		_debugLog(self, "Create", "BloomFilter Deduplication enabled with size "..config.DeduplicationCacheSize)
	end
	return self
end

function FullBus:Destroy()
	if self._readOnly then
		Debugger:Throw("warn", "Destroy", "Bus is in read-only mode; operation ignored.")
		return false
	end
	if self._destroyed then
		Debugger:Throw("error", "Destroy", "Attempt to use a destroyed bus instance.")
		return
	end
	self:_acquireLock()
	if self._destroyed then
		self:_releaseLock()
		return
	end
	createMutex:lock()
	if Buses[self._name] == self then
		Buses[self._name] = nil
	end
	createMutex:unlock()
	self:_clearAllInternal()
	table.clear(self._middleware)
	table.clear(self._eventHistory)
	table.clear(self._allSubscribers)
	for _, childBus in ipairs(self._childBuses) do
		if childBus and not childBus._destroyed then
			pcall(childBus.Destroy, childBus)
		end
	end
	table.clear(self._childBuses)
	self._wildcardMatchCache:Clear()
	self._prefixSubscribers:Clear()
	self._hllUniqueEvents:clear()
	self._eventCountTimeline:Clear()
	self._eventCountTimeline = LazyPropagation.new(table.create(self._config.TimelineSize, 0), "sum")
	self._eventHistoryLog = BPlusTree.new(self._config.HistoryTreeOrder)
	self._intervalSubscribers = {}
	self._rateLimiters = {}
	self._eventAuditLog = {}
	self._lastAuditTree = nil
	self._deduplicationFilter:Clear()
	self._destroyed = true
	_debugLog(self, "Destroy", "FullBus destroyed")
	if self._lock and type(self._lock) == "table" then
		local destroyNames = {"destroy", "Destroy"}
		for _, name in ipairs(destroyNames) do
			if type(self._lock[name]) == "function" then
				pcall(self._lock[name], self._lock)
				break
			end
		end
	end
	self:_releaseLock()
end

function FullBus:CreateSubscriptionGroup():SubscriptionGroup
	if self._destroyed then
		Debugger:Throw("warn", "CreateSubscriptionGroup", "Attempt to use a destroyed bus instance.")
	end
	local group:SubscriptionGroup = {
		_handles = {},
	}
	function group:Add(handle:DisconnectHandle):DisconnectHandle
		if handle and handle.Disconnect then
			table.insert(self._handles, handle)
		end
		return handle
	end
	function group:Destroy()
		for _, handle in ipairs(self._handles) do
			if handle and handle.Disconnect then
				pcall(handle.Disconnect, handle)
			end
		end
		table.clear(self._handles)
	end
	function group:Count():number
		return #self._handles
	end
	return group
end

function FullBus:Subscribe(eventName:string, callback:Callback, options:SubscribeOptions?):DisconnectHandle
	if self._readOnly then
		Debugger:Throw("warn", "Subscribe", "Bus is in read-only mode; operation ignored.")
		return false
	end
	if self._destroyed then
		Debugger:Throw("warn", "Subscribe", "Attempt to use a destroyed bus instance.")
		return
	end
	if type(eventName) ~= "string" or eventName == "" then
		Debugger:Throw("error", "Subscribe", "Event name must be a string")
		return
	end
	if type(callback) ~= "function" then
		Debugger:Throw("error", "Subscribe", "Callback must be a function")
		return
	end
	local opts = options or {}
	local connection:Connection
	self:_acquireLock()
	local success, result = pcall(function()
		if not self._subscribers[eventName] then
			self._subscribers[eventName] = {}
		end
		if #self._subscribers[eventName] >= self._config.MaxListenersPerEvent then
			Debugger:Throw("warn", "Subscribe", ("Max listeners (%d) reached for event '%s'")
					:format(self._config.MaxListenersPerEvent,eventName))
			return nil
		end
		connection = {
			Callback = callback,
			Priority = opts.Priority or 0,
			Once = opts.Once or false,
			Filter = opts.Filter,
			Connected = true,
			EventName = eventName,
			_bus = self,
		}
		table.insert(self._subscribers[eventName], connection)
		_sortByPriority(self._subscribers[eventName])
		if self._config.EnableWildcards then
			self._wildcardMatchCache:Clear()
			_debugLog(self, "Subscribe", "Subscriber added, clearing SplayTree cache.")
		end
		_debugLog(self, "Subscribe", ("Subscribed to '%s'(Priority:%d, Once:%s)")
			:format(eventName,connection.Priority,tostring(connection.Once)))
		local handle = {}
		handle.Disconnect = function()
			self:Disconnect(connection)
		end
		if opts.Group and opts.Group.Add then
			opts.Group:Add(handle)
		end
		self:_queueEvent(self._subscribeSignal, eventName, connection)
		return handle
	end)
	self:_releaseLock()
	if success and connection and not connection.Once then
		local stickyData = self._stickyCache[eventName]
		if stickyData and stickyData.CompressedArgs then
			local decompressedArgs = self:_deserializeArgs(stickyData.CompressedArgs)
			if not decompressedArgs then
				Debugger:Throw("error", "Subscribe", "Failed to decompress sticky event: "..eventName)
				return result
			end
			local callFunc = function()
				_safeCall(self, connection.Callback, eventName, table.unpack(decompressedArgs))
			end
			if self._config.AsyncByDefault then
				task.spawn(callFunc)
			else
				pcall(callFunc)
			end
			_debugLog(self, "Subscribe", ("Replayed sticky event '%s' to new subscriber.")
				:format(eventName))
		end
	end
	if not success then
		Debugger:Throw("error", "Subscribe", "Internal failure:"..tostring(result))
	end
	return result
end

function FullBus:SubscribeOnce(eventName:string, callback:Callback, options:SubscribeOptions?):DisconnectHandle
	if self._readOnly then
		Debugger:Throw("warn", "SubscribeOnce", "Bus is in read-only mode; operation ignored.")
		return false
	end
	local opts = options or {}
	opts.Once = true
	return self:Subscribe(eventName, callback, opts)
end

function FullBus:SubscribeByPrefix(prefix:string, callback:Callback, options:SubscribeOptions?):DisconnectHandle
	if self._readOnly then
		Debugger:Throw("warn", "SubscribeByPrefix", "Bus is in read-only mode; operation ignored.")
		return false
	end
	if self._destroyed then
		Debugger:Throw("warn", "SubscribeByPrefix", "Attempt to use a destroyed bus instance.")
		return
	end
	local opts = options or {}
	local connection:Connection
	self:_acquireLock()
	connection = {
		Callback = callback,
		Priority = opts.Priority or 0,
		Once = opts.Once or false,
		Filter = opts.Filter,
		Connected = true,
		EventName = prefix,
		_bus = self,
	}
	local connections = self._prefixSubscribers:Search(prefix) or {}
	table.insert(connections, connection)
	self._prefixSubscribers:Insert(prefix, connections)
	_debugLog(self, "SubscribeByPrefix", ("Subscribed to prefix '%s'")
		:format(prefix))
	local handle = {}
	handle.Disconnect = function()
		if not connection or not connection.Connected then return end
		if connection._bus._destroyed then return end
		connection._bus:_acquireLock()
		connection.Connected = false
		local eventSubs = connection._bus._prefixSubscribers:Search(connection.EventName)
		if eventSubs then
			for i = #eventSubs, 1, -1 do
				if eventSubs[i] == connection then
					table.remove(eventSubs, i)
					_debugLog(connection._bus, "SubscribeByPrefix", ("Disconnected from prefix '%s'")
						:format(connection.EventName))
					connection._bus:_queueEvent(connection._bus._disconnectSignal, connection.EventName, connection)
					break
				end
			end
			if #eventSubs == 0 then
				connection._bus._prefixSubscribers:Delete(connection.EventName)
			end
		end
		self:_queueEvent(self._subscribeSignal, connection)
		connection._bus:_releaseLock()
	end
	if opts.Group and opts.Group.Add then
		opts.Group:Add(handle)
	end
	self:_queueEvent(self._subscribeSignal, prefix, connection)
	self:_releaseLock()
	return handle
end

function FullBus:SubscribeTimeRange(eventName:string, low:number, high:number, callback:Callback, options:SubscribeOptions?):DisconnectHandle
	if self._readOnly then
		Debugger:Throw("warn", "SubscribeTimeRange", "Bus is in read-only mode; operation ignored.")
		return false
	end
	if self._destroyed then
		Debugger:Throw("warn", "SubscribeTimeRange", "Attempt to use a destroyed bus instance.")
		return
	end
	local opts = options or {}
	local connection:Connection
	self:_acquireLock()
	connection = {
		Callback = callback,
		Priority = opts.Priority or 0,
		Once = opts.Once or false,
		Filter = opts.Filter,
		Connected = true,
		EventName = eventName,
		_bus = self,
	}
	local tree = self._intervalSubscribers[eventName]
	if not tree or type(tree) ~= "table" or not tree.insert then
		tree = IntervalTree.new()
		self._intervalSubscribers[eventName] = tree
	end
	if low <= high and type(tree) == "table" then
		tree:insert(low, high, connection)
		_debugLog(self, "SubscribeTimeRange", ("Subscribed to '%s' in time range [%d, %d]")
			:format(eventName, low, high))
	else
		local endOfDay = 86399
		tree:insert(low, endOfDay, connection)
		tree:insert(0, high, connection)
		_debugLog(self, "SubscribeTimeRange", ("Subscribed to '%s' in time range [%d, %d] (MIDNIGHT WRAP)")
			:format(eventName, low, high))
	end
	local handle = {}
	handle.Disconnect = function()
		if connection then
			connection._bus:_acquireLock()
			connection.Connected = false
			_debugLog(connection._bus, "SubscribeTimeRange", ("Disconnected time range sub from '%s'")
				:format(eventName))
			connection._bus:_queueEvent(connection._bus._disconnectSignal, eventName, connection)
			connection._bus:_releaseLock()
		end
	end
	if opts.Group and opts.Group.Add then
		opts.Group:Add(handle)
	end
	self:_queueEvent(self._subscribeSignal, eventName, connection)
	self:_releaseLock()
	return handle
end

function FullBus:SubscribeDebounced(eventName:string, waitTime:number, callback:Callback, options:SubscribeOptions?):DisconnectHandle
	if self._readOnly then
		Debugger:Throw("warn", "SubscribeDebounced", "Bus is in read-only mode; operation ignored.")
		return false
	end
	if self._destroyed then
		Debugger:Throw("warn", "SubscribeDebounced", "Attempt to use a destroyed bus instance.")
		return
	end
	if type(waitTime) ~= "number" or waitTime <= 0 then
		Debugger:Throw("error", "SubscribeDebounced", "waitTime must be a positive number")
		return
	end
	local opts = options or {}
	local handle:DisconnectHandle
	self:_acquireLock()
	local connection:Connection = {
		Callback = callback,
		Priority = opts.Priority or 0,
		Once = opts.Once or false,
		Filter = opts.Filter,
		Connected = true,
		EventName = eventName,
		_bus = self,
		_handlerType = "Debounce", 
		_waitTime = waitTime,
		_latestArgs = nil,
		_debounceTask = nil,
	}
	if not self._subscribers[eventName] then
		self._subscribers[eventName] = {}
	end
	table.insert(self._subscribers[eventName], connection)
	_sortByPriority(self._subscribers[eventName])
	_debugLog(self, "SubscribeDebounced", ("Debounced subscriber added to '%s' (Wait:%f)")
		:format(eventName, waitTime))
	handle = {}
	handle.Disconnect = function()
		self:Disconnect(connection)
	end
	if opts.Group and opts.Group.Add then
		opts.Group:Add(handle)
	end
	self:_queueEvent(self._subscribeSignal, eventName, connection)
	self:_releaseLock()
	return handle
end

function FullBus:SubscribeBatched(eventName:string, waitTime:number, callback:Callback, options:SubscribeOptions?):DisconnectHandle
	if self._readOnly then
		Debugger:Throw("warn", "SubscribeBatched", "Bus is in read-only mode; operation ignored.")
		return false
	end
	if self._destroyed then
		Debugger:Throw("warn", "SubscribeBatched", "Attempt to use a destroyed bus instance.")
		return
	end
	if type(waitTime) ~= "number" or waitTime <= 0 then
		Debugger:Throw("error", "SubscribeBatched", "waitTime must be a positive number")
		return
	end
	local opts = options or {}
	local handle:DisconnectHandle
	self:_acquireLock()
	local connection:Connection = {
		Callback = callback,
		Priority = opts.Priority or 0,
		Once = opts.Once or false,
		Filter = opts.Filter,
		Connected = true,
		EventName = eventName,
		_bus = self,
		_handlerType = "Batch", 
		_waitTime = waitTime,
		_batchBuffer = {},
		_batchTask = nil,
	}
	if not self._subscribers[eventName] then
		self._subscribers[eventName] = {}
	end
	table.insert(self._subscribers[eventName], connection)
	_sortByPriority(self._subscribers[eventName])
	_debugLog(self, "SubscribeBatched", ("Batched subscriber added to '%s' (Wait:%f)")
		:format(eventName, waitTime))
	handle = {}
	handle.Disconnect = function()
		self:Disconnect(connection)
	end
	if opts.Group and opts.Group.Add then
		opts.Group:Add(handle)
	end
	self:_queueEvent(self._subscribeSignal, eventName, connection)
	self:_releaseLock()
	return handle
end

function FullBus:SubscribeThrottled(eventName:string, waitTime:number, callback:Callback, options:SubscribeOptions?):DisconnectHandle
	if self._readOnly then
		Debugger:Throw("warn", "SubscribeThrottled", "Bus is in read-only mode; operation ignored.")
		return false
	end
	if self._destroyed then
		Debugger:Throw("warn", "SubscribeThrottled", "Attempt to use a destroyed bus instance.")
		return
	end
	if type(waitTime) ~= "number" or waitTime <= 0 then
		Debugger:Throw("error", "SubscribeThrottled", "waitTime must be a positive number")
		return
	end
	local opts = options or {}
	local handle:DisconnectHandle
	self:_acquireLock()
	local connection:Connection = {
		Callback = callback,
		Priority = opts.Priority or 0,
		Once = opts.Once or false,
		Filter = opts.Filter,
		Connected = true,
		EventName = eventName,
		_bus = self,
		_handlerType = "Throttle", 
		_waitTime = waitTime,
		_lastCallTime = 0,
	}
	if not self._subscribers[eventName] then
		self._subscribers[eventName] = {}
	end
	table.insert(self._subscribers[eventName], connection)
	_sortByPriority(self._subscribers[eventName])
	_debugLog(self, "SubscribeThrottled", ("Throttled subscriber added to '%s' (Wait:%f)")
		:format(eventName, waitTime))
	handle = {}
	handle.Disconnect = function()
		self:Disconnect(connection)
	end
	if opts.Group and opts.Group.Add then
		opts.Group:Add(handle)
	end
	self:_queueEvent(self._subscribeSignal, eventName, connection)
	self:_releaseLock()
	return handle
end

function FullBus:SubscribeToAll(callback:Callback, options:SubscribeOptions?):DisconnectHandle
	if self._readOnly then
		Debugger:Throw("warn", "SubscribeToAll", "Bus is in read-only mode; operation ignored.")
		return false
	end
	if self._destroyed then
		Debugger:Throw("warn", "SubscribeToAll", "Attempt to use a destroyed bus instance.")
		return
	end
	if type(callback) ~= "function" then
		Debugger:Throw("error", "SubscribeToAll", "Callback must be a function")
		return
	end
	local opts = options or {}
	local connection:Connection
	self:_acquireLock()
	connection = {
		Callback = callback,
		Priority = opts.Priority or 0,
		Once = opts.Once or false,
		Filter = opts.Filter,
		Connected = true,
		EventName = "*",
		_bus = self,
	}
	table.insert(self._allSubscribers, connection)
	_sortByPriority(self._allSubscribers)
	_debugLog(self, "SubscribeToAll", ("Subscribed to ALL events (Priority:%d, Once:%s)")
		:format(connection.Priority,tostring(connection.Once)))
	local handle = {}
	handle.Disconnect = function()
		if not connection or not connection.Connected then return end
		if connection._bus._destroyed then return end
		connection._bus:_acquireLock()
		connection.Connected = false
		local subs = connection._bus._allSubscribers
		for i = #subs, 1, -1 do
			if subs[i] == connection then
				table.remove(subs, i)
				connection._bus:_queueEvent(connection._bus._disconnectSignal, "*", connection)
				break
			end
		end
		connection._bus:_releaseLock()
	end
	if opts.Group and opts.Group.Add then
		opts.Group:Add(handle)
	end
	self:_queueEvent(self._subscribeSignal, "*", connection)
	self:_releaseLock()
	return handle
end

function FullBus:CreateChildBus(prefix:string):FullBus
	if self._readOnly then
		Debugger:Throw("warn", "CreateChildBus", "Bus is in read-only mode; operation ignored.")
		return false
	end
	if self._destroyed then
		Debugger:Throw("warn", "CreateChildBus", "Attempt to use a destroyed bus instance.")
		return
	end
	if type(prefix) ~= "string" or prefix == "" then
		Debugger:Throw("error", "CreateChildBus", "Prefix must be a non-empty string")
		return
	end
	if not prefix:match("%.?$") then
		prefix = prefix.."."
	end
	local ok, childBus = pcall(FullBus.Create, self._config)
	if not ok or not childBus then
		Debugger:Throw("error", "CreateChildBus", "Failed to create child bus instance: "..tostring(childBus))
		return
	end
	childBus:AddMiddleware(function(eventName:string, ...:any)
		self:Publish(prefix..eventName, ...)
		return eventName, ...
	end)
	self:_acquireLock()
	table.insert(self._childBuses, childBus)
	self:_releaseLock()
	_debugLog(self, "CreateChildBus", "Created child bus with prefix: "..prefix)
	return childBus
end

function FullBus:Reply(eventName:string, callback:Callback, options:SubscribeOptions?):DisconnectHandle
	if self._readOnly then
		Debugger:Throw("warn", "Reply", "Bus is in read-only mode; operation ignored.")
		return false
	end
	if self._destroyed then
		Debugger:Throw("warn", "Reply", "Attempt to use a destroyed bus instance.")
		return
	end
	if type(callback) ~= "function" then
		Debugger:Throw("error", "Reply", "Callback must be a function")
		return
	end
	local function wrapperCallback(...)
		local args = table.pack(...)
		local replyEventName = args[args.n]
		if type(replyEventName) == "string" and replyEventName:match("^_reply%.") then
			local argsToPass = {}
			for i = 1, args.n - 1 do
				table.insert(argsToPass, args[i])
			end
			local pcallResults = {pcall(function() return callback(table.unpack(argsToPass)) end)}
			local success = table.remove(pcallResults, 1)
			if success then
				self:Publish(replyEventName, true, table.unpack(pcallResults))
			else
				local err = tostring(pcallResults[1] or "Unknown error")
				self:Publish(replyEventName, false, err)
			end
		else
			_debugLog(self, "Reply", "Reply subscriber for '"..eventName.."' fired without reply topic.")
			pcall(callback, ...)
		end
	end
	return self:Subscribe(eventName, wrapperCallback, options)
end

function FullBus:Request(eventName:string, timeout:number?, ...:any): (boolean, ...any)
	if self._destroyed then
		Debugger:Throw("error", "Request", "Attempt to use a destroyed bus instance.")
		return false, "Bus destroyed"
	end
	self:_acquireLock()
	self._replyCounter = (self._replyCounter or 0) + 1
	local replyEventName = "_reply."..tostring(self._replyCounter)
	self:_releaseLock()
	local args = {...}
	local currentThread = coroutine.running()
	local success, result
	task.spawn(function()
		local waitResults = {self:WaitFor(replyEventName, timeout)}
		local ok = table.remove(waitResults, 1)
		if not ok then
			success = false
			result = {"Request timed out"}
		else
			local replyArgs = waitResults
			success = replyArgs[1]
			table.remove(replyArgs, 1)
			result = replyArgs
		end
		task.spawn(currentThread, success, result)
	end)
	self:Publish(eventName, table.unpack(args), replyEventName)
	local coSuccess, coResult = coroutine.yield()
	if not coSuccess then
		return false, table.unpack(coResult, 1, coResult.n)
	end
	return coSuccess, table.unpack(coResult, 1, coResult.n)
end

function FullBus:Disconnect(connection:Connection)
	if self._readOnly then
		Debugger:Throw("warn", "Disconnect", "Bus is in read-only mode; operation ignored.")
		return false
	end
	if not connection or 
		not connection.Connected then
		return
	end
	if connection._bus._destroyed then
		return
	end
	task.spawn(function()
		connection._bus:_acquireLock()
		_disconnectInternal(connection)
		connection._bus:_releaseLock()
	end)
end

function FullBus:Unsubscribe(eventName:string, callback:Callback)
	if self._readOnly then
		Debugger:Throw("warn", "Unsubscribe", "Bus is in read-only mode; operation ignored.")
		return false
	end
	if self._destroyed then
		Debugger:Throw("warn", "Unsubscribe", "Attempt to use a destroyed bus instance.")
		return
	end
	if type(eventName) ~= "string" or eventName == "" then
		Debugger:Throw("error", "Unsubscribe", "Event name must be a non-empty string")
		return
	end
	if type(callback) ~= "function" then
		Debugger:Throw("error", "Unsubscribe", "Callback must be a function")
		return
	end
	self:_acquireLock()
	local subscribers = self._subscribers[eventName]
	if not subscribers then
		_debugLog(self, "Unsubscribe", ("No subscribers found for event '%s'.")
			:format(eventName))
		self:_releaseLock()
		return
	end
	local disconnectedCount = 0
	for i = #subscribers, 1, -1 do
		local connection = subscribers[i]
		if connection.Connected and connection.Callback == callback then
			_disconnectInternal(connection)
			disconnectedCount += 1
		end
	end
	_debugLog(self, "Unsubscribe", ("Unsubscribed %d connections from '%s' using callback function.")
		:format(disconnectedCount, eventName))
	self:_releaseLock()
end

function FullBus:_gatherConnections(eventName:string, ...:any):({any}, {Connection})
	local args = {...}
	if self._config.EnableDeduplication then
		local eventKey = _serializeEvent(eventName, args)
		if self._deduplicationFilter:Contains(eventKey) then
			_debugLog(self, "_gatherConnections", ("Event '%s' dropped (BloomFilter deduplication:duplicate)")
				:format(eventName))
			return nil, nil
		else
			self._deduplicationFilter:Add(eventKey)
		end
	end
	local connectionsToCall = {}
	local limiter = self._rateLimiters[eventName]
	if limiter then
		if not limiter:consume(1) then
			_debugLog(self, "_gatherConnections", ("Event '%s' dropped (rate limit)")
				:format(eventName))
			return nil, nil
		end
	end
	self:_acquireLock()
	local ok, err = pcall(function()
		for _, mw in ipairs(self._middleware) do
			local newArgs = {mw(eventName, table.unpack(args))}
			if #newArgs > 0 then
				args = newArgs
			end
		end
		self._hllUniqueEvents:add(eventName)
		local serializedEvent = _serializeEvent(eventName, args)
		table.insert(self._eventAuditLog, serializedEvent)
		if #self._eventAuditLog > 1000 then
			table.remove(self._eventAuditLog, 1)
		end
		local compressedArgs = self:_serializeArgs(args)
		if compressedArgs then
			self._eventHistoryLog:Insert(os.clock(), {Name = eventName, CompressedArgs = compressedArgs})
		end
		self._timelineTick = (self._timelineTick % self._config.TimelineSize) + 1
		local currentTickCount = self._eventCountTimeline:PointQuery(self._timelineTick)
		self._eventCountTimeline:PointUpdate(self._timelineTick, currentTickCount + 1)
		self._eventHistory[eventName] = (self._eventHistory[eventName] or 0) + 1
		self:_queueEvent(self._publishSignal, eventName, args)
		_debugLog(self, "_gatherConnections", ("Publishing '%s' with %d arg(s)")
			:format(eventName, #args))
		local matchingConnections:{Connection} = {}
		local matchingPatterns = self._wildcardMatchCache:Find(eventName)
		if not matchingPatterns then
			matchingPatterns = {}
			for pattern in pairs(self._subscribers) do
				if _matchesPattern(self, pattern, eventName) then
					table.insert(matchingPatterns, pattern)
				end
			end
			self._wildcardMatchCache:Insert(eventName, matchingPatterns)
		end
		for _, pattern in ipairs(matchingPatterns) do
			local connections = self._subscribers[pattern]
			if connections then
				for _, connection in ipairs(connections) do
					if not connection.Connected then continue end
					if connection._handlerType == "Debounce" then
						connection._latestArgs = args
						if connection._debounceTask then
							task.cancel(connection._debounceTask)
						end
						local connToCapture = connection
						connection._debounceTask = task.spawn(function()
							task.wait(connToCapture._waitTime)
							if connToCapture.Connected and connToCapture._latestArgs then
								_safeCall(self, connToCapture.Callback, eventName, table.unpack(connToCapture._latestArgs))
								if connToCapture.Once then task.defer(function()
										self:Disconnect(connToCapture)
									end)
								end
								connToCapture._latestArgs = nil
							end
							connToCapture._debounceTask = nil
						end)
					elseif connection._handlerType == "Batch" then
						table.insert(connection._batchBuffer, args)
						if not connection._batchTask then
							local connToCapture = connection
							connection._batchTask = task.spawn(function()
								task.wait(connToCapture._waitTime)
								if connToCapture.Connected and #connToCapture._batchBuffer > 0 then
									_safeCall(self, connToCapture.Callback, eventName, connToCapture._batchBuffer)
									if connToCapture.Once then task.defer(function()
											self:Disconnect(connToCapture)
										end)
									end
								end
								connToCapture._batchBuffer = {}
								connToCapture._batchTask = nil
							end)
						end
					elseif connection._handlerType == "Throttle" then
						local now = os.clock()
						if (now - connection._lastCallTime) >= connection._waitTime then
							connection._lastCallTime = now
							table.insert(matchingConnections, connection)
						else -- Still in cooldown, ignore this event
						end
					else
						table.insert(matchingConnections, connection)
					end
				end
			end
		end
		for i = 1, #eventName do
			local prefix = eventName:sub(1, i)
			local conns = self._prefixSubscribers:Search(prefix)
			if conns then
				for _, conn in ipairs(conns) do
					if conn.Connected then
						table.insert(matchingConnections, conn)
					end
				end
			end
		end
		local intervalTree = self._intervalSubscribers[eventName]
		if intervalTree then
			local secondsToday = self:_getSecondsToday()
			local overlapping = intervalTree:queryPoint(secondsToday)
			for _, intervalData in ipairs(overlapping) do
				if intervalData.data.Connected then
					table.insert(matchingConnections, intervalData.data)
				end
			end
		end
		for _, conn in ipairs(self._allSubscribers) do
			if conn.Connected then
				table.insert(matchingConnections, conn)
			end
		end
		_sortByPriority(matchingConnections)
		local processedConnections = {}
		for _, connection in ipairs(matchingConnections) do
			if not processedConnections[connection] then
				processedConnections[connection] = true
				if not connection.Connected then
					continue
				end
				if connection.Filter and not connection.Filter(table.unpack(args)) then
					continue
				end
				table.insert(connectionsToCall, {Conn = connection, Args = args})
			end
		end
	end)
	self:_releaseLock()
	if not ok then
		Debugger:Throw("error", "Publish(Gather)", "Internal failure:"..tostring(err))
		return nil, nil
	end
	return connectionsToCall, args
end

function FullBus:WaitFor(eventName:string, timeout:number?): (boolean, ...any)
	if self._destroyed then
		Debugger:Throw("error", "WaitFor", "Attempt to use a destroyed bus instance.")
		return false
	end
	if type(eventName) ~= "string" or eventName == "" then
		Debugger:Throw("error", "WaitFor", "Event name must be a string")
		return false
	end
	local eventSignal = Signal.new()
	local capturedArgs:{any} = {}
	local fired = false
	local connection
	local function onEvent(...)
		capturedArgs = table.pack(...)
		fired = true
		eventSignal:Fire()
	end
	connection = self:SubscribeOnce(eventName, onEvent)
	if not connection then
		return false
	end
	local timeoutTime = timeout or 0
	local startTime = os.clock()
	local waitSuccess = false
	if timeoutTime > 0 then
		local timer = task.delay(timeoutTime, function()
			if not fired then
				eventSignal:Fire() 
			end
		end)
		eventSignal:Wait()
		task.cancel(timer)
		if fired then
			waitSuccess = true
		end
	else
		eventSignal:Wait()
		waitSuccess = true
	end
	eventSignal:DisconnectAll()
	if connection and connection.Connected then
		connection.Disconnect()
	end
	if not fired then
		return false
	end
	return true, table.unpack(capturedArgs, 1, capturedArgs.n)
end

function FullBus:Publish(eventName:string, ...:any)
	if self._readOnly then
		Debugger:Throw("warn", "Publish", "Bus is in read-only mode; operation ignored.")
		return false
	end
	if self._destroyed then
		Debugger:Throw("error", "Publish", "Attempt to use a destroyed bus instance.")
		return
	end
	if type(eventName) ~= "string" then
		Debugger:Throw("error", "Publish", "Event name must be a string")
		return
	end
	local connectionsToCall, args = self:_gatherConnections(eventName, ...)
	if not connectionsToCall then
		return
	end
	for _, item in ipairs(connectionsToCall) do
		if self._config.AsyncByDefault then
			task.spawn(function()
				_safeCall(self, item.Conn.Callback, eventName, table.unpack(item.Args))
				if item.Conn.Once then
					self:Disconnect(item.Conn)
				end
			end)
		else
			_safeCall(self, item.Conn.Callback, eventName, table.unpack(item.Args))
			if item.Conn.Once then
				self:Disconnect(item.Conn)
			end
		end
	end
end

function FullBus:PublishAsync(eventName:string, ...:any)
	if self._readOnly then
		Debugger:Throw("warn", "PublishAsync", "Bus is in read-only mode; operation ignored.")
		return false
	end
	if self._destroyed then
		Debugger:Throw("error", "PublishAsync", "Attempt to use a destroyed bus instance.")
		return
	end
	if type(eventName) ~= "string" then
		Debugger:Throw("error", "PublishAsync", "Event name must be a string")
		return
	end
	local connectionsToCall, args = self:_gatherConnections(eventName, ...)
	if not connectionsToCall then
		return
	end
	if #connectionsToCall == 0 then
		return
	end
	local completionSignal = Signal.new()
	for _, item in ipairs(connectionsToCall) do
		task.spawn(function()
			_safeCall(self, item.Conn.Callback, eventName, table.unpack(item.Args))
			if item.Conn.Once then
				self:Disconnect(item.Conn)
			end
			pcall(function() completionSignal:Fire() end)
		end)
	end
	for i = 1, #connectionsToCall do
		completionSignal:Wait()
	end
	completionSignal:DisconnectAll()
end

function FullBus:PublishSticky(eventName:string, ...:any)
	if self._readOnly then
		Debugger:Throw("warn", "PublishSticky", "Bus is in read-only mode; operation ignored.")
		return false
	end
	if self._destroyed then
		Debugger:Throw("error", "PublishSticky", "Attempt to use a destroyed bus instance.")
		return
	end
	if type(eventName) ~= "string" then
		Debugger:Throw("error", "PublishSticky", "Event name must be a string")
		return
	end
	self:Publish(eventName, ...)
	local args = table.pack(...)
	self:_acquireLock()
	local compressedArgs = self:_serializeArgs(args)
	if compressedArgs then
		self._stickyCache[eventName] = {CompressedArgs = compressedArgs}
	end
	_debugLog(self, "PublishSticky", ("Sticky event '%s' published and cached.")
		:format(eventName))
	self:_releaseLock()
end

function FullBus:RemoveSticky(eventName:string)
	if self._readOnly then
		Debugger:Throw("warn", "RemoveSticky", "Bus is in read-only mode; operation ignored.")
		return false
	end
	if self._destroyed then
		Debugger:Throw("error", "RemoveSticky", "Attempt to use a destroyed bus instance.")
		return
	end
	if type(eventName) ~= "string" or eventName == "" then
		Debugger:Throw("error", "RemoveSticky", "Event name must be a non-empty string")
		return
	end
	self:_acquireLock()
	if self._stickyCache[eventName] then
		self._stickyCache[eventName] = nil
		_debugLog(self, "RemoveSticky", ("Sticky cache for '%s' removed.")
			:format(eventName))
	end
	self:_releaseLock()
end

function FullBus:PublishByPrefix(eventName:string, ...:any)
	if self._readOnly then
		Debugger:Throw("warn", "PublishByPrefix", "Bus is in read-only mode; operation ignored.")
		return false
	end
	if self._destroyed then
		Debugger:Throw("error", "PublishByPrefix", "Attempt to use a destroyed bus instance.")
		return
	end
	local args = {...}
	local connectionsToCall = {}
	self:_acquireLock()
	local matchingConnections = {}
	for i = 1, #eventName do
		local prefix = eventName:sub(1, i)
		local conns = self._prefixSubscribers:Search(prefix)
		if conns then
			for _, conn in ipairs(conns) do
				if conn.Connected then
					table.insert(matchingConnections, conn)
				end
			end
		end
	end
	_sortByPriority(matchingConnections)
	local processedConnections = {}
	for _, connection in ipairs(matchingConnections) do
		if not processedConnections[connection] then
			processedConnections[connection] = true
			if not connection.Connected then continue end
			if connection.Filter and not connection.Filter(table.unpack(args)) then continue end
			table.insert(connectionsToCall, {Conn = connection, Args = args})
		end
	end
	self:_releaseLock()
	for _, item in ipairs(connectionsToCall) do
		if self._config.AsyncByDefault then
			task.spawn(function()
				_safeCall(self, item.Conn.Callback, eventName, table.unpack(item.Args))
				if item.Conn.Once then
					self:Disconnect(item.Conn)
				end
			end)
		else
			_safeCall(self, item.Conn.Callback, eventName, table.unpack(item.Args))
			if item.Conn.Once then
				self:Disconnect(item.Conn)
			end
		end
	end
end

function FullBus:AddMiddleware(middlewareFunc:Middleware)
	if self._readOnly then
		Debugger:Throw("warn", "AddMiddleware", "Bus is in read-only mode; operation ignored.")
		return false
	end
	if self._destroyed then
		Debugger:Throw("error", "AddMiddleware", "Attempt to use a destroyed bus instance.")
		return
	end
	if type(middlewareFunc) ~= "function" then
		Debugger:Throw("error", "AddMiddleware", "Middleware must be a function")
		return
	end
	self:_acquireLock()
	table.insert(self._middleware, middlewareFunc)
	_debugLog(self, "AddMiddleware", "Middleware added")
	self:_releaseLock()
end

function FullBus:RemoveMiddleware(middlewareFunc:Middleware)
	if self._readOnly then
		Debugger:Throw("warn", "RemoveMiddleware", "Bus is in read-only mode; operation ignored.")
		return false
	end
	if self._destroyed then
		Debugger:Throw("error", "RemoveMiddleware", "Attempt to use a destroyed bus instance.")
		return
	end
	if type(middlewareFunc) ~= "function" then
		Debugger:Throw("error", "RemoveMiddleware", "Middleware must be a function")
		return
	end
	self:_acquireLock()
	local found = false
	for i = #self._middleware, 1, -1 do
		if self._middleware[i] == middlewareFunc then
			table.remove(self._middleware, i)
			found = true
			break
		end
	end
	if found then
		_debugLog(self, "RemoveMiddleware", "Middleware removed")
	else
		_debugLog(self, "RemoveMiddleware", "Middleware function not found")
	end
	self:_releaseLock()
end

function FullBus:SetEventRateLimit(eventName:string, refillRate:number, capacity:number)
	if self._readOnly then
		Debugger:Throw("warn", "SetEventRateLimit", "Bus is in read-only mode; operation ignored.")
		return false
	end
	if self._destroyed then
		Debugger:Throw("error", "SetEventRateLimit", "Attempt to use a destroyed bus instance.")
		return
	end
	self:_acquireLock()
	self._rateLimiters[eventName] = TokenBucket.new(refillRate, capacity, capacity)
	_debugLog(self, "SetEventRateLimit", ("Rate limit set for '%s' (Rate:%d, Cap:%d)")
		:format(eventName, refillRate, capacity))
	self:_releaseLock()
end

function FullBus:_clearInternal(eventName:string)
	if self._subscribers[eventName] then
		for _, connection in ipairs(self._subscribers[eventName]) do
			connection.Connected = false
		end
		self._subscribers[eventName] = nil
		_debugLog(self, "_clearInternal", ("Cleared all subscribers for '%s'")
			:format(eventName))
	end
	if self._intervalSubscribers[eventName] then
		self._intervalSubscribers[eventName] = nil
		_debugLog(self, "_clearInternal", ("Cleared all time-range subscribers for '%s'")
			:format(eventName))
	end
end

function FullBus:Clear(eventName:string)
	if self._readOnly then
		Debugger:Throw("warn", "Clear", "Bus is in read-only mode; operation ignored.")
		return false
	end
	if self._destroyed then
		Debugger:Throw("error", "Clear", "Attempt to use a destroyed bus instance.")
		return
	end
	self:_acquireLock()
	self:_clearInternal(eventName)
	self._wildcardMatchCache:Clear()
	self:_releaseLock()
end

function FullBus:_clearAllInternal()
	for eventName, connections in pairs(self._subscribers) do
		for _, connection in ipairs(connections) do
			connection.Connected = false
		end
	end
	self._subscribers = {}
	for _, conn in ipairs(self._allSubscribers) do
		conn.Connected = false
	end
	self._allSubscribers = {}
	self._prefixSubscribers:Clear()
	self._intervalSubscribers = {}
	self._wildcardMatchCache:Clear()
	self._deduplicationFilter:Clear()
	_debugLog(self, "_clearAllInternal", "Cleared all subscribers")
end

function FullBus:ClearAll()
	if self._readOnly then
		Debugger:Throw("warn", "ClearAll", "Bus is in read-only mode; operation ignored.")
		return false
	end
	if self._destroyed then
		Debugger:Throw("error", "ClearAll", "Attempt to use a destroyed bus instance.")
		return
	end
	self:_acquireLock()
	self:_clearAllInternal()
	self:_releaseLock()
end

function FullBus:GetStats():BusStats
	if self._destroyed then
		Debugger:Throw("error", "GetStats", "Attempt to use a destroyed bus instance.")
		return {Destroyed = true}
	end
	self:_acquireLock()
	local _Stats:BusStats = {
		Destroyed = self._destroyed,
		TotalEvents = 0,
		TotalSubscribers = 0,
		NormalSubscriptions = 0,
		PrefixSubscriptions = 0,
		TimeRangeSubscriptions = 0,
		WildcardSubscriptions = 0,
		StickyEvents = 0,
		EventCounts = {},
		SubscriberCounts = {},
		EventHistory = {},
		UniqueEventNamesEstimate = 0,
		TimelineEventCount = 0,
		TimelineWindowSize = self._config.TimelineSize,
		PendingAuditLogSize = 0,
		LastAuditRoot = nil,
	}
	local totalPublishedEvents = 0
	for eventName, count in pairs(self._eventHistory) do
		_Stats.EventHistory[eventName] = count
		totalPublishedEvents += count
	end
	_Stats.TotalEvents = totalPublishedEvents
	for _, _ in pairs(self._stickyCache or {}) do
		_Stats.StickyEvents += 1
	end
	for eventName, connections in pairs(self._subscribers) do
		local activeCount = 0
		for _, conn in ipairs(connections) do
			if conn.Connected then
				activeCount += 1
			end
		end
		_Stats.SubscriberCounts[eventName] = activeCount
		if eventName:match("[%*%?]") then
			_Stats.WildcardSubscriptions += activeCount
		else
			_Stats.NormalSubscriptions += activeCount
		end
	end
	local function walkRadixTree(node)
		if node.isEnd and node.value then
			for _, conn in ipairs(node.value) do
				if conn.Connected then
					_Stats.PrefixSubscriptions += 1
				end
			end
		end
		for _, child in pairs(node.children) do
			walkRadixTree(child)
		end
	end
	if self._prefixSubscribers.root then
		for _, child in pairs(self._prefixSubscribers.root.children) do
			walkRadixTree(child)
		end
	end
	for _, intervalTree in pairs(self._intervalSubscribers) do
		local allConnections = {}
		local ok, data = pcall(function() return intervalTree:getAll() end)
		if ok and type(data) == "table" then
			allConnections = data
		end
		for _, intervalData in ipairs(allConnections) do
			if intervalData and intervalData.data and intervalData.data.Connected then
				_Stats.TimeRangeSubscriptions += 1
			end
		end
	end
	_Stats.TotalSubscribers = _Stats.NormalSubscriptions + _Stats.WildcardSubscriptions + 
		_Stats.PrefixSubscriptions + _Stats.TimeRangeSubscriptions
	for eventName, count in pairs(self._eventHistory) do
		_Stats.EventHistory[eventName] = count
	end
	_Stats.UniqueEventNamesEstimate = self._hllUniqueEvents:count()
	_Stats.TimelineEventCount = self._eventCountTimeline:RangeQuery(1, self._config.TimelineSize)
	_Stats.PendingAuditLogSize = #self._eventAuditLog
	_Stats.LastAuditRoot = self._lastAuditTree and self._lastAuditTree:getRoot()
	self:_releaseLock()
	return _Stats
end

function FullBus:GetEventHistoryRange(startTime:number, endTime:number):{any}
	if self._destroyed then
		Debugger:Throw("error", "GetEventHistoryRange", "Attempt to use a destroyed bus instance.")
		return {}
	end
	self:_acquireLock()
	local rawResults = self._eventHistoryLog:RangeQuery(startTime, endTime)
	local finalResults = {}
	for _, entry in ipairs(rawResults) do
		if entry.value and entry.value.CompressedArgs then
			local decompressedArgs = self:_deserializeArgs(entry.value.CompressedArgs)
			if decompressedArgs then
				table.insert(finalResults, {
					key = entry.key,
					value = {Name = entry.value.Name, Args = decompressedArgs}
				})
			else
				Debugger:Throw("warn", "GetEventHistoryRange", "Failed to decompress history entry.")
			end
		end
	end
	self:_releaseLock()
	return finalResults
end

function FullBus:GetEventProof(index:number):{any}?
	if self._destroyed then return nil end
	self:_acquireLock()
	if not self._lastAuditTree then
		_debugLog(self, "GetEventProof", "No audit tree built.")
		self:_releaseLock()
		return nil
	end
	local proof = self._lastAuditTree:getProof(index) 
	self:_releaseLock()
	return proof
end

function FullBus:GetPendingAuditLog():{string}
	if self._destroyed then return {} end
	self:_acquireLock()
	local logCopy = table.clone(self._eventAuditLog)
	self:_releaseLock()
	return logCopy
end

function FullBus:BuildAuditTree():string?
	if self._readOnly then
		Debugger:Throw("warn", "Clear", "Bus is in read-only mode; operation ignored.")
		return false
	end
	if self._destroyed then return nil end
	self:_acquireLock()
	if #self._eventAuditLog == 0 then
		_debugLog(self, "GetPendingAuditLog", "BuildAuditTree:No events in log.")
		self:_releaseLock()
		return nil
	end
	self._lastAuditTree = MerkleTree.new(self._eventAuditLog)
	self._eventAuditLog = {}
	local root = self._lastAuditTree:getRoot()
	_debugLog(self, "GetPendingAuditLog", "Built audit tree. New root:"..root)
	self:_releaseLock()
	return root
end

function FullBus:GetAuditRoot():string?
	if self._destroyed then return nil end
	self:_acquireLock()
	local root = self._lastAuditTree and self._lastAuditTree:getRoot()
	self:_releaseLock()
	return root
end

function FullBus:VerifyWithLastRoot(proof:{any}, leafData:string):boolean
	if self._destroyed then return false end
	self:_acquireLock()
	if not self._lastAuditTree then
		_debugLog(self, "VerifyWithLastRoot", "VerifyWithLastRoot:No audit tree built.")
		self:_releaseLock()
		return false
	end
	local root = self._lastAuditTree:getRoot()
	local success = MerkleTree.verify(proof, leafData, root)
	self:_releaseLock()
	return success
end

function FullBus:SetDebug(enabled:boolean)
	if self._destroyed then
		Debugger:Throw("error", "SetDebug", "Attempt to use a destroyed bus instance.")
		return
	end
	self:_acquireLock()
	self._config.EnableDebug = (enabled == true)
	_debugLog(self, "SetDebug", "Debug mode "..(self._config.EnableDebug and "enabled" or "disabled"))
	self:_releaseLock()
end

function FullBus:ReadOnly(state:boolean)
	if self._destroyed then
		Debugger:Throw("error", "ReadOnly", "Attempt to use a destroyed bus instance.")
		return
	end
	self:_acquireLock()
	local success, result = pcall(function()
		if type(state) == "boolean" then
			if state == true then
				self._readOnly = true
				_debugLog(self, "ReadOnly", "Read-only mode enabled.")
			else
				self._readOnly = false
				_debugLog(self, "ReadOnly", "Read-only mode disabled.")
			end
		else
			Debugger:Throw("error", "ReadOnly", ("Expected state to be a boolean value, got type: %q")
				:format(type(state)))
		end
	end)
	self:_releaseLock()
	if not success then
		Debugger:Throw("error", "ReadOnly", ("Internal failure: %s\n%s")
			:format(tostring(result), debug.traceback(nil, 2)))
	end
end

-- Signals

function FullBus:OnPublish(fn: (eventName:string, args:{any})->())
	if self._destroyed then
		Debugger:Throw("error", "OnPublish", "Attempt to use a destroyed bus instance.")
		return nil
	end
	return self._publishSignal:Connect(fn)
end

function FullBus:OnSubscribe(fn: (eventName:string, connection:Connection)->())
	if self._destroyed then return nil end
	return self._subscribeSignal:Connect(fn)
end

function FullBus:OnDisconnect(fn: (eventName:string, connection:Connection)->())
	if self._destroyed then return nil end
	return self._disconnectSignal:Connect(fn)
end

function FullBus:OnError(fn: ErrorCallback)
	if self._destroyed then return nil end
	return self._errorSignal:Connect(fn)
end

function FullBus:DisconnectSignal(signalInstance: any, connectionId: number)
	if self._destroyed then return end
	if signalInstance and type(signalInstance.Disconnect) == "function" then
		pcall(signalInstance.Disconnect, signalInstance, connectionId)
	else
		Debugger:Throw("warn", "DisconnectSignal", "Invalid signal instance provided.")
	end
end

-- Introspection

function FullBus:Keys(): {string}
	if self._destroyed then
		Debugger:Throw("error", "Keys", "Attempt to use a destroyed bus instance.")
		return {}
	end
	self:_acquireLock()
	local keySet = {}
	local keys = {}
	for eventName, connections in pairs(self._subscribers) do
		for _, conn in ipairs(connections) do
			if conn.Connected then
				if not keySet[eventName] then
					keySet[eventName] = true
					table.insert(keys, eventName)
				end
				break
			end
		end
	end
	local function checkPrefixNode(node)
		if node.isEnd and node.value then
			for _, conn in ipairs(node.value) do
				if conn.Connected then
					local prefix = conn.EventName
					if not keySet[prefix] then
						keySet[prefix] = true
						table.insert(keys, prefix)
					end
					break
				end
			end
		end
		for _, child in pairs(node.children) do
			checkPrefixNode(child)
		end
	end
	if self._prefixSubscribers.root then
		checkPrefixNode(self._prefixSubscribers.root)
	end
	for eventName, intervalTree in pairs(self._intervalSubscribers) do
		if not keySet[eventName] then
			local ok, allIntervals = pcall(function() return intervalTree:getAll() end)
			if ok and allIntervals then
				for _, intervalData in ipairs(allIntervals) do
					if intervalData.data and intervalData.data.Connected then
						keySet[eventName] = true
						table.insert(keys, eventName)
						break
					end
				end
			end
		end
	end
	if #self._allSubscribers > 0 then
		local hasActiveAll = false
		for _, conn in ipairs(self._allSubscribers) do
			if conn.Connected then
				hasActiveAll = true
				break
			end
		end
		if hasActiveAll and not keySet["*"] then
			keySet["*"] = true
			table.insert(keys, "*")
		end
	end
	self:_releaseLock()
	return keys
end

function FullBus:Subscribers(eventName: string): {SubscriberInfo}
	if self._destroyed then
		Debugger:Throw("error", "Subscribers", "Attempt to use a destroyed bus instance.")
		return {}
	end
	if type(eventName) ~= "string" then
		Debugger:Throw("error", "Subscribers", "Event name must be a string.")
		return {}
	end
	self:_acquireLock()
	local results = {}
	local connections = self._subscribers[eventName]
	if connections then
		for _, conn in ipairs(connections) do
			if conn.Connected then
				local info: SubscriberInfo = {
					Callback = conn.Callback,
					Priority = conn.Priority,
					Once = conn.Once,
					Filter = conn.Filter,
					HandlerType = conn._handlerType,
					WaitTime = conn._waitTime,
					LastCallTime = conn._lastCallTime,
				}
				table.insert(results, info)
			end
		end
	end
	self:_releaseLock()
	return results
end

function FullBus:ForEach(fn: (eventName: string, connection: Connection) -> ())
	if self._destroyed then
		Debugger:Throw("error", "ForEach", "Attempt to use a destroyed bus instance.")
		return
	end
	if type(fn) ~= "function" then
		Debugger:Throw("error", "ForEach", "Provided argument must be a function.")
		return
	end
	self:_acquireLock()
	local success, err = pcall(function()
		for eventName, connections in pairs(self._subscribers) do
			if connections then
				for _, connection in ipairs(connections) do
					if connection.Connected then
						local callSuccess, callErr = pcall(fn, eventName, connection)
						if not callSuccess then
							Debugger:Throw("warn", "ForEach", ("Error during callback execution for event '%s': %s")
								:format(eventName, tostring(callErr)))
						end
					end
				end
			end
		end
	end)
	self:_releaseLock()
	if not success then
		Debugger:Throw("error", "ForEach", ("Internal failure during iteration: %s\n%s")
			:format(tostring(err), debug.traceback(nil, 2)))
	end
end

function FullBus:Transaction(transactionFn: (txBus: FullBus) -> any): (boolean, any?)
	if self._destroyed then
		Debugger:Throw("error", "Transaction", "Attempt to use a destroyed bus instance.")
		return false, "Bus destroyed"
	end
	if self._readOnly then
		Debugger:Throw("warn", "Transaction", "Bus is in read-only mode; operation ignored.")
		return false, "Read-only mode"
	end
	if type(transactionFn) ~= "function" then
		Debugger:Throw("error", "Transaction", "Provided argument must be a function.")
		return false, "Invalid argument: function required"
	end
	local journal = {}
	local txBus = {}
	local transactionalMethods = {
		"Subscribe", "SubscribeOnce", "SubscribeByPrefix", "SubscribeTimeRange",
		"SubscribeDebounced", "SubscribeBatched", "SubscribeThrottled", "SubscribeToAll",
		"Reply",
		"Publish", "PublishAsync", "PublishSticky", "PublishByPrefix",
		"Disconnect", "Unsubscribe",
		"Clear", "ClearAll",
		"AddMiddleware", "RemoveMiddleware",
		"SetEventRateLimit",
		"RemoveSticky",
	}
	local methodSet = {}
	for _, name in ipairs(transactionalMethods) do methodSet[name] = true end
	setmetatable(txBus, {
		__index = function(t, k)
			if methodSet[k] then
				return function(_, ...)
					local journalIndex = #journal + 1
					table.insert(journal, {op = k, args = table.pack(...), index = journalIndex})
					if k:match("^Subscribe") or k == "Reply" then
						local capturedJournalIndex = journalIndex
						local dummyHandle = {
							_journalIndex = capturedJournalIndex,
							Disconnect = function()
								table.insert(journal, {
									op = "__DISCONNECT_PENDING",
									subscribeIndex = capturedJournalIndex
								})
							end
						}
						return dummyHandle
					end
				end
			else
				local realValue = FullBus[k]
				if type(realValue) == "function" then
					return function(_, ...)
						return realValue(self, ...)
					end
				else
					return realValue
				end
			end
		end
	})
	self:_acquireLock()
	local eventsToFire
	local txSuccess, txResults = pcall(transactionFn, txBus)
	local applySuccess = false
	local applyError = nil
	if txSuccess then
		local applyOk, applyErr = pcall(function()
			local createdConnections = {}
			local handlesToReturn = {}
			for entryIndex, entry in ipairs(journal) do
				if entry.op:match("^Subscribe") or entry.op == "Reply" then
					local method = FullBus[entry.op]
					if method then
						local results = {method(self, table.unpack(entry.args, 1, entry.args.n))}
						local realHandle = results[1]
						if realHandle then
							handlesToReturn[entry.index] = realHandle
							local eventNameArg = entry.args[1]
							local callbackArg = entry.args[2]
							local actualConn = nil
							local subs
							if entry.op == "SubscribeByPrefix" then
								subs = self._prefixSubscribers:Search(eventNameArg)
							elseif entry.op == "SubscribeToAll" then
								subs = self._allSubscribers
							else
								subs = self._subscribers[eventNameArg]
							end
							if subs then
								for i = #subs, 1, -1 do
									if subs[i].Callback == callbackArg and subs[i].Connected then
										actualConn = subs[i]
										break
									end
								end
							end
							if actualConn then
								createdConnections[entry.index] = actualConn
							else
								Debugger:Throw("warn", "TransactionApply", ("Could not find connection object after subscribing for journal index %d")
									:format(entry.index))
							end
						end
					else
						error(("Transactional method '%s' not found on FullBus.")
							:format(entry.op))
					end
				end
			end
			for entryIndex, entry in ipairs(journal) do
				local method = FullBus[entry.op]
				if entry.op == "__DISCONNECT_PENDING" then
					local targetConn = createdConnections[entry.subscribeIndex]
					if targetConn and targetConn.Connected then
						_disconnectInternal(targetConn)
					else
						Debugger:Throw("warn", "TransactionApply", ("Could not disconnect pending connection for journal index %d - Connection invalid or already disconnected")
							:format(entry.subscribeIndex or -1))
					end
				elseif not (entry.op:match("^Subscribe") or entry.op == "Reply") and method then
					method(self, table.unpack(entry.args, 1, entry.args.n))
				elseif not method and entry.op ~= "__DISCONNECT_PENDING" then
					error(("Transactional method '%s' not found on FullBus.")
						:format(entry.op))
				end
			end
		end)
		applySuccess = applyOk
		applyError = applyErr
	else
		Debugger:Throw("warn", "Transaction", ("Transaction function failed: %s. Operations discarded.")
			:format(tostring(txResults)))
		applySuccess = false
	end
	if txSuccess and not applySuccess then
		Debugger:Throw("error", "Transaction", ("Failed applying transaction journal: %s. Bus state might be inconsistent.")
			:format(tostring(applyError)))
	end
	if #self._eventQueue > 0 then
		eventsToFire = self._eventQueue
		self._eventQueue = {}
	end
	self:_releaseLock()
	if eventsToFire then
		for _, event in ipairs(eventsToFire) do
			pcall(event.Signal.Fire, event.Signal, table.unpack(event.Args))
		end
	end
	if txSuccess and applySuccess then
		if type(txResults) == "table" and txResults.n ~= nil then
			return true, table.unpack(txResults, 1, txResults.n)
		else
			return true, txResults
		end
	else
		return false, applyError or txResults
	end
end
FullBus.Version = VERSION; FullBus.Registry = Buses
return Debugger:Profile(FullBus, "Create", script) :: TypeDef.Static
