-- DO NOT EDIT IF YOU DON'T KNOW WHAT YOU'RE DOING
local CHF = require(script.Parent.CHF)
local MerkleTree = {}
MerkleTree.__index = MerkleTree

local function hash(data: string): string
	return CHF.SHA256(data)
end

local function combineHash(left: string, right: string): string
	return hash(left .. right)
end

local function createNode(hash: string, left, right)
	return {
		hash = hash,
		left = left,
		right = right
	}
end

function MerkleTree.new(leaves: {any})
	local self = setmetatable({}, MerkleTree)
	if not leaves or #leaves == 0 then
		error("MerkleTree requires at least one leaf")
	end
	self.leaves = {}
	self.layers = {}
	for i, data in ipairs(leaves) do
		local leafHash = hash(data)
		self.leaves[i] = createNode(leafHash, nil, nil)
	end
	self:buildTree()
	return self
end

function MerkleTree:buildTree()
	local currentLayer = self.leaves
	self.layers = {currentLayer}
	while #currentLayer > 1 do
		local nextLayer = {}
		for i = 1, #currentLayer, 2 do
			local left = currentLayer[i]
			local right = currentLayer[i + 1]
			if right then
				local parentHash = combineHash(left.hash, right.hash)
				table.insert(nextLayer, createNode(parentHash, left, right))
			else
				local parentHash = combineHash(left.hash, left.hash)
				table.insert(nextLayer, createNode(parentHash, left, left))
			end
		end
		table.insert(self.layers, nextLayer)
		currentLayer = nextLayer
	end
	self.root = currentLayer[1]
end

function MerkleTree:getRoot(): string
	return self.root.hash
end

function MerkleTree:getProof(index: number): {any}
	if index < 1 or index > #self.leaves then
		error("Index out of bounds")
	end
	local proof = {}
	local currentIndex = index
	for layerIdx = 1, #self.layers - 1 do
		local layer = self.layers[layerIdx]
		local isRightNode = currentIndex % 2 == 0
		local siblingIndex = isRightNode and currentIndex - 1 or currentIndex + 1
		if siblingIndex <= #layer then
			table.insert(proof, {
				hash = layer[siblingIndex].hash,
				position = isRightNode and "left" or "right"
			})
		else
			table.insert(proof, {
				hash = layer[currentIndex].hash,
				position = isRightNode and "left" or "right"
			})
		end
		currentIndex = math.ceil(currentIndex / 2)
	end
	return proof
end

function MerkleTree.verify(proof: {any}, leaf: any, rootHash: string): boolean
	local currentHash = hash(leaf)
	for _, step in ipairs(proof) do
		if step.position == "left" then
			currentHash = combineHash(step.hash, currentHash)
		else
			currentHash = combineHash(currentHash, step.hash)
		end
	end
	return currentHash == rootHash
end

function MerkleTree:getLeaves(): {string}
	local hashes = {}
	for i, leaf in ipairs(self.leaves) do
		hashes[i] = leaf.hash
	end
	return hashes
end

function MerkleTree:getDepth(): number
	return #self.layers
end

return MerkleTree
