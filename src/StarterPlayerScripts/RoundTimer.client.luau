--!strict

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local STATE_NAME = "RoundState"
local GUI_NAME = "RoundTimerGui"

local PHASE_WAITING = "Waiting"
local PHASE_STARTING = "Starting"
local PHASE_ROUND = "Round"
local PHASE_ENDED = "Ended"

local ROLE_HIDER = "Hider"
local ROLE_SEEKER = "Seeker"

local HIDER_COLOR = Color3.fromRGB(126, 255, 20)
local SEEKER_COLOR = Color3.fromRGB(255, 153, 28)
local EMPTY_COLOR = Color3.fromRGB(9, 12, 16)
local WHITE = Color3.fromRGB(255, 255, 255)
local BLACK = Color3.fromRGB(0, 0, 0)

local localPlayer = Players.LocalPlayer
local playerGui = localPlayer:WaitForChild("PlayerGui")
local roundState = ReplicatedStorage:WaitForChild(STATE_NAME)

local oldGui = playerGui:FindFirstChild(GUI_NAME)
if oldGui then
	oldGui:Destroy()
end

local screenGui = Instance.new("ScreenGui")
screenGui.Name = GUI_NAME
screenGui.DisplayOrder = 20
screenGui.IgnoreGuiInset = true
screenGui.ResetOnSpawn = false
screenGui.Parent = playerGui

local container = Instance.new("Frame")
container.Name = "Container"
container.AnchorPoint = Vector2.new(0.5, 0)
container.Position = UDim2.new(0.5, 0, 0, 12)
container.Size = UDim2.fromOffset(430, 154)
container.BackgroundTransparency = 1
container.Parent = screenGui

local phaseLabel = Instance.new("TextLabel")
phaseLabel.Name = "Phase"
phaseLabel.AnchorPoint = Vector2.new(0.5, 0)
phaseLabel.Position = UDim2.new(0.5, 0, 0, 0)
phaseLabel.Size = UDim2.fromOffset(330, 24)
phaseLabel.BackgroundTransparency = 1
phaseLabel.Font = Enum.Font.GothamBold
phaseLabel.Text = "WAITING FOR PLAYERS"
phaseLabel.TextColor3 = WHITE
phaseLabel.TextSize = 16
phaseLabel.TextStrokeColor3 = BLACK
phaseLabel.TextStrokeTransparency = 0
phaseLabel.Parent = container

local timerRow = Instance.new("Frame")
timerRow.Name = "TimerRow"
timerRow.AnchorPoint = Vector2.new(0.5, 0)
timerRow.Position = UDim2.new(0.5, 0, 0, 22)
timerRow.Size = UDim2.fromOffset(240, 62)
timerRow.BackgroundTransparency = 1
timerRow.Parent = container

local timerLayout = Instance.new("UIListLayout")
timerLayout.FillDirection = Enum.FillDirection.Horizontal
timerLayout.HorizontalAlignment = Enum.HorizontalAlignment.Center
timerLayout.VerticalAlignment = Enum.VerticalAlignment.Center
timerLayout.Padding = UDim.new(0, 8)
timerLayout.Parent = timerRow

local clockCircle = Instance.new("Frame")
clockCircle.Name = "Clock"
clockCircle.Size = UDim2.fromOffset(52, 52)
clockCircle.BackgroundColor3 = EMPTY_COLOR
clockCircle.BorderSizePixel = 0
clockCircle.LayoutOrder = 1
clockCircle.Parent = timerRow

local clockCorner = Instance.new("UICorner")
clockCorner.CornerRadius = UDim.new(1, 0)
clockCorner.Parent = clockCircle

local clockStroke = Instance.new("UIStroke")
clockStroke.Color = SEEKER_COLOR
clockStroke.Thickness = 4
clockStroke.Parent = clockCircle

local clockText = Instance.new("TextLabel")
clockText.Size = UDim2.fromScale(1, 1)
clockText.BackgroundTransparency = 1
clockText.Font = Enum.Font.GothamBlack
clockText.Text = "⏱"
clockText.TextColor3 = WHITE
clockText.TextScaled = true
clockText.Parent = clockCircle

local clockPadding = Instance.new("UIPadding")
clockPadding.PaddingTop = UDim.new(0, 5)
clockPadding.PaddingBottom = UDim.new(0, 5)
clockPadding.PaddingLeft = UDim.new(0, 5)
clockPadding.PaddingRight = UDim.new(0, 5)
clockPadding.Parent = clockText

