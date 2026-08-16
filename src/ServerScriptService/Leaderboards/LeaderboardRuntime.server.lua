local ok, err = xpcall(function()
	local LeaderboardService = require(script.Parent:WaitForChild("LeaderboardService"))
	LeaderboardService.Start()
end, debug.traceback)

if not ok then
	warn("[Leaderboards] Fatal startup error:\n" .. tostring(err))
end
