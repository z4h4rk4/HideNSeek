--!strict

local MarketplaceService = game:GetService("MarketplaceService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage:WaitForChild("CooldownPassConfig"))
local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

type PassClientConfig = {
	Key: string,
	GamePassId: number,
	OwnedAttribute: string,
	ReadyAttribute: string,
	FrameName: string,
	ButtonName: string,
}

type PassState = {
	Frame: Instance?,
	Button: GuiButton?,
	Thanks: GuiObject?,
	ButtonConnection: RBXScriptConnection?,
	ProductInfoReady: boolean,
	ProductForSale: boolean,
	PromptPending: boolean,
	AwaitingServerGrant: boolean,
}

local PASS_CONFIGS: {PassClientConfig} = {
	{
		Key = "Cooldown",
		GamePassId = Config.GAME_PASS_ID,
		OwnedAttribute = Config.OWNED_ATTRIBUTE,
		ReadyAttribute = Config.OWNERSHIP_READY_ATTRIBUTE,
		FrameName = Config.COOLDOWN_PASS_FRAME_NAME,
		ButtonName = Config.COOLDOWN_BUY_BUTTON_NAME,
	},
	{
		Key = "VIP",
		GamePassId = Config.VIP_GAME_PASS_ID,
		OwnedAttribute = Config.VIP_OWNED_ATTRIBUTE,
		ReadyAttribute = Config.VIP_OWNERSHIP_READY_ATTRIBUTE,
		FrameName = Config.VIP_PASS_FRAME_NAME,
		ButtonName = Config.VIP_BUY_BUTTON_NAME,
	},
	{
		Key = "x2Cash",
		GamePassId = Config.X2_CASH_GAME_PASS_ID,
		OwnedAttribute = Config.X2_CASH_OWNED_ATTRIBUTE,
		ReadyAttribute = Config.X2_CASH_OWNERSHIP_READY_ATTRIBUTE,
		FrameName = Config.X2_CASH_PASS_FRAME_NAME,
		ButtonName = Config.X2_CASH_BUY_BUTTON_NAME,
	},
}

local states: {[string]: PassState} = {}
local bindRevision = 0

for _, passConfig in ipairs(PASS_CONFIGS) do
	states[passConfig.Key] = {
		Frame = nil,
		Button = nil,
		Thanks = nil,
		ButtonConnection = nil,
		ProductInfoReady = false,
		ProductForSale = false,
		PromptPending = false,
		AwaitingServerGrant = false,
	}
end

local function ownsPass(passConfig: PassClientConfig): boolean
	return player:GetAttribute(passConfig.OwnedAttribute) == true
end

local function refreshState(passConfig: PassClientConfig)
	local state = states[passConfig.Key]
	local button = state.Button
	if not button or not button.Parent then
		return
	end

	local owned = ownsPass(passConfig)
	local ownershipReady = player:GetAttribute(passConfig.ReadyAttribute) == true
	local thanks = state.Thanks
	if thanks and thanks.Parent then
		thanks.Visible = owned
	end
	button.Visible = not owned
	button.Interactable = not owned
		and ownershipReady
		and state.ProductInfoReady
		and state.ProductForSale
		and not state.PromptPending
		and not state.AwaitingServerGrant
	button:SetAttribute(`{passConfig.Key}PassOwned`, owned)
	button:SetAttribute(`{passConfig.Key}PassOwnershipReady`, ownershipReady)
	button:SetAttribute(`{passConfig.Key}PassProductReady`, state.ProductInfoReady)
	button:SetAttribute(`{passConfig.Key}PassForSale`, state.ProductForSale)
end

local function beginPurchase(passConfig: PassClientConfig)
	local state = states[passConfig.Key]
	if state.PromptPending
		or state.AwaitingServerGrant
		or ownsPass(passConfig)
		or player:GetAttribute(passConfig.ReadyAttribute) ~= true
		or not state.ProductInfoReady
		or not state.ProductForSale then
		return
	end

	state.PromptPending = true
	refreshState(passConfig)
	local succeeded, message = pcall(
		MarketplaceService.PromptGamePassPurchase,
		MarketplaceService,
		player,
		passConfig.GamePassId
	)
	if not succeeded then
		state.PromptPending = false
		refreshState(passConfig)
		warn(`{passConfig.Key}Pass: failed to open purchase prompt: {tostring(message)}`)
	end
end

local function findGamePassesFrame(): Instance?
	local shopGui = playerGui:FindFirstChild(Config.SHOP_GUI_NAME)
	local shopMainFrame = shopGui and shopGui:FindFirstChild(Config.SHOP_MAIN_FRAME_NAME, true)
	local scrollingFrame = shopMainFrame and shopMainFrame:FindFirstChild(Config.SCROLLING_FRAME_NAME, true)
	return scrollingFrame and scrollingFrame:FindFirstChild(Config.GAME_PASSES_FRAME_NAME, true)
end

local function findPassFrame(passConfig: PassClientConfig): Instance?
	local gamePasses = findGamePassesFrame()
	return gamePasses and gamePasses:FindFirstChild(passConfig.FrameName, true) or nil
end

local function findButton(passFrame: Instance?, passConfig: PassClientConfig): GuiButton?
	local button = passFrame and passFrame:FindFirstChild(passConfig.ButtonName, true)
	return if button and button:IsA("GuiButton") then button else nil
end

local function findThanks(passFrame: Instance?): GuiObject?
	local thanks = passFrame and passFrame:FindFirstChild(Config.THANKS_LABEL_NAME, true)
	return if thanks and thanks:IsA("GuiObject") then thanks else nil
end

local function disconnectButtons()
	for _, state in pairs(states) do
		if state.ButtonConnection then
			state.ButtonConnection:Disconnect()
			state.ButtonConnection = nil
		end
		state.Frame = nil
		state.Button = nil
		state.Thanks = nil
	end
end

local function bindControls()
	bindRevision += 1
	local revision = bindRevision
	disconnectButtons()

	task.spawn(function()
		local deadline = os.clock() + Config.UI_BIND_TIMEOUT_SECONDS
		repeat
			local allBound = true
			for _, passConfig in ipairs(PASS_CONFIGS) do
				local state = states[passConfig.Key]
				local passFrame = findPassFrame(passConfig)
				local button = findButton(passFrame, passConfig)
				if button then
					state.Frame = passFrame
					state.Button = button
					state.Thanks = findThanks(passFrame)
					state.ButtonConnection = button.Activated:Connect(function()
						beginPurchase(passConfig)
					end)
					refreshState(passConfig)
				else
					allBound = false
				end
			end

			if revision ~= bindRevision then
				return
			end
			if allBound then
				return
			end

			disconnectButtons()
			task.wait(0.1)
		until revision ~= bindRevision or os.clock() >= deadline

		if revision == bindRevision then
			warn(
				"GamePassShop: expected buttons under PlayerGui.ShopGui.ShopMainFrame."
					.. "ScrollingFrame.GamePasses"
			)
		end
	end)
end

local function loadProductInfo(passConfig: PassClientConfig)
	task.spawn(function()
		local state = states[passConfig.Key]
		while not state.ProductInfoReady do
			local succeeded, info = pcall(
				MarketplaceService.GetProductInfo,
				MarketplaceService,
				passConfig.GamePassId,
				Enum.InfoType.GamePass
			)
			if succeeded and type(info) == "table" then
				state.ProductInfoReady = true
				state.ProductForSale = info.IsForSale == true
				refreshState(passConfig)
				return
			end
			task.wait(Config.PRODUCT_INFO_RETRY_SECONDS)
		end
	end)
end

local passByGamePassId: {[number]: PassClientConfig} = {}
for _, passConfig in ipairs(PASS_CONFIGS) do
	passByGamePassId[passConfig.GamePassId] = passConfig
	player:GetAttributeChangedSignal(passConfig.OwnedAttribute):Connect(function()
		local state = states[passConfig.Key]
		if ownsPass(passConfig) then
			state.PromptPending = false
			state.AwaitingServerGrant = false
		end
		refreshState(passConfig)
	end)
	player:GetAttributeChangedSignal(passConfig.ReadyAttribute):Connect(function()
		refreshState(passConfig)
	end)
	loadProductInfo(passConfig)
end

MarketplaceService.PromptGamePassPurchaseFinished:Connect(function(
	promptPlayer: Player,
	gamePassId: number,
	wasPurchased: boolean
)
	if promptPlayer ~= player then
		return
	end
	local passConfig = passByGamePassId[gamePassId]
	if not passConfig then
		return
	end

	local state = states[passConfig.Key]
	state.PromptPending = false
	state.AwaitingServerGrant = wasPurchased
	refreshState(passConfig)
	if wasPurchased then
		task.delay(Config.PURCHASE_GRANT_TIMEOUT_SECONDS, function()
			if not ownsPass(passConfig) then
				state.AwaitingServerGrant = false
				refreshState(passConfig)
			end
		end)
	end
end)

playerGui.DescendantAdded:Connect(function(descendant)
	if descendant.Name == Config.SHOP_GUI_NAME
		or descendant.Name == Config.SHOP_MAIN_FRAME_NAME
		or descendant.Name == Config.SCROLLING_FRAME_NAME
		or descendant.Name == Config.GAME_PASSES_FRAME_NAME then
		task.defer(bindControls)
		return
	end
	for _, passConfig in ipairs(PASS_CONFIGS) do
		if descendant.Name == passConfig.FrameName
			or descendant.Name == passConfig.ButtonName
			or descendant.Name == Config.THANKS_LABEL_NAME then
			task.defer(bindControls)
			return
		end
	end
end)

playerGui.DescendantRemoving:Connect(function(descendant)
	for _, state in pairs(states) do
		local button = state.Button
		local thanks = state.Thanks
		if (button and (descendant == button or descendant:IsAncestorOf(button)))
			or (thanks and (descendant == thanks or descendant:IsAncestorOf(thanks))) then
			task.defer(bindControls)
			return
		end
	end
end)

bindControls()
