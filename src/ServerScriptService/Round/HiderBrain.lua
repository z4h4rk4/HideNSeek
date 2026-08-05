--!strict

local HiderConfig = require(script.Parent:WaitForChild("HiderConfig"))
local HiderMapGeometry = require(script.Parent:WaitForChild("HiderMapGeometry"))
local HiderVisibilityGraph = require(script.Parent:WaitForChild("HiderVisibilityGraph"))
local NpcDoorInteraction = require(script.Parent:WaitForChild("NpcDoorInteraction"))

type CandidateChoice = {
	position: Vector3,
	sectorId: string,
	score: number,
}

type PlannedRoute = {
	geometry: HiderMapGeometry.ArenaGeometry,
	points: {Vector3},
	destination: Vector3,
	sectorId: string,
}

export type Controller = {
	npc: Model,
	humanoid: Humanoid,
	rootPart: BasePart,
	random: Random,
	running: boolean,
	active: boolean,
	geometry: HiderMapGeometry.ArenaGeometry?,
	route: {Vector3},
	routeIndex: number,
	destination: Vector3?,
	destinationSector: string?,
	pendingRoute: PlannedRoute?,
	sectorVisits: {[string]: number},
	nextRouteRetryAt: number,
	nextPrefetchRetryAt: number,
	waypointPlaneNormal: Vector3,
	waypointPlaneDistance: number,
	waypointApproachStart: Vector3,
	bestWaypointDistance: number,
	lastProgressAt: number,
	lastMoveDirection: Vector3,
	nextDoorPushAt: number,
}

local HiderBrain = {}

local function planarDistance(left: Vector3, right: Vector3): number
	return Vector2.new(left.X - right.X, left.Z - right.Z).Magnitude
end

local function horizontalUnit(vector: Vector3): Vector3?
	local horizontal = Vector3.new(vector.X, 0, vector.Z)
	return if horizontal.Magnitude > 0.001 then horizontal.Unit else nil
end

local function clearRoute(controller: Controller)
	controller.route = {}
	controller.routeIndex = 1
	controller.destination = nil
	controller.destinationSector = nil
	controller.waypointPlaneNormal = Vector3.zero
	controller.waypointPlaneDistance = 0
	controller.bestWaypointDistance = math.huge
	controller.nextDoorPushAt = 0
end

local function clearPendingRoute(controller: Controller)
	controller.pendingRoute = nil
	controller.npc:SetAttribute("AIPrefetchedRoute", false)
end

local function setNavigationStatus(controller: Controller, status: string)
	if controller.npc:GetAttribute("AINavigationStatus") ~= status then
		controller.npc:SetAttribute("AINavigationStatus", status)
	end
end

local function setWaypointApproach(controller: Controller)
	local waypoint = controller.route[controller.routeIndex]
	if not waypoint then
		controller.waypointPlaneNormal = Vector3.zero
		controller.waypointPlaneDistance = 0
		controller.bestWaypointDistance = math.huge
		return
	end
	controller.waypointApproachStart = controller.rootPart.Position
	local normal = horizontalUnit(controller.waypointApproachStart - waypoint)
	controller.waypointPlaneNormal = normal or Vector3.zero
	controller.waypointPlaneDistance = if normal then normal:Dot(waypoint) else 0
	controller.bestWaypointDistance = planarDistance(controller.rootPart.Position, waypoint)
	controller.lastProgressAt = os.clock()
end

local function waypointReached(controller: Controller, waypoint: Vector3): boolean
	if planarDistance(controller.rootPart.Position, waypoint) <= HiderConfig.WAYPOINT_REACHED_DISTANCE then
		return true
	end
	local normal = controller.waypointPlaneNormal
	if normal == Vector3.zero then
		return false
	end
	local planeDistance = normal:Dot(controller.rootPart.Position) - controller.waypointPlaneDistance
	if planeDistance > HiderConfig.WAYPOINT_PLANE_THRESHOLD then
		return false
	end
	local direction = -normal
	local right = Vector3.new(-direction.Z, 0, direction.X)
	local crossTrack = math.abs(right:Dot(controller.rootPart.Position - waypoint))
	return crossTrack <= HiderConfig.WAYPOINT_MAX_CROSS_TRACK
end

