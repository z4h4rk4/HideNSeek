local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local SearchConfig = require(ReplicatedStorage:WaitForChild("SeekerSearchConfig"))

local NAME_TAG_NAME = "OverheadPlayerNameTag"
local MAX_DISTANCE = 250
local TAG_SIZE = UDim2.fromOffset(170, 34)
local TAG_OFFSET = Vector3.new(0, 2.8, 0)

local function getPlayerLabel(player: Player): string
	local displayName = string.gsub(player.DisplayName or "", "^%s*(.-)%s*$", "%1")
	if displayName ~= "" then
		return displayName
	end

	return player.Name
end

local function createNameTag(player: Player, head: BasePart)
	local oldTag = head:FindFirstChild(NAME_TAG_NAME)
	if oldTag then
		oldTag:Destroy()
	end

	local billboard = Instance.new("BillboardGui")
	billboard.Name = NAME_TAG_NAME
	billboard.AlwaysOnTop = true
	billboard.MaxDistance = MAX_DISTANCE
	billboard.Size = TAG_SIZE
	billboard.StudsOffsetWorldSpace = TAG_OFFSET
	billboard.Adornee = head
	billboard.Enabled = true
	billboard.LightInfluence = 0
	billboard:SetAttribute(SearchConfig.PRESERVE_VISUAL_ATTRIBUTE, true)
	billboard.Parent = head

	local label = Instance.new("TextLabel")
	label.Name = "NameLabel"
	label.BackgroundTransparency = 1
	label.Size = UDim2.fromScale(1, 1)
	label.Font = Enum.Font.GothamBold
	label.Text = getPlayerLabel(player)
	label.TextColor3 = Color3.fromRGB(255, 255, 255)
	label.TextScaled = true
	label.TextStrokeColor3 = Color3.fromRGB(15, 18, 25)
	label.TextStrokeTransparency = 0.15
	label.Parent = billboard

	local textSizeConstraint = Instance.new("UITextSizeConstraint")
	textSizeConstraint.MaxTextSize = 20
	textSizeConstraint.MinTextSize = 10
	textSizeConstraint.Parent = label
end

local function setupCharacter(player: Player, character: Model)
	local humanoid = character:WaitForChild("Humanoid", 10)
	if humanoid and humanoid:IsA("Humanoid") then
		humanoid.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.None
	end

	local head = character:WaitForChild("Head", 10)
	if not head or not head:IsA("BasePart") or player.Character ~= character then
		return
	end

	createNameTag(player, head)
end

local function refreshCharacterName(player: Player)
	local character = player.Character
	local head = if character then character:FindFirstChild("Head") else nil
	local billboard = if head then head:FindFirstChild(NAME_TAG_NAME) else nil
	local label = if billboard then billboard:FindFirstChild("NameLabel") else nil
	if label and label:IsA("TextLabel") then
		label.Text = getPlayerLabel(player)
	end
end

local function setupPlayer(player: Player)
	player.CharacterAdded:Connect(function(character)
		task.spawn(setupCharacter, player, character)
	end)

	player:GetPropertyChangedSignal("DisplayName"):Connect(function()
		refreshCharacterName(player)
	end)

	if player.Character then
		task.spawn(setupCharacter, player, player.Character)
	end
end

for _, player in ipairs(Players:GetPlayers()) do
	setupPlayer(player)
end

Players.PlayerAdded:Connect(setupPlayer)
