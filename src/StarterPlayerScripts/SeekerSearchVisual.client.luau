--!strict

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Config = require(ReplicatedStorage:WaitForChild("SeekerSearchConfig"))
local SearchGeometry = require(ReplicatedStorage:WaitForChild("SeekerSearchGeometry"))

local ROUND_STATE_NAME = "RoundState"
local NPC_FOLDER_NAME = "RoundNPCs"
local ROLE_ATTRIBUTE = "RoundRole"
local ROLE_SEEKER = "Seeker"
local PHASE_ROUND = "Round"
local SEARCH_RAYCAST_COLLISION_GROUP = Config.RAYCAST_COLLISION_GROUP
local VISUAL_FOLDER_NAME = "_LocalSeekerSearchVisuals"
local MAP_CONTAINER_NAME = "Map"
local WALLS_CONTAINER_NAME = "Walls"

type SearchVisual = {
	model: Model,
	wedges: {WedgePart},
}

local roundState = ReplicatedStorage:WaitForChild(ROUND_STATE_NAME)
local existingVisualFolder = Workspace:FindFirstChild(VISUAL_FOLDER_NAME)
if existingVisualFolder then
	existingVisualFolder:Destroy()
end

local visualFolder = Instance.new("Folder")
visualFolder.Name = VISUAL_FOLDER_NAME
visualFolder.Archivable = false
visualFolder.Parent = Workspace

local searchVisuals: {[Model]: SearchVisual} = {}
local updateAccumulator = 0
local lastVisualErrorAt = 0
local wallCacheDirty = true
local cachedWallParameters: RaycastParams? = nil

local function configureWedge(wedge: WedgePart)
	wedge.Name = "SearchField"
	wedge.Anchored = true
	wedge.CanCollide = false
	wedge.CanTouch = false
	wedge.CanQuery = false
	wedge.CastShadow = false
	wedge.Material = Enum.Material.Neon
	wedge.Color = Config.VISUAL_COLOR
	wedge.Transparency = Config.VISUAL_TRANSPARENCY
	wedge.Size = Vector3.new(Config.VISUAL_THICKNESS, 0.05, 0.05)
	wedge.Parent = visualFolder
end

local function setWedgeVisible(wedge: WedgePart, visible: boolean)
	wedge.Transparency = if visible then Config.VISUAL_TRANSPARENCY else 1
end

local function drawTriangle(
	pointA: Vector3,
	pointB: Vector3,
	pointC: Vector3,
	firstWedge: WedgePart,
	secondWedge: WedgePart
)
	local ab = pointB - pointA
	local ac = pointC - pointA
	local bc = pointC - pointB
	local abSquared = ab:Dot(ab)
	local acSquared = ac:Dot(ac)
	local bcSquared = bc:Dot(bc)

	-- Reorder the triangle so BC is the longest edge. This lets two
	-- right-angle WedgeParts cover the arbitrary triangle without gaps.
	if abSquared > acSquared and abSquared > bcSquared then
		pointC, pointA = pointA, pointC
	elseif acSquared > abSquared and acSquared > bcSquared then
		pointA, pointB = pointB, pointA
	end

	ab = pointB - pointA
	ac = pointC - pointA
	bc = pointC - pointB
	local rightVector = ac:Cross(ab)
	if rightVector.Magnitude <= 0.001 or bc.Magnitude <= 0.001 then
		setWedgeVisible(firstWedge, false)
		setWedgeVisible(secondWedge, false)
		return
	end

	local right = rightVector.Unit
	local back = bc.Unit
	local upVector = bc:Cross(right)
	if upVector.Magnitude <= 0.001 then
		setWedgeVisible(firstWedge, false)
		setWedgeVisible(secondWedge, false)
		return
	end
	local up = upVector.Unit
	local height = math.abs(ab:Dot(up))
	local firstLength = math.abs(ab:Dot(back))
	local secondLength = math.abs(ac:Dot(back))
	if height <= 0.01 or (firstLength <= 0.01 and secondLength <= 0.01) then
		setWedgeVisible(firstWedge, false)
		setWedgeVisible(secondWedge, false)
		return
	end

	firstWedge.Size = Vector3.new(
		Config.VISUAL_THICKNESS,
		math.max(0.01, height),
		math.max(0.01, firstLength)
	)
	firstWedge.CFrame = CFrame.fromMatrix((pointA + pointB) * 0.5, right, up, back)
	secondWedge.Size = Vector3.new(
		Config.VISUAL_THICKNESS,
		math.max(0.01, height),
		math.max(0.01, secondLength)
	)
	secondWedge.CFrame = CFrame.fromMatrix((pointA + pointC) * 0.5, -right, up, -back)
	setWedgeVisible(firstWedge, firstLength > 0.01)
	setWedgeVisible(secondWedge, secondLength > 0.01)
