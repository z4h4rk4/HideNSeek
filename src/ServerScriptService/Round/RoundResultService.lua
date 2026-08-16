--!strict

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Config = require(ReplicatedStorage:WaitForChild("RoundResultConfig"))
local CurrencyService = require(
	script.Parent.Parent:WaitForChild("Currency"):WaitForChild("CurrencyService")
)
local CollectibleConfig = require(
	script.Parent.Parent:WaitForChild("Currency"):WaitForChild("CollectibleConfig")
)

type ParticipantStats = {
	Knockouts: number,
	Coins: number,
	EliminatedAt: number?,
}

local RoundResultService = {}

local participantStats: {[Player]: ParticipantStats} = {}
local capturedVictims: {[Instance]: boolean} = {}
local currencyChangedConnection: RBXScriptConnection? = nil
local resultRemote: RemoteEvent? = nil
local roundStartedAt = 0
local active = false
local started = false
local collectibleReasons: {[string]: boolean} = {}

local ROUND_STATE_NAME = "RoundState"
local ROUND_ROLE_ATTRIBUTE = "RoundRole"
local PHASE_ROUND = "Round"
local ROLE_HIDER = "Hider"
local ROLE_SEEKER = "Seeker"

local function getOrCreateRemote(): RemoteEvent
	local existing = ReplicatedStorage:FindFirstChild(Config.REMOTE_NAME)
	if existing then
		if not existing:IsA("RemoteEvent") then
			error(`ReplicatedStorage.{Config.REMOTE_NAME} must be a RemoteEvent`)
		end
		return existing
	end

	local remote = Instance.new("RemoteEvent")
	remote.Name = Config.REMOTE_NAME
	remote.Parent = ReplicatedStorage
	return remote
end

local function clearRound()
	active = false
	roundStartedAt = 0
	table.clear(participantStats)
	table.clear(capturedVictims)
end

local function ownerToPlayer(owner: Instance): Player?
	if owner:IsA("Player") then
		return owner
	end
	if owner:IsA("Model") then
		return Players:GetPlayerFromCharacter(owner)
	end
	return nil
end

local function recordKnockoutForPlayer(player: Player?)
	if not active or not player then
		return
	end
	local stats = participantStats[player]
	if not stats then
		return
	end
	stats.Knockouts += 1
end

local function isActiveRound(): boolean
	local roundState = ReplicatedStorage:FindFirstChild(ROUND_STATE_NAME)
	return active
		and roundState ~= nil
		and roundState:GetAttribute("Phase") == PHASE_ROUND
end

local function isCollectibleReason(reason: any): boolean
	return type(reason) == "string" and collectibleReasons[reason] == true
end

function RoundResultService.Start()
	if started then
		return
	end
	started = true
	resultRemote = getOrCreateRemote()
	for _, collectibleType in ipairs(CollectibleConfig.TYPES) do
		collectibleReasons[collectibleType.Reason] = true
	end
	currencyChangedConnection = CurrencyService.Changed:Connect(function(
		player: Player,
		_newBalance: number,
		delta: number,
		reason: string
	)
		if not isActiveRound()
			or type(delta) ~= "number"
			or delta <= 0
			or not isCollectibleReason(reason) then
			return
		end
		local stats = participantStats[player]
		if not stats then
			return
		end
		stats.Coins += math.max(0, math.floor(delta))
	end)
end

function RoundResultService.BeginRound(participants: {[Player]: string})
	RoundResultService.Start()
	clearRound()

	roundStartedAt = Workspace:GetServerTimeNow()
	for player in pairs(participants) do
		if player.Parent == Players then
			participantStats[player] = {
				Knockouts = 0,
				Coins = 0,
				EliminatedAt = nil,
			}
		end
	end
	active = true
end

function RoundResultService.MarkEliminated(player: Player)
	if not active then
		return
	end
	local stats = participantStats[player]
	if not stats or stats.EliminatedAt ~= nil then
		return
	end
	stats.EliminatedAt = Workspace:GetServerTimeNow()
end

function RoundResultService.RecordKnockdown(attackerCharacter: Model, targetCharacter: Model)
	local targetPlayer = Players:GetPlayerFromCharacter(targetCharacter)
	local targetRole = if targetPlayer
		then targetPlayer:GetAttribute(ROUND_ROLE_ATTRIBUTE)
		else targetCharacter:GetAttribute(ROUND_ROLE_ATTRIBUTE)
	if not isActiveRound()
		or attackerCharacter == targetCharacter
		or targetRole ~= ROLE_HIDER
		or (targetPlayer ~= nil and participantStats[targetPlayer] == nil) then
		return
	end
	local attacker = Players:GetPlayerFromCharacter(attackerCharacter)
	local attackerRole = if attacker then attacker:GetAttribute(ROUND_ROLE_ATTRIBUTE) else nil
	if attackerRole ~= ROLE_HIDER and attackerRole ~= ROLE_SEEKER then
		return
	end
	recordKnockoutForPlayer(attacker)
end

function RoundResultService.RecordCapture(captorOwner: Instance, victimOwner: Instance)
	local victimPlayer = ownerToPlayer(victimOwner)
	if not isActiveRound()
		or captorOwner == victimOwner
		or capturedVictims[victimOwner]
		or (victimPlayer ~= nil and participantStats[victimPlayer] == nil) then
		return
	end
	capturedVictims[victimOwner] = true
	recordKnockoutForPlayer(ownerToPlayer(captorOwner))
end

function RoundResultService.FinishRound()
	if not active then
		return
	end

	local finishedAt = Workspace:GetServerTimeNow()
	local remote = resultRemote
	active = false
	if remote and Config.DISPLAY_ENABLED then
		for player, stats in pairs(participantStats) do
			if player.Parent == Players then
				local survivedUntil = stats.EliminatedAt or finishedAt
				local secondsSurvived = math.max(0, math.floor(survivedUntil - roundStartedAt))
				remote:FireClient(player, {
					UserId = player.UserId,
					Name = player.Name,
					Knockouts = stats.Knockouts,
					SecondsSurvived = secondsSurvived,
					Coins = stats.Coins,
				})
			end
		end
	end
	clearRound()
end

function RoundResultService.CancelRound()
	clearRound()
end

return RoundResultService
