--!strict

local AdminValidationCore = {}

function AdminValidationCore.ParseIntegerInRange(
	raw: any,
	minimum: number,
	maximum: number
): number?
	local value: number? = nil
	if type(raw) == "number" then
		value = raw
	elseif type(raw) == "string" then
		local digits = string.match(raw, "^%s*(%d+)%s*$")
		if digits then
			value = tonumber(digits)
		end
	end

	if type(value) ~= "number"
		or value ~= value
		or value == math.huge
		or value == -math.huge
		or value % 1 ~= 0
		or value < minimum
		or value > maximum then
		return nil
	end
	return value
end

function AdminValidationCore.IsAuthorizedUserId(
	userId: any,
	allowedUserIds: {[number]: boolean}
): boolean
	return type(userId) == "number"
		and userId % 1 == 0
		and allowedUserIds[userId] == true
end

function AdminValidationCore.IsRequestId(
	value: any,
	minimumLength: number,
	maximumLength: number
): boolean
	return type(value) == "string"
		and #value >= minimumLength
		and #value <= maximumLength
		and string.match(value, "^[%w_%-]+$") ~= nil
end

function AdminValidationCore.HasOnlyKeys(payload: {[any]: any}, allowedKeys: {[string]: boolean}): boolean
	local count = 0
	for key in payload do
		if type(key) ~= "string" or not allowedKeys[key] then
			return false
		end
		count += 1
		if count > 8 then
			return false
		end
	end
	return true
end

return table.freeze(AdminValidationCore)
