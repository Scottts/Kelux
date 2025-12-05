-- Alfred Aho & Margaret J. Corasick
-- DO NOT EDIT IF YOU DON'T KNOW WHAT YOU'RE DOING
local module = {}
module.__index = module

local function createNode()
	return {
		children = {},
		failure = nil,
		output = {},
		isEndOfPattern = false
	}
end

function module.new(patterns)
	local self = setmetatable({}, module)
	self.root = createNode()
	self.patterns = patterns or {}
	self.isBuilt = false
	return self
end

function module:AddPattern(pattern)
	if type(pattern) ~= "string" or #pattern == 0 then
		error("Pattern must be a non-empty string")
	end
	table.insert(self.patterns, pattern)
	self.isBuilt = false
end

function module:AddPatterns(patterns)
	for _, pattern in ipairs(patterns) do
		if type(pattern) ~= "string" or #pattern == 0 then
			error("All patterns must be non-empty strings")
		end
		table.insert(self.patterns, pattern)
	end
	self.isBuilt = false
end

function module:Build()
	if #self.patterns == 0 then
		return
	end
	self:_buildTrie()
	self:_buildFailureLinks()
	self:_buildOutputLinks()
	self.isBuilt = true
end

function module:_buildTrie()
	self.root = createNode()
	for patternIndex, pattern in ipairs(self.patterns) do
		local currentNode = self.root
		for i = 1, #pattern do
			local char = string.sub(pattern, i, i)
			if not currentNode.children[char] then
				currentNode.children[char] = createNode()
			end
			currentNode = currentNode.children[char]
		end
		currentNode.isEndOfPattern = true
		table.insert(currentNode.output, {
			pattern = pattern,
			index = patternIndex
		})
	end
end

function module:_buildFailureLinks()
	local queue = {}
	for char, child in pairs(self.root.children) do
		child.failure = self.root
		table.insert(queue, child)
	end

	while #queue > 0 do
		local currentNode = table.remove(queue, 1)
		for char, child in pairs(currentNode.children) do
			table.insert(queue, child)
			local failure = currentNode.failure
			while failure and not failure.children[char] do
				failure = failure.failure
			end
			if failure and failure.children[char] then
				child.failure = failure.children[char]
			else
				child.failure = self.root
			end
		end
	end
end

function module:_buildOutputLinks()
	local queue = {}
	for char, child in pairs(self.root.children) do
		table.insert(queue, child)
	end
	while #queue > 0 do
		local currentNode = table.remove(queue, 1)
		for char, child in pairs(currentNode.children) do
			table.insert(queue, child)
		end
		if currentNode.failure then
			for _, output in ipairs(currentNode.failure.output) do
				table.insert(currentNode.output, output)
			end
		end
	end
end

function module:Search(text)
	if not self.isBuilt then
		error("Automaton has not been built. Call Build() after adding patterns.")
	end
	if type(text) ~= "string" then
		error("Text must be a string")
	end
	local matches = {}
	if #self.patterns == 0 then
		return matches
	end
	local currentNode = self.root
	for i = 1, #text do
		local char = string.sub(text, i, i)
		while currentNode ~= self.root and not currentNode.children[char] do
			currentNode = currentNode.failure
		end
		if currentNode.children[char] then
			currentNode = currentNode.children[char]
		end
		for _, output in ipairs(currentNode.output) do
			local match = {
				pattern = output.pattern,
				startPos = i - #output.pattern + 1,
				endPos = i,
				patternIndex = output.index
			}
			table.insert(matches, match)
		end
	end
	return matches
end

function module:Contains(text)
	return #self:Search(text) > 0
end

function module:Count(text)
	return #self:Search(text)
end

function module:GetMatchedPatterns(text)
	local matches = self:Search(text)
	local uniquePatterns = {}
	local seen = {}
	for _, match in ipairs(matches) do
		if not seen[match.pattern] then
			seen[match.pattern] = true
			table.insert(uniquePatterns, match.pattern)
		end
	end
	return uniquePatterns
end

function module:Replace(text, replacements)
	if not self.isBuilt then
		error("Automaton has not been built. Call Build() after adding patterns.")
	end
	if type(replacements) == "string" then
		local singleReplacement = replacements
		replacements = {}
		for _, pattern in ipairs(self.patterns) do
			replacements[pattern] = singleReplacement
		end
	elseif type(replacements) ~= "table" then
		error("Replacements must be a string or table")
	end
	local matches = self:Search(text)
	table.sort(matches, function(a, b)
		if a.startPos ~= b.startPos then
			return a.startPos > b.startPos
		end
		return #a.pattern > #b.pattern
	end)
	local result = text
	local lastReplacedPos = #text + 1
	for _, match in ipairs(matches) do
		local replacement = replacements[match.pattern]
		if replacement and match.endPos < lastReplacedPos then
			result = string.sub(result, 1, match.startPos - 1)..
				replacement..string.sub(result, match.endPos + 1)
			lastReplacedPos = match.startPos
		end
	end
	return result
end

function module:GetStats()
	local nodeCount = 0
	if self.isBuilt then
		local function countNodes(node)
			local count = 1
			for _, child in pairs(node.children) do
				count = count + countNodes(child)
			end
			return count
		end
		nodeCount = countNodes(self.root)
	end
	return {
		patternCount = #self.patterns,
		nodeCount = nodeCount,
		isBuilt = self.isBuilt,
		patterns = self.patterns
	}
end

return module
