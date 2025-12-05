local Properties = require(script.Parent.Properties)
local function shallowcopy(original)
	local copy = {}
	for key, value in pairs(original) do
		copy[key] = value
	end
	return copy
end

local Serializer = {}

local ClassHierarchy = {
	-- Base Classes
	Part = "BasePart",
	Model = "Instance",
	BasePart = "Instance",
	TrussPart = "Part",
	WedgePart = "Part",
	CornerWedgePart = "Part",
	MeshPart = "Part",
	PartOperation = "BasePart",
	VehicleSeat = "Seat",
	Seat = "Part",
	SpawnLocation = "Part",
	-- Gui Classes
	ScreenGui = "LayerCollector",
	BillboardGui = "LayerCollector",
	SurfaceGui = "LayerCollector",
	LayerCollector = "GuiBase2d",
	Frame = "GuiObject",
	ImageLabel = "GuiObject",
	TextLabel = "GuiObject",
	ImageButton = "GuiButton",
	TextButton = "GuiButton",
	TextBox = "GuiObject",
	GuiButton = "GuiObject",
	ScrollingFrame = "GuiObject",
	GuiObject = "GuiBase2d",
	GuiBase2d = "GuiBase",
	GuiBase = "Instance",
	-- Constraints
	WeldConstraint = "Instance",
	HingeConstraint = "Constraint",
	Constraint = "Instance",
	-- Lights
	PointLight = "Light",
	SpotLight = "Light",
	SurfaceLight = "Light",
	Light = "Instance",
	-- Others
	Humanoid = "Instance",
	Animation = "Instance",
	Sound = "Instance",
	Tool = "BackpackItem",
	BackpackItem = "Instance",
	Attachment = "Instance",
	ParticleEmitter = "Instance",
	-- Top-level terminator
	Instance = nil,
}

local TypeHandlers = {
	Vector3 = {
		serialize = function(v) return {v.X, v.Y, v.Z} end,
		deserialize = function(t) return Vector3.new(unpack(t)) end,
	},
	Vector2 = {
		serialize = function(v) return {v.X, v.Y} end,
		deserialize = function(t) return Vector2.new(unpack(t)) end,
	},
	CFrame = {
		serialize = function(cf) return {cf:GetComponents()} end,
		deserialize = function(t) return CFrame.new(unpack(t)) end,
	},
	Color3 = {
		serialize = function(c) return {c.R, c.G, c.B} end,
		deserialize = function(t) return Color3.new(t[1], t[2], t[3]) end,
	},
	BrickColor = {
		serialize = function(bc) return bc.Number end,
		deserialize = function(n) return BrickColor.new(n) end,
	},
	UDim = {
		serialize = function(u) return {u.Scale, u.Offset} end,
		deserialize = function(t) return UDim.new(t[1], t[2]) end,
	},
	UDim2 = {
		serialize = function(u2) return {u2.X.Scale, u2.X.Offset, u2.Y.Scale, u2.Y.Offset} end,
		deserialize = function(t) return UDim2.new(t[1], t[2], t[3], t[4]) end,
	},
	Rect = {
		serialize = function(r) return {r.Min.X, r.Min.Y, r.Max.X, r.Max.Y} end,
		deserialize = function(t) return Rect.new(t[1], t[2], t[3], t[4]) end,
	},
	EnumItem = {
		serialize = function(e)
			if typeof(e) == "EnumItem" then
				return {Type = tostring(e.EnumType), Name = e.Name}
			else
				return tostring(e)
			end
		end,
		deserialize = function(t) return Enum[t.Type][t.Name] end,
	},
	NumberRange = {
		serialize = function(nr) return {nr.Min, nr.Max} end,
		deserialize = function(t) return NumberRange.new(t[1], t[2]) end,
	},
	ColorSequence = {
		serialize = function(cs)
			local keypoints = {}
			for _, kp in ipairs(cs.Keypoints) do
				table.insert(keypoints, {Time = kp.Time, Color = {kp.Value.R, kp.Value.G, kp.Value.B}})
			end
			return keypoints
		end,
		deserialize = function(t)
			local keypoints = {}
			for _, kpData in ipairs(t) do
				table.insert(keypoints, ColorSequenceKeypoint.new(kpData.Time, Color3.new(unpack(kpData.Color))))
			end
			return ColorSequence.new(keypoints)
		end,
	},
	NumberSequence = {
		serialize = function(ns)
			local keypoints = {}
			for _, kp in ipairs(ns.Keypoints) do
				table.insert(keypoints, {Time = kp.Time, Value = kp.Value, Envelope = kp.Envelope})
			end
			return keypoints
		end,
		deserialize = function(t)
			local keypoints = {}
			for _, kpData in ipairs(t) do
				table.insert(keypoints, NumberSequenceKeypoint.new(kpData.Time, kpData.Value, kpData.Envelope))
			end
			return NumberSequence.new(keypoints)
		end,
	},
	PhysicalProperties = {
		serialize = function(p) return {p.Density, p.Friction, p.Elasticity, p.FrictionWeight, p.ElasticityWeight} end,
		deserialize = function(t) return PhysicalProperties.new(t[1], t[2], t[3], t[4], t[5]) end,
	},
}

