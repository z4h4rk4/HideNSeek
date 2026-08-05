--!strict

local HiderConfig = require(script.Parent:WaitForChild("HiderConfig"))
local HiderMapGeometry = require(script.Parent:WaitForChild("HiderMapGeometry"))

type Link = {
	to: number,
	cost: number,
}

type Graph = {
	geometry: HiderMapGeometry.ArenaGeometry,
	nodes: {Vector2},
	links: {{Link}},
	edgeCount: number,
}

export type GraphStats = {
	nodes: number,
	edges: number,
	walls: number,
}

local HiderVisibilityGraph = {}
local graphsByMap: {[Instance]: Graph} = {}
local cachedGeometryRevision = -1

local function planar(position: Vector3): Vector2
	return Vector2.new(position.X, position.Z)
end

local function world(point: Vector2, y: number): Vector3
	return Vector3.new(point.X, y, point.Y)
end

local function cross(left: Vector2, right: Vector2): number
	return left.X * right.Y - left.Y * right.X
end

local function segmentIntersection(
	firstStart: Vector2,
	firstEnd: Vector2,
	secondStart: Vector2,
	secondEnd: Vector2
): Vector2?
	local firstDirection = firstEnd - firstStart
	local secondDirection = secondEnd - secondStart
	local denominator = cross(firstDirection, secondDirection)
	if math.abs(denominator) <= HiderConfig.GEOMETRY_EPSILON then
		return nil
	end
	local betweenStarts = secondStart - firstStart
	local firstTime = cross(betweenStarts, secondDirection) / denominator
	local secondTime = cross(betweenStarts, firstDirection) / denominator
	local epsilon = HiderConfig.GEOMETRY_EPSILON
	if firstTime < -epsilon or firstTime > 1 + epsilon
		or secondTime < -epsilon or secondTime > 1 + epsilon then
		return nil
	end
	return firstStart + firstDirection * math.clamp(firstTime, 0, 1)
end

local function appendUniqueNode(
	nodes: {Vector2},
	geometry: HiderMapGeometry.ArenaGeometry,
	candidate: Vector2
)
	if not HiderMapGeometry.PointIsNavigable(geometry, candidate) then
		return
	end
	local mergeDistanceSquared = HiderConfig.NODE_MERGE_DISTANCE ^ 2
	for _, node in ipairs(nodes) do
		if (node - candidate).Magnitude ^ 2 <= mergeDistanceSquared then
			return
		end
	end
	table.insert(nodes, candidate)
end

