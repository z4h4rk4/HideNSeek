--!strict

return table.freeze({
	SEARCH_SHAPE_VERSION = 2,
	SEARCH_SHAPE_VERSION_ATTRIBUTE = "SeekerSearchShapeVersion",
	RAYCAST_COLLISION_GROUP = "SeekerSearchRaycasts",
	SEARCH_RADIUS = 3,
	FORWARD_RADIUS_BONUS = 3,
	FORWARD_RAY_FRACTION = 1 / 4,
	MAX_VERTICAL_DIFFERENCE = 2,
	LINE_OF_SIGHT_HEIGHT = 1.5,
	SERVER_SCAN_INTERVAL = 0.1,
	-- Vision is separate from the short-range capture field above. Being seen
	-- can make a bot Seeker chase and reveal a Hider to a player Seeker, but it
	-- never captures the Hider by itself.
	VISION_DISTANCE = 12,
	VISION_TRACK_DISTANCE = 14,
	VISION_FOV_DEGREES = 80,
	VISION_TRACK_FOV_DEGREES = 105,
	-- A Hider who is almost touching the Hunter is noticed even slightly outside
	-- the normal forward cone. Walls still block this close-range awareness.
	VISION_CLOSE_ALERT_DISTANCE = 4.5,
	VISION_DETECTION_SECONDS = 0.15,
	VISION_LOST_GRACE_SECONDS = 0.65,
	VISION_REVEAL_FADE_SECONDS = 0.05,
	VISION_HIDE_FADE_SECONDS = 0.6,

	CAGED_ATTRIBUTE = "SearchCaged",
	RESCUE_PROGRESS_ATTRIBUTE = "SearchRescueProgress",
	FORCED_VISIBLE_ATTRIBUTE = "SearchForcedVisible",
	HIDER_INVISIBLE_ATTRIBUTE = "RoundHiderInvisible",
	PRESERVE_VISUAL_ATTRIBUTE = "RoundPreserveVisualWhenInvisible",

	VISUAL_RAY_COUNT = 64,
	VISUAL_UPDATE_INTERVAL = 1 / 30,
	VISUAL_WALL_PADDING = 0.1,
	VISUAL_FLOOR_OFFSET = 0.06,
	VISUAL_THICKNESS = 0.08,
	VISUAL_COLOR = Color3.fromRGB(255, 88, 28),
	VISUAL_TRANSPARENCY = 0.48,

	NORMAL_WALK_SPEED = 16,
})
