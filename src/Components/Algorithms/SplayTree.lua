-- DO NOT EDIT IF YOU DON'T KNOW WHAT YOU'RE DOING
local module = {}
module.__index = module

local function createNode(key, value)
	return {
		key = key,
		value = value,
		left = nil,
		right = nil,
		parent = nil
	}
end

function module.new()
	local self = setmetatable({}, module)
	self.root = nil
	self.size = 0
	return self
end

function module:_rotateRight(node)
	local left = node.left
	node.left = left.right
	if left.right then
		left.right.parent = node
	end
	left.parent = node.parent
	if not node.parent then
		self.root = left
	elseif node == node.parent.right then
		node.parent.right = left
	else
		node.parent.left = left
	end
	left.right = node
	node.parent = left
end

function module:_rotateLeft(node)
	local right = node.right
	node.right = right.left
	if right.left then
		right.left.parent = node
	end
	right.parent = node.parent
	if not node.parent then
		self.root = right
	elseif node == node.parent.left then
		node.parent.left = right
	else
		node.parent.right = right
	end
	right.left = node
	node.parent = right
end

function module:_splay(node)
	while node.parent do
		local parent = node.parent
		local grandparent = parent.parent
		if not grandparent then
			if node == parent.left then
				self:_rotateRight(parent)
			else
				self:_rotateLeft(parent)
			end
		elseif node == parent.left and parent == grandparent.left then
			self:_rotateRight(grandparent)
			self:_rotateRight(parent)
		elseif node == parent.right and parent == grandparent.right then
			self:_rotateLeft(grandparent)
			self:_rotateLeft(parent)
		elseif node == parent.right and parent == grandparent.left then
			self:_rotateLeft(parent)
			self:_rotateRight(grandparent)
		else
			self:_rotateRight(parent)
			self:_rotateLeft(grandparent)
		end
	end
end

function module:Insert(key, value)
	if not self.root then
		self.root = createNode(key, value)
		self.size = 1
		return true
	end
	local current = self.root
	local parent = nil
	while current do
		parent = current
		if key < current.key then
			current = current.left
		elseif key > current.key then
			current = current.right
		else
			current.value = value
			self:_splay(current)
			return false
		end
	end
	local newNode = createNode(key, value)
	newNode.parent = parent
	if key < parent.key then
		parent.left = newNode
	else
		parent.right = newNode
	end
	self.size += 1
	self:_splay(newNode)
	return true
end

function module:Find(key)
	if not self.root then
		return nil
	end
	local current = self.root
	local lastNode = nil
	while current do
		lastNode = current
		if key < current.key then
			current = current.left
		elseif key > current.key then
			current = current.right
		else
			self:_splay(current)
			return current.value
		end
	end
	self:_splay(lastNode)
	return nil
end

function module:Delete(key)
	local value = self:Find(key)
	if not value then
		return false
	end
	local root = self.root
	if not root.left then
		self.root = root.right
		if self.root then
			self.root.parent = nil
		end
	elseif not root.right then
		self.root = root.left
		if self.root then
			self.root.parent = nil
		end
	else
		local leftTree = root.left
		leftTree.parent = nil
		local rightTree = root.right
		rightTree.parent = nil
		local maxNode = leftTree
		while maxNode.right do
			maxNode = maxNode.right
		end
		self.root = leftTree
		self:_splay(maxNode)
		self.root.right = rightTree
		rightTree.parent = self.root
	end
	self.size -= 1
	return true
end

function module:FindMin()
	if not self.root then
		return nil
	end
	local current = self.root
	while current.left do
		current = current.left
	end
	self:_splay(current)
	return current.key, current.value
end

function module:FindMax()
	if not self.root then
		return nil
	end
	local current = self.root
	while current.right do
		current = current.right
	end
	self:_splay(current)
	return current.key, current.value
end

function module:PopMin()
	local key, value = self:FindMin()
	if key then
		self:Delete(key)
		return key, value
	end
	return nil
end

function module:PopMax()
	local key, value = self:FindMax()
	if key then
		self:Delete(key)
		return key, value
	end
	return nil
end

function module:InOrder()
	local result = {}
	local function traverse(node)
		if not node then return end
		traverse(node.left)
		table.insert(result, {key = node.key, value = node.value})
		traverse(node.right)
	end
	traverse(self.root)
	return result
end

function module:GetRange(minKey, maxKey)
	local result = {}
	local function traverse(node)
		if not node then return end
		if node.key > minKey then
			traverse(node.left)
		end
		if node.key >= minKey and node.key <= maxKey then
			table.insert(result, {key = node.key, value = node.value})
		end
		if node.key < maxKey then
			traverse(node.right)
		end
	end
	traverse(self.root)
	return result
end

function module:GetSize()
	return self.size
end

function module:IsEmpty()
	return self.size == 0
end

function module:Clear()
	self.root = nil
	self.size = 0
end

return module
