local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")

local player = Players.LocalPlayer
local screenGui = script.Parent
local remote = screenGui:WaitForChild("AdminRequest")

local COLORS = {
	background = Color3.fromRGB(8, 11, 19),
	panel = Color3.fromRGB(16, 21, 34),
	panelRaised = Color3.fromRGB(22, 29, 46),
	panelSoft = Color3.fromRGB(27, 35, 55),
	sidebar = Color3.fromRGB(12, 17, 28),
	border = Color3.fromRGB(53, 66, 91),
	text = Color3.fromRGB(239, 244, 255),
	muted = Color3.fromRGB(142, 156, 182),
	accent = Color3.fromRGB(105, 92, 255),
	accentSoft = Color3.fromRGB(55, 49, 118),
	green = Color3.fromRGB(42, 188, 126),
	red = Color3.fromRGB(226, 76, 94),
	orange = Color3.fromRGB(232, 147, 57),
	blue = Color3.fromRGB(52, 145, 224),
	input = Color3.fromRGB(10, 15, 25),
}

local TARGET_ACTIONS = {
	GetSnapshot = true,
	AddCoins = true,
	RemoveCoins = true,
	SaveProfile = true,
	SetRole = true,
	RespawnPlayer = true,
	HealPlayer = true,
	NormalizeMovement = true,
}

local function create(className, properties, parent)
	local instance = Instance.new(className)
	for property, value in properties do
		instance[property] = value
	end
	instance.Parent = parent
	return instance
end

local function addCorner(parent, radius)
	return create("UICorner", { CornerRadius = UDim.new(0, radius) }, parent)
end

local function addStroke(parent, color, transparency)
	return create("UIStroke", {
		Color = color or COLORS.border,
		Transparency = transparency or 0,
		Thickness = 1,
	}, parent)
end

local function addLabel(parent, text, position, size, font, textSize, color)
	return create("TextLabel", {
		BackgroundTransparency = 1,
		Font = font or Enum.Font.Gotham,
		Position = position,
		Size = size,
		Text = text,
		TextColor3 = color or COLORS.text,
		TextSize = textSize or 13,
		TextWrapped = false,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextYAlignment = Enum.TextYAlignment.Center,
	}, parent)
end

local function makeButton(parent, text, color, position, size)
	local button = create("TextButton", {
		AutoButtonColor = false,
		BackgroundColor3 = color,
		Font = Enum.Font.GothamSemibold,
		Position = position,
		Size = size,
		Text = text,
		TextColor3 = COLORS.text,
		TextSize = 12,
	}, parent)
	addCorner(button, 8)
	addStroke(button, color:Lerp(Color3.new(1, 1, 1), 0.22), 0.58)
	button:SetAttribute("BaseColor", color)
	button.MouseEnter:Connect(function()
		if button.Interactable then
			local baseColor = button:GetAttribute("BaseColor") or color
			TweenService:Create(
				button,
				TweenInfo.new(0.12),
				{ BackgroundColor3 = baseColor:Lerp(Color3.new(1, 1, 1), 0.09) }
			):Play()
		end
	end)
	button.MouseLeave:Connect(function()
		TweenService:Create(
			button,
			TweenInfo.new(0.12),
			{ BackgroundColor3 = button:GetAttribute("BaseColor") or color }
		):Play()
	end)
	return button
end

local function makeInput(parent, placeholder, position, size)
	local input = create("TextBox", {
		BackgroundColor3 = COLORS.input,
		ClearTextOnFocus = false,
		Font = Enum.Font.GothamMedium,
		PlaceholderColor3 = Color3.fromRGB(91, 104, 130),
		PlaceholderText = placeholder,
		Position = position,
		Size = size,
		Text = "",
		TextColor3 = COLORS.text,
		TextSize = 13,
		TextXAlignment = Enum.TextXAlignment.Left,
	}, parent)
	addCorner(input, 8)
	addStroke(input, COLORS.border, 0.18)
	create("UIPadding", {
		PaddingLeft = UDim.new(0, 12),
		PaddingRight = UDim.new(0, 12),
	}, input)
	return input
end

local function formatInteger(value)
	local formatted = tostring(math.floor(tonumber(value) or 0))
	while true do
		local nextValue, replacements = formatted:gsub("^(-?%d+)(%d%d%d)", "%1,%2")
		formatted = nextValue
		if replacements == 0 then
			return formatted
		end
	end
end

local function makePage(parent, name)
	local page = create("ScrollingFrame", {
		Name = name .. "Page",
		AutomaticCanvasSize = Enum.AutomaticSize.Y,
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		CanvasSize = UDim2.fromOffset(0, 0),
		ScrollBarImageColor3 = COLORS.accent,
		ScrollBarThickness = 4,
		ScrollingDirection = Enum.ScrollingDirection.Y,
		Size = UDim2.fromScale(1, 1),
		Visible = false,
	}, parent)
	create("UIPadding", {
		PaddingBottom = UDim.new(0, 14),
		PaddingLeft = UDim.new(0, 14),
		PaddingRight = UDim.new(0, 14),
		PaddingTop = UDim.new(0, 14),
	}, page)
	create("UIListLayout", {
		Padding = UDim.new(0, 12),
		SortOrder = Enum.SortOrder.LayoutOrder,
	}, page)
	return page
end

