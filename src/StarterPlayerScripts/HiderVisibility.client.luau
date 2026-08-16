--!strict

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Config = require(ReplicatedStorage:WaitForChild("SeekerSearchConfig"))
local SearchGeometry = require(ReplicatedStorage:WaitForChild("SeekerSearchGeometry"))

local localPlayer = Players.LocalPlayer

local NPC_FOLDER_NAME = "RoundNPCs"
local ROLE_ATTRIBUTE = "RoundRole"
local ROLE_SEEKER = "Seeker"
local INVISIBLE_ATTRIBUTE = Config.HIDER_INVISIBLE_ATTRIBUTE
local PRESERVE_VISUAL_ATTRIBUTE = Config.PRESERVE_VISUAL_ATTRIBUTE
local CAGED_ATTRIBUTE = Config.CAGED_ATTRIBUTE
local FORCED_VISIBLE_ATTRIBUTE = Config.FORCED_VISIBLE_ATTRIBUTE
local NPC_COLOR_HIGHLIGHT_NAME = "NpcColorHighlight"
local MAP_CONTAINER_NAME = "Map"
local FLOOR_CONTAINER_NAME = "Floor"
local WALLS_CONTAINER_NAME = "Walls"
local VISIBILITY_UPDATE_INTERVAL = 0.05
local PARAMETERS_CACHE_SECONDS = 0.2

type Tracker = {
	model: Model,
	hidden: boolean,
	detected: boolean,
	losingSight: boolean,
	exposureStartedAt: number?,
	lastVisibleAt: number,
	hiddenAlpha: number,
	targetHiddenAlpha: number,
	transitionStartedAt: number?,
	transitionStartAlpha: number,
	transitionDuration: number,
	localTransparencies: {[BasePart]: number},
	castShadows: {[BasePart]: boolean},
	surfaceLocalTransparencies: {[Decal]: number},
	highlights: {[Highlight]: boolean},
	billboards: {[BillboardGui]: boolean},
	displayTypes: {[Humanoid]: EnumItem},
	connections: {RBXScriptConnection},
}

local trackers: {[Model]: Tracker} = {}
local playerConnections: {[Player]: {RBXScriptConnection}} = {}
local visibilityAccumulator = 0
local cachedLineOfSightParameters: RaycastParams? = nil
local lineOfSightParametersExpireAt = 0
local wallCacheDirty = true
local cachedWallParameters: RaycastParams? = nil

local function shouldPreserveVisual(object: Instance, model: Model): boolean
	local current: Instance? = object
	while current do
		if current:GetAttribute(PRESERVE_VISUAL_ATTRIBUTE) == true then
			return true
		end
		if current == model then
			break
		end
		current = current.Parent
	end
	return false
end

local function hideObject(tracker: Tracker, object: Instance, hiddenAlpha: number?)
	if shouldPreserveVisual(object, tracker.model) then
		return
	end
	local alpha = math.clamp(hiddenAlpha or 1, 0, 1)

	if object:IsA("BasePart") then
		if tracker.localTransparencies[object] == nil then
			tracker.localTransparencies[object] = object.LocalTransparencyModifier
			tracker.castShadows[object] = object.CastShadow
		end
		local originalTransparency = tracker.localTransparencies[object] or 0
		object.LocalTransparencyModifier = originalTransparency + (1 - originalTransparency) * alpha
		object.CastShadow = (tracker.castShadows[object] == true) and alpha < 0.99
	elseif object:IsA("Decal") then
		if tracker.surfaceLocalTransparencies[object] == nil then
			tracker.surfaceLocalTransparencies[object] = object.LocalTransparencyModifier
		end
		local originalTransparency = tracker.surfaceLocalTransparencies[object] or 0
		object.LocalTransparencyModifier = originalTransparency + (1 - originalTransparency) * alpha
	elseif object:IsA("Highlight") and object.Name == NPC_COLOR_HIGHLIGHT_NAME then
		if tracker.highlights[object] == nil then
			tracker.highlights[object] = object.Enabled
		end
		object.Enabled = tracker.highlights[object] == true and alpha < 0.99
	elseif object:IsA("BillboardGui") then
		if tracker.billboards[object] == nil then
			tracker.billboards[object] = object.Enabled
		end
		object.Enabled = tracker.billboards[object] == true and alpha < 0.99
	elseif object:IsA("Humanoid") then
		if tracker.displayTypes[object] == nil then
			tracker.displayTypes[object] = object.DisplayDistanceType
		end
		object.DisplayDistanceType = if alpha >= 0.99
			then Enum.HumanoidDisplayDistanceType.None
			else (tracker.displayTypes[object] :: any)
	end
