--!strict

local Lighting = game:GetService("Lighting")
local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local DEFAULT_BIND_TIMEOUT_SECONDS = 20
local DEFAULT_MOBILE_MAX_WIDTH = 900
local DEFAULT_OPEN_BLUR_SIZE = 18
local OPEN_SCALE = 1
local CLOSED_SCALE = 0.76
local OVERSHOOT_SCALE = 1.07

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

type TargetGui = ScreenGui | GuiObject
type GuiState = {
	Enabled: boolean?,
	Visible: boolean?,
}
type ContentState = {
	AnchorPoint: Vector2,
	Position: UDim2,
}

export type ModalHandle = {
	Open: () -> (),
	Close: () -> (),
	Toggle: () -> (),
	Rebind: () -> (),
	IsOpen: () -> boolean,
	GetOpenButton: () -> GuiButton?,
	GetTarget: () -> TargetGui?,
	GetContent: () -> GuiObject?,
}

export type ModalConfig = {
	Name: string,
	BindTimeoutSeconds: number?,
	MobileMaxWidth: number?,
	OpenBlurSize: number?,
	FindOpenButton: () -> GuiButton?,
	FindTarget: () -> TargetGui?,
	FindContent: (TargetGui) -> GuiObject?,
	FindCloseButton: (TargetGui) -> GuiButton?,
	ShouldRebind: ((Instance) -> boolean)?,
	Warning: string?,
	OnBound: ((ModalHandle, GuiButton, TargetGui, GuiObject, GuiButton) -> ())?,
	OnOpen: ((ModalHandle) -> ())?,
	OnClose: ((ModalHandle) -> ())?,
}

local ModalController = {}
local activeHandle: ModalHandle? = nil
local sharedBlur: BlurEffect? = nil

local function getBlur(): BlurEffect
	if sharedBlur and sharedBlur.Parent then
		return sharedBlur
	end

	local existing = Lighting:FindFirstChild("MenuModalBlur")
	if existing and existing:IsA("BlurEffect") then
		sharedBlur = existing
	else
		local blur = Instance.new("BlurEffect")
		blur.Name = "MenuModalBlur"
		blur.Size = 0
		blur.Enabled = false
		blur.Parent = Lighting
		sharedBlur = blur
	end
	return sharedBlur :: BlurEffect
end

local function isMobileViewport(maxWidth: number): boolean
	local camera = Workspace.CurrentCamera
	local viewport = if camera then camera.ViewportSize else Vector2.new(1280, 720)
	return UserInputService.TouchEnabled and viewport.X <= maxWidth
end

local function getTopLevelGui(target: TargetGui): Instance?
	if target:IsA("ScreenGui") then
		return target
	end
	local current: Instance? = target
	while current and current.Parent ~= playerGui do
		current = current.Parent
	end
	return current
end

local function setTargetVisible(target: TargetGui, visible: boolean)
	if target:IsA("ScreenGui") then
		target.Enabled = visible
	else
		target.Visible = visible
	end
end

local function getScale(content: GuiObject): UIScale
	local existing = content:FindFirstChildOfClass("UIScale")
	if existing then
		return existing
	end
	local scale = Instance.new("UIScale")
	scale.Scale = OPEN_SCALE
	scale.Parent = content
	return scale
end

