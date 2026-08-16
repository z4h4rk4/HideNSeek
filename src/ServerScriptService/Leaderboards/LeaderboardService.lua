--!strict

local DataStoreService = game:GetService("DataStoreService")
local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")

local Config = require(script.Parent:WaitForChild("LeaderboardConfig"))
local CurrencyService = require(
	script.Parent.Parent:WaitForChild("Currency"):WaitForChild("CurrencyService")
)

type LeaderboardEntry = {
	UserId: number,
	Score: number,
	Name: string,
	Thumbnail: string,
}

type LeaderboardRow = {
	Card: GuiObject,
	Photo: any,
	NameLabel: any,
	NumberLabel: any,
	ScoreLabel: any,
}

type BoardView = {
	Template: GuiObject,
	Rows: {LeaderboardRow},
}

type WriteState = {
	Desired: number?,
	InFlight: number?,
	LastWritten: number?,
	Running: boolean,
	ChangeVersion: number,
	FlushRequested: boolean,
	FlushFailed: boolean,
	RetryScheduled: boolean,
	Closed: boolean,
}

local LeaderboardService = {}

local orderedStores: {[string]: any} = {}
local boardViews: {[string]: BoardView} = {}
local writeStates: {[string]: {[number]: WriteState}} = {}
local nameCache: {[number]: string} = {}
local thumbnailCache: {[number]: string} = {}
local profileLoadedConnections: {[Player]: RBXScriptConnection} = {}
local warned: {[string]: boolean} = {}

local started = false
local shuttingDown = false
local refreshing = false
local refreshScheduled = false
local profileSavedConnection: RBXScriptConnection? = nil
local playerAddedConnection: RBXScriptConnection? = nil
local playerRemovingConnection: RBXScriptConnection? = nil

for _, metricName in ipairs(Config.BOARD_ORDER) do
	local boardConfig = Config.BOARDS[metricName]
	orderedStores[metricName] = DataStoreService:GetOrderedDataStore(
		boardConfig.STORE_NAME,
		Config.DATASTORE_SCOPE
	)
	writeStates[metricName] = {}
end

local function disconnect(connection: RBXScriptConnection?)
	if connection then
		connection:Disconnect()
	end
end

local function warnOnce(key: string, message: string)
	if warned[key] then
		return
	end
	warned[key] = true
	warn("[Leaderboards] " .. message)
end

local function normalizeScore(value: any): number?
	if type(value) ~= "number"
		or value ~= value
		or value == math.huge
		or value == -math.huge then
		return nil
	end
	return math.clamp(math.floor(value), 0, Config.MAX_SCORE)
end

local function formatInteger(value: number): string
	local digits = tostring(math.floor(value))
	local groups: {string} = {}
	while #digits > 3 do
		table.insert(groups, 1, string.sub(digits, -3))
		digits = string.sub(digits, 1, -4)
	end
	table.insert(groups, 1, digits)
	return table.concat(groups, " ")
end

local function formatDuration(value: number): string
	local totalSeconds = math.max(0, math.floor(value))
	local hours = math.floor(totalSeconds / 3600)
	local minutes = math.floor(totalSeconds % 3600 / 60)
	local seconds = totalSeconds % 60
	if hours < 100 then
		return string.format("%02d:%02d:%02d", hours, minutes, seconds)
	end
	return string.format("%dh %02dm", hours, minutes)
end

local function formatScore(metricName: string, value: number): string
	local boardConfig = Config.BOARDS[metricName]
	if boardConfig.SCORE_KIND == "Duration" then
		return formatDuration(value)
	end
	return formatInteger(value)
end

local function findTextObject(card: GuiObject, objectName: string): any
	local object = card:FindFirstChild(objectName, true)
	if object
		and (object:IsA("TextLabel") or object:IsA("TextButton") or object:IsA("TextBox")) then
		return object
	end
	return nil
end

