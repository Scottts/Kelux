-- Edsger Dijkstra
-- DO NOT EDIT IF YOU DON'T KNOW WHAT YOU'RE DOING
local Signal = require(script.Parent.Parent.KelSignal)
local Mutex = require(script.Parent.Parent.Mutex)
local RunService = game:GetService("RunService")

local Semaphore = {}
Semaphore.__index = Semaphore

function Semaphore.new(capacity)
	assert(type(capacity) == "number" and capacity > 0, "Capacity must be a positive number")
	local self = setmetatable({}, Semaphore)
	self._capacity = capacity
	self._available = capacity
	self._waitQueue = {}
	self._isDestroyed = false
	self._mutex = Mutex.new()
	self._stats = {
		totalAcquires = 0,
		totalReleases = 0,
		currentWaiting = 0,
		maxWaiting = 0,
		averageWaitTime = 0,
	}
	self._resourceAcquired = Signal.new()
	self._resourceReleased = Signal.new()
	self._destroyed = Signal.new()
	return self
end

function Semaphore:acquire(amount, timeout)
	amount = amount or 1
	timeout = timeout or math.huge
	assert(type(amount) == "number" and amount > 0, "Amount must be a positive number")
	assert(type(timeout) == "number" and timeout > 0, "Timeout must be a positive number")
	assert(not self._isDestroyed, "Semaphore has been destroyed")
	self._mutex:lock()
	if self._available >= amount then
		self._available = self._available - amount
		self._stats.totalAcquires = self._stats.totalAcquires + 1
		self._resourceAcquired:Fire(amount)
		self._mutex:unlock()
		return true
	end
	local waitStart = tick()
	local waitSignal = Signal.new()
	local waitData = {amount = amount, signal = waitSignal}
	table.insert(self._waitQueue, waitData)
	self._stats.currentWaiting = self._stats.currentWaiting + 1
	self._stats.maxWaiting = math.max(self._stats.maxWaiting, self._stats.currentWaiting)
	self._mutex:unlock()
	local success = waitSignal:Wait(timeout)
	if not success then
		self._mutex:lock()
		self:_removeFromQueue(waitData)
		self._mutex:unlock()
	end
	return success
end

function Semaphore:_processWaitQueue()
	local i = 1
	while i <= #self._waitQueue do
		local waitData = self._waitQueue[i]
		if self._available >= waitData.amount then
			self._available = self._available - waitData.amount
			self._stats.totalAcquires = self._stats.totalAcquires + 1
			table.remove(self._waitQueue, i)
			self._stats.currentWaiting = math.max(0, self._stats.currentWaiting - 1)
			self._resourceAcquired:Fire(waitData.amount)
			waitData.signal:Fire(true)
		else
			i = i + 1
		end
	end
end

function Semaphore:_removeFromQueue(waitData)
	for i, item in ipairs(self._waitQueue) do
		if item == waitData then
			table.remove(self._waitQueue, i)
			self._stats.currentWaiting = math.max(0, self._stats.currentWaiting - 1)
			break
		end
	end
end

function Semaphore:release(amount)
	amount = amount or 1
	assert(type(amount) == "number" and amount > 0, "Amount must be a positive number")
	assert(not self._isDestroyed, "Semaphore has been destroyed")
	self._mutex:lock()
	self._available = self._available + amount
	self._stats.totalReleases = self._stats.totalReleases + 1
	self._resourceReleased:Fire(amount)
	self:_processWaitQueue()
	self._mutex:unlock()
end

function Semaphore:getAvailable()
	return self._available
end

function Semaphore:getCapacity()
	return self._capacity
end

function Semaphore:getWaitingCount()
	return #self._waitQueue
end

function Semaphore:getStats()
	local stats = {}
	for k, v in pairs(self._stats) do
		stats[k] = v
	end
	stats.currentWaiting = #self._waitQueue
	stats.utilizationRate = (self._capacity - self._available) / self._capacity
	return stats
end

function Semaphore:reset()
	assert(not self._isDestroyed, "Semaphore has been destroyed")
	self._available = self._capacity
	for _, waitData in ipairs(self._waitQueue) do
		if waitData.promise then
			waitData.promise:_complete(false)
		end
	end
	self._waitQueue = {}
	self._stats.currentWaiting = 0
end

function Semaphore:destroy()
	if self._isDestroyed then return end
	self._isDestroyed = true
	for _, waitData in ipairs(self._waitQueue) do
		if waitData.promise then
			waitData.promise:_complete(false)
		end
	end
	self._resourceAcquired:Destroy()
	self._resourceReleased:Destroy()
	self._destroyed:Fire()
	self._destroyed:Destroy()
end

function Semaphore:onResourceAcquired(callback)
	return self._resourceAcquired.Event:Connect(callback)
end

function Semaphore:onResourceReleased(callback)
	return self._resourceReleased.Event:Connect(callback)
end

function Semaphore:onDestroyed(callback)
	return self._destroyed.Event:Connect(callback)
end

Semaphore.Mutex = Mutex
return Semaphore
