--!strict

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local ArenaTeleportService = require(script.Parent.Parent:WaitForChild("ArenaTeleportService"))
local BatAttackConfig = require(ReplicatedStorage:WaitForChild("BatAttackConfig"))
local SeekerSearchConfig = require(ReplicatedStorage:WaitForChild("SeekerSearchConfig"))
local HiderConfig = require(script.Parent:WaitForChild("HiderConfig"))
local HiderEvidenceService = require(script.Parent:WaitForChild("HiderEvidenceService"))
local HiderMapGeometry = require(script.Parent:WaitForChild("HiderMapGeometry"))
local HiderThreatAwareness = require(script.Parent:WaitForChild("HiderThreatAwareness"))
local HiderVisibilityGraph = require(script.Parent:WaitForChild("HiderVisibilityGraph"))
local HunterAggroPresentation = require(script.Parent:WaitForChild("HunterAggroPresentation"))
local NpcDoorInteraction = require(script.Parent:WaitForChild("NpcDoorInteraction"))
local RoundConfig = require(script.Parent:WaitForChild("RoundConfig"))

local NPC_FOLDER_NAME = "RoundNPCs"
local TARGET_KIND_SIGHT = "Sight"
local TARGET_KIND_LAST_SEEN = "LastSeen"

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
	reserveDestination: boolean?,
	evidence: HiderEvidenceService.Target?,
}

type DestinationReservation = {
	position: Vector3,
	sectorId: string,
}

export type Controller = {
	npc: Model,
	humanoid: Humanoid,
	rootPart: BasePart,
	turnAttachment: Attachment,
	turnOrientation: AlignOrientation,
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
	doorInteractionStartedAt: number,
	nextThreatCheckAt: number,
	nextFleeReplanAt: number,
	seekerRoots: {BasePart},
	fleeing: boolean,
	fleeSafeSince: number,
	seekerEvidence: HiderEvidenceService.Target?,
	plannedEvidence: HiderEvidenceService.Target?,
	nextEvidenceCheckAt: number,
	nextEvidenceReplanAt: number,
	lastSeenOwner: Model?,
	lastSeenPosition: Vector3?,
	lastSeenUntil: number,
	chaseEndsAt: number,
	aggroReactionEndsAt: number,
	nextAggroAt: number,
	lastTeleportCooldownUntil: number,
}

local HiderBrain = {}
local currentReservations: {[Model]: DestinationReservation} = {}
local pendingReservations: {[Model]: DestinationReservation} = {}
local controllerSerial = 0
local seekerTargetSerial = 0

local TURN_ATTACHMENT_NAME = "NpcSmoothTurnAttachment"
local TURN_ORIENTATION_NAME = "NpcSmoothTurnOrientation"

local function planarDistance(left: Vector3, right: Vector3): number
	return Vector2.new(left.X - right.X, left.Z - right.Z).Magnitude
end

local function horizontalUnit(vector: Vector3): Vector3?
	local horizontal = Vector3.new(vector.X, 0, vector.Z)
	return if horizontal.Magnitude > 0.001 then horizontal.Unit else nil
end

local function updateFacingDirection(controller: Controller, fallbackDirection: Vector3)
	local direction = horizontalUnit(controller.humanoid.MoveDirection) or fallbackDirection
	controller.lastMoveDirection = direction
	controller.turnOrientation.CFrame = CFrame.lookAt(Vector3.zero, direction)
end

local function facePosition(controller: Controller, position: Vector3)
	local direction = horizontalUnit(position - controller.rootPart.Position)
	if not direction then
		return
	end
	controller.lastMoveDirection = direction
	controller.turnOrientation.CFrame = CFrame.lookAt(Vector3.zero, direction)
end

local function setAggroTurnProfile(controller: Controller, aggro: boolean)
	controller.turnOrientation.Responsiveness = if aggro
		then HiderConfig.SEEKER_AGGRO_TURN_RESPONSIVENESS
		else HiderConfig.NPC_TURN_RESPONSIVENESS
	controller.turnOrientation.MaxAngularVelocity = if aggro
		then HiderConfig.SEEKER_AGGRO_TURN_MAX_ANGULAR_VELOCITY
		else HiderConfig.NPC_TURN_MAX_ANGULAR_VELOCITY
end

local function createSmoothTurn(rootPart: BasePart): (Attachment, AlignOrientation)
	local oldAttachment = rootPart:FindFirstChild(TURN_ATTACHMENT_NAME)
	if oldAttachment then
		oldAttachment:Destroy()
	end
	local oldOrientation = rootPart:FindFirstChild(TURN_ORIENTATION_NAME)
	if oldOrientation then
		oldOrientation:Destroy()
	end

	local attachment = Instance.new("Attachment")
	attachment.Name = TURN_ATTACHMENT_NAME
	attachment.Parent = rootPart

	local orientation = Instance.new("AlignOrientation")
	orientation.Name = TURN_ORIENTATION_NAME
	orientation.Mode = Enum.OrientationAlignmentMode.OneAttachment
	orientation.Attachment0 = attachment
	orientation.RigidityEnabled = false
	orientation.Responsiveness = HiderConfig.NPC_TURN_RESPONSIVENESS
	orientation.MaxAngularVelocity = HiderConfig.NPC_TURN_MAX_ANGULAR_VELOCITY
	orientation.MaxTorque = HiderConfig.NPC_TURN_MAX_TORQUE
	orientation.CFrame = CFrame.lookAt(Vector3.zero, horizontalUnit(rootPart.CFrame.LookVector) or Vector3.zAxis)
	orientation.Parent = rootPart
	return attachment, orientation
end

local function getLivingRoot(model: Model): BasePart?
	local humanoid = model:FindFirstChildOfClass("Humanoid")
	local rootPart = model:FindFirstChild("HumanoidRootPart")
	if not model.Parent
		or not humanoid
		or humanoid.Health <= 0
		or not rootPart
		or not rootPart:IsA("BasePart") then
		return nil
	end
	return rootPart
end

local function appendSeekerRoot(
	roots: {BasePart},
	owner: Instance,
	model: Model,
	geometry: HiderMapGeometry.ArenaGeometry
)
	if owner:GetAttribute("RoundRole") ~= HiderConfig.ROLE_SEEKER then
		return
	end
	local rootPart = getLivingRoot(model)
	if not rootPart then
		return
	end
	local seekerGeometry = HiderMapGeometry.GetForPosition(rootPart.Position)
	if seekerGeometry and seekerGeometry.map == geometry.map then
		table.insert(roots, rootPart)
	end
