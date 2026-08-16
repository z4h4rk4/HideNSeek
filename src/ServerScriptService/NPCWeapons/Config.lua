--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local BatAttackConfig = require(ReplicatedStorage:WaitForChild("BatAttackConfig"))
local CageConfig = require(ReplicatedStorage:WaitForChild("CageConfig"))
local FistConfig = require(ReplicatedStorage:WaitForChild("FistConfig"))
local TrashCanConfig = require(ReplicatedStorage:WaitForChild("TrashCanConfig"))

local function interval(minimum: number, maximum: number)
	return table.freeze({
		Min = minimum,
		Max = maximum,
	})
end

return table.freeze({
	ENABLED = true,
	NPC_FOLDER_NAME = "RoundNPCs",
	ROUND_STATE_NAME = "RoundState",
	MANAGED_NPC_ATTRIBUTE = "ManagedRoundNPC",
	ROLE_ATTRIBUTE = "RoundRole",
	OWNED_TOOL_ATTRIBUTE = "NpcWeaponOwned",

	-- Hider NPCs can sabotage other Hiders, matching the existing Tool rules.
	-- Hunter stays a separate capture role and does not use this optional system.
	ALLOWED_ATTACKER_ROLES = table.freeze({
		Hider = true,
		Seeker = false,
	}),
	TARGET_ROLES_BY_ATTACKER = table.freeze({
		Hider = table.freeze({ Hider = true }),
		Seeker = table.freeze({ Hider = true }),
	}),
	ACTIVE_PHASES = table.freeze({
		Round = true,
	}),

	INITIAL_DELAY_SECONDS = interval(2, 5),
	THINK_INTERVAL_SECONDS = interval(0.35, 0.6),
	NO_TARGET_DELAY_SECONDS = interval(0.9, 1.5),
	REJECTED_ATTACK_DELAY_SECONDS = interval(1.5, 2.4),
	GLOBAL_ATTACK_GAP_SECONDS = 1.25,
	TARGET_REUSE_DELAY_SECONDS = 3.5,
	EQUIP_LEAD_TIME_SECONDS = 0.22,
	POST_ATTACK_HOLD_SECONDS = 0.85,
	MAX_TARGET_VERTICAL_DIFFERENCE = 6,

	WEAPON_ORDER = table.freeze({
		FistConfig.WEAPON_MODEL_NAME,
		BatAttackConfig.BAT_MODEL_NAME,
		CageConfig.WEAPON_MODEL_NAME,
		TrashCanConfig.WEAPON_MODEL_NAME,
	}),
	WEAPONS = table.freeze({
		[FistConfig.WEAPON_MODEL_NAME] = table.freeze({
			Weight = FistConfig.NPC_WEIGHT,
			Chance = FistConfig.NPC_ATTACK_CHANCE,
			MinRange = FistConfig.NPC_MIN_RANGE_STUDS,
			MaxRange = FistConfig.RANGE_STUDS,
			MaxVerticalDifference = FistConfig.MAX_VERTICAL_DIFFERENCE,
			MinFacingDot = FistConfig.MIN_TARGET_FORWARD_DOT,
			CooldownSeconds = interval(
				FistConfig.NPC_COOLDOWN_MIN_SECONDS,
				FistConfig.NPC_COOLDOWN_MAX_SECONDS
			),
			AttackAnimationName = nil,
		}),
		[BatAttackConfig.BAT_MODEL_NAME] = table.freeze({
			Weight = 5,
			Chance = 0.68,
			MinRange = 0,
			MaxRange = 4.5,
			MinFacingDot = 0.05,
			CooldownSeconds = interval(4.5, 7),
			AttackAnimationName = BatAttackConfig.ATTACK_ANIMATION_NAME,
		}),
		[CageConfig.WEAPON_MODEL_NAME] = table.freeze({
			Weight = 2,
			Chance = 0.48,
			MinRange = 0,
			MaxRange = 3.8,
			MinFacingDot = 0.05,
			CooldownSeconds = interval(7, 10),
			AttackAnimationName = BatAttackConfig.ATTACK_ANIMATION_NAME,
		}),
		[TrashCanConfig.WEAPON_MODEL_NAME] = table.freeze({
			Weight = 1,
			Chance = 0.34,
			MinRange = 1.5,
			MaxRange = 10,
			MinFacingDot = -0.15,
			CooldownSeconds = interval(9, 13),
			AttackAnimationName = nil,
		}),
	}),
})
