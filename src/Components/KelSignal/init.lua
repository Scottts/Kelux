--!strict
--!optimize 2
--[[
	Author: Kel (@GudEveningBois)
	[6/15/25 10:40 PM UTC+9]
	
	About:
		A fork of stravant's FastSignal, but with aggressive optimizations.
	Benchmark:
		._____________________________________________________________________________________
		|
		| Library        | Operation      | Avg Time (ms) | Median (ms) | Min (ms) | Max (ms) |
		| -------------- | -------------- | ------------- | ----------- | -------- | -------- |
		|   KelSignal    |  Connect()     |   1.65290     | 1.56550     | 1.46620  | 5.84610  |
		|                |  Fire()        |   0.30763     | 0.29865     | 0.28360  | 0.57320  |
		|                |  Disconnect()  |   0.04712     | 0.04405     | 0.03890  | 0.11710  |
		|
		| FastSignal   |  Connect()     |   3.97193     | 3.83900     | 2.95230  | 7.43620  |
		|                |  Fire()        |	  1.10438     | 1.05075     | 0.63950  | 2.80460  |
		|                |  Disconnect()  |   0.02575     | 0.02400     | 0.02120  | 0.05610  |
		^‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾
	All metrics measured in Roblox on a warmed VM over 100 iterations with 10,000 listeners
	Designed for systems where connection and firing throughput dominate usage patterns
	(Disconnect is slower but negligible)
]]
local TypeDef = require(script.TypeDef)

local table_clear = table.clear
local coroutine_running = coroutine.running
local coroutine_yield = coroutine.yield
local coroutine_resume = coroutine.resume
local task_defer = task.defer
local task_spawn = task.spawn

local Signal = {}
Signal.__index = Signal

function Signal.new(): TypeDef.Signal
	return setmetatable({
		_handlers = {}, 
		_ids = {},
		_lookup = {}, 
		_nextId = 0,
		_firing = false,
		_deferredDisconnects = {},
		_disconnectAllDeferred = false,
	}, Signal) :: any
end

function Signal:Connect(handler: TypeDef.Handler): number
	local id:number = self._nextId
	self._nextId = id+1
	local index = #self._handlers+1
	self._handlers[index] = handler
	self._ids[index] = id
	self._lookup[id] = index
	return id
end

function Signal:Once(handler: TypeDef.Handler): number
	local connectionId
	connectionId = self:Connect(function(...)
		self:Disconnect(connectionId)
		handler(...)
	end)
	return connectionId
end

function Signal:Disconnect(id: number)
	if not self._lookup[id] then return end

	if self._firing then
		self._deferredDisconnects[id] = true
	else
		self:_disconnectNow(id)
	end
end

function Signal:_disconnectNow(id: number)
	local index_to_remove = self._lookup[id]
	if not index_to_remove then return end
	local handlers = self._handlers
	local ids = self._ids
	local last_index = #handlers
	if index_to_remove ~= last_index then
		local id_of_last = ids[last_index]
		handlers[index_to_remove] = handlers[last_index]
		ids[index_to_remove] = id_of_last
		self._lookup[id_of_last] = index_to_remove
	end

	handlers[last_index] = nil
	ids[last_index] = nil
	self._lookup[id] = nil
end

function Signal:DisconnectAll()
	if self._firing then
		self._disconnectAllDeferred = true
	else
		table_clear(self._handlers)
		table_clear(self._ids)
		table_clear(self._lookup)
		table_clear(self._deferredDisconnects)
	end
end

function Signal:Wait(): ...any
	local waitingCoroutine = coroutine_running()
	local args
	self:Once(function(...)
		args = {...}
		task_defer(function()
			coroutine_resume(waitingCoroutine)
		end)
	end)
	if not args then
		coroutine_yield()
	end
	return unpack(args)
end

function Signal:Fire(...: any)
	self._firing = true
	local handlers = self._handlers
	for i = 1, #handlers do
		handlers[i](...)
	end
	self._firing = false
	if self._disconnectAllDeferred then
		self._disconnectAllDeferred = false
		self:DisconnectAll()
		return
	end
	local deferred = self._deferredDisconnects
	for id, _ in pairs(deferred) do
		self:_disconnectNow(id)
	end
	table_clear(deferred)
end

return Signal :: TypeDef.Static
