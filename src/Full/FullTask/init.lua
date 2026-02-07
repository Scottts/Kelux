--!optimize 2
--[[
	AUTHOR: Kel (@GudEveningBois)

	Created:
	idk, somewhere after FullPool was released
	
	Read documentary in FullTask.Documentary
]]
local VERSION = "0.1.384 (STABLE)"

local FullTask = {}
FullTask.__index = FullTask

-- Services
local HttpService = game:GetService("HttpService")

-- Dependencies
local TypeDef = require(script.TypeDef)
local Components = script.Parent.Parent.Components
local Debugger = require(Components.Debugger).From(script.Name)
local TTLService = require(Components.TTLService)
local Signal = require(Components.KelSignal)
local CronParser = require(Components.CronParser)
local Mutex = require(Components.Mutex)

-- Algorithms
local TopologicalSort = require(Components.Algorithms.TopologicalSort)
local FibonacciHeap = require(Components.Algorithms.FibonacciHeap)
local PairingHeap = require(Components.Algorithms.PairingHeap)
local Semaphore = require(Components.Algorithms.Semaphore)
local Trie = require(Components.Algorithms.Trie)
local CHF = require(Components.Algorithms.CHF)
local TBA = require(Components.Algorithms.TBA)

local TaskState = {
	PENDING = "PENDING",
	RUNNING = "RUNNING",
	COMPLETED = "COMPLETED",
	FAILED = "FAILED",
	CANCELLED = "CANCELLED",
	WAITING = "WAITING"
}

local Priority = {
	LOW = 1,
	NORMAL = 2,
	HIGH = 3,
	CRITICAL = 4
}

function FullTask:_getTime()
	return os.time()
end

local function generateContentHashFromOptions(fn, options)
	options = options or {}
	local hashInput = {
		tostring(fn),
		options.name or "",
		HttpService:JSONEncode(options.data or {}),
		options.priority or Priority.NORMAL,
		options.maxRetries or 0,
		options.timeout or 0,
		HttpService:JSONEncode(options.resources or {}),
		HttpService:JSONEncode(options.dependencies or {}),
		options.cronExpression or "",
	}
	if options.id then
		table.insert(hashInput, tostring(options.id))
	end
	local serializedContent = HttpService:JSONEncode(hashInput)
	return CHF.SHA256(serializedContent)
end
local _taskManagers = {}
local _globalMutex = Mutex.new()

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

local function _stringToSequence(str)
	local seq = {}
	for i = 1, #str do
		table.insert(seq, string.sub(str, i, i))
	end
	return seq
end

function FullTask:_getAllIdsFromNode(startNode)
	local ids = {}
	local function recurse(node)
		if node.isTerminal and node.actionName then
			table.insert(ids, node.actionName)
		end
		for _, childNode in pairs(node.children) do
			recurse(childNode)
		end
	end
	recurse(startNode)
	return ids
end

local function _globToLuaPattern(glob: string)
	local pattern = glob
	pattern = string.gsub(pattern, "%.", "%%.")
	pattern = string.gsub(pattern, "%+", "%%+")
	pattern = string.gsub(pattern, "%-", "%%-")
	pattern = string.gsub(pattern, "%(", "%%(")
	pattern = string.gsub(pattern, "%)", "%%)")
	pattern = string.gsub(pattern, "%[", "%%[")
	pattern = string.gsub(pattern, "%]", "%%]")
	pattern = string.gsub(pattern, "%?", ".")
	pattern = string.gsub(pattern, "%*", ".*")
	return "^"..pattern.."$"
end

local Task = {}
Task.__index = Task

function Task.new(fn, options)
	local self = setmetatable({
		id = options.id or HttpService:GenerateGUID(false),
		name = options.name or "Unnamed _Task",
		fn = fn,
		priority = options.priority or Priority.NORMAL,
		retries = options.retries or 0,
		maxRetries = options.maxRetries or 0,
		timeout = options.timeout,
		resources = options.resources or {},
		dependencies = options.dependencies or {},
		dependents = {},
		scheduledFor = options.scheduledFor,
		cronExpression = options.cronExpression,
		recurringCount = options.recurringCount,
		state = (options.cronExpression ~= nil) and TaskState.WAITING or TaskState.PENDING,
		cancellationRequested = false,
		data = options.data or {},
		thread = nil,
		submitTime = os.time(),
		startTime = nil,
		endTime = nil,
		result = nil,
		error = nil,
		parsedCron = nil,
		_heapNode = nil,
	}, Task)
	self.isRecurring = self.cronExpression ~= nil
	if not self.isRecurring and self.scheduledFor then
		self.state = TaskState.WAITING
	end
	if self and self.cronExpression then
		local success, parser = pcall(CronParser.new, self.cronExpression)
		if success then
			self.parsedCron = parser
			if self.isRecurring and not options.scheduledFor then
				self.scheduledFor = self.parsedCron:getNextRun(os.time())
			end
		else
			Debugger:Log("error","new",("Invalid cron expression: %s - %s")
				:format(self.cronExpression,parser))
			return nil
		end
	end
	return self
end

function Task:setState(newState)
	self.state = newState
end

function FullTask:_internalTimeoutTask(taskId)
	self.mutex:lock()
	local _Task = self.tasks[taskId]
	if not _Task then 
		self.mutex:unlock()
		return 
	end
	if _Task.state ~= TaskState.RUNNING then
		self.mutex:unlock()
		return 
	end
	_Task:setState(TaskState.FAILED)
	_Task.error = "Task timed out after "..tostring(_Task.timeout).."s"
	self.metrics.tasksFailed = self.metrics.tasksFailed + 1
	self.mutex:unlock()
end

function FullTask.Create(NameOrConfig, Options)
	local config = Options or {}
	local name
	if type(NameOrConfig) == "string" then
		name = NameOrConfig
	elseif type(NameOrConfig) == "table" then
		config = NameOrConfig
		name = config.name
	end
	name = name or HttpService:GenerateGUID(false)
	config.name = name
	_globalMutex:lock()
	if _taskManagers[name] and not _taskManagers[name]._isDestroying then
		local existing = _taskManagers[name]
		_globalMutex:unlock()
		return existing
	end
	_globalMutex:unlock()
	local taskRateLimit = config.taskRateLimit or 50
	local self = setmetatable({
		name = name,
		maxConcurrency = config.maxConcurrency or 10,
		maxLoadPerHeartbeat = config.maxLoadPerHeartbeat or 0.005,
		currentConcurrency = 0,
		_currentFrameLoad = 0,
		autoProcessInterval = config.autoProcessInterval or 0.1,
		_isDestroying = false,
		_shouldRunLoop = true,
		tasks = {},
		runningTasks = {},
		completedTasks = {},
		failedTasks = {},
		cancelledTasks = {},
		scheduledTasks = {},
		tasksByContentHash = {},
		_eventQueue = {},
		mutex = Mutex.new(),
		nameTrie = Trie.new(),
	}, FullTask)
	local heapType = (config.heapType and string.lower(config.heapType)) or "pairingheap" 
	if heapType == "fibonacciheap" then
		self.priorityQueue = FibonacciHeap.new()
	elseif heapType == "pairingheap" then
		self.priorityQueue = PairingHeap.new()
	else
		Debugger:Log("error","Create",("Invalid heapType: %q"):format(heapType))
	end
	self.signals = {
		taskQueued = Signal.new(),
		taskStarted = Signal.new(),
		taskCompleted = Signal.new(),
		taskFailed = Signal.new(),
		taskCancelled = Signal.new(),
		taskRetried = Signal.new(),
		resourceAcquired = Signal.new(),
		resourceReleased = Signal.new(),
		queueEmpty = Signal.new(),
		systemOverload = Signal.new()
	}
	self._mainLoopConnection = nil
	local function onExpire(taskId)
		self:_internalTimeoutTask(taskId)
	end
	self.ttlService = TTLService.new(self, nil, nil, onExpire)
	self.ttlService:start()
	self._resourceLimits = config.resourceLimits or {}
	self._resourceSemaphores = {} 
	self.taskRateLimiter = TBA.new(taskRateLimit, taskRateLimit)
	self.metrics = {
		totalTasksSubmitted = 0,
		tasksCompleted = 0,
		tasksFailed = 0,
		tasksCancelled = 0,
		tasksRetried = 0,
		tasksInQueue = 0, 
		currentConcurrency = 0,
		totalExecutionTime = 0,
		averageExecutionTime = 0,
		uptime = os.time()
	}
	self:_startMainLoop()
	_globalMutex:lock()
	_taskManagers[self.name] = self
	_globalMutex:unlock()
	return self