end

local function createSearchVisual(model: Model): SearchVisual
	local wedges: {WedgePart} = {}
	for _ = 1, Config.VISUAL_RAY_COUNT * 2 do
		local wedge = Instance.new("WedgePart")
		configureWedge(wedge)
		table.insert(wedges, wedge)
	end
	local visual = {
		model = model,
		wedges = wedges,
	}
	searchVisuals[model] = visual
	return visual
end

local function destroySearchVisual(model: Model)
	local visual = searchVisuals[model]
	if not visual then
		return
	end
	searchVisuals[model] = nil
	for _, wedge in ipairs(visual.wedges) do
		wedge:Destroy()
	end
end

local function collectRoleModels(role: string): {[Model]: BasePart}
	local models: {[Model]: BasePart} = {}
	for _, player in ipairs(Players:GetPlayers()) do
		local character = player.Character
		local humanoid = if character then character:FindFirstChildOfClass("Humanoid") else nil
		local rootPart = if character then character:FindFirstChild("HumanoidRootPart") else nil
		if player:GetAttribute(ROLE_ATTRIBUTE) == role
			and character
			and humanoid
			and humanoid.Health > 0
			and rootPart
			and rootPart:IsA("BasePart") then
			models[character] = rootPart
		end
	end

	local npcFolder = Workspace:FindFirstChild(NPC_FOLDER_NAME)
	if npcFolder then
		for _, child in ipairs(npcFolder:GetChildren()) do
			if child:IsA("Model") and child:GetAttribute(ROLE_ATTRIBUTE) == role then
				local humanoid = child:FindFirstChildOfClass("Humanoid")
				local rootPart = child:FindFirstChild("HumanoidRootPart")
				if humanoid
					and humanoid.Health > 0
					and rootPart
					and rootPart:IsA("BasePart") then
					models[child] = rootPart
				end
			end
		end
	end
	return models
end

local function makeRaycastParameters(): RaycastParams
	local excluded: {Instance} = { visualFolder }
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
	parameters.CollisionGroup = SEARCH_RAYCAST_COLLISION_GROUP
	return parameters
end

local function isInsideMapWalls(instance: Instance): boolean
	if instance.Name == WALLS_CONTAINER_NAME
		and instance.Parent
		and instance.Parent.Name == MAP_CONTAINER_NAME then
		return true
	end
	local current = instance.Parent
	while current and current ~= Workspace do
		if current.Name == WALLS_CONTAINER_NAME
			and current.Parent
			and current.Parent.Name == MAP_CONTAINER_NAME then
			return true
		end
		current = current.Parent
	end
	return false
end

local function affectsWallCache(instance: Instance): boolean
	return instance.Name == MAP_CONTAINER_NAME
		or instance.Name == WALLS_CONTAINER_NAME
		or isInsideMapWalls(instance)
end

Workspace.DescendantAdded:Connect(function(descendant)
	if affectsWallCache(descendant) then
		wallCacheDirty = true
	end
end)

Workspace.DescendantRemoving:Connect(function(descendant)
	if affectsWallCache(descendant) then
		wallCacheDirty = true
	end
end)

local function getWallRaycastParameters(): RaycastParams?
	if not wallCacheDirty then
		return cachedWallParameters
	end

	local wallParts: {Instance} = {}
	for _, descendant in ipairs(Workspace:GetDescendants()) do
		if descendant:IsA("BasePart") and isInsideMapWalls(descendant) then
			table.insert(wallParts, descendant)
		end
	end

	if #wallParts == 0 then
		cachedWallParameters = nil
	else
		local parameters = RaycastParams.new()
		parameters.FilterType = Enum.RaycastFilterType.Include
		parameters.FilterDescendantsInstances = wallParts
		parameters.IgnoreWater = true
		parameters.RespectCanCollide = false
		parameters.CollisionGroup = SEARCH_RAYCAST_COLLISION_GROUP
		cachedWallParameters = parameters
	end
	wallCacheDirty = false
	return cachedWallParameters
end

local function getFloorY(rootPart: BasePart, parameters: RaycastParams): number
	local result = Workspace:Raycast(rootPart.Position, Vector3.new(0, -30, 0), parameters)
	return if result
		then result.Position.Y + Config.VISUAL_FLOOR_OFFSET
		else rootPart.Position.Y - rootPart.Size.Y * 0.5 + Config.VISUAL_FLOOR_OFFSET
end