local function tweenBlur(size: number, enabled: boolean)
	local blur = getBlur()
	blur.Enabled = true
	TweenService:Create(
		blur,
		TweenInfo.new(0.18, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
		{ Size = size }
	):Play()
	if not enabled then
		task.delay(0.2, function()
			if blur.Parent and blur.Size <= 0.1 then
				blur.Enabled = false
			end
		end)
	end
end

function ModalController.Bind(config: ModalConfig): ModalHandle
	local bindTimeoutSeconds = config.BindTimeoutSeconds or DEFAULT_BIND_TIMEOUT_SECONDS
	local mobileMaxWidth = config.MobileMaxWidth or DEFAULT_MOBILE_MAX_WIDTH
	local openBlurSize = config.OpenBlurSize or DEFAULT_OPEN_BLUR_SIZE
	local activeTarget: TargetGui? = nil
	local activeContent: GuiObject? = nil
	local activeOpenButton: GuiButton? = nil
	local openButtonConnection: RBXScriptConnection? = nil
	local closeButtonConnection: RBXScriptConnection? = nil
	local ancestryConnection: RBXScriptConnection? = nil
	local bindRevision = 0
	local isOpen = false
	local hiddenMobileGuiStates: {[Instance]: GuiState} = {}
	local originalContentStates: {[GuiObject]: ContentState} = {}
	local handle: ModalHandle

	local function hideMobileGui(target: TargetGui)
		if not isMobileViewport(mobileMaxWidth) then
			return
		end
		table.clear(hiddenMobileGuiStates)
		local topLevelGui = getTopLevelGui(target)
		for _, child in ipairs(playerGui:GetChildren()) do
			if child ~= topLevelGui then
				if child:IsA("ScreenGui") then
					hiddenMobileGuiStates[child] = { Enabled = child.Enabled }
					child.Enabled = false
				elseif child:IsA("GuiObject") then
					hiddenMobileGuiStates[child] = { Visible = child.Visible }
					child.Visible = false
				end
			end
		end
		if not target:IsA("ScreenGui") and target.Parent then
			for _, sibling in ipairs(target.Parent:GetChildren()) do
				if sibling ~= target and sibling:IsA("GuiObject") then
					hiddenMobileGuiStates[sibling] = { Visible = sibling.Visible }
					sibling.Visible = false
				end
			end
		end
	end

	local function restoreMobileGui()
		for instance, state in pairs(hiddenMobileGuiStates) do
			if instance.Parent then
				if instance:IsA("ScreenGui") and state.Enabled ~= nil then
					instance.Enabled = state.Enabled
				elseif instance:IsA("GuiObject") and state.Visible ~= nil then
					instance.Visible = state.Visible
				end
			end
		end
		table.clear(hiddenMobileGuiStates)
	end

	local function animateOpen(content: GuiObject)
		local scale = getScale(content)
		scale.Scale = CLOSED_SCALE
		if not originalContentStates[content] then
			originalContentStates[content] = {
				AnchorPoint = content.AnchorPoint,
				Position = content.Position,
			}
		end
		content.AnchorPoint = Vector2.new(0.5, 0.5)
		content.Position = UDim2.fromScale(0.5, 0.5)
		content.Visible = true

		local grow = TweenService:Create(
			scale,
			TweenInfo.new(0.18, Enum.EasingStyle.Back, Enum.EasingDirection.Out),
			{ Scale = OVERSHOOT_SCALE }
		)
		local settle = TweenService:Create(
			scale,
			TweenInfo.new(0.11, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
			{ Scale = OPEN_SCALE }
		)
		grow.Completed:Once(function()
			if isOpen and scale.Parent then
				settle:Play()
			end
		end)
		grow:Play()
	end

	local function animateClose(content: GuiObject, target: TargetGui)
		local scale = getScale(content)
		local shrink = TweenService:Create(
			scale,
			TweenInfo.new(0.13, Enum.EasingStyle.Quad, Enum.EasingDirection.In),
			{ Scale = CLOSED_SCALE }
		)
		shrink.Completed:Once(function()
			if not isOpen and target.Parent then
				setTargetVisible(target, false)
				scale.Scale = OPEN_SCALE
				local originalState = originalContentStates[content]
				if originalState then
					content.AnchorPoint = originalState.AnchorPoint
					content.Position = originalState.Position
				end
			end
		end)
		shrink:Play()
	end

	local function close()
		local target = activeTarget
		local content = activeContent
		if not target or not isOpen then
			return
		end
		isOpen = false
		if activeHandle == handle then
			activeHandle = nil
		end
		restoreMobileGui()
		tweenBlur(0, false)
		if content and content.Parent then
			animateClose(content, target)
		else
			setTargetVisible(target, false)
		end
		if config.OnClose then
			config.OnClose(handle)
		end
	end

	local function open()
		local target = activeTarget
		local content = activeContent
		if not target then
			return
		end
		if isOpen then
			close()
			return
		end
		if activeHandle and activeHandle ~= handle then
			activeHandle.Close()
		end
		activeHandle = handle
		isOpen = true
		hideMobileGui(target)
		setTargetVisible(target, true)
		tweenBlur(openBlurSize, true)
		if content and content.Parent then
			animateOpen(content)
		end
		if config.OnOpen then
			config.OnOpen(handle)
		end
	end

	local function disconnectControls()
		if openButtonConnection then
			openButtonConnection:Disconnect()
			openButtonConnection = nil
		end
		if closeButtonConnection then
			closeButtonConnection:Disconnect()
			closeButtonConnection = nil
		end
		if ancestryConnection then
			ancestryConnection:Disconnect()
			ancestryConnection = nil
		end
		activeTarget = nil
		activeContent = nil
		activeOpenButton = nil
	end

	local function bindControls()
		bindRevision += 1
		local revision = bindRevision
		disconnectControls()

		task.spawn(function()
			local deadline = os.clock() + bindTimeoutSeconds
			repeat
				local openButton = config.FindOpenButton()
				local target = config.FindTarget()
				local closeButton = if target then config.FindCloseButton(target) else nil
				local content = if target then config.FindContent(target) else nil
				if openButton and target and closeButton and content then
					if revision ~= bindRevision then
						return
					end
					activeTarget = target
					activeContent = content
					activeOpenButton = openButton
					setTargetVisible(target, false)
					openButtonConnection = openButton.Activated:Connect(open)
					closeButtonConnection = closeButton.Activated:Connect(close)
					ancestryConnection = target.AncestryChanged:Connect(function()
						if not target:IsDescendantOf(playerGui) then
							restoreMobileGui()
							tweenBlur(0, false)
							task.defer(bindControls)
						end
					end)
					if config.OnBound then
						config.OnBound(handle, openButton, target, content, closeButton)
					end
					return
				end
				task.wait(0.1)
			until revision ~= bindRevision or os.clock() >= deadline

			if revision == bindRevision then
				warn(config.Warning or `{config.Name}: modal controls were not found`)
			end
		end)
	end

	handle = {
		Open = open,
		Close = close,
		Toggle = open,
		Rebind = bindControls,
		IsOpen = function()
			return isOpen
		end,
		GetOpenButton = function()
			return activeOpenButton
		end,
		GetTarget = function()
			return activeTarget
		end,
		GetContent = function()
			return activeContent
		end,
	}

	playerGui.DescendantAdded:Connect(function(descendant)
		if not config.ShouldRebind or config.ShouldRebind(descendant) then
			task.defer(bindControls)
		end
	end)
	Workspace:GetPropertyChangedSignal("CurrentCamera"):Connect(function()
		if isOpen and activeTarget then
			restoreMobileGui()
			hideMobileGui(activeTarget)
		end
	end)
	UserInputService.InputBegan:Connect(function(input, processed)
		if processed or not isOpen then
			return
		end
		if input.KeyCode == Enum.KeyCode.Escape then
			close()
		end
	end)

	bindControls()
	return handle
end

return ModalController
