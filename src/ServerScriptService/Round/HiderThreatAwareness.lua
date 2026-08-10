--!strict

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local SearchConfig = require(ReplicatedStorage:WaitForChild("SeekerSearchConfig"))
local SearchGeometry = require(ReplicatedStorage:WaitForChild("SeekerSearchGeometry"))
local HiderMapGeometry = require(script.Parent:WaitForChild("HiderMapGeometry"))

local NPC_FOLDER_NAME = "RoundNPCs"
local ROLE_ATTRIBUTE = "RoundRole"
local ROLE_HIDER = "Hider"
local WALLS_CONTAINER_NAME = "Walls"
local LINE_OF_SIGHT_PARAMETERS_CACHE_SECONDS = 0.2

type WallParametersRecord = {
	revision: number,
	parameters: RaycastParams?,
}

type SightRecord = {
	exposureStartedAt: number?,
	detected: boolean,
	lastVisibleAt: number,
	lastHiderPosition: Vector3,
	lastSeekerPosition: Vector3,
}

local HiderThreatAwareness = {}
local wallParametersByMap: {[Instance]: WallParametersRecord} = {}
local cachedLineOfSightParameters: RaycastParams? = nil
local lineOfSightParametersExpireAt = 0
local sightRecordsBySeeker: {[BasePart]: {[BasePart]: SightRecord}} = setmetatable(
	{},
	{ __mode = "k" }
) :: any

function HiderThreatAwareness.ClearSeeker(seekerRoot: BasePart)
	sightRecordsBySeeker[seekerRoot] = nil
end

local function planarDistance(left: Vector3, right: Vector3): number
	return Vector2.new(left.X - right.X, left.Z - right.Z).Magnitude
end

local function getLivingHumanoid(rootPart: BasePart): Humanoid?
	local model = rootPart:FindFirstAncestorOfClass("Model")
	if not model or not model.Parent then
		return nil
	end
	local humanoid = model:FindFirstChildOfClass("Humanoid")
	return if humanoid and humanoid.Health > 0 then humanoid else nil
end

local function alreadyDetected(seekerRoot: BasePart, hiderRoot: BasePart): boolean
	local records = sightRecordsBySeeker[seekerRoot]
	local record = if records then records[hiderRoot] else nil
	return record ~= nil and record.detected
end

local function updateSightRecord(
	seekerRoot: BasePart,
	hiderRoot: BasePart,
	rawVisible: boolean,
	now: number
): (boolean, boolean, Vector3, Vector3)
	local records = sightRecordsBySeeker[seekerRoot]
	if not records then
		records = setmetatable({}, { __mode = "k" }) :: any
		sightRecordsBySeeker[seekerRoot] = records
	end

	local record = records[hiderRoot]
	if not record then
		record = {
			exposureStartedAt = nil,
			detected = false,
			lastVisibleAt = -math.huge,
			lastHiderPosition = hiderRoot.Position,
			lastSeekerPosition = seekerRoot.Position,
		}
		records[hiderRoot] = record
	end

	if rawVisible then
		local exposureStartedAt = record.exposureStartedAt or now
		record.exposureStartedAt = exposureStartedAt
		if record.detected or now - exposureStartedAt >= SearchConfig.VISION_DETECTION_SECONDS then
			record.detected = true
			record.lastVisibleAt = now
			record.lastHiderPosition = hiderRoot.Position
			record.lastSeekerPosition = seekerRoot.Position
			return true, true, record.lastHiderPosition, record.lastSeekerPosition
		end
		return false, true, hiderRoot.Position, seekerRoot.Position
	end

	record.exposureStartedAt = nil
	if record.detected
		and now - record.lastVisibleAt <= SearchConfig.VISION_LOST_GRACE_SECONDS then
		return true, false, record.lastHiderPosition, record.lastSeekerPosition
	end
	record.detected = false
	return false, false, record.lastHiderPosition, record.lastSeekerPosition
end

local function getLineOfSightParameters(): RaycastParams
	local now = os.clock()
	if cachedLineOfSightParameters and now < lineOfSightParametersExpireAt then
		return cachedLineOfSightParameters
	end

	local excluded: {Instance} = {}
	local npcFolder = Workspace:FindFirstChild(NPC_FOLDER_NAME)
	if npcFolder then
		table.insert(excluded, npcFolder)
	end
	for _, player in ipairs(Players:GetPlayers()) do
		if player.Character then
			table.insert(excluded, player.Character)
		end
	end

	local parameters = RaycastParams.new()
	parameters.FilterType = Enum.RaycastFilterType.Exclude
	parameters.FilterDescendantsInstances = excluded
	parameters.IgnoreWater = true
	parameters.RespectCanCollide = true
	parameters.CollisionGroup = SearchConfig.RAYCAST_COLLISION_GROUP
	cachedLineOfSightParameters = parameters
	lineOfSightParametersExpireAt = now + LINE_OF_SIGHT_PARAMETERS_CACHE_SECONDS
	return parameters
