local CollectionService = game:GetService("CollectionService")
local ServerStorage = game:GetService("ServerStorage")

local TEMPLATE_NAME = "GoldBar"
local SPAWN_AREA_NAME = "GoldenBarSpawnArea"
local VISUAL_TAG = "ClientSpinningGoldBar"
local GENERATED_FOLDER_NAME = "SpawnedGoldBars"
local populatedSpawnAreas = {}

local function isGoldBarObject(object: Instance): boolean
	return object:IsA("BasePart") or object:IsA("Model")
end

local function isTopLevelSpawnArea(object: Instance): boolean
	if object.Name ~= SPAWN_AREA_NAME
		or (not object:IsA("Model") and not object:IsA("Folder")) then
		return false
	end
	local ancestor = object.Parent
	while ancestor and ancestor ~= workspace do
		if ancestor.Name == SPAWN_AREA_NAME
			and (ancestor:IsA("Model") or ancestor:IsA("Folder")) then
			return false
		end
		ancestor = ancestor.Parent
	end
	return true
end

local goldBarTemplate = ServerStorage:WaitForChild(TEMPLATE_NAME)
if not isGoldBarObject(goldBarTemplate) then
	error(`ServerStorage.{TEMPLATE_NAME} must be a BasePart or Model`)
end

local function clearPreviouslySpawnedGoldBars()
	local oldFolders = {}

	for _, object in ipairs(workspace:GetDescendants()) do
		if object:IsA("Folder") and object.Name == GENERATED_FOLDER_NAME then
			table.insert(oldFolders, object)
		end
	end

	for _, folder in ipairs(oldFolders) do
		folder:Destroy()
	end
end

local function findSpawnAreas(): { Instance }
	local spawnAreas = {}

	for _, object in ipairs(workspace:GetDescendants()) do
		if isTopLevelSpawnArea(object) then
			table.insert(spawnAreas, object)
		end
	end

	return spawnAreas
end

local function prepareGoldBar(goldBar: Instance)
	for _, object in ipairs(goldBar:GetDescendants()) do
		if object:IsA("BasePart") then
			object.Anchored = true
			object.CanCollide = false
			object.CanTouch = true
		end
	end

	if goldBar:IsA("BasePart") then
		goldBar.Anchored = true
		goldBar.CanCollide = false
		goldBar.CanTouch = true
		goldBar.PivotOffset = CFrame.new()
	end
end

local function placeGoldBarAtMarker(marker: BasePart, goldBarsFolder: Folder)
	local goldBar = goldBarTemplate:Clone()
	prepareGoldBar(goldBar)

	if goldBar:IsA("BasePart") then
		goldBar.CFrame = marker.CFrame
	else
		goldBar:PivotTo(marker.CFrame)
	end

	local boundsCenter
	if goldBar:IsA("Model") then
		local boundsCFrame = goldBar:GetBoundingBox()
		boundsCenter = boundsCFrame.Position
	else
		boundsCenter = goldBar.Position
	end

	goldBar:PivotTo(goldBar:GetPivot() + (marker.Position - boundsCenter))
	goldBar.Parent = goldBarsFolder
	CollectionService:AddTag(goldBar, VISUAL_TAG)

	marker.Anchored = true
	marker.CanCollide = false
	marker.CanTouch = false
	marker.CanQuery = false
	marker.Transparency = 1
end

local function populateSpawnArea(spawnArea: Instance)
	if populatedSpawnAreas[spawnArea] or not isTopLevelSpawnArea(spawnArea) then
		return
	end
	populatedSpawnAreas[spawnArea] = true
	spawnArea.Destroying:Once(function()
		populatedSpawnAreas[spawnArea] = nil
	end)
	local markers = {}

	for _, object in ipairs(spawnArea:GetDescendants()) do
		if object:IsA("BasePart") then
			table.insert(markers, object)
		end
	end

	if #markers == 0 then
		warn(`GoldBarSpawner: {spawnArea:GetFullName()} has no BasePart markers`)
		return
	end

	local goldBarsFolder = Instance.new("Folder")
	goldBarsFolder.Name = GENERATED_FOLDER_NAME
	goldBarsFolder.Parent = spawnArea.Parent

	for _, marker in ipairs(markers) do
		placeGoldBarAtMarker(marker, goldBarsFolder)
	end
end

clearPreviouslySpawnedGoldBars()

local spawnAreas = findSpawnAreas()
if #spawnAreas == 0 then
	print(`GoldBarSpawner: waiting for runtime arena {SPAWN_AREA_NAME} models`)
end

for _, spawnArea in ipairs(spawnAreas) do
	populateSpawnArea(spawnArea)
end

workspace.DescendantAdded:Connect(function(descendant)
	if descendant.Name ~= SPAWN_AREA_NAME then
		return
	end
	task.defer(function()
		if descendant:IsDescendantOf(workspace) then
			populateSpawnArea(descendant)
		end
	end)
end)
