--!strict

local MarketplaceService = game:GetService("MarketplaceService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage:WaitForChild("CashProductConfig"))
local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

type ProductClientConfig = {
	Key: string,
	FrameName: string,
	ProductId: number,
	Amount: number,
}

type ProductState = {
	Button: GuiButton?,
	ButtonConnection: RBXScriptConnection?,
	ProductInfoReady: boolean,
	ProductForSale: boolean,
	PromptPending: boolean,
}

local states: {[string]: ProductState} = {}
local productById: {[number]: ProductClientConfig} = {}
local bindRevision = 0

for _, productConfig in ipairs(Config.PRODUCTS) do
	states[productConfig.Key] = {
		Button = nil,
		ButtonConnection = nil,
		ProductInfoReady = false,
		ProductForSale = false,
		PromptPending = false,
	}
	productById[productConfig.ProductId] = productConfig
end

local function refreshState(productConfig: ProductClientConfig)
	local state = states[productConfig.Key]
	local button = state.Button
	if not button or not button.Parent then
		return
	end

	button.Interactable = state.ProductInfoReady
		and state.ProductForSale
		and not state.PromptPending
	button:SetAttribute(`{productConfig.Key}ProductReady`, state.ProductInfoReady)
	button:SetAttribute(`{productConfig.Key}ProductForSale`, state.ProductForSale)
	button:SetAttribute(`{productConfig.Key}PromptPending`, state.PromptPending)
end

local function beginPurchase(productConfig: ProductClientConfig)
	local state = states[productConfig.Key]
	if state.PromptPending or not state.ProductInfoReady or not state.ProductForSale then
		return
	end

	state.PromptPending = true
	refreshState(productConfig)
	local succeeded, message = pcall(
		MarketplaceService.PromptProductPurchase,
		MarketplaceService,
		player,
		productConfig.ProductId
	)
	if not succeeded then
		state.PromptPending = false
		refreshState(productConfig)
		warn(`[CashProducts] failed to open purchase prompt: {tostring(message)}`)
		return
	end

	task.delay(Config.PURCHASE_PROMPT_TIMEOUT_SECONDS, function()
		if state.PromptPending then
			state.PromptPending = false
			refreshState(productConfig)
		end
	end)
end

local function findCashFrame(): Instance?
	local shopGui = playerGui:FindFirstChild(Config.SHOP_GUI_NAME)
	local shopMainFrame = shopGui and shopGui:FindFirstChild(Config.SHOP_MAIN_FRAME_NAME, true)
	local scrollingFrame = shopMainFrame and shopMainFrame:FindFirstChild(Config.SCROLLING_FRAME_NAME, true)
	return scrollingFrame and scrollingFrame:FindFirstChild(Config.CASH_FRAME_NAME, true)
end

local function findButton(productConfig: ProductClientConfig): GuiButton?
	local cashFrame = findCashFrame()
	local productFrame = cashFrame and cashFrame:FindFirstChild(productConfig.FrameName, true)
	local button = productFrame and productFrame:FindFirstChild(Config.BUY_BUTTON_NAME, true)
	return if button and button:IsA("GuiButton") then button else nil
end

local function disconnectButtons()
	for _, state in pairs(states) do
		if state.ButtonConnection then
			state.ButtonConnection:Disconnect()
			state.ButtonConnection = nil
		end
		state.Button = nil
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
			for _, productConfig in ipairs(Config.PRODUCTS) do
				local state = states[productConfig.Key]
				local button = findButton(productConfig)
				if button then
					state.Button = button
					state.ButtonConnection = button.Activated:Connect(function()
						beginPurchase(productConfig)
					end)
					refreshState(productConfig)
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
				"CashProducts: expected buttons under PlayerGui.ShopGui.ShopMainFrame."
					.. "ScrollingFrame.Cash"
			)
		end
	end)
end

local function loadProductInfo(productConfig: ProductClientConfig)
	task.spawn(function()
		local state = states[productConfig.Key]
		while not state.ProductInfoReady do
			local succeeded, info = pcall(
				MarketplaceService.GetProductInfo,
				MarketplaceService,
				productConfig.ProductId,
				Enum.InfoType.Product
			)
			if succeeded and type(info) == "table" then
				state.ProductInfoReady = true
				state.ProductForSale = info.IsForSale == true
				refreshState(productConfig)
				return
			end
			task.wait(Config.PRODUCT_INFO_RETRY_SECONDS)
		end
	end)
end

for _, productConfig in ipairs(Config.PRODUCTS) do
	loadProductInfo(productConfig)
end

MarketplaceService.PromptProductPurchaseFinished:Connect(function(
	userId: number,
	productId: number,
	_wasPurchased: boolean
)
	if userId ~= player.UserId then
		return
	end
	local productConfig = productById[productId]
	if not productConfig then
		return
	end

	local state = states[productConfig.Key]
	state.PromptPending = false
	refreshState(productConfig)
end)

playerGui.DescendantAdded:Connect(function(descendant)
	if descendant.Name == Config.SHOP_GUI_NAME
		or descendant.Name == Config.SHOP_MAIN_FRAME_NAME
		or descendant.Name == Config.SCROLLING_FRAME_NAME
		or descendant.Name == Config.CASH_FRAME_NAME
		or descendant.Name == Config.BUY_BUTTON_NAME then
		task.defer(bindControls)
		return
	end
	for _, productConfig in ipairs(Config.PRODUCTS) do
		if descendant.Name == productConfig.FrameName then
			task.defer(bindControls)
			return
		end
	end
end)

playerGui.DescendantRemoving:Connect(function(descendant)
	for _, state in pairs(states) do
		local button = state.Button
		if button and (descendant == button or descendant:IsAncestorOf(button)) then
			task.defer(bindControls)
			return
		end
	end
end)

bindControls()