local function scoreCandidate(
	controller: Controller,
	origin: Vector3,
	candidate: HiderMapGeometry.Destination,
	now: number
): number?
	local offset = candidate.position - origin
	local distance = Vector2.new(offset.X, offset.Z).Magnitude
	if distance < HiderConfig.WANDER_ABSOLUTE_MIN_TARGET_DISTANCE then
		return nil
	end

	local lastVisitedAt = controller.sectorVisits[candidate.sectorId]
	local explorationBonus = if lastVisitedAt
		then math.min(
			HiderConfig.WANDER_REVISIT_BONUS_CAP,
			math.max(0, now - lastVisitedAt) * HiderConfig.WANDER_REVISIT_RECOVERY_PER_SECOND
		)
		else HiderConfig.WANDER_UNVISITED_SECTOR_BONUS
	local direction = horizontalUnit(offset)
	local turnScore = 0
	if direction then
		local currentDirection = horizontalUnit(controller.lastMoveDirection)
			or horizontalUnit(controller.rootPart.CFrame.LookVector)
		if currentDirection then
			turnScore = currentDirection:Dot(direction) * HiderConfig.WANDER_FORWARD_WEIGHT
		end
	end
	local shortTargetPenalty = math.max(0, HiderConfig.WANDER_MIN_TARGET_DISTANCE - distance)
		* HiderConfig.WANDER_SHORT_TARGET_PENALTY
	return explorationBonus
		+ math.min(distance, HiderConfig.WANDER_DISTANCE_SCORE_CAP)
		+ turnScore
		+ controller.random:NextNumber(0, HiderConfig.WANDER_SCORE_RANDOMNESS)
		- shortTargetPenalty
end