end

function FullTask:_getResourceSemaphore(resourceName)
	local semaphore = self._resourceSemaphores[resourceName]
	if not semaphore then
		local capacity = self._resourceLimits[resourceName] or math.huge 
		semaphore = Semaphore.new(capacity)
		self._resourceSemaphores[resourceName] = semaphore
	end
	return semaphore
end

function FullTask:_acquireResources(_Task)
	local acquired = {}
	local function releaseAll()
		for _, a in ipairs(acquired) do
			a.sem:release(a.amount)
		end
	end
	for resourceName, amount in pairs(_Task.resources) do
		local semaphore = self:_getResourceSemaphore(resourceName)
		local available = semaphore:getAvailable()
		if available >= amount then
			local ok, err = pcall(function() return semaphore:acquire(amount) end)
			if not ok then
				releaseAll()
				return false
			end
			table.insert(acquired, {resource = resourceName, sem = semaphore, amount = amount})
		else
			releaseAll()
			return false
		end
	end
	return true
end

function FullTask:_reconcileConcurrencyMetrics()
	local runningCount = 0
	if self and self.runningTasks then
		for _ in pairs(self.runningTasks) do runningCount = runningCount + 1 end
	end
	local authoritative = runningCount
	if (self.currentConcurrency or 0) ~= authoritative then
		pcall(function()
			if self.mutex then self.mutex:lock() end
			self.currentConcurrency = authoritative
			if self.metrics then self.metrics.currentConcurrency = self.currentConcurrency end
			if self.mutex then self.mutex:unlock() end
		end)
	end
end

function FullTask:_internalSubmit(taskFn, options)
	options = options or {}
	local contentHash = generateContentHashFromOptions(taskFn, options)
	if options.id and self.tasks[options.id] then
		Debugger:Log("warn", "Submit", ("Attempt to submit _Task with duplicate explicit id: %s"):format(tostring(options.id)))
		return nil
	end
	if self and self.tasksByContentHash[contentHash] then
		Debugger:Log("warn", "Submit", ("_Task with identical content already submitted (existing ID: %s, Content Hash: %s)")
			:format(self.tasksByContentHash[contentHash], contentHash))
		return nil
	end
	local _Task = Task.new(taskFn, options)
	if not _Task then return nil end
	_Task.contentHash = contentHash
	self.tasksByContentHash[contentHash] = _Task.id
	if #_Task.dependencies > 0 then
		local validDependencies = true
		for _, depId in ipairs(_Task.dependencies) do
			local depTask = self.tasks[depId]
			if not depTask then
				Debugger:Log("warn", "Submit", 
					("Attempted to submit _Task %s with non-existent dependency: %s")
						:format(_Task.id, depId))
				validDependencies = false
			end
		end
		if not validDependencies then
			self.tasksByContentHash[_Task.contentHash] = nil
			return nil
		end
		local dependencyGraph = {}
		local nodeSet = {}
		for _, depId in ipairs(_Task.dependencies) do
			local depTask = self.tasks[depId]
			if not dependencyGraph[depId] then dependencyGraph[depId] = {} end
			table.insert(dependencyGraph[depId], _Task.id)
			table.insert(depTask.dependents, _Task.id)
			nodeSet[depId] = true
			nodeSet[_Task.id] = true
		end
		local hasCycle, cycleError = TopologicalSort.hasCycle(dependencyGraph)
		if hasCycle then
			for _, depId in ipairs(_Task.dependencies) do
				local depTask = self.tasks[depId]
				if depTask then
					for i = #depTask.dependents, 1, -1 do
						if depTask.dependents[i] == _Task.id then
							table.remove(depTask.dependents, i)
							break
						end
					end
				end
			end
			self.tasksByContentHash[_Task.contentHash] = nil 
			Debugger:Log("error", "Submit", ("Circular dependency detected when submitting _Task %s: %q")
				:format(_Task.id, cycleError or "unknown cycle"))
			return nil
		end
	end
	self.tasks[_Task.id] = _Task
	self.metrics.totalTasksSubmitted = self.metrics.totalTasksSubmitted + 1
	local success, seq = pcall(_stringToSequence, _Task.name)
	if success and seq then
		self.nameTrie:insert(_Task.id, seq, function() end)
	end
	local allDepsMet = true
	if #_Task.dependencies > 0 then
		for _, depId in ipairs(_Task.dependencies) do
			local depTask = self.tasks[depId]
			if not depTask or depTask.state ~= TaskState.COMPLETED then
				allDepsMet = false
				break
			end
		end
	end
	if _Task.scheduledFor then
		_Task:setState(TaskState.WAITING)
		self.scheduledTasks[_Task.id] = _Task
	elseif not allDepsMet then
		_Task:setState(TaskState.WAITING)
	else
		self:_unsafeEnqueue(_Task)
	end
	return _Task
end

function FullTask:Submit(taskFn: (ctx: TypeDef.TaskExecutionContext) -> ...any, options: TypeDef.TaskOptions?): TypeDef.Task?
	if self and self._destroyed then
		Debugger:Log("error", "Submit", "Attempt to use a destroyed task instance.")
		return nil
	end
	self.mutex:lock()
	local eventsToFire
	local success, result = pcall(function()
		return self:_internalSubmit(taskFn, options)
	end)
	if #self._eventQueue > 0 then
		eventsToFire = self._eventQueue
		self._eventQueue = {}
	end
	self.mutex:unlock()
	if eventsToFire then
		for _, event in ipairs(eventsToFire) do
			pcall(event.Signal.Fire, event.Signal, unpack(event.Args))
		end
	end
	if not success then
		Debugger:Log("error", "Submit", ("Internal failure: %s\n%s")
			:format(tostring(result), debug.traceback(nil, 2)))
	end
	return result
end

function FullTask:_unsafeEnqueue(_Task)
	local newHeapKey = (Priority.CRITICAL - _Task.priority) * 1e12 + (_Task.submitTime)
	if _Task._heapNode then
		if self and self.priorityQueue.updateKey then
			self.priorityQueue:updateKey(_Task._heapNode, newHeapKey)
		else
			self.priorityQueue:delete(_Task._heapNode) 
			_Task._heapNode = self.priorityQueue:insert(newHeapKey, _Task)
		end
	else
		_Task._heapNode = self.priorityQueue:insert(newHeapKey, _Task)
	end
	self.metrics.tasksInQueue = self.priorityQueue.size
	self:_queueEvent(self.signals.taskQueued, _Task)
end

function FullTask:_enqueueTask(_Task)
	self.mutex:lock()
	local eventsToFire
	local success, result = pcall(function()
		self:_unsafeEnqueue(_Task)
	end)
	if #self._eventQueue > 0 then
		eventsToFire = self._eventQueue
		self._eventQueue = {}
	end
	self.mutex:unlock()
	if eventsToFire then
		for _, event in ipairs(eventsToFire) do
			pcall(event.Signal.Fire, event.Signal, unpack(event.Args))
		end
	end
	if not success then
		Debugger:Log("error", "_enqueueTask", ("Internal failure: %s\n%s")
			:format(tostring(result), debug.traceback(nil, 2)))
	end
end

