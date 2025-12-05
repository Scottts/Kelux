--!strict
--!optimize 2
--[[
	AUTHOR: Kel (@GudEveningBois)
	
	Created:
		12/6/2025
		12:37 AM UTC+9
		
	The lite version of FullTask.
	Documentation not available yet
]]
local VERSION = "0.1.0 (ALPHA)"
local TypeDef = require(script.TypeDef)

local LiteTask = {}
LiteTask.__index = LiteTask

local _registry: { [any]: thread | number } = {}

function LiteTask.Delay(seconds: number, callback: () -> ()): TypeDef.CleanupToken
	local active = true
	local thread = task.delay(seconds, function()
		if active then
			callback()
		end
	end)
	return {
		Cancel = function()
			active = false
			if thread then task.cancel(thread) end
		end
	}
end

function LiteTask.Debounce(key: any, seconds: number, callback: (...any) -> (), ...: any)
	local existing = _registry[key]
	if existing and typeof(existing) == "thread" then
		task.cancel(existing)
	end
	local args = {...}
	_registry[key] = task.delay(seconds, function()
		_registry[key] = nil
		callback(table.unpack(args))
	end)
end

function LiteTask.Throttle(key: any, seconds: number, callback: (...any) -> (), ...: any)
	local now = os.clock()
	local lastCall = _registry[key]
	if type(lastCall) == "number" then
		if (now - lastCall) < seconds then
			return
		end
	end
	_registry[key] = now
	task.delay(seconds, function()
		if _registry[key] == now then
			_registry[key] = nil
		end
	end)
	callback(...)
end

function LiteTask.Cancel(key: any)
	local existing = _registry[key]
	if existing and typeof(existing) == "thread" then
		task.cancel(existing)
		_registry[key] = nil
	end
end

function LiteTask.Cleanup()
	for key, entry in pairs(_registry) do
		if typeof(entry) == "thread" then
			task.cancel(entry)
		end
	end
	table.clear(_registry)
end

LiteTask.Version = VERSION
return LiteTask :: TypeDef.Master