local function buildRow(card: GuiObject): LeaderboardRow?
	local photo = card:FindFirstChild(Config.PHOTO_NAME, true)
	local nameLabel = findTextObject(card, Config.PLAYER_NAME)
	local numberLabel = findTextObject(card, Config.NUMBER_NAME)
	local scoreLabel = findTextObject(card, Config.SCORE_NAME)
	if not photo
		or not (photo:IsA("ImageLabel") or photo:IsA("ImageButton"))
		or not nameLabel
		or not numberLabel
		or not scoreLabel then
		return nil
	end
	return {
		Card = card,
		Photo = photo,
		NameLabel = nameLabel,
		NumberLabel = numberLabel,
		ScoreLabel = scoreLabel,
	}
end

local function setPlaceholder(row: LeaderboardRow, rank: number)
	row.NumberLabel.Text = tostring(rank)
	row.NameLabel.Text = "—"
	row.ScoreLabel.Text = "—"
	row.Photo.Image = ""
	row.Card.Visible = true
end

local function mountBoard(metricName: string): BoardView?
	local existingView = boardViews[metricName]
	if existingView
		and existingView.Template.Parent
		and existingView.Template:IsDescendantOf(Workspace) then
		local parent = existingView.Template.Parent
		local rowsAreMounted = #existingView.Rows == Config.MAX_ENTRIES
		for _, row in ipairs(existingView.Rows) do
			if row.Card.Parent ~= parent
				or row.Card:GetAttribute(Config.GENERATED_ATTRIBUTE) ~= true then
				rowsAreMounted = false
				break
			end
		end
		if rowsAreMounted then
			return existingView
		end
	end
	boardViews[metricName] = nil

	local hub = Workspace:FindFirstChild(Config.HUB_NAME)
	if not hub then
		warnOnce("missing-hub", `Workspace.{Config.HUB_NAME} was not found`)
		return nil
	end

	local root = hub:FindFirstChild(Config.ROOT_NAME)
	if not root then
		warnOnce(
			"missing-root",
			`Workspace.{Config.HUB_NAME}.{Config.ROOT_NAME} was not found`
		)
		return nil
	end

	local boardConfig = Config.BOARDS[metricName]
	local board = root:FindFirstChild(boardConfig.MODEL_NAME)
	local scoreBlock = board and board:FindFirstChild(Config.SCORE_BLOCK_NAME)
	local list = scoreBlock and scoreBlock:FindFirstChild(Config.LIST_NAME)
	local template = list and list:FindFirstChild(Config.TEMPLATE_NAME)
	if not board or not scoreBlock or not list or not template then
		warnOnce(
			"missing-path:" .. metricName,
			(`Expected Workspace.{Config.HUB_NAME}.{Config.ROOT_NAME}.{boardConfig.MODEL_NAME}.`
				.. `{Config.SCORE_BLOCK_NAME}.{Config.LIST_NAME}.{Config.TEMPLATE_NAME}`)
		)
		return nil
	end
	if not template:IsA("GuiObject") or not buildRow(template) then
		warnOnce(
			"invalid-template:" .. metricName,
			(`{template:GetFullName()} must be a GuiObject containing Photo, Name, Number, and Score`)
		)
		return nil
	end
	local layout = list:FindFirstChildOfClass("UIListLayout")
	if layout then
		layout.SortOrder = Enum.SortOrder.LayoutOrder
	else
		warnOnce("missing-layout:" .. metricName, `{list:GetFullName()} has no UIListLayout`)
	end

	for _, child in ipairs(list:GetChildren()) do
		if child:GetAttribute(Config.GENERATED_ATTRIBUTE) == true then
			child:Destroy()
		end
	end

	local templateWasVisible = template.Visible
	template.Visible = false
	local rows: {LeaderboardRow} = {}
	for rank = 1, Config.MAX_ENTRIES do
		local cloneOk, clone = pcall(function()
			return template:Clone()
		end)
		if not cloneOk or not clone or not clone:IsA("GuiObject") then
			if clone and typeof(clone) == "Instance" then
				clone:Destroy()
			end
			break
		end
		clone.Name = `{Config.TEMPLATE_NAME}{rank}`
		clone.LayoutOrder = rank
		clone:SetAttribute(Config.GENERATED_ATTRIBUTE, true)
		clone.Parent = list
		local row = buildRow(clone)
		if not row then
			clone:Destroy()
			break
		end
		setPlaceholder(row, rank)
		table.insert(rows, row)
	end

	if #rows ~= Config.MAX_ENTRIES then
		for _, row in ipairs(rows) do
			row.Card:Destroy()
		end
		template.Visible = templateWasVisible
		warnOnce("clone-failed:" .. metricName, `Could not create all rows for {list:GetFullName()}`)
		return nil
	end

	local view = {
		Template = template,
		Rows = rows,
	}
	boardViews[metricName] = view
	return view
