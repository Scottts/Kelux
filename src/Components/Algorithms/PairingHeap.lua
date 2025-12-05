-- Michael L. Fredman, Robert Sedgewick, Daniel Sleator, and Robert Tarjan
-- DO NOT EDIT IF YOU DON'T KNOW WHAT YOU'RE DOING
local PairingHeap = {}
PairingHeap.__index = PairingHeap

local Node = {}
Node.__index = Node

function Node.new(key, value)
	local self = setmetatable({}, Node)
	self.key = key
	self.value = value
	self.firstChild = nil
	self.nextSibling = nil
	self.prev = nil  
	return self
end

function PairingHeap.new()
	local self = setmetatable({}, PairingHeap)
	self.root = nil
	self.size = 0
	return self
end

function PairingHeap:insert(key, value)
	local newNode = Node.new(key, value)
	if self.root == nil then
		self.root = newNode
	else
		self.root = self:_meld(self.root, newNode)
	end
	self.size = self.size + 1
	return newNode
end

function PairingHeap:getMin()
	return self.root
end

function PairingHeap:extractMin()
	if self.root == nil then
		return nil
	end
	local minNode = self.root
	if self.root.firstChild == nil then
		self.root = nil
	else
		self.root = self:_mergePairs(self.root.firstChild)
	end
	self.size = self.size - 1
	return minNode
end

function PairingHeap:decreaseKey(node, newKey)
	if newKey > node.key then
		error("New key is greater than current key")
	end
	node.key = newKey
	if node ~= self.root then
		self:_cut(node)
		self.root = self:_meld(self.root, node)
	end
end

function PairingHeap:delete(node)
	if node == self.root then
		self:extractMin()
	else
		self:decreaseKey(node, -math.huge)
		self:extractMin()
	end
end

function PairingHeap:isEmpty()
	return self.root == nil
end

function PairingHeap:getSize()
	return self.size
end

function PairingHeap:union(other)
	local newHeap = PairingHeap.new()
	if self.root == nil then
		newHeap.root = other.root
	elseif other.root == nil then
		newHeap.root = self.root
	else
		newHeap.root = self:_meld(self.root, other.root)
	end
	newHeap.size = self.size + other.size
	return newHeap
end

function PairingHeap:clear()
	self.root = nil
	self.size = 0
end


function PairingHeap:_meld(a, b)
	if a == nil then return b end
	if b == nil then return a end
	if a.key > b.key then
		a, b = b, a
	end
	b.prev = a
	b.nextSibling = a.firstChild
	if a.firstChild ~= nil then
		a.firstChild.prev = b
	end
	a.firstChild = b
	return a
end

function PairingHeap:_cut(node)
	if node.prev == nil then
		return 
	end
	if node.nextSibling ~= nil then
		node.nextSibling.prev = node.prev
	end
	if node.prev.firstChild == node then
		node.prev.firstChild = node.nextSibling
	else
		node.prev.nextSibling = node.nextSibling
	end
	node.prev = nil
	node.nextSibling = nil
end

function PairingHeap:_mergePairs(firstChild)
	if firstChild == nil then
		return nil
	end
	if firstChild.nextSibling == nil then
		firstChild.prev = nil
		return firstChild
	end
	local children = {}
	local current = firstChild
	while current ~= nil do
		local next = current.nextSibling
		current.prev = nil
		current.nextSibling = nil
		table.insert(children, current)
		current = next
	end
	local merged = {}
	for i = 1, #children, 2 do
		if i + 1 <= #children then
			table.insert(merged, self:_meld(children[i], children[i + 1]))
		else
			table.insert(merged, children[i])
		end
	end
	local result = merged[#merged]
	for i = #merged - 1, 1, -1 do
		result = self:_meld(merged[i], result)
	end
	return result
end

return PairingHeap
