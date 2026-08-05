local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")

local SOURCE_FOLDER_NAME = "Leaks"
local CLIENT_FOLDER_NAME = "LeaksVisualAssets"
local REQUIRED_ASSETS = { "LeaksVFX", "Left", "Right" }

local sourceFolder = ServerStorage:WaitForChild(SOURCE_FOLDER_NAME, 10)
if not sourceFolder then
	warn(`LeaksAssetsSetup: ServerStorage.{SOURCE_FOLDER_NAME} not found`)
	return
end

local oldClientFolder = ReplicatedStorage:FindFirstChild(CLIENT_FOLDER_NAME)
if oldClientFolder then
	oldClientFolder:Destroy()
end

local clientFolder = Instance.new("Folder")
clientFolder.Name = CLIENT_FOLDER_NAME

for _, assetName in ipairs(REQUIRED_ASSETS) do
	local asset = sourceFolder:FindFirstChild(assetName, true)
	if asset then
		local assetClone = asset:Clone()
		assetClone.Name = assetName
		assetClone.Parent = clientFolder
	else
		warn(`LeaksAssetsSetup: ServerStorage.{SOURCE_FOLDER_NAME}.{assetName} not found`)
	end
end

clientFolder.Parent = ReplicatedStorage