function FullTask:_processQueue()
	self.mutex:lock()
	if self._isPaused then
		self.mutex:unlock()
		return
	end
	if not self.priorityQueue or self.priorityQueue.size == 0 then
		self.mutex:unlock()
		return
	end
	local candidates = {}
	local maxCandidates = math.min(self.priorityQueue.size, math.max(1, self.maxConcurrency * 2))
	for i = 1, maxCandidates do
		if self.priorityQueue.size == 0 then break end
		local node = self.priorityQueue:getMin()
		if not node or not node.value then break end
		self.priorityQueue:extractMin()
		table.insert(candidates, node.value)
	end
	self.metrics.tasksInQueue = self.priorityQueue.size
	local tasksToExecute = {}
	local reinserts = {}
	local eventsToFire
	for _, _Task in ipairs(candidates) do
		if self.currentConcurrency >= self.maxConcurrency then
			table.insert(reinserts, _Task)
			continue
		end
		if self._currentFrameLoad >= self.maxLoadPerHeartbeat then
			table.insert(reinserts, _Task)
			continue
		end
		if self.taskRateLimiter and not self.taskRateLimiter:consume(1) then
			table.insert(reinserts, _Task)
			break 
		end
		self.mutex:unlock()
		local resourcesAvailable = self:_acquireResources(_Task)
		self.mutex:lock()
		if self._destroyed or _Task.state == TaskState.CANCELLED then
			if resourcesAvailable then self:_releaseResources(_Task) end
			continue
		end
		if not resourcesAvailable then
			table.insert(reinserts, _Task)
			continue
		end
		self.currentConcurrency = self.currentConcurrency + 1
		self.runningTasks[_Task.id] = _Task
		_Task:setState(TaskState.RUNNING)
		_Task.startTime = os.time()
		for resourceName, amount in pairs(_Task.resources) do
			self:_queueEvent(self.signals.resourceAcquired, _Task.id, resourceName, amount)
		end
		self:_queueEvent(self.signals.taskStarted, _Task)
		if _Task.timeout and self.ttlService then
			self.ttlService:push(_Task.id, os.time() + _Task.timeout)
		end
		table.insert(tasksToExecute, _Task)
	end
	for _, rTask in ipairs(reinserts) do
		local newHeapKey = (Priority.CRITICAL - rTask.priority) * 1e12 + (os.time() + 0.001)
		rTask._heapNode = self.priorityQueue:insert(newHeapKey, rTask)
	end
	self.metrics.tasksInQueue = self.priorityQueue.size
	if #self._eventQueue > 0 then
		eventsToFire = self._eventQueue
		self._eventQueue = {}
	end
	self.mutex:unlock()
	if eventsToFire then
		for _, event in ipairs(eventsToFire) do
			pcall(event.Signal.Fire, event.Signal, unpack(event.Args))
		end
	end
	for _, _Task in ipairs(tasksToExecute) do
		self:_executeTaskFinal(_Task)
	end
end

function FullTask:_releaseResources(_Task)
	for resourceName, amount in pairs(_Task.resources) do
		local semaphore = self._resourceSemaphores[resourceName]
		if semaphore then
			semaphore:release(amount)
		end
	end
end

function FullTask:_executeTaskFinal(_Task)
	local function _unsafeCleanup(_Task)
		if self.runningTasks and self.runningTasks[_Task.id] then
			self.runningTasks[_Task.id] = nil
			local runningCount = 0
			for _ in pairs(self.runningTasks) do 
				runningCount = runningCount + 1 end
			self.currentConcurrency = runningCount
			if self.metrics then self.metrics.currentConcurrency = self.currentConcurrency end
		end
		if self.tasksByContentHash and _Task.contentHash then
			self.tasksByContentHash[_Task.contentHash] = nil
		end
		if self and self.ttlService then
			self.ttlService:invalidate(_Task.id)
		end
		local success, seq = pcall(_stringToSequence, _Task.name)
		if success and seq then
			self.nameTrie:remove(_Task.id, seq)
		end
		_Task._heapNode = nil
	end
	_Task.thread = coroutine.create(function()
		local execCtx = setmetatable({
			wait = task.wait,
			spawn = task.spawn,
			defer = task.defer,
		}, { __index = _Task })
		local success, result = pcall(_Task.fn, execCtx)
		if self._destroyed or self._isDestroying then
			self.mutex:lock()
			_unsafeCleanup(_Task)
			self.mutex:unlock()
			return
		end
		local shouldProcessQueue = false
		local shouldRetry = false
		local eventsToFire
		local tasksToEnqueueAfterUnlock
		self.mutex:lock()
		if _Task.state == TaskState.FAILED then
			self:_releaseResources(_Task)
			for resourceName, amount in pairs(_Task.resources) do
				self:_queueEvent(self.signals.resourceReleased, _Task.id, resourceName, amount)
			end
			_unsafeCleanup(_Task)
			self:_queueEvent(self.signals.taskFailed, _Task) 
			if #self._eventQueue > 0 then
				eventsToFire = self._eventQueue
				self._eventQueue = {}
			end
			self.mutex:unlock()
			if eventsToFire then
				for _, event in ipairs(eventsToFire) do
					pcall(event.Signal.Fire, event.Signal, unpack(event.Args))
				end
			end
			return
		end
		if success 
		then
			if _Task.state == TaskState.FAILED then
				_Task.error = _Task.error or "Error lost during success path"
			else
				_Task.endTime = os.time()
				_Task.state = TaskState.COMPLETED
				_Task.result = result
				self.metrics.tasksCompleted = self.metrics.tasksCompleted + 1
				local executionTime = _Task.endTime - _Task.startTime
				_Task.executionTime = executionTime
				self._currentFrameLoad = self._currentFrameLoad + executionTime
				self.metrics.totalExecutionTime = self.metrics.totalExecutionTime + executionTime
				self.metrics.averageExecutionTime = self.metrics.totalExecutionTime / self.metrics.tasksCompleted
				self:_releaseResources(_Task)
				for resourceName, amount in pairs(_Task.resources) do
					self:_queueEvent(self.signals.resourceReleased, _Task.id, resourceName, amount)
				end
				_unsafeCleanup(_Task)
				tasksToEnqueueAfterUnlock = self:_signalDependentsOnComplete(_Task)
				self:_queueEvent(self.signals.taskCompleted, _Task)
				shouldProcessQueue = true
			end
		else
			if _Task.state ~= TaskState.FAILED then
				_Task.error = result 
			end
			_Task.retries = _Task.retries + 1
			_Task.endTime = os.time()
			local executionTime = _Task.endTime - _Task.startTime
			_Task.executionTime = executionTime
			self._currentFrameLoad = self._currentFrameLoad + executionTime
			if _Task.retries <= _Task.maxRetries then
				_Task.state = TaskState.PENDING
				self.metrics.tasksRetried = self.metrics.tasksRetried + 1
				self:_releaseResources(_Task)
				for resourceName, amount in pairs(_Task.resources) do
					self:_queueEvent(self.signals.resourceReleased, _Task.id, resourceName, amount)
				end
				_unsafeCleanup(_Task)
				self:_queueEvent(self.signals.taskRetried, _Task)
				shouldRetry = true
				shouldProcessQueue = true
			else
				_Task.state = TaskState.FAILED
				self.metrics.tasksFailed = self.metrics.tasksFailed + 1
				self:_releaseResources(_Task)
				for resourceName, amount in pairs(_Task.resources) do
					self:_queueEvent(self.signals.resourceReleased, _Task.id, resourceName, amount)
				end
				_unsafeCleanup(_Task)
				self:_queueEvent(self.signals.taskFailed, _Task)
				shouldProcessQueue = true
			end
		end
		if #self._eventQueue > 0 then
			eventsToFire = self._eventQueue
			self._eventQueue = {}
		end
		self.mutex:unlock()
		if eventsToFire then
			for _, event in ipairs(eventsToFire) do
				pcall(event.Signal.Fire, event.Signal, unpack(event.Args))
			end
		end
		if tasksToEnqueueAfterUnlock and #tasksToEnqueueAfterUnlock > 0 then
			for _, taskToEnqueue in ipairs(tasksToEnqueueAfterUnlock) do
				self:_enqueueTask(taskToEnqueue)
			end
		end
		if shouldRetry then
			self:_enqueueTask(_Task)
		end
	end)
	coroutine.resume(_Task.thread)