end

local function getWallLineOfSightParameters(
	geometry: HiderMapGeometry.ArenaGeometry
): RaycastParams?
	local cached = wallParametersByMap[geometry.map]
	if cached and cached.revision == geometry.revision then
		return cached.parameters
	end

	local wallParts: {Instance} = {}
	local wallsContainer = geometry.map:FindFirstChild(WALLS_CONTAINER_NAME)
	if wallsContainer then
		if wallsContainer:IsA("BasePart") then
			table.insert(wallParts, wallsContainer)
		end
		for _, descendant in ipairs(wallsContainer:GetDescendants()) do
			if descendant:IsA("BasePart") then
				table.insert(wallParts, descendant)
			end
		end
	end

	local parameters: RaycastParams? = nil
	if #wallParts > 0 then
		local activeParameters = RaycastParams.new()
		activeParameters.FilterType = Enum.RaycastFilterType.Include
		activeParameters.FilterDescendantsInstances = wallParts
		activeParameters.IgnoreWater = true
		activeParameters.RespectCanCollide = false
		activeParameters.CollisionGroup = SearchConfig.RAYCAST_COLLISION_GROUP
		parameters = activeParameters
	end
	wallParametersByMap[geometry.map] = {
		revision = geometry.revision,
		parameters = parameters,
	}
	return parameters
end

local function lineOfSightHeight(rootPart: BasePart, humanoid: Humanoid): Vector3
	local floorY = rootPart.Position.Y
		- math.max(0, humanoid.HipHeight)
		- rootPart.Size.Y * 0.5
	return Vector3.new(
		rootPart.Position.X,
		floorY + SearchConfig.LINE_OF_SIGHT_HEIGHT,
		rootPart.Position.Z
	)
end

local function hasLineOfSight(
	seekerRoot: BasePart,
	seekerHumanoid: Humanoid,
	hiderRoot: BasePart,
	hiderHumanoid: Humanoid,
	parameters: RaycastParams,
	wallParameters: RaycastParams?
): boolean
	local origin = lineOfSightHeight(seekerRoot, seekerHumanoid)
	local destination = lineOfSightHeight(hiderRoot, hiderHumanoid)
	local direction = destination - origin
	if direction.Magnitude <= 0.05 then
		return true
	end
	if Workspace:Raycast(origin, direction, parameters) then
		return false
	end
	return not wallParameters or Workspace:Raycast(origin, direction, wallParameters) == nil
end

export type VisibleHider = {
	player: Player,
	character: Model,
	humanoid: Humanoid,
	rootPart: BasePart,
	position: Vector3,
	distance: number,
	currentlyVisible: boolean,
}

