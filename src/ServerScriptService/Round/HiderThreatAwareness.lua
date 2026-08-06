--!strict

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local SearchConfig = require(ReplicatedStorage:WaitForChild("SeekerSearchConfig"))
local SearchGeometry = require(ReplicatedStorage:WaitForChild("SeekerSearchGeometry"))
local HiderMapGeometry = require(script.Parent:WaitForChild("HiderMapGeometry"))

local NPC_FOLDER_NAME = "RoundNPCs"
local CAGE_FOLDER_NAMES = { "RoundCages", "_RoundCages" }
local WALLS_CONTAINER_NAME = "Walls"
local LINE_OF_SIGHT_PARAMETERS_CACHE_SECONDS = 0.2

type WallParametersRecord = {
	revision: number,
	parameters: RaycastParams?,
}

local HiderThreatAwareness = {}
local wallParametersByMap: {[Instance]: WallParametersRecord} = {}
local cachedLineOfSightParameters: RaycastParams? = nil
local lineOfSightParametersExpireAt = 0

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
	for _, folderName in ipairs(CAGE_FOLDER_NAMES) do
		local cageFolder = Workspace:FindFirstChild(folderName)
		if cageFolder then
			table.insert(excluded, cageFolder)
		end
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
	for _, seekerRoot in ipairs(seekerRoots) do
		local seekerHumanoid = if seekerRoot.Parent then getLivingHumanoid(seekerRoot) else nil
		if not seekerHumanoid then
			continue
		end
		local seekerPosition = seekerRoot.Position
		local hiderPosition = hiderRoot.Position
		if math.abs(seekerPosition.Y - hiderPosition.Y) > SearchConfig.MAX_VERTICAL_DIFFERENCE then
			continue
		end
		local direction = hiderPosition - seekerPosition
		local distance = planarDistance(seekerPosition, hiderPosition)
		if distance > alertDistance then
			continue
		end
		local searchRadius = SearchGeometry.GetRadius(seekerRoot.CFrame.LookVector, direction)
		local insideForwardSector = searchRadius > SearchConfig.SEARCH_RADIUS
		local insideCloseBubble = distance <= SearchConfig.SEARCH_RADIUS
		if not insideForwardSector and not insideCloseBubble then
			continue
		end

		local activeParameters = parameters
		if not activeParameters then
			activeParameters = getLineOfSightParameters()
			parameters = activeParameters
			wallParameters = getWallLineOfSightParameters(geometry)
		end
		if hasLineOfSight(
			seekerRoot,
			seekerHumanoid,
			hiderRoot,
			hiderHumanoid,
			activeParameters,
			wallParameters
		) then
			table.insert(threats, seekerPosition)
		end
	end
	return threats
end

return table.freeze(HiderThreatAwareness)
