--!strict

local boards = table.freeze({
	Currency = table.freeze({
		MODEL_NAME = "LeaderBoardTheRichest",
		STORE_NAME = "HideNSeekLeaderboardRichest_v1",
		SCORE_KIND = "Integer",
	}),
	PlayTimeSeconds = table.freeze({
		MODEL_NAME = "LeaderBoardTheMostActive",
		STORE_NAME = "HideNSeekLeaderboardMostActive_v1",
		SCORE_KIND = "Duration",
	}),
	Wins = table.freeze({
		MODEL_NAME = "LeaderBoardTopWins",
		STORE_NAME = "HideNSeekLeaderboardTopWins_v1",
		SCORE_KIND = "Integer",
	}),
})

return table.freeze({
	DATASTORE_SCOPE = "global",
	MAX_SCORE = 1_000_000_000_000_000,
	MAX_ENTRIES = 10,

	HUB_NAME = "HUB",
	ROOT_NAME = "LeaderBoards",
	SCORE_BLOCK_NAME = "ScoreBlock",
	LIST_NAME = "LeaderBoard",
	TEMPLATE_NAME = "PlayerCard",
	PHOTO_NAME = "Photo",
	PLAYER_NAME = "Name",
	NUMBER_NAME = "Number",
	SCORE_NAME = "Score",
	GENERATED_ATTRIBUTE = "GeneratedLeaderboardCard",

	INITIAL_REFRESH_DELAY_SECONDS = 5,
	REFRESH_INTERVAL_SECONDS = 60,
	FIRST_WRITE_REFRESH_DELAY_SECONDS = 3,
	MOUNT_RETRY_SECONDS = 2,
	MOUNT_ATTEMPTS = 15,
	INITIAL_WRITE_DELAY_SECONDS = 1,
	WRITE_DEBOUNCE_SECONDS = 10,
	FAILED_WRITE_RETRY_SECONDS = 30,
	WRITE_ATTEMPTS = 4,
	WRITE_RETRY_BASE_SECONDS = 1,
	WRITE_RETRY_MAX_SECONDS = 6,
	PROFILE_LOAD_WAIT_SECONDS = 60,

	BOARD_ORDER = table.freeze({ "Currency", "PlayTimeSeconds", "Wins" }),
	BOARDS = boards,
})