end

local function collectSeekerRoots(
	controller: Controller,
	geometry: HiderMapGeometry.ArenaGeometry
): {BasePart}
	local roots: {BasePart} = {}
	if controller.npc:GetAttribute("RoundRole") ~= HiderConfig.ROLE_HIDER then
		return roots
	end

	for _, player in ipairs(Players:GetPlayers()) do
		local character = player.Character
		if character then
			appendSeekerRoot(roots, player, character, geometry)
		end
	end

	local npcFolder = Workspace:FindFirstChild(NPC_FOLDER_NAME)
	if npcFolder then
		for _, child in ipairs(npcFolder:GetChildren()) do
			if child:IsA("Model") and child ~= controller.npc then
				appendSeekerRoot(roots, child, child, geometry)
			end
		end
	end
	return roots
end

local function getSeekerPositions(roots: {BasePart}): {Vector3}
	local positions: {Vector3} = {}
	for _, rootPart in ipairs(roots) do
		if rootPart.Parent and rootPart:IsDescendantOf(Workspace) then
			table.insert(positions, rootPart.Position)
		end
	end
	return positions
end

local function setFleeing(controller: Controller, fleeing: boolean)
	if controller.fleeing == fleeing then
		return
	end
	controller.fleeing = fleeing
	controller.npc:SetAttribute("AIFleeing", fleeing)
	if controller.active then
		controller.npc:SetAttribute("AIState", if fleeing then "Escape" else "Wander")
	end
	if not fleeing then
		controller.fleeSafeSince = 0
	end
end

local function getSeekerTargetState(target: HiderEvidenceService.Target): string
	return if target.kind == TARGET_KIND_SIGHT
		then "Chase"
		elseif target.kind == TARGET_KIND_LAST_SEEN
		then "SearchLastKnown"
		else "Investigate"
end

local function setSeekerSpeed(controller: Controller)
	if controller.npc:GetAttribute("RoundRole") ~= HiderConfig.ROLE_SEEKER then
		return
	end
	local multiplier = if controller.chaseEndsAt > 0
		then HiderConfig.SEEKER_CHASE_SPEED_MULTIPLIER
		else 1
	local targetSpeed = RoundConfig.SEEKER_WALK_SPEED * multiplier
	if math.abs(controller.humanoid.WalkSpeed - targetSpeed) >= 0.01 then
		controller.humanoid.WalkSpeed = targetSpeed
	end
end

local function setSeekerEvidence(
	controller: Controller,
	evidence: HiderEvidenceService.Target?
)
	controller.seekerEvidence = evidence
	setSeekerSpeed(controller)
	if evidence then
		controller.npc:SetAttribute(
			"AIState",
			if controller.aggroReactionEndsAt > os.clock()
				then "Alert"
				else getSeekerTargetState(evidence)
		)
		controller.npc:SetAttribute("AIEvidenceKind", evidence.kind)
		controller.npc:SetAttribute("AIEvidenceOwner", evidence.owner:GetFullName())
		controller.npc:SetAttribute("AIEvidenceDistance", evidence.distance)
		controller.npc:SetAttribute("AIEvidencePosition", evidence.position)
	else
		controller.npc:SetAttribute("AIEvidenceKind", "")
		controller.npc:SetAttribute("AIEvidenceOwner", "")
		controller.npc:SetAttribute("AIEvidenceDistance", -1)
		controller.npc:SetAttribute("AIEvidencePosition", nil)
		if controller.active
			and controller.npc:GetAttribute("RoundRole") == HiderConfig.ROLE_SEEKER then
			local plannedTarget = controller.plannedEvidence
			controller.npc:SetAttribute(
				"AIState",
				if controller.chaseEndsAt > 0
					then "AggroSearch"
					elseif plannedTarget
						and plannedTarget.kind ~= TARGET_KIND_SIGHT
						and plannedTarget.kind ~= TARGET_KIND_LAST_SEEN
					then getSeekerTargetState(plannedTarget)
					else "Patrol"
			)
		end
	end
end

local function clearLastSeen(controller: Controller)
	controller.lastSeenOwner = nil
	controller.lastSeenPosition = nil
	controller.lastSeenUntil = 0
end

local function startSeekerChase(controller: Controller, targetPosition: Vector3, now: number)
	local chaseDuration = controller.random:NextNumber(
		HiderConfig.SEEKER_CHASE_MIN_SECONDS,
		HiderConfig.SEEKER_CHASE_MAX_SECONDS
	)
	controller.aggroReactionEndsAt = now + HiderConfig.SEEKER_AGGRO_REACTION_SECONDS
	controller.chaseEndsAt = controller.aggroReactionEndsAt + chaseDuration
	controller.npc:SetAttribute("AIAggro", true)
	controller.npc:SetAttribute("AIAggroReactionEndsAt", controller.aggroReactionEndsAt)
	controller.npc:SetAttribute("AIChaseEndsAt", controller.chaseEndsAt)
	setAggroTurnProfile(controller, true)
	facePosition(controller, targetPosition)
	setSeekerSpeed(controller)
	HunterAggroPresentation.Show(controller.npc, controller.rootPart)
end

local function finishSeekerChase(controller: Controller, now: number)
	controller.chaseEndsAt = 0
	controller.aggroReactionEndsAt = 0
	controller.nextAggroAt = now + HiderConfig.SEEKER_REACQUIRE_COOLDOWN_SECONDS
	controller.npc:SetAttribute("AIAggro", false)
	controller.npc:SetAttribute("AIAggroReactionEndsAt", 0)
	controller.npc:SetAttribute("AIChaseEndsAt", 0)
	setAggroTurnProfile(controller, false)
	HunterAggroPresentation.Hide(controller.npc)
	HiderThreatAwareness.ClearSeeker(controller.rootPart)
	clearLastSeen(controller)
	setSeekerEvidence(controller, nil)
end