local function makeHeading(parent, title, subtitle, order)
	local heading = create("Frame", {
		BackgroundTransparency = 1,
		LayoutOrder = order,
		Size = UDim2.new(1, 0, 0, 56),
	}, parent)
	addLabel(
		heading,
		title,
		UDim2.fromOffset(0, 0),
		UDim2.new(1, 0, 0, 30),
		Enum.Font.GothamBold,
		21,
		COLORS.text
	)
	local subtitleLabel = addLabel(
		heading,
		subtitle,
		UDim2.fromOffset(0, 30),
		UDim2.new(1, 0, 0, 22),
		Enum.Font.Gotham,
		12,
		COLORS.muted
	)
	subtitleLabel.TextWrapped = true
	return heading
end

local function makeCard(parent, title, subtitle, height, order)
	local card = create("Frame", {
		BackgroundColor3 = COLORS.panelRaised,
		LayoutOrder = order,
		Size = UDim2.new(1, 0, 0, height),
	}, parent)
	addCorner(card, 11)
	addStroke(card, COLORS.border, 0.28)
	addLabel(
		card,
		title,
		UDim2.fromOffset(16, 10),
		UDim2.new(1, -32, 0, 24),
		Enum.Font.GothamBold,
		14,
		COLORS.text
	)
	if subtitle then
		local subtitleLabel = addLabel(
			card,
			subtitle,
			UDim2.fromOffset(16, 34),
			UDim2.new(1, -32, 0, 30),
			Enum.Font.Gotham,
			11,
			COLORS.muted
		)
		subtitleLabel.TextWrapped = true
	end
	return card
end

local previousRoot = screenGui:FindFirstChild("AdminRoot")
if previousRoot then
	previousRoot:Destroy()
end

local root = create("Frame", {
	Name = "AdminRoot",
	BackgroundTransparency = 1,
	Size = UDim2.fromScale(1, 1),
}, screenGui)

local launcher = makeButton(
	root,
	"ADMIN  ·  F2",
	COLORS.accent,
	UDim2.new(1, -154, 1, -62),
	UDim2.fromOffset(140, 46)
)
launcher.AnchorPoint = Vector2.new(0, 0)
launcher.TextSize = 13

local overlay = create("Frame", {
	Name = "Overlay",
	Active = true,
	BackgroundColor3 = Color3.fromRGB(2, 4, 9),
	BackgroundTransparency = 0.24,
	Size = UDim2.fromScale(1, 1),
	Visible = false,
}, root)

local panel = create("Frame", {
	Name = "Panel",
	AnchorPoint = Vector2.new(0.5, 0.5),
	BackgroundColor3 = COLORS.panel,
	ClipsDescendants = true,
	Position = UDim2.fromScale(0.5, 0.5),
	Size = UDim2.fromScale(0.88, 0.86),
}, overlay)
addCorner(panel, 14)
addStroke(panel, COLORS.border, 0.04)
local panelConstraint = create("UISizeConstraint", {
	MinSize = Vector2.new(760, 520),
	MaxSize = Vector2.new(1040, 700),
}, panel)

local header = create("Frame", {
	Name = "Header",
	Active = true,
	BackgroundColor3 = COLORS.panelRaised,
	Size = UDim2.new(1, 0, 0, 64),
}, panel)
create("UIGradient", {
	Color = ColorSequence.new({
		ColorSequenceKeypoint.new(0, Color3.fromRGB(36, 38, 82)),
		ColorSequenceKeypoint.new(1, COLORS.panelRaised),
	}),
}, header)

local badge = create("Frame", {
	BackgroundColor3 = COLORS.accent,
	Position = UDim2.fromOffset(16, 13),
	Size = UDim2.fromOffset(38, 38),
}, header)
addCorner(badge, 10)
local badgeText = addLabel(
	badge,
	"A",
	UDim2.fromScale(0, 0),
	UDim2.fromScale(1, 1),
	Enum.Font.GothamBold,
	17,
	COLORS.text
)
badgeText.TextXAlignment = Enum.TextXAlignment.Center

local headerTitle = addLabel(
	header,
	"HIDE & SEEK CONTROL",
	UDim2.fromOffset(66, 8),
	UDim2.new(1, -200, 0, 27),
	Enum.Font.GothamBold,
	16,
	COLORS.text
)
local headerSubtitle = addLabel(
	header,
	"Secure server-side testing tools",
	UDim2.fromOffset(66, 33),
	UDim2.new(1, -200, 0, 20),
	Enum.Font.Gotham,
	11,
	COLORS.muted
)
local closeButton = makeButton(
	header,
	"CLOSE",
	Color3.fromRGB(53, 62, 82),
	UDim2.new(1, -112, 0, 14),
	UDim2.fromOffset(96, 36)
)

local targetBar = create("Frame", {
	Name = "TargetBar",
	BackgroundColor3 = COLORS.panelSoft,
	Position = UDim2.fromOffset(0, 64),
	Size = UDim2.new(1, 0, 0, 80),
}, panel)
create("Frame", {
	BackgroundColor3 = COLORS.border,
	BackgroundTransparency = 0.4,
	Position = UDim2.new(0, 0, 1, -1),
	Size = UDim2.new(1, 0, 0, 1),
}, targetBar)
addLabel(
	targetBar,
	"TARGET USER ID",
	UDim2.fromOffset(16, 7),
	UDim2.fromOffset(210, 18),
	Enum.Font.GothamBold,
	9,
	COLORS.muted
)
local targetInput = makeInput(
	targetBar,
	"Online player UserId",
	UDim2.fromOffset(16, 27),
	UDim2.fromOffset(250, 40)
)
targetInput.Text = tostring(player.UserId)
local loadButton = makeButton(
	targetBar,
	"Refresh",
	COLORS.accent,
	UDim2.fromOffset(276, 27),
	UDim2.fromOffset(104, 40)
)
local targetSummary = addLabel(
	targetBar,
	"Loading target snapshot...",
	UDim2.fromOffset(398, 9),
	UDim2.new(1, -414, 1, -18),
	Enum.Font.GothamMedium,
	12,
	COLORS.text
)
targetSummary.TextWrapped = true

