--!strict

local MarketplaceService = game:GetService("MarketplaceService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage:WaitForChild("CooldownPassConfig"))
local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

local activePanel: GuiObject? = nil
local activeButton: GuiButton? = nil
local buttonConnection: RBXScriptConnection? = nil
local bindRevision = 0
local promptPending = false
local awaitingServerGrant = false
local productInfoReady = false
local productForSale = false

local function ownsPass(): boolean
	return player:GetAttribute(Config.OWNED_ATTRIBUTE) == true
end

local function refreshState()
	local panel = activePanel
	local button = activeButton
	if not panel or not panel.Parent or not button or not button.Parent then
		return
	end

	local owned = ownsPass()
	local ownershipReady = player:GetAttribute(Config.OWNERSHIP_READY_ATTRIBUTE) == true
	button.Interactable = not owned
		and ownershipReady
		and productInfoReady
		and productForSale
		and not promptPending
		and not awaitingServerGrant
	button:SetAttribute("CooldownPassOwned", owned)
	button:SetAttribute("CooldownPassOwnershipReady", ownershipReady)
	button:SetAttribute("CooldownPassProductReady", productInfoReady)
	button:SetAttribute("CooldownPassForSale", productForSale)
end

local function beginPurchase()
	if promptPending
		or awaitingServerGrant
		or ownsPass()
		or player:GetAttribute(Config.OWNERSHIP_READY_ATTRIBUTE) ~= true
		or not productInfoReady
		or not productForSale then
		return
	end

	promptPending = true
	refreshState()
	local succeeded, message = pcall(
		MarketplaceService.PromptGamePassPurchase,
		MarketplaceService,
		player,
		Config.GAME_PASS_ID
	)
	if not succeeded then
		promptPending = false
		refreshState()
		warn(`CooldownPass: failed to open purchase prompt: {tostring(message)}`)
	end
end

local function disconnectButton()
	if buttonConnection then
		buttonConnection:Disconnect()
		buttonConnection = nil
	end
	activePanel = nil
	activeButton = nil
end

local function findControls(): (GuiObject?, GuiButton?)
	local iconsGui = playerGui:FindFirstChild(Config.ICONS_GUI_NAME)
	if not iconsGui then
		return nil, nil
	end
	local panel = iconsGui:FindFirstChild(Config.PANEL_NAME, true)
	if not panel or not panel:IsA("GuiObject") then
		return nil, nil
	end
	local button = panel:FindFirstChild(Config.BUY_BUTTON_NAME, true)
	return panel, if button and button:IsA("GuiButton") then button else nil
end

local function bindControls()
	bindRevision += 1
	local revision = bindRevision
	disconnectButton()

	task.spawn(function()
		local deadline = os.clock() + Config.UI_BIND_TIMEOUT_SECONDS
		repeat
			local panel, button = findControls()
			if panel and button then
				if revision ~= bindRevision then
					return
				end
				activePanel = panel
				activeButton = button
				buttonConnection = button.Activated:Connect(beginPurchase)
				refreshState()
				return
			end
			task.wait(0.1)
		until revision ~= bindRevision or os.clock() >= deadline

		if revision == bindRevision then
			warn(
				`CooldownPass: {Config.ICONS_GUI_NAME}.{Config.PANEL_NAME}.`
					.. `{Config.BUY_BUTTON_NAME} must be a GuiButton`
			)
		end
	end)
end

local function loadProductInfo()
	task.spawn(function()
		while not productInfoReady do
			local succeeded, info = pcall(
				MarketplaceService.GetProductInfo,
				MarketplaceService,
				Config.GAME_PASS_ID,
				Enum.InfoType.GamePass
			)
			if succeeded and type(info) == "table" then
				productInfoReady = true
				productForSale = info.IsForSale == true
				refreshState()
				return
			end
			task.wait(Config.PRODUCT_INFO_RETRY_SECONDS)
		end
	end)
end

MarketplaceService.PromptGamePassPurchaseFinished:Connect(function(
	promptPlayer: Player,
	gamePassId: number,
	wasPurchased: boolean
)
	if promptPlayer ~= player or gamePassId ~= Config.GAME_PASS_ID then
		return
	end
	promptPending = false
	awaitingServerGrant = wasPurchased
	refreshState()
	if wasPurchased then
		task.delay(Config.PURCHASE_GRANT_TIMEOUT_SECONDS, function()
			if not ownsPass() then
				awaitingServerGrant = false
				refreshState()
			end
		end)
	end
end)

player:GetAttributeChangedSignal(Config.OWNED_ATTRIBUTE):Connect(function()
	if ownsPass() then
		promptPending = false
		awaitingServerGrant = false
	end
	refreshState()
end)
player:GetAttributeChangedSignal(Config.OWNERSHIP_READY_ATTRIBUTE):Connect(refreshState)
playerGui.DescendantAdded:Connect(function(descendant)
	if descendant.Name == Config.ICONS_GUI_NAME
		or descendant.Name == Config.PANEL_NAME
		or descendant.Name == Config.BUY_BUTTON_NAME then
		task.defer(bindControls)
	end
end)
playerGui.DescendantRemoving:Connect(function(descendant)
	local panel = activePanel
	local button = activeButton
	if (panel and (descendant == panel or descendant:IsAncestorOf(panel)))
		or (button and (descendant == button or descendant:IsAncestorOf(button))) then
		task.defer(bindControls)
	end
end)

bindControls()
loadProductInfo()
