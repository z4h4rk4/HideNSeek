--!strict

local Players = game:GetService("Players")

local ICONS_GUI_NAME = "IconsGui"
local SKIN_SHOP_GUI_NAME = "SkinShopGui"
local MAIN_FRAME_NAME = "MainFrame"
local SKINS_MAIN_FRAME_NAME = "SkinsMainFrame"
local MONEY_PANEL_NAME = "MoneyPanel"
local BALANCE_TEXT_NAME = "BalanceText"
local LEADERSTATS_NAME = "leaderstats"
local CURRENCY_VALUE_NAME = "Coins"

local localPlayer = Players.LocalPlayer
local playerGui = localPlayer:WaitForChild("PlayerGui")
local coinsValue: IntValue? = nil

local function addBalanceText(textLabels: {TextLabel}, root: Instance?, mainFrameName: string)
	local mainFrame = root and root:FindFirstChild(mainFrameName, true)
	local moneyPanel = mainFrame and mainFrame:FindFirstChild(MONEY_PANEL_NAME, true)
	local balanceText = moneyPanel and moneyPanel:FindFirstChild(BALANCE_TEXT_NAME, true)
	if balanceText and balanceText:IsA("TextLabel") then
		table.insert(textLabels, balanceText)
	end
end

local function getBalanceTexts(): {TextLabel}
	local textLabels: {TextLabel} = {}
	local iconsGui = playerGui:FindFirstChild(ICONS_GUI_NAME)
	addBalanceText(textLabels, iconsGui, MAIN_FRAME_NAME)

	local skinShopGui = playerGui:FindFirstChild(SKIN_SHOP_GUI_NAME)
	addBalanceText(textLabels, skinShopGui, SKINS_MAIN_FRAME_NAME)

	return textLabels
end

local function updateDisplay()
	for _, balanceText in ipairs(getBalanceTexts()) do
		balanceText.Text = if coinsValue then tostring(coinsValue.Value) else "..."
	end
end

playerGui.DescendantAdded:Connect(function(descendant)
	if descendant.Name == BALANCE_TEXT_NAME
		or descendant.Name == MONEY_PANEL_NAME
		or descendant.Name == ICONS_GUI_NAME
		or descendant.Name == SKIN_SHOP_GUI_NAME then
		task.defer(updateDisplay)
	end
end)

updateDisplay()

task.spawn(function()
	local leaderstats = localPlayer:WaitForChild(LEADERSTATS_NAME)
	local value = leaderstats:WaitForChild(CURRENCY_VALUE_NAME)
	if not value:IsA("IntValue") then
		warn(`leaderstats.{CURRENCY_VALUE_NAME} must be an IntValue`)
		return
	end

	coinsValue = value
	value:GetPropertyChangedSignal("Value"):Connect(updateDisplay)
	updateDisplay()
end)
