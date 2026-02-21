--!optimize 2
--[[
	AUTHOR: Kel (@GudEveningBois)

	Created:
	11/2/25
	5:09 AM UTC+9
	
	Read documentary in FullState.Documentary
]]
local Version = "0.1.1 (STABLE)"
-- Dependencies
local TypeDef = require(script.TypeDef)
local HttpService = game:GetService("HttpService")
local Components = script.Parent.Parent.Components
local Debugger = require(Components.Debugger).From(script.Name)
local Signal = require(Components.KelSignal)
local Mutex = require(Components.Mutex)
local LZ4 = require(Components.Algorithms.LZ4)
local xxHash = require(Components.Algorithms.xxHash)
local MerkleTree = require(Components.Algorithms.MerkleTree)
local RadixTree = require(Components.Algorithms.RadixTree)
local BPlusTree = require(Components.Algorithms.BplusTree)
local DedupeLog = require(Components.Algorithms.DedupeLog)
local Base64 = require(Components.Algorithms.Base64)

-- Central registry for all state managers
local States = {}
local createMutex = Mutex.new()

local FullState = {}
FullState.__index = FullState

-- Helper functions ----------------------------------------------------------------------------------------

local function deepCopy(original, seen)
	if type(original) ~= "table" then return original end
	if seen and seen[original] then return seen[original] end
	seen = seen or {}
	local copy = {}
	seen[original] = copy
	for k, v in pairs(original) do
		copy[deepCopy(k, seen)] = deepCopy(v, seen)
	end
	return copy
end

local function deepFreeze(tbl: any): any
	if type(tbl) ~= "table" then
		return tbl
	end
	local frozen = table.freeze(tbl)
	for _, v in pairs(frozen) do
		if type(v) == "table" then
			deepFreeze(v)
		end
	end
	return frozen
end

local function shallowEqual(a: any, b: any): boolean
	if a == b then return true end
	if type(a) ~= "table" or type(b) ~= "table" then return false end
	for k, v in pairs(a) do
		if b[k] ~= v then return false end
	end
	for k in pairs(b) do
		if a[k] == nil then return false end
	end
	return true
end

local function _compressState(state: any): string?
	local ok, json = pcall(HttpService.JSONEncode, HttpService, state)
	if not ok then
		Debugger:Log("warn", "_compressState", "Failed to JSONEncode state: "..tostring(json))
		return nil
	end
	local ok, compressed = pcall(LZ4.compress, json)
	if not ok then
		Debugger:Log("warn", "_compressState", "Failed to LZ4 compress state: "..tostring(compressed))
		return nil
	end
	local compressedString
	if type(compressed) == "table" then
		compressedString = string.char(unpack(compressed))
	elseif type(compressed) == "string" then
		compressedString = compressed
	else
		Debugger:Log("warn", "_compressState", "LZ4.compress returned unknown type: "..type(compressed))
		return nil
	end
	local ok, base64Str = pcall(Base64.encode, compressedString)
	if not ok then
		Debugger:Log("warn", "_compressState", "Failed to Base64Encode state: "..tostring(base64Str))
		return nil
	end
	return base64Str
end

local function _decompressState(compressed: string): any?
	local ok, lz4String = pcall(Base64.decode, compressed)
	if not ok then
		Debugger:Log("warn", "_decompressState", "Failed to Base64Decode state: "..tostring(lz4String))
		return nil
	end
	local ok, json = pcall(LZ4.decompress, lz4String)
	if not ok then
		Debugger:Log("warn", "_decompressState", "Failed to LZ4 decompress state: "..tostring(json))
		return nil
	end
	local ok, state = pcall(HttpService.JSONDecode, HttpService, json)
	if not ok then
		Debugger:Log("warn", "_decompressState", "Failed to JSONDecode state: "..tostring(state))
		return nil
	end
	return state
end

function FullState:_safeCallListener(listener: (...any)->(), ...:any)
	if self._destroyed then return end
	local args = {...}
	local success, err = pcall(function() 
		listener(table.unpack(args)) 
	end)
	if not success then
		local errStr = tostring(err)
		Debugger:Log("warn","SafeCall", ("Error in path subscriber: %s")
			:format(errStr))
		self:_queueEvent(self._errorSignal, "PathSubscriber", errStr, listener)
	end
end

local function _getStateByPath(state: any, path: string): any
	if type(state) ~= "table" then
		return nil
	end
	local current = state
	for part in string.gmatch(path, "([^.]+)") do
		if type(current) ~= "table" then
			return nil
		end
		current = current[part]
	end
	return current
end

function FullState:_acquireLock()
	self._mutex:lock()
end

