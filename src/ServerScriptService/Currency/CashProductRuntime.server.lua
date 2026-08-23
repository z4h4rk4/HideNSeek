local ok, message = pcall(function()
	local service = require(script.Parent:WaitForChild("CashProductService"))
	service.Start()
end)

if not ok then
	warn("CashProductService failed to start:\n" .. tostring(message))
end
