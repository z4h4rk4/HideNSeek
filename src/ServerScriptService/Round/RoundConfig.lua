--!strict

local npcColors = table.freeze({
	Color3.fromRGB(255, 99, 107),
	Color3.fromRGB(70, 205, 255),
	Color3.fromRGB(183, 112, 255),
	Color3.fromRGB(116, 232, 123),
	Color3.fromRGB(255, 205, 75),
	Color3.fromRGB(79, 126, 255),
	Color3.fromRGB(255, 120, 211),
	Color3.fromRGB(255, 145, 61),
})

return table.freeze({
	STARTING_DURATION_SECONDS = 20,
	ROUND_DURATION_SECONDS = 60,
	ROUND_END_HIDER_COUNT = 1,
	-- The Starting countdown begins in HUB. Participants are moved to the
	-- arena only for its final ARENA_READY_DURATION_SECONDS.
	ARENA_READY_DURATION_SECONDS = 5,
	-- Clone the next ServerStorage/Arenas template at this point in the
	-- Starting countdown. The previous runtime arena stays loaded until then.
	ARENA_LOAD_REMAINING_SECONDS = 10,
	MINIMUM_PLAYERS = 1,
	MAX_HIDERS = 6,
	MAX_SEEKERS = 1,
	BOT_SEEKER_MODE = true,
	PLAYER_SEEKER_CHANCE = 0,
	WALK_SPEED = 10,
	SEEKER_WALK_SPEED = 5,
	SEEKER_SCALE_MULTIPLIER = 1.5,
	DOOR_COLLIDER = table.freeze({
		-- Preserve each role's real width, but replace the animated multi-part
		-- contact with one slightly inset, smooth vertical cylinder.
		DIAMETER_MULTIPLIER = 0.9,
		HEIGHT_MULTIPLIER = 1,
		MIN_DIAMETER = 1.4,
		MIN_HEIGHT = 1.6,
	}),
	ROLE_HIDER = "Hider",
	ROLE_SEEKER = "Seeker",
	ROLE_SPECTATOR = "Spectator",
	PHASE_WAITING = "Waiting",
	PHASE_PREPARING = "Preparing",
	PHASE_STARTING = "Starting",
	PHASE_ROUND = "Round",
	PHASE_ENDED = "Ended",

	NPC = table.freeze({
		SPAWN_SPACING = 4,
		SPAWN_CLEARANCE = 0.1,
		MAX_ACTIVE_NPCS = 6,
		AUTOMATIC_HIDER_COUNT_BY_PLAYER_COUNT = table.freeze({
			[1] = 5,
			[2] = 3,
		}),
		COLORS = npcColors,
	}),
})