function FullState:_releaseLock()
	local eventsToFire
	local eventsToFire
	if #self._eventQueue > 0 then
		eventsToFire = self._eventQueue
		self._eventQueue = {}
	end
	self._mutex:unlock()
	if eventsToFire then
		for _, event in ipairs(eventsToFire) do
			if event and event.Signal then
				local ok, err = pcall(function()
					event.Signal:Fire(unpack(event.Args))
				end)
				if not ok then
					Debugger:Log("warn", "_releaseLock", "Failed to fire event: "..tostring(err))
				end
			end
		end
	end
end

function FullState:_queueEvent(signalInstance, ...)
	if not self._destroyed then
		table.insert(self._eventQueue, {Signal = signalInstance, Args = {...}})
	end
end

-- Main Logic ----------------------------------------------------------------------------------------------

function FullState.Create(StateName: string, initialState: any, reducer: TypeDef.Reducer?, options: TypeDef.CreateOptions?): TypeDef.FullState
	createMutex:lock()
	if typeof(StateName) ~= "string" then
		Debugger:Log("error", "Create", "StateName must be a string")
	end
	if States[StateName] then
		Debugger:Log("warn", "Create", "State manager '"..StateName.."' already exists. Returning existing instance.")
		createMutex:unlock()
		return States[StateName]
	end
	local self = setmetatable({}, FullState)
	self._name = StateName
	self._state = deepCopy(initialState)
	self._reducer = reducer
	self._middleware = {}
	self._selectors = {}
	self._stateHash = xxHash.hash32Hex(HttpService:JSONEncode(self._state))
	-- Concurrency & State
	self._mutex = Mutex.new()
	self._destroyed = false
	self._readOnly = false
	self._eventQueue = {}
	-- Time travel debugging
	self._history = BPlusTree.new(5)
	self._historySize = 1
	self._historyIndex = 1
	self._maxHistorySize = 50
	local compressedInitial = _compressState(initialState)
	if compressedInitial then
		self._history:Insert(1, compressedInitial)
	else
		Debugger:Log("warn", "Create", "Failed to compress initial state for history.")
	end
	-- Action tracking & Auditing
	self._actionHistory = {}
	self._maxActionHistory = 100
	self._actionAuditLog = {}
	self._lastAuditTree = nil
	self._dedupeLog = nil
	if options and options.deduplication and options.deduplication.enabled then
		local config = options.deduplication
		self._dedupeLog = DedupeLog.new(config.maxSize, config.maxAge)
	end
	-- Batch updates
	self._batchDepth = 0
	self._pendingNotifications = false
	-- Performance tracking
	self._metrics = {
		dispatchCount = 0,
		lastDispatchTime = 0,
		historySize = 1,
		listenerCount = 0,
		middlewareCount = 0,
		selectorCount = 0
	}
	-- Signals
	self._pathSubscribers = RadixTree.new()
	self._dispatchSignal = Signal.new()
	self._commitSignal = Signal.new()
	self._changedSignal = Signal.new()
	self._errorSignal = Signal.new()
	States[StateName] = self
	createMutex:unlock()
	return self
end

function FullState:Destroy()
	if self._destroyed then
		Debugger:Log("error", "Destroy", "Attempt to use a destroyed state instance.")
		return
	end
	self:_acquireLock()
	if self._destroyed then
		self:_releaseLock()
		return
	end
	self._destroyed = true
	self._readOnly = true
	createMutex:lock()
	States[self._name] = nil
	createMutex:unlock()
	self._state = nil
	self._reducer = nil
	self._middleware = nil
	self._selectors = nil
	self._history = nil
	self._actionHistory = nil
	self._actionAuditLog = nil
	self._lastAuditTree = nil
	if self._pathSubscribers then
		self._pathSubscribers:Clear()
		self._pathSubscribers = nil
	end
	self._dedupeLog = nil
	self._dispatchSignal:DisconnectAll()
	self._commitSignal:DisconnectAll()
	self._changedSignal:DisconnectAll()
	self._errorSignal:DisconnectAll()
	self._dispatchSignal = nil
	self._commitSignal = nil
	self._changedSignal = nil
	self._errorSignal = nil
	self._metrics = nil
	self:_releaseLock()
end

function FullState:ReadOnly(state: boolean)
	if self._destroyed then
		Debugger:Log("error", "ReadOnly", "Attempt to use a destroyed state instance.")
		return
	end
	self:_acquireLock()
	if type(state) == "boolean" then
		self._readOnly = state
	else
		Debugger:Log("error", "ReadOnly", "Expected boolean, got "..type(state))
	end
	self:_releaseLock()
end

function FullState:GetState(): any
	if self._destroyed then
		Debugger:Log("error", "GetState", "Attempt to use a destroyed state instance.")
		return
	end
	local success, result = pcall(function()
		return deepFreeze(deepCopy(self._state))
	end)
	if success then
		return result
	end
	return nil
end

function FullState:GetStateHash(): string
	if self._destroyed then
		Debugger:Log("error", "GetStateHash", "Attempt to use a destroyed state instance.")
		return ""
	end
	return self._stateHash
end