local function holdSeekerAggroReaction(controller: Controller, now: number): boolean
	if controller.aggroReactionEndsAt <= 0 then
		return false
	end
	if now >= controller.aggroReactionEndsAt then
		controller.aggroReactionEndsAt = 0
		controller.npc:SetAttribute("AIAggroReactionEndsAt", 0)
		setAggroTurnProfile(controller, false)
		local target = controller.seekerEvidence
		controller.npc:SetAttribute(
			"AIState",
			if target then getSeekerTargetState(target) else "AggroSearch"
		)
		return false
	end

	controller.humanoid:Move(Vector3.zero, false)
	local owner = controller.lastSeenOwner
	local targetRoot = if owner then getLivingRoot(owner) else nil
	if targetRoot then
		facePosition(controller, targetRoot.Position)
	elseif controller.lastSeenPosition then
		facePosition(controller, controller.lastSeenPosition)
	end
	controller.npc:SetAttribute("AIState", "Alert")
	return true
end

local function makeSeekerTarget(
	owner: Model,
	kind: string,
	position: Vector3,
	distance: number,
	duration: number
): HiderEvidenceService.Target
	seekerTargetSerial += 1
	local serverNow = Workspace:GetServerTimeNow()
	return {
		owner = owner,
		kind = kind,
		position = position,
		createdAt = serverNow,
		expiresAt = serverNow + duration,
		serial = seekerTargetSerial,
		distance = distance,
	}
end

local function nearestSeekerDistance(position: Vector3, seekerPositions: {Vector3}): number
	local nearest = math.huge
	for _, seekerPosition in ipairs(seekerPositions) do
		nearest = math.min(nearest, planarDistance(position, seekerPosition))
	end
	return nearest
end

local function segmentSeekerClearance(
	segmentStart: Vector3,
	segmentEnd: Vector3,
	seekerPositions: {Vector3}
): number
	local startPoint = Vector2.new(segmentStart.X, segmentStart.Z)
	local endPoint = Vector2.new(segmentEnd.X, segmentEnd.Z)
	local segment = endPoint - startPoint
	local lengthSquared = segment:Dot(segment)
	local clearance = math.huge
	for _, seekerPosition in ipairs(seekerPositions) do
		local seekerPoint = Vector2.new(seekerPosition.X, seekerPosition.Z)
		local closest = startPoint
		if lengthSquared > 0.000001 then
			local alpha = math.clamp((seekerPoint - startPoint):Dot(segment) / lengthSquared, 0, 1)
			closest = startPoint + segment * alpha
		end
		clearance = math.min(clearance, (seekerPoint - closest).Magnitude)
	end
	return clearance
end

local function routeSeekerClearance(
	origin: Vector3,
	route: {Vector3},
	seekerPositions: {Vector3}
): number
	local clearance = nearestSeekerDistance(origin, seekerPositions)
	local previous = origin
	for index = 1, #route do
		local waypoint = route[index]
		clearance = math.min(
			clearance,
			segmentSeekerClearance(previous, waypoint, seekerPositions)
		)
		previous = waypoint
	end
	return clearance
end

local function getFleeScore(
	origin: Vector3,
	candidate: HiderMapGeometry.Destination,
	seekerPositions: {Vector3}
): number
	if #seekerPositions == 0 then
		return 0
	end
	local originDistance = nearestSeekerDistance(origin, seekerPositions)
	local candidateDistance = nearestSeekerDistance(candidate.position, seekerPositions)
	local distanceGain = math.clamp(
		candidateDistance - originDistance,
		-HiderConfig.FLEE_DISTANCE_GAIN_SCORE_CAP,
		HiderConfig.FLEE_DISTANCE_GAIN_SCORE_CAP
	)
	local dangerPenalty = math.max(0, HiderConfig.FLEE_DANGER_DISTANCE - candidateDistance)
		* HiderConfig.FLEE_DANGER_PENALTY_PER_STUD
	return distanceGain * HiderConfig.FLEE_DISTANCE_GAIN_WEIGHT
		+ math.min(candidateDistance, HiderConfig.FLEE_DISTANCE_SCORE_CAP)
			* HiderConfig.FLEE_DISTANCE_WEIGHT
		- dangerPenalty
end

local function getRouteFleeScore(
	origin: Vector3,
	route: {Vector3},
	seekerPositions: {Vector3}
): number
	if #seekerPositions == 0 or #route == 0 then
		return 0
	end
	local originDistance = nearestSeekerDistance(origin, seekerPositions)
	local firstDistance = nearestSeekerDistance(route[1], seekerPositions)
	local firstGain = math.clamp(
		firstDistance - originDistance,
		-HiderConfig.FLEE_ROUTE_FIRST_GAIN_SCORE_CAP,
		HiderConfig.FLEE_ROUTE_FIRST_GAIN_SCORE_CAP
	)
	local clearance = routeSeekerClearance(origin, route, seekerPositions)
	local dangerPenalty = math.max(0, HiderConfig.FLEE_DANGER_DISTANCE - clearance)
		* HiderConfig.FLEE_ROUTE_DANGER_PENALTY_PER_STUD
	return firstGain * HiderConfig.FLEE_ROUTE_FIRST_GAIN_WEIGHT - dangerPenalty
end

local function clearRoute(controller: Controller)
	currentReservations[controller.npc] = nil
	controller.route = {}
	controller.routeIndex = 1
	controller.destination = nil
	controller.destinationSector = nil
	controller.plannedEvidence = nil
	controller.waypointPlaneNormal = Vector3.zero
	controller.waypointPlaneDistance = 0
	controller.bestWaypointDistance = math.huge
	controller.nextDoorPushAt = 0
	controller.doorInteractionStartedAt = 0
	controller.npc:SetAttribute("AITargetSector", "")
	controller.npc:SetAttribute("AITargetPosition", nil)
	if controller.active
		and not controller.seekerEvidence
		and controller.npc:GetAttribute("RoundRole") == HiderConfig.ROLE_SEEKER then
		controller.npc:SetAttribute(
			"AIState",
			if controller.chaseEndsAt > 0 then "AggroSearch" else "Patrol"
		)
	end
end

local function clearPendingRoute(controller: Controller)
	pendingReservations[controller.npc] = nil
	controller.pendingRoute = nil
	controller.npc:SetAttribute("AIPrefetchedRoute", false)
end

local function leaveEscape(controller: Controller): boolean
	if not controller.fleeing then
		return false
	end
	setFleeing(controller, false)
	clearPendingRoute(controller)
	return controller.destination ~= nil
end

local function reservationPenaltyFor(
	candidate: HiderMapGeometry.Destination,
	reservation: DestinationReservation?
): number
	if not reservation then
		return 0
	end
	local penalty = if reservation.sectorId == candidate.sectorId
		then HiderConfig.TARGET_RESERVATION_SECTOR_PENALTY
		else 0
	local distance = planarDistance(candidate.position, reservation.position)
	local proximity = math.max(0, 1 - distance / HiderConfig.TARGET_RESERVATION_RADIUS)
	return penalty + proximity * HiderConfig.TARGET_RESERVATION_PROXIMITY_PENALTY