end

local function resolveName(userId: number): string
	local cached = nameCache[userId]
	if cached then
		return cached
	end
	local onlinePlayer = Players:GetPlayerByUserId(userId)
	if onlinePlayer then
		nameCache[userId] = onlinePlayer.Name
		return onlinePlayer.Name
	end

	local ok, result = pcall(function()
		return Players:GetNameFromUserIdAsync(userId)
	end)
	if ok and type(result) == "string" and result ~= "" then
		nameCache[userId] = result
		return result
	end
	warnOnce(`name:{userId}`, `Could not resolve the username for user {userId}: {tostring(result)}`)
	return `User {userId}`
end

local function resolveThumbnail(userId: number): string
	local cached = thumbnailCache[userId]
	if cached then
		return cached
	end

	local ok, content, isReady = pcall(function()
		return Players:GetUserThumbnailAsync(
			userId,
			Enum.ThumbnailType.HeadShot,
			Enum.ThumbnailSize.Size150x150
		)
	end)
	if ok and type(content) == "string" and content ~= "" then
		if isReady then
			thumbnailCache[userId] = content
		end
		return content
	end
	warnOnce(
		`thumbnail:{userId}`,
		`Could not resolve the avatar for user {userId}: {tostring(content)}`
	)
	return `rbxthumb://type=AvatarHeadShot&id={userId}&w=150&h=150`
end

local function fetchEntries(metricName: string): {LeaderboardEntry}?
	local store = orderedStores[metricName]
	local ok, pagesOrError = pcall(function()
		return store:GetSortedAsync(false, Config.MAX_ENTRIES)
	end)
	if not ok then
		warnOnce(
			"read:" .. metricName,
			`Could not read {metricName}: {tostring(pagesOrError)}`
		)
		return nil
	end

	local pageOk, pageOrError = pcall(function()
		return pagesOrError:GetCurrentPage()
	end)
	if not pageOk or type(pageOrError) ~= "table" then
		warnOnce(
			"page:" .. metricName,
			`Could not read the current {metricName} page: {tostring(pageOrError)}`
		)
		return nil
	end

	local candidates: {{UserId: number, Score: number}} = {}
	for _, item in ipairs(pageOrError) do
		local userId = tonumber(item.key)
		local score = normalizeScore(item.value)
		if userId and userId > 0 and userId % 1 == 0 and score then
			table.insert(candidates, { UserId = userId, Score = score })
		end
	end

	local entries: {LeaderboardEntry} = {}
	local remaining = #candidates
	for index, candidate in ipairs(candidates) do
		task.spawn(function()
			local resolvedOk, resolvedEntry = xpcall(function()
				return {
					UserId = candidate.UserId,
					Score = candidate.Score,
					Name = resolveName(candidate.UserId),
					Thumbnail = resolveThumbnail(candidate.UserId),
				}
			end, debug.traceback)
			if resolvedOk then
				entries[index] = resolvedEntry
			else
				entries[index] = {
					UserId = candidate.UserId,
					Score = candidate.Score,
					Name = `User {candidate.UserId}`,
					Thumbnail = `rbxthumb://type=AvatarHeadShot&id={candidate.UserId}&w=150&h=150`,
				}
				warn(
					`[Leaderboards] Identity lookup failed for user {candidate.UserId}: `
						.. tostring(resolvedEntry)
				)
			end
			remaining -= 1
		end)
	end
	while remaining > 0 and not shuttingDown do
		task.wait()
	end
	return entries