local navigation = create("Frame", {
	Name = "Navigation",
	BackgroundColor3 = COLORS.sidebar,
	Position = UDim2.fromOffset(0, 144),
	Size = UDim2.new(0, 170, 1, -144),
}, panel)
create("Frame", {
	BackgroundColor3 = COLORS.border,
	BackgroundTransparency = 0.45,
	Position = UDim2.new(1, -1, 0, 0),
	Size = UDim2.new(0, 1, 1, 0),
}, navigation)

local navOrder = { "Overview", "Economy", "Player", "Round", "NPC" }
local navButtons = {}
for index, name in navOrder do
	local button = makeButton(
		navigation,
		"  " .. name,
		if index == 1 then COLORS.accentSoft else COLORS.sidebar,
		UDim2.fromOffset(12, 16 + (index - 1) * 48),
		UDim2.new(1, -24, 0, 40)
	)
	button.TextXAlignment = Enum.TextXAlignment.Left
	navButtons[name] = button
end

local adminIdentity = addLabel(
	navigation,
	("ADMIN\n%s\n%d"):format(player.Name, player.UserId),
	UDim2.new(0, 16, 1, -82),
	UDim2.new(1, -32, 0, 68),
	Enum.Font.GothamMedium,
	10,
	COLORS.muted
)
adminIdentity.TextWrapped = true
adminIdentity.TextYAlignment = Enum.TextYAlignment.Bottom

local content = create("Frame", {
	Name = "Content",
	BackgroundTransparency = 1,
	Position = UDim2.fromOffset(170, 144),
	Size = UDim2.new(1, -170, 1, -144),
}, panel)
local pageHost = create("Frame", {
	Name = "Pages",
	BackgroundTransparency = 1,
	Position = UDim2.fromOffset(0, 0),
	Size = UDim2.new(1, 0, 1, -50),
}, content)

local pages = {
	Overview = makePage(pageHost, "Overview"),
	Economy = makePage(pageHost, "Economy"),
	Player = makePage(pageHost, "Player"),
	Round = makePage(pageHost, "Round"),
	NPC = makePage(pageHost, "NPC"),
}

local statusBar = create("Frame", {
	Name = "StatusBar",
	BackgroundColor3 = COLORS.panelRaised,
	Position = UDim2.new(0, 12, 1, -43),
	Size = UDim2.new(1, -24, 0, 34),
}, content)
addCorner(statusBar, 8)
addStroke(statusBar, COLORS.border, 0.42)
local statusDot = create("Frame", {
	BackgroundColor3 = COLORS.muted,
	Position = UDim2.fromOffset(11, 12),
	Size = UDim2.fromOffset(9, 9),
}, statusBar)
addCorner(statusDot, 9)
local statusLabel = addLabel(
	statusBar,
	"Ready",
	UDim2.fromOffset(28, 0),
	UDim2.new(1, -38, 1, 0),
	Enum.Font.GothamMedium,
	11,
	COLORS.muted
)

makeHeading(
	pages.Overview,
	"Overview",
	"Live player, round, and NPC status from the server.",
	1
)
local playerStatusCard = makeCard(pages.Overview, "Selected Player", nil, 110, 2)
local playerStatusLabel = addLabel(
	playerStatusCard,
	"No snapshot loaded.",
	UDim2.fromOffset(16, 38),
	UDim2.new(1, -32, 1, -48),
	Enum.Font.GothamMedium,
	12,
	COLORS.text
)
playerStatusLabel.TextWrapped = true
playerStatusLabel.TextYAlignment = Enum.TextYAlignment.Top

local roundStatusCard = makeCard(pages.Overview, "Round Status", nil, 158, 3)
local roundStatusLabel = addLabel(
	roundStatusCard,
	"Round state unavailable.",
	UDim2.fromOffset(16, 38),
	UDim2.new(1, -32, 1, -48),
	Enum.Font.GothamMedium,
	12,
	COLORS.text
)
roundStatusLabel.TextWrapped = true
roundStatusLabel.TextYAlignment = Enum.TextYAlignment.Top

makeHeading(
	pages.Economy,
	"Economy",
	"Adjust loaded profiles through CurrencyService only.",
	1
)
local economyCard = makeCard(
	pages.Economy,
	"Coins",
	"Whole numbers only. Every change is recorded in the server audit log.",
	188,
	2
)
local amountInput = makeInput(
	economyCard,
	"Coin amount",
	UDim2.fromOffset(16, 72),
	UDim2.new(1, -32, 0, 40)
)
local addCoinsButton = makeButton(
	economyCard,
	"Add Coins",
	COLORS.green,
	UDim2.new(0, 16, 0, 126),
	UDim2.new(0.5, -22, 0, 42)
)
local removeCoinsButton = makeButton(
	economyCard,
	"Remove Coins",
	COLORS.red,
	UDim2.new(0.5, 6, 0, 126),
	UDim2.new(0.5, -22, 0, 42)
)
local saveCard = makeCard(
	pages.Economy,
	"Profile Persistence",
	"Request an immediate DataStore save for the selected loaded profile.",
	126,
	3
)
local saveProfileButton = makeButton(
	saveCard,
	"Save Profile Now",
	COLORS.blue,
	UDim2.fromOffset(16, 70),
	UDim2.new(1, -32, 0, 40)
)