--[[
	These properties are often computed, read-only, or context-dependent
	and can cause errors when accessed on standalone instances
]]
local Blacklist = {
	-- Identity & Parentage
	["Parent"] = true,
	["ClassName"] = true,
	["Archivable"] = true,
	-- Computed Physics State
	["AssemblyAngularVelocity"] = true,
	["AssemblyCenterOfMass"] = true,
	["AssemblyLinearVelocity"] = true,
	["AssemblyMass"] = true,
	["AssemblyRootPart"] = true,
	["Mass"] = true,
	-- Computed World Coordinates
	["WorldCFrame"] = true,
	["WorldPosition"] = true,
	["WorldOrientation"] = true,
	["WorldPivot"] = true,
	["WorldAxis"] = true,
	["WorldSecondaryAxis"] = true,
	["ExtentsOffsetWorldSpace"] = true,
	["StudsOffsetWorldSpace"] = true,
	-- Computed GUI Coordinates
	["AbsolutePosition"] = true,
	["AbsoluteRotation"] = true,
	["AbsoluteSize"] = true,
	["AbsoluteCanvasSize"] = true,
	["AbsoluteWindowSize"] = true,
	-- Live State & Read-Only
	["IsPlaying"] = true,
	["IsPaused"] = true,
	["IsLoaded"] = true,
	["PlaybackLoudness"] = true,
	["TimePosition"] = true,
	["TimeLength"] = true,
	["Occupant"] = true,
	["CurrentPage"] = true,
	["IsFinished"] = true,
	["Status"] = true,
	["CurrentCamera"] = true,
	["Character"] = true,
	-- Properties that are references to other instances
	["Adornee"] = true,
	["Part0"] = true,
	["Part1"] = true,
	["Attachment0"] = true,
	["Attachment1"] = true,
	["PrimaryPart"] = true,
	-- Deprecated / Internal / Unsafe
	["PropertyStatusStudio"] = true,
	["ResizeableFaces"] = true,
	["GroupColor"] = true,
	["AccessoryBlob"] = true,
	["Shape"] = true,
	["ChildName"] = true,
	["ParentName"] = true,
	["Broken"] = true,
	["DestructionEnabled"] = true,
	["DestructionForce"] = true,
	["DestructionTorque"] = true,
	["DebugMode"] = true,
	-- Restricted to higher permissions
	["LevelOfDetail"] = true,
	["Source"] = true,
	["ChannelCount"] = true,
	["AlphaMode"] = true,
	["ColorMap"] = true,
	["MetalnessMap"] = true,
	["NormalMap"] = true,
	["RoughnessMap"] = true,
	-- FaceControls properties
	["ChinRaiser"] = true,
	["ChinRaiserUpperLip"] = true,
	["Corrugator"] = true,
	["EyesLookDown"] = true,
	["EyesLookLeft"] = true,
	["EyesLookRight"] = true,
	["EyesLookUp"] = true,
	["FlatPucker"] = true,
	["Funneler"] = true,
	["JawDrop"] = true,
	["JawLeft"] = true,
	["JawRight"] = true,
	["LeftBrowLowerer"] = true,
	["LeftCheekPuff"] = true,
	["LeftCheekRaiser"] = true,
	["LeftDimpler"] = true,
	["LeftEyeClosed"] = true,
	["LeftEyeUpperLidRaiser"] = true,
	["LeftInnerBrowRaiser"] = true,
	["LeftLipCornerDown"] = true,
	["LeftLipCornerPuller"] = true,
	["LeftLipStretcher"] = true,
	["LeftLowerLipDepressor"] = true,
	["LeftNoseWrinkler"] = true,
	["LeftOuterBrowRaiser"] = true,
	["LeftUpperLipRaiser"] = true,
	["LipPresser"] = true,
	["LipsTogether"] = true,
	["LowerLipSuck"] = true,
	["MouthLeft"] = true,
	["MouthRight"] = true,
	["Pucker"] = true,
	["RightBrowLowerer"] = true,
	["RightCheekPuff"] = true,
	["RightCheekRaiser"] = true,
	["RightDimpler"] = true,
	["RightEyeClosed"] = true,
	["RightEyeUpperLidRaiser"] = true,
	["RightInnerBrowRaiser"] = true,
	["RightLipCornerDown"] = true,
	["RightLipCornerPuller"] = true,
	["RightLipStretcher"] = true,
	["RightLowerLipDepressor"] = true,
	["RightNoseWrinkler"] = true,
	["RightOuterBrowRaiser"] = true,
	["RightUpperLipRaiser"] = true,
	["TongueDown"] = true,
	["TongueOut"] = true,
	["TongueUp"] = true,
	["UpperLipSuck"] = true,
}