function FullState:OnChanged(listener: TypeDef.Listener): RBXScriptSignal
	if self._destroyed then
		Debugger:Log("error", "OnChanged", "Attempt to use a destroyed state instance.")
		return
	end
	return self._changedSignal:Connect(listener)
end

function FullState:OnDispatch(listener: (action: TypeDef.Action) -> ())
	if self._destroyed then
		Debugger:Log("error", "OnDispatch", "Attempt to use a destroyed state instance.")
		return
	end
	return self._dispatchSignal:Connect(listener)
end

function FullState:OnCommit(listener: (newState: any, oldState: any, action: TypeDef.Action) -> ())
	if self._destroyed then
		Debugger:Log("error", "OnCommit", "Attempt to use a destroyed state instance.")
		return
	end
	return self._commitSignal:Connect(listener)
end

function FullState:OnError(listener: ErrorCallback)
	if self._destroyed then
		Debugger:Log("error", "OnError", "Attempt to use a destroyed state instance.")
		return
	end
	return self._errorSignal:Connect(listener)
end

function FullState:use(middleware: Middleware)
	if self._destroyed then
		Debugger:Log("error", "use", "Attempt to use a destroyed state instance.")
		return
	end
	self:_acquireLock()
	if self._readOnly then
		Debugger:Log("warn", "use", "State is in read-only mode; operation ignored.")
		self:_releaseLock()
		return self
	end
	table.insert(self._middleware, middleware)
	self._metrics.middlewareCount = #self._middleware
	self:_releaseLock()
	return self
end

function FullState:Dispatch(action: TypeDef.Action)
	if self._destroyed then
		Debugger:Log("error", "Dispatch", "Attempt to use a destroyed state instance.")
		return
	end
	if self._readOnly then
		Debugger:Log("warn", "Dispatch", "State is in read-only mode; operation ignored.")
		return
	end
	if self._dedupeLog then
		local isDuplicate = self._dedupeLog:CheckAndAdd(action)
		return
	end
	self:_acquireLock()
	local success, result = pcall(function()
		self:_queueEvent(self._dispatchSignal, action)
		local startTime = os.clock()
		local oldState = deepCopy(self._state)
		local function finalDispatch()
			if type(action) ~= "table" or not action.type then
				Debugger:Log("error", "Dispatch", "Action must be a table with a 'type' field")
				return
			end
			if self._reducer then
				self._state = self._reducer(self._state, action)
			end
		end
		local next = finalDispatch
		if #self._middleware > 0 then
			for i = #self._middleware, 1, -1 do
				local middleware = self._middleware[i]
				local nextInChain = next 
				next = function()
					middleware(self, action, nextInChain)
				end
			end
		end next()
		self:_queueEvent(self._commitSignal, self._state, oldState, action)
		local allPaths = self._pathSubscribers:GetAllKeys()
		if #allPaths > 0 then
			for _, path in ipairs(allPaths) do
				local newValue = _getStateByPath(self._state, path)
				local subscribers = self._pathSubscribers:Search(path)
				if subscribers then
					for _, subInfo in ipairs(subscribers) do
						local oldValue = subInfo.lastValue
						if not subInfo.equality(newValue, oldValue) then
							subInfo.lastValue = newValue
							self:_safeCallListener(subInfo.listener, newValue, oldValue)
						end
					end
				end
			end
		end
		self:_recordAction(action, os.clock() - startTime)
		self:_recordStateHistory(self._state)
		self._stateHash = xxHash.hash32Hex(HttpService:JSONEncode(self._state))
		if self._batchDepth > 0 then
			self._pendingNotifications = true
		else
			self:_queueEvent(self._changedSignal, self._state,
				oldState, action, self._stateHash)
		end
		self._metrics.dispatchCount += 1
		self._metrics.lastDispatchTime = os.clock() - startTime
	end)
	if not success then
		local errStr = ("Internal failure: %s\n%s")
			:format(tostring(result), debug.traceback(nil, 2))
		self:_queueEvent(self._errorSignal, "Dispatch", errStr, action)
		self:_releaseLock()
		Debugger:Log("error", "Dispatch", errStr)
	end
	self:_releaseLock()
end

