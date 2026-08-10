--!strict

local Players = game:GetService("Players")

local Config = require(script.Parent:WaitForChild("AdminConfig"))
local Validation = require(script.Parent:WaitForChild("AdminValidationCore"))
local AdminService = require(script.Parent:WaitForChild("AdminService"))

local clientTemplate = script.Parent:WaitForChild(Config.ClientTemplateName)
if not clientTemplate:IsA("LocalScript") then
	error(Config.ClientTemplateName .. " must be a LocalScript")
end

type CacheEntry = {
	Fingerprint: string,
	Response: {[string]: any},
}
type PlayerCache = {
	Entries: {[string]: CacheEntry},
	Order: {string},
}

local busy: {[Player]: boolean} = {}
local lastRequestAt: {[Player]: number} = {}
local lastActionAt: {[Player]: {[string]: number}} = {}
local lastResourceActionAt: {[string]: number} = {}
local lastAcceptedSequence: {[Player]: number} = {}
local responseCaches: {[Player]: PlayerCache} = {}

local function basicResponse(ok: boolean, reason: string, message: string): {[string]: any}
	return {
		Ok = ok,
		Reason = reason,
		Message = message,
	}
end

local function unauthorized(player: Player): {[string]: any}
	warn(("[AdminSecurity] Unauthorized request by %s (%d)"):format(player.Name, player.UserId))
	return basicResponse(false, "UNAUTHORIZED", "Access denied.")
end

local function payloadFingerprint(payload: {[any]: any}): string?
	local keys: {string} = {}
	for key, value in payload do
		if type(key) ~= "string" or #key > 64 then
			return nil
		end
		local valueType = type(value)
		if valueType ~= "string" and valueType ~= "number" and valueType ~= "boolean" then
			return nil
		end
		if valueType == "string" and #value > 128 then
			return nil
		end
		if valueType == "number"
			and (value ~= value or value == math.huge or value == -math.huge) then
			return nil
		end
		table.insert(keys, key)
		if #keys > 8 then
			return nil
		end
	end
	table.sort(keys)
	local pieces: {string} = {}
	for _, key in keys do
		local value = payload[key]
		table.insert(pieces, key .. ":" .. type(value) .. "=" .. tostring(value))
	end
	return table.concat(pieces, "|")
end

type SanitizeBudget = {
	Nodes: number,
	Exceeded: boolean,
}

local function sanitize(value: any, depth: number?, budget: SanitizeBudget?): any
	local currentDepth = depth or 0
	local currentBudget = budget or { Nodes = 0, Exceeded = false }
	currentBudget.Nodes += 1
	if currentBudget.Nodes > Config.MaxResponseNodes then
		currentBudget.Exceeded = true
		return nil
	end
	local valueType = type(value)
	if valueType == "boolean" then
		return value
	elseif valueType == "string" then
		return string.sub(value, 1, 512)
	elseif valueType == "number" then
		if value == value and value ~= math.huge and value ~= -math.huge then
			return value
		end
		return nil
	elseif valueType ~= "table" or currentDepth >= 4 then
		return nil
	end

	local result: {[string]: any} = {}
	local count = 0
	for key, child in value do
		if type(key) == "string" and #key <= 64 then
			local sanitized = sanitize(child, currentDepth + 1, currentBudget)
			if sanitized ~= nil then
				result[key] = sanitized
				count += 1
				if count >= 64 then
					break
				end
			end
		end
	end
	return result
end

local function getCache(player: Player): PlayerCache
	local cache = responseCaches[player]
	if cache then
		return cache
	end
	cache = {
		Entries = {},
		Order = {},
	}
	responseCaches[player] = cache
	return cache
end

local function cacheResponse(
	player: Player,
	requestId: string,
	fingerprint: string,
	result: {[string]: any}
)
	local cache = getCache(player)
	cache.Entries[requestId] = {
		Fingerprint = fingerprint,
		Response = result,
	}
	table.insert(cache.Order, requestId)
	while #cache.Order > Config.ResponseCacheSize do
		local oldest = table.remove(cache.Order, 1)
		cache.Entries[oldest] = nil
	end
end

