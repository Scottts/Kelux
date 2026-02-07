--!strict
--!optimize 2
--[[
	AUTHOR: Kel (@GudEveningBois)
	
	Created:
		12/6/2025
		12:48 AM UTC+9
		
	The lite version of FullState.
	Documentation not available yet
]]
local VERSION = "0.1.0 (ALPHA)"

-- Dependencies
local TypeDef = require(script.TypeDef)
local Signal = require(script.Parent.Parent.Components.KelSignal)
local Debugger = require(script.Parent.Parent.Components.Debugger)

local LiteState = {}
LiteState.__index = LiteState

function LiteState.new<T>(initialState: T)
	local self = setmetatable({
		_state = initialState,
		_changed = Signal.new(),
		_batchDepth = 0,
		_batchChanged = false,
		_destroyed = false,
	}, LiteState)
	return self
end

function LiteState:Get()
	return self._state
end

function LiteState:Set(newValue)
	if self._destroyed then return end
	local oldValue = self._state
	if newValue == oldValue and type(newValue) ~= "table" and type(newValue) ~= "userdata" then
		return
	end
	self._state = newValue
	if self._batchDepth > 0 then
		self._batchChanged = true
	else
		self._changed:Fire(newValue, oldValue)
	end
end

function LiteState:Update(callback)
	if self._destroyed then return end
	local newValue = callback(self._state)
	self:Set(newValue)
end

function LiteState:Subscribe(listener)
	if self._destroyed then 
		error("Attempt to subscribe to destroyed LiteState")
	end
	return self._changed:Connect(listener)
end

function LiteState:Batch(callback)
	if self._destroyed then return end
	self._batchDepth += 1
	local success, err = pcall(callback)
	self._batchDepth -= 1
	if not success then
		Debugger:Log("error", "Batch", "Error during batch update: "..tostring(err))
	end
	if self._batchDepth == 0 and self._batchChanged then
		self._batchChanged = false
		self._changed:Fire(self._state, nil)
	end
end

function LiteState:Destroy()
	if self._destroyed then return end
	self._destroyed = true
	self._changed:DisconnectAll()
	self._state = nil
	setmetatable(self, nil)
end

LiteState.Version = VERSION
return LiteState :: TypeDef.Static