local ok, message = pcall(function()
	local service = require(script.Parent:WaitForChild("SkinCaseService"))
	service.Start()
end)

if not ok then
	warn("SkinCaseService failed to start:\n" .. tostring(message))
end
