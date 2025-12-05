-- Michael L. Fredman and Robert E. Tarjan
-- DO NOT EDIT IF YOU DON'T KNOW WHAT YOU'RE DOING
local FibonacciHeap = {}
FibonacciHeap.__index = FibonacciHeap

local Node = {}
Node.__index = Node

function Node.new(key, value)
	local self = setmetatable({}, Node)
	self.key = key
	self.value = value
	self.degree = 0
	self.marked = false
	self.parent = nil
	self.child = nil
	self.left = self
	self.right = self
	return self
end

function FibonacciHeap.new()
	local self = setmetatable({}, FibonacciHeap)
	self.min = nil
	self.n = 0  
	return self
end

function FibonacciHeap:insert(key, value)
	local node = Node.new(key, value)
	if self.min == nil then
		self.min = node
	else
		self:_addToRootList(node)
		if node.key < self.min.key then
			self.min = node
		end
	end
	self.n = self.n + 1
	return node
end

function FibonacciHeap:getMin()
	return self.min
end

function FibonacciHeap:extractMin()
	local z = self.min
	if z ~= nil then
		if z.child ~= nil then
			local child = z.child
			repeat
				local next = child.right
				child.parent = nil
				self:_addToRootList(child)
				child = next
			until child == z.child
		end
		self:_removeFromRootList(z)
		if z == z.right then
			self.min = nil
		else
			self.min = z.right
			self:_consolidate()
		end
		self.n = self.n - 1
	end
	return z
end

function FibonacciHeap:decreaseKey(node, newKey)
	if newKey > node.key then
		error("New key is greater than current key")
	end
	node.key = newKey
	local parent = node.parent
	if parent ~= nil and node.key < parent.key then
		self:_cut(node, parent)
		self:_cascadingCut(parent)
	end
	if node.key < self.min.key then
		self.min = node
	end
end

function FibonacciHeap:delete(node)
	self:decreaseKey(node, -math.huge)
	self:extractMin()
end

function FibonacciHeap:isEmpty()
	return self.min == nil
end

function FibonacciHeap:size()
	return self.n
end

function FibonacciHeap:union(other)
	local newHeap = FibonacciHeap.new()
	newHeap.min = self.min
	if newHeap.min ~= nil and other.min ~= nil then
		local temp = newHeap.min.right
		newHeap.min.right = other.min.right
		other.min.right.left = newHeap.min
		other.min.right = temp
		temp.left = other.min
		if other.min.key < newHeap.min.key then
			newHeap.min = other.min
		end
	elseif newHeap.min == nil then
		newHeap.min = other.min
	end
	newHeap.n = self.n + other.n
	return newHeap
end

function FibonacciHeap:_addToRootList(node)
	if self.min == nil then
		self.min = node
		node.left = node
		node.right = node
	else
		node.left = self.min
		node.right = self.min.right
		self.min.right.left = node
		self.min.right = node
	end
	node.parent = nil
end

function FibonacciHeap:_removeFromRootList(node)
	if node.right == node then
		return
	end
	node.left.right = node.right
	node.right.left = node.left
end

function FibonacciHeap:_consolidate()
	local maxDegree = math.floor(math.log(self.n) / math.log(2)) + 1
	local A = {}
	for i = 0, maxDegree do
		A[i] = nil
	end
	local rootNodes = {}
	if self.min ~= nil then
		local current = self.min
		repeat
			table.insert(rootNodes, current)
			current = current.right
		until current == self.min
	end
	for _, w in ipairs(rootNodes) do
		local x = w
		local d = x.degree
		while A[d] ~= nil do
			local y = A[d]
			if x.key > y.key then
				x, y = y, x
			end
			self:_link(y, x)
			A[d] = nil
			d = d + 1
		end
		A[d] = x
	end
	self.min = nil
	for i = 0, maxDegree do
		if A[i] ~= nil then
			if self.min == nil then
				self.min = A[i]
				A[i].left = A[i]
				A[i].right = A[i]
			else
				self:_addToRootList(A[i])
				if A[i].key < self.min.key then
					self.min = A[i]
				end
			end
		end
	end
end

function FibonacciHeap:_link(y, x)
	self:_removeFromRootList(y)
	y.parent = x
	if x.child == nil then
		x.child = y
		y.left = y
		y.right = y
	else
		y.left = x.child
		y.right = x.child.right
		x.child.right.left = y
		x.child.right = y
	end
	x.degree = x.degree + 1
	y.marked = false
end

function FibonacciHeap:_cut(x, y)
	if x.right == x then
		y.child = nil
	else
		if y.child == x then
			y.child = x.right
		end
		x.left.right = x.right
		x.right.left = x.left
	end
	y.degree = y.degree - 1
	self:_addToRootList(x)
	x.parent = nil
	x.marked = false
end

function FibonacciHeap:_cascadingCut(y)
	local z = y.parent
	if z ~= nil then
		if not y.marked then
			y.marked = true
		else
			self:_cut(y, z)
			self:_cascadingCut(z)
		end
	end
end

return FibonacciHeap
