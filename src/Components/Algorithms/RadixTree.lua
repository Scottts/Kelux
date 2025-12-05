-- Donald R. Morrison and Gernot Gwehenberger
-- DO NOT EDIT IF YOU DON'T KNOW WHAT YOU'RE DOING
local module = {}
module.__index = module

local function createNode(prefix: string, isEnd: boolean, value: any?)
	return {
		prefix = prefix or "",
		children = {},
		isEnd = isEnd or false,
		value = value,
	}
end

local function longestCommonPrefix(str1: string, str2: string): string
	local minLen = math.min(#str1, #str2)
	for i = 1, minLen do
		if str1:sub(i, i) ~= str2:sub(i, i) then
			return str1:sub(1, i - 1)
		end
	end
	return str1:sub(1, minLen)
end

function module.new()
	local self = setmetatable({}, module)
	self.root = createNode("", false, nil)
	self.size = 0
	return self
end

function module:Insert(key: string, value: any)
	if not key or #key == 0 then
		warn("Cannot insert empty key")
		return
	end
	local node = self.root
	local remainingKey = key
	while #remainingKey > 0 do
		local foundChild = false
		for firstChar, child in pairs(node.children) do
			local prefix = child.prefix
			local commonPrefix = longestCommonPrefix(remainingKey, prefix)
			if #commonPrefix > 0 then
				foundChild = true
				if commonPrefix == prefix then
					remainingKey = remainingKey:sub(#commonPrefix + 1)
					node = child
					break
				end
				local splitNode = createNode(commonPrefix, false, nil)
				child.prefix = prefix:sub(#commonPrefix + 1)
				splitNode.children[child.prefix:sub(1, 1)] = child
				node.children[firstChar] = nil
				node.children[commonPrefix:sub(1, 1)] = splitNode
				remainingKey = remainingKey:sub(#commonPrefix + 1)
				if #remainingKey > 0 then
					local newNode = createNode(remainingKey, true, value)
					splitNode.children[remainingKey:sub(1, 1)] = newNode
					self.size = self.size + 1
					return
				else
					splitNode.isEnd = true
					splitNode.value = value
					self.size = self.size + 1
					return
				end
			end
		end
		if not foundChild then
			local newNode = createNode(remainingKey, true, value)
			node.children[remainingKey:sub(1, 1)] = newNode
			self.size = self.size + 1
			return
		end
	end
	if not node.isEnd then
		self.size = self.size + 1
	end
	node.isEnd = true
	node.value = value
end

function module:Search(key: string): any?
	if not key then
		return nil
	end
	local node = self.root
	local remainingKey = key
	while #remainingKey > 0 do
		local foundChild = false
		for _, child in pairs(node.children) do
			local prefix = child.prefix
			local commonPrefix = longestCommonPrefix(remainingKey, prefix)
			if commonPrefix == prefix then
				remainingKey = remainingKey:sub(#prefix + 1)
				node = child
				foundChild = true
				break
			end
		end
		if not foundChild then
			return nil
		end
	end
	return node.isEnd and node.value or nil
end

function module:Delete(key: string): boolean
	if not key then
		return false
	end
	local function deleteHelper(node, remainingKey: string): boolean
		if #remainingKey == 0 then
			if not node.isEnd then
				return false
			end
			node.isEnd = false
			node.value = nil
			self.size = self.size - 1
			return true
		end
		for firstChar, child in pairs(node.children) do
			local prefix = child.prefix
			local commonPrefix = longestCommonPrefix(remainingKey, prefix)
			if commonPrefix == prefix then
				local deleted = deleteHelper(child, remainingKey:sub(#prefix + 1))
				if deleted then
					local childCount = 0
					for _ in pairs(child.children) do
						childCount = childCount + 1
					end
					if childCount == 0 and not child.isEnd then
						node.children[firstChar] = nil
					elseif childCount == 1 and not child.isEnd then
						local onlyChild = next(child.children)
						local merged = child.children[onlyChild]
						merged.prefix = child.prefix .. merged.prefix
						node.children[firstChar] = merged
					end
				end

				return deleted
			end
		end
		return false
	end
	return deleteHelper(self.root, key)
end

function module:StartsWith(prefix: string): {any}
	local results = {}
	local function findNode(node, remainingPrefix: string)
		if #remainingPrefix == 0 then
			return node
		end
		for _, child in pairs(node.children) do
			local nodePrefix = child.prefix
			local commonPrefix = longestCommonPrefix(remainingPrefix, nodePrefix)
			if commonPrefix == nodePrefix then
				return findNode(child, remainingPrefix:sub(#nodePrefix + 1))
			elseif commonPrefix == remainingPrefix then
				return child
			end
		end

		return nil
	end
	local function collectValues(node)
		if node.isEnd then
			table.insert(results, node.value)
		end

		for _, child in pairs(node.children) do
			collectValues(child)
		end
	end
	local startNode = findNode(self.root, prefix)
	if startNode then
		collectValues(startNode)
	end
	return results
end

function module:GetAllKeys(): {string}
	local keys = {}
	local function traverse(node, currentKey: string)
		local fullKey = currentKey .. node.prefix
		if node.isEnd then
			table.insert(keys, fullKey)
		end

		for _, child in pairs(node.children) do
			traverse(child, fullKey)
		end
	end
	for _, child in pairs(self.root.children) do
		traverse(child, "")
	end
	return keys
end

function module:Clear()
	self.root = createNode("", false, nil)
	self.size = 0
end

function module:GetSize(): number
	return self.size
end

return module
