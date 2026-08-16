--!strict

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local GUI_NAME = "RoundTopGui"
local TOP_FRAME_NAME = "TopFrame"
local TITLE_CONTAINER_NAME = "RoundStartsInLabel"
local TITLE_NAME = "Round Starts In"
local PLAYER_QUANTITY_FRAME_NAME = "PlayerQuantityFrame"
local PLAYER_QUANTITY_TEXT_NAME = "PlayerQuantityText"
local PLAYER_INDICATOR_NAME = "PlayerIndicator"
local ROUND_STATE_NAME = "RoundState"

local PHASE_WAITING = "Waiting"
local PHASE_PREPARING = "Preparing"
local PHASE_STARTING = "Starting"
local PHASE_ROUND = "Round"
local PHASE_ENDED = "Ended"

local ALIVE_COLOR = Color3.fromRGB(43, 232, 55)
local CAUGHT_COLOR = Color3.fromRGB(255, 76, 76)
local GENERATED_INDICATOR_ATTRIBUTE = "RoundTopGeneratedIndicator"

local localPlayer = Players.LocalPlayer
local playerGui = localPlayer:WaitForChild("PlayerGui")
local roundState = ReplicatedStorage:WaitForChild(ROUND_STATE_NAME)

local roundTopGui = playerGui:WaitForChild(GUI_NAME)
local topFrame = roundTopGui:WaitForChild(TOP_FRAME_NAME)
local titleContainer = topFrame:WaitForChild(TITLE_CONTAINER_NAME)
local titleInstance = titleContainer:WaitForChild(TITLE_NAME)
local quantityFrame = topFrame:WaitForChild(PLAYER_QUANTITY_FRAME_NAME)
local quantityTextInstance = topFrame:WaitForChild(PLAYER_QUANTITY_TEXT_NAME)
local playerIndicator = quantityFrame:WaitForChild(PLAYER_INDICATOR_NAME)

if not titleInstance:IsA("TextLabel") then
	warn(`{GUI_NAME}.{TOP_FRAME_NAME}.{TITLE_CONTAINER_NAME}.{TITLE_NAME} must be a TextLabel`)
	return
end
if not quantityTextInstance:IsA("TextLabel") then
	warn(
		`{GUI_NAME}.{TOP_FRAME_NAME}.{PLAYER_QUANTITY_TEXT_NAME} must be a TextLabel`
	)
	return
end
if not playerIndicator:IsA("GuiObject") then
	warn(
		`{GUI_NAME}.{TOP_FRAME_NAME}.{PLAYER_QUANTITY_FRAME_NAME}.{PLAYER_INDICATOR_NAME} must be a GuiObject`
	)
	return
end

local titleLabel = titleInstance :: TextLabel
local quantityLabel = quantityTextInstance :: TextLabel
local indicatorTemplate = playerIndicator :: GuiObject
local indicators: {GuiObject} = { indicatorTemplate }
local lastRoundParticipantCount = 0

for _, child in ipairs(quantityFrame:GetChildren()) do
	if child:GetAttribute(GENERATED_INDICATOR_ATTRIBUTE) == true then
		child:Destroy()
	end
end

local function readWholeNumber(attributeName: string, fallback: number): number
	local value = roundState:GetAttribute(attributeName)
	return if type(value) == "number" then math.max(0, math.floor(value)) else fallback
end

local function getPlayerCapacity(): number
	return math.max(1, readWholeNumber("MaxHiders", 6))
end

local function setIndicatorColor(indicator: GuiObject, color: Color3)
	if indicator:IsA("ImageLabel") then
		indicator.ImageColor3 = color
		indicator.BackgroundColor3 = color
	elseif indicator:IsA("ImageButton") then
		indicator.ImageColor3 = color
		indicator.BackgroundColor3 = color
	else
		indicator.BackgroundColor3 = color
	end
end