end

local function hideTree(tracker: Tracker, root: Instance, hiddenAlpha: number?)
	hideObject(tracker, root, hiddenAlpha)
	for _, object in ipairs(root:GetDescendants()) do
		hideObject(tracker, object, hiddenAlpha)
	end
end

local function restoreObject(tracker: Tracker, object: Instance)
	if object:IsA("BasePart") then
		local localTransparency = tracker.localTransparencies[object]
		if localTransparency ~= nil then
			object.LocalTransparencyModifier = localTransparency
			tracker.localTransparencies[object] = nil
		end
		local castShadow = tracker.castShadows[object]
		if castShadow ~= nil then
			object.CastShadow = castShadow
			tracker.castShadows[object] = nil
		end
	elseif object:IsA("Decal") then
		local transparency = tracker.surfaceLocalTransparencies[object]
		if transparency ~= nil then
			object.LocalTransparencyModifier = transparency
			tracker.surfaceLocalTransparencies[object] = nil
		end
	elseif object:IsA("Highlight") then
		local enabled = tracker.highlights[object]
		if enabled ~= nil then
			object.Enabled = enabled
			tracker.highlights[object] = nil
		end
	elseif object:IsA("BillboardGui") then
		local enabled = tracker.billboards[object]
		if enabled ~= nil then
			object.Enabled = enabled
			tracker.billboards[object] = nil
		end
	elseif object:IsA("Humanoid") then
		local displayType = tracker.displayTypes[object]
		if displayType ~= nil then
			object.DisplayDistanceType = displayType :: any
			tracker.displayTypes[object] = nil
		end
	end
end

local function restoreTree(tracker: Tracker, root: Instance)
	restoreObject(tracker, root)
	for _, object in ipairs(root:GetDescendants()) do
		restoreObject(tracker, object)
	end
end

local function restoreAll(tracker: Tracker)
	for part, localTransparency in pairs(tracker.localTransparencies) do
		if part.Parent then
			part.LocalTransparencyModifier = localTransparency
		end
	end
	for part, castShadow in pairs(tracker.castShadows) do
		if part.Parent then
			part.CastShadow = castShadow
		end
	end
	for decal, localTransparency in pairs(tracker.surfaceLocalTransparencies) do
		if decal.Parent then
			decal.LocalTransparencyModifier = localTransparency
		end
	end
	for highlight, enabled in pairs(tracker.highlights) do
		if highlight.Parent then
			highlight.Enabled = enabled
		end
	end
	for billboard, enabled in pairs(tracker.billboards) do
		if billboard.Parent then
			billboard.Enabled = enabled
		end
	end
	for humanoid, displayType in pairs(tracker.displayTypes) do
		if humanoid.Parent then
			humanoid.DisplayDistanceType = displayType :: any
		end
	end
	table.clear(tracker.localTransparencies)
	table.clear(tracker.castShadows)
	table.clear(tracker.surfaceLocalTransparencies)
	table.clear(tracker.highlights)
	table.clear(tracker.billboards)
	table.clear(tracker.displayTypes)
	tracker.hidden = false
	tracker.hiddenAlpha = 0
	tracker.targetHiddenAlpha = 0
	tracker.transitionStartedAt = nil
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
		parameters.CollisionGroup = Config.RAYCAST_COLLISION_GROUP
		cachedWallParameters = parameters
	end
	wallCacheDirty = false
	return cachedWallParameters
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
	for _, descendant in ipairs(Workspace:GetDescendants()) do
		if descendant.Name == FLOOR_CONTAINER_NAME
			and descendant.Parent
			and descendant.Parent.Name == MAP_CONTAINER_NAME then
			table.insert(excluded, descendant)
		end
	end

	local parameters = RaycastParams.new()
	parameters.FilterType = Enum.RaycastFilterType.Exclude
	parameters.FilterDescendantsInstances = excluded
	parameters.IgnoreWater = true
	parameters.RespectCanCollide = true
	parameters.CollisionGroup = Config.RAYCAST_COLLISION_GROUP
	cachedLineOfSightParameters = parameters
	lineOfSightParametersExpireAt = now + PARAMETERS_CACHE_SECONDS
	return parameters
