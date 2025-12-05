-- DO NOT EDIT IF YOU DON'T KNOW WHAT YOU'RE DOING
local module = {}
module.__index = module

-- TrieNode class
local TrieNode = {}
TrieNode.__index = TrieNode

function TrieNode.new()
	local self = setmetatable({}, TrieNode)
	self.children = {}
	self.isTerminal = false
	self.actionName = nil
	self.callback = nil
	self.expectedSequenceLength = 0
	return self
end

function TrieNode:hasChild(keyCode)
	return self.children[keyCode] ~= nil
end

function TrieNode:getChild(keyCode)
	return self.children[keyCode]
end

function TrieNode:addChild(keyCode)
	if not self.children[keyCode] then
		self.children[keyCode] = TrieNode.new()
	end
	return self.children[keyCode]
end

function TrieNode:setTerminal(actionName, callback, sequenceLength)
	self.isTerminal = true
	self.actionName = actionName
	self.callback = callback
	self.expectedSequenceLength = sequenceLength
end

-- module class
function module.new()
	local self = setmetatable({}, module)
	self.root = TrieNode.new()
	return self
end

function module:insert(actionName, comboSequence, callback)
	if not actionName or type(comboSequence) ~= "table" or #comboSequence == 0 or typeof(callback) ~= "function" then
		warn("[module] insert: Invalid arguments for actionName:", tostring(actionName))
		return false
	end

	local currentNode = self.root

	-- Traverse/create path through the trie
	for i = 1, #comboSequence do
		local keyCode = comboSequence[i]
		if not currentNode:hasChild(keyCode) then
			currentNode:addChild(keyCode)
		end
		currentNode = currentNode:getChild(keyCode)
	end

	-- Mark the final node as terminal
	currentNode:setTerminal(actionName, callback, #comboSequence)
	return true
end

function module:search(inputSequence)
	if not inputSequence or #inputSequence == 0 then
		return nil
	end

	local currentNode = self.root

	-- Traverse the trie following the input sequence
	for i = 1, #inputSequence do
		local keyCode = inputSequence[i]
		if not currentNode:hasChild(keyCode) then
			return nil -- Path doesn't exist in trie
		end
		currentNode = currentNode:getChild(keyCode)
	end

	return currentNode
end

function module:findMatch(inputSequence)
	local node = self:search(inputSequence)

	if not node then
		return nil -- No path found
	end

	-- Check if this is a complete combo match
	if node.isTerminal and node.expectedSequenceLength == #inputSequence then
		return {
			actionName = node.actionName,
			callback = node.callback,
			sequenceLength = node.expectedSequenceLength
		}
	end

	return nil -- Path exists but not a complete match
end

function module:hasPrefix(inputSequence)
	local node = self:search(inputSequence)
	return node ~= nil
end

function module:remove(actionName, comboSequence)
	if not actionName or type(comboSequence) ~= "table" or #comboSequence == 0 then
		warn("[module] remove: Invalid arguments for actionName:", tostring(actionName))
		return false
	end

	local function removeRecursive(node, sequence, depth)
		if depth > #sequence then
			-- We've reached the end of the sequence
			if node.isTerminal and node.actionName == actionName then
				node.isTerminal = false
				node.actionName = nil
				node.callback = nil
				node.expectedSequenceLength = 0
			end
			-- Return true if node can be deleted (no children and not terminal)
			return not node.isTerminal and self:_isNodeEmpty(node)
		end

		local keyCode = sequence[depth]
		local childNode = node:getChild(keyCode)

		if not childNode then
			return false -- Path doesn't exist
		end

		local shouldDeleteChild = removeRecursive(childNode, sequence, depth + 1)

		if shouldDeleteChild then
			node.children[keyCode] = nil
		end

		-- Return true if current node can be deleted
		return not node.isTerminal and self:_isNodeEmpty(node)
	end

	removeRecursive(self.root, comboSequence, 1)
	return true
end

function module:clear()
	self.root = TrieNode.new()
end

function module:_isNodeEmpty(node)
	for _ in pairs(node.children) do
		return false -- Has at least one child
	end
	return true -- No children
end

-- Debug function to print the trie structure
function module:printStructure(node, prefix, keyCodeToString)
	node = node or self.root
	prefix = prefix or ""
	keyCodeToString = keyCodeToString or tostring

	if node.isTerminal then
		print(prefix .. "-> [TERMINAL] Action: " .. (node.actionName or "nil") .. 
			" (Length: " .. node.expectedSequenceLength .. ")")
	end

	for keyCode, childNode in pairs(node.children) do
		local keyStr = keyCodeToString(keyCode)
		print(prefix .. keyStr)
		self:printStructure(childNode, prefix .. "  ", keyCodeToString)
	end
end

return module
