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
local DISPLAY_REFRESH_SECONDS = 0.2

local localPlayer = Players.LocalPlayer
local playerGui = localPlayer:WaitForChild("PlayerGui")
local roundState = ReplicatedStorage:WaitForChild(ROUND_STATE_NAME)

local boundGui: ScreenGui? = nil
local titleLabel: TextLabel? = nil
local quantityLabel: TextLabel? = nil
local indicatorContainer: GuiObject? = nil
local indicatorTemplate: GuiObject? = nil
local indicatorListLayout: UIListLayout? = nil
local indicators: {GuiObject} = {}
local lastRoundParticipantCount = 0
local lastDebugState = ""

local function clearBinding()
	boundGui = nil
	titleLabel = nil
	quantityLabel = nil
	indicatorContainer = nil
	indicatorTemplate = nil
	indicatorListLayout = nil
	table.clear(indicators)
end

local function readWholeNumber(attributeName: string, fallback: number): number
	local value = roundState:GetAttribute(attributeName)
	return if type(value) == "number" then math.max(0, math.floor(value)) else fallback
end

local function getPlayerCapacity(): number
	return math.max(1, readWholeNumber("MaxHiders", 6))
end

local function bindRoundTopGui(guiInstance: Instance): boolean
	if not guiInstance:IsA("ScreenGui") then
		warn(`{GUI_NAME} must be a ScreenGui`)
		return false
	end

	local topFrame = guiInstance:WaitForChild(TOP_FRAME_NAME)
	local titleContainer = topFrame:WaitForChild(TITLE_CONTAINER_NAME)
	local titleInstance = titleContainer:WaitForChild(TITLE_NAME)
	local quantityFrame = topFrame:WaitForChild(PLAYER_QUANTITY_FRAME_NAME)
	local quantityTextInstance = topFrame:WaitForChild(PLAYER_QUANTITY_TEXT_NAME)
	local playerIndicator = quantityFrame:WaitForChild(PLAYER_INDICATOR_NAME)

	if not titleInstance:IsA("TextLabel") then
		warn(`{GUI_NAME}.{TOP_FRAME_NAME}.{TITLE_CONTAINER_NAME}.{TITLE_NAME} must be a TextLabel`)
		return false
	end
	if not quantityTextInstance:IsA("TextLabel") then
		warn(`{GUI_NAME}.{TOP_FRAME_NAME}.{PLAYER_QUANTITY_TEXT_NAME} must be a TextLabel`)
		return false
	end
	if not quantityFrame:IsA("GuiObject") then
		warn(`{GUI_NAME}.{TOP_FRAME_NAME}.{PLAYER_QUANTITY_FRAME_NAME} must be a GuiObject`)
		return false
	end
	if not playerIndicator:IsA("GuiObject") then
		warn(
			`{GUI_NAME}.{TOP_FRAME_NAME}.{PLAYER_QUANTITY_FRAME_NAME}.{PLAYER_INDICATOR_NAME} must be a GuiObject`
		)
		return false
	end

	guiInstance.ResetOnSpawn = false
	boundGui = guiInstance
	titleLabel = titleInstance
	quantityLabel = quantityTextInstance
	indicatorContainer = quantityFrame
	indicatorTemplate = playerIndicator
	indicatorListLayout = quantityFrame:FindFirstChildWhichIsA("UIListLayout")
	indicators = { playerIndicator }
	lastDebugState = ""

	quantityFrame.ClipsDescendants = false
	quantityFrame.AutomaticSize = Enum.AutomaticSize.X
	playerIndicator.Visible = true
	playerIndicator.LayoutOrder = 1

	for _, child in ipairs(quantityFrame:GetChildren()) do
		if child:GetAttribute(GENERATED_INDICATOR_ATTRIBUTE) == true then
			child:Destroy()
		end
	end

	return true
end

local function rebindCurrentRoundTopGui()
	local existing = playerGui:FindFirstChild(GUI_NAME)
	if existing and existing ~= boundGui and bindRoundTopGui(existing) then
		print(`[RoundTopGui] rebound to {existing:GetFullName()}`)
	end
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
	local container = indicatorContainer
	local template = indicatorTemplate
	if not container or not template then
		return
	end

	while #indicators < desiredCount do
		local clone = template:Clone() :: GuiObject
		clone.Name = `{PLAYER_INDICATOR_NAME}{#indicators + 1}`
		clone:SetAttribute(GENERATED_INDICATOR_ATTRIBUTE, true)
		clone.Parent = container
		table.insert(indicators, clone)
	end
	for index, indicator in ipairs(indicators) do
		indicator.LayoutOrder = index
		indicator.Visible = index <= desiredCount
	end

	local listLayout = indicatorListLayout
	if listLayout then
		task.defer(function()
			if container.Parent then
				local contentSize = listLayout.AbsoluteContentSize
				if contentSize.X > 0 then
					local currentSize = container.Size
					container.Size = UDim2.new(0, contentSize.X, currentSize.Y.Scale, currentSize.Y.Offset)
				end
			end
		end)
	end
end

