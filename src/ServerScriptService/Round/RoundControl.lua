--!strict

export type Arguments = {[string]: any}
export type Handler = (action: string, arguments: Arguments) -> (boolean, string, any?)

local RoundControl = {}
local registeredHandler: Handler? = nil

function RoundControl.Register(handler: Handler)
	if registeredHandler then
		error("RoundControl already has a registered handler")
	end
	registeredHandler = handler
end

function RoundControl.Execute(action: string, arguments: Arguments?): (boolean, string, any?)
	if type(action) ~= "string" then
		return false, "Invalid round-control action.", nil
	end
	local handler = registeredHandler
	if not handler then
		return false, "The round service is not ready yet.", nil
	end
	return handler(action, arguments or {})
end

return table.freeze(RoundControl)
