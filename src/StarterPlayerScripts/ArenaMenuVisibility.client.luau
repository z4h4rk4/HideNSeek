--!strict

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local CooldownPassConfig = require(ReplicatedStorage:WaitForChild("CooldownPassConfig"))

local ROUND_STATE_NAME = "RoundState"
local ROLE_ATTRIBUTE = "RoundRole"
local ROLE_HIDER = "Hider"
local ROLE_SEEKER = "Seeker"
local PHASE_PREPARING = "Preparing"
local PHASE_STARTING = "Starting"
local PHASE_ROUND = "Round"

local BUTTON_NAMES: {[string]: boolean} = table.freeze({
	FreeBtn = true,
	InventoryBtn = true,
	SkinsBtn = true,
	ShopBtn = true,
	[CooldownPassConfig.PANEL_NAME] = true,
})

type ButtonState = {
	VisibleBeforeHide: boolean,
	HiddenByController: boolean,
	VisibleConnection: RBXScriptConnection,
}

local localPlayer = Players.LocalPlayer
local playerGui = localPlayer:WaitForChild("PlayerGui")
local roundState = ReplicatedStorage:WaitForChild(ROUND_STATE_NAME)
local buttonStates: {[GuiObject]: ButtonState} = {}

local function isCooldownPassPanel(button: GuiObject): boolean
	return button.Name == CooldownPassConfig.PANEL_NAME
end

local function isTopBarIcon(button: GuiObject): boolean
	local iconFrame = button.Parent
	local mainFrame = iconFrame and iconFrame.Parent
	local iconsGui = mainFrame and mainFrame.Parent
	return iconFrame ~= nil
		and iconFrame.Name == "IconFrame"
		and mainFrame ~= nil
		and mainFrame.Name == "MainFrame"
		and iconsGui ~= nil
		and iconsGui.Name == "IconsGui"
		and iconsGui:IsDescendantOf(playerGui)
end

local function shouldTrackButton(button: GuiObject): boolean
	if isCooldownPassPanel(button) then
		local iconsGui = playerGui:FindFirstChild("IconsGui")
		return iconsGui ~= nil and button:IsDescendantOf(iconsGui)
	end
	return isTopBarIcon(button)
end

local function shouldHideButtons(): boolean
	local role = localPlayer:GetAttribute(ROLE_ATTRIBUTE)
	if role ~= ROLE_HIDER and role ~= ROLE_SEEKER then
		return false
	end

	local phase = roundState:GetAttribute("Phase")
	return phase == PHASE_PREPARING or phase == PHASE_STARTING or phase == PHASE_ROUND
end

local function applyVisibility(button: GuiObject, state: ButtonState)
	if isCooldownPassPanel(button) then
		local hiddenForRound = shouldHideButtons()
		local ownsPass = localPlayer:GetAttribute(CooldownPassConfig.OWNED_ATTRIBUTE) == true
		state.HiddenByController = hiddenForRound
		button.Visible = not hiddenForRound and not ownsPass
		return
	end

	if shouldHideButtons() then
		if not state.HiddenByController then
			state.VisibleBeforeHide = button.Visible
			state.HiddenByController = true
		end
		button.Visible = false
	elseif state.HiddenByController then
		state.HiddenByController = false
		button.Visible = state.VisibleBeforeHide
	end
end

local function trackButton(instance: Instance)
	if not BUTTON_NAMES[instance.Name]
		or not instance:IsA("GuiObject")
		or buttonStates[instance]
		or not shouldTrackButton(instance :: GuiObject) then
		return
	end

	local button = instance :: GuiObject
	local state: ButtonState
	state = {
		VisibleBeforeHide = button.Visible,
		HiddenByController = false,
		VisibleConnection = button:GetPropertyChangedSignal("Visible"):Connect(function()
			if isCooldownPassPanel(button) then
				applyVisibility(button, state)
			elseif state.HiddenByController and button.Visible then
				button.Visible = false
			end
		end),
	}
	buttonStates[button] = state
	applyVisibility(button, state)
end

local function refreshButtons()
	for _, descendant in ipairs(playerGui:GetDescendants()) do
		trackButton(descendant)
	end
	for button, state in pairs(buttonStates) do
		if button:IsDescendantOf(playerGui) then
			applyVisibility(button, state)
		else
			state.VisibleConnection:Disconnect()
			buttonStates[button] = nil
		end
	end
end

playerGui.DescendantAdded:Connect(function(descendant)
	if BUTTON_NAMES[descendant.Name] then
		task.defer(trackButton, descendant)
	end
end)

playerGui.DescendantRemoving:Connect(function(descendant)
	local button = if descendant:IsA("GuiObject") then descendant else nil
	local state = if button then buttonStates[button] else nil
	if button and state then
		state.VisibleConnection:Disconnect()
		buttonStates[button] = nil
	end
end)

localPlayer:GetAttributeChangedSignal(ROLE_ATTRIBUTE):Connect(refreshButtons)
localPlayer:GetAttributeChangedSignal(CooldownPassConfig.OWNED_ATTRIBUTE):Connect(refreshButtons)
roundState:GetAttributeChangedSignal("Phase"):Connect(refreshButtons)

refreshButtons()