local function updateSearchVisual(
	visual: SearchVisual,
	rootPart: BasePart,
	parameters: RaycastParams,
	wallParameters: RaycastParams?
)
	local floorY = getFloorY(rootPart, parameters)
	local origin = Vector3.new(
		rootPart.Position.X,
		floorY + Config.LINE_OF_SIGHT_HEIGHT,
		rootPart.Position.Z
	)
	local center = Vector3.new(origin.X, floorY, origin.Z)
	local directions: {Vector3} = table.create(Config.VISUAL_RAY_COUNT)
	local obstacleDistances: {number?} = table.create(Config.VISUAL_RAY_COUNT)
	local flatForward = Vector2.new(rootPart.CFrame.LookVector.X, rootPart.CFrame.LookVector.Z)
	if flatForward.Magnitude <= 0.001 then
		flatForward = Vector2.new(0, -1)
	else
		flatForward = flatForward.Unit
	end
	local flatRight = Vector2.new(-flatForward.Y, flatForward.X)
	local forwardShapeEnabled = roundState:GetAttribute(Config.SEARCH_SHAPE_VERSION_ATTRIBUTE)
		== Config.SEARCH_SHAPE_VERSION
	local maximumRadius = if forwardShapeEnabled
		then Config.SEARCH_RADIUS + Config.FORWARD_RADIUS_BONUS
		else Config.SEARCH_RADIUS
	for index = 1, Config.VISUAL_RAY_COUNT do
		local relativeAngle = (index - 1) / Config.VISUAL_RAY_COUNT * math.pi * 2 - math.pi
		local cosine = math.cos(relativeAngle)
		local sine = math.sin(relativeAngle)
		local flatDirection = flatForward * cosine + flatRight * sine
		local unitDirection = Vector3.new(flatDirection.X, 0, flatDirection.Y)
		directions[index] = unitDirection
		local direction = unitDirection * maximumRadius
		local result = Workspace:Raycast(origin, direction, parameters)
		local wallResult = if wallParameters
			then Workspace:Raycast(origin, direction, wallParameters)
			else nil
		local hitDistance: number? = nil
		if result then
			hitDistance = result.Distance
		end
		if wallResult then
			hitDistance = if hitDistance
				then math.min(hitDistance, wallResult.Distance)
				else wallResult.Distance
		end
		obstacleDistances[index] = hitDistance
	end

	local forwardSegmentCount = if forwardShapeEnabled then SearchGeometry.GetForwardRayCount() else 0
	local firstForwardSegment = math.floor((Config.VISUAL_RAY_COUNT - forwardSegmentCount) * 0.5) + 1
	local lastForwardSegment = firstForwardSegment + forwardSegmentCount - 1
	local function getEndpoint(rayIndex: number, segmentRadius: number): Vector3
		local distance = segmentRadius
		local obstacleDistance = obstacleDistances[rayIndex]
		if obstacleDistance and obstacleDistance <= segmentRadius then
			distance = math.max(0, obstacleDistance - Config.VISUAL_WALL_PADDING)
		end
		return center + directions[rayIndex] * distance
	end

	for index = 1, Config.VISUAL_RAY_COUNT do
		local nextIndex = if index == Config.VISUAL_RAY_COUNT then 1 else index + 1
		local wedgeIndex = (index - 1) * 2 + 1
		local isForwardSegment = index >= firstForwardSegment and index <= lastForwardSegment
		local segmentRadius = if isForwardSegment
			then Config.SEARCH_RADIUS + Config.FORWARD_RADIUS_BONUS
			else Config.SEARCH_RADIUS
		drawTriangle(
			center,
			getEndpoint(index, segmentRadius),
			getEndpoint(nextIndex, segmentRadius),
			visual.wedges[wedgeIndex],
			visual.wedges[wedgeIndex + 1]
		)
	end
end

local function updateVisuals()
	if roundState:GetAttribute("Phase") ~= PHASE_ROUND then
		local modelsToRemove: {Model} = {}
		for model in pairs(searchVisuals) do
			table.insert(modelsToRemove, model)
		end
		for _, model in ipairs(modelsToRemove) do
			destroySearchVisual(model)
		end
		return
	end

	local seekerModels = collectRoleModels(ROLE_SEEKER)
	local parameters = makeRaycastParameters()
	local wallParameters = getWallRaycastParameters()
	for model, rootPart in pairs(seekerModels) do
		local visual = searchVisuals[model] or createSearchVisual(model)
		updateSearchVisual(visual, rootPart, parameters, wallParameters)
	end
	for model in pairs(searchVisuals) do
		if not seekerModels[model] then
			destroySearchVisual(model)
		end
	end
end

RunService.RenderStepped:Connect(function(deltaTime)
	updateAccumulator += deltaTime
	if updateAccumulator < Config.VISUAL_UPDATE_INTERVAL then
		return
	end
	updateAccumulator = 0
	local succeeded, message = xpcall(updateVisuals, debug.traceback)
	if not succeeded then
		local now = os.clock()
		if now - lastVisualErrorAt >= 3 then
			lastVisualErrorAt = now
			warn(`Seeker search visual update failed:\n{message}`)
		end
	end
end)
