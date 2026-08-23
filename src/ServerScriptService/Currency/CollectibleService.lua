--!strict

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local CollectibleConfig = require(script.Parent:WaitForChild("CollectibleConfig"))
local CurrencyService = require(script.Parent:WaitForChild("CurrencyService"))
local GamePassService = require(
	ServerScriptService:WaitForChild("WeaponShop"):WaitForChild("CooldownPassService")
)

local CollectibleService = {}

local registered: {[Instance]: {RBXScriptConnection}} = {}
local claimed: {[Instance]: boolean} = {}
local tagConnections: {RBXScriptConnection} = {}
local started = false
local pickupRemote: RemoteEvent? = nil

local ROUND_STATE_NAME = "RoundState"
local PHASE_STARTING = "Starting"
local PHASE_ROUND = "Round"
local ROLE_HIDER = "Hider"
local ROLE_SEEKER = "Seeker"

local function getOrCreatePickupRemote(): RemoteEvent
	local existing = ReplicatedStorage:FindFirstChild(CollectibleConfig.PICKUP_REMOTE_NAME)
	if existing then
		if not existing:IsA("RemoteEvent") then
			error(`ReplicatedStorage.{CollectibleConfig.PICKUP_REMOTE_NAME} must be a RemoteEvent`)
		end
		return existing
	end

	local remote = Instance.new("RemoteEvent")
	remote.Name = CollectibleConfig.PICKUP_REMOTE_NAME
	remote.Parent = ReplicatedStorage
	return remote
end

local function disconnectCollectible(collectible: Instance)
	local connections = registered[collectible]
	if connections then
		for _, connection in ipairs(connections) do
			connection:Disconnect()
		end
	end
	registered[collectible] = nil
	claimed[collectible] = nil
end

local function getPlayerFromHit(hit: BasePart): (Player?, Model?)
	local character = hit:FindFirstAncestorOfClass("Model")
	if not character then
		return nil, nil
	end

	local player = Players:GetPlayerFromCharacter(character)
	if not player then
		return nil, nil
	end
	return player, character
end

local function canCollect(player: Player, collectible: Instance, character: Model): boolean
	local roundState = ReplicatedStorage:FindFirstChild(ROUND_STATE_NAME)
	local role = player:GetAttribute("RoundRole")
	local phase = if roundState then roundState:GetAttribute("Phase") else nil
	if not roundState
		or (phase ~= PHASE_STARTING and phase ~= PHASE_ROUND)
		or (role ~= ROLE_HIDER and role ~= ROLE_SEEKER) then
		return false
	end

	local humanoid = character:FindFirstChildOfClass("Humanoid")
	local rootPart = character:FindFirstChild("HumanoidRootPart")
	if not humanoid or humanoid.Health <= 0 or not rootPart or not rootPart:IsA("BasePart") then
		return false
	end
	if not (collectible:IsA("BasePart") or collectible:IsA("Model")) then
		return false
	end

	local offset = rootPart.Position - collectible:GetPivot().Position
	return offset:Dot(offset) <= CollectibleConfig.MAX_PICKUP_DISTANCE ^ 2
end

local function collect(collectible: Instance, collectibleType, hit: BasePart)
	if claimed[collectible] or not collectible:IsDescendantOf(workspace) then
		return
	end

	local player, character = getPlayerFromHit(hit)
	if not player or not character or not canCollect(player, collectible, character) then
		return
	end

	claimed[collectible] = true
	local reward, previousCashRemainder = GamePassService.ApplyCashMultiplier(player, collectibleType.Reward)
	local ok, _, reason = CurrencyService.AddCurrency(
		player,
		reward,
		collectibleType.Reason
	)
	if ok then
		if pickupRemote then
			pickupRemote:FireClient(player)
		end
		collectible:Destroy()
		return
	end

	claimed[collectible] = nil
	GamePassService.RestoreCashMultiplierRemainder(player, previousCashRemainder)
	if reason ~= "NOT_LOADED" and reason ~= "PROFILE_CLOSING" then
		warn(("[Collectible] Could not grant %d Coins to %s: %s"):format(
			reward,
			player.Name,
			tostring(reason)
		))
	end
end

local function registerCollectible(collectible: Instance, collectibleType)
	if registered[collectible] or not collectible:IsDescendantOf(workspace) then
		return
	end
	if not (collectible:IsA("BasePart") or collectible:IsA("Model")) then
		warn(`[Collectible] Tagged object is not a BasePart or Model: {collectible:GetFullName()}`)
		return
	end

	local connections = {}
	registered[collectible] = connections

	local function connectPart(part: BasePart)
		part.CanTouch = true
		table.insert(connections, part.Touched:Connect(function(hit)
			collect(collectible, collectibleType, hit)
		end))
	end

	if collectible:IsA("BasePart") then
		connectPart(collectible)
	end
	for _, descendant in ipairs(collectible:GetDescendants()) do
		if descendant:IsA("BasePart") then
			connectPart(descendant)
		end
	end

	if #connections == 0 then
		registered[collectible] = nil
		warn(`[Collectible] Tagged model has no BaseParts: {collectible:GetFullName()}`)
		return
	end

	table.insert(connections, collectible.Destroying:Connect(function()
		disconnectCollectible(collectible)
	end))
end

function CollectibleService.Start()
	if started then
		return
	end
	started = true
	pickupRemote = getOrCreatePickupRemote()

	for _, collectibleType in ipairs(CollectibleConfig.TYPES) do
		for _, collectible in ipairs(CollectionService:GetTagged(collectibleType.Tag)) do
			registerCollectible(collectible, collectibleType)
		end

		table.insert(
			tagConnections,
			CollectionService:GetInstanceAddedSignal(collectibleType.Tag):Connect(function(collectible)
				registerCollectible(collectible, collectibleType)
			end)
		)
		table.insert(
			tagConnections,
			CollectionService:GetInstanceRemovedSignal(collectibleType.Tag):Connect(function(collectible)
				disconnectCollectible(collectible)
			end)
		)
	end

	print("[Collectible] Coin rewards enabled with game pass multipliers")
end

return CollectibleService