end

function FullTask:_internalUpdateTaskPriority(taskId: string, newPriority: number)
	local _Task = self.tasks[taskId]
	if not _Task then return false end
	local wasScheduled = false
	if self and self.scheduledTasks[taskId] then
		self.scheduledTasks[taskId] = nil
		wasScheduled = true
	end
	if _Task.state == TaskState.CANCELLED
		or _Task.state == TaskState.COMPLETED
		or _Task.state == TaskState.FAILED
	then return wasScheduled end
	if _Task and _Task._heapNode and _Task.state == TaskState.PENDING then 
		_Task.priority = newPriority
		local newHeapKey = (Priority.CRITICAL - _Task.priority) * 1e12 + (_Task.submitTime)
		if self and self.priorityQueue.updateKey then
			self.priorityQueue:updateKey(_Task._heapNode, newHeapKey)
		elseif self and self.priorityQueue.decreaseKey then
			self.priorityQueue:decreaseKey(_Task._heapNode, newHeapKey)
		else
			self.priorityQueue:delete(_Task._heapNode)
			_Task._heapNode = self.priorityQueue:insert(newHeapKey, _Task) 
		end
	end
end

function FullTask:UpdateTaskPriority(taskId: string, newPriority: number)
	if self and self._destroyed then
		Debugger:Log("error", "UpdateTaskPriority", "Attempt to use a destroyed task instance.")
		return
	end
	self.mutex:lock()
	local success, result = pcall(function()
		return self:_internalUpdateTaskPriority(taskId, newPriority)
	end)
	self.mutex:unlock()
	if not success then
		Debugger:Log("error", "UpdateTaskPriority", ("Internal failure: %s\n%s")
			:format(tostring(result), debug.traceback(nil, 2)))
	end
	return result
end

function FullTask:_internalCancelTask(taskId: string, force: boolean?)
	local _Task = self.tasks[taskId]
	if not _Task then return false end
	local wasScheduled = false
	if self and self.scheduledTasks[taskId] then
		self.scheduledTasks[taskId] = nil
		wasScheduled = true
	end
	if _Task.state == TaskState.CANCELLED then
		return true
	end

	if (_Task.state == TaskState.COMPLETED or _Task.state == TaskState.FAILED) and not wasScheduled then
		return false
	end
	if _Task.state == TaskState.RUNNING and not force then
		Debugger:Log("warn", "CancelTask", ("Cannot cancel running _Task %s without force option.")
			:format(taskId))
		return false
	end
	local previousState = _Task.state
	_Task:setState(TaskState.CANCELLED)
	self.metrics.tasksCancelled = self.metrics.tasksCancelled + 1
	_Task.cancellationRequested = true
	if _Task.contentHash and self.tasksByContentHash then
		self.tasksByContentHash[_Task.contentHash] = nil
	end
	local success, seq = pcall(_stringToSequence, _Task.name)
	if success and seq then
		self.nameTrie:remove(_Task.id, seq)
	end
	if previousState == TaskState.RUNNING then
		self.runningTasks[taskId] = nil
		self.currentConcurrency = math.max(0, (self.currentConcurrency or 0) - 1)
		if self.metrics then self.metrics.currentConcurrency = self.currentConcurrency end
		if _Task.thread and coroutine.status(_Task.thread) ~= "dead" then
			pcall(function() coroutine.close(_Task.thread) end)
		end
	end
	if self and self.scheduledTasks[taskId] then
		self.scheduledTasks[taskId] = nil
	end
	local heapNode = _Task._heapNode
	if heapNode then
		self.priorityQueue:delete(heapNode)
		self.metrics.tasksInQueue = self.metrics.tasksInQueue - 1
	end
	self:_queueEvent(self.signals.taskCancelled, _Task)
	return true
end

function FullTask:CancelTask(taskId: string, force: boolean?)
	if self and self._destroyed then
		Debugger:Log("error", "CancelTask", "Attempt to use a destroyed task instance.")
		return
	end
	self.mutex:lock()
	local eventsToFire
	local success, result = pcall(function()
		return self:_internalCancelTask(taskId, force)
	end)
	if #self._eventQueue > 0 then
		eventsToFire = self._eventQueue
		self._eventQueue = {}
	end
	self.mutex:unlock()
	if eventsToFire then
		for _, event in ipairs(eventsToFire) do
			pcall(event.Signal.Fire, event.Signal, unpack(event.Args))
		end
	end
	if not success then
		Debugger:Log("error", "CancelTask", ("Internal failure: %s\n%s")
			:format(tostring(result), debug.traceback(nil, 2)))
	end
	return result
end

function FullTask:_signalDependentsOnComplete(taskObj)
	if not taskObj or not taskObj.dependents then return nil end
	local tasksToEnqueue = {}
	for i = #taskObj.dependents, 1, -1 do
		local depId = taskObj.dependents[i]
		local depTask = self.tasks and self.tasks[depId]
		if depTask then
			local depFound = false
			for j = #depTask.dependencies, 1, -1 do
				if depTask.dependencies[j] == taskObj.id then
					table.remove(depTask.dependencies, j)
					depFound = true
					break
				end
			end
			if depFound and depTask.state == TaskState.WAITING then
				local allDepsMet = true
				for _, otherDepId in ipairs(depTask.dependencies) do
					local otherDepTask = self.tasks[otherDepId]
					if not otherDepTask or otherDepTask.state ~= TaskState.COMPLETED then
						allDepsMet = false
						break
					end
				end
				if allDepsMet then
					depTask:setState(TaskState.PENDING)
					table.insert(tasksToEnqueue, depTask)
				end
			end
		else
			table.remove(taskObj.dependents, i)
		end
	end
	return tasksToEnqueue
end

function FullTask:_signalDependents(taskObj, status)
	if not taskObj then return end
	pcall(function()
		for i = #taskObj.dependents, 1, -1 do
			local depId = taskObj.dependents[i]
			local depTask = self.tasks and self.tasks[depId]
			if depTask then
				for j = #depTask.dependencies, 1, -1 do
					if depTask.dependencies[j] == taskObj.id then
						table.remove(depTask.dependencies, j)
					end
				end
				if status == "CANCELLED" then
					self:_queueEvent(self.signals.taskCancelled, depTask)
				end
			else
				table.remove(taskObj.dependents, i)
			end
		end
	end)
end

function FullTask:_startMainLoop()
	if self and self._mainLoopConnection then return end

	self._reconciler = task.spawn(function()
		local interval = 0.25
		while not (self._destroyed or self._isDestroying) do
			task.wait(interval)
			pcall(function() self:_reconcileConcurrencyMetrics() end)
		end
	end)
	local heartbeatCounter = 0
	self._mainLoopConnection = game:GetService("RunService").Heartbeat:Connect(function(dt)
		self._currentFrameLoad = 0
		heartbeatCounter = heartbeatCounter + 1
		self:_processScheduledTasks()
		self:_processWaitingTasks()
		self:_processQueue()
		if heartbeatCounter >= 20 then
			heartbeatCounter = 0
			pcall(function() self:_reconcileConcurrencyMetrics() end)
		end
	end)
end

function FullTask:_processScheduledTasks()
	local now = os.time()
	local tasksToProcess = {}
	local tasksToEnqueue = {}
	local eventsToFire
	self.mutex:lock()
	local pcall_success, pcall_err = pcall(function()
		for id, _Task in pairs(self.scheduledTasks) do
			if _Task.scheduledFor and _Task.scheduledFor <= now then
				table.insert(tasksToProcess, _Task)
			end
		end
		if #tasksToProcess == 0 then return end
		for _, _Task in ipairs(tasksToProcess) do
			self.scheduledTasks[_Task.id] = nil
			local shouldEnqueue = true
			if _Task.isRecurring then
				shouldEnqueue = self:_internalScheduleRecurring(_Task)
			end
			if shouldEnqueue then
				table.insert(tasksToEnqueue, _Task)
			end
		end
	end)
	if #self._eventQueue > 0 then
		eventsToFire = self._eventQueue
		self._eventQueue = {}
	end
	self.mutex:unlock()
	if eventsToFire then
		for _, event in ipairs(eventsToFire) do
			pcall(event.Signal.Fire, event.Signal, unpack(event.Args))
		end
	end
	if not pcall_success then
		Debugger:Log("error", "_processScheduledTasks", ("Internal failure: %s\n%s")
			:format(tostring(pcall_err), debug.traceback(nil, 2)))
		return
	end
	for _, _Task in ipairs(tasksToEnqueue) do
		_Task:setState(TaskState.PENDING)
		self:_enqueueTask(_Task)
	end