function FullState:CreateSlice(slicePath: string): FullState
	if self._destroyed then
		Debugger:Log("error", "CreateSlice", "Attempt to use a destroyed parent state instance.")
		return
	end
	if type(slicePath) ~= "string" or slicePath == "" then
		Debugger:Log("error", "CreateSlice", "slicePath must be a non-empty string.")
		return
	end
	local sliceStore = {
		_parentStore = self,
		_slicePath = slicePath,
	}
	function sliceStore:GetState()
		local parentState = self._parentStore:GetState()
		return _getStateByPath(parentState, self._slicePath)
	end
	function sliceStore:Dispatch(action: TypeDef.Action)
		if type(action) ~= "table" or not action.type then
			Debugger:Log("error", "Dispatch (slice)", "Action must be a table with a 'type' field")
			return
		end
		local prefixedAction = deepCopy(action)
		prefixedAction.type = self._slicePath.."/"..action.type
		return self._parentStore:Dispatch(prefixedAction)
	end
	function sliceStore:CreateSelector(selectorFn: Selector, equalityFn: ((any, any) -> boolean)?)
		local wrappedSelector = function(parentState: any)
			local sliceState = _getStateByPath(parentState, self._slicePath)
			return selectorFn(sliceState)
		end
		return self._parentStore:CreateSelector(wrappedSelector, equalityFn)
	end
	function sliceStore:SubscribeToPath(subPath: string, listener: (newValue: any, oldValue: any) -> (), options: {equalityFn: ((any, any) -> boolean)?}?)
		local fullPath = self._slicePath.."."..subPath
		return self._parentStore:SubscribeToPath(fullPath, listener, options)
	end
	function sliceStore:OnChanged(listener: Listener)
		local pathPrefix = "^"..self._slicePath.."/"
		local wrappedListener = function(newState: any, oldState: any, action: TypeDef.Action, stateHash: string)
			if string.match(action.type, pathPrefix) then
				local newSliceState = _getStateByPath(newState, self._slicePath)
				local oldSliceState = _getStateByPath(oldState, self._slicePath)
				self:_safeCallListener(listener, newSliceState, oldSliceState, action, stateHash)
			end
		end
		return self._parentStore:OnChanged(wrappedListener)
	end
	setmetatable(sliceStore, { __index = self })
	return sliceStore
end

function FullState:Batch(callback: () -> ())
	if self._destroyed then
		Debugger:Log("error", "Batch", "Attempt to use a destroyed state instance.")
		return
	end
	if self._readOnly then
		Debugger:Log("warn", "Batch", "State is in read-only mode; operation ignored.")
		return
	end
	self:_acquireLock()
	local oldState = deepCopy(self._state)
	self._batchDepth += 1
	self:_releaseLock()
	local success, err = pcall(callback)
	self:_acquireLock()
	self._batchDepth -= 1
	if not success then
		local errStr = "Error during batch callback: "..tostring(err)
		self:_queueEvent(self._errorSignal, "Batch", errStr)
		Debugger:Log("error", "Batch", errStr)
	end
	if self._batchDepth == 0 and self._pendingNotifications then
		self._pendingNotifications = false
		self:_queueEvent(self._changedSignal, self._state, oldState, {type="@@BATCH"}, self._stateHash)
	end
	self:_releaseLock()
end

function FullState:CreateSelector(selectorFn: Selector, equalityFn: ((any, any) -> boolean)?)
	local equality = equalityFn or shallowEqual
	local lastResult = nil
	local lastStateHash = nil
	local storeInstance = self
	self:_acquireLock()
	self._metrics.selectorCount = (self._metrics.selectorCount or 0) + 1
	self:_releaseLock()
	return function(): any
		if storeInstance._destroyed then return end
		if lastResult ~= nil and storeInstance._stateHash == lastStateHash then
			return lastResult
		end
		local currentResult = selectorFn(storeInstance._state)
		if lastResult ~= nil and equality(lastResult, currentResult) then
			lastStateHash = storeInstance._stateHash
			return lastResult
		end
		lastResult = currentResult
		lastStateHash = storeInstance._stateHash
		return currentResult
	end
end

function FullState:Undo()
	if self._destroyed then
		Debugger:Log("error", "Undo", "Attempt to use a destroyed state instance.")
		return
	end
	if self._readOnly then
		Debugger:Log("warn", "Undo", "State is in read-only mode; operation ignored.")
		return
	end
	self:_acquireLock()
	local success, result = pcall(function()
		if self._historyIndex > 1 then
			self._historyIndex -= 1
			local oldState = deepCopy(self._state)
			local compressedState = self._history:Search(self._historyIndex)
			if not compressedState then
				Debugger:Log("warn", "Undo", "Failed to find history state at index: "..self._historyIndex)
				return
			end
			self._state = _decompressState(compressedState)
			self._stateHash = xxHash.hash32Hex(HttpService:JSONEncode(self._state))
			self:_queueEvent(self._changedSignal, self._state, oldState, {type = "@@UNDO"}, self._stateHash)
			
		end
	end)
	self:_releaseLock()
	if not success then
		local errStr = ("Internal failure: %s\n%s")
			:format(tostring(result), debug.traceback(nil, 2))
		self:_queueEvent(self._errorSignal, "Undo", errStr)
		Debugger:Log("error", "Undo", errStr)
	end
end

