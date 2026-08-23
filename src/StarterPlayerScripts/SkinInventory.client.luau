--!strict

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage:WaitForChild("SkinCaseConfig"))
local remote = ReplicatedStorage:WaitForChild(Config.REMOTE_NAME) :: RemoteFunction

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

local INVENTORY_GUI_NAME = "InventoryGui"
local INVENTORY_MAIN_FRAME_NAME = "InventoryMainFrame"
local SCROLLING_FRAME_NAME = "ScrollingFrame"
local CARD_FRAME_NAME = "CardFrame"
local EQUIP_AREA_NAME = "EquipArea"
local SKIN_IMAGE_NAME = "SkinImage"
local SKIN_NAME_NAME = "SkinName"
local EQUIP_BUTTON_NAME = "EquipBtn"
local EQUIP_TEXT_NAME = "TextLabel"
local RARITY_BACKGROUND_NAME = "SkinRarityBackground"
local GENERATED_ATTRIBUTE = "GeneratedSkinInventoryCard"
local SELECTED_ATTRIBUTE = "SelectedSkinInventoryCard"
local DEFAULT_STROKE_COLOR_ATTRIBUTE = "SkinInventoryDefaultStrokeColor"
local DEFAULT_STROKE_TRANSPARENCY_ATTRIBUTE = "SkinInventoryDefaultStrokeTransparency"

local SELECTED_STROKE_COLOR = Color3.fromRGB(255, 255, 255)
local SELECTED_STROKE_TRANSPARENCY = 0
local EQUIPPED_BUTTON_COLOR = Color3.fromRGB(218, 48, 48)
local DEFAULT_EQUIP_BUTTON_COLOR = Color3.fromRGB(45, 120, 255)
local FOREGROUND_Z_OFFSET = 1

type SkinInfo = {
	Id: string,
	DisplayName: string,
	Rarity: string,
	Image: string,
	BackgroundImage: string,
}

type InventoryState = {
	OwnedSkins: {[string]: boolean},
	EquippedSkin: string?,
}

local skinById: {[string]: SkinInfo} = {}
local selectedSkinId: string? = nil
local state: InventoryState = {
	OwnedSkins = {},
	EquippedSkin = nil,
}
local bindingRevision = 0
local refreshQueued = false
local connections: {RBXScriptConnection} = {}
local templateCard: GuiObject? = nil
local defaultEquipButtonColor: Color3 = DEFAULT_EQUIP_BUTTON_COLOR

for _, caseDefinition in pairs(Config.CASES) do
	for _, skin in ipairs(caseDefinition.Skins) do
		local rarity = skin.Rarity
		skinById[skin.Id] = {
			Id = skin.Id,
			DisplayName = skin.DisplayName,
			Rarity = rarity,
			Image = Config.SKIN_IMAGES[skin.Id] or "",
			BackgroundImage = Config.RARITY_BACKGROUND_IMAGES[rarity] or "",
		}
	end
end

local function disconnect()
	for _, connection in ipairs(connections) do
		connection:Disconnect()
	end
	table.clear(connections)
end

local function invoke(action: string, payload)
	local ok, success, result = pcall(function()
		return remote:InvokeServer(action, payload)
	end)
	if not ok then
		return false, success
	end
	return success == true, result
end

local function findInventoryGui(): ScreenGui?
	local gui = playerGui:FindFirstChild(INVENTORY_GUI_NAME)
	return if gui and gui:IsA("ScreenGui") then gui else nil
end

local function findInventoryMainFrame(gui: ScreenGui): GuiObject?
	local mainFrame = gui:FindFirstChild(INVENTORY_MAIN_FRAME_NAME)
	return if mainFrame and mainFrame:IsA("GuiObject") then mainFrame else nil
end

local function findScrollingFrame(gui: ScreenGui): ScrollingFrame?
	local root = findInventoryMainFrame(gui) or gui
	local scrollingFrame = root:FindFirstChild(SCROLLING_FRAME_NAME, true)
	return if scrollingFrame and scrollingFrame:IsA("ScrollingFrame") then scrollingFrame else nil
end

local function findGuiObject(root: Instance?, name: string): GuiObject?
	local child = root and root:FindFirstChild(name, true)
	return if child and child:IsA("GuiObject") then child else nil
end