end

local function getReservationPenalty(
	controller: Controller,
	candidate: HiderMapGeometry.Destination
): number
	local penalty = 0
	for npc, reservation in pairs(currentReservations) do
		if npc ~= controller.npc and npc.Parent then
			penalty += reservationPenaltyFor(candidate, reservation)
		end
	end
	for npc, reservation in pairs(pendingReservations) do
		if npc ~= controller.npc and npc.Parent then
			penalty += reservationPenaltyFor(candidate, reservation)
		end
	end
	return penalty
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
	now: number,
	seekerPositions: {Vector3}
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
	local reservationPenalty = getReservationPenalty(controller, candidate)
	local fleeScore = getFleeScore(origin, candidate, seekerPositions)
	return explorationBonus
		+ math.min(distance, HiderConfig.WANDER_DISTANCE_SCORE_CAP)
		+ turnScore
		+ controller.random:NextNumber(0, HiderConfig.WANDER_SCORE_RANDOMNESS)
		+ fleeScore
		- shortTargetPenalty
		- reservationPenalty
end

local function appendChoice(
	bySector: {[string]: {CandidateChoice}},
	choice: CandidateChoice
)
	local sectorChoices = bySector[choice.sectorId]
	if not sectorChoices then
		sectorChoices = {}
		bySector[choice.sectorId] = sectorChoices
	end
	table.insert(sectorChoices, choice)
	table.sort(sectorChoices, function(left, right)
		return left.score > right.score
	end)
	if #sectorChoices > HiderConfig.WANDER_CANDIDATES_PER_SECTOR then
		table.remove(sectorChoices)
	end
end