makeHeading(
	pages.Player,
	"Player",
	"Test roles and character state for an online player.",
	1
)
local roleCard = makeCard(
	pages.Player,
	"Round Role",
	"Role and movement normalization are applied by the round service.",
	136,
	2
)
local hiderButton = makeButton(
	roleCard,
	"Hider",
	COLORS.green,
	UDim2.new(0, 16, 0, 76),
	UDim2.new(1 / 3, -18, 0, 42)
)
local seekerButton = makeButton(
	roleCard,
	"Hunter",
	COLORS.orange,
	UDim2.new(1 / 3, 4, 0, 76),
	UDim2.new(1 / 3, -14, 0, 42)
)
local spectatorButton = makeButton(
	roleCard,
	"Spectator",
	COLORS.blue,
	UDim2.new(2 / 3, 2, 0, 76),
	UDim2.new(1 / 3, -18, 0, 42)
)
local characterCard = makeCard(
	pages.Player,
	"Character",
	"All changes execute on the server and only affect the selected online player.",
	136,
	3
)
local healButton = makeButton(
	characterCard,
	"Heal",
	COLORS.green,
	UDim2.new(0, 16, 0, 76),
	UDim2.new(1 / 3, -18, 0, 42)
)
local movementButton = makeButton(
	characterCard,
	"Normalize",
	COLORS.accent,
	UDim2.new(1 / 3, 4, 0, 76),
	UDim2.new(1 / 3, -14, 0, 42)
)
local respawnButton = makeButton(
	characterCard,
	"Respawn",
	COLORS.red,
	UDim2.new(2 / 3, 2, 0, 76),
	UDim2.new(1 / 3, -18, 0, 42)
)

makeHeading(
	pages.Round,
	"Round",
	"Control the active server round without changing replicated attributes directly.",
	1
)
local lifecycleCard = makeCard(
	pages.Round,
	"Lifecycle",
	"Start skips the current countdown. Restart creates a fresh assignment.",
	136,
	2
)
local startRoundButton = makeButton(
	lifecycleCard,
	"Start Now",
	COLORS.green,
	UDim2.new(0, 16, 0, 76),
	UDim2.new(1 / 3, -18, 0, 42)
)
local endRoundButton = makeButton(
	lifecycleCard,
	"End Round",
	COLORS.red,
	UDim2.new(1 / 3, 4, 0, 76),
	UDim2.new(1 / 3, -14, 0, 42)
)
local restartRoundButton = makeButton(
	lifecycleCard,
	"Restart",
	COLORS.orange,
	UDim2.new(2 / 3, 2, 0, 76),
	UDim2.new(1 / 3, -18, 0, 42)
)
local timerCard = makeCard(
	pages.Round,
	"Remaining Time",
	"Set the current phase timer from 1 to 600 seconds.",
	136,
	3
)
local secondsInput = makeInput(
	timerCard,
	"Seconds (1–600)",
	UDim2.fromOffset(16, 76),
	UDim2.new(1, -158, 0, 42)
)
secondsInput.Text = "60"
local setTimeButton = makeButton(
	timerCard,
	"Apply Time",
	COLORS.accent,
	UDim2.new(1, -132, 0, 76),
	UDim2.fromOffset(116, 42)
)

makeHeading(
	pages.NPC,
	"NPC & Hunters",
	"Manage server-owned characters. Hunter is the player-facing name for the Seeker role.",
	1
)
local npcPopulationCard = makeCard(
	pages.NPC,
	"Quick Population Tools",
	"Automatic mode uses normal round limits. Role-clearing buttons remove that whole NPC role.",
	190,
	2
)
local fillNpcsButton = makeButton(
	npcPopulationCard,
	"Fill Empty Slots",
	COLORS.green,
	UDim2.new(0, 16, 0, 76),
	UDim2.new(0.5, -22, 0, 42)
)
local clearNpcsButton = makeButton(
	npcPopulationCard,
	"Clear NPCs Safely",
	COLORS.red,
	UDim2.new(0.5, 6, 0, 76),
	UDim2.new(0.5, -22, 0, 42)
)
local spawnHiderButton = makeButton(
	npcPopulationCard,
	"+1 Hider",
	COLORS.green,
	UDim2.new(0, 16, 0, 132),
	UDim2.new(0.25, -19, 0, 40)
)
local removeHidersButton = makeButton(
	npcPopulationCard,
	"Clear Hiders",
	Color3.fromRGB(122, 72, 79),
	UDim2.new(0.25, 5, 0, 132),
	UDim2.new(0.25, -14, 0, 40)
)
local spawnSeekerButton = makeButton(
	npcPopulationCard,
	"+1 Hunter",
	COLORS.orange,
	UDim2.new(0.5, 4, 0, 132),
	UDim2.new(0.25, -14, 0, 40)
)
local removeSeekersButton = makeButton(
	npcPopulationCard,
	"Clear Hunters",
	Color3.fromRGB(122, 72, 79),
	UDim2.new(0.75, 3, 0, 132),
	UDim2.new(0.25, -19, 0, 40)
)
local exactPopulationCard = makeCard(
	pages.NPC,
	"Exact NPC Composition",
	"Persists across rounds for this server session. The server enforces the combined limit.",
	256,
	3
)
addLabel(
	exactPopulationCard,
	"HIDERS",
	UDim2.fromOffset(16, 68),
	UDim2.new(0.5, -22, 0, 18),
	Enum.Font.GothamBold,
	9,
	COLORS.muted
)
addLabel(
	exactPopulationCard,
	"HUNTERS",
	UDim2.new(0.5, 6, 0, 68),
	UDim2.new(0.5, -22, 0, 18),
	Enum.Font.GothamBold,
	9,
	COLORS.muted
)
local npcHiderCountInput = makeInput(
	exactPopulationCard,
	"Hider count",
	UDim2.fromOffset(16, 88),
	UDim2.new(0.5, -22, 0, 40)
)
npcHiderCountInput.Text = "0"
local npcHunterCountInput = makeInput(
	exactPopulationCard,
	"Hunter count",
	UDim2.new(0.5, 6, 0, 88),
	UDim2.new(0.5, -22, 0, 40)
)
npcHunterCountInput.Text = "1"
local applyNpcPopulationButton = makeButton(
	exactPopulationCard,
	"Apply Exact Counts",
	COLORS.accent,
	UDim2.fromOffset(16, 142),
	UDim2.new(0.5, -22, 0, 42)
)
local onlyHuntersButton = makeButton(
	exactPopulationCard,
	"Only Hunters",
	COLORS.orange,
	UDim2.new(0.5, 6, 0, 142),
	UDim2.new(0.5, -22, 0, 42)
)
local automaticNpcPopulationButton = makeButton(
	exactPopulationCard,
	"Restore Automatic Population",
	COLORS.blue,
	UDim2.fromOffset(16, 198),
	UDim2.new(1, -32, 0, 42)
)
local npcAiCard = makeCard(
	pages.NPC,
	"Artificial Intelligence",
	"Pause or resume navigation for every managed round NPC.",
	136,
	4
)
local enableAiButton = makeButton(
	npcAiCard,
	"Enable AI",
	COLORS.green,
	UDim2.new(0, 16, 0, 76),
	UDim2.new(0.5, -22, 0, 42)
)
local disableAiButton = makeButton(
	npcAiCard,
	"Disable AI",
	COLORS.orange,
	UDim2.new(0.5, 6, 0, 76),
	UDim2.new(0.5, -22, 0, 42)
)