local function ensureIndicatorCount(desiredCount: number)
	while #indicators < desiredCount do
		local clone = indicatorTemplate:Clone() :: GuiObject
		clone.Name = `{PLAYER_INDICATOR_NAME}{#indicators + 1}`
		clone:SetAttribute(GENERATED_INDICATOR_ATTRIBUTE, true)
		clone.Parent = quantityFrame
		table.insert(indicators, clone)
	end
	for index, indicator in ipairs(indicators) do
		indicator.LayoutOrder = index
		indicator.Visible = index <= desiredCount
	end
end

local function updatePlayerDisplay()
	local humanPlayerCount = #Players:GetPlayers()
	local capacity = getPlayerCapacity()
	local displayedParticipantCount = math.min(humanPlayerCount, capacity)

	local phase = roundState:GetAttribute("Phase")
	local caughtCount = math.min(readWholeNumber("CaughtHiderCount", 0), capacity)
	local roleParticipantCount = math.min(
		readWholeNumber("HiderCount", 0)
			+ caughtCount,
		capacity
	)
	local indicatorCount = displayedParticipantCount
	if phase == PHASE_STARTING or phase == PHASE_ROUND then
		if roleParticipantCount > 0 then
			indicatorCount = roleParticipantCount
			lastRoundParticipantCount = roleParticipantCount
		end
	elseif phase == PHASE_ENDED and lastRoundParticipantCount > 0 then
		indicatorCount = lastRoundParticipantCount
	elseif phase == PHASE_WAITING then
		lastRoundParticipantCount = 0
		caughtCount = 0
	else
		caughtCount = 0
	end

	caughtCount = math.min(caughtCount, indicatorCount)
	local aliveCount = indicatorCount - caughtCount
	quantityLabel.Text = `Players {aliveCount}/{capacity}:`
	ensureIndicatorCount(indicatorCount)
	for index, indicator in ipairs(indicators) do
		if index <= indicatorCount then
			setIndicatorColor(indicator, if index <= aliveCount then ALIVE_COLOR else CAUGHT_COLOR)
		end
	end
end

local function formatTime(seconds: number): string
	local wholeSeconds = math.max(0, math.ceil(seconds))
	if wholeSeconds < 60 then
		return tostring(wholeSeconds)
	end
	return string.format("%d:%02d", math.floor(wholeSeconds / 60), wholeSeconds % 60)
end

local function updateTitle()
	local phase = roundState:GetAttribute("Phase")
	local endsAt = roundState:GetAttribute("EndsAt")
	local remainingText = if type(endsAt) == "number" and endsAt > 0
		then formatTime(endsAt - workspace:GetServerTimeNow())
		else nil

	local text: string
	if phase == PHASE_PREPARING then
		text = if remainingText then `Get Ready {remainingText}` else "Get Ready"
	elseif phase == PHASE_STARTING then
		text = if remainingText then `Round Starts In {remainingText}` else "Round Starts In"
	elseif phase == PHASE_ROUND then
		text = if remainingText then `Round Ends In {remainingText}` else "Round In Progress"
	elseif phase == PHASE_ENDED then
		text = "Round Over"
	elseif phase == PHASE_WAITING then
		text = "Waiting For Players"
	else
		text = "Round Starts In"
	end

	if titleLabel.Text ~= text then
		titleLabel.Text = text
	end
end

Players.PlayerAdded:Connect(function()
	task.defer(updatePlayerDisplay)
end)
Players.PlayerRemoving:Connect(function()
	task.defer(updatePlayerDisplay)
end)

roundState:GetAttributeChangedSignal("MaxHiders"):Connect(updatePlayerDisplay)
roundState:GetAttributeChangedSignal("HiderCount"):Connect(updatePlayerDisplay)
roundState:GetAttributeChangedSignal("CaughtHiderCount"):Connect(updatePlayerDisplay)
roundState:GetAttributeChangedSignal("Phase"):Connect(function()
	updatePlayerDisplay()
	updateTitle()
end)
roundState:GetAttributeChangedSignal("EndsAt"):Connect(updateTitle)

updatePlayerDisplay()
updateTitle()

RunService.RenderStepped:Connect(updateTitle)