function FullState:Redo()
	if self._destroyed then
		Debugger:Log("error", "Redo", "Attempt to use a destroyed state instance.")
		return
	end
	if self._readOnly then
		Debugger:Log("warn", "Redo", "State is in read-only mode; operation ignored.")
		return
	end
	self:_acquireLock()
	local success, result = pcall(function()
		local maxKey, _ = self._history:GetMax()
		if maxKey and self._historyIndex < maxKey then
			self._historyIndex += 1
			local oldState = deepCopy(self._state)
			local compressedState = self._history:Search(self._historyIndex)
			if not compressedState then
				Debugger:Log("warn", "Redo", "Failed to find history state at index: "..self._historyIndex)
				return
			end
			self._state = _decompressState(compressedState)
			self._stateHash = xxHash.hash32Hex(HttpService:JSONEncode(self._state))
			self:_queueEvent(self._changedSignal, self._state, oldState, {type = "@@REDO"}, self._stateHash)
			
		end
	end)
	self:_releaseLock()
	if not success then
		local errStr = ("Internal failure: %s\n%s")
			:format(tostring(result), debug.traceback(nil, 2))
		self:_queueEvent(self._errorSignal, "Redo", errStr)
		Debugger:Log("error", "Redo", errStr)
	end
end

function FullState:Snapshot(): StateSnapshot
	if self._destroyed then
		Debugger:Log("error", "Snapshot", "Attempt to use a destroyed state instance.")
		return
	end
	self:_acquireLock()
	local historyData = self._history:InOrderTraversal()
	local snapshot = {
		state = deepCopy(self._state),
		history = historyData,
		historyIndex = self._historyIndex,
		actionAuditLog = deepCopy(self._actionAuditLog),
		lastAuditRoot = self._lastAuditTree and self._lastAuditTree:getRoot(),
	}
	self:_releaseLock()
	return snapshot
end

function FullState:Restore(snapshot: StateSnapshot)
	if self._destroyed then
		Debugger:Log("error", "Restore", "Attempt to use a destroyed state instance.")
		return
	end
	if self._readOnly then
		Debugger:Log("warn", "Restore", "State is in read-only mode; operation ignored.")
		return
	end
	self:_acquireLock()
	local success, result = pcall(function()
		local oldState = deepCopy(self._state)
		self._state = deepCopy(snapshot.state)
		self._history = BPlusTree.new(5)
		if snapshot.history and type(snapshot.history) == "table" then
			for _, entry in ipairs(snapshot.history) do
				self._history:Insert(entry.key, entry.value)
			end
			self._historySize = #snapshot.history
		else
			self._historySize = 0
		end
		self._historyIndex = snapshot.historyIndex
		self._actionAuditLog = deepCopy(snapshot.actionAuditLog)
		if snapshot.lastAuditRoot and #self._actionAuditLog > 0 then
			self._lastAuditTree = MerkleTree.new(self._actionAuditLog)
			if self._lastAuditTree:getRoot() ~= snapshot.lastAuditRoot then
				Debugger:Log("warn", "Restore", "Restored audit log root hash does not match snapshot root hash. Log may be inconsistent.")
			end
		else
			self._lastAuditTree = nil
		end
		self._stateHash = xxHash.hash32Hex(HttpService:JSONEncode(self._state))
		
		self:_queueEvent(self._changedSignal, self._state, oldState, {type="@@RESTORE"}, self._stateHash)
	end)
	self:_releaseLock()
	if not success then
		local errStr = ("Internal failure: %s\n%s")
			:format(tostring(result), debug.traceback(nil, 2))
		self:_queueEvent(self._errorSignal, "Restore", errStr)
		Debugger:Log("error", "Restore", errStr)
	end
end

function FullState:ToJSON(): string
	if self._destroyed then
		Debugger:Log("error", "ToJSON", "Attempt to use a destroyed state instance.")
		return ""
	end
	local snapshot = self:Snapshot()
	local ok, json = pcall(HttpService.JSONEncode, HttpService, snapshot)
	if not ok then
		Debugger:Log("error", "ToJSON", "Failed to serialize snapshot: "..tostring(json))
		return ""
	end
	return json
end

function FullState:FromJSON(jsonString: string)
	if self._destroyed then
		Debugger:Log("error", "FromJSON", "Attempt to use a destroyed state instance.")
		return
	end
	if self._readOnly then
		Debugger:Log("warn", "FromJSON", "State is in read-only mode; operation ignored.")
		return
	end
	local ok, snapshot = pcall(HttpService.JSONDecode, HttpService, jsonString)
	if not ok then
		local errStr = "Failed to deserialize snapshot: "..tostring(snapshot)
		self:_acquireLock()
		self:_queueEvent(self._errorSignal, "FromJSON", errStr)
		self:_releaseLock()
		Debugger:Log("error", "FromJSON", errStr)
		return
	end
	self:Restore(snapshot)
end

function FullState:GetStateHistoryRange(startIndex: number, endIndex: number): {{key: number, state: any}}
	if self._destroyed then
		Debugger:Log("error", "GetStateHistoryRange", "Attempt to use a destroyed state instance.")
		return {}
	end
	local results = {}
	local rawResults = self._history:RangeQuery(startIndex, endIndex)
	for _, entry in ipairs(rawResults) do
		if entry.value then
			local decompressedState = _decompressState(entry.value)
			if decompressedState then
				table.insert(results, {key = entry.key, state = decompressedState})
			else
				Debugger:Log("warn", "GetStateHistoryRange", "Failed to decompress history entry at key: "..entry.key)
			end
		end
	end
	return results