local requestButtons = {
	loadButton,
	addCoinsButton,
	removeCoinsButton,
	saveProfileButton,
	hiderButton,
	seekerButton,
	spectatorButton,
	healButton,
	movementButton,
	respawnButton,
	startRoundButton,
	endRoundButton,
	restartRoundButton,
	setTimeButton,
	fillNpcsButton,
	clearNpcsButton,
	spawnHiderButton,
	removeHidersButton,
	spawnSeekerButton,
	removeSeekersButton,
	applyNpcPopulationButton,
	onlyHuntersButton,
	automaticNpcPopulationButton,
	enableAiButton,
	disableAiButton,
}

local snapshot = nil
local requestBusy = false
local mobileLayout = false
local requestSequence = 0

local function updateHunterRoleButton()
	local round = if type(snapshot) == "table" then snapshot.Round else nil
	local locked = type(round) == "table" and round.BotSeekerMode == true
	seekerButton.Interactable = not requestBusy and not locked
	seekerButton.Active = not requestBusy and not locked
	seekerButton.TextTransparency = if requestBusy or locked then 0.42 else 0
end

local function setStatus(message, color)
	statusLabel.Text = message
	statusLabel.TextColor3 = color or COLORS.muted
	statusDot.BackgroundColor3 = color or COLORS.muted
end

local function setBusy(isBusy)
	requestBusy = isBusy
	for _, button in requestButtons do
		button.Interactable = not isBusy
		button.Active = not isBusy
		button.TextTransparency = if isBusy then 0.42 else 0
	end
	updateHunterRoleButton()
end

local function updateSnapshot(nextSnapshot)
	snapshot = nextSnapshot
	if type(snapshot) ~= "table" then
		targetSummary.Text = "No target snapshot loaded."
		playerStatusLabel.Text = "No snapshot loaded."
		roundStatusLabel.Text = "Round state unavailable."
		updateHunterRoleButton()
		return
	end

	local coinsText = if snapshot.CurrencyLoaded and snapshot.Coins ~= nil
		then formatInteger(snapshot.Coins)
		else "Not loaded"
	local displayName = tostring(snapshot.DisplayName or snapshot.TargetName or "Unknown")
	local username = tostring(snapshot.TargetName or "Unknown")
	if mobileLayout then
		targetSummary.Text = ("%s  @%s\nCoins: %s  ·  Role: %s"):format(
			displayName,
			username,
			coinsText,
			tostring(snapshot.Role or "Spectator")
		)
	else
		targetSummary.Text = ("%s  @%s\nUserId %s  ·  Coins %s  ·  Role %s"):format(
			displayName,
			username,
			tostring(snapshot.TargetUserId or "—"),
			coinsText,
			tostring(snapshot.Role or "Spectator")
		)
	end

	local aliveText = if snapshot.CharacterAlive then "Alive" else "No living character"
	playerStatusLabel.Text = ("%s  ·  Team: %s\nHealth: %s / %s  ·  Speed: %s  ·  Scale: %.2f\nCoins: %s"):format(
		aliveText,
		tostring(snapshot.Team or "None"),
		formatInteger(snapshot.Health),
		formatInteger(snapshot.MaxHealth),
		tostring(snapshot.WalkSpeed or 0),
		tonumber(snapshot.CharacterScale) or 0,
		coinsText
	)

	local round = snapshot.Round
	if type(round) == "table" then
		local exactPopulation = round.NpcPopulationOverrideEnabled == true
		local populationText = if exactPopulation
			then ("Exact: %s Hider / %s Hunter target"):format(
				formatInteger(round.NpcTargetHiders),
				formatInteger(round.NpcTargetSeekers)
			)
			else "Automatic"
		roundStatusLabel.Text = ("Phase: %s  ·  Remaining: %ss  ·  Arena: %s\nRoles: %s Hiders (%s caught)  ·  %s Hunters\nNPCs: %s/%s total (%s Hiders, %s Hunters)\nPopulation: %s  ·  AI: %s  ·  NPC Hunter mode: %s"):format(
			tostring(round.Phase or "Unavailable"),
			formatInteger(round.RemainingTime),
			tostring(round.ActiveArena or "None"),
			formatInteger(round.HiderCount),
			formatInteger(round.CaughtHiderCount),
			formatInteger(round.SeekerCount),
			formatInteger(round.NpcCount),
			formatInteger(round.MaxAdminNpcs),
			formatInteger(round.HiderNpcCount),
			formatInteger(round.SeekerNpcCount),
			populationText,
			if round.NpcAIEnabled == false then "Paused" else "Running",
			if round.BotSeekerMode == true then "On" else "Off"
		)
		if not npcHiderCountInput:IsFocused() then
			npcHiderCountInput.Text = tostring(if exactPopulation
				then math.floor(tonumber(round.NpcTargetHiders) or 0)
				else math.floor(tonumber(round.HiderNpcCount) or 0))
		end
		if not npcHunterCountInput:IsFocused() then
			npcHunterCountInput.Text = tostring(if exactPopulation
				then math.floor(tonumber(round.NpcTargetSeekers) or 0)
				else math.floor(tonumber(round.SeekerNpcCount) or 0))
		end
	else
		roundStatusLabel.Text = "Round state unavailable."
	end
	updateHunterRoleButton()