local function mountPanel(player: Player)
	if not AdminService.IsAuthorized(player) then
		return
	end

	local playerGui = player:WaitForChild("PlayerGui", 15)
	if not playerGui or player.Parent ~= Players then
		return
	end
	if playerGui:FindFirstChild(Config.GuiName) then
		return
	end

	local screenGui = Instance.new("ScreenGui")
	screenGui.Name = Config.GuiName
	screenGui.ResetOnSpawn = false
	screenGui.IgnoreGuiInset = true
	screenGui.DisplayOrder = 1000
	screenGui.ZIndexBehavior = Enum.ZIndexBehavior.Global
	screenGui:SetAttribute("ServerAuthorizedAdminPanel", true)

	local remote = Instance.new("RemoteFunction")
	remote.Name = Config.RemoteName
	remote.OnServerInvoke = function(invokingPlayer: Player, payload: any)
		if invokingPlayer ~= player or not AdminService.IsAuthorized(invokingPlayer) then
			return unauthorized(invokingPlayer)
		end
		if type(payload) ~= "table" then
			return basicResponse(false, "INVALID_REQUEST", "Invalid request.")
		end

		local requestId = payload.RequestId
		if not Validation.IsRequestId(
			requestId,
			Config.MinRequestIdLength,
			Config.MaxRequestIdLength
		) then
			return basicResponse(false, "INVALID_REQUEST_ID", "Invalid request identifier.")
		end
		local sequence = Validation.ParseIntegerInRange(
			payload.Sequence,
			1,
			Config.MaxRequestSequence
		)
		if not sequence then
			return basicResponse(false, "INVALID_SEQUENCE", "Invalid request sequence.")
		end
		local fingerprint = payloadFingerprint(payload)
		if not fingerprint then
			return basicResponse(false, "INVALID_REQUEST", "Invalid request payload.")
		end

		local cache = getCache(invokingPlayer)
		local cached = cache.Entries[requestId]
		if cached then
			if cached.Fingerprint ~= fingerprint then
				warn(("[AdminSecurity] RequestId reuse by %s (%d)"):format(
					invokingPlayer.Name,
					invokingPlayer.UserId
				))
				return basicResponse(false, "REQUEST_ID_REUSED", "Request identifier was reused.")
			end
			return cached.Response
		end
		if sequence <= (lastAcceptedSequence[invokingPlayer] or 0) then
			return basicResponse(false, "STALE_REQUEST", "This request was already processed.")
		end

		if busy[invokingPlayer] then
			return basicResponse(false, "REQUEST_IN_PROGRESS", "Another request is still running.")
		end
		local now = os.clock()
		if now - (lastRequestAt[invokingPlayer] or 0) < Config.RequestCooldownSeconds then
			return basicResponse(false, "RATE_LIMITED", "Please wait before sending another request.")
		end
		local action = if type(payload.Action) == "string" then payload.Action else ""
		local actionCooldown = Config.ActionCooldownSeconds[action]
		local resourceKey = Config.ActionResourceKeys[action]
		local resourceCooldown = if resourceKey
			then Config.ResourceCooldownSeconds[resourceKey]
			else nil
		local playerActionTimes = lastActionAt[invokingPlayer]
		if actionCooldown
			and playerActionTimes
			and now - (playerActionTimes[action] or 0) < actionCooldown then
			return basicResponse(false, "ACTION_RATE_LIMITED", "Please wait before repeating this action.")
		end
		if resourceKey
			and resourceCooldown
			and now - (lastResourceActionAt[resourceKey] or 0) < resourceCooldown then
			return basicResponse(false, "RESOURCE_RATE_LIMITED", "Please wait before changing this server resource again.")
		end

		lastRequestAt[invokingPlayer] = now
		lastAcceptedSequence[invokingPlayer] = sequence
		if actionCooldown then
			if not playerActionTimes then
				playerActionTimes = {}
				lastActionAt[invokingPlayer] = playerActionTimes
			end
			playerActionTimes[action] = now
		end
		if resourceKey then
			lastResourceActionAt[resourceKey] = now
		end
		busy[invokingPlayer] = true
		local handled, rawResult = xpcall(function()
			return AdminService.HandleRequest(invokingPlayer, payload)
		end, debug.traceback)
		busy[invokingPlayer] = nil

		local result: {[string]: any}
		if not handled then
			warn(("[AdminPanel] Request failed for %s (%d):\n%s"):format(
				invokingPlayer.Name,
				invokingPlayer.UserId,
				tostring(rawResult)
			))
			result = basicResponse(false, "SERVER_ERROR", "Internal server error.")
		else
			local responseBudget: SanitizeBudget = { Nodes = 0, Exceeded = false }
			local sanitized = sanitize(rawResult, 0, responseBudget)
			if responseBudget.Exceeded or type(sanitized) ~= "table" then
				result = basicResponse(false, "SERVER_ERROR", "Invalid server response.")
			else
				result = sanitized
			end
		end
		result.RequestId = requestId
		if invokingPlayer.Parent == Players then
			cacheResponse(invokingPlayer, requestId, fingerprint, result)
		end
		return result
	end
	remote.Parent = screenGui

	local client = clientTemplate:Clone()
	client.Name = Config.ClientTemplateName
	client.Parent = screenGui
	screenGui.Parent = playerGui
	print(("[AdminPanel] Mounted secure panel for %s (%d)"):format(player.Name, player.UserId))
end

Players.PlayerAdded:Connect(function(player)
	task.spawn(mountPanel, player)
end)

Players.PlayerRemoving:Connect(function(player)
	busy[player] = nil
	lastRequestAt[player] = nil
	lastActionAt[player] = nil
	lastAcceptedSequence[player] = nil
	responseCaches[player] = nil
end)

for _, player in Players:GetPlayers() do
	task.spawn(mountPanel, player)
end
