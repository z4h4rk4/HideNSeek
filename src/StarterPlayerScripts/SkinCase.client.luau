--!strict

local Lighting = game:GetService("Lighting")
local MarketplaceService = game:GetService("MarketplaceService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local Config = require(ReplicatedStorage:WaitForChild("SkinCaseConfig"))
local remote = ReplicatedStorage:WaitForChild(Config.REMOTE_NAME) :: RemoteFunction

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

local quantity = 1
local bindingRevision = 0
local coinConnection: RBXScriptConnection? = nil
local robuxConnection: RBXScriptConnection? = nil
local plusConnection: RBXScriptConnection? = nil
local minusConnection: RBXScriptConnection? = nil
local pendingCoinOpen = false
local pendingRobuxOpen = false
local openingQueue = {}
local openingInProgress = false
local openingBlur: BlurEffect? = nil
local openingGuiHidden = false
local hiddenOpeningGuiStates: {[Instance]: { Enabled: boolean?, Visible: boolean? }} = {}

type CaseOpeningBinding = {
	Gui: ScreenGui,
	MainFrame: GuiObject,
	CaseObject: GuiObject,
	CharacterObject: GuiObject,
	RaysObject: GuiObject?,
}

local function formatCoins(amount: number): string
	return tostring(amount)
end

local function findCard(): GuiObject?
	local skinShopGui = playerGui:FindFirstChild(Config.SKIN_SHOP_GUI_NAME)
	local skinsMainFrame = skinShopGui and skinShopGui:FindFirstChild(Config.SKINS_MAIN_FRAME_NAME, true)
	local scrollingFrame = skinsMainFrame and skinsMainFrame:FindFirstChild(Config.YOU_SCROLLING_FRAME_NAME, true)
	local card = scrollingFrame and scrollingFrame:FindFirstChild(Config.CARD_STARTER_PACK_NAME, true)
	return if card and card:IsA("GuiObject") then card else nil
end

local function findButton(root: Instance, buttonName: string): GuiButton?
	local button = root:FindFirstChild(buttonName, true)
	return if button and button:IsA("GuiButton") then button else nil
end

local function findText(root: Instance, textName: string): TextLabel?
	local text = root:FindFirstChild(textName, true)
	return if text and text:IsA("TextLabel") then text else nil
end

local function setOptionalText(root: Instance, names: {string}, value: string)
	for _, name in ipairs(names) do
		local label = findText(root, name)
		if label then
			label.Text = value
		end
	end
end

local function findDirectGuiObject(root: Instance, name: string): GuiObject?
	local instance = root:FindFirstChild(name)
	return if instance and instance:IsA("GuiObject") then instance else nil
end

local function findOpeningBinding(): CaseOpeningBinding?
	local gui = playerGui:FindFirstChild(Config.CASE_OPENING_GUI_NAME)
	if not gui then
		return nil
	end
	if not gui:IsA("ScreenGui") then
		warn(`SkinCaseOpening: PlayerGui.{Config.CASE_OPENING_GUI_NAME} must be a ScreenGui`)
		return nil
	end

	local mainFrame = findDirectGuiObject(gui, Config.CASE_OPENING_MAIN_FRAME_NAME)
	if not mainFrame then
		warn(
			`SkinCaseOpening: expected PlayerGui.{Config.CASE_OPENING_GUI_NAME}.`
				.. `{Config.CASE_OPENING_MAIN_FRAME_NAME}`
		)
		return nil
	end

	local caseObject = findDirectGuiObject(mainFrame, Config.CASE_OPENING_CASE_NAME)
	local characterObject = findDirectGuiObject(mainFrame, Config.CASE_OPENING_CHARACTER_NAME)
	local raysObject = findDirectGuiObject(mainFrame, Config.CASE_OPENING_RAYS_NAME)
	if not caseObject or not characterObject then
		warn(
			`SkinCaseOpening: expected {Config.CASE_OPENING_CASE_NAME} and `
				.. `{Config.CASE_OPENING_CHARACTER_NAME} under {mainFrame:GetFullName()}`
		)
		return nil
	end

	gui.ResetOnSpawn = false
	gui.DisplayOrder = math.max(gui.DisplayOrder, 1000)
	return {
		Gui = gui,
		MainFrame = mainFrame,
		CaseObject = caseObject,
		CharacterObject = characterObject,
		RaysObject = raysObject,
	}
end

local function waitForOpeningBinding(): CaseOpeningBinding?
	local deadline = os.clock() + Config.CASE_OPENING_BIND_TIMEOUT_SECONDS
	repeat
		local binding = findOpeningBinding()
		if binding then
			return binding
		end
		task.wait(0.1)
	until os.clock() >= deadline

	warn(
		`SkinCaseOpening: {Config.CASE_OPENING_GUI_NAME}.`
			.. `{Config.CASE_OPENING_MAIN_FRAME_NAME} was not found`
	)
	return nil
end

local function getOpeningBlur(): BlurEffect
	if openingBlur and openingBlur.Parent then
		return openingBlur
	end

	local existing = Lighting:FindFirstChild(Config.CASE_OPENING_BLUR_NAME)
	if existing and existing:IsA("BlurEffect") then
		openingBlur = existing
	else
		local blur = Instance.new("BlurEffect")
		blur.Name = Config.CASE_OPENING_BLUR_NAME
		blur.Size = 0
		blur.Enabled = false
		blur.Parent = Lighting
		openingBlur = blur
	end
	return openingBlur :: BlurEffect
end

local function tweenBlur(targetSize: number)
	local blur = getOpeningBlur()
	blur.Enabled = true
	local tween = TweenService:Create(
		blur,
		TweenInfo.new(0.2, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
		{ Size = targetSize }
	)
	tween:Play()
	if targetSize <= 0 then
		local connection: RBXScriptConnection? = nil
		connection = tween.Completed:Connect(function()
			if connection then
				connection:Disconnect()
				connection = nil
			end
			if blur.Size <= 0.05 then
				blur.Enabled = false
			end
		end)
	end
end

local function hideOtherGui(openingGui: ScreenGui)
	if openingGuiHidden then
		return
	end
	openingGuiHidden = true
	table.clear(hiddenOpeningGuiStates)

	for _, child in ipairs(playerGui:GetChildren()) do
		if child ~= openingGui then
			if child:IsA("ScreenGui") then
				hiddenOpeningGuiStates[child] = { Enabled = child.Enabled }
				child.Enabled = false
			elseif child:IsA("GuiObject") then
				hiddenOpeningGuiStates[child] = { Visible = child.Visible }
				child.Visible = false
			end
		end
	end
end

local function restoreOtherGui()
	if not openingGuiHidden then
		return
	end
	openingGuiHidden = false

	for instance, state in pairs(hiddenOpeningGuiStates) do
		if instance.Parent then
			if instance:IsA("ScreenGui") and state.Enabled ~= nil then
				instance.Enabled = state.Enabled
			elseif instance:IsA("GuiObject") and state.Visible ~= nil then
				instance.Visible = state.Visible
			end
		end
	end
	table.clear(hiddenOpeningGuiStates)
end

local function getOrCreateScale(guiObject: GuiObject, name: string): UIScale
	for _, child in ipairs(guiObject:GetChildren()) do
		if child.Name == name and child:IsA("UIScale") then
			return child
		end
	end

	local scale = Instance.new("UIScale")
	scale.Name = name
	scale.Parent = guiObject
	return scale
end

local function setImage(root: GuiObject, image: string)
	if root:IsA("ImageLabel") or root:IsA("ImageButton") then
		root.Image = image
		root.ImageRectOffset = Vector2.new(0, 0)
		root.ImageRectSize = Vector2.new(0, 0)
		return
	end

	for _, descendant in ipairs(root:GetDescendants()) do
		if descendant:IsA("ImageLabel") or descendant:IsA("ImageButton") then
			descendant.Image = image
			descendant.ImageRectOffset = Vector2.new(0, 0)
			descendant.ImageRectSize = Vector2.new(0, 0)
			return
		end
	end
end

local function setGuiTreeZIndex(root: GuiObject, zIndex: number)
	root.ZIndex = zIndex
	for _, descendant in ipairs(root:GetDescendants()) do
		if descendant:IsA("GuiObject") then
			descendant.ZIndex = zIndex
		end
	end
end

local function playTween(instance: Instance, tweenInfo: TweenInfo, properties): Tween
	local tween = TweenService:Create(instance, tweenInfo, properties)
	tween:Play()
	return tween
end

local function setOpeningVisible(binding: CaseOpeningBinding, visible: boolean)
	if visible then
		hideOtherGui(binding.Gui)
	else
		restoreOtherGui()
	end
	binding.Gui.Enabled = visible
	binding.MainFrame.Visible = visible
	binding.CaseObject.Visible = visible
	binding.CharacterObject.Visible = false
	if binding.RaysObject then
		binding.RaysObject.Visible = false
	end
	tweenBlur(if visible then Config.CASE_OPENING_BLUR_SIZE else 0)
end

local function hideOpeningGui()
	local binding = findOpeningBinding()
	if not binding then
		restoreOtherGui()
		tweenBlur(0)
		return
	end
	setOpeningVisible(binding, false)
end

local function playCasePress(caseObject: GuiObject, caseScale: UIScale)
	task.spawn(function()
		playTween(
			caseScale,
			TweenInfo.new(0.08, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
			{ Scale = 0.82 }
		).Completed:Wait()
		if caseObject.Parent then
			playTween(
				caseScale,
				TweenInfo.new(0.12, Enum.EasingStyle.Back, Enum.EasingDirection.Out),
				{ Scale = 1 }
			)
		end
	end)
end

local function waitForCaseClicks(caseObject: GuiObject, caseScale: UIScale): boolean
	local clickCount = 0
	local done = false
	local connection: RBXScriptConnection

	local function handleClick()
		if done then
			return
		end
		clickCount += 1
		playCasePress(caseObject, caseScale)
		if clickCount >= Config.CASE_OPENING_CLICK_COUNT then
			done = true
		end
	end

	if caseObject:IsA("GuiButton") then
		connection = caseObject.Activated:Connect(handleClick)
	else
		caseObject.Active = true
		connection = caseObject.InputBegan:Connect(function(input)
			if input.UserInputType == Enum.UserInputType.MouseButton1
				or input.UserInputType == Enum.UserInputType.Touch then
				handleClick()
			end
		end)
	end

	while not done and caseObject.Parent and openingInProgress do
		task.wait(0.05)
	end
	connection:Disconnect()
	return done
end

local function spinRays(raysObject: GuiObject): RBXScriptConnection
	return RunService.RenderStepped:Connect(function(deltaTime)
		if raysObject.Parent and raysObject.Visible then
			raysObject.Rotation = (raysObject.Rotation + deltaTime * 120) % 360
		end
	end)
end

local function playOpeningResult(result)
	if type(result) ~= "table" then
		return
	end

	local binding = waitForOpeningBinding()
	if not binding then
		return
	end

	local skinId = tostring(result.SkinId)
	local skinImage = Config.SKIN_IMAGES[skinId] or ""
	local caseScale = getOrCreateScale(binding.CaseObject, "CaseOpeningCaseScale")
	local characterScale = getOrCreateScale(binding.CharacterObject, "CaseOpeningCharacterScale")
	local raysObject = binding.RaysObject
	local raysScale = if raysObject then getOrCreateScale(raysObject, "CaseOpeningRaysScale") else nil

	setImage(binding.CharacterObject, skinImage)
	if raysObject then
		local characterZIndex = math.max(binding.CharacterObject.ZIndex, raysObject.ZIndex + 1, 2)
		setGuiTreeZIndex(raysObject, characterZIndex - 1)
		setGuiTreeZIndex(binding.CharacterObject, characterZIndex)
	end
	setOpeningVisible(binding, true)
	caseScale.Scale = 0.35
	characterScale.Scale = 0.25
	if raysScale then
		raysScale.Scale = 0.6
	end
	binding.CharacterObject.Visible = false
	if raysObject then
		raysObject.Visible = false
	end

	playTween(
		caseScale,
		TweenInfo.new(0.28, Enum.EasingStyle.Back, Enum.EasingDirection.Out),
		{ Scale = 1 }
	).Completed:Wait()

	if not waitForCaseClicks(binding.CaseObject, caseScale) then
		return
	end

	playTween(
		caseScale,
		TweenInfo.new(0.18, Enum.EasingStyle.Back, Enum.EasingDirection.In),
		{ Scale = 0.08 }
	).Completed:Wait()

	binding.CaseObject.Visible = false
	binding.CharacterObject.Visible = true
	local raysConnection: RBXScriptConnection? = nil
	if raysObject then
		raysObject.Rotation = 0
		raysObject.Visible = true
		raysConnection = spinRays(raysObject)
		if raysScale then
			playTween(
				raysScale,
				TweenInfo.new(0.35, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
				{ Scale = 1 }
			)
		end
	end
	playTween(
		characterScale,
		TweenInfo.new(0.35, Enum.EasingStyle.Back, Enum.EasingDirection.Out),
		{ Scale = 1 }
	)

	task.wait(Config.CASE_OPENING_REVEAL_SECONDS)
	if raysConnection then
		raysConnection:Disconnect()
	end
end

local function processOpeningQueue()
	if openingInProgress then
		return
	end
	openingInProgress = true
	while #openingQueue > 0 do
		local result = table.remove(openingQueue, 1)
		playOpeningResult(result)
	end
	openingInProgress = false
	hideOpeningGui()
end

local function enqueueOpeningResults(payload)
	if type(payload) ~= "table" or type(payload.Results) ~= "table" then
		return
	end

	for _, result in ipairs(payload.Results) do
		table.insert(openingQueue, result)
	end
	task.spawn(processOpeningQueue)
end

local function setButtonsEnabled(card: GuiObject, enabled: boolean)
	for _, buttonName in ipairs({
		Config.COIN_BUY_BUTTON_NAME,
		Config.ROBUX_BUTTON_NAME,
		Config.PLUS_BUTTON_NAME,
		Config.MINUS_BUTTON_NAME,
	}) do
		local button = findButton(card, buttonName)
		if button then
			button.Interactable = enabled
			button.Active = enabled
		end
	end
end

local function updateCard(card: GuiObject)
	quantity = math.clamp(quantity, 1, Config.MAX_COIN_OPEN_QUANTITY)
	local totalPrice = Config.STARTER_PACK_COIN_PRICE * quantity
	local priceLabel = findText(card, Config.COIN_PRICE_LABEL_NAME)
	if priceLabel then
		priceLabel.Text = formatCoins(totalPrice)
	end
	card:SetAttribute("SkinCaseQuantity", quantity)
	card:SetAttribute("SkinCaseCoinPrice", totalPrice)
	setOptionalText(card, { "QuantityText", "AmountText", "CountText" }, `x{quantity}`)
end

local function applyOpenResult(card: GuiObject, payload)
	if type(payload) ~= "table" or type(payload.Results) ~= "table" then
		return
	end

	local firstResult = payload.Results[#payload.Results]
	if type(firstResult) ~= "table" then
		return
	end

	local skinId = tostring(firstResult.SkinId)
	local displayName = tostring(firstResult.DisplayName or skinId)
	local rarity = tostring(firstResult.Rarity or "Unknown")
	local duplicate = firstResult.Duplicate == true
	local duplicateCoins = if type(firstResult.DuplicateCoins) == "number" then firstResult.DuplicateCoins else 0

	card:SetAttribute("LastSkinId", skinId)
	card:SetAttribute("LastSkinName", displayName)
	card:SetAttribute("LastSkinRarity", rarity)
	card:SetAttribute("LastSkinDuplicate", duplicate)
	card:SetAttribute("LastDuplicateCoins", duplicateCoins)

	setOptionalText(card, { "ResultText", "ResultLabel", "SkinName", "SkinNameText" }, displayName)
	setOptionalText(card, { "RarityText", "RarityLabel" }, rarity)
	if duplicate then
		setOptionalText(card, { "DuplicateText", "DuplicateLabel" }, `Duplicate +{duplicateCoins}`)
	else
		setOptionalText(card, { "DuplicateText", "DuplicateLabel" }, "")
	end
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

local function openWithCoins(card: GuiObject)
	if pendingCoinOpen then
		return
	end

	pendingCoinOpen = true
	setButtonsEnabled(card, false)
	local success, result = invoke("OpenCoins", {
		CaseId = Config.STARTER_PACK_CASE_ID,
		Quantity = quantity,
	})
	pendingCoinOpen = false
	setButtonsEnabled(card, true)
	updateCard(card)

	if success then
		applyOpenResult(card, result)
		enqueueOpeningResults(result)
	else
		warn(`[SkinCase] Coin open failed: {tostring(result)}`)
	end
end

local function openWithRobux(card: GuiObject)
	if pendingRobuxOpen then
		return
	end

	pendingRobuxOpen = true
	setButtonsEnabled(card, false)
	local success, message = pcall(
		MarketplaceService.PromptProductPurchase,
		MarketplaceService,
		player,
		Config.STARTER_PACK_ROBUX_PRODUCT_ID
	)
	if not success then
		pendingRobuxOpen = false
		setButtonsEnabled(card, true)
		warn(`[SkinCase] Robux prompt failed: {tostring(message)}`)
	end
end

local function consumeRobuxResult()
	local card = findCard()
	if not card then
		return
	end
	local success, result = invoke("ConsumeLastRobuxResult", nil)
	if success and result then
		applyOpenResult(card, result)
		enqueueOpeningResults(result)
	end
	pendingRobuxOpen = false
	setButtonsEnabled(card, true)
	updateCard(card)
end

local function disconnect()
	if coinConnection then
		coinConnection:Disconnect()
		coinConnection = nil
	end
	if robuxConnection then
		robuxConnection:Disconnect()
		robuxConnection = nil
	end
	if plusConnection then
		plusConnection:Disconnect()
		plusConnection = nil
	end
	if minusConnection then
		minusConnection:Disconnect()
		minusConnection = nil
	end
end

local function bindCard()
	bindingRevision += 1
	local revision = bindingRevision
	disconnect()

	task.spawn(function()
		local deadline = os.clock() + Config.UI_BIND_TIMEOUT_SECONDS
		repeat
			local card = findCard()
			local coinButton = card and findButton(card, Config.COIN_BUY_BUTTON_NAME)
			local robuxButton = card and findButton(card, Config.ROBUX_BUTTON_NAME)
			local plusButton = card and findButton(card, Config.PLUS_BUTTON_NAME)
			local minusButton = card and findButton(card, Config.MINUS_BUTTON_NAME)
			if card and coinButton and robuxButton and plusButton and minusButton then
				updateCard(card)
				coinConnection = coinButton.Activated:Connect(function()
					openWithCoins(card)
				end)
				robuxConnection = robuxButton.Activated:Connect(function()
					openWithRobux(card)
				end)
				plusConnection = plusButton.Activated:Connect(function()
					quantity += 1
					updateCard(card)
				end)
				minusConnection = minusButton.Activated:Connect(function()
					quantity -= 1
					updateCard(card)
				end)
				return
			end

			if revision ~= bindingRevision then
				return
			end
			task.wait(0.1)
		until revision ~= bindingRevision or os.clock() >= deadline

		if revision == bindingRevision then
			warn(
				"SkinCase: expected SkinShopGui.SkinsMainFrame.YouScrollingFrame."
					.. "CardStarterPack controls"
			)
		end
	end)
end

MarketplaceService.PromptProductPurchaseFinished:Connect(function(userId: number, productId: number, _wasPurchased: boolean)
	if userId ~= player.UserId or productId ~= Config.STARTER_PACK_ROBUX_PRODUCT_ID then
		return
	end

	task.delay(0.15, consumeRobuxResult)
	task.delay(1, consumeRobuxResult)
	task.delay(3, consumeRobuxResult)
end)

playerGui.DescendantAdded:Connect(function(descendant)
	if openingInProgress
		and descendant.Parent == playerGui
		and descendant.Name ~= Config.CASE_OPENING_GUI_NAME then
		if descendant:IsA("ScreenGui") then
			if hiddenOpeningGuiStates[descendant] == nil then
				hiddenOpeningGuiStates[descendant] = { Enabled = descendant.Enabled }
			end
			descendant.Enabled = false
		elseif descendant:IsA("GuiObject") then
			if hiddenOpeningGuiStates[descendant] == nil then
				hiddenOpeningGuiStates[descendant] = { Visible = descendant.Visible }
			end
			descendant.Visible = false
		end
	end

	if descendant.Name == Config.SKIN_SHOP_GUI_NAME
		or descendant.Name == Config.SKINS_MAIN_FRAME_NAME
		or descendant.Name == Config.YOU_SCROLLING_FRAME_NAME
		or descendant.Name == Config.CARD_STARTER_PACK_NAME
		or descendant.Name == Config.COIN_BUY_BUTTON_NAME
		or descendant.Name == Config.ROBUX_BUTTON_NAME
		or descendant.Name == Config.PLUS_BUTTON_NAME
		or descendant.Name == Config.MINUS_BUTTON_NAME then
		task.defer(bindCard)
	end
	if descendant.Name == Config.CASE_OPENING_GUI_NAME
		or descendant.Name == Config.CASE_OPENING_MAIN_FRAME_NAME
		or descendant.Name == Config.CASE_OPENING_CASE_NAME
		or descendant.Name == Config.CASE_OPENING_CHARACTER_NAME
		or descendant.Name == Config.CASE_OPENING_RAYS_NAME then
		if not openingInProgress then
			task.defer(hideOpeningGui)
		end
	end
end)

playerGui.DescendantRemoving:Connect(function(descendant)
	local card = findCard()
	if card and (descendant == card or descendant:IsAncestorOf(card)) then
		task.defer(bindCard)
	end
end)

bindCard()
task.defer(hideOpeningGui)
task.spawn(function()
	invoke("GetState", nil)
end)