end

local function sendRequest(action, fields)
	if requestBusy then
		return
	end
	if TARGET_ACTIONS[action] and targetInput.Text == "" then
		setStatus("Enter an online player's UserId.", COLORS.red)
		return
	end

	local payload = {}
	if fields then
		for key, value in fields do
			payload[key] = value
		end
	end
	payload.Action = action
	payload.RequestId = HttpService:GenerateGUID(false):gsub("%-", "_")
	requestSequence += 1
	payload.Sequence = requestSequence
	if TARGET_ACTIONS[action] then
		payload.TargetUserId = targetInput.Text
	end

	setBusy(true)
	setStatus("Running a secure server request...", COLORS.orange)
	task.spawn(function()
		local invoked, result = pcall(function()
			return remote:InvokeServer(payload)
		end)
		setBusy(false)
		if not invoked or type(result) ~= "table" then
			setStatus("The server did not respond.", COLORS.red)
			return
		end
		if type(result.Snapshot) == "table" then
			updateSnapshot(result.Snapshot)
		elseif snapshot and type(result.Data) == "table" and type(result.Data.Round) == "table" then
			-- Global round/NPC actions return round-only data, so the selected
			-- player's card cannot accidentally switch back to the admin.
			snapshot.Round = result.Data.Round
			updateSnapshot(snapshot)
		end
		setStatus(
			tostring(result.Message or "Request completed."),
			if result.Ok then COLORS.green else COLORS.red
		)
	end)
end

local function selectTab(name)
	for pageName, page in pages do
		local selected = pageName == name
		page.Visible = selected
		local button = navButtons[pageName]
		local color = if selected then COLORS.accentSoft else COLORS.sidebar
		button.BackgroundColor3 = color
		button:SetAttribute("BaseColor", color)
	end
end

local function setPanelVisible(visible)
	overlay.Visible = visible
	launcher.Visible = not visible
	if visible then
		setStatus("Ready", COLORS.muted)
		task.defer(function()
			if overlay.Visible and not requestBusy then
				sendRequest("GetSnapshot")
			end
		end)
	end
end

