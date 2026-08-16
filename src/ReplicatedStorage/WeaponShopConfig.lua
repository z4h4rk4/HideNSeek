--!strict

local fists = table.freeze({
	WEAPON_NAME = "Fists",
	DISPLAY_NAME = "Fists",
	FREE = true,
	BUTTON_NAME = "FistBtn",
	PURCHASE_FRAME_NAME = nil,
	TIMER_FRAME_NAME = nil,
	CURRENCY_PRICE = 0,
	GAME_PASS_ID = 0,
	COOLDOWN_MIN_SECONDS = 0.3,
	COOLDOWN_MAX_SECONDS = 0.3,
	ATTACK_ICON_IMAGE = nil,
	ATTACK_ICON_ROTATION = nil,
})

local bat = table.freeze({
	WEAPON_NAME = "BatModel",
	DISPLAY_NAME = "Bat",
	FREE = false,
	BUTTON_NAME = "BatBtn",
	PURCHASE_FRAME_NAME = "BatFrame",
	TIMER_FRAME_NAME = "BatTimerFrame",
	CURRENCY_PRICE = 25,
	GAME_PASS_ID = 0, -- Set the published Game Pass ID.
	COOLDOWN_MIN_SECONDS = 3,
	COOLDOWN_MAX_SECONDS = 3,
	ATTACK_ICON_IMAGE = "rbxassetid://112363019868873",
	ATTACK_ICON_ROTATION = 0,
})

local cage = table.freeze({
	WEAPON_NAME = "CageModel",
	DISPLAY_NAME = "Cage",
	FREE = false,
	BUTTON_NAME = "CageBtn",
	PURCHASE_FRAME_NAME = "CageFrame",
	TIMER_FRAME_NAME = "CageTimerFrame",
	CURRENCY_PRICE = 50,
	GAME_PASS_ID = 0, -- Set the published Game Pass ID.
	COOLDOWN_MIN_SECONDS = 25,
	COOLDOWN_MAX_SECONDS = 25,
	ATTACK_ICON_IMAGE = "rbxassetid://120887538496096",
	ATTACK_ICON_ROTATION = -35,
})

local trashCan = table.freeze({
	WEAPON_NAME = "TrashCan",
	DISPLAY_NAME = "Trash Can",
	FREE = false,
	BUTTON_NAME = "TrashCanBtn",
	PURCHASE_FRAME_NAME = "TrashCanFrame",
	TIMER_FRAME_NAME = "TrashCanTimerFrame",
	CURRENCY_PRICE = 100,
	GAME_PASS_ID = 0, -- Set the published Game Pass ID.
	COOLDOWN_MIN_SECONDS = 15,
	COOLDOWN_MAX_SECONDS = 15,
	ATTACK_ICON_IMAGE = "rbxassetid://140110369805889",
	ATTACK_ICON_ROTATION = 0,
})

local items = table.freeze({ fists, bat, cage, trashCan })
local byWeapon = table.freeze({
	[fists.WEAPON_NAME] = fists,
	[bat.WEAPON_NAME] = bat,
	[cage.WEAPON_NAME] = cage,
	[trashCan.WEAPON_NAME] = trashCan,
})

return table.freeze({
	DEBUG_LOGGING = true,
	ICON_FRAME_NAME = "IconFrame",
	BUY_BUTTON_NAME = "BuyBtn",
	PRICE_TEXT_NAME = "Price",
	TIMER_TEXT_NAME = "Timer",

	PURCHASE_REMOTE_NAME = "WeaponShopRequest",
	PURCHASE_ACTION = "BuyWithCurrency",
	OWNED_ATTRIBUTE_PREFIX = "WeaponOwned_",
	COOLDOWN_ATTRIBUTE_PREFIX = "WeaponCooldownUntil_",
	ROUND_ARENA_TELEPORT_REVISION_ATTRIBUTE = "RoundArenaTeleportRevision",
	OWNERSHIP_READY_ATTRIBUTE = "WeaponOwnershipReady",
	REQUEST_COOLDOWN_SECONDS = 0.5,
	CLIENT_COOLDOWN_BUFFER_SECONDS = 0.08,

	ITEMS = items,
	BY_WEAPON = byWeapon,
})