local function findText(root: Instance?, name: string): TextLabel?
	local child = root and root:FindFirstChild(name, true)
	return if child and child:IsA("TextLabel") then child else nil
end

local function findButton(root: Instance?, name: string): GuiButton?
	local child = root and root:FindFirstChild(name, true)
	return if child and child:IsA("GuiButton") then child else nil
end

local function setImage(guiObject: GuiObject?, image: string)
	if not guiObject then
		return
	end
	if guiObject:IsA("ImageLabel") or guiObject:IsA("ImageButton") then
		guiObject.Image = image
		guiObject.ImageRectOffset = Vector2.new(0, 0)
		guiObject.ImageRectSize = Vector2.new(0, 0)
	end
end

local function keepDescendantsAboveBackground(area: GuiObject, background: GuiObject)
	local foregroundZIndex = background.ZIndex + FOREGROUND_Z_OFFSET
	for _, descendant in ipairs(area:GetDescendants()) do
		if descendant:IsA("GuiObject")
			and descendant ~= background
			and not descendant:IsDescendantOf(background) then
			descendant.ZIndex = math.max(descendant.ZIndex, foregroundZIndex)
		end
	end
end

local function setBackgroundImage(area: GuiObject, image: string)
	setImage(area, image)
	if area:IsA("ImageLabel") or area:IsA("ImageButton") then
		return
	end

	local background = area:FindFirstChild(RARITY_BACKGROUND_NAME)
	if not background or not background:IsA("ImageLabel") then
		background = Instance.new("ImageLabel")
		background.Name = RARITY_BACKGROUND_NAME
		background.BackgroundTransparency = 1
		background.BorderSizePixel = 0
		background.Size = UDim2.fromScale(1, 1)
		background.Position = UDim2.fromScale(0, 0)
		background.Active = false
		background.Selectable = false
		background.ScaleType = Enum.ScaleType.Stretch
		local corner = area:FindFirstChildOfClass("UICorner")
		if corner then
			corner:Clone().Parent = background
		end
		background.Parent = area
	end
	background.ZIndex = area.ZIndex
	background.Image = image
	background.ImageRectOffset = Vector2.new(0, 0)
	background.ImageRectSize = Vector2.new(0, 0)
	keepDescendantsAboveBackground(area, background)
end

local function getOrCreateSelectionStroke(target: GuiObject): UIStroke
	local stroke = target:FindFirstChildOfClass("UIStroke")
	if not stroke then
		stroke = Instance.new("UIStroke")
		stroke.Name = "SkinSelectionStroke"
		stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
		stroke.Thickness = 2
		stroke.Transparency = 1
		stroke.Parent = target
	end
	if target:GetAttribute(DEFAULT_STROKE_COLOR_ATTRIBUTE) == nil then
		target:SetAttribute(DEFAULT_STROKE_COLOR_ATTRIBUTE, stroke.Color)
		target:SetAttribute(DEFAULT_STROKE_TRANSPARENCY_ATTRIBUTE, stroke.Transparency)
	end
	return stroke
end

local function applySelectionStroke(target: GuiObject, selected: boolean)
	local stroke = getOrCreateSelectionStroke(target)
	if selected then
		stroke.Color = SELECTED_STROKE_COLOR
		stroke.Transparency = SELECTED_STROKE_TRANSPARENCY
		return
	end

	local defaultColor = target:GetAttribute(DEFAULT_STROKE_COLOR_ATTRIBUTE)
	local defaultTransparency = target:GetAttribute(DEFAULT_STROKE_TRANSPARENCY_ATTRIBUTE)
	stroke.Color = if typeof(defaultColor) == "Color3" then defaultColor else SELECTED_STROKE_COLOR
	stroke.Transparency = if type(defaultTransparency) == "number" then defaultTransparency else 1
end

local function connectGuiActivation(target: GuiObject, callback: () -> ())
	target.Active = true
	if target:IsA("GuiButton") then
		table.insert(connections, target.Activated:Connect(callback))
		return
	end
	table.insert(connections, target.InputBegan:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1
			or input.UserInputType == Enum.UserInputType.Touch then
			callback()
		end
	end))
end

local function connectActivationIfPresent(root: Instance, name: string, callback: () -> ())
	local object = findGuiObject(root, name)
	if object then
		connectGuiActivation(object, callback)
	end
end