local function applyResponsiveLayout()
	local camera = workspace.CurrentCamera
	local viewport = if camera then camera.ViewportSize else Vector2.new(1280, 720)
	mobileLayout = viewport.X < 760 or (UserInputService.TouchEnabled and viewport.X < 900)
	if mobileLayout then
		screenGui.IgnoreGuiInset = false
		launcher.Text = "ADMIN"
		launcher.Position = UDim2.new(1, -112, 1, -54)
		launcher.Size = UDim2.fromOffset(100, 42)
		panel.Size = UDim2.new(1, -10, 1, -10)
		panel.Position = UDim2.fromScale(0.5, 0.5)
		panelConstraint.MinSize = Vector2.new(300, 420)
		panelConstraint.MaxSize = Vector2.new(2000, 2000)
		header.Size = UDim2.new(1, 0, 0, 58)
		badge.Position = UDim2.fromOffset(10, 11)
		badge.Size = UDim2.fromOffset(36, 36)
		headerTitle.Text = "ADMIN CONTROL"
		headerTitle.Position = UDim2.fromOffset(56, 7)
		headerTitle.Size = UDim2.new(1, -164, 0, 44)
		headerTitle.TextSize = 14
		headerSubtitle.Visible = false
		closeButton.Position = UDim2.new(1, -100, 0, 11)
		closeButton.Size = UDim2.fromOffset(90, 36)

		targetBar.Position = UDim2.fromOffset(0, 58)
		targetBar.Size = UDim2.new(1, 0, 0, 92)
		targetInput.Position = UDim2.fromOffset(10, 25)
		targetInput.Size = UDim2.new(1, -126, 0, 38)
		loadButton.Position = UDim2.new(1, -108, 0, 25)
		loadButton.Size = UDim2.fromOffset(98, 38)
		targetSummary.Position = UDim2.fromOffset(10, 64)
		targetSummary.Size = UDim2.new(1, -20, 0, 27)
		targetSummary.TextSize = 10

		navigation.Position = UDim2.fromOffset(0, 150)
		navigation.Size = UDim2.new(1, 0, 0, 48)
		adminIdentity.Visible = false
		for index, name in navOrder do
			local button = navButtons[name]
			button.Position = UDim2.new((index - 1) / 5, 3, 0, 6)
			button.Size = UDim2.new(1 / 5, -6, 0, 36)
			button.Text = name
			button.TextSize = 10
			button.TextXAlignment = Enum.TextXAlignment.Center
		end

		content.Position = UDim2.fromOffset(0, 198)
		content.Size = UDim2.new(1, 0, 1, -198)

		roundStatusCard.Size = UDim2.new(1, 0, 0, 220)
		npcPopulationCard.Size = UDim2.new(1, 0, 0, 246)
		spawnHiderButton.Position = UDim2.fromOffset(16, 132)
		spawnHiderButton.Size = UDim2.new(0.5, -22, 0, 40)
		removeHidersButton.Position = UDim2.new(0.5, 6, 0, 132)
		removeHidersButton.Size = UDim2.new(0.5, -22, 0, 40)
		spawnSeekerButton.Position = UDim2.fromOffset(16, 184)
		spawnSeekerButton.Size = UDim2.new(0.5, -22, 0, 40)
		removeSeekersButton.Position = UDim2.new(0.5, 6, 0, 184)
		removeSeekersButton.Size = UDim2.new(0.5, -22, 0, 40)
	else
		screenGui.IgnoreGuiInset = true
		launcher.Text = "ADMIN  ·  F2"
		launcher.Position = UDim2.new(1, -154, 1, -62)
		launcher.Size = UDim2.fromOffset(140, 46)
		panel.Size = UDim2.fromScale(0.88, 0.86)
		panelConstraint.MinSize = Vector2.new(760, 520)
		panelConstraint.MaxSize = Vector2.new(1040, 700)
		header.Size = UDim2.new(1, 0, 0, 64)
		badge.Position = UDim2.fromOffset(16, 13)
		badge.Size = UDim2.fromOffset(38, 38)
		headerTitle.Text = "HIDE & SEEK CONTROL"
		headerTitle.Position = UDim2.fromOffset(66, 8)
		headerTitle.Size = UDim2.new(1, -200, 0, 27)
		headerTitle.TextSize = 16
		headerSubtitle.Visible = true
		closeButton.Position = UDim2.new(1, -112, 0, 14)
		closeButton.Size = UDim2.fromOffset(96, 36)

		targetBar.Position = UDim2.fromOffset(0, 64)
		targetBar.Size = UDim2.new(1, 0, 0, 80)
		targetInput.Position = UDim2.fromOffset(16, 27)
		targetInput.Size = UDim2.fromOffset(250, 40)
		loadButton.Position = UDim2.fromOffset(276, 27)
		loadButton.Size = UDim2.fromOffset(104, 40)
		targetSummary.Position = UDim2.fromOffset(398, 9)
		targetSummary.Size = UDim2.new(1, -414, 1, -18)
		targetSummary.TextSize = 12

		navigation.Position = UDim2.fromOffset(0, 144)
		navigation.Size = UDim2.new(0, 170, 1, -144)
		adminIdentity.Visible = true
		for index, name in navOrder do
			local button = navButtons[name]
			button.Position = UDim2.fromOffset(12, 16 + (index - 1) * 48)
			button.Size = UDim2.new(1, -24, 0, 40)
			button.Text = "  " .. name
			button.TextSize = 12
			button.TextXAlignment = Enum.TextXAlignment.Left
		end

		content.Position = UDim2.fromOffset(170, 144)
		content.Size = UDim2.new(1, -170, 1, -144)

		roundStatusCard.Size = UDim2.new(1, 0, 0, 158)
		npcPopulationCard.Size = UDim2.new(1, 0, 0, 190)
		spawnHiderButton.Position = UDim2.new(0, 16, 0, 132)
		spawnHiderButton.Size = UDim2.new(0.25, -19, 0, 40)
		removeHidersButton.Position = UDim2.new(0.25, 5, 0, 132)
		removeHidersButton.Size = UDim2.new(0.25, -14, 0, 40)
		spawnSeekerButton.Position = UDim2.new(0.5, 4, 0, 132)
		spawnSeekerButton.Size = UDim2.new(0.25, -14, 0, 40)
		removeSeekersButton.Position = UDim2.new(0.75, 3, 0, 132)
		removeSeekersButton.Size = UDim2.new(0.25, -19, 0, 40)
	end
	updateSnapshot(snapshot)
end

launcher.Activated:Connect(function()
	setPanelVisible(true)
end)
closeButton.Activated:Connect(function()
	setPanelVisible(false)
end)
for _, name in navOrder do
	navButtons[name].Activated:Connect(function()
		selectTab(name)
	end)
end

local function bindConfirmedAction(button, callback, captureValue)
	local normalText = button.Text
	local confirmationExpiresAt = 0
	local pendingValue = nil
	button.Activated:Connect(function()
		local now = os.clock()
		if now <= confirmationExpiresAt then
			confirmationExpiresAt = 0
			button.Text = normalText
			local confirmedValue = pendingValue
			pendingValue = nil
			callback(confirmedValue)
			return
		end
		confirmationExpiresAt = now + 3
		pendingValue = if captureValue then captureValue() else nil
		button.Text = "CONFIRM"
		setStatus("Press the same button again within 3 seconds.", COLORS.orange)
		task.delay(3, function()
			if confirmationExpiresAt > 0 and os.clock() >= confirmationExpiresAt then
				confirmationExpiresAt = 0
				pendingValue = nil
				button.Text = normalText
			end
		end)
	end)
end