end

local function lineOfSightHeight(rootPart: BasePart, humanoid: Humanoid): Vector3
	local floorY = rootPart.Position.Y
		- math.max(0, humanoid.HipHeight)
		- rootPart.Size.Y * 0.5
	return Vector3.new(
		rootPart.Position.X,
		floorY + Config.LINE_OF_SIGHT_HEIGHT,
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

local function shouldHide(tracker: Tracker): boolean
	return tracker.model:GetAttribute(INVISIBLE_ATTRIBUTE) == true
		and localPlayer:GetAttribute(ROLE_ATTRIBUTE) == ROLE_SEEKER
		and (not tracker.detected or tracker.losingSight)
		and tracker.model:GetAttribute(CAGED_ATTRIBUTE) ~= true
		and tracker.model:GetAttribute(FORCED_VISIBLE_ATTRIBUTE) ~= true
end

local function applyHiddenAlpha(tracker: Tracker, hiddenAlpha: number)
	tracker.hiddenAlpha = math.clamp(hiddenAlpha, 0, 1)
	tracker.hidden = tracker.hiddenAlpha > 0.001
	if tracker.hidden then
		hideTree(tracker, tracker.model, tracker.hiddenAlpha)
	else
		restoreAll(tracker)
	end
end

local function refreshTracker(tracker: Tracker, instant: boolean?)
	local target = if shouldHide(tracker) then 1 else 0
	if tracker.targetHiddenAlpha == target
		and (tracker.transitionStartedAt ~= nil or math.abs(tracker.hiddenAlpha - target) <= 0.001) then
		return
	end
	tracker.targetHiddenAlpha = target
	tracker.transitionStartAlpha = tracker.hiddenAlpha
	tracker.transitionDuration = if target > tracker.hiddenAlpha
		then Config.VISION_HIDE_FADE_SECONDS
		else Config.VISION_REVEAL_FADE_SECONDS
	if instant or tracker.transitionDuration <= 0 then
		tracker.transitionStartedAt = nil
		applyHiddenAlpha(tracker, target)
	else
		tracker.transitionStartedAt = os.clock()
	end
end

local function updateTransition(tracker: Tracker, now: number)
	local startedAt = tracker.transitionStartedAt
	if not startedAt then
		return
	end
	local progress = math.clamp((now - startedAt) / tracker.transitionDuration, 0, 1)
	local eased = 1 - (1 - progress) * (1 - progress)
	applyHiddenAlpha(
		tracker,
		tracker.transitionStartAlpha
			+ (tracker.targetHiddenAlpha - tracker.transitionStartAlpha) * eased
	)
	if progress >= 1 then
		tracker.transitionStartedAt = nil
	end
end

local function resetDetection(tracker: Tracker)
	local changed = tracker.detected
	tracker.detected = false
	tracker.losingSight = false
	tracker.exposureStartedAt = nil
	tracker.lastVisibleAt = -math.huge
	if changed or tracker.hidden then
		refreshTracker(tracker)
	end
end

local function updateVisibility()
	if localPlayer:GetAttribute(ROLE_ATTRIBUTE) ~= ROLE_SEEKER then
		for _, tracker in pairs(trackers) do
			resetDetection(tracker)
		end
		return
	end

	local seekerCharacter = localPlayer.Character
	local seekerHumanoid = if seekerCharacter
		then seekerCharacter:FindFirstChildOfClass("Humanoid")
		else nil
	local seekerRoot = if seekerCharacter
		then seekerCharacter:FindFirstChild("HumanoidRootPart")
		else nil
	if not seekerHumanoid
		or seekerHumanoid.Health <= 0
		or not seekerRoot
		or not seekerRoot:IsA("BasePart") then
		for _, tracker in pairs(trackers) do
			resetDetection(tracker)
		end
		return
	end

	local now = os.clock()
	local parameters = getLineOfSightParameters()
	local wallParameters = getWallRaycastParameters()
	for _, tracker in pairs(trackers) do
		local model = tracker.model
		if model == seekerCharacter
			or model:GetAttribute(INVISIBLE_ATTRIBUTE) ~= true then
			resetDetection(tracker)
			continue
		end

		local hiderHumanoid = model:FindFirstChildOfClass("Humanoid")
		local hiderRoot = model:FindFirstChild("HumanoidRootPart")
		local rawVisible = hiderHumanoid ~= nil
			and hiderHumanoid.Health > 0
			and hiderRoot ~= nil
			and hiderRoot:IsA("BasePart")
		if rawVisible and hiderHumanoid and hiderRoot and hiderRoot:IsA("BasePart") then
			local offset = hiderRoot.Position - seekerRoot.Position
			local planarDistance = Vector2.new(offset.X, offset.Z).Magnitude
			local allowedDistance = if tracker.detected
				then Config.VISION_TRACK_DISTANCE
				else Config.VISION_DISTANCE
			local allowedFov = if tracker.detected
				then Config.VISION_TRACK_FOV_DEGREES
				else Config.VISION_FOV_DEGREES
			rawVisible = math.abs(offset.Y) <= Config.MAX_VERTICAL_DIFFERENCE
				and planarDistance <= allowedDistance
				and SearchGeometry.IsInsideVisionFov(seekerRoot.CFrame.LookVector, offset, allowedFov)
				and hasLineOfSight(
					seekerRoot,
					seekerHumanoid,
					hiderRoot,
					hiderHumanoid,
					parameters,
					wallParameters
				)
		end

		local wasDetected = tracker.detected
		if rawVisible and hiderHumanoid and hiderRoot and hiderRoot:IsA("BasePart") then
			if tracker.losingSight then
				tracker.losingSight = false
				refreshTracker(tracker)
			end
			local exposureStartedAt = tracker.exposureStartedAt or now
			tracker.exposureStartedAt = exposureStartedAt
			if tracker.detected or now - exposureStartedAt >= Config.VISION_DETECTION_SECONDS then
				tracker.detected = true
				tracker.lastVisibleAt = now
			end
		else
			tracker.exposureStartedAt = nil
			if tracker.detected then
				if not tracker.losingSight then
					tracker.losingSight = true
					refreshTracker(tracker)
				end
				if now - tracker.lastVisibleAt > Config.VISION_LOST_GRACE_SECONDS then
					tracker.detected = false
					tracker.losingSight = false
				end
			end
		end
		if tracker.detected ~= wasDetected then
			refreshTracker(tracker)
		end
	end
end

local function untrackModel(model: Model, restore: boolean?)
	local tracker = trackers[model]
	if not tracker then
		return
	end
	trackers[model] = nil
	for _, connection in ipairs(tracker.connections) do
		connection:Disconnect()
	end
	table.clear(tracker.connections)
	if restore ~= false then
		restoreAll(tracker)
	end
end

local function trackModel(model: Model)
	if trackers[model] then
		return
	end

	local tracker: Tracker = {
		model = model,
		hidden = false,
		detected = false,
		losingSight = false,
		exposureStartedAt = nil,
		lastVisibleAt = -math.huge,
		hiddenAlpha = 0,
		targetHiddenAlpha = 0,
		transitionStartedAt = nil,
		transitionStartAlpha = 0,
		transitionDuration = 0,
		localTransparencies = {},
		castShadows = {},
		surfaceLocalTransparencies = {},
		highlights = {},
		billboards = {},
		displayTypes = {},
		connections = {},
	}
	trackers[model] = tracker
	table.insert(
		tracker.connections,
		model:GetAttributeChangedSignal(INVISIBLE_ATTRIBUTE):Connect(function()
			refreshTracker(tracker)
		end)
	)
	table.insert(
		tracker.connections,
		model:GetAttributeChangedSignal(CAGED_ATTRIBUTE):Connect(function()
			refreshTracker(tracker)
		end)
	)
	table.insert(
		tracker.connections,
		model:GetAttributeChangedSignal(FORCED_VISIBLE_ATTRIBUTE):Connect(function()
			refreshTracker(tracker)
		end)
	)
	table.insert(tracker.connections, model.DescendantAdded:Connect(function(object)
		if tracker.hidden then
			hideTree(tracker, object, tracker.hiddenAlpha)
		end
	end))
	table.insert(tracker.connections, model.DescendantRemoving:Connect(function(object)
		restoreTree(tracker, object)
	end))
	table.insert(tracker.connections, model.Destroying:Connect(function()
		untrackModel(model, false)
	end))
	refreshTracker(tracker, true)
end

local function setupPlayer(player: Player)
	if playerConnections[player] then
		return
	end
	local connections: {RBXScriptConnection} = {}
	playerConnections[player] = connections
	table.insert(connections, player.CharacterAdded:Connect(trackModel))
	table.insert(connections, player.CharacterRemoving:Connect(function(character)
		untrackModel(character)
	end))
	if player.Character then
		trackModel(player.Character)
	end
end

local function removePlayer(player: Player)
	local connections = playerConnections[player]
	if connections then
		playerConnections[player] = nil
		for _, connection in ipairs(connections) do
			connection:Disconnect()
		end
	end
	if player.Character then
		untrackModel(player.Character)
	end
end

for _, player in ipairs(Players:GetPlayers()) do
	setupPlayer(player)
end
Players.PlayerAdded:Connect(setupPlayer)
Players.PlayerRemoving:Connect(removePlayer)

local npcFolder = Workspace:WaitForChild(NPC_FOLDER_NAME)
for _, child in ipairs(npcFolder:GetChildren()) do
	if child:IsA("Model") then
		trackModel(child)
	end
end
npcFolder.ChildAdded:Connect(function(child)
	if child:IsA("Model") then
		trackModel(child)
	end
end)
npcFolder.ChildRemoved:Connect(function(child)
	if child:IsA("Model") then
		untrackModel(child)
	end
end)

localPlayer:GetAttributeChangedSignal(ROLE_ATTRIBUTE):Connect(function()
	for _, tracker in pairs(trackers) do
		tracker.detected = false
		tracker.losingSight = false
		tracker.exposureStartedAt = nil
		tracker.lastVisibleAt = -math.huge
		refreshTracker(tracker, true)
	end
end)

RunService.RenderStepped:Connect(function(deltaTime)
	local now = os.clock()
	for _, tracker in pairs(trackers) do
		updateTransition(tracker, now)
	end
	visibilityAccumulator += deltaTime
	if visibilityAccumulator < VISIBILITY_UPDATE_INTERVAL then
		return
	end
	visibilityAccumulator = 0
	updateVisibility()
end)