local function connectActivationWithin(root: GuiObject, callback: () -> ())
	connectGuiActivation(root, callback)
	local background = root:FindFirstChild(RARITY_BACKGROUND_NAME)
	for _, descendant in ipairs(root:GetDescendants()) do
		if descendant:IsA("GuiObject")
			and descendant.Name ~= RARITY_BACKGROUND_NAME
			and (not background or not descendant:IsDescendantOf(background)) then
			connectGuiActivation(descendant, callback)
		end
	end
end

local function getMainEquipArea(gui: ScreenGui): GuiObject?
	local mainFrame = findInventoryMainFrame(gui)
	local direct = mainFrame and mainFrame:FindFirstChild(EQUIP_AREA_NAME)
	if direct and direct:IsA("GuiObject") then
		return direct
	end

	local scrollingFrame = findScrollingFrame(gui)
	local root = mainFrame or gui
	for _, descendant in ipairs(root:GetDescendants()) do
		if descendant.Name == EQUIP_AREA_NAME
			and descendant:IsA("GuiObject")
			and (not scrollingFrame or not descendant:IsDescendantOf(scrollingFrame)) then
			return descendant
		end
	end
	return nil
end

local function getOwnedSkinIds(): {string}
	local skinIds: {string} = {}
	for skinId, owned in pairs(state.OwnedSkins) do
		if owned == true and skinById[skinId] then
			table.insert(skinIds, skinId)
		end
	end
	table.sort(skinIds, function(left, right)
		return skinById[left].DisplayName < skinById[right].DisplayName
	end)
	return skinIds
end

local function applySkinToArea(area: GuiObject, skinInfo: SkinInfo)
	setBackgroundImage(area, skinInfo.BackgroundImage)
	setImage(findGuiObject(area, SKIN_IMAGE_NAME), skinInfo.Image)
	local skinName = findText(area, SKIN_NAME_NAME)
	if skinName then
		skinName.Text = skinInfo.DisplayName
	end
	area:SetAttribute("SkinId", skinInfo.Id)
	area:SetAttribute("SkinRarity", skinInfo.Rarity)
end

local refreshInventory: () -> ()

local function isGeneratedCardDescendant(instance: Instance): boolean
	local current: Instance? = instance
	while current and current ~= playerGui do
		if current:GetAttribute(GENERATED_ATTRIBUTE) == true then
			return true
		end
		current = current.Parent
	end
	return false
end

local function scheduleRefresh()
	if refreshQueued then
		return
	end
	refreshQueued = true
	task.defer(function()
		refreshQueued = false
		refreshInventory()
	end)
end

local function selectSkin(skinId: string)
	if not state.OwnedSkins[skinId] then
		return
	end
	if selectedSkinId == skinId then
		return
	end
	selectedSkinId = skinId
	refreshInventory()
end

local function equipSelected()
	local skinId = selectedSkinId
	if not skinId or state.EquippedSkin == skinId then
		return
	end
	local success, result = invoke("EquipSkin", {
		SkinId = skinId,
	})
	if not success then
		warn(`[SkinInventory] Equip failed: {tostring(result)}`)
		return
	end
	if type(result) == "table" then
		state.OwnedSkins = if type(result.OwnedSkins) == "table" then result.OwnedSkins else state.OwnedSkins
		state.EquippedSkin = if type(result.EquippedSkin) == "string" then result.EquippedSkin else nil
	end
	refreshInventory()
end

local function clearGeneratedCards(scrollingFrame: ScrollingFrame)
	for _, child in ipairs(scrollingFrame:GetChildren()) do
		if child:IsA("GuiObject") and child:GetAttribute(GENERATED_ATTRIBUTE) == true then
			child:Destroy()
		end
	end
end

local function renderCard(card: GuiObject, skinInfo: SkinInfo, order: number)
	card.Name = `Card_{skinInfo.Id}`
	card.LayoutOrder = order
	card.Visible = true
	card:SetAttribute("SkinId", skinInfo.Id)
	card:SetAttribute(SELECTED_ATTRIBUTE, selectedSkinId == skinInfo.Id)

	local equipArea = findGuiObject(card, EQUIP_AREA_NAME) or card
	local selected = selectedSkinId == skinInfo.Id
	applySkinToArea(equipArea, skinInfo)
	applySelectionStroke(equipArea, selected)
	card:SetAttribute(SELECTED_ATTRIBUTE, selected)

	local function activate()
		selectSkin(skinInfo.Id)
	end
	connectActivationWithin(equipArea, activate)
	if card ~= equipArea then
		connectGuiActivation(card, activate)
	end
