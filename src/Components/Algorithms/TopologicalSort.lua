local TopologicalSort = {}

local function dfsTopologicalSort(graph, visited, stack, node, inProgress)
	inProgress[node] = true
	visited[node] = true
	if graph[node] then
		for _, neighbor in ipairs(graph[node]) do
			if inProgress[neighbor] then
				return false, "Cycle detected involving node: "..tostring(neighbor)
			end
			if not visited[neighbor] then
				local success, errorMsg = dfsTopologicalSort(graph, visited, stack, neighbor, inProgress)
				if not success then
					return false, errorMsg
				end
			end
		end
	end
	inProgress[node] = false
	table.insert(stack, node)
	return true, nil
end

local function edgeListToAdjacencyList(edges)
	local graph = {}
	local nodes = {}
	for _, edge in ipairs(edges) do
		local from, to = edge[1], edge[2]
		nodes[from] = true
		nodes[to] = true

		if not graph[from] then
			graph[from] = {}
		end
		if not graph[to] then
			graph[to] = {}
		end
		table.insert(graph[from], to)
	end
	return graph, nodes
end

local function kahnAlgorithm(graph, allNodes)
	local inDegree = {}
	local queue = {}
	local result = {}
	for node in pairs(allNodes) do
		inDegree[node] = 0
	end
	for node, neighbors in pairs(graph) do
		for _, neighbor in ipairs(neighbors) do
			inDegree[neighbor] = inDegree[neighbor] + 1
		end
	end
	for node, degree in pairs(inDegree) do
		if degree == 0 then
			table.insert(queue, node)
		end
	end
	while #queue > 0 do
		local current = table.remove(queue, 1)
		table.insert(result, current)
		if graph[current] then
			for _, neighbor in ipairs(graph[current]) do
				inDegree[neighbor] = inDegree[neighbor] - 1
				if inDegree[neighbor] == 0 then
					table.insert(queue, neighbor)
				end
			end
		end
	end
	local totalNodes = 0
	for _ in pairs(allNodes) do
		totalNodes = totalNodes + 1
	end
	if #result ~= totalNodes then
		return nil, "Cycle detected in graph"
	end
	return result, nil
end

function TopologicalSort.sortFromAdjacencyList(graph, useKahn)
	if not graph or type(graph) ~= "table" then
		return nil, "Invalid graph provided"
	end
	local allNodes = {}
	for node, neighbors in pairs(graph) do
		allNodes[node] = true
		for _, neighbor in ipairs(neighbors) do
			allNodes[neighbor] = true
		end
	end
	if useKahn then
		return kahnAlgorithm(graph, allNodes)
	else
		local visited = {}
		local stack = {}
		local inProgress = {}
		for node in pairs(allNodes) do
			if not visited[node] then
				local success, errorMsg = dfsTopologicalSort(graph, visited, stack, node, inProgress)
				if not success then
					return nil, errorMsg
				end
			end
		end
		local result = {}
		for i = #stack, 1, -1 do
			table.insert(result, stack[i])
		end
		return result, nil
	end
end

function TopologicalSort.sortFromEdgeList(edges, useKahn)
	if not edges or type(edges) ~= "table" then
		return nil, "Invalid edges provided"
	end
	local graph, allNodes = edgeListToAdjacencyList(edges)
	if useKahn then
		return kahnAlgorithm(graph, allNodes)
	else
		return TopologicalSort.sortFromAdjacencyList(graph, false)
	end
end

function TopologicalSort.hasCycle(graph)
	local result, errorMsg = TopologicalSort.sortFromAdjacencyList(graph, false)
	return result == nil, errorMsg
end

function TopologicalSort.getAllNodes(graph)
	local allNodes = {}
	local nodeSet = {}
	for node, neighbors in pairs(graph) do
		if not nodeSet[node] then
			nodeSet[node] = true
			table.insert(allNodes, node)
		end
		for _, neighbor in ipairs(neighbors) do
			if not nodeSet[neighbor] then
				nodeSet[neighbor] = true
				table.insert(allNodes, neighbor)
			end
		end
	end
	return allNodes
end

function TopologicalSort.resolveDependencies(dependencies)
	local graph = {}
	local allNodes = {}
	for item, deps in pairs(dependencies) do
		allNodes[item] = true
		if not graph[item] then
			graph[item] = {}
		end
		for _, dep in ipairs(deps) do
			allNodes[dep] = true
			if not graph[dep] then
				graph[dep] = {}
			end
			table.insert(graph[dep], item)
		end
	end
	return TopologicalSort.sortFromAdjacencyList(graph, true)
end

return TopologicalSort
