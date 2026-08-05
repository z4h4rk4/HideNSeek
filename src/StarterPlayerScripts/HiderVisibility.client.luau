--!strict

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Config = require(ReplicatedStorage:WaitForChild("SeekerSearchConfig"))

local localPlayer = Players.LocalPlayer

local NPC_FOLDER_NAME = "RoundNPCs"
local ROLE_ATTRIBUTE = "RoundRole"
local ROLE_HIDER = "Hider"
local INVISIBLE_ATTRIBUTE = Config.HIDER_INVISIBLE_ATTRIBUTE
local PRESERVE_VISUAL_ATTRIBUTE = Config.PRESERVE_VISUAL_ATTRIBUTE
local NPC_COLOR_HIGHLIGHT_NAME = "NpcColorHighlight"

type Tracker = {
	model: Model,
	hidden: boolean,
	localTransparencies: {[BasePart]: number},
	castShadows: {[BasePart]: boolean},
	surfaceLocalTransparencies: {[Decal]: number},
	highlights: {[Highlight]: boolean},
	displayTypes: {[Humanoid]: EnumItem},
	connections: {RBXScriptConnection},
}

local trackers: {[Model]: Tracker} = {}
local playerConnections: {[Player]: {RBXScriptConnection}} = {}

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

local function hideObject(tracker: Tracker, object: Instance)
	if shouldPreserveVisual(object, tracker.model) then
		return
	end

	if object:IsA("BasePart") then
		if tracker.localTransparencies[object] == nil then
			tracker.localTransparencies[object] = object.LocalTransparencyModifier
			tracker.castShadows[object] = object.CastShadow
		end
		object.LocalTransparencyModifier = 1
		object.CastShadow = false
	elseif object:IsA("Decal") then
		if tracker.surfaceLocalTransparencies[object] == nil then
			tracker.surfaceLocalTransparencies[object] = object.LocalTransparencyModifier
		end
		object.LocalTransparencyModifier = 1
	elseif object:IsA("Highlight") and object.Name == NPC_COLOR_HIGHLIGHT_NAME then
		if tracker.highlights[object] == nil then
			tracker.highlights[object] = object.Enabled
		end
		object.Enabled = false
	elseif object:IsA("Humanoid") then
		if tracker.displayTypes[object] == nil then
			tracker.displayTypes[object] = object.DisplayDistanceType
		end
		object.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.None
	end
end

local function hideTree(tracker: Tracker, root: Instance)
	hideObject(tracker, root)
	for _, object in ipairs(root:GetDescendants()) do
		hideObject(tracker, object)
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
	for humanoid, displayType in pairs(tracker.displayTypes) do
		if humanoid.Parent then
			humanoid.DisplayDistanceType = displayType :: any
		end
	end
	table.clear(tracker.localTransparencies)
	table.clear(tracker.castShadows)
	table.clear(tracker.surfaceLocalTransparencies)
	table.clear(tracker.highlights)
	table.clear(tracker.displayTypes)
	tracker.hidden = false
end

local function shouldHide(model: Model): boolean
	return model:GetAttribute(INVISIBLE_ATTRIBUTE) == true
		and model:GetAttribute(Config.CAGED_ATTRIBUTE) ~= true
		and localPlayer:GetAttribute(ROLE_ATTRIBUTE) ~= ROLE_HIDER
end

local function refreshTracker(tracker: Tracker)
	if shouldHide(tracker.model) then
		tracker.hidden = true
		for _, object in ipairs(tracker.model:GetDescendants()) do
			hideObject(tracker, object)
		end
	elseif tracker.hidden then
		restoreAll(tracker)
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
		localTransparencies = {},
		castShadows = {},
		surfaceLocalTransparencies = {},
		highlights = {},
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
		model:GetAttributeChangedSignal(Config.CAGED_ATTRIBUTE):Connect(function()
			refreshTracker(tracker)
		end)
	)
	table.insert(tracker.connections, model.DescendantAdded:Connect(function(object)
		if tracker.hidden then
			hideTree(tracker, object)
		end
	end))
	table.insert(tracker.connections, model.DescendantRemoving:Connect(function(object)
		restoreTree(tracker, object)
	end))
	table.insert(tracker.connections, model.Destroying:Connect(function()
		untrackModel(model, false)
	end))
	refreshTracker(tracker)
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
		refreshTracker(tracker)
	end
end)