end

function FullState:SubscribeToPath(path: string, listener: (newValue: any, oldValue: any) -> (), options: {equalityFn: ((any, any) -> boolean)?}?)
	if self._destroyed then
		Debugger:Log("error", "SubscribeToPath", "Attempt to use a destroyed state instance.")
		return
	end
	if type(path) ~= "string" or path == "" then
		Debugger:Log("error", "SubscribeToPath", "Path must be a non-empty string.")
		return
	end
	if type(listener) ~= "function" then
		Debugger:Log("error", "SubscribeToPath", "Listener must be a function.")
		return
	end
	local opts = options or {}
	local equality = opts.equalityFn or shallowEqual
	local currentValue = _getStateByPath(self._state, path)
	local subInfo = {
		listener = listener,
		equality = equality,
		lastValue = currentValue,
	}
	self:_acquireLock()
	local subscribers = self._pathSubscribers:Search(path) or {}
	table.insert(subscribers, subInfo)
	self._pathSubscribers:Insert(path, subscribers)
	self:_releaseLock()
	return function()
		if self._destroyed then return end
		self:_acquireLock()
		local currentSubs = self._pathSubscribers:Search(path)
		if currentSubs then
			for i = #currentSubs, 1, -1 do
				if currentSubs[i].listener == listener then
					table.remove(currentSubs, i)
					break
				end
			end
			if #currentSubs == 0 then
				self._pathSubscribers:Delete(path)
			end
		end
		self:_releaseLock()
	end
end

function FullState:BuildAuditTree(): string?
	if self._destroyed then
		Debugger:Log("error", "BuildAuditTree", "Attempt to use a destroyed state instance.")
		return
	end
	if self._readOnly then
		Debugger:Log("warn", "BuildAuditTree", "State is in read-only mode; operation ignored.")
		return
	end
	self:_acquireLock()
	if #self._actionAuditLog == 0 then
		self:_releaseLock()
		return nil
	end
	self._lastAuditTree = MerkleTree.new(self._actionAuditLog)
	self._actionAuditLog = {}
	local root = self._lastAuditTree:getRoot()
	self:_releaseLock()
	return root
end

function FullState:GetAuditRoot(): string?
	if self._destroyed then
		Debugger:Log("error", "GetAuditRoot", "Attempt to use a destroyed state instance.")
		return
	end
	self:_acquireLock()
	local root = self._lastAuditTree and self._lastAuditTree:getRoot()
	self:_releaseLock()
	return root
end

function FullState:GetActionHistory(): {Action}
	return deepCopy(self._actionHistory)
end

function FullState:GetMetrics(): {[string]: any}
	return deepCopy(self._metrics)
end

function FullState:Transaction(transactionFn: (txStore: FullState) -> any): (boolean, any?)
	if self._destroyed then
		Debugger:Log("error", "Transaction", "Attempt to use a destroyed state instance.")
		return false, "State destroyed"
	end
	if self._readOnly then
		Debugger:Log("warn", "Transaction", "State is in read-only mode; operation ignored.")
		return false, "Read-only mode"
	end
	if type(transactionFn) ~= "function" then
		Debugger:Log("error", "Transaction", "Provided argument must be a function.")
		return false, "Invalid argument: function required"
	end
	local journaledActions = {}
	local transactionState = deepCopy(self._state)
	local txStore = {}
	function txStore:GetState()
		return transactionState
	end
	function txStore:Dispatch(action: TypeDef.Action)
		if type(action) ~= "table" or not action.type then
			Debugger:Log("error", "Dispatch (tx)", "Action must be a table with a 'type' field")
			return
		end
		if self._reducer then
			transactionState = self._reducer(transactionState, action)
		end
		table.insert(journaledActions, action)
	end
	function txStore:CreateSelector(selectorFn: Selector, equalityFn: ((any, any) -> boolean)?)
		local equality = equalityFn or shallowEqual
		local lastValue
		return function(): any
			if self._destroyed then return end
			local currentResult = selectorFn(transactionState) 
			if lastValue and equality(lastValue, currentResult) then
				return lastValue
			end
			lastValue = currentResult
			return currentResult
		end
	end
	setmetatable(txStore, { __index = self })
	self:_acquireLock()
	local startTime = os.clock()
	local oldStateForNotify = deepCopy(self._state)
	local success, results = pcall(transactionFn, txStore)
	if success then
		local duration = os.clock() - startTime
		self._state = transactionState 
		 
		self._stateHash = xxHash.hash32Hex(HttpService:JSONEncode(self._state))
		local txAction = {type="@@TRANSACTION", payload = journaledActions}
		self:_recordAction(txAction, duration)
		self:_recordStateHistory(self._state)
		self:_queueEvent(self._changedSignal, self._state, oldStateForNotify, txAction, self._stateHash)
	else
		local errStr = "Transaction function failed: "..tostring(results)
		self:_queueEvent(self._errorSignal, "Transaction", errStr, results)
		Debugger:Log("warn", "Transaction", errStr..". Operations discarded.")
	end
	self:_releaseLock()
	if success then
		if type(results) == "table" and results.n ~= nil then
			return true, table.unpack(results, 1, results.n)
		end
		return true, results
	else
		return false, results
	end
