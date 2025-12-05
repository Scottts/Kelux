local Signal = require(script.Parent.KelSignal)

local Mutex = {}
Mutex.__index = Mutex

function Mutex.new()
	local self = setmetatable({
		_isLocked = false,
		_lockOwner = nil,
		_lockCount = 0,
		_lockQueue = {}
	}, Mutex)
	return self
end

function Mutex:lock()
	local threadId = coroutine.running()
	if self._isLocked and self._lockOwner ~= threadId then
		local waiterSignal = Signal.new()
		table.insert(self._lockQueue, waiterSignal)
		waiterSignal:Wait()
	end
	self._isLocked = true
	self._lockOwner = threadId
	self._lockCount = self._lockCount + 1
	return true
end

function Mutex:unlock()
	local threadId = coroutine.running()
	if not self._isLocked or self._lockOwner ~= threadId then
		error("Attempt to unlock a mutex not owned by current thread or not locked", 2)
	end
	self._lockCount = self._lockCount - 1
	if self._lockCount == 0 then
		self._isLocked = false
		self._lockOwner = nil
		if #self._lockQueue > 0 then
			local waiterSignal = table.remove(self._lockQueue, 1)
			waiterSignal:Fire()
		end
	end
	return true
end

return Mutex