local function collectChoices(
	controller: Controller,
	geometry: HiderMapGeometry.ArenaGeometry,
	origin: Vector3,
	now: number
): {CandidateChoice}
	local bySector: {[string]: {CandidateChoice}} = {}
	for _ = 1, HiderConfig.WANDER_SAMPLE_COUNT do
		local candidate = HiderMapGeometry.SampleDestination(geometry, controller.random)
		if candidate then
			local score = scoreCandidate(controller, origin, candidate, now)
			if score then
				local choice = {
					position = candidate.position,
					sectorId = candidate.sectorId,
					score = score,
				}
				local sectorChoices = bySector[candidate.sectorId]
				if not sectorChoices then
					sectorChoices = {}
					bySector[candidate.sectorId] = sectorChoices
				end
				table.insert(sectorChoices, choice)
				table.sort(sectorChoices, function(left, right)
					return left.score > right.score
				end)
				if #sectorChoices > HiderConfig.WANDER_CANDIDATES_PER_SECTOR then
					table.remove(sectorChoices)
				end
			end
		end
	end

	local choices: {CandidateChoice} = {}
	for _, sectorChoices in pairs(bySector) do
		for _, choice in ipairs(sectorChoices) do
			table.insert(choices, choice)
		end
	end
	table.sort(choices, function(left, right)
		return left.score > right.score
	end)
	controller.npc:SetAttribute("AICandidateCount", #choices)
	return choices
end

local function updateGeometryDiagnostics(
	controller: Controller,
	geometry: HiderMapGeometry.ArenaGeometry
)
	local stats = HiderVisibilityGraph.GetStats(geometry)
	controller.npc:SetAttribute("AIMapName", geometry.map:GetFullName())
	controller.npc:SetAttribute("AIWallCount", stats.walls)
	controller.npc:SetAttribute("AIGraphNodes", stats.nodes)
	controller.npc:SetAttribute("AIGraphEdges", stats.edges)
end

local function planRoute(
	controller: Controller,
	origin: Vector3,
	now: number,
	reportFailure: boolean
): PlannedRoute?
	local geometry = HiderMapGeometry.GetForPosition(origin)
	if not geometry then
		if reportFailure then
			controller.npc:SetAttribute("AIStallReason", "NoMapFloorOrWalls")
		end
		return nil
	end
	controller.geometry = geometry
	updateGeometryDiagnostics(controller, geometry)

	local choices = collectChoices(controller, geometry, origin, now)
	if #choices == 0 then
		if reportFailure then
			controller.npc:SetAttribute("AIStallReason", "NoFreeFloorCandidate")
		end
		return nil
	end
	local maximum = math.min(#choices, HiderConfig.WANDER_PATH_CANDIDATE_LIMIT)
	for index = 1, maximum do
		local choice = choices[index]
		local route = HiderVisibilityGraph.FindPath(geometry, origin, choice.position)
		if route and #route > 0 then
			return {
				geometry = geometry,
				points = route,
				destination = choice.position,
				sectorId = choice.sectorId,
			}
		end
	end
	if reportFailure then
		controller.npc:SetAttribute("AIStallReason", "NoVisibilityRoute")
	end
	return nil
end

local function startPlannedRoute(controller: Controller, planned: PlannedRoute, now: number): boolean
	controller.geometry = planned.geometry
	controller.route = planned.points
	controller.routeIndex = 1
	local firstWaypoint = controller.route[controller.routeIndex]
	while firstWaypoint
		and planarDistance(controller.rootPart.Position, firstWaypoint)
			<= HiderConfig.WAYPOINT_REACHED_DISTANCE do
		controller.routeIndex += 1
		firstWaypoint = controller.route[controller.routeIndex]
	end
	if controller.routeIndex > #controller.route then
		clearRoute(controller)
		return false
	end
	controller.destination = planned.destination
	controller.destinationSector = planned.sectorId
	controller.sectorVisits[planned.sectorId] = now
	controller.npc:SetAttribute("AITargetSector", planned.sectorId)
	controller.npc:SetAttribute("AITargetPosition", planned.destination)
	controller.npc:SetAttribute("AIPathWaypoints", #planned.points)
	controller.npc:SetAttribute("AIStallReason", "")
	setNavigationStatus(controller, "Moving")
	controller.nextPrefetchRetryAt = 0
	setWaypointApproach(controller)
	return true
end

local function planAndStart(controller: Controller, now: number): boolean
	local planned = planRoute(controller, controller.rootPart.Position, now, true)
	if planned and startPlannedRoute(controller, planned, now) then
		return true
	end
	controller.nextRouteRetryAt = now + HiderConfig.ROUTE_RETRY_SECONDS
	setNavigationStatus(controller, "Searching")
	return false
end

local function activatePendingRoute(controller: Controller, now: number): boolean
	local pending = controller.pendingRoute
	clearPendingRoute(controller)
	return if pending then startPlannedRoute(controller, pending, now) else false
end

local function remainingRouteDistance(controller: Controller): number
	return HiderVisibilityGraph.RouteLength(
		controller.rootPart.Position,
		controller.route,
		controller.routeIndex
	)
end

local function prefetchRoute(controller: Controller, now: number)
	if controller.pendingRoute or not controller.destination or now < controller.nextPrefetchRetryAt then
		return
	end
	if remainingRouteDistance(controller) > HiderConfig.ROUTE_PREFETCH_DISTANCE then
		return
	end
	local planned = planRoute(controller, controller.destination, now, false)
	controller.nextPrefetchRetryAt = now + HiderConfig.PREFETCH_RETRY_SECONDS
	if planned then
		controller.pendingRoute = planned
		controller.npc:SetAttribute("AIPrefetchedRoute", true)
	end
end

local function recoverFromStall(controller: Controller, now: number)
	controller.npc:SetAttribute("AIStallReason", "NoWaypointProgress")
	clearPendingRoute(controller)
	local destination = controller.destination
	local sectorId = controller.destinationSector
	local geometry = HiderMapGeometry.GetForPosition(controller.rootPart.Position)
	if destination and sectorId and geometry then
		local recovered = HiderVisibilityGraph.FindPath(
			geometry,
			controller.rootPart.Position,
			destination
		)
		if recovered and #recovered > 0 then
			startPlannedRoute(controller, {
				geometry = geometry,
				points = recovered,
				destination = destination,
				sectorId = sectorId,
			}, now)
			return
		end
	end
	clearRoute(controller)
	if not planAndStart(controller, now) then
		controller.humanoid:Move(Vector3.zero, false)
	end
end

function HiderBrain.New(npc: Model): Controller?
	local humanoid = npc:FindFirstChildOfClass("Humanoid")
	local rootPart = npc:FindFirstChild("HumanoidRootPart")
	if not humanoid or humanoid.Health <= 0 or not rootPart or not rootPart:IsA("BasePart") then
		return nil
	end
	npc:SetAttribute("AIState", "Idle")
	npc:SetAttribute("AINavigationStatus", "Idle")
	npc:SetAttribute("AIStallReason", "")
	npc:SetAttribute("AIMapName", "")
	npc:SetAttribute("AIWallCount", 0)
	npc:SetAttribute("AIGraphNodes", 0)
	npc:SetAttribute("AIGraphEdges", 0)
	npc:SetAttribute("AIPathWaypoints", 0)
	npc:SetAttribute("AICandidateCount", 0)
	npc:SetAttribute("AIPrefetchedRoute", false)
	npc:SetAttribute("AITargetSector", "")
	npc:SetAttribute("AIDoorPushCount", 0)
	npc:SetAttribute("AILastDoorPart", "")
	return {
		npc = npc,
		humanoid = humanoid,
		rootPart = rootPart,
		random = Random.new(),
		running = true,
		active = false,
		geometry = nil,
		route = {},
		routeIndex = 1,
		destination = nil,
		destinationSector = nil,
		pendingRoute = nil,
		sectorVisits = {},
		nextRouteRetryAt = 0,
		nextPrefetchRetryAt = 0,
		waypointPlaneNormal = Vector3.zero,
		waypointPlaneDistance = 0,
		waypointApproachStart = rootPart.Position,
		bestWaypointDistance = math.huge,
		lastProgressAt = os.clock(),
		lastMoveDirection = Vector3.zero,
		nextDoorPushAt = 0,
	}
end

function HiderBrain.SetActive(controller: Controller, active: boolean)
	if controller.active == active then
		return
	end
	controller.active = active
	clearRoute(controller)
	clearPendingRoute(controller)
	controller.sectorVisits = {}
	controller.nextRouteRetryAt = 0
	controller.nextPrefetchRetryAt = 0
	if active then
		controller.npc:SetAttribute("AIState", "Wander")
		if not planAndStart(controller, os.clock()) then
			controller.humanoid:Move(Vector3.zero, false)
		end
	else
		controller.humanoid:Move(Vector3.zero, false)
		controller.npc:SetAttribute("AIState", "Idle")
		controller.npc:SetAttribute("AITargetSector", "")
		setNavigationStatus(controller, "Idle")
	end
end

function HiderBrain.Step(controller: Controller)
	if not controller.running or not controller.active or not controller.npc.Parent then
		return
	end
	if controller.humanoid.Health <= 0 then
		controller.humanoid:Move(Vector3.zero, false)
		return
	end
	local now = os.clock()
	local waypoint = controller.route[controller.routeIndex]
	if not waypoint then
		if not activatePendingRoute(controller, now) then
			if now < controller.nextRouteRetryAt or not planAndStart(controller, now) then
				controller.humanoid:Move(Vector3.zero, false)
				return
			end
		end
		waypoint = controller.route[controller.routeIndex]
	end

	while waypoint and waypointReached(controller, waypoint) do
		controller.routeIndex += 1
		if controller.routeIndex > #controller.route then
			clearRoute(controller)
			if not activatePendingRoute(controller, now) and not planAndStart(controller, now) then
				controller.humanoid:Move(Vector3.zero, false)
				return
			end
		else
			setWaypointApproach(controller)
		end
		waypoint = controller.route[controller.routeIndex]
	end
	if not waypoint then
		controller.humanoid:Move(Vector3.zero, false)
		return
	end
	local direction = horizontalUnit(waypoint - controller.rootPart.Position)
	if direction then
		controller.lastMoveDirection = direction
		controller.humanoid:Move(direction, false)
	else
		controller.humanoid:Move(Vector3.zero, false)
	end

	local waypointDistance = planarDistance(controller.rootPart.Position, waypoint)
	if waypointDistance <= controller.bestWaypointDistance - HiderConfig.PROGRESS_EPSILON then
		controller.bestWaypointDistance = waypointDistance
		controller.lastProgressAt = now
	else
		local stalledFor = now - controller.lastProgressAt
		if direction
			and stalledFor >= HiderConfig.DOOR_INTERACTION_DELAY
			and now >= controller.nextDoorPushAt then
			controller.nextDoorPushAt = now + HiderConfig.DOOR_PUSH_INTERVAL
			local pushedDoor = NpcDoorInteraction.TryPush(
				controller.npc,
				controller.rootPart,
				direction
			)
			if pushedDoor then
				local pushCount = controller.npc:GetAttribute("AIDoorPushCount")
				controller.npc:SetAttribute(
					"AIDoorPushCount",
					if type(pushCount) == "number" then pushCount + 1 else 1
				)
				controller.npc:SetAttribute("AILastDoorPart", pushedDoor:GetFullName())
			end
		end
		if stalledFor >= HiderConfig.STALL_SECONDS then
			recoverFromStall(controller, now)
			return
		end
	end
	prefetchRoute(controller, now)
end

function HiderBrain.Destroy(controller: Controller)
	controller.running = false
	controller.active = false
	clearRoute(controller)
	clearPendingRoute(controller)
	controller.humanoid:Move(Vector3.zero, false)
end

return HiderBrain