end

function FullState:Reset(...)
	if self._destroyed then
		Debugger:Log("error", "Reset", "Attempt to use a destroyed state instance.")
		return
	end
	if self._readOnly then
		Debugger:Log("warn", "Reset", "State is in read-only mode; operation ignored.")
		return
	end
	local argCount = select("#", ...)
	local args = {...}
	self:_acquireLock()
	local success, result = pcall(function()
		local oldState = deepCopy(self._state)
		local compressedInitial = self._history:Search(1) 
		local initialState
		if argCount > 0 then
			initialState = deepCopy(args[1])
		else
			initialState = _decompressState(compressedInitial)
		end
		self._state = initialState
		self._history = BPlusTree.new(5)
		self._history:Insert(1, _compressState(initialState))
		self._historySize = 1
		self._historyIndex = 1
		self._actionHistory = {}
		self._actionAuditLog = {}
		self._lastAuditTree = nil
		self._stateHash = xxHash.hash32Hex(HttpService:JSONEncode(self._state))
		self:_queueEvent(self._changedSignal, self._state, oldState, {type = "@@RESET"}, self._stateHash)
	end)
	self:_releaseLock()
	if not success then
		local errStr = ("Internal failure: %s\n%s")
			:format(tostring(result), debug.traceback(nil, 2))
		self:_queueEvent(self._errorSignal, "Reset", errStr)
		Debugger:Log("error", "Reset", errStr)
	end
end

function FullState:Disconnect(connectionId: number)
	if self._destroyed then return end
	if type(connectionId) ~= "number" then
		Debugger:Log("warn", "Disconnect", "Invalid connectionId, expected a number.")
		return
	end
	self:_acquireLock()
	self._dispatchSignal:Disconnect(connectionId)
	self._commitSignal:Disconnect(connectionId)
	self._changedSignal:Disconnect(connectionId)
	self._errorSignal:Disconnect(connectionId)
	self:_releaseLock()
end

function FullState:ClearListeners()
	if self._destroyed then
		Debugger:Log("error", "ClearListeners", "Attempt to use a destroyed state instance.")
		return
	end
	self:_acquireLock()
	self._changedSignal:DisconnectAll()
	self:_releaseLock()
end

function FullState:WaitForChange(selectorFn: Selector?, timeout: number?): (any?, string?)
	if self._destroyed then
		return nil, "state destroyed"
	end
	local selector = selectorFn or function(s) return s end
	local co = coroutine.running()
	if not co then
		local errStr = "WaitForChange must be called from a coroutine (e.g., inside task.spawn)."
		Debugger:Log("error", "WaitForChange", errStr)
		return nil, errStr
	end
	local startValue
	local ok, result = pcall(selector, self:GetState())
	if not ok then
		local errStr = "Selector function failed on initial call: "..tostring(result)
		Debugger:Log("error", "WaitForChange", errStr)
		return nil, errStr
	end
	startValue = result
	local connection
	local timeoutThread
	local function onStateChanged(newState: S)
		local currentValue
		local ok_s, result_s = pcall(selector, newState)
		if not ok_s then
			if timeoutThread then task.cancel(timeoutThread) end
			if connection then self:Disconnect(connection) end
			if coroutine.status(co) == "suspended" then
				coroutine.resume(co, nil, "Selector function failed during wait: "..tostring(result_s))
			end
			return
		end
		currentValue = result_s
		if currentValue ~= startValue then
			if timeoutThread then task.cancel(timeoutThread) end
			if connection then self:Disconnect(connection) end
			if coroutine.status(co) == "suspended" then
				coroutine.resume(co, currentValue, nil)
			end
		end
	end
	local function onTimeout()
		if connection then self:Disconnect(connection) end
		if coroutine.status(co) == "suspended" then
			coroutine.resume(co, nil, "timeout")
		end
	end
	connection = self:OnChanged(onStateChanged)
	if timeout and timeout > 0 then
		timeoutThread = task.delay(timeout, onTimeout)
	end
	local newValue, errorMsg = coroutine.yield()
	return newValue, errorMsg
end

