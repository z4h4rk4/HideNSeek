--!strict

local service = require(script.Parent:WaitForChild("CooldownPassService"))

local succeeded, message = pcall(service.Start)
if not succeeded then
	warn("CooldownPass failed to start:\n" .. tostring(message))
end
