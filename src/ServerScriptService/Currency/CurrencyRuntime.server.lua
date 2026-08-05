local Players = game:GetService("Players")

local ok, err = xpcall(function()
	local CurrencyService = require(script.Parent:WaitForChild("CurrencyService"))
	local CollectibleService = require(script.Parent:WaitForChild("CollectibleService"))
	CurrencyService.Start()
	CollectibleService.Start()
end, debug.traceback)

if not ok then
	warn("[Currency] Fatal startup error:\n" .. tostring(err))
	Players.PlayerAdded:Connect(function(player)
		player:Kick("The currency system failed to start. Please rejoin later.")
	end)
	for _, player in ipairs(Players:GetPlayers()) do
		player:Kick("The currency system failed to start. Please rejoin later.")
	end
end