local function getBoundaryEdges(boundary: {Vector2}): {{startPoint: Vector2, endPoint: Vector2}}
	local edges: {{startPoint: Vector2, endPoint: Vector2}} = {}
	for index, startPoint in ipairs(boundary) do
		local endPoint = boundary[index % #boundary + 1]
		table.insert(edges, {
			startPoint = startPoint,
			endPoint = endPoint,
		})
	end
	return edges
end

local function buildNodes(geometry: HiderMapGeometry.ArenaGeometry): {Vector2}
	local nodes: {Vector2} = {}
	local boundaries: {{Vector2}} = {}
	for _, obstacle in ipairs(geometry.obstacles) do
		for _, corner in ipairs(HiderMapGeometry.GetNavigationCorners(obstacle, HiderConfig.NODE_OUTSET)) do
			appendUniqueNode(nodes, geometry, corner)
		end
		table.insert(boundaries, HiderMapGeometry.GetNavigationBoundary(obstacle))
	end

	-- Overlapping and joined rectangles create union-outline corners at edge
	-- intersections. They are not necessarily corners of either original Part.
	for firstIndex = 1, #boundaries - 1 do
		local firstEdges = getBoundaryEdges(boundaries[firstIndex])
		for secondIndex = firstIndex + 1, #boundaries do
			local secondEdges = getBoundaryEdges(boundaries[secondIndex])
			for _, firstEdge in ipairs(firstEdges) do
				for _, secondEdge in ipairs(secondEdges) do
					local intersection = segmentIntersection(
						firstEdge.startPoint,
						firstEdge.endPoint,
						secondEdge.startPoint,
						secondEdge.endPoint
					)
					if intersection then
						for directionIndex = 0, HiderConfig.INTERSECTION_OUTSET_DIRECTIONS - 1 do
							local angle = directionIndex * math.pi * 2
								/ HiderConfig.INTERSECTION_OUTSET_DIRECTIONS
							local direction = Vector2.new(math.cos(angle), math.sin(angle))
							appendUniqueNode(
								nodes,
								geometry,
								intersection + direction * HiderConfig.NODE_OUTSET
							)
						end
					end
				end
			end
		end
	end
	return nodes
end

local function buildGraph(geometry: HiderMapGeometry.ArenaGeometry): Graph
	local nodes = buildNodes(geometry)
	local links: {{Link}} = {}
	for _ = 1, #nodes do
		table.insert(links, {})
	end
	local edgeCount = 0
	for firstIndex = 1, #nodes - 1 do
		for secondIndex = firstIndex + 1, #nodes do
			local first = nodes[firstIndex]
			local second = nodes[secondIndex]
			if HiderMapGeometry.SegmentIsNavigable(geometry, first, second, false) then
				local cost = (second - first).Magnitude
				table.insert(links[firstIndex], { to = secondIndex, cost = cost })
				table.insert(links[secondIndex], { to = firstIndex, cost = cost })
				edgeCount += 1
			end
		end
	end
	return {
		geometry = geometry,
		nodes = nodes,
		links = links,
		edgeCount = edgeCount,
	}
end

local function getGraph(geometry: HiderMapGeometry.ArenaGeometry): Graph
	local currentRevision = HiderMapGeometry.GetRevision()
	if currentRevision ~= cachedGeometryRevision then
		graphsByMap = {}
		cachedGeometryRevision = currentRevision
	end
	local existing = graphsByMap[geometry.map]
	if existing and existing.geometry == geometry then
		return existing
	end
	local graph = buildGraph(geometry)
	graphsByMap[geometry.map] = graph
	return graph
end

local function smoothRoute(
	geometry: HiderMapGeometry.ArenaGeometry,
	startPoint: Vector2,
	rawRoute: {Vector2}
): {Vector2}
	local smoothed: {Vector2} = {}
	local current = startPoint
	local rawIndex = 1
	local firstSegment = true
	while rawIndex <= #rawRoute do
		local selectedIndex = rawIndex
		for candidateIndex = #rawRoute, rawIndex, -1 do
			if HiderMapGeometry.SegmentIsNavigable(
				geometry,
				current,
				rawRoute[candidateIndex],
				firstSegment
			) then
				selectedIndex = candidateIndex
				break
			end
		end
		local selected = rawRoute[selectedIndex]
		table.insert(smoothed, selected)
		current = selected
		rawIndex = selectedIndex + 1
		firstSegment = false
	end
	return smoothed
end

local function buildQueryGraph(
	graph: Graph,
	startPosition: Vector3,
	goalPosition: Vector3
): ({Vector2}, {{Link}}, number, number)
	local nodes: {Vector2} = {}
	for _, node in ipairs(graph.nodes) do
		table.insert(nodes, node)
	end
	local links: {{Link}} = {}
	for _, sourceLinks in ipairs(graph.links) do
		local copied: {Link} = {}
		for _, link in ipairs(sourceLinks) do
			table.insert(copied, {
				to = link.to,
				cost = link.cost,
			})
		end
		table.insert(links, copied)
	end

	local staticNodeCount = #nodes
	local startIndex = #nodes + 1
	table.insert(nodes, planar(startPosition))
	table.insert(links, {})
	local goalIndex = #nodes + 1
	table.insert(nodes, planar(goalPosition))
	table.insert(links, {})

	-- Static-to-static visibility is already present in graph.links. Only the
	-- query nodes (Start and Goal) need new visibility checks. Iterating
	-- from the first dynamic node avoids repeating the static graph's O(n^2)
	-- pair scan for every wander candidate and every NPC.
	for secondIndex = staticNodeCount + 1, #nodes do
		for firstIndex = 1, secondIndex - 1 do
			local firstPoint = nodes[firstIndex]
			local secondPoint = nodes[secondIndex]
			local visible: boolean
			if firstIndex == startIndex then
				visible = HiderMapGeometry.SegmentIsNavigable(graph.geometry, firstPoint, secondPoint, true)
			elseif secondIndex == startIndex then
				visible = HiderMapGeometry.SegmentIsNavigable(graph.geometry, secondPoint, firstPoint, true)
			else
				visible = HiderMapGeometry.SegmentIsNavigable(graph.geometry, firstPoint, secondPoint, false)
			end
			if visible then
				local cost = (secondPoint - firstPoint).Magnitude
				table.insert(links[firstIndex], { to = secondIndex, cost = cost })
				table.insert(links[secondIndex], { to = firstIndex, cost = cost })
			end
		end
	end
	return nodes, links, startIndex, goalIndex
end

local function reconstructRoute(
	geometry: HiderMapGeometry.ArenaGeometry,
	nodes: {Vector2},
	startIndex: number,
	goalIndex: number,
	cameFrom: {[number]: number},
	y: number
): {Vector3}?
	local reversed: {Vector2} = {}
	local current = goalIndex
	while current ~= startIndex do
		local previous = cameFrom[current]
		if not previous then
			return nil
		end
		table.insert(reversed, nodes[current])
		current = previous
	end

	local rawPoints: {Vector2} = {}
	for index = #reversed, 1, -1 do
		table.insert(rawPoints, reversed[index])
	end

	local route: {Vector3} = {}
	for _, point in ipairs(smoothRoute(geometry, nodes[startIndex], rawPoints)) do
		table.insert(route, world(point, y))
	end
	return route
end

function HiderVisibilityGraph.FindPath(
	geometry: HiderMapGeometry.ArenaGeometry,
	startPosition: Vector3,
	goalPosition: Vector3
): {Vector3}?
	local startPoint = planar(startPosition)
	local goalPoint = planar(goalPosition)
	if not HiderMapGeometry.PointIsNavigable(geometry, goalPoint) then
		return nil
	end
	if HiderMapGeometry.SegmentIsNavigable(geometry, startPoint, goalPoint, true) then
		return { world(goalPoint, startPosition.Y) }
	end

	local graph = getGraph(geometry)
	local nodes, links, startIndex, goalIndex = buildQueryGraph(graph, startPosition, goalPosition)
	local openSet: {[number]: boolean} = { [startIndex] = true }
	local cameFrom: {[number]: number} = {}
	local costFromStart: {[number]: number} = { [startIndex] = 0 }
	local estimatedTotalCost: {[number]: number} = {
		[startIndex] = (nodes[startIndex] - nodes[goalIndex]).Magnitude,
	}

	while next(openSet) ~= nil do
		local current: number? = nil
		local bestEstimate = math.huge
		for index in pairs(openSet) do
			local estimate = estimatedTotalCost[index] or math.huge
			if estimate < bestEstimate then
				bestEstimate = estimate
				current = index
			end
		end
		if not current then
			break
		end
		openSet[current] = nil
		if current == goalIndex then
			return reconstructRoute(
				geometry,
				nodes,
				startIndex,
				goalIndex,
				cameFrom,
				startPosition.Y
			)
		end

		local currentCost = costFromStart[current]
		if not currentCost then
			continue
		end
		for _, link in ipairs(links[current]) do
			local tentativeCost = currentCost + link.cost
			if tentativeCost < (costFromStart[link.to] or math.huge) then
				cameFrom[link.to] = current
				costFromStart[link.to] = tentativeCost
				estimatedTotalCost[link.to] = tentativeCost
					+ (nodes[link.to] - nodes[goalIndex]).Magnitude
				openSet[link.to] = true
			end
		end
	end
	return nil
end

function HiderVisibilityGraph.GetStats(
	geometry: HiderMapGeometry.ArenaGeometry
): GraphStats
	local graph = getGraph(geometry)
	return {
		nodes = #graph.nodes,
		edges = graph.edgeCount,
		walls = #geometry.obstacles,
	}
end

function HiderVisibilityGraph.PrepareAll()
	for _, geometry in ipairs(HiderMapGeometry.GetAll()) do
		getGraph(geometry)
	end
end

function HiderVisibilityGraph.RouteLength(startPosition: Vector3, route: {Vector3}, firstIndex: number?): number
	local length = 0
	local previous = startPosition
	for index = firstIndex or 1, #route do
		local waypoint = route[index]
		length += (planar(waypoint) - planar(previous)).Magnitude
		previous = waypoint
	end
	return length
end

return HiderVisibilityGraph