function HiderThreatAwareness.GetBestVisibleHumanHider(
	seekerHumanoid: Humanoid,
	seekerRoot: BasePart,
	geometry: HiderMapGeometry.ArenaGeometry,
	maxDistance: number,
	preferredCharacter: Model?,
	switchAdvantage: number?
): VisibleHider?
	local closest: VisibleHider? = nil
	local preferred: VisibleHider? = nil
	local parameters: RaycastParams? = nil
	local wallParameters: RaycastParams? = nil
	local now = os.clock()
	for _, player in ipairs(Players:GetPlayers()) do
		-- A cage immobilizes a Hider; it must not make that Hider invisible to the
		-- Hunter. This is what makes placing a cage near the monster dangerous.
		if player:GetAttribute(ROLE_ATTRIBUTE) ~= ROLE_HIDER then
			continue
		end
		local character = player.Character
		if not character then
			continue
		end
		local hiderHumanoid = character:FindFirstChildOfClass("Humanoid")
		local hiderRoot = character:FindFirstChild("HumanoidRootPart")
		if not hiderHumanoid
			or hiderHumanoid.Health <= 0
			or not hiderRoot
			or not hiderRoot:IsA("BasePart") then
			continue
		end
		if not HiderMapGeometry.ContainsPosition(geometry, hiderRoot.Position) then
			continue
		end

		local seekerPosition = seekerRoot.Position
		local hiderPosition = hiderRoot.Position
		local direction = hiderPosition - seekerPosition
		local distance = planarDistance(seekerPosition, hiderPosition)
		local tracked = alreadyDetected(seekerRoot, hiderRoot)
		local allowedDistance = if tracked
			then maxDistance + (SearchConfig.VISION_TRACK_DISTANCE - SearchConfig.VISION_DISTANCE)
			else maxDistance
		local allowedFov = if tracked
			then SearchConfig.VISION_TRACK_FOV_DEGREES
			else SearchConfig.VISION_FOV_DEGREES
		local insideVision = SearchGeometry.IsInsideVisionFov(
			seekerRoot.CFrame.LookVector,
			direction,
			allowedFov
		) or distance <= SearchConfig.VISION_CLOSE_ALERT_DISTANCE
		local rawVisible = math.abs(seekerPosition.Y - hiderPosition.Y)
			<= SearchConfig.MAX_VERTICAL_DIFFERENCE
			and distance <= allowedDistance
			and insideVision
		if rawVisible then
			local activeParameters = parameters
			if not activeParameters then
				activeParameters = getLineOfSightParameters()
				parameters = activeParameters
				wallParameters = getWallLineOfSightParameters(geometry)
			end
			rawVisible = hasLineOfSight(
				seekerRoot,
				seekerHumanoid,
				hiderRoot,
				hiderHumanoid,
				activeParameters,
				wallParameters
			)
		end
		local detected, currentlyVisible, seenPosition = updateSightRecord(
			seekerRoot,
			hiderRoot,
			rawVisible,
			now
		)
		if detected then
			local seenDistance = planarDistance(seekerPosition, seenPosition)
			local visibleHider: VisibleHider = {
				player = player,
				character = character,
				humanoid = hiderHumanoid,
				rootPart = hiderRoot,
				position = seenPosition,
				distance = seenDistance,
				currentlyVisible = currentlyVisible,
			}
			if not closest or seenDistance < closest.distance then
				closest = visibleHider
			end
			if character == preferredCharacter then
				preferred = visibleHider
			end
		end
	end
	if preferred
		and closest
		and preferred.character ~= closest.character
		and preferred.distance <= closest.distance + (switchAdvantage or 0) then
		return preferred
	end
	return closest
end

function HiderThreatAwareness.GetVisibleThreatPositions(
	hiderHumanoid: Humanoid,
	hiderRoot: BasePart,
	geometry: HiderMapGeometry.ArenaGeometry,
	seekerRoots: {BasePart},
	alertDistance: number
): {Vector3}
	local threats: {Vector3} = {}
	local parameters: RaycastParams? = nil
	local wallParameters: RaycastParams? = nil
	local now = os.clock()
	for _, seekerRoot in ipairs(seekerRoots) do
		local seekerHumanoid = if seekerRoot.Parent then getLivingHumanoid(seekerRoot) else nil
		if not seekerHumanoid then
			continue
		end
		local seekerPosition = seekerRoot.Position
		local hiderPosition = hiderRoot.Position
		local direction = hiderPosition - seekerPosition
		local distance = planarDistance(seekerPosition, hiderPosition)
		local tracked = alreadyDetected(seekerRoot, hiderRoot)
		local allowedDistance = if tracked
			then alertDistance + (SearchConfig.VISION_TRACK_DISTANCE - SearchConfig.VISION_DISTANCE)
			else alertDistance
		local allowedFov = if tracked
			then SearchConfig.VISION_TRACK_FOV_DEGREES
			else SearchConfig.VISION_FOV_DEGREES
		local rawVisible = math.abs(seekerPosition.Y - hiderPosition.Y)
			<= SearchConfig.MAX_VERTICAL_DIFFERENCE
			and distance <= allowedDistance
			and SearchGeometry.IsInsideVisionFov(seekerRoot.CFrame.LookVector, direction, allowedFov)
		if rawVisible then
			local activeParameters = parameters
			if not activeParameters then
				activeParameters = getLineOfSightParameters()
				parameters = activeParameters
				wallParameters = getWallLineOfSightParameters(geometry)
			end
			rawVisible = hasLineOfSight(
				seekerRoot,
				seekerHumanoid,
				hiderRoot,
				hiderHumanoid,
				activeParameters,
				wallParameters
			)
		end
		local detected, _, _, seenSeekerPosition = updateSightRecord(
			seekerRoot,
			hiderRoot,
			rawVisible,
			now
		)
		if detected then
			table.insert(threats, seenSeekerPosition)
		end
	end
	return threats
end

return table.freeze(HiderThreatAwareness)