local timerLabel = Instance.new("TextLabel")
timerLabel.Name = "Time"
timerLabel.Size = UDim2.fromOffset(160, 62)
timerLabel.BackgroundTransparency = 1
timerLabel.Font = Enum.Font.GothamBlack
timerLabel.Text = "0:15"
timerLabel.TextColor3 = WHITE
timerLabel.TextScaled = true
timerLabel.TextStrokeColor3 = BLACK
timerLabel.TextStrokeTransparency = 0
timerLabel.LayoutOrder = 2
timerLabel.Parent = timerRow

local timerPadding = Instance.new("UIPadding")
timerPadding.PaddingTop = UDim.new(0, 2)
timerPadding.PaddingBottom = UDim.new(0, 2)
timerPadding.Parent = timerLabel

local slotRow = Instance.new("Frame")
slotRow.Name = "RoleSlots"
slotRow.AnchorPoint = Vector2.new(0.5, 0)
slotRow.Position = UDim2.new(0.5, 0, 0, 88)
slotRow.Size = UDim2.fromOffset(350, 31)
slotRow.BackgroundTransparency = 1
slotRow.Parent = container

local slotLayout = Instance.new("UIListLayout")
slotLayout.FillDirection = Enum.FillDirection.Horizontal
slotLayout.HorizontalAlignment = Enum.HorizontalAlignment.Center
slotLayout.VerticalAlignment = Enum.VerticalAlignment.Center
slotLayout.Padding = UDim.new(0, 7)
slotLayout.Parent = slotRow

local hiderSlots: {Frame} = {}
local seekerSlots: {Frame} = {}

local function createSlot(layoutOrder: number): Frame
	local slot = Instance.new("Frame")
	slot.Name = `Slot{layoutOrder}`
	slot.Size = UDim2.fromOffset(28, 28)
	slot.BackgroundColor3 = EMPTY_COLOR
	slot.BorderSizePixel = 0
	slot.LayoutOrder = layoutOrder
	slot.Parent = slotRow

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(1, 0)
	corner.Parent = slot

	local stroke = Instance.new("UIStroke")
	stroke.Name = "Outline"
	stroke.Color = BLACK
	stroke.Thickness = 3
	stroke.Parent = slot

	local symbol = Instance.new("TextLabel")
	symbol.Name = "Symbol"
	symbol.Size = UDim2.fromScale(1, 1)
	symbol.BackgroundTransparency = 1
	symbol.Font = Enum.Font.GothamBlack
	symbol.Text = "+"
	symbol.TextColor3 = WHITE
	symbol.TextSize = 22
	symbol.TextStrokeColor3 = BLACK
	symbol.TextStrokeTransparency = 0
	symbol.Parent = slot

	return slot
end

local maxHiders = roundState:GetAttribute("MaxHiders")
local maxSeekers = roundState:GetAttribute("MaxSeekers")
local hiderCapacity = if type(maxHiders) == "number" then maxHiders else 6
local seekerCapacity = if type(maxSeekers) == "number" then maxSeekers else 2

for index = 1, hiderCapacity do
	table.insert(hiderSlots, createSlot(index))
end
for index = 1, seekerCapacity do
	table.insert(seekerSlots, createSlot(hiderCapacity + index))
end

local summaryLabel = Instance.new("TextLabel")
summaryLabel.Name = "Summary"
summaryLabel.AnchorPoint = Vector2.new(0.5, 0)
summaryLabel.Position = UDim2.new(0.5, 0, 0, 121)
summaryLabel.Size = UDim2.fromOffset(410, 20)
summaryLabel.BackgroundTransparency = 1
summaryLabel.Font = Enum.Font.GothamBold
summaryLabel.Text = "0/6 HIDERS   0/2 SEEKERS"
summaryLabel.TextColor3 = WHITE
summaryLabel.TextSize = 14
summaryLabel.TextStrokeColor3 = BLACK
summaryLabel.TextStrokeTransparency = 0
summaryLabel.Parent = container