end

local function renderBoard(metricName: string, entries: {LeaderboardEntry})
	local view = mountBoard(metricName)
	if not view then
		return
	end
	for rank, row in ipairs(view.Rows) do
		local entry = entries[rank]
		if entry then
			row.NumberLabel.Text = tostring(rank)
			row.NameLabel.Text = entry.Name
			row.ScoreLabel.Text = formatScore(metricName, entry.Score)
			row.Photo.Image = entry.Thumbnail
			row.Card.Visible = true
		else
			setPlaceholder(row, rank)
		end
	end
end

local function refreshAllBoards()
	if refreshing or shuttingDown then
		return
	end
	refreshing = true
	local ok, refreshError = xpcall(function()
		for _, metricName in ipairs(Config.BOARD_ORDER) do
			mountBoard(metricName)
			local entries = fetchEntries(metricName)
			if entries then
				renderBoard(metricName, entries)
			end
		end
	end, debug.traceback)
	refreshing = false
	if not ok then
		warn("[Leaderboards] Refresh failed:\n" .. tostring(refreshError))
	end
end

local function scheduleFirstWriteRefresh()
	if refreshScheduled or shuttingDown then
		return
	end
	refreshScheduled = true
	task.delay(Config.FIRST_WRITE_REFRESH_DELAY_SECONDS, function()
		refreshScheduled = false
		if started and not shuttingDown then
			refreshAllBoards()
		end
	end)
end

local function writeStoreValue(metricName: string, userId: number, value: number): boolean
	local lastError: any = "WRITE_FAILED"
	for attempt = 1, Config.WRITE_ATTEMPTS do
		local ok, result = pcall(function()
			local store = orderedStores[metricName]
			if metricName == "Currency" then
				store:SetAsync(tostring(userId), value)
			else
				store:UpdateAsync(tostring(userId), function(currentValue)
					local currentScore = normalizeScore(currentValue)
					if currentScore and currentScore > value then
						return currentScore
					end
					return value
				end)
			end
		end)
		if ok then
			return true
		end
		lastError = result
		if attempt < Config.WRITE_ATTEMPTS then
			task.wait(math.min(
				Config.WRITE_RETRY_BASE_SECONDS * (2 ^ (attempt - 1)),
				Config.WRITE_RETRY_MAX_SECONDS
			))
		end
	end
	warnOnce(
		`write:{metricName}:{userId}`,
		`Could not write {metricName} for user {userId}: {tostring(lastError)}`
	)
	return false
end

local startWriteWorker: any

