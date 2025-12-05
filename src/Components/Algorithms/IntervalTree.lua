-- Jon Bentley
-- DO NOT EDIT IF YOU DON'T KNOW WHAT YOU'RE DOING
local module = {}
module.__index = module

local Node = {}
Node.__index = Node

function Node.new(low, high, data)
	local self = setmetatable({}, Node)
	self.low = low
	self.high = high
	self.max = high
	self.data = data
	self.left = nil
	self.right = nil
	return self
end

function module.new()
	local self = setmetatable({}, module)
	self.root = nil
	self.size = 0
	return self
end

local function updateMax(node)
	if not node then return end
	node.max = node.high
	if node.left and node.left.max > node.max then
		node.max = node.left.max
	end
	if node.right and node.right.max > node.max then
		node.max = node.right.max
	end
end

local function insertNode(node, low, high, data)
	if not node then
		return Node.new(low, high, data)
	end
	if low < node.low then
		node.left = insertNode(node.left, low, high, data)
	else
		node.right = insertNode(node.right, low, high, data)
	end
	updateMax(node)
	return node
end

function module:insert(low, high, data)
	assert(low <= high, "Low must be less than or equal to high")
	self.root = insertNode(self.root, low, high, data)
	self.size = self.size + 1
end

local function doOverlap(low1, high1, low2, high2)
	return low1 <= high2 and low2 <= high1
end

local function queryNode(node, low, high, results)
	if not node then return end
	if node.left and node.left.max >= low then
		queryNode(node.left, low, high, results)
	end
	if doOverlap(node.low, node.high, low, high) then
		table.insert(results, {
			low = node.low,
			high = node.high,
			data = node.data
		})
	end
	if node.right and node.low <= high then
		queryNode(node.right, low, high, results)
	end
end

function module:query(low, high)
	assert(low <= high, "Low must be less than or equal to high")

	local results = {}
	queryNode(self.root, low, high, results)
	return results
end

function module:queryPoint(point)
	return self:query(point, point)
end

local function inorderNode(node, callback)
	if not node then return end
	inorderNode(node.left, callback)
	callback(node)
	inorderNode(node.right, callback)
end

function module:getAll()
	local results = {}
	inorderNode(self.root, function(node)
		table.insert(results, {
			low = node.low,
			high = node.high,
			data = node.data
		})
	end)
	return results
end

function module:getSize()
	return self.size
end

function module:clear()
	self.root = nil
	self.size = 0
end

function module:isEmpty()
	return self.root == nil
end

local function getHeight(node)
	if not node then return 0 end
	return 1 + math.max(getHeight(node.left), getHeight(node.right))
end

function module:getHeight()
	return getHeight(self.root)
end

return module