end

function FullTask:_queueEvent(signal, ...)
	table.insert(self._eventQueue, {Signal = signal, Args = {...}})
end

function FullTask:_processWaitingTasks()
	local tasksToResume = {}
	local tasksToCleanup = {}
	local eventsToFire
	self.mutex:lock()
	for id, _Task in pairs(self.runningTasks) do
		if _Task.state == TaskState.WAITING then
			local status = coroutine.status(_Task.coroutine)
			if status == "suspended" then
				table.insert(tasksToResume, _Task)
			elseif status == "dead" then
				Debugger:Log("warn", "FullTask:_processWaitingTasks", ("Task %s in WAITING state but coroutine is DEAD. Removing.")
					:format(_Task.id))
				table.insert(tasksToCleanup, id)
			end
		end
	end
	for _, id in ipairs(tasksToCleanup) do
		self.runningTasks[id] = nil
	end
	self.mutex:unlock()
	for _, _Task in ipairs(tasksToResume) do
		local success, result = coroutine.resume(_Task.coroutine)
		if not success then
			Debugger:Log("error", "FullTask:_processWaitingTasks", ("Coroutine for task %s errored during resume while WAITING: %s")
				:format(_Task.id, tostring(result)))
			self.mutex:lock()
			_Task:setState(TaskState.FAILED)
			self.runningTasks[_Task.id] = nil
			self:_queueEvent(self.signals.taskFailed, _Task, tostring(result))
			if #self._eventQueue > 0 then
				eventsToFire = self._eventQueue
				self._eventQueue = {}
			end
			self.mutex:unlock()
			if eventsToFire then
				for _, event in ipairs(eventsToFire) do
					pcall(event.Signal.Fire, event.Signal, unpack(event.Args))
				end
			end
		end
	end
end

function FullTask:_internalScheduleRecurring(_Task)
	if not _Task.parsedCron then
		Debugger:Log("warn","_scheduleRecurring",("Attempted to schedule recurring _Task without valid cron parser: %s")
			:format(_Task.id))
		return false
	end
	if _Task.recurringCount ~= nil and _Task.recurringCount < 1 then
		Debugger:Log("print", "_scheduleRecurring", ("Recurring task %s has completed its run count.")
			:format(_Task.id))
		return false
	end
	local nextRun = _Task.parsedCron:getNextRun(os.time())
	if nextRun then
		_Task.scheduledFor = nextRun
		_Task:setState(TaskState.WAITING)
		self.scheduledTasks[_Task.id] = _Task 
		if _Task.recurringCount then
			_Task.recurringCount = _Task.recurringCount - 1
		end
		return true 
	else
		Debugger:Log("warn","_scheduleRecurring",("Could not determine next run time for recurring _Task: %s. Discontinuing.")
			:format(_Task.id))
		self.metrics.tasksCancelled = self.metrics.tasksCancelled + 1 
		self:_queueEvent(self.signals.taskCancelled, _Task)
		return false
	end
end

function FullTask:_internalGetTask(id)
	local taskObj = self.tasks[id]
	return taskObj
end

function FullTask:GetTask(id)
	if self and self._destroyed then
		Debugger:Log("error", "GetTask", "Attempt to use a destroyed task instance.")
		return nil
	end
	self.mutex:lock()
	local success, result = pcall(function()
		return self:_internalGetTask(id)
	end)
	self.mutex:unlock()
	if not success then
		Debugger:Log("error", "GetTask", ("Internal failure: %s\n%s")
			:format(tostring(result), debug.traceback(nil, 2)))
	end
	return result
end

function FullTask:_internalGetTasks(status)
	local results = {}
	for taskId, taskObj in pairs(self.tasks) do
		if not status or taskObj.state == status then
			results[taskId] = taskObj 
		end
	end
	return results
end

function FullTask:GetTasks(status)
	if self and self._destroyed then
		Debugger:Log("error", "GetTasks", "Attempt to use a destroyed task instance.")
		return nil
	end

	self.mutex:lock()
	local success, result = pcall(function()
		return self:_internalGetTasks(status)
	end)
	self.mutex:unlock()
	if not success then
		Debugger:Log("error", "GetTasks", ("Internal failure: %s\n%s")
			:format(tostring(result), debug.traceback(nil, 2)))
	end
	return result
end

function FullTask:_internalSetPriority(id, newPriority)
	local taskObj = self.tasks[id]
	if not taskObj then
		return false, "Task not found."
	end
	if taskObj.state ~= "PENDING" and taskObj.state ~= "WAITING" then
		return false, "Cannot change priority for a task that is "..taskObj.state.."."
	end
	taskObj.priority = newPriority
	if taskObj._heapNode and self.priorityQueue then
		local newHeapKey = (Priority.CRITICAL - taskObj.priority) * 1e12 + (taskObj.submitTime)
		if self.priorityQueue.UpdateKey then
			local success, err = pcall(function()
				self.priorityQueue:UpdateKey(taskObj._heapNode, newHeapKey)
			end)
			if not success then error(err) end
		elseif self.priorityQueue.decreaseKey then
			local success, err = pcall(function()
				self.priorityQueue:decreaseKey(taskObj._heapNode, newHeapKey)
			end)
			if not success then error(err) end
		else
			pcall(function() self.priorityQueue:delete(taskObj._heapNode) end)
			taskObj._heapNode = self.priorityQueue:insert(newHeapKey, taskObj)
		end
	end
	return true
end