local FullPropertiesMap = {}
local function getOrBuildProperties(className, propsDefinition)
	if FullPropertiesMap[className] then
		return shallowcopy(FullPropertiesMap[className])
	end
	local finalProperties = {}
	local ownProperties = propsDefinition[className] or {}
	for _, prop in ipairs(ownProperties) do
		table.insert(finalProperties, prop)
	end
	local parentClass = ClassHierarchy[className]
	if parentClass then
		local inheritedProperties = getOrBuildProperties(parentClass, propsDefinition)
		for _, prop in ipairs(inheritedProperties) do
			table.insert(finalProperties, prop)
		end
	end
	FullPropertiesMap[className] = finalProperties
	return finalProperties
end

local function BuildInheritanceMap(propsDefinition)
	for className in pairs(propsDefinition) do
		getOrBuildProperties(className, propsDefinition)
	end
	return FullPropertiesMap
end
local CompleteProperties = BuildInheritanceMap(Properties)

--[[
    Serializes a single Roblox Instance into a JSON-safe table.
]]
function Serializer.SerializeInstance(instance, includeDescendants)
	local className = instance.ClassName
	local data = {
		ClassName = className,
		Name = instance.Name,
		Properties = {},
		Attributes = {},
		Children = nil,
	}
	local propertiesToSave = CompleteProperties[className]
	if not propertiesToSave then
		warn("Serializer: No properties found for class:", className)
		return data
	end
	for _, propName in ipairs(propertiesToSave) do
		if not Blacklist[propName] then
			local accessSuccess, value = pcall(function() return instance[propName] end)
			if accessSuccess and value ~= nil then
				local valueType = typeof(value)
				if valueType == "Instance" then
					-- ignore
				elseif TypeHandlers[valueType] then
					local serializeSuccess, result = pcall(TypeHandlers[valueType].serialize, value)
					if serializeSuccess then
						data.Properties[propName] = {_type = valueType, _value = result}
					else
						warn(("[Serializer Error] > Failed to process property '%s'. Reason: %s")
							:format(propName, tostring(result)))
					end
				elseif type(value) == "string" or type(value) == "number" or type(value) == "boolean" then
					data.Properties[propName] = value
				elseif typeof(value) == "EnumItem" and TypeHandlers["EnumItem"] then
					local serializeSuccess, result = pcall(TypeHandlers["EnumItem"].serialize, value)
					if serializeSuccess then
						data.Properties[propName] = {_type = "EnumItem", _value = result}
					else
						warn(("[Serializer Error] > Failed to process EnumItem property '%s'. Reason: %s"):format(propName, tostring(result)))
					end
				end
			elseif not accessSuccess then
				warn(("[Serializer Error] > Failed to access property '%s'. Reason: %s")
					:format(propName, tostring(value)))
			end
		end
	end
	local allAttributes = instance:GetAttributes()
	for attrName, attrValue in pairs(allAttributes) do
		if attrValue ~= nil then
			local valueType = typeof(attrValue)
			if valueType == "Instance" then
				-- ignore
			elseif TypeHandlers[valueType] then
				local serializeSuccess, result = pcall(TypeHandlers[valueType].serialize, attrValue)
				if serializeSuccess then
					data.Attributes[attrName] = {_type = valueType, _value = result}
				else
					warn(("[Serializer Error] > Failed to process attribute '%s'. Reason: %s")
						:format(attrName, tostring(result)))
				end
			elseif type(attrValue) == "string" or type(attrValue) == "number" or type(attrValue) == "boolean" then
				data.Attributes[attrName] = attrValue
			elseif typeof(attrValue) == "EnumItem" and TypeHandlers["EnumItem"] then
				local serializeSuccess, result = pcall(TypeHandlers["EnumItem"].serialize, attrValue)
				if serializeSuccess then
					data.Attributes[attrName] = {_type = "EnumItem", _value = result}
				else
					warn(("[Serializer Error] > Failed to process EnumItem attribute '%s'. Reason: %s")
						:format(attrName, tostring(result)))
				end
			end
		end
	end
	if includeDescendants then
		local childrenData = {}
		for _, child in ipairs(instance:GetChildren()) do
			local childData = Serializer.SerializeInstance(child, true)
			if childData then
				table.insert(childrenData, childData)
			end
		end
		if #childrenData > 0 then
			data.Children = childrenData
		end
	end
	return data
