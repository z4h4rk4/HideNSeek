--!strict

local Players = game:GetService("Players")

local MONEY_GUI_NAME = "MoneyPanelGui"
local MONEY_PANEL_NAME = "MoneyPanel"
local BALANCE_TEXT_NAME = "BalanceText"
local LEADERSTATS_NAME = "leaderstats"
local CURRENCY_VALUE_NAME = "Coins"

local localPlayer = Players.LocalPlayer
local playerGui = localPlayer:WaitForChild("PlayerGui")
local coinsValue: IntValue? = nil

local function getBalanceText(): TextLabel?
	local moneyGui = playerGui:FindFirstChild(MONEY_GUI_NAME)
	local moneyPanel = moneyGui and moneyGui:FindFirstChild(MONEY_PANEL_NAME)
	local balanceText = moneyPanel and moneyPanel:FindFirstChild(BALANCE_TEXT_NAME)
	if balanceText and balanceText:IsA("TextLabel") then
		return balanceText
	end
	return nil
end

local function updateDisplay()
	local balanceText = getBalanceText()
	if balanceText then
		balanceText.Text = if coinsValue then tostring(coinsValue.Value) else "..."
	end
end

playerGui.DescendantAdded:Connect(function(descendant)
	if descendant.Name == BALANCE_TEXT_NAME then
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