local roleLabel = Instance.new("TextLabel")
roleLabel.Name = "YourRole"
roleLabel.AnchorPoint = Vector2.new(0.5, 0)
roleLabel.Position = UDim2.new(0.5, 0, 0, 140)
roleLabel.Size = UDim2.fromOffset(380, 18)
roleLabel.BackgroundTransparency = 1
roleLabel.Font = Enum.Font.GothamBold
roleLabel.Text = ""
roleLabel.TextSize = 13
roleLabel.TextStrokeColor3 = BLACK
roleLabel.TextStrokeTransparency = 0
roleLabel.Parent = container

local function setSlotState(slot: Frame, state: string, roleColor: Color3)
	local stroke = slot:FindFirstChild("Outline")
	local symbol = slot:FindFirstChild("Symbol")
	if stroke and stroke:IsA("UIStroke") then
		stroke.Color = if state == "Alive" then roleColor else BLACK
	end
	if symbol and symbol:IsA("TextLabel") then
		symbol.Text = if state == "Empty" then "+" else ""
	end
	slot.BackgroundColor3 = if state == "Empty" then Color3.fromRGB(18, 21, 25) else EMPTY_COLOR
end

local function readCount(attributeName: string): number
	local value = roundState:GetAttribute(attributeName)
	return if type(value) == "number" then math.max(0, math.floor(value)) else 0
end

local function updateRoleDisplay()
	local hiderCount = readCount("HiderCount")
	local caughtHiderCount = readCount("CaughtHiderCount")
	local seekerCount = readCount("SeekerCount")
	for index, slot in ipairs(hiderSlots) do
		local state = if index <= hiderCount
			then "Alive"
			elseif index <= hiderCount + caughtHiderCount then "Caught"
			else "Empty"
		setSlotState(slot, state, HIDER_COLOR)
	end
	for index, slot in ipairs(seekerSlots) do
		setSlotState(slot, if index <= seekerCount then "Alive" else "Empty", SEEKER_COLOR)
	end

	summaryLabel.Text = `{hiderCount}/{hiderCapacity} HIDERS · {caughtHiderCount} CAUGHT   `
		.. `{seekerCount}/{seekerCapacity} SEEKERS`

	local role = localPlayer:GetAttribute("RoundRole")
	if role == ROLE_HIDER then
		roleLabel.Text = "YOUR ROLE: HIDER"
		roleLabel.TextColor3 = HIDER_COLOR
	elseif role == ROLE_SEEKER then
		roleLabel.Text = "YOUR ROLE: SEEKER"
		roleLabel.TextColor3 = SEEKER_COLOR
	else
		roleLabel.Text = ""
	end
end

local function updatePhaseDisplay()
	local phase = roundState:GetAttribute("Phase")
	if phase == PHASE_STARTING then
		phaseLabel.Text = "ROUND STARTS IN"
		phaseLabel.TextColor3 = SEEKER_COLOR
	elseif phase == PHASE_ROUND then
		phaseLabel.Text = "ROUND"
		phaseLabel.TextColor3 = HIDER_COLOR
	elseif phase == PHASE_ENDED then
		phaseLabel.Text = "ROUND OVER"
		phaseLabel.TextColor3 = WHITE
	else
		phaseLabel.Text = "WAITING FOR PLAYERS"
		phaseLabel.TextColor3 = WHITE
	end
end

local function formatTime(seconds: number): string
	local wholeSeconds = math.max(0, math.ceil(seconds))
	local minutes = math.floor(wholeSeconds / 60)
	return string.format("%d:%02d", minutes, wholeSeconds % 60)
end

roundState:GetAttributeChangedSignal("HiderCount"):Connect(updateRoleDisplay)
roundState:GetAttributeChangedSignal("CaughtHiderCount"):Connect(updateRoleDisplay)
roundState:GetAttributeChangedSignal("SeekerCount"):Connect(updateRoleDisplay)
roundState:GetAttributeChangedSignal("Phase"):Connect(updatePhaseDisplay)
localPlayer:GetAttributeChangedSignal("RoundRole"):Connect(updateRoleDisplay)

updateRoleDisplay()
updatePhaseDisplay()

RunService.RenderStepped:Connect(function()
	local phase = roundState:GetAttribute("Phase")
	local endsAt = roundState:GetAttribute("EndsAt")
	if phase == PHASE_WAITING or type(endsAt) ~= "number" or endsAt <= 0 then
		timerLabel.Text = "--:--"
		return
	end
	timerLabel.Text = formatTime(endsAt - workspace:GetServerTimeNow())
end)
