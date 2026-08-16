--!strict

local service = require(script.Parent:WaitForChild("WeaponShopService"))

local succeeded, message = pcall(service.Start)
if not succeeded then
	warn("WeaponShop failed to start:\n" .. tostring(message))
end