end

--[[
    Deserializes a table into a new Roblox Instance.
]]
function Serializer.DeserializeInstance(data)
	if not data or not data.ClassName then return nil end
	local instance: Instance?
	local success, result = pcall(Instance.new, data.ClassName)
	if not success then
		warn("Serializer: Failed to create instance of type", data.ClassName, "-", result)
		return nil
	end
	instance = result
	instance.Name = data.Name
	for propName, value in pairs(data.Properties) do
		local finalValue = value
		local typeInfo = type(value) == "table" and value._type
		if typeInfo and TypeHandlers[typeInfo] then
			local deserializeSuccess, deserializedValue = pcall(TypeHandlers[typeInfo].deserialize, value._value)
			if deserializeSuccess then
				finalValue = deserializedValue
			else
				warn(("[Serializer Error] > Failed to deserialize property '%s' of type '%s'. Reason: %s")
					:format(propName, typeInfo, tostring(deserializedValue)))
				finalValue = nil
			end
		elseif typeInfo then
			warn(("[Serializer Warning] > Unknown _type '%s' found for property '%s'. Using raw value.")
				:format(typeInfo, propName))
			finalValue = value._value -- Use raw value if type handler missing
		end
		if finalValue ~= nil then
			local setSuccess, setError = pcall(function()
				instance[propName] = finalValue
			end)
			if not setSuccess then
				warn(("[Serializer Error] > Failed to set property '%s' on %s. Value: %s. Reason: %s")
					:format(propName, instance.ClassName, tostring(finalValue), tostring(setError)))
			end
		end
	end
	if data.Attributes then
		for attrName, value in pairs(data.Attributes) do
			local finalValue = value
			local typeInfo = type(value) == "table" and value._type
			if typeInfo and TypeHandlers[typeInfo] then
				local deserializeSuccess, deserializedValue = pcall(TypeHandlers[typeInfo].deserialize, value._value)
				if deserializeSuccess then
					finalValue = deserializedValue
				else
					warn(("[Serializer Error] > Failed to deserialize attribute '%s' of type '%s'. Reason: %s")
						:format(attrName, typeInfo, tostring(deserializedValue)))
					finalValue = nil
				end
			elseif typeInfo then
				warn(("[Serializer Warning] > Unknown _type '%s' found for attribute '%s'. Using raw value.")
					:format(typeInfo, attrName))
				finalValue = value._value
			elseif typeInfo == "EnumItem" and TypeHandlers["EnumItem"] then
				local deserializeSuccess, deserializedValue = pcall(TypeHandlers["EnumItem"].deserialize, value._value)
				if deserializeSuccess then
					finalValue = deserializedValue
				else
					warn(("[Serializer Error] > Failed to deserialize EnumItem attribute '%s'. Reason: %s"):format(attrName, tostring(deserializedValue)))
					finalValue = nil
				end
			end
			if finalValue ~= nil then
				local setSuccess, setError = pcall(instance.SetAttribute, instance, attrName, finalValue)
				if not setSuccess then
					warn(("[Serializer Error] > Failed to set attribute '%s'. Value: %s. Reason: %s"):format(attrName, tostring(finalValue), tostring(setError)))
				end
			end
		end
	end
	if data.Children then
		for _, childData in ipairs(data.Children) do
			local childInstance = Serializer.DeserializeInstance(childData)
			if childInstance then
				childInstance.Parent = instance
			end
		end
	end
	return instance
end

return Serializer
