-- (B+ Tree)
-- DO NOT EDIT IF YOU DON'T KNOW WHAT YOU'RE DOING
local module = {}
module.__index = module

local Node = {}
Node.__index = Node

function Node.new(isLeaf)
	local self = setmetatable({}, Node)
	self.keys = {}
	self.values = {}
	self.children = {}
	self.isLeaf = isLeaf
	self.next = nil
	return self
end

function Node:FindIndex(key)
	local left, right = 1, #self.keys
	while left <= right do
		local mid = math.floor((left + right) / 2)
		if self.keys[mid] == key then
			return mid, true
		elseif self.keys[mid] < key then
			left = mid + 1
		else
			right = mid - 1
		end
	end
	return left, false
end

function Node:InsertAt(index, key, value)
	table.insert(self.keys, index, key)
	if self.isLeaf then
		table.insert(self.values, index, value)
	end
end

function Node:InsertChild(index, child)
	table.insert(self.children, index, child)
end

function Node:RemoveAt(index)
	table.remove(self.keys, index)
	if self.isLeaf then
		table.remove(self.values, index)
	end
end

function Node:RemoveChild(index)
	table.remove(self.children, index)
end

function module.new(order)
	order = order or 3
	assert(order >= 3, "Order must be at least 3")
	local self = setmetatable({}, module)
	self.order = order
	self.root = Node.new(true)
	self.minKeys = math.ceil(order / 2) - 1
	self.maxKeys = order - 1
	return self
end

function module:Search(key)
	return self:_search(self.root, key)
end

function module:_search(node, key)
	local idx, found = node:FindIndex(key)
	if node.isLeaf then
		if found then
			return node.values[idx]
		end
		return nil
	end
	if found then
		return self:_search(node.children[idx + 1], key)
	else
		return self:_search(node.children[idx], key)
	end
end

function module:Insert(key, value)
	local newChild = self:_insert(self.root, key, value)
	if newChild then
		local newRoot = Node.new(false)
		newRoot.keys[1] = newChild.key
		newRoot.children[1] = self.root
		newRoot.children[2] = newChild.node
		self.root = newRoot
	end
end

function module:_insert(node, key, value)
	if node.isLeaf then
		local idx, found = node:FindIndex(key)
		if found then
			node.values[idx] = value
			return nil
		end
		node:InsertAt(idx, key, value)
		if #node.keys > self.maxKeys then
			return self:_splitLeaf(node)
		end
		return nil
	else
		local idx, found = node:FindIndex(key)
		local childIdx = found and idx + 1 or idx
		local newChild = self:_insert(node.children[childIdx], key, value)
		if newChild then
			node:InsertAt(idx, newChild.key, nil)
			node:InsertChild(childIdx + 1, newChild.node)
			if #node.keys > self.maxKeys then
				return self:_splitInternal(node)
			end
		end
		return nil
	end
end

function module:_splitLeaf(node)
	local midIdx = math.ceil(#node.keys / 2)
	local newNode = Node.new(true)
	for i = midIdx, #node.keys do
		newNode.keys[#newNode.keys + 1] = node.keys[i]
		newNode.values[#newNode.values + 1] = node.values[i]
	end
	for i = #node.keys, midIdx, -1 do
		node:RemoveAt(i)
	end
	newNode.next = node.next
	node.next = newNode
	return {key = newNode.keys[1], node = newNode}
end

function module:_splitInternal(node)
	local midIdx = math.ceil(#node.keys / 2)
	local newNode = Node.new(false)
	local promotedKey = node.keys[midIdx]
	for i = midIdx + 1, #node.keys do
		newNode.keys[#newNode.keys + 1] = node.keys[i]
	end
	for i = midIdx + 1, #node.children do
		newNode.children[#newNode.children + 1] = node.children[i]
	end
	for i = #node.keys, midIdx, -1 do
		node:RemoveAt(i)
	end
	for i = #node.children, midIdx + 1, -1 do
		node:RemoveChild(i)
	end
	return {key = promotedKey, node = newNode}
end

function module:Delete(key)
	self:_delete(self.root, key)
	if #self.root.keys == 0 and not self.root.isLeaf and #self.root.children > 0 then
		self.root = self.root.children[1]
	end
end

function module:_delete(node, key)
	local idx, found = node:FindIndex(key)

	if node.isLeaf then
		if found then
			node:RemoveAt(idx)
		end
		return
	end
	local childIdx = found and idx + 1 or idx
	self:_delete(node.children[childIdx], key)
	if #node.children[childIdx].keys < self.minKeys and node.children[childIdx] ~= self.root then
		-- TODO: For simplicity this implementation doesn't handle all rebalancing cases
		-- A full implementation would handle borrowing from siblings and merging nodes
	end
end

function module:RangeQuery(startKey, endKey)
	local results = {}
	local node = self:_findLeaf(self.root, startKey)
	while node do
		for i = 1, #node.keys do
			if node.keys[i] >= startKey and node.keys[i] <= endKey then
				table.insert(results, {key = node.keys[i], value = node.values[i]})
			elseif node.keys[i] > endKey then
				return results
			end
		end
		node = node.next
	end
	return results
end

function module:_findLeaf(node, key)
	if node.isLeaf then
		return node
	end
	local idx, found = node:FindIndex(key)
	local childIdx = found and idx + 1 or idx
	return self:_findLeaf(node.children[childIdx], key)
end

function module:InOrderTraversal()
	local result = {}
	local node = self:_findLeaf(self.root, -math.huge)
	while node do
		for i = 1, #node.keys do
			table.insert(result, {key = node.keys[i], value = node.values[i]})
		end
		node = node.next
	end
	return result
end

function module:GetMin()
	local node = self.root
	while not node.isLeaf do
		node = node.children[1]
	end
	if #node.keys > 0 then
		return node.keys[1], node.values[1]
	end
	return nil
end

function module:GetMax()
	local node = self.root
	while not node.isLeaf do
		node = node.children[#node.children]
	end
	if #node.keys > 0 then
		local idx = #node.keys
		return node.keys[idx], node.values[idx]
	end
	return nil
end

return module
