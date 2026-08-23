--!strict

local Players = game:GetService("Players")
local ProximityPromptService = game:GetService("ProximityPromptService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local ModalController = require(script.Parent:WaitForChild("ModalController"))
local CashProductConfig = require(ReplicatedStorage:WaitForChild("CashProductConfig"))
local SkinCaseConfig = require(ReplicatedStorage:WaitForChild("SkinCaseConfig"))

local ICONS_GUI_NAME = "IconsGui"
local ICONS_MAIN_FRAME_NAME = "MainFrame"
local ICON_FRAME_NAME = "IconFrame"
local MONEY_PANEL_NAME = "MoneyPanel"
local PLUS_BUTTON_NAME = "PlusBtn"
local CLOSE_BUTTON_NAME = "CloseBtn"

local INVENTORY_BUTTON_NAME = "InventoryBtn"
local INVENTORY_GUI_NAME = "InventoryGui"

local SKINS_BUTTON_NAME = "SkinsBtn"
local SKIN_SHOP_GUI_NAME = "SkinShopGui"
local SKINS_MAIN_FRAME_NAME = "SkinsMainFrame"

local SHOP_BUTTON_NAME = "ShopBtn"
local SHOP_GUI_NAME = "ShopGui"
local SHOP_MAIN_FRAME_NAME = "ShopMainFrame"
local SHOP_SCROLLING_FRAME_NAME = "ScrollingFrame"
local CASH_FRAME_NAME = "Cash"

local LIKE_REWARD_REMOTE_NAME = "LikeRewardRemote"
local FREE_BUTTON_NAME = "FreeBtn"
local FREE_GUI_NAME = "FreeGui"
local FREE_FRAME_NAME = "FreeFrame"

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

type TargetGui = ScreenGui | GuiObject
type ShopModalHandle = {
	Open: () -> (),
	Close: () -> (),
	IsOpen: () -> boolean,
}

local function findTopBarButton(buttonName: string): GuiButton?
	local iconsGui = playerGui:FindFirstChild(ICONS_GUI_NAME)
	local mainFrame = iconsGui and iconsGui:FindFirstChild(ICONS_MAIN_FRAME_NAME)
	local iconFrame = mainFrame and mainFrame:FindFirstChild(ICON_FRAME_NAME)
	local button = iconFrame and iconFrame:FindFirstChild(buttonName)
	return if button and button:IsA("GuiButton") then button else nil
end

local function findIconsMoneyPlusButton(): GuiButton?
	local iconsGui = playerGui:FindFirstChild(ICONS_GUI_NAME)
	local mainFrame = iconsGui and iconsGui:FindFirstChild(ICONS_MAIN_FRAME_NAME)
	local moneyPanel = mainFrame and mainFrame:FindFirstChild(MONEY_PANEL_NAME)
	local button = moneyPanel and moneyPanel:FindFirstChild(PLUS_BUTTON_NAME)
	return if button and button:IsA("GuiButton") then button else nil
end

local function findSkinsMoneyPlusButton(): GuiButton?
	local skinShopGui = playerGui:FindFirstChild(SKIN_SHOP_GUI_NAME)
	local skinsMainFrame = skinShopGui and skinShopGui:FindFirstChild(SKINS_MAIN_FRAME_NAME, true)
	local moneyPanel = skinsMainFrame and skinsMainFrame:FindFirstChild(MONEY_PANEL_NAME, true)
	local button = moneyPanel and moneyPanel:FindFirstChild(PLUS_BUTTON_NAME, true)
	return if button and button:IsA("GuiButton") then button else nil
end

local function findTargetGui(guiName: string): TargetGui?
	local child = playerGui:FindFirstChild(guiName)
	if child and (child:IsA("ScreenGui") or child:IsA("GuiObject")) then
		return child
	end
	for _, descendant in ipairs(playerGui:GetDescendants()) do
		if descendant.Name == guiName
			and (descendant:IsA("ScreenGui") or descendant:IsA("GuiObject")) then
			return descendant
		end
	end
	return nil
end

local function findNamedContent(target: TargetGui, contentName: string): GuiObject?
	local content = target:FindFirstChild(contentName, true)
	if content and content:IsA("GuiObject") then
		return content
	end
	if target:IsA("GuiObject") then
		return target
	end
	return nil
end

local function findFirstContent(target: TargetGui): GuiObject?
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

local function findCloseButton(target: TargetGui, content: GuiObject?): GuiButton?
	local root = content or target
	local button = root:FindFirstChild(CLOSE_BUTTON_NAME, true)
	return if button and button:IsA("GuiButton") then button else nil
end

local function bindStandardModal(
	name: string,
	buttonName: string,
	guiName: string,
	contentName: string?
)
	return ModalController.Bind({
		Name = name,
		FindOpenButton = function()
			return findTopBarButton(buttonName)
		end,
		FindTarget = function()
			return findTargetGui(guiName)
		end,
		FindContent = function(target: TargetGui): GuiObject?
			return if contentName then findNamedContent(target, contentName) else findFirstContent(target)
		end,
		FindCloseButton = function(target: TargetGui): GuiButton?
			local content = if contentName then findNamedContent(target, contentName) else findFirstContent(target)
			return findCloseButton(target, content)
		end,
		ShouldRebind = function(descendant: Instance): boolean
			return descendant.Name == buttonName
				or descendant.Name == guiName
				or descendant.Name == contentName
				or descendant.Name == CLOSE_BUTTON_NAME
		end,
		Warning = `{name}: expected PlayerGui.IconsGui.MainFrame.IconFrame.{buttonName} `
			.. `and PlayerGui.{guiName}.{if contentName then contentName .. "." else ""}CloseBtn`,
	})
end

local function findShopScrollingFrame(): ScrollingFrame?
	local shopGui = playerGui:FindFirstChild(SHOP_GUI_NAME)
	local shopMainFrame = shopGui and shopGui:FindFirstChild(SHOP_MAIN_FRAME_NAME, true)
	local scrollingFrame = shopMainFrame and shopMainFrame:FindFirstChild(SHOP_SCROLLING_FRAME_NAME, true)
	return if scrollingFrame and scrollingFrame:IsA("ScrollingFrame") then scrollingFrame else nil
end

local function revealCashFrame()
	local scrollingFrame = findShopScrollingFrame()
	if not scrollingFrame then
		return
	end

	local cashFrame = scrollingFrame:FindFirstChild(CASH_FRAME_NAME, true)
	if not cashFrame or not cashFrame:IsA("GuiObject") then
		return
	end

	cashFrame.Visible = true
	task.defer(function()
		if not scrollingFrame.Parent or not cashFrame.Parent then
			return
		end

		local targetY = cashFrame.AbsolutePosition.Y
			- scrollingFrame.AbsolutePosition.Y
			+ scrollingFrame.CanvasPosition.Y
		local maxY = math.max(0, scrollingFrame.AbsoluteCanvasSize.Y - scrollingFrame.AbsoluteWindowSize.Y)
		scrollingFrame.CanvasPosition = Vector2.new(
			scrollingFrame.CanvasPosition.X,
			math.clamp(targetY, 0, maxY)
		)
	end)
end

local function findSkinCaseScrollingFrame(): ScrollingFrame?
	local skinShopGui = playerGui:FindFirstChild(SKIN_SHOP_GUI_NAME)
	local skinsMainFrame = skinShopGui and skinShopGui:FindFirstChild(SKINS_MAIN_FRAME_NAME, true)
	local scrollingFrame = skinsMainFrame
		and skinsMainFrame:FindFirstChild(SkinCaseConfig.YOU_SCROLLING_FRAME_NAME, true)
	return if scrollingFrame and scrollingFrame:IsA("ScrollingFrame") then scrollingFrame else nil
end

local function revealStarterPackCard()
	local scrollingFrame = findSkinCaseScrollingFrame()
	if not scrollingFrame then
		return
	end

	local card = scrollingFrame:FindFirstChild(SkinCaseConfig.CARD_STARTER_PACK_NAME, true)
	if not card or not card:IsA("GuiObject") then
		return
	end

	card.Visible = true
	task.defer(function()
		if not scrollingFrame.Parent or not card.Parent then
			return
		end

		local targetY = card.AbsolutePosition.Y
			- scrollingFrame.AbsolutePosition.Y
			+ scrollingFrame.CanvasPosition.Y
		local maxY = math.max(0, scrollingFrame.AbsoluteCanvasSize.Y - scrollingFrame.AbsoluteWindowSize.Y)
		scrollingFrame.CanvasPosition = Vector2.new(
			scrollingFrame.CanvasPosition.X,
			math.clamp(targetY, 0, maxY)
		)
	end)
end

local function bindCashOpenButtons(shopModal: ShopModalHandle)
	local iconsConnection: RBXScriptConnection? = nil
	local skinsConnection: RBXScriptConnection? = nil
	local bindRevision = 0

	local function disconnect()
		if iconsConnection then
			iconsConnection:Disconnect()
			iconsConnection = nil
		end
		if skinsConnection then
			skinsConnection:Disconnect()
			skinsConnection = nil
		end
	end

	local function openCash()
		if not shopModal.IsOpen() then
			shopModal.Open()
		end
		task.defer(revealCashFrame)
		task.delay(0.05, revealCashFrame)
		task.delay(0.25, revealCashFrame)
	end

	local function bind()
		bindRevision += 1
		local revision = bindRevision
		disconnect()

		task.spawn(function()
			local deadline = os.clock() + CashProductConfig.UI_BIND_TIMEOUT_SECONDS
			repeat
				local iconsButton = findIconsMoneyPlusButton()
				local skinsButton = findSkinsMoneyPlusButton()
				if iconsButton then
					iconsConnection = iconsButton.Activated:Connect(openCash)
				end
				if skinsButton then
					skinsConnection = skinsButton.Activated:Connect(openCash)
				end
				if revision ~= bindRevision then
					return
				end
				if iconsButton and skinsButton then
					return
				end

				disconnect()
				task.wait(0.1)
			until revision ~= bindRevision or os.clock() >= deadline
		end)
	end

	playerGui.DescendantAdded:Connect(function(descendant)
		if descendant.Name == PLUS_BUTTON_NAME
			or descendant.Name == MONEY_PANEL_NAME
			or descendant.Name == ICONS_GUI_NAME
			or descendant.Name == SKIN_SHOP_GUI_NAME
			or descendant.Name == SHOP_GUI_NAME
			or descendant.Name == CASH_FRAME_NAME then
			task.defer(bind)
		end
	end)

	playerGui.DescendantRemoving:Connect(function(descendant)
		local iconsButton = findIconsMoneyPlusButton()
		local skinsButton = findSkinsMoneyPlusButton()
		if (iconsButton and (descendant == iconsButton or descendant:IsAncestorOf(iconsButton)))
			or (skinsButton and (descendant == skinsButton or descendant:IsAncestorOf(skinsButton))) then
			task.defer(bind)
		end
	end)

	bind()
end

local function bindCaseSellerPrompt(skinsModal: ShopModalHandle)
	local function openSkinCases()
		if not skinsModal.IsOpen() then
			skinsModal.Open()
		end
		task.defer(revealStarterPackCard)
		task.delay(0.05, revealStarterPackCard)
		task.delay(0.25, revealStarterPackCard)
	end

	ProximityPromptService.PromptTriggered:Connect(function(prompt: ProximityPrompt)
		if prompt.Name == SkinCaseConfig.HUB_CASE_SELLER_PROMPT_NAME
			or prompt:GetAttribute(SkinCaseConfig.HUB_CASE_SELLER_PROMPT_ATTRIBUTE) == true then
			openSkinCases()
		end
	end)
end

local function bindLikeRewardModal()
	local remoteFunction = ReplicatedStorage:WaitForChild(LIKE_REWARD_REMOTE_NAME) :: RemoteFunction
	local claimConnection: RBXScriptConnection? = nil
	local claimPending = false
	local modal

	local function findClaimButton(content: GuiObject): GuiButton?
		local button = content:FindFirstChild(FREE_BUTTON_NAME, true)
		return if button and button:IsA("GuiButton") then button else nil
	end

	local function setButtonEnabled(button: GuiButton, enabled: boolean)
		button.Active = enabled
		button.Interactable = enabled
	end

	modal = ModalController.Bind({
		Name = "LikeRewardController",
		FindOpenButton = function()
			return findTopBarButton(FREE_BUTTON_NAME)
		end,
		FindTarget = function()
			return findTargetGui(FREE_GUI_NAME)
		end,
		FindContent = function(target: TargetGui): GuiObject?
			return findNamedContent(target, FREE_FRAME_NAME)
		end,
		FindCloseButton = function(target: TargetGui): GuiButton?
			local content = findNamedContent(target, FREE_FRAME_NAME)
			return findCloseButton(target, content)
		end,
		ShouldRebind = function(descendant: Instance): boolean
			return descendant.Name == FREE_BUTTON_NAME
				or descendant.Name == FREE_GUI_NAME
				or descendant.Name == FREE_FRAME_NAME
				or descendant.Name == CLOSE_BUTTON_NAME
		end,
		Warning = "LikeRewardController: expected PlayerGui.IconsGui.MainFrame.IconFrame.FreeBtn "
			.. "and PlayerGui.FreeGui.FreeFrame.CloseBtn",
		OnBound = function(handle, openButton, _, content)
			if claimConnection then
				claimConnection:Disconnect()
				claimConnection = nil
			end

			local claimButton = findClaimButton(content)
			if not claimButton then
				warn("LikeRewardController: expected PlayerGui.FreeGui.FreeFrame.FreeBtn")
				return
			end

			claimPending = false
			setButtonEnabled(claimButton, true)
			claimConnection = claimButton.Activated:Connect(function()
				if claimPending then
					return
				end

				claimPending = true
				setButtonEnabled(claimButton, false)
				local ok, success, message = pcall(function()
					return remoteFunction:InvokeServer("Claim")
				end)

				if ok and success == true then
					openButton.Visible = false
					handle.Close()
					print(`[LikeReward] {tostring(message)}`)
				else
					claimPending = false
					setButtonEnabled(claimButton, true)
					warn(`[LikeReward] Failed to claim: {if ok then tostring(message) else tostring(success)}`)
				end
			end)
		end,
	})

	task.spawn(function()
		local ok, claimedOrMessage = pcall(function()
			return remoteFunction:InvokeServer("Check")
		end)

		local openButton: GuiButton? = nil
		for _ = 1, 200 do
			openButton = modal.GetOpenButton()
			if openButton then
				break
			end
			task.wait(0.1)
		end
		if ok and claimedOrMessage == true then
			if openButton then
				openButton.Visible = false
			end
		elseif not ok then
			warn(`[LikeReward] Failed to check claim status: {tostring(claimedOrMessage)}`)
		end
	end)
end

bindStandardModal("InventoryController", INVENTORY_BUTTON_NAME, INVENTORY_GUI_NAME, nil)
local skinsModal = bindStandardModal("SkinsController", SKINS_BUTTON_NAME, SKIN_SHOP_GUI_NAME, SKINS_MAIN_FRAME_NAME)
local shopModal = bindStandardModal("ShopController", SHOP_BUTTON_NAME, SHOP_GUI_NAME, SHOP_MAIN_FRAME_NAME)
bindCashOpenButtons(shopModal)
bindCaseSellerPrompt(skinsModal)
bindLikeRewardModal()
