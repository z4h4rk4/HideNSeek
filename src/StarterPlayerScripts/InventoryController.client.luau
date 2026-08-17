--!strict

local Lighting = game:GetService("Lighting")
local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local ICONS_GUI_NAME = "IconsGui"
local ICONS_MAIN_FRAME_NAME = "MainFrame"
local ICON_FRAME_NAME = "IconFrame"
local INVENTORY_BUTTON_NAME = "InventoryBtn"
local INVENTORY_GUI_NAME = "InventoryGui"
local CLOSE_BUTTON_NAME = "CloseBtn"
local BLUR_NAME = "InventoryMenuBlur"
local BIND_TIMEOUT_SECONDS = 20
local MOBILE_MAX_WIDTH = 900
local OPEN_BLUR_SIZE = 18
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

local activeInventory: TargetGui? = nil
local activeContent: GuiObject? = nil
local activeCloseButton: GuiButton? = nil
local openButtonConnection: RBXScriptConnection? = nil
local closeButtonConnection: RBXScriptConnection? = nil
local descendantConnection: RBXScriptConnection? = nil
local bindRevision = 0
local isOpen = false
local hiddenMobileGuiStates: {[Instance]: GuiState} = {}
local originalContentStates: {[GuiObject]: ContentState} = {}
local contentScale: UIScale? = nil
local existingBlur = Lighting:FindFirstChild(BLUR_NAME)
local blur: BlurEffect? = if existingBlur and existingBlur:IsA("BlurEffect")
	then existingBlur
	else nil
if not blur then
	blur = Instance.new("BlurEffect")
	blur.Name = BLUR_NAME
	blur.Size = 0
	blur.Enabled = false
	blur.Parent = Lighting
end

local function isMobileViewport(): boolean
	local camera = Workspace.CurrentCamera
	local viewport = if camera then camera.ViewportSize else Vector2.new(1280, 720)
	return UserInputService.TouchEnabled and viewport.X <= MOBILE_MAX_WIDTH
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

local function isTargetVisible(target: TargetGui): boolean
	return if target:IsA("ScreenGui") then target.Enabled else target.Visible
end

local function findInventoryButton(): GuiButton?
	local iconsGui = playerGui:FindFirstChild(ICONS_GUI_NAME)
	local mainFrame = iconsGui and iconsGui:FindFirstChild(ICONS_MAIN_FRAME_NAME)
	local iconFrame = mainFrame and mainFrame:FindFirstChild(ICON_FRAME_NAME)
	local button = iconFrame and iconFrame:FindFirstChild(INVENTORY_BUTTON_NAME)
	return if button and button:IsA("GuiButton") then button else nil
end

local function findInventoryGui(): TargetGui?
	local child = playerGui:FindFirstChild(INVENTORY_GUI_NAME)
	if child and (child:IsA("ScreenGui") or child:IsA("GuiObject")) then
		return child
	end
	for _, descendant in ipairs(playerGui:GetDescendants()) do
		if descendant.Name == INVENTORY_GUI_NAME
			and (descendant:IsA("ScreenGui") or descendant:IsA("GuiObject")) then
			return descendant
		end
	end
	return nil
end

local function findCloseButton(target: TargetGui): GuiButton?
	local button = target:FindFirstChild(CLOSE_BUTTON_NAME, true)
	return if button and button:IsA("GuiButton") then button else nil
end

local function findContent(target: TargetGui): GuiObject?
	if target:IsA("GuiObject") then
		return target
	end

	local mainFrame = target:FindFirstChild(ICONS_MAIN_FRAME_NAME, true)
	if mainFrame and mainFrame:IsA("GuiObject") then
		return mainFrame
	end
	for _, descendant in ipairs(target:GetDescendants()) do
		if descendant:IsA("GuiObject") and descendant.Name ~= CLOSE_BUTTON_NAME then
			return descendant
		end
	end
	return nil
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
	if not blur then
		return
	end
	blur.Enabled = true
	TweenService:Create(
		blur,
		TweenInfo.new(0.18, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
		{ Size = size }
	):Play()
	if not enabled then
		task.delay(0.2, function()
			if blur and blur.Size <= 0.1 then
				blur.Enabled = false
			end
		end)
	end
end

local function hideMobileGui(target: TargetGui)
	if not isMobileViewport() then
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
	contentScale = getScale(content)
	contentScale.Scale = CLOSED_SCALE
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
		contentScale,
		TweenInfo.new(0.18, Enum.EasingStyle.Back, Enum.EasingDirection.Out),
		{ Scale = OVERSHOOT_SCALE }
	)
	local settle = TweenService:Create(
		contentScale,
		TweenInfo.new(0.11, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
		{ Scale = OPEN_SCALE }
	)
	grow.Completed:Once(function()
		if isOpen and contentScale then
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

local function closeInventory()
	local target = activeInventory
	local content = activeContent
	if not target or not isOpen then
		return
	end
	isOpen = false
	restoreMobileGui()
	tweenBlur(0, false)
	if content and content.Parent then
		animateClose(content, target)
	else
		setTargetVisible(target, false)
	end
end

local function openInventory()
	local target = activeInventory
	local content = activeContent
	if not target then
		return
	end
	if isOpen then
		closeInventory()
		return
	end
	isOpen = true
	hideMobileGui(target)
	setTargetVisible(target, true)
	tweenBlur(OPEN_BLUR_SIZE, true)
	if content and content.Parent then
		animateOpen(content)
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
	if descendantConnection then
		descendantConnection:Disconnect()
		descendantConnection = nil
	end
	activeInventory = nil
	activeContent = nil
	activeCloseButton = nil
end

local function bindControls()
	bindRevision += 1
	local revision = bindRevision
	disconnectControls()

	task.spawn(function()
		local deadline = os.clock() + BIND_TIMEOUT_SECONDS
		repeat
			local openButton = findInventoryButton()
			local inventory = findInventoryGui()
			local closeButton = if inventory then findCloseButton(inventory) else nil
			local content = if inventory then findContent(inventory) else nil
			if openButton and inventory and closeButton and content then
				if revision ~= bindRevision then
					return
				end
				activeInventory = inventory
				activeContent = content
				activeCloseButton = closeButton
				setTargetVisible(inventory, false)
				openButtonConnection = openButton.Activated:Connect(openInventory)
				closeButtonConnection = closeButton.Activated:Connect(closeInventory)
				descendantConnection = inventory.AncestryChanged:Connect(function()
					if not inventory:IsDescendantOf(playerGui) then
						restoreMobileGui()
						tweenBlur(0, false)
						task.defer(bindControls)
					end
				end)
				return
			end
			task.wait(0.1)
		until revision ~= bindRevision or os.clock() >= deadline

		if revision == bindRevision then
			warn(
				"InventoryController: expected PlayerGui.IconsGui.MainFrame.IconFrame.InventoryBtn "
					.. "and PlayerGui.InventoryGui.CloseBtn"
			)
		end
	end)
end

playerGui.DescendantAdded:Connect(function(descendant)
	if descendant.Name == INVENTORY_BUTTON_NAME
		or descendant.Name == INVENTORY_GUI_NAME
		or descendant.Name == CLOSE_BUTTON_NAME then
		task.defer(bindControls)
	end
end)

UserInputService.InputBegan:Connect(function(input, processed)
	if processed or not isOpen then
		return
	end
	if input.KeyCode == Enum.KeyCode.Escape then
		closeInventory()
	end
end)

Workspace:GetPropertyChangedSignal("CurrentCamera"):Connect(function()
	if isOpen and activeInventory then
		restoreMobileGui()
		hideMobileGui(activeInventory)
	end
end)

bindControls()