startWriteWorker = function(metricName: string, userId: number, state: WriteState)
	if state.Running
		or state.Closed
		or (not state.FlushRequested and (not started or shuttingDown)) then
		return
	end
	state.Running = true
	task.spawn(function()
		while not state.Closed
			and (state.FlushRequested or (started and not shuttingDown)) do
			local desired = state.Desired
			if desired == nil then
				break
			end

			if not state.FlushRequested then
				local changeVersion = state.ChangeVersion
				local debounceSeconds = if state.LastWritten == nil
					then Config.INITIAL_WRITE_DELAY_SECONDS
					else Config.WRITE_DEBOUNCE_SECONDS
				task.wait(debounceSeconds)
				if state.Closed
					or (not state.FlushRequested and (not started or shuttingDown)) then
					break
				end
				if not state.FlushRequested and state.ChangeVersion ~= changeVersion then
					continue
				end
				desired = state.Desired
				if desired == nil then
					break
				end
			end

			if state.LastWritten == desired then
				if state.Desired == desired then
					state.Desired = nil
				end
				if state.FlushRequested and state.Desired == nil then
					state.FlushRequested = false
				end
				continue
			end

			state.InFlight = desired
			local written = writeStoreValue(metricName, userId, desired)
			state.InFlight = nil
			if written then
				local firstWrite = state.LastWritten == nil
				state.LastWritten = desired
				if firstWrite then
					scheduleFirstWriteRefresh()
				end
				if state.Desired == desired then
					state.Desired = nil
				end
				if state.FlushRequested and state.Desired == nil then
					state.FlushRequested = false
				end
			else
				if state.FlushRequested then
					state.FlushFailed = true
					state.FlushRequested = false
					state.Desired = nil
					state.Closed = true
					break
				end

				state.Running = false
				if not state.RetryScheduled then
					state.RetryScheduled = true
					task.delay(Config.FAILED_WRITE_RETRY_SECONDS, function()
						if not state.RetryScheduled then
							return
						end
						state.RetryScheduled = false
						if state.Desired ~= nil then
							startWriteWorker(metricName, userId, state)
						end
					end)
				end
				return
			end
		end
		state.Running = false
		if not state.Closed
			and state.Desired ~= nil
			and (state.FlushRequested or (started and not shuttingDown)) then
			startWriteWorker(metricName, userId, state)
		end
	end)
end

local function getWriteState(metricName: string, userId: number): WriteState
	local states = writeStates[metricName]
	local state = states[userId]
	if state then
		return state
	end
	state = {
		Desired = nil,
		InFlight = nil,
		LastWritten = nil,
		Running = false,
		ChangeVersion = 0,
		FlushRequested = false,
		FlushFailed = false,
		RetryScheduled = false,
		Closed = false,
	}
	states[userId] = state
	return state
end

local function reopenWriteStates(userId: number)
	for _, metricName in ipairs(Config.BOARD_ORDER) do
		local state = writeStates[metricName][userId]
		if state then
			state.Closed = false
			state.FlushFailed = false
		end
	end
end

local function queueMetric(metricName: string, userId: number, value: any)
	if not started or shuttingDown or not orderedStores[metricName] then
		return
	end
	local normalized = normalizeScore(value)
	if not normalized then
		return
	end
	local state = getWriteState(metricName, userId)
	if state.Closed then
		return
	end
	state.Desired = normalized
	state.ChangeVersion += 1
	startWriteWorker(metricName, userId, state)
end

local function queueSnapshot(userId: number, snapshot: {[string]: number})
	for _, metricName in ipairs(Config.BOARD_ORDER) do
		queueMetric(metricName, userId, snapshot[metricName])
	end
end

local function syncPlayer(player: Player)
	if not CurrencyService.AwaitLoaded(player, Config.PROFILE_LOAD_WAIT_SECONDS) then
		return
	end
	local snapshot = CurrencyService.GetStatsSnapshot(player)
	if snapshot then
		queueSnapshot(player.UserId, snapshot)
	end
end

local function flushSnapshot(userId: number, snapshot: {[string]: any})
	local states: {WriteState} = {}
	for _, metricName in ipairs(Config.BOARD_ORDER) do
		local normalized = normalizeScore(snapshot[metricName])
		local state = getWriteState(metricName, userId)
		-- Cancel any older delayed retry before this serialized final flush.
		state.RetryScheduled = false
		state.Closed = false
		state.FlushFailed = false
		if normalized then
			state.Desired = normalized
			state.ChangeVersion += 1
			state.FlushRequested = true
			startWriteWorker(metricName, userId, state)
		else
			state.Desired = nil
			state.FlushRequested = false
		end
		table.insert(states, state)
	end

	local pending = true
	while pending do
		pending = false
		for _, state in ipairs(states) do
			if state.Running
				or state.InFlight ~= nil
				or state.Desired ~= nil
				or state.FlushRequested then
				pending = true
				break
			end
		end
		if pending then
			task.wait(0.05)
		end
	end

	local succeeded = not pending
	for _, state in ipairs(states) do
		if state.FlushFailed then
			succeeded = false
		end
		state.Closed = true
		state.FlushRequested = false
		state.Desired = nil
	end
	return succeeded, if succeeded then nil else "ORDERED_WRITE_FAILED"