loadButton.Activated:Connect(function()
	sendRequest("GetSnapshot")
end)
addCoinsButton.Activated:Connect(function()
	sendRequest("AddCoins", { Amount = amountInput.Text })
end)
bindConfirmedAction(
	removeCoinsButton,
	function(confirmedAmount)
		sendRequest("RemoveCoins", { Amount = confirmedAmount })
	end,
	function()
		return amountInput.Text
	end
)
saveProfileButton.Activated:Connect(function()
	sendRequest("SaveProfile")
end)
hiderButton.Activated:Connect(function()
	sendRequest("SetRole", { Role = "Hider" })
end)
seekerButton.Activated:Connect(function()
	sendRequest("SetRole", { Role = "Seeker" })
end)
spectatorButton.Activated:Connect(function()
	sendRequest("SetRole", { Role = "Spectator" })
end)
healButton.Activated:Connect(function()
	sendRequest("HealPlayer")
end)
movementButton.Activated:Connect(function()
	sendRequest("NormalizeMovement")
end)
bindConfirmedAction(respawnButton, function()
	sendRequest("RespawnPlayer")
end)
startRoundButton.Activated:Connect(function()
	sendRequest("StartRoundNow")
end)
bindConfirmedAction(endRoundButton, function()
	sendRequest("EndRound")
end)
bindConfirmedAction(restartRoundButton, function()
	sendRequest("RestartRound")
end)
setTimeButton.Activated:Connect(function()
	sendRequest("SetRemainingTime", { Seconds = secondsInput.Text })
end)
fillNpcsButton.Activated:Connect(function()
	sendRequest("FillNpcSlots")
end)
bindConfirmedAction(clearNpcsButton, function()
	sendRequest("ClearNpcs")
end)
spawnHiderButton.Activated:Connect(function()
	sendRequest("SpawnNpc", { Role = "Hider" })
end)
bindConfirmedAction(removeHidersButton, function()
	sendRequest("RemoveNpcs", { Role = "Hider" })
end)
spawnSeekerButton.Activated:Connect(function()
	sendRequest("SpawnNpc", { Role = "Seeker" })
end)
bindConfirmedAction(removeSeekersButton, function()
	sendRequest("RemoveNpcs", { Role = "Seeker" })
end)
bindConfirmedAction(
	applyNpcPopulationButton,
	function(confirmedCounts)
		sendRequest("SetNpcPopulation", {
			HiderCount = confirmedCounts.Hiders,
			SeekerCount = confirmedCounts.Hunters,
		})
	end,
	function()
		return {
			Hiders = npcHiderCountInput.Text,
			Hunters = npcHunterCountInput.Text,
		}
	end
)
bindConfirmedAction(
	onlyHuntersButton,
	function(confirmedHunterCount)
		npcHiderCountInput.Text = "0"
		sendRequest("SetNpcPopulation", {
			HiderCount = "0",
			SeekerCount = confirmedHunterCount,
		})
	end,
	function()
		local hunterCount = tonumber(npcHunterCountInput.Text)
		if not hunterCount or hunterCount < 1 then
			hunterCount = 1
			npcHunterCountInput.Text = "1"
		end
		return tostring(hunterCount)
	end
)
bindConfirmedAction(automaticNpcPopulationButton, function()
	sendRequest("ClearNpcPopulationOverride")
end)
enableAiButton.Activated:Connect(function()
	sendRequest("SetNpcAIEnabled", { Enabled = true })
end)
disableAiButton.Activated:Connect(function()
	sendRequest("SetNpcAIEnabled", { Enabled = false })
end)

UserInputService.InputBegan:Connect(function(input, processed)
	if processed then
		return
	end
	if input.KeyCode == Enum.KeyCode.F2 then
		setPanelVisible(not overlay.Visible)
	elseif input.KeyCode == Enum.KeyCode.Escape and overlay.Visible then
		setPanelVisible(false)
	end
end)

local dragging = false
local dragInput = nil
local dragStart = nil
local panelStart = nil

header.InputBegan:Connect(function(input)
	if mobileLayout then
		return
	end
	if input.UserInputType == Enum.UserInputType.MouseButton1
		or input.UserInputType == Enum.UserInputType.Touch then
		dragging = true
		dragInput = input
		dragStart = input.Position
		panelStart = panel.Position
	end
end)

UserInputService.InputChanged:Connect(function(input)
	if mobileLayout or not dragging or not dragInput or not dragStart or not panelStart then
		return
	end
	local mouseDrag = dragInput.UserInputType == Enum.UserInputType.MouseButton1
		and input.UserInputType == Enum.UserInputType.MouseMovement
	local touchDrag = dragInput.UserInputType == Enum.UserInputType.Touch and input == dragInput
	if mouseDrag or touchDrag then
		local delta = input.Position - dragStart
		panel.Position = UDim2.new(
			panelStart.X.Scale,
			panelStart.X.Offset + delta.X,
			panelStart.Y.Scale,
			panelStart.Y.Offset + delta.Y
		)
	end
end)

UserInputService.InputEnded:Connect(function(input)
	if input == dragInput
		or (dragInput
			and dragInput.UserInputType == Enum.UserInputType.MouseButton1
			and input.UserInputType == Enum.UserInputType.MouseButton1) then
		dragging = false
		dragInput = nil
	end
end)

local viewportConnection = nil
local function bindViewport()
	if viewportConnection then
		viewportConnection:Disconnect()
		viewportConnection = nil
	end
	local camera = workspace.CurrentCamera
	if camera then
		viewportConnection = camera:GetPropertyChangedSignal("ViewportSize"):Connect(
			applyResponsiveLayout
		)
	end
	applyResponsiveLayout()
end

workspace:GetPropertyChangedSignal("CurrentCamera"):Connect(bindViewport)
bindViewport()
selectTab("Overview")
task.delay(0.35, function()
	sendRequest("GetSnapshot")
end)