local function collectChoices(
	controller: Controller,
	geometry: HiderMapGeometry.ArenaGeometry,
	origin: Vector3,
	now: number,
	seekerPositions: {Vector3}
): {CandidateChoice}
	local bySector: {[string]: {CandidateChoice}} = {}
	for _ = 1, HiderConfig.WANDER_SAMPLE_COUNT do
		local candidate = HiderMapGeometry.SampleDestination(geometry, controller.random)
		if candidate then
			local score = scoreCandidate(controller, origin, candidate, now, seekerPositions)
			if score then
				appendChoice(bySector, {
					position = candidate.position,
					sectorId = candidate.sectorId,
					score = score,
				})
			end
		end
	end
	if controller.npc:GetAttribute("RoundRole") == HiderConfig.ROLE_SEEKER then
		local searchPoints = HiderVisibilityGraph.GetSearchPoints(geometry, origin.Y)
		local sampleCount = math.min(
			#searchPoints,
			HiderConfig.SEEKER_PATROL_NODE_SAMPLE_COUNT
		)
		for _ = 1, sampleCount do
			local index = controller.random:NextInteger(1, #searchPoints)
			local position = table.remove(searchPoints, index)
			if position then
				local candidate: HiderMapGeometry.Destination = {
					position = position,
					sectorId = HiderMapGeometry.GetSectorId(geometry, position),
				}
				local score = scoreCandidate(
					controller,
					origin,
					candidate,
					now,
					seekerPositions
				)
				if score then
					appendChoice(bySector, {
						position = position,
						sectorId = candidate.sectorId,
						score = score + HiderConfig.SEEKER_PATROL_NODE_BONUS,
					})
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

local function getEvidenceGoal(
	geometry: HiderMapGeometry.ArenaGeometry,
	origin: Vector3,
	evidencePosition: Vector3
): Vector3?
	if HiderMapGeometry.PointIsNavigable(
		geometry,
		Vector2.new(evidencePosition.X, evidencePosition.Z)
	) then
		return evidencePosition
	end

	for radius = 1, 4 do
		local best: Vector3? = nil
		local bestApproachDistance = math.huge
		for index = 0, 7 do
			local angle = index * math.pi / 4
			local candidate = evidencePosition
				+ Vector3.new(math.cos(angle) * radius, 0, math.sin(angle) * radius)
			if HiderMapGeometry.PointIsNavigable(
				geometry,
				Vector2.new(candidate.X, candidate.Z)
			) then
				local approachDistance = planarDistance(origin, candidate)
				if approachDistance < bestApproachDistance then
					best = candidate
					bestApproachDistance = approachDistance
				end
			end
		end
		if best then
			return best
		end
	end
	return nil
end

local function findPortalRouteToEvidence(
	geometry: HiderMapGeometry.ArenaGeometry,
	origin: Vector3,
	evidenceGoal: Vector3
): {Vector3}?
	local bestRoute: {Vector3}? = nil
	local bestTotalDistance = math.huge
	for _, link in ipairs(ArenaTeleportService.GetLinks()) do
		local entryGeometry = HiderMapGeometry.GetForPosition(link.Entry.Position)
		local exitGeometry = HiderMapGeometry.GetForPosition(link.Exit.Position)
		if not entryGeometry
			or entryGeometry.map ~= geometry.map
			or not exitGeometry
			or exitGeometry.map ~= geometry.map then
			continue
		end

		local entryGoal = getEvidenceGoal(geometry, origin, link.Entry.Position)
		local exitStart = getEvidenceGoal(geometry, evidenceGoal, link.Exit.Position)
		local routeToEntry = if entryGoal
			then HiderVisibilityGraph.FindPath(geometry, origin, entryGoal)
			else nil
		local routeFromExit = if exitStart
			then HiderVisibilityGraph.FindPath(geometry, exitStart, evidenceGoal)
			else nil
		if not routeToEntry or #routeToEntry == 0 or not routeFromExit then
			continue
		end

		local totalDistance = HiderVisibilityGraph.RouteLength(origin, routeToEntry)
			+ HiderVisibilityGraph.RouteLength(exitStart :: Vector3, routeFromExit)
		if totalDistance < bestTotalDistance then
			bestTotalDistance = totalDistance
			bestRoute = routeToEntry
		end
	end
	return bestRoute
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
	local evidence = controller.seekerEvidence
	if evidence
		and controller.npc:GetAttribute("RoundRole") == HiderConfig.ROLE_SEEKER then
		controller.npc:SetAttribute("AICandidateCount", 1)
		local evidenceGoal = getEvidenceGoal(geometry, origin, evidence.position)
		local evidenceRoute = if evidenceGoal
			then HiderVisibilityGraph.FindPath(geometry, origin, evidenceGoal)
			else nil
		if evidenceGoal and (not evidenceRoute or #evidenceRoute == 0) then
			evidenceRoute = findPortalRouteToEvidence(geometry, origin, evidenceGoal)
		end
		if evidenceRoute and #evidenceRoute > 0 then
			return {
				geometry = geometry,
				points = evidenceRoute,
				destination = evidenceGoal :: Vector3,
				sectorId = `Evidence:{evidence.kind}`,
				reserveDestination = false,
				evidence = evidence,
			}
		end
		if reportFailure then
			controller.npc:SetAttribute("AIStallReason", "NoEvidenceRoute")
		end
		return nil
	end

	local seekerPositions: {Vector3} = {}
	if controller.fleeing then
		controller.seekerRoots = collectSeekerRoots(controller, geometry)
		seekerPositions = getSeekerPositions(controller.seekerRoots)
	end
	local choices = collectChoices(controller, geometry, origin, now, seekerPositions)
	if #choices == 0 then
		if reportFailure then
			controller.npc:SetAttribute("AIStallReason", "NoFreeFloorCandidate")
		end
		return nil
	end
	local maximum = math.min(#choices, HiderConfig.WANDER_PATH_CANDIDATE_LIMIT)
	if #seekerPositions > 0 then
		maximum = math.min(maximum, HiderConfig.FLEE_ROUTE_CANDIDATE_LIMIT)
	end
	local bestFleeRoute: PlannedRoute? = nil
	local bestFleeScore = -math.huge
	for index = 1, maximum do
		local choice = choices[index]
		local route = HiderVisibilityGraph.FindPath(geometry, origin, choice.position)
		if route and #route > 0 then
			local planned = {
				geometry = geometry,
				points = route,
				destination = choice.position,
				sectorId = choice.sectorId,
			}
			if #seekerPositions == 0 then
				return planned
			end
			local fleeScore = choice.score + getRouteFleeScore(origin, route, seekerPositions)
			if fleeScore > bestFleeScore then
				bestFleeScore = fleeScore
				bestFleeRoute = planned
			end
		end
	end
	if bestFleeRoute then
		return bestFleeRoute
	end
	if reportFailure then
		controller.npc:SetAttribute("AIStallReason", "NoVisibilityRoute")
	end
	return nil
end

local function markPatrolDestinationReached(
	controller: Controller,
	evidence: HiderEvidenceService.Target?,
	sectorId: string?,
	now: number
)
	if not evidence and sectorId then
		controller.sectorVisits[sectorId] = now
		local pending = controller.pendingRoute
		if pending and pending.sectorId == sectorId then
			clearPendingRoute(controller)
		end
	end
end

local function completeSeekerTarget(
	controller: Controller,
	target: HiderEvidenceService.Target?
)
	if not target then
		return
	end
	if target.kind ~= TARGET_KIND_LAST_SEEN then
		return
	end
	local selected = controller.seekerEvidence
	if selected
		and selected.kind == TARGET_KIND_LAST_SEEN
		and selected.owner == target.owner then
		local now = os.clock()
		if controller.chaseEndsAt > now then
			-- The Hunter reached the last seen position before the chase timer
			-- expired. Keep the alert and faster search patrol alive so briefly
			-- breaking line of sight does not switch the monster off instantly.
			clearLastSeen(controller)
			setSeekerEvidence(controller, nil)
		else
			finishSeekerChase(controller, now)
		end
	end
end

local function startPlannedRoute(controller: Controller, planned: PlannedRoute, now: number): boolean
	controller.geometry = planned.geometry
	controller.route = planned.points
	controller.routeIndex = 1
	controller.plannedEvidence = planned.evidence
	local firstWaypoint = controller.route[controller.routeIndex]
	while firstWaypoint
		and planarDistance(controller.rootPart.Position, firstWaypoint)
			<= HiderConfig.WAYPOINT_REACHED_DISTANCE do
		controller.routeIndex += 1
		firstWaypoint = controller.route[controller.routeIndex]
	end
	if controller.routeIndex > #controller.route then
		markPatrolDestinationReached(
			controller,
			controller.plannedEvidence,
			planned.sectorId,
			now
		)
		completeSeekerTarget(controller, controller.plannedEvidence)
		clearRoute(controller)
		return false
	end
	controller.destination = planned.destination
	controller.destinationSector = planned.sectorId
	if planned.reserveDestination == false then
		currentReservations[controller.npc] = nil
	else
		currentReservations[controller.npc] = {
			position = planned.destination,
			sectorId = planned.sectorId,
		}
	end
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
	-- The tracked position can already be under the Seeker. Refresh once so a
	-- still-active signal can immediately produce a route to the owner's new spot.
	for _ = 1, 2 do
		local planned = planRoute(controller, controller.rootPart.Position, now, true)
		if not planned then
			break
		end
		if startPlannedRoute(controller, planned, now) then
			return true
		end
		if not controller.seekerEvidence then
			break
		end
	end
	local retrySeconds = if controller.seekerEvidence
		then HiderConfig.SEEKER_EVIDENCE_REPLAN_INTERVAL
		else HiderConfig.ROUTE_RETRY_SECONDS
	controller.nextRouteRetryAt = now + retrySeconds
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
	if controller.seekerEvidence
		or controller.plannedEvidence
		or controller.pendingRoute
		or not controller.destination
		or now < controller.nextPrefetchRetryAt then
		return
	end
	if remainingRouteDistance(controller) > HiderConfig.ROUTE_PREFETCH_DISTANCE then
		return
	end
	local planned = planRoute(controller, controller.destination, now, false)
	controller.nextPrefetchRetryAt = now + HiderConfig.PREFETCH_RETRY_SECONDS
	if planned then
		controller.pendingRoute = planned
		pendingReservations[controller.npc] = {
			position = planned.destination,
			sectorId = planned.sectorId,
		}
		controller.npc:SetAttribute("AIPrefetchedRoute", true)
	end
end

local function recoverFromStall(controller: Controller, now: number)
	controller.npc:SetAttribute("AIStallReason", "NoWaypointProgress")
	clearPendingRoute(controller)
	local destination = controller.destination
	local sectorId = controller.destinationSector
	local evidence = controller.plannedEvidence
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
				reserveDestination = evidence == nil,
				evidence = evidence,
			}, now)
			return
		end
	end
	clearRoute(controller)
	if not planAndStart(controller, now) then
		controller.humanoid:Move(Vector3.zero, false)
	end
end

local function shouldReplanForSeeker(controller: Controller, now: number): boolean
	if controller.npc:GetAttribute("RoundRole") ~= HiderConfig.ROLE_HIDER
		or now < controller.nextThreatCheckAt then
		return false
	end
	controller.nextThreatCheckAt = now + HiderConfig.FLEE_THREAT_CHECK_INTERVAL

	local geometry = HiderMapGeometry.GetForPosition(controller.rootPart.Position)
	if not geometry then
		controller.seekerRoots = {}
		controller.npc:SetAttribute("AINearestSeekerDistance", -1)
		controller.npc:SetAttribute("AISeekerCount", 0)
		controller.npc:SetAttribute("AIVisibleSeekerCount", 0)
		return leaveEscape(controller)
	end
	controller.seekerRoots = collectSeekerRoots(controller, geometry)
	local seekerPositions = getSeekerPositions(controller.seekerRoots)
	controller.npc:SetAttribute("AISeekerCount", #seekerPositions)
	if #seekerPositions == 0 then
		controller.npc:SetAttribute("AINearestSeekerDistance", -1)
		controller.npc:SetAttribute("AIVisibleSeekerCount", 0)
		return leaveEscape(controller)
	end

	local currentDistance = nearestSeekerDistance(controller.rootPart.Position, seekerPositions)
	controller.npc:SetAttribute("AINearestSeekerDistance", currentDistance)
	local threatPositions = HiderThreatAwareness.GetVisibleThreatPositions(
		controller.humanoid,
		controller.rootPart,
		geometry,
		controller.seekerRoots,
		HiderConfig.FLEE_TRIGGER_DISTANCE
	)
	controller.npc:SetAttribute("AIVisibleSeekerCount", #threatPositions)
	if #threatPositions == 0 then
		if controller.fleeing then
			if controller.fleeSafeSince <= 0 then
				controller.fleeSafeSince = now
			elseif now - controller.fleeSafeSince >= HiderConfig.FLEE_RELEASE_DELAY then
				return leaveEscape(controller)
			end
		end
		return false
	end

	local enteredEscape = not controller.fleeing
	setFleeing(controller, true)
	controller.fleeSafeSince = 0
	if enteredEscape then
		controller.nextFleeReplanAt = now + HiderConfig.FLEE_ROUTE_REPLAN_INTERVAL
		return controller.destination ~= nil
	end
	if now < controller.nextFleeReplanAt then
		return false
	end
	local currentThreatDistance = nearestSeekerDistance(
		controller.rootPart.Position,
		threatPositions
	)

	local destination = controller.destination
	if not destination then
		-- Initial planning is already staggered by nextRouteRetryAt. Do not make
		-- every nearby Hider bypass that delay and run A* in the same frame.
		return false
	end
	local destinationDistance = nearestSeekerDistance(destination, threatPositions)
	local routeApproachesSeeker = false
	local waypoint = controller.route[controller.routeIndex]
	if waypoint then
		local immediateClearance = segmentSeekerClearance(
			controller.rootPart.Position,
			waypoint,
			threatPositions
		)
		routeApproachesSeeker = immediateClearance
			< currentThreatDistance - HiderConfig.FLEE_ROUTE_APPROACH_TOLERANCE
	end
	if destinationDistance
		>= currentThreatDistance + HiderConfig.FLEE_DESTINATION_MIN_DISTANCE_GAIN
		and not routeApproachesSeeker then
		return false
	end
	controller.nextFleeReplanAt = now + HiderConfig.FLEE_ROUTE_REPLAN_INTERVAL
	return true
end

local function rememberedHiderIsValid(controller: Controller): boolean
	local owner = controller.lastSeenOwner
	if not owner then
		return false
	end
	local player = Players:GetPlayerFromCharacter(owner)
	if not player
		or player.Character ~= owner
		or player:GetAttribute("RoundRole") ~= HiderConfig.ROLE_HIDER then
		return false
	end
	return getLivingRoot(owner) ~= nil
end

local function selectSeekerTarget(
	controller: Controller,
	geometry: HiderMapGeometry.ArenaGeometry,
	now: number
): HiderEvidenceService.Target?
	if controller.chaseEndsAt > 0 and now >= controller.chaseEndsAt then
		finishSeekerChase(controller, now)
	end
	local currentTarget = controller.seekerEvidence
	local preferredCharacter = if currentTarget then currentTarget.owner else nil
	local visible = if controller.chaseEndsAt > 0 or now >= controller.nextAggroAt
		then HiderThreatAwareness.GetBestVisibleHumanHider(
			controller.humanoid,
			controller.rootPart,
			geometry,
			SeekerSearchConfig.VISION_DISTANCE,
			preferredCharacter,
			HiderConfig.SEEKER_TARGET_SWITCH_ADVANTAGE
		)
		else nil
	if visible then
		if controller.chaseEndsAt <= 0 then
			startSeekerChase(controller, visible.position, now)
		end
		if visible.currentlyVisible then
			controller.lastSeenOwner = visible.character
			controller.lastSeenPosition = visible.position
			controller.lastSeenUntil = controller.chaseEndsAt
		end
		return makeSeekerTarget(
			visible.character,
			TARGET_KIND_SIGHT,
			visible.position,
			visible.distance,
			HiderConfig.SEEKER_EVIDENCE_CHECK_INTERVAL * 2
		)
	end

	local owner = controller.lastSeenOwner
	local position = controller.lastSeenPosition
	if owner and not rememberedHiderIsValid(controller) then
		finishSeekerChase(controller, now)
		return nil
	end
	if owner
		and position
		and now < controller.lastSeenUntil
		then
		if HiderMapGeometry.ContainsPosition(geometry, position) then
			return makeSeekerTarget(
				owner,
				TARGET_KIND_LAST_SEEN,
				position,
				planarDistance(controller.rootPart.Position, position),
				controller.lastSeenUntil - now
			)
		end
	end
	clearLastSeen(controller)
	local evidence = HiderEvidenceService.GetClosest(
		controller.rootPart.Position,
		geometry,
		Workspace:GetServerTimeNow(),
		if currentTarget
			and currentTarget.kind ~= TARGET_KIND_SIGHT
			and currentTarget.kind ~= TARGET_KIND_LAST_SEEN
			then currentTarget.owner
			else nil
	)
	if evidence then
		return evidence
	end
	return nil
end

local function shouldReplanForSeekerTarget(controller: Controller, now: number): boolean
	local role = controller.npc:GetAttribute("RoundRole")
	if role ~= HiderConfig.ROLE_SEEKER then
		local previousState = controller.npc:GetAttribute("AIState")
		local hadAggro = controller.chaseEndsAt > 0
			or controller.aggroReactionEndsAt > 0
			or controller.npc:GetAttribute("AIAggro") == true
		if hadAggro then
			finishSeekerChase(controller, now)
		elseif controller.seekerEvidence then
			setSeekerEvidence(controller, nil)
		end
		clearLastSeen(controller)
		controller.chaseEndsAt = 0
		controller.aggroReactionEndsAt = 0
		controller.nextAggroAt = 0
		if role == HiderConfig.ROLE_HIDER
			and previousState ~= "Wander"
			and previousState ~= "Escape" then
			controller.humanoid.WalkSpeed = RoundConfig.WALK_SPEED
			controller.npc:SetAttribute("AIState", "Wander")
		end
		return false
	end
	if now < controller.nextEvidenceCheckAt then
		return false
	end
	controller.nextEvidenceCheckAt = now + HiderConfig.SEEKER_EVIDENCE_CHECK_INTERVAL

	local geometry = HiderMapGeometry.GetForPosition(controller.rootPart.Position)
	if not geometry then
		local wasTrackingTarget = controller.seekerEvidence ~= nil
			or controller.plannedEvidence ~= nil
		local hadAggro = controller.chaseEndsAt > 0 or controller.aggroReactionEndsAt > 0
		if hadAggro then
			finishSeekerChase(controller, now)
		elseif wasTrackingTarget then
			setSeekerEvidence(controller, nil)
		end
		if wasTrackingTarget or hadAggro then
			clearPendingRoute(controller)
		end
		clearLastSeen(controller)
		return wasTrackingTarget or hadAggro
	end
	local target = selectSeekerTarget(controller, geometry, now)
	if not target then
		local wasTrackingTarget = controller.seekerEvidence ~= nil
			or controller.plannedEvidence ~= nil
		if wasTrackingTarget then
			setSeekerEvidence(controller, nil)
			clearPendingRoute(controller)
		end
		return wasTrackingTarget
	end

	local previous = controller.seekerEvidence
	setSeekerEvidence(controller, target)
	if not previous then
		controller.nextEvidenceReplanAt = now + HiderConfig.SEEKER_EVIDENCE_REPLAN_INTERVAL
		return true
	end

	local plannedTarget = controller.plannedEvidence
	if not plannedTarget then
		controller.nextEvidenceReplanAt = now + HiderConfig.SEEKER_EVIDENCE_REPLAN_INTERVAL
		return true
	end
	local ownerChanged = plannedTarget.owner ~= target.owner
	if ownerChanged and target.kind == TARGET_KIND_SIGHT then
		controller.nextEvidenceReplanAt = now + HiderConfig.SEEKER_EVIDENCE_REPLAN_INTERVAL
		return true
	end
	if now < controller.nextEvidenceReplanAt then
		return false
	end
	if ownerChanged
		or plannedTarget.kind ~= target.kind
		or planarDistance(plannedTarget.position, target.position)
			>= HiderConfig.SEEKER_EVIDENCE_REPLAN_DISTANCE then
		controller.nextEvidenceReplanAt = now + HiderConfig.SEEKER_EVIDENCE_REPLAN_INTERVAL
		return true
	end
	return false
end

function HiderBrain.New(npc: Model): Controller?
	local humanoid = npc:FindFirstChildOfClass("Humanoid")
	local rootPart = npc:FindFirstChild("HumanoidRootPart")
	if not humanoid or humanoid.Health <= 0 or not rootPart or not rootPart:IsA("BasePart") then
		return nil
	end
	controllerSerial += 1
	local turnAttachment, turnOrientation = createSmoothTurn(rootPart)
	humanoid.AutoRotate = false
	local navigationSeed = math.floor(os.clock() * 1000000 + controllerSerial * 104729)
		% 2147483647
	navigationSeed = math.max(1, navigationSeed)
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
	npc:SetAttribute("AINavigationSeed", navigationSeed)
	npc:SetAttribute("AIFleeing", false)
	npc:SetAttribute("AINearestSeekerDistance", -1)
	npc:SetAttribute("AISeekerCount", 0)
	npc:SetAttribute("AIVisibleSeekerCount", 0)
	npc:SetAttribute("AIEvidenceKind", "")
	npc:SetAttribute("AIEvidenceOwner", "")
	npc:SetAttribute("AIEvidenceDistance", -1)
	npc:SetAttribute("AIEvidencePosition", nil)
	npc:SetAttribute("AIAggro", false)
	npc:SetAttribute("AIAggroReactionEndsAt", 0)
	npc:SetAttribute("AIChaseEndsAt", 0)
	return {
		npc = npc,
		humanoid = humanoid,
		rootPart = rootPart,
		turnAttachment = turnAttachment,
		turnOrientation = turnOrientation,
		random = Random.new(navigationSeed),
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
		doorInteractionStartedAt = 0,
		nextThreatCheckAt = 0,
		nextFleeReplanAt = 0,
		seekerRoots = {},
		fleeing = false,
		fleeSafeSince = 0,
		seekerEvidence = nil,
		plannedEvidence = nil,
		nextEvidenceCheckAt = 0,
		nextEvidenceReplanAt = 0,
		lastSeenOwner = nil,
		lastSeenPosition = nil,
		lastSeenUntil = 0,
		chaseEndsAt = 0,
		aggroReactionEndsAt = 0,
		nextAggroAt = 0,
		lastTeleportCooldownUntil = 0,
	}
end

function HiderBrain.SetActive(controller: Controller, active: boolean)
	if controller.active == active then
		return
	end
	controller.active = active
	controller.humanoid.AutoRotate = false
	clearRoute(controller)
	clearPendingRoute(controller)
	controller.sectorVisits = {}
	controller.nextRouteRetryAt = 0
	controller.nextPrefetchRetryAt = 0
	controller.nextThreatCheckAt = 0
	controller.nextFleeReplanAt = 0
	controller.seekerRoots = {}
	controller.fleeing = false
	controller.fleeSafeSince = 0
	controller.seekerEvidence = nil
	controller.plannedEvidence = nil
	controller.nextEvidenceCheckAt = 0
	controller.nextEvidenceReplanAt = 0
	controller.chaseEndsAt = 0
	controller.aggroReactionEndsAt = 0
	controller.nextAggroAt = 0
	clearLastSeen(controller)
	HiderThreatAwareness.ClearSeeker(controller.rootPart)
	setAggroTurnProfile(controller, false)
	HunterAggroPresentation.Hide(controller.npc)
	controller.npc:SetAttribute("AIFleeing", false)
	controller.npc:SetAttribute("AINearestSeekerDistance", -1)
	controller.npc:SetAttribute("AISeekerCount", 0)
	controller.npc:SetAttribute("AIVisibleSeekerCount", 0)
	controller.npc:SetAttribute("AIEvidenceKind", "")
	controller.npc:SetAttribute("AIEvidenceOwner", "")
	controller.npc:SetAttribute("AIEvidenceDistance", -1)
	controller.npc:SetAttribute("AIEvidencePosition", nil)
	controller.npc:SetAttribute("AIAggro", false)
	controller.npc:SetAttribute("AIAggroReactionEndsAt", 0)
	controller.npc:SetAttribute("AIChaseEndsAt", 0)
	if controller.npc:GetAttribute(SeekerSearchConfig.CAGED_ATTRIBUTE) ~= true then
		setSeekerSpeed(controller)
	end
	if active then
		setSeekerSpeed(controller)
		controller.npc:SetAttribute(
			"AIState",
			if controller.npc:GetAttribute("RoundRole") == HiderConfig.ROLE_SEEKER
				then "Patrol"
				else "Wander"
		)
		controller.nextRouteRetryAt = os.clock()
			+ controller.random:NextNumber(0, HiderConfig.START_STAGGER_MAX_SECONDS)
		setNavigationStatus(controller, "Searching")
		controller.humanoid:Move(Vector3.zero, false)
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
		if controller.chaseEndsAt > 0
			or controller.aggroReactionEndsAt > 0
			or controller.npc:GetAttribute("AIAggro") == true then
			finishSeekerChase(controller, os.clock())
		end
		controller.humanoid:Move(Vector3.zero, false)
		return
	end
	if controller.npc:GetAttribute(BatAttackConfig.KNOCKDOWN_ATTRIBUTE) == true
		or controller.humanoid.PlatformStand then
		controller.humanoid:Move(Vector3.zero, false)
		return
	end
	-- Cage/knockdown systems restore the speed they observed before disabling an
	-- NPC. Reassert the current patrol/chase profile after those states end.
	setSeekerSpeed(controller)
	local now = os.clock()
	local teleportCooldown = controller.npc:GetAttribute(ArenaTeleportService.COOLDOWN_ATTRIBUTE)
	local teleportCooldownUntil = if type(teleportCooldown) == "number" then teleportCooldown else 0
	if teleportCooldownUntil > controller.lastTeleportCooldownUntil then
		controller.lastTeleportCooldownUntil = teleportCooldownUntil
		clearPendingRoute(controller)
		clearRoute(controller)
		if not planAndStart(controller, now) then
			controller.humanoid:Move(Vector3.zero, false)
			return
		end
	end
	local seekerTargetChanged = shouldReplanForSeekerTarget(controller, now)
	local hiderThreatChanged = shouldReplanForSeeker(controller, now)
	if seekerTargetChanged or hiderThreatChanged then
		clearPendingRoute(controller)
		clearRoute(controller)
		if holdSeekerAggroReaction(controller, now) then
			return
		end
		if not planAndStart(controller, now) then
			controller.humanoid:Move(Vector3.zero, false)
			return
		end
	end
	if holdSeekerAggroReaction(controller, now) then
		return
	end
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
			markPatrolDestinationReached(
				controller,
				controller.plannedEvidence,
				controller.destinationSector,
				now
			)
			completeSeekerTarget(controller, controller.plannedEvidence)
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
		controller.humanoid:Move(direction, false)
		updateFacingDirection(controller, direction)
	else
		controller.humanoid:Move(Vector3.zero, false)
	end

	local waypointDistance = planarDistance(controller.rootPart.Position, waypoint)
	if waypointDistance <= controller.bestWaypointDistance - HiderConfig.PROGRESS_EPSILON then
		controller.bestWaypointDistance = waypointDistance
		controller.lastProgressAt = now
		controller.doorInteractionStartedAt = 0
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
				if controller.doorInteractionStartedAt <= 0 then
					controller.doorInteractionStartedAt = now
				end
				if now - controller.doorInteractionStartedAt
					<= HiderConfig.DOOR_INTERACTION_MAX_SECONDS then
					-- Do not replace the route while a real moving leaf is being
					-- pushed. A permanently jammed door still falls through to the
					-- regular stall recovery after this bounded grace period.
					controller.lastProgressAt = now
					stalledFor = 0
				end
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
	controller.npc:SetAttribute("AIFleeing", false)
	controller.npc:SetAttribute("AINearestSeekerDistance", -1)
	controller.npc:SetAttribute("AISeekerCount", 0)
	controller.npc:SetAttribute("AIVisibleSeekerCount", 0)
	controller.npc:SetAttribute("AIEvidenceKind", "")
	controller.npc:SetAttribute("AIEvidenceOwner", "")
	controller.npc:SetAttribute("AIEvidenceDistance", -1)
	controller.npc:SetAttribute("AIEvidencePosition", nil)
	controller.seekerRoots = {}
	controller.fleeing = false
	controller.fleeSafeSince = 0
	controller.seekerEvidence = nil
	controller.plannedEvidence = nil
	controller.chaseEndsAt = 0
	controller.aggroReactionEndsAt = 0
	controller.nextAggroAt = 0
	clearLastSeen(controller)
	HiderThreatAwareness.ClearSeeker(controller.rootPart)
	controller.npc:SetAttribute("AIAggro", false)
	controller.npc:SetAttribute("AIAggroReactionEndsAt", 0)
	controller.npc:SetAttribute("AIChaseEndsAt", 0)
	HunterAggroPresentation.Destroy(controller.npc)
	controller.turnOrientation:Destroy()
	controller.turnAttachment:Destroy()
	controller.humanoid.AutoRotate = true
	controller.humanoid:Move(Vector3.zero, false)
end

return HiderBrain