end

local function renderMainEquipArea(gui: ScreenGui)
	local area = getMainEquipArea(gui)
	if not area then
		return
	end

	local skinId = selectedSkinId
	local skinInfo = if skinId then skinById[skinId] else nil
	if not skinInfo then
		area.Visible = false
		return
	end

	area.Visible = true
	applySkinToArea(area, skinInfo)

	local equipButton = findButton(area, EQUIP_BUTTON_NAME)
	local label = findText(equipButton, EQUIP_TEXT_NAME) or findText(area, EQUIP_TEXT_NAME)
	local equipped = state.EquippedSkin == skinInfo.Id
	if equipButton then
		if equipButton:GetAttribute("SkinInventoryDefaultColorCaptured") ~= true then
			defaultEquipButtonColor = equipButton.BackgroundColor3
			equipButton:SetAttribute("SkinInventoryDefaultColorCaptured", true)
		end
		equipButton.Active = true
		equipButton.AutoButtonColor = not equipped
		equipButton.BackgroundColor3 = if equipped then EQUIPPED_BUTTON_COLOR else defaultEquipButtonColor
		table.insert(connections, equipButton.Activated:Connect(equipSelected))
	end
	if label then
		label.Text = if equipped then "EQUIPPED" else "EQUIP"
	end
end

refreshInventory = function()
	local gui = findInventoryGui()
	if not gui then
		return
	end
	local scrollingFrame = findScrollingFrame(gui)
	if not scrollingFrame then
		return
	end

	disconnect()
	local cardTemplate = if templateCard and templateCard.Parent == scrollingFrame
		then templateCard
		else findGuiObject(scrollingFrame, CARD_FRAME_NAME)
	if not cardTemplate then
		return
	end
	templateCard = cardTemplate
	clearGeneratedCards(scrollingFrame)

	local ownedSkinIds = getOwnedSkinIds()
	if (#ownedSkinIds > 0 and (not selectedSkinId or not state.OwnedSkins[selectedSkinId])) then
		selectedSkinId = if state.EquippedSkin and state.OwnedSkins[state.EquippedSkin]
			then state.EquippedSkin
			else ownedSkinIds[1]
	end

	cardTemplate.Visible = false
	for index, skinId in ipairs(ownedSkinIds) do
		local skinInfo = skinById[skinId]
		local card = cardTemplate:Clone()
		card:SetAttribute(GENERATED_ATTRIBUTE, true)
		renderCard(card, skinInfo, index)
		card.Parent = scrollingFrame
	end

	renderMainEquipArea(gui)
end

local function applyState(payload)
	if type(payload) ~= "table" then
		return
	end
	if type(payload.OwnedSkins) == "table" then
		state.OwnedSkins = payload.OwnedSkins
	end
	state.EquippedSkin = if type(payload.EquippedSkin) == "string" then payload.EquippedSkin else nil
	refreshInventory()
end

local function requestState()
	local success, payload = invoke("GetState", nil)
	if success then
		applyState(payload)
	end
end

player:GetAttributeChangedSignal("EquippedSkin"):Connect(requestState)
for skinId in pairs(skinById) do
	player:GetAttributeChangedSignal(`SkinOwned_{skinId}`):Connect(requestState)
end

playerGui.DescendantAdded:Connect(function(descendant)
	if isGeneratedCardDescendant(descendant) then
		return
	end
	if descendant.Name == INVENTORY_GUI_NAME
		or descendant.Name == SCROLLING_FRAME_NAME
		or descendant.Name == CARD_FRAME_NAME
		or descendant.Name == EQUIP_AREA_NAME
		or descendant.Name == SKIN_IMAGE_NAME
		or descendant.Name == SKIN_NAME_NAME
		or descendant.Name == EQUIP_BUTTON_NAME then
		scheduleRefresh()
	end
end)

playerGui.DescendantRemoving:Connect(function(descendant)
	local gui = findInventoryGui()
	local scrollingFrame = if gui then findScrollingFrame(gui) else nil
	if scrollingFrame and (descendant == scrollingFrame or descendant:IsAncestorOf(scrollingFrame)) then
		scheduleRefresh()
	end
end)

task.spawn(requestState)
