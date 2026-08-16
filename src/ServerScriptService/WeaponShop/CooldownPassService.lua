--!strict

local MarketplaceService = game:GetService("MarketplaceService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage:WaitForChild("CooldownPassConfig"))

local Service = {}
local started = false
local syncRevisions: {[Player]: number} = {}
local warnedOwnershipFailure: {[Player]: boolean} = {}
local verifiedOwnership: {[Player]: boolean} = {}
local verifiedOwnershipReady: {[Player]: boolean} = {}
local testOverrides: {[Player]: boolean?} = {}

local function applyEntitlement(player: Player)
	local testOverride = testOverrides[player]
	local owned = verifiedOwnership[player] == true
	local ready = verifiedOwnershipReady[player] == true
	if testOverride ~= nil then
		owned = testOverride
		ready = true
	end

	player:SetAttribute(Config.OWNED_ATTRIBUTE, owned)
	player:SetAttribute(Config.OWNERSHIP_READY_ATTRIBUTE, ready)
	player:SetAttribute(Config.TEST_OVERRIDE_ATTRIBUTE, testOverride)
end

local function setVerifiedOwnership(player: Player, owned: boolean, ready: boolean)
	verifiedOwnership[player] = owned
	verifiedOwnershipReady[player] = ready
	applyEntitlement(player)
end

local function syncOwnership(player: Player)
	local revision = (syncRevisions[player] or 0) + 1
	syncRevisions[player] = revision
	setVerifiedOwnership(player, false, false)

	task.spawn(function()
		local retryDelay = Config.OWNERSHIP_RETRY_INITIAL_SECONDS
		while player.Parent == Players and syncRevisions[player] == revision do
			local succeeded, ownsPass = pcall(
				MarketplaceService.UserOwnsGamePassAsync,
				MarketplaceService,
				player.UserId,
				Config.GAME_PASS_ID
			)
			if succeeded then
				warnedOwnershipFailure[player] = nil
				if player.Parent == Players and syncRevisions[player] == revision then
					setVerifiedOwnership(player, ownsPass == true, true)
				end
				return
			end

			if not warnedOwnershipFailure[player] then
				warnedOwnershipFailure[player] = true
				warn(
					`CooldownPass: ownership check failed for {player.Name}; `
						.. "the benefit stays locked until Roblox confirms ownership"
				)
			end
			task.wait(retryDelay)
			retryDelay = math.min(retryDelay * 2, Config.OWNERSHIP_RETRY_MAX_SECONDS)
		end
	end)
end

function Service.GetState(player: Player): {[string]: any}
	local testOverride = testOverrides[player]
	return {
		GamePassId = Config.GAME_PASS_ID,
		RealOwnershipReady = verifiedOwnershipReady[player] == true,
		RealOwned = verifiedOwnership[player] == true,
		EffectiveOwned = player:GetAttribute(Config.OWNED_ATTRIBUTE) == true,
		TestMode = if testOverride == nil
			then "Roblox"
			elseif testOverride
			then "Owned"
			else "Unowned",
	}
end

function Service.SetTestOverride(player: Player, override: boolean?): (boolean, any)
	if player.Parent ~= Players then
		return false, "TARGET_NOT_IN_SERVER"
	end
	if override ~= nil and type(override) ~= "boolean" then
		return false, "INVALID_OVERRIDE"
	end

	-- This value is deliberately server-memory only. It lets an authorized admin
	-- test both entitlement states without granting, revoking, or saving a pass.
	testOverrides[player] = override
	applyEntitlement(player)
	return true, Service.GetState(player)
end

function Service.Start()
	if started then
		return
	end
	started = true
	assert(
		type(Config.GAME_PASS_ID) == "number" and Config.GAME_PASS_ID > 0,
		"CooldownPassConfig.GAME_PASS_ID must be a positive number"
	)
	assert(
		type(Config.COOLDOWN_MULTIPLIER) == "number"
			and Config.COOLDOWN_MULTIPLIER > 0
			and Config.COOLDOWN_MULTIPLIER <= 1,
		"CooldownPassConfig.COOLDOWN_MULTIPLIER must be in (0, 1]"
	)

	MarketplaceService.PromptGamePassPurchaseFinished:Connect(function(
		player: Player,
		gamePassId: number,
		wasPurchased: boolean
	)
		if gamePassId ~= Config.GAME_PASS_ID
			or not wasPurchased
			or player.Parent ~= Players then
			return
		end

		-- This is the server-only MarketplaceService completion signal. Grant the
		-- permanent benefit immediately so a paying player does not wait for a
		-- possibly cached ownership query. Future sessions verify inventory again.
		syncRevisions[player] = (syncRevisions[player] or 0) + 1
		warnedOwnershipFailure[player] = nil
		testOverrides[player] = nil
		setVerifiedOwnership(player, true, true)
	end)

	Players.PlayerAdded:Connect(syncOwnership)
	Players.PlayerRemoving:Connect(function(player)
		syncRevisions[player] = nil
		warnedOwnershipFailure[player] = nil
		verifiedOwnership[player] = nil
		verifiedOwnershipReady[player] = nil
		testOverrides[player] = nil
	end)
	for _, player in ipairs(Players:GetPlayers()) do
		syncOwnership(player)
	end
end

return Service