end

local function onPlayerAdded(player: Player)
	reopenWriteStates(player.UserId)
	disconnect(profileLoadedConnections[player])
	profileLoadedConnections[player] = player:GetAttributeChangedSignal("ProfileLoaded"):Connect(
		function()
			if player:GetAttribute("ProfileLoaded") == true then
				task.spawn(syncPlayer, player)
			end
		end
	)
	task.spawn(syncPlayer, player)
end

local function onPlayerRemoving(player: Player)
	disconnect(profileLoadedConnections[player])
	profileLoadedConnections[player] = nil
end

function LeaderboardService.Start()
	if started then
		return
	end
	started = true
	shuttingDown = false

	CurrencyService.Start()
	local publisherSet, publisherError = CurrencyService.SetProfileSnapshotPublisher(flushSnapshot)
	if not publisherSet then
		error(`Could not register the leaderboard publisher: {tostring(publisherError)}`)
	end
	profileSavedConnection = CurrencyService.ProfileSaved:Connect(function(player, snapshot, released)
		if released ~= true then
			queueSnapshot(player.UserId, snapshot)
		end
	end)
	playerAddedConnection = Players.PlayerAdded:Connect(onPlayerAdded)
	playerRemovingConnection = Players.PlayerRemoving:Connect(onPlayerRemoving)
	for _, player in ipairs(Players:GetPlayers()) do
		onPlayerAdded(player)
	end
	task.spawn(function()
		for attempt = 1, Config.MOUNT_ATTEMPTS do
			if shuttingDown then
				return
			end
			local allMounted = true
			for _, metricName in ipairs(Config.BOARD_ORDER) do
				if not mountBoard(metricName) then
					allMounted = false
				end
			end
			if allMounted then
				if attempt > 1 then
					task.spawn(refreshAllBoards)
				end
				return
			end
			task.wait(Config.MOUNT_RETRY_SECONDS)
		end
	end)

	task.spawn(function()
		task.wait(Config.INITIAL_REFRESH_DELAY_SECONDS)
		while started and not shuttingDown do
			refreshAllBoards()
			task.wait(Config.REFRESH_INTERVAL_SECONDS)
		end
	end)

	print("[Leaderboards] Service started")
end

function LeaderboardService.RefreshNow()
	task.spawn(refreshAllBoards)
end

function LeaderboardService.Shutdown()
	if shuttingDown then
		return
	end
	local finalSnapshots: {[number]: {[string]: number}} = {}
	for _, player in ipairs(Players:GetPlayers()) do
		CurrencyService.CommitPlayTime(player)
		local snapshot = CurrencyService.GetStatsSnapshot(player)
		if snapshot then
			finalSnapshots[player.UserId] = snapshot
		end
	end

	shuttingDown = true
	started = false
	CurrencyService.SetProfileSnapshotPublisher(nil)
	disconnect(profileSavedConnection)
	disconnect(playerAddedConnection)
	disconnect(playerRemovingConnection)
	profileSavedConnection = nil
	playerAddedConnection = nil
	playerRemovingConnection = nil
	for player, connection in pairs(profileLoadedConnections) do
		disconnect(connection)
		profileLoadedConnections[player] = nil
	end

	for userId, snapshot in pairs(finalSnapshots) do
		local flushed, flushError = flushSnapshot(userId, snapshot)
		if not flushed then
			warn(
				`[Leaderboards] Final flush failed for user {userId}: {tostring(flushError)}`
			)
		end
	end
end

return LeaderboardService
