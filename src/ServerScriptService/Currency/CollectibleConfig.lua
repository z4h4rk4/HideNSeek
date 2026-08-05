--!strict

local coin = table.freeze({
	Tag = "ClientSpinningCoin",
	Reward = 1,
	Reason = "CoinPickup",
})

local goldBar = table.freeze({
	Tag = "ClientSpinningGoldBar",
	Reward = 3,
	Reason = "GoldBarPickup",
})

return table.freeze({
	MAX_PICKUP_DISTANCE = 10,
	PICKUP_REMOTE_NAME = "CollectiblePickedUp",
	TYPES = table.freeze({ coin, goldBar }),
})
