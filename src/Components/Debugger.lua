local module = {}
module.__index = module

function module.From(Title)
	local self = setmetatable({}, module)
	self.Title = Title
	return self
end

-- General
function module:Log(Type:string, method:string, msg:string, level:number)
	local Title = self.Title or script.Parent.Name
	local Type = string.lower(Type)
	if Type == "error" then
		error(("%s.%s: %s")
			:format(Title, method, msg), level or 2)
	elseif Type == "warn" then
		warn(("%s.%s: %s")
			:format(Title, method, msg))
	elseif Type == "info" or Type == "print" then
		print(("%s.%s: %s") 
			:format(Title, method, msg))
	else -- Fallback
		warn(("Unknown error! Type: %s | Method: %s | Msg: %s")
			:format(Type, method, msg))
	end
end

-- Profiler Injection
function module:Profile(implementationTable, constructorName, scriptInstance)
	if scriptInstance and scriptInstance:GetAttribute("Profileable") == false then
		return implementationTable
	end
	local ReplicatedStorage = game:GetService("ReplicatedStorage")
	local ProfilerModule = ReplicatedStorage:FindFirstChild("ProfilerService")
	if not ProfilerModule then
	--	warn("[Kelux Debugger] ProfilerService not found; skipping profiling for "..tostring(self.Title))
		return implementationTable
	end
	local success, Profiler = pcall(require, ProfilerModule)
	if success and type(Profiler) == "table" then
		if Profiler.WrapFactory and constructorName then
			return Profiler.WrapFactory(self.Title, implementationTable, constructorName)
		elseif Profiler.Wrap then
			return Profiler.Wrap(self.Title, implementationTable)
		end
	end
	return implementationTable
end

-- Policy Checking
function module.Check(maxSize, policyName)
	policyName = policyName or "Policy"
	if typeof(maxSize) ~= "number" then
		if typeof(maxSize) == "string" then
			local num = tonumber(maxSize)
			if num == nil then
				module:Log("error","Check",("%s.new: maxSize (%s) could not be converted to a number.")
					:format(policyName,maxSize))
			end
			maxSize = num
		else
			module:Log("error","Check",("%s.new: maxSize must be a number, got type: %q")
				:format(policyName, maxSize))
		end
	end
	if maxSize < 0 then
		module:Log("error","Check",("%s.new: maxSize must be a non-negative number, got number: %s")
			:format(policyName, maxSize))
	end
	return maxSize
end

return module