function FullTask:SetPriority(id, newPriority)
	if self and self._destroyed then
		Debugger:Log("error", "SetPriority", "Attempt to use a destroyed task instance.")
		return false, "Task manager destroyed."
	end
	self.mutex:lock()
	local pcall_results = { pcall(function()
		return self:_internalSetPriority(id, newPriority)
	end) }
	self.mutex:unlock()
	local success = pcall_results[1]
	if not success then
		local err = tostring(pcall_results[2])
		Debugger:Log("error", "SetPriority", ("Internal failure: %s\n%s")
			:format(err, debug.traceback(nil, 2)))
		return false, err
	end
	return table.unpack(pcall_results, 2, #pcall_results)
end

function FullTask:_internalAbortTask(id)
	local taskObj = self.tasks[id]
	if not taskObj then
		return false, "Task not found."
	end
	local currentState = taskObj.state
	if currentState == "COMPLETED" or currentState == "FAILED" or currentState == "CANCELLED" then
		return false, "Task is already finished."
	end
	taskObj.cancellationRequested = true
	if currentState == "PENDING" or currentState == "WAITING" then
		self.scheduledTasks[id] = nil
		if taskObj._heapNode and self.priorityQueue and self.priorityQueue.delete then
			pcall(function() self.priorityQueue:delete(taskObj._heapNode) end)
			taskObj._heapNode = nil
		end
	elseif currentState == "RUNNING" then
		self.runningTasks[id] = nil
		self.currentConcurrency = math.max(0, self.currentConcurrency - 1)
		if self.ttlService then
			pcall(function() self.ttlService:invalidate(id) end)
		end
	end
	taskObj.state = "CANCELLED"
	self.cancelledTasks[id] = taskObj
	self:_signalDependents(taskObj, "CANCELLED") 
	return true
end

function FullTask:AbortTask(id)
	if self and self._destroyed then
		Debugger:Log("error", "AbortTask", "Attempt to use a destroyed task instance.")
		return false, "Task manager destroyed."
	end
	self.mutex:lock()
	local eventsToFire
	local pcall_results = { pcall(function()
		return self:_internalAbortTask(id)
	end) }
	if #self._eventQueue > 0 then
		eventsToFire = self._eventQueue
		self._eventQueue = {}
	end
	self.mutex:unlock()
	if eventsToFire then
		for _, event in ipairs(eventsToFire) do
			pcall(event.Signal.Fire, event.Signal, unpack(event.Args))
		end
	end
	local success = pcall_results[1]
	if not success then
		local err = tostring(pcall_results[2])
		Debugger:Log("error", "AbortTask", ("Internal failure: %s\n%s")
			:format(err, debug.traceback(nil, 2)))
		return false, err
	end
	return table.unpack(pcall_results, 2, #pcall_results)
end

local function buildDependencyGraph(self)
	local graph = {}
	for id, taskObj in pairs(self.tasks) do
		if not graph[id] then
			graph[id] = {}
		end
		for _, depId in ipairs(taskObj.dependencies or {}) do
			if self.tasks[depId] then
				if not graph[depId] then
					graph[depId] = {}
				end
				table.insert(graph[depId], id)
			end
		end
	end
	return graph
end

function FullTask:_internalAddDependency(taskId, prerequisiteTaskId)
	local taskObj = self.tasks[taskId]
	local prereqObj = self.tasks[prerequisiteTaskId]
	if not taskObj or not prereqObj then
		return false, "One or both tasks not found."
	end
	if taskObj.state ~= "PENDING" and taskObj.state ~= "WAITING" then
		return false, "Cannot add dependency to a task that is not PENDING or WAITING."
	end
	if prereqObj.state == "CANCELLED" or prereqObj.state == "FAILED" then
		return false, "Cannot add dependency on a task that is CANCELLED or FAILED."
	end
	if taskId == prerequisiteTaskId then
		return false, "Task cannot depend on itself."
	end
	local isNew = true
	for _, depId in ipairs(taskObj.dependencies) do
		if depId == prerequisiteTaskId then
			isNew = false
			break
		end
	end
	if isNew then
		table.insert(taskObj.dependencies, prerequisiteTaskId)
		table.insert(prereqObj.dependents, taskId)
		local currentGraph = buildDependencyGraph(self)
		local hasCycle, cycleError = TopologicalSort.hasCycle(currentGraph)
		if hasCycle then
			for i = #taskObj.dependencies, 1, -1 do
				if taskObj.dependencies[i] == prerequisiteTaskId then
					table.remove(taskObj.dependencies, i)
					break
				end
			end
			for i = #prereqObj.dependents, 1, -1 do
				if prereqObj.dependents[i] == taskId then
					table.remove(prereqObj.dependents, i)
					break
				end
			end
			return false, "Cyclic dependency detected."
		else
			if self._reconcileTaskState then
				self:_reconcileTaskState(taskObj)
			end
		end
	end
	return true
end

function FullTask:AddDependency(taskId, prerequisiteTaskId)
	if self and self._destroyed then
		Debugger:Log("error", "AddDependency", "Attempt to use a destroyed task instance.")
		return false, "Task manager destroyed."
	end
	self.mutex:lock()
	local pcall_results = { pcall(function()
		return self:_internalAddDependency(taskId, prerequisiteTaskId)
	end) }
	self.mutex:unlock()
	local success = pcall_results[1]
	if not success then
		local err = tostring(pcall_results[2])
		Debugger:Log("error", "AddDependency", ("Internal failure: %s\n%s")
			:format(err, debug.traceback(nil, 2)))
		return false, err
	end
	return table.unpack(pcall_results, 2, #pcall_results)
end

function FullTask:_internalPause()
	if self._isPaused == true then
		return false, "Scheduler is already paused."
	end
	self._isPaused = true
	if self._mainLoopConnection then
		self._mainLoopConnection:Disconnect()
		self._mainLoopConnection = nil
	end
	return true
end

function FullTask:Pause()
	if self and self._destroyed then
		Debugger:Log("error", "Pause", "Attempt to use a destroyed task instance.")
		return false, "Task manager destroyed."
	end
	self.mutex:lock()
	local pcall_results = { pcall(function()
		return self:_internalPause()
	end) }

	self.mutex:unlock()
	local success = pcall_results[1]
	if not success then
		local err = tostring(pcall_results[2])
		Debugger:Log("error", "Pause", ("Internal failure: %s\n%s")
			:format(err, debug.traceback(nil, 2)))
		return false, err
	end
	return table.unpack(pcall_results, 2, #pcall_results)
end

function FullTask:_internalResume()
	if self._isPaused == false then
		return false, "Scheduler is already running."
	end
	self._isPaused = false
	if not self._mainLoopConnection then
		local Heartbeat = game:GetService("RunService").Heartbeat
		local heartbeatCounter = 0
		self._mainLoopConnection = Heartbeat:Connect(function(dt)
			self._currentFrameLoad = 0
			heartbeatCounter = heartbeatCounter + 1
			self:_processScheduledTasks()
			self:_processWaitingTasks()
			self:_processQueue()
			if heartbeatCounter >= 20 then
				heartbeatCounter = 0
				pcall(function() self:_reconcileConcurrencyMetrics() end)
			end
		end)
	end
	return true
end

function FullTask:Resume()
	if self and self._destroyed then
		Debugger:Log("error", "Resume", "Attempt to use a destroyed task instance.")
		return false, "Task manager destroyed."
	end
	self.mutex:lock()
	local pcall_results = { pcall(function()
		return self:_internalResume()
	end) }
	self.mutex:unlock()
	local success = pcall_results[1]
	if not success then
		local err = tostring(pcall_results[2])
		Debugger:Log("error", "Resume", ("Internal failure: %s\n%s")
			:format(err, debug.traceback(nil, 2)))
		return false, err
	end
	local internal_success = pcall_results[2]
	return table.unpack(pcall_results, 2, #pcall_results)
end

function FullTask:_internalGetTaskDependencies(id)
	local taskObj = self.tasks[id]
	local dependencies = {}
	if taskObj and taskObj.dependencies then
		for _, depId in ipairs(taskObj.dependencies) do
			table.insert(dependencies, depId)
		end
	end
	return dependencies
end

function FullTask:GetTaskDependencies(id)
	if self and self._destroyed then
		Debugger:Log("error", "GetTaskDependencies", "Attempt to use a destroyed task instance.")
		return nil
	end
	self.mutex:lock()
	local success, result = pcall(function()
		return self:_internalGetTaskDependencies(id)
	end)
	self.mutex:unlock()
	if not success then
		Debugger:Log("error", "GetTaskDependencies", ("Internal failure: %s\n%s")
			:format(tostring(result), debug.traceback(nil, 2)))
		return nil
	end
	return result
end

function FullTask:_internalDestroy()
	self._isDestroying = true
	if self._reconciler then
		self._reconciler = nil
	end
	self._shouldRunLoop = false
	if self and self._mainLoopConnection then
		self._mainLoopConnection:Disconnect()
		self._mainLoopConnection = nil
	end
	if self and self.runningTasks then
		for taskId, taskObj in pairs(self.runningTasks) do
			taskObj.cancellationRequested = true
			if taskObj.thread and coroutine.status(taskObj.thread) ~= "dead" then
				pcall(function() coroutine.close(taskObj.thread) end)
			end
			if self.ttlService then
				pcall(function() self.ttlService:invalidate(taskId) end)
			end
		end
		self.runningTasks = {}
		self.currentConcurrency = 0
		if self.metrics then
			self.metrics.currentConcurrency = 0
		end
	end
	if self and self.signals then
		for _, sig in pairs(self.signals) do
			pcall(function() sig:DisconnectAll() end)
		end
		self.signals = nil
	end
	self.scheduledTasks = {}
	self.priorityQueue = nil
	self.tasks = nil
	self.completedTasks = nil
	self.failedTasks = nil
	self.cancelledTasks = nil
	self.ttlService = nil
	if self and self._resourceSemaphores then
		for _, sem in pairs(self._resourceSemaphores) do
			pcall(function() sem:destroy() end)
		end
		self._resourceSemaphores = nil
	end
end

function FullTask:Destroy()
	if self and self._destroyed then
		Debugger:Log("error", "Destroy", "Attempt to use a destroyed task instance.")
		return
	end
	self._destroyed = true
	_globalMutex:lock()
	if _taskManagers[self.name] == self then
		_taskManagers[self.name] = nil
	end
	_globalMutex:unlock()
	self.mutex:lock()
	local eventsToFire
	local success, result = pcall(function()
		return self:_internalDestroy()
	end)
	if #self._eventQueue > 0 then
		eventsToFire = self._eventQueue
		self._eventQueue = {}
	end
	self.mutex:unlock()
	if eventsToFire then
		for _, event in ipairs(eventsToFire) do
			pcall(event.Signal.Fire, event.Signal, unpack(event.Args))
		end
	end
	if not success then
		Debugger:Log("error", "Destroy", ("Internal failure: %s\n%s")
			:format(tostring(result), debug.traceback(nil, 2)))
	end
end

function FullTask:Snapshot(): TypeDef.FullTaskSnapshot?
	if self and self._destroyed then
		Debugger:Log("error", "Snapshot", "Attempt to use a destroyed task instance.")
		return nil
	end
	self.mutex:lock()
	local success, result = pcall(function()
		return self:_internalSnapshot()
	end)
	self.mutex:unlock()
	if not success then
		Debugger:Log("error", "Snapshot", ("Internal failure: %s\n%s")
			:format(tostring(result), debug.traceback(nil, 2)))
		return nil
	end
	return result
end

function FullTask:_internalSnapshot(): TypeDef.FullTaskSnapshot
	local snapshot = {
		version = VERSION,
		name = self.name,
		timestamp = os.time(),
		config = {
			maxConcurrency = self.maxConcurrency,
			resourceLimits = deepCopy(self._resourceLimits) or {},
		},
		tasks = {}
	}
	for id, _Task in pairs(self.tasks) do
		local state = _Task.state
		if state == TaskState.COMPLETED or state == TaskState.FAILED
			or state == TaskState.CANCELLED then
			continue
		end
		local savedState = (state == TaskState.RUNNING) and TaskState.PENDING or state
		local taskData = {
			id = _Task.id,
			name = _Task.name,
			state = savedState,
			priority = _Task.priority,
			retries = _Task.retries,
			maxRetries = _Task.maxRetries,
			timeout = _Task.timeout,
			resources = deepCopy(_Task.resources),
			dependencies = deepCopy(_Task.dependencies),
			scheduledFor = _Task.scheduledFor,
			cronExpression = _Task.cronExpression,
			recurringCount = _Task.recurringCount,
			data = deepCopy(_Task.data),
			submitTime = _Task.submitTime,
			contentHash = _Task.contentHash,
			isRecurring = _Task.isRecurring,
		}
		snapshot.tasks[id] = taskData
	end
	return snapshot
end

function FullTask:_internalClear()
	self._isPaused = true
	if self._mainLoopConnection then
		self._mainLoopConnection:Disconnect()
		self._mainLoopConnection = nil
	end
	if self._reconciler then
		pcall(function() coroutine.close(self._reconciler) end)
		self._reconciler = nil
	end
	for id, taskObj in pairs(self.runningTasks) do
		if taskObj.thread and coroutine.status(taskObj.thread) ~= "dead" then
			pcall(function() coroutine.close(taskObj.thread) end)
		end
	end
	self.tasks = {}
	self.runningTasks = {}
	self.completedTasks = {}
	self.failedTasks = {}
	self.cancelledTasks = {}
	self.scheduledTasks = {}
	self.tasksByContentHash = {}
	self.currentConcurrency = 0
	local heapType = (self.priorityQueue and self.priorityQueue.updateKey)
		and "fibonacciheap" or "pairingheap"
	if heapType == "fibonacciheap" then
		self.priorityQueue = FibonacciHeap.new()
	else
		self.priorityQueue = PairingHeap.new()
	end
	for _, sem in pairs(self._resourceSemaphores) do
		pcall(function() sem:destroy() end)
	end
	self._resourceSemaphores = {}
	if self.ttlService then
		self.ttlService:stop()
		self.ttlService = TTLService.new(self)
	end
	self.metrics = {
		totalTasksSubmitted = 0,
		tasksCompleted = 0,
		tasksFailed = 0,
		tasksCancelled = 0,
		tasksRetried = 0,
		tasksInQueue = 0,
		currentConcurrency = 0,
		totalExecutionTime = 0,
		averageExecutionTime = 0,
		uptime = os.time()
	}
end

function FullTask:_internalRestore(snapshotData: TypeDef.FullTaskSnapshot, functionMap: {[string]: () -> ...any})
	self:_internalPause()
	self:_internalClear()
	self.maxConcurrency = snapshotData.config.maxConcurrency or self.maxConcurrency
	self._resourceLimits = deepCopy(snapshotData.config.resourceLimits) or {}
	local tasksToRebuildDependents = {}
	for id, taskData in pairs(snapshotData.tasks) do
		local fn = functionMap[taskData.id] or functionMap[taskData.name]
		if not fn then
			Debugger:Log("warn", "_internalRestore", ("No function found in map for task ID %s (name: %s). Skipping.")
				:format(id, taskData.name or "nil"))
			continue
		end
		local _Task = Task.new(fn, taskData)
		_Task.id = taskData.id
		_Task.state = taskData.state
		_Task.retries = taskData.retries
		_Task.submitTime = taskData.submitTime
		_Task.recurringCount = taskData.recurringCount
		_Task.contentHash = taskData.contentHash
		self.tasks[_Task.id] = _Task
		if _Task.contentHash then
			self.tasksByContentHash[_Task.contentHash] = _Task.id
		end
		self.metrics.totalTasksSubmitted = self.metrics.totalTasksSubmitted + 1
		table.insert(tasksToRebuildDependents, _Task)
		if _Task.state == TaskState.WAITING then
			self.scheduledTasks[_Task.id] = _Task
		elseif _Task.state == TaskState.PENDING then
			local heapKey = (Priority.CRITICAL - _Task.priority) * 1e12 + (_Task.submitTime)
			_Task._heapNode = self.priorityQueue:insert(heapKey, _Task)
			self.metrics.tasksInQueue = self.metrics.tasksInQueue + 1
		end
	end
	for _, taskObj in ipairs(tasksToRebuildDependents) do
		for _, depId in ipairs(taskObj.dependencies) do
			local depTask = self.tasks[depId]
			if depTask then
				table.insert(depTask.dependents, taskObj.id)
			else
				Debugger:Log("warn", "_internalRestore", ("Restored task %s has a dependency (%s) that was not found in the snapshot.")
					:format(taskObj.id, depId))
			end
		end
	end
	return true
end

function FullTask:Restore(snapshotData: TypeDef.FullTaskSnapshot, functionMap: {[string]: () -> ...any})
	if self and self._destroyed then
		Debugger:Log("error", "Restore", "Attempt to use a destroyed task instance.")
		return false, "Task manager destroyed."
	end
	if not snapshotData or not functionMap or next(functionMap) == nil then
		Debugger:Log("error", "Restore", "Snapshot data and a non-empty functionMap are required.")
		return false, "Snapshot data and functionMap are required."
	end
	self.mutex:lock()
	local pcall_results = { pcall(function()
		return self:_internalRestore(snapshotData, functionMap)
	end) }
	self.mutex:unlock()
	local success = pcall_results[1]
	if not success then
		local err = tostring(pcall_results[2])
		Debugger:Log("error", "Restore", ("Internal failure: %s\n%s")
			:format(err, debug.traceback(nil, 2)))
		return false, err
	end
	if pcall_results[2] == true then
		self:Resume()
	end
	return table.unpack(pcall_results, 2, #pcall_results)
end

function FullTask:ToJSON(): string?
	if self and self._destroyed then
		Debugger:Log("error", "ToJSON", "Attempt to use a destroyed task instance.")
		return nil
	end
	local snapshot = self:Snapshot()
	if not snapshot then
		return nil
	end
	local success, jsonString = pcall(HttpService.JSONEncode, HttpService, snapshot)
	if not success then
		Debugger:Log("error", "ToJSON", ("Failed to encode snapshot to JSON: %s")
			:format(jsonString))
		return nil
	end
	return jsonString
end

function FullTask:FromJSON(jsonString: string, functionMap: {[string]: () -> ...any})
	if self and self._destroyed then
		Debugger:Log("error", "FromJSON", "Attempt to use a destroyed task instance.")
		return false, "Task manager destroyed."
	end
	local success, snapshotData = pcall(HttpService.JSONDecode, HttpService, jsonString)
	if not success then
		Debugger:Log("error", "FromJSON", ("Failed to decode JSON string: %s")
			:format(snapshotData))
		return false, "JSON decoding failed."
	end
	return self:Restore(snapshotData, functionMap)
end

function FullTask:Transaction(transactionFn: (tx: TypeDef.FullTask) -> ...any)
	if self and self._destroyed then
		Debugger:Log("error", "Transaction", "Attempt to use a destroyed task instance.")
		return
	end
	self.mutex:lock()
	local eventsToFire
	local tx_pcall_results = { pcall(function()
		local journal = { actions = {} }
		local tx = {}
		function tx:Submit(taskFn, options)
			table.insert(journal.actions, {
				type = "SUBMIT",
				args = {taskFn, options}
			})
			return true
		end
		function tx:CancelTask(taskId, force)
			table.insert(journal.actions, {
				type = "CANCEL",
				args = {taskId, force}
			})
			return true
		end
		function tx:SetPriority(id, newPriority)
			table.insert(journal.actions, {
				type = "SETPRIORITY",
				args = {id, newPriority}
			})
			return true
		end
		function tx:AddDependency(taskId, prerequisiteTaskId)
			table.insert(journal.actions, {
				type = "ADD_DEPENDENCY",
				args = {taskId, prerequisiteTaskId}
			})
			return true
		end
		setmetatable(tx, { __index = self })
		local tx_fn_pcall_results = { pcall(transactionFn, tx) }
		local tx_fn_success = tx_fn_pcall_results[1]
		if not tx_fn_success then
			local err_msg = tostring(tx_fn_pcall_results[2])
			error("Transaction failed: "..err_msg)
		end
		for _, action in ipairs(journal.actions) do
			local success, result
			if action.type == "SUBMIT" then
				result = self:_internalSubmit(unpack(action.args))
				success = (result ~= nil)
			elseif action.type == "CANCEL" then
				result = self:_internalCancelTask(unpack(action.args))
				success = (result == true)
			elseif action.type == "SETPRIORITY" then
				success, result = self:_internalSetPriority(unpack(action.args))
			elseif action.type == "ADD_DEPENDENCY" then
				success, result = self:_internalAddDependency(unpack(action.args))
			end
			if not success then
				error(string.format("Transaction commit failed on action %s: %s",
					action.type, tostring(result or "internal error")))
			end
		end
		return table.unpack(tx_fn_pcall_results, 2, #tx_fn_pcall_results)
	end) }
	local tx_success = tx_pcall_results[1]
	if #self._eventQueue > 0 then
		eventsToFire = self._eventQueue
		self._eventQueue = {}
	end
	self.mutex:unlock()
	if eventsToFire then
		for _, event in ipairs(eventsToFire) do
			pcall(event.Signal.Fire, event.Signal, unpack(event.Args))
		end
	end
	if not tx_success then
		local err = tostring(tx_pcall_results[2])
		Debugger:Log("error", "Transaction", ("Internal failure: %s\n%s")
			:format(err, debug.traceback(nil, 2)))
		error(err)
	end
	local final_result = table.unpack(tx_pcall_results, 2, #tx_pcall_results)
	return final_result
end

function FullTask:_internalBulkCancel(taskIds: {string}, force: boolean?)
	local cancelledCount = 0
	for _, taskId in ipairs(taskIds) do
		local success = self:_internalCancelTask(taskId, force)
		if success == true then
			cancelledCount = cancelledCount + 1
		end
	end
	return cancelledCount
end

function FullTask:BulkCancel(taskIds: {string}, force: boolean?)
	if self and self._destroyed then
		Debugger:Log("error", "BulkCancel", "Attempt to use a destroyed task instance.")
		return 0
	end
	if not taskIds then
		return 0
	end
	self.mutex:lock()
	local eventsToFire
	local pcall_results = { pcall(function()
		return self:_internalBulkCancel(taskIds, force)
	end) }
	if #self._eventQueue > 0 then
		eventsToFire = self._eventQueue
		self._eventQueue = {}
	end
	self.mutex:unlock()
	if eventsToFire then
		for _, event in ipairs(eventsToFire) do
			pcall(event.Signal.Fire, event.Signal, unpack(event.Args))
		end
	end
	local success = pcall_results[1]
	if not success then
		local err = tostring(pcall_results[2])
		Debugger:Log("error", "BulkCancel", ("Internal failure: %s\n%s")
			:format(err, debug.traceback(nil, 2)))
		return 0
	end
	return table.unpack(pcall_results, 2, #pcall_results)
end

function FullTask:_internalCancelByPattern(patOrFn: string | ((task: Task) -> boolean), force: boolean?)
	local tasksToCancel = {}
	local patType = type(patOrFn)
	if patType == "function" then
		for id, taskObj in pairs(self.tasks) do
			local success, result = pcall(patOrFn, taskObj)
			if success and result == true then
				table.insert(tasksToCancel, id)
			end
		end
	elseif patType == "string" then
		if string.sub(patOrFn, -1) == "*" and not string.find(patOrFn, "[?]", 1, true) then
			local prefix = string.sub(patOrFn, 1, -2)
			local success, seq = pcall(_stringToSequence, prefix)
			if success and seq and #seq > 0 then
				local startNode = self.nameTrie:search(seq)
				if startNode then
					tasksToCancel = self:_getAllIdsFromNode(startNode)
				end
			elseif success and #seq == 0 then
				tasksToCancel = self:_getAllIdsFromNode(self.nameTrie.root)
			end
		else
			local luaPattern = _globToLuaPattern(patOrFn)
			for id, taskObj in pairs(self.tasks) do
				if string.match(taskObj.name or "", luaPattern) then
					table.insert(tasksToCancel, id)
				end
			end
		end
	else
		error("Invalid patOrFn type. Expected string or function, got "..patType)
	end
	if #tasksToCancel == 0 then
		return 0
	end
	return self:_internalBulkCancel(tasksToCancel, force)
end

function FullTask:CancelByPattern(patOrFn: string | ((task: Task) -> boolean), force: boolean?)
	if self and self._destroyed then
		Debugger:Log("error", "CancelByPattern", "Attempt to use a destroyed task instance.")
		return 0
	end
	if not patOrFn then
		return 0
	end
	self.mutex:lock()
	local eventsToFire
	local pcall_results = { pcall(function()
		return self:_internalCancelByPattern(patOrFn, force)
	end) }
	if #self._eventQueue > 0 then
		eventsToFire = self._eventQueue
		self._eventQueue = {}
	end
	self.mutex:unlock()
	if eventsToFire then
		for _, event in ipairs(eventsToFire) do
			pcall(event.Signal.Fire, event.Signal, unpack(event.Args))
		end
	end
	local success = pcall_results[1]
	if not success then
		local err = tostring(pcall_results[2])
		Debugger:Log("error", "CancelByPattern", ("Internal failure: %s\n%s")
			:format(err, debug.traceback(nil, 2)))
		return 0
	end
	return table.unpack(pcall_results, 2, #pcall_results)
end

FullTask.TaskState = TaskState; FullTask.Priority = Priority
FullTask.Version = VERSION; FullTask.Registry = _taskManagers
return Debugger:Profile(FullTask, "Create", script) :: TypeDef.Static
