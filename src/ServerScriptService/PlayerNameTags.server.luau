local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local GamePassConfig = require(ReplicatedStorage:WaitForChild("CooldownPassConfig"))
local SearchConfig = require(ReplicatedStorage:WaitForChild("SeekerSearchConfig"))

local NAME_TAG_NAME = "OverheadPlayerNameTag"
local MAX_DISTANCE = 250
-- Используем Scale (стады), чтобы размер корректно адаптировался под разные экраны
local TAG_SIZE = UDim2.fromScale(3, 1)
-- Подняли высоту, так как крепим к HumanoidRootPart (в районе пояса)
local TAG_OFFSET = Vector3.new(0, 3.5, 0)
local DEFAULT_TEXT_COLOR = Color3.fromRGB(255, 255, 255)
local VIP_TEXT_COLOR = Color3.fromRGB(255, 214, 64)

local function getPlayerLabel(player: Player): string
	local displayName = string.gsub(player.DisplayName or "", "^%s*(.-)%s*$", "%1")
	local name = if displayName ~= "" then displayName else player.Name
	if player:GetAttribute(GamePassConfig.VIP_OWNED_ATTRIBUTE) == true then
		return `[VIP] {name}`
	end
	if displayName ~= "" then
		return displayName
	end

	return player.Name
end

local function getPlayerLabelColor(player: Player): Color3
	return if player:GetAttribute(GamePassConfig.VIP_OWNED_ATTRIBUTE) == true
		then VIP_TEXT_COLOR
		else DEFAULT_TEXT_COLOR
end

local function createNameTag(player: Player, attachPart: BasePart)
	local oldTag = attachPart:FindFirstChild(NAME_TAG_NAME)
	if oldTag then
		oldTag:Destroy()
	end

	local billboard = Instance.new("BillboardGui")
	billboard.Name = NAME_TAG_NAME
	billboard.AlwaysOnTop = true
	billboard.MaxDistance = MAX_DISTANCE
	billboard.Size = TAG_SIZE
	billboard.StudsOffsetWorldSpace = TAG_OFFSET
	billboard.Adornee = attachPart
	billboard.Enabled = true
	billboard.LightInfluence = 0
	billboard:SetAttribute(SearchConfig.PRESERVE_VISUAL_ATTRIBUTE, true)
	billboard.Parent = attachPart

	local label = Instance.new("TextLabel")
	label.Name = "NameLabel"
	label.BackgroundTransparency = 1
	label.Size = UDim2.fromScale(1, 1)
	label.Font = Enum.Font.GothamBold
	label.Text = getPlayerLabel(player)
	label.TextColor3 = getPlayerLabelColor(player)
	label.TextScaled = true
	label.TextStrokeColor3 = Color3.fromRGB(15, 18, 25)
	label.TextStrokeTransparency = 0.15
	label.Parent = billboard

	local textSizeConstraint = Instance.new("UITextSizeConstraint")
	-- Увеличили макс. размер шрифта, движок сам подберет идеальный благодаря TextScaled
	textSizeConstraint.MaxTextSize = 50
	textSizeConstraint.MinTextSize = 10
	textSizeConstraint.Parent = label
end

local function setupCharacter(player: Player, character: Model)
	local humanoid = character:WaitForChild("Humanoid", 10)
	if humanoid and humanoid:IsA("Humanoid") then
		humanoid.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.None
	end

	-- Ждем HumanoidRootPart, так как эта часть гарантированно не удаляется при загрузке аватара
	local rootPart = character:WaitForChild("HumanoidRootPart", 10)
	if not rootPart or not rootPart:IsA("BasePart") or player.Character ~= character then
		return
	end

	createNameTag(player, rootPart)
end

local function refreshCharacterName(player: Player)
	local character = player.Character
	local rootPart = if character then character:FindFirstChild("HumanoidRootPart") else nil
	local billboard = if rootPart then rootPart:FindFirstChild(NAME_TAG_NAME) else nil
	local label = if billboard then billboard:FindFirstChild("NameLabel") else nil
	if label and label:IsA("TextLabel") then
		label.Text = getPlayerLabel(player)
		label.TextColor3 = getPlayerLabelColor(player)
	end
end

local function setupPlayer(player: Player)
	player.CharacterAdded:Connect(function(character)
		task.spawn(setupCharacter, player, character)
	end)

	player:GetPropertyChangedSignal("DisplayName"):Connect(function()
		refreshCharacterName(player)
	end)
	player:GetAttributeChangedSignal(GamePassConfig.VIP_OWNED_ATTRIBUTE):Connect(function()
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
