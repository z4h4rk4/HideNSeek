--!strict

local StarterGui = game:GetService("StarterGui")

local RETRY_COUNT = 30
local RETRY_DELAY_SECONDS = 0.2

for _ = 1, RETRY_COUNT do
	local succeeded = pcall(function()
		StarterGui:SetCore("ResetButtonCallback", false)
	end)
	if succeeded then
		break
	end
	task.wait(RETRY_DELAY_SECONDS)
end
