-- (Lazy Propagation Segment Tree)
-- DO NOT EDIT IF YOU DON'T KNOW WHAT YOU'RE DOING
local module = {}
module.__index = module

local OP_SUM = "sum"
local OP_MIN = "min"
local OP_MAX = "max"

function module.new(arr, operation)
	local self = setmetatable({}, module)
	self.n = #arr
	self.arr = table.clone(arr)
	self.operation = operation or OP_SUM
	self.tree = table.create(4 * self.n, 0)
	self.lazy = table.create(4 * self.n, 0)
	self:_build(1, 1, self.n)
	return self
end

function module:_merge(left, right)
	if self.operation == OP_SUM then
		return left + right
	elseif self.operation == OP_MIN then
		return math.min(left, right)
	elseif self.operation == OP_MAX then
		return math.max(left, right)
	end
	return left + right
end

function module:_neutral()
	if self.operation == OP_SUM then
		return 0
	elseif self.operation == OP_MIN then
		return math.huge
	elseif self.operation == OP_MAX then
		return -math.huge
	end
	return 0
end

function module:_build(node, start, finish)
	if start == finish then
		self.tree[node] = self.arr[start]
		return
	end
	local mid = math.floor((start + finish) / 2)
	local leftChild = 2 * node
	local rightChild = 2 * node + 1
	self:_build(leftChild, start, mid)
	self:_build(rightChild, mid + 1, finish)
	self.tree[node] = self:_merge(self.tree[leftChild], self.tree[rightChild])
end

function module:_push(node, start, finish)
	if self.lazy[node] == 0 then
		return
	end
	if self.operation == OP_SUM then
		self.tree[node] = self.tree[node] + (finish - start + 1) * self.lazy[node]
	elseif self.operation == OP_MIN or self.operation == OP_MAX then
		self.tree[node] = self.tree[node] + self.lazy[node]
	end
	if start ~= finish then
		local leftChild = 2 * node
		local rightChild = 2 * node + 1
		self.lazy[leftChild] = self.lazy[leftChild] + self.lazy[node]
		self.lazy[rightChild] = self.lazy[rightChild] + self.lazy[node]
	end
	self.lazy[node] = 0
end

function module:RangeUpdate(left, right, value)
	self:_updateRange(1, 1, self.n, left, right, value)
end

function module:_updateRange(node, start, finish, left, right, value)
	self:_push(node, start, finish)
	if start > right or finish < left then
		return
	end
	if start >= left and finish <= right then
		self.lazy[node] = self.lazy[node] + value
		self:_push(node, start, finish)
		return
	end
	local mid = math.floor((start + finish) / 2)
	local leftChild = 2 * node
	local rightChild = 2 * node + 1
	self:_updateRange(leftChild, start, mid, left, right, value)
	self:_updateRange(rightChild, mid + 1, finish, left, right, value)
	self:_push(leftChild, start, mid)
	self:_push(rightChild, mid + 1, finish)
	self.tree[node] = self:_merge(self.tree[leftChild], self.tree[rightChild])
end

function module:RangeQuery(left, right)
	return self:_queryRange(1, 1, self.n, left, right)
end

function module:_queryRange(node, start, finish, left, right)
	self:_push(node, start, finish)
	if start > right or finish < left then
		return self:_neutral()
	end
	if start >= left and finish <= right then
		return self.tree[node]
	end
	local mid = math.floor((start + finish) / 2)
	local leftChild = 2 * node
	local rightChild = 2 * node + 1
	local leftResult = self:_queryRange(leftChild, start, mid, left, right)
	local rightResult = self:_queryRange(rightChild, mid + 1, finish, left, right)
	return self:_merge(leftResult, rightResult)
end

function module:PointUpdate(index, value)
	self:_updatePoint(1, 1, self.n, index, value)
end

function module:_updatePoint(node, start, finish, index, value)
	self:_push(node, start, finish)
	if start == finish then
		self.tree[node] = value
		self.arr[index] = value
		return
	end
	local mid = math.floor((start + finish) / 2)
	local leftChild = 2 * node
	local rightChild = 2 * node + 1
	if index <= mid then
		self:_updatePoint(leftChild, start, mid, index, value)
	else
		self:_updatePoint(rightChild, mid + 1, finish, index, value)
	end
	self:_push(leftChild, start, mid)
	self:_push(rightChild, mid + 1, finish)
	self.tree[node] = self:_merge(self.tree[leftChild], self.tree[rightChild])
end

function module:PointQuery(index)
	return self:RangeQuery(index, index)
end

function module:Clear()
	self.tree = {}
end

return module
