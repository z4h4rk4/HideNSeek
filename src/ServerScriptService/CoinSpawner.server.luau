local CollectionService = game:GetService("CollectionService")
local ServerStorage = game:GetService("ServerStorage")

local COIN_TEMPLATE_NAME = "Coin"
local COIN_SPAWN_AREA_NAME = "CoinSpawnArea"
local COIN_TAG = "ClientSpinningCoin"
local COINS_FOLDER_NAME = "SpawnedCoins"
local COIN_RESPAWN_SECONDS = 20
local populatedSpawnAreas = {}

local function isCoinObject(object: Instance): boolean
	return object:IsA("BasePart") or object:IsA("Model")
end

local function isTopLevelSpawnArea(object: Instance): boolean
	if object.Name ~= COIN_SPAWN_AREA_NAME
		or (not object:IsA("Model") and not object:IsA("Folder")) then
		return false
	end
	local ancestor = object.Parent
	while ancestor and ancestor ~= workspace do
		if ancestor.Name == COIN_SPAWN_AREA_NAME
			and (ancestor:IsA("Model") or ancestor:IsA("Folder")) then
			return false
		end
		ancestor = ancestor.Parent
	end
	return true
end

local coinTemplate = ServerStorage:WaitForChild(COIN_TEMPLATE_NAME)
if not isCoinObject(coinTemplate) then
	error(`ServerStorage.{COIN_TEMPLATE_NAME} must be a BasePart or Model`)
end

local function clearPreviouslySpawnedCoins()
	local oldFolders = {}

	for _, object in ipairs(workspace:GetDescendants()) do
		if object:IsA("Folder") and object.Name == COINS_FOLDER_NAME then
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

local function prepareCoin(coin: Instance)
	for _, object in ipairs(coin:GetDescendants()) do
		if object:IsA("BasePart") then
			object.Anchored = true
			object.CanCollide = false
			object.CanTouch = true
		end
	end

	if coin:IsA("BasePart") then
		coin.Anchored = true
		coin.CanCollide = false
		coin.CanTouch = true
		coin.PivotOffset = CFrame.new()
	end
end

local placeCoinAtMarker: (BasePart, Folder) -> ()
placeCoinAtMarker = function(marker: BasePart, coinsFolder: Folder)
	local coin = coinTemplate:Clone()
	prepareCoin(coin)

	if coin:IsA("BasePart") then
		coin.CFrame = marker.CFrame
	else
		coin:PivotTo(marker.CFrame)
	end

	-- Совмещаем с маркером геометрический центр, даже если Pivot шаблона смещён.
	local boundsCenter
	if coin:IsA("Model") then
		local boundsCFrame = coin:GetBoundingBox()
		boundsCenter = boundsCFrame.Position
	else
		boundsCenter = coin.Position
	end

	coin:PivotTo(coin:GetPivot() + (marker.Position - boundsCenter))
	coin.Parent = coinsFolder
	coin.Destroying:Once(function()
		task.delay(COIN_RESPAWN_SECONDS, function()
			if marker:IsDescendantOf(workspace) and coinsFolder:IsDescendantOf(workspace) then
				placeCoinAtMarker(marker, coinsFolder)
			end
		end)
	end)
	CollectionService:AddTag(coin, COIN_TAG)

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
		warn(`CoinSpawner: {spawnArea:GetFullName()} has no BasePart markers`)
		return
	end

	local coinsFolder = Instance.new("Folder")
	coinsFolder.Name = COINS_FOLDER_NAME
	coinsFolder.Parent = spawnArea.Parent

	for _, marker in ipairs(markers) do
		placeCoinAtMarker(marker, coinsFolder)
	end
end

clearPreviouslySpawnedCoins()

local spawnAreas = findSpawnAreas()
if #spawnAreas == 0 then
	print("CoinSpawner: waiting for runtime arena CoinSpawnArea models")
end

for _, spawnArea in ipairs(spawnAreas) do
	populateSpawnArea(spawnArea)
end

workspace.DescendantAdded:Connect(function(descendant)
	if descendant.Name ~= COIN_SPAWN_AREA_NAME then
		return
	end
	task.defer(function()
		if descendant:IsDescendantOf(workspace) then
			populateSpawnArea(descendant)
		end
	end)
end)