local function updatePlayerDisplay()
	if not boundGui or boundGui.Parent ~= playerGui then
		clearBinding()
		rebindCurrentRoundTopGui()
	elseif not quantityLabel or not indicatorTemplate or not indicatorContainer then
		rebindCurrentRoundTopGui()
	end
	local label = quantityLabel
	if not label then
		return
	end

	local capacity = getPlayerCapacity()
	local phase = roundState:GetAttribute("Phase")
	local caughtCount = math.min(readWholeNumber("CaughtHiderCount", 0), capacity)
	local roleParticipantCount = math.min(readWholeNumber("HiderCount", 0) + caughtCount, capacity)
	local expectedParticipantCount = math.min(readWholeNumber("ExpectedHiderCount", #Players:GetPlayers()), capacity)
	local indicatorCount = expectedParticipantCount

	if phase == PHASE_STARTING or phase == PHASE_ROUND then
		if roleParticipantCount > 0 then
			indicatorCount = roleParticipantCount
			lastRoundParticipantCount = roleParticipantCount
		elseif expectedParticipantCount > 0 then
			indicatorCount = expectedParticipantCount
			lastRoundParticipantCount = expectedParticipantCount
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
	label.Text = `Players {aliveCount}/{capacity}:`
	ensureIndicatorCount(indicatorCount)
	for index, indicator in ipairs(indicators) do
		if index <= indicatorCount then
			setIndicatorColor(indicator, if index <= aliveCount then ALIVE_COLOR else CAUGHT_COLOR)
		end
	end

	local debugState =
		`{tostring(phase)}|{aliveCount}|{capacity}|{indicatorCount}|{caughtCount}|{tostring(boundGui)}`
	if debugState ~= lastDebugState then
		lastDebugState = debugState
		print(
			`[RoundTopGui] Phase={tostring(phase)} `
				.. `ExpectedHiderCount={readWholeNumber("ExpectedHiderCount", -1)} `
				.. `HiderCount={readWholeNumber("HiderCount", -1)} `
				.. `CaughtHiderCount={readWholeNumber("CaughtHiderCount", -1)} `
				.. `Indicators={indicatorCount} Text="{label.Text}"`
		)
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
	if not boundGui or boundGui.Parent ~= playerGui then
		clearBinding()
		rebindCurrentRoundTopGui()
	elseif not titleLabel then
		rebindCurrentRoundTopGui()
	end
	local label = titleLabel
	if not label then
		return
	end

	local phase = roundState:GetAttribute("Phase")
	local endsAt = roundState:GetAttribute("EndsAt")
	local remainingText = if type(endsAt) == "number" and endsAt > 0
		then formatTime(endsAt - workspace:GetServerTimeNow())
		else nil
	local timerText = remainingText or "0"

	local text: string
	if phase == PHASE_PREPARING then
		text = `Get Ready {timerText}`
	elseif phase == PHASE_STARTING then
		text = `Round Starts In {timerText}`
	elseif phase == PHASE_ROUND then
		text = `Round Ends In {timerText}`
	elseif phase == PHASE_ENDED then
		text = "Round Over"
	elseif phase == PHASE_WAITING then
		text = "Waiting For Players"
	else
		text = "Waiting For Players"
	end

	if label.Text ~= text then
		label.Text = text
	end
end

local function updateDisplay()
	if not boundGui or boundGui.Parent ~= playerGui then
		clearBinding()
		rebindCurrentRoundTopGui()
	end
	updatePlayerDisplay()
	updateTitle()
end

Players.PlayerAdded:Connect(function()
	task.defer(updateDisplay)
end)
Players.PlayerRemoving:Connect(function()
	task.defer(updateDisplay)
end)
localPlayer.CharacterAdded:Connect(function()
	task.defer(updateDisplay)
end)
playerGui.ChildAdded:Connect(function(child)
	if child.Name == GUI_NAME then
		task.defer(function()
			bindRoundTopGui(child)
			updateDisplay()
		end)
	end
end)

roundState:GetAttributeChangedSignal("MaxHiders"):Connect(updateDisplay)
roundState:GetAttributeChangedSignal("ExpectedHiderCount"):Connect(updateDisplay)
roundState:GetAttributeChangedSignal("HiderCount"):Connect(updateDisplay)
roundState:GetAttributeChangedSignal("CaughtHiderCount"):Connect(updateDisplay)
roundState:GetAttributeChangedSignal("NpcCount"):Connect(updateDisplay)
roundState:GetAttributeChangedSignal("NpcHiderCount"):Connect(updateDisplay)
roundState:GetAttributeChangedSignal("Phase"):Connect(updateDisplay)
roundState:GetAttributeChangedSignal("EndsAt"):Connect(updateDisplay)

bindRoundTopGui(playerGui:WaitForChild(GUI_NAME))
updateDisplay()

local displayRefreshElapsed = 0
RunService.RenderStepped:Connect(function(deltaTime)
	updateTitle()
	displayRefreshElapsed += deltaTime
	if displayRefreshElapsed >= DISPLAY_REFRESH_SECONDS then
		displayRefreshElapsed = 0
		updatePlayerDisplay()
	end
end)