function FullState:_recordStateHistory(state: any)
	local maxKey, _ = self._history:GetMax()
	if maxKey and maxKey > self._historyIndex then
		for k = self._historyIndex + 1, maxKey do
			local success, err = pcall(self._history.Delete, self._history, k)
			if success then
				self._historySize = math.max(0, self._historySize - 1)
			else
				Debugger:Log("warn", "_recordStateHistory", ("Failed to delete history key %d: %s")
					:format(k, tostring(err)))
			end
		end
	end
	local compressed = _compressState(state)
	if not compressed then
		Debugger:Log("warn", "_recordStateHistory", "Failed to compress state for history, not recording.")
		return
	end
	self._historyIndex = self._historyIndex + 1
	self._history:Insert(self._historyIndex, compressed)
	self._historySize = self._historySize + 1
	while self._historySize > self._maxHistorySize do
		local minKey, _ = self._history:GetMin()
		if minKey then
			local success, err = pcall(self._history.Delete, self._history, minKey)
			if success then
				self._historySize = math.max(0, self._historySize - 1)
			else
				Debugger:Log("warn", "_recordStateHistory", ("Failed to prune history key %d: %s")
					:format(minKey, tostring(err)))
				break
			end
		else
			break
		end
	end
	self._metrics.historySize = self._historySize
end

function FullState:_recordAction(action: TypeDef.Action, executionTime: number)
	local actionRecord = {
		action = deepCopy(action),
		timestamp = os.time(),
		executionTime = executionTime
	}
	table.insert(self._actionHistory, actionRecord)
	local ok, auditString = pcall(HttpService.JSONEncode, HttpService, actionRecord)
	if ok then
		table.insert(self._actionAuditLog, xxHash.hash32Hex(auditString))
	else
		Debugger:Log("warn", "_recordAction", "Failed to serialize action for audit log.")
	end
	while #self._actionHistory > self._maxActionHistory do
		table.remove(self._actionHistory, 1)
	end
end

function FullState.combineReducers(reducers: {[string]: TypeDef.Reducer}): TypeDef.Reducer
	if type(reducers) ~= "table" then
		Debugger:Log("error", "combineReducers", "Expected 'reducers' to be a table, got "..type(reducers))
		return function(state) return state end
	end
	local reducerKeys = {}
	for key, reducer in pairs(reducers) do
		if type(reducer) ~= "function" then
			Debugger:Log("error", "combineReducers", ("Reducer for key '%s' is not a function, got %s")
				:format(tostring(key), type(reducer)))
			return function(state) return state end
		end
		table.insert(reducerKeys, key)
	end
	return function(state: any, action: TypeDef.Action)
		local hasChanged = false
		local nextState = nil 
		for _, key in ipairs(reducerKeys) do
			local reducer = reducers[key]
			local previousStateForKey = state[key]
			local nextStateForKey = reducer(previousStateForKey, action)
			if nextStateForKey == nil then
				Debugger:Log("warn", "combineReducers", ("Reducer for key '%s' returned nil for action '%s'.")
					:format(tostring(key), tostring(action.type)))
			end
			if previousStateForKey ~= nextStateForKey then
				hasChanged = true
				if nextState == nil then
					nextState = {}
					for k, v in pairs(state) do
						nextState[k] = v
					end
				end
				nextState[key] = nextStateForKey
			elseif nextState ~= nil then
				nextState[key] = nextStateForKey
			end
		end
		return hasChanged and nextState or state
	end
end

FullState.middleware = {}

function FullState.middleware.logger()
	return function(store: any, action: TypeDef.Action, next: () -> ())
		local prevState = store:GetState()
		Debugger:Log("print", "logger", ("Action: %s")
			:format(action.type)) next()
		local nextState = store:GetState()
		Debugger:Log("print", "logger", "State updated")
	end
end

function FullState.middleware.thunk()
	return function(store: any, action: TypeDef.Action, next: () -> ())
		if type(action) == "function" then
			local dispatch = function(act)
				store:Dispatch(act)
			end
			local getState = function()
				return store:GetState()
			end
			action(dispatch, getState)
		else
			next()
		end
	end
end

function FullState.middleware.performance(threshold: number?)
	local warnThreshold = threshold or 0.016
	return function(store: any, action: TypeDef.Action, next: () -> ())
		local start = os.clock() next()
		local duration = os.clock() - start
		if duration > warnThreshold then
			Debugger:Log("warn", "performance", ("Slow action '%s' took %.3fms")
				:format(action.type,duration * 100))
		end
	end
end

function FullState.middleware.validator(schema: {[string]: string})
	return function(store: any, action: TypeDef.Action, next: () -> ())
		local expectedType = schema[action.type]
		if expectedType then
			local payloadType = type(action.payload)
			if payloadType ~= expectedType then
				Debugger:Log("error", "validator",("Invalid payload type for action '%s'. Expected %s, got %s")
					:format(action.type,expectedType,payloadType))
				return
			end
		end
		next()
	end
end
FullState.Version = Version; FullState.Registry = States
return Debugger:Profile(FullState, "Create", script) :: TypeDef.Static
