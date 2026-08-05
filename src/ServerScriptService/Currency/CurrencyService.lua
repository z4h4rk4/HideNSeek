--!strict

local Players = game:GetService("Players")

local CurrencyConfig = require(script.Parent:WaitForChild("CurrencyConfig"))
local CurrencyCore = require(script.Parent:WaitForChild("CurrencyCore"))
local CurrencyDataStore = require(script.Parent:WaitForChild("CurrencyDataStore"))

local CurrencyService = {}

local profiles: {[number]: any} = {}
local loading: {[number]: Player} = {}
local changedEvent = Instance.new("BindableEvent")
local started = false
local shuttingDown = false
local playerAddedConnection: RBXScriptConnection? = nil
local playerRemovingConnection: RBXScriptConnection? = nil

CurrencyService.Changed = changedEvent.Event

local scheduleDirtySave: any
local closeProfile: any

local function disconnect(connection: RBXScriptConnection?)
	if connection then
		connection:Disconnect()
	end
end

local function validReason(reason: any): boolean
	return type(reason) == "string" and #reason >= 1 and #reason <= 128
end

local function isPermanentDataError(reason: any): boolean
	return reason == "CORRUPT_DATA"
		or reason == "UNSUPPORTED_VERSION"
		or reason == "INVALID_CURRENCY"
end

local function getUsableProfile(player: Player)
	local profile = profiles[player.UserId]
	if not profile or profile.player ~= player then
		return nil, "NOT_LOADED"
	end
	if profile.closing or profile.closed then
		return nil, "PROFILE_CLOSING"
	end
	if not profile.sessionValid then
		return nil, "SESSION_SUPERSEDED"
	end
	return profile
end

local function setDisplayedCurrency(profile)
	if profile.currencyValue and profile.currencyValue.Parent then
		profile.currencyValue.Value = profile.data.Currency
	end
end

local function invalidateSession(profile, reason: string)
	if not profile.sessionValid then
		return
	end
	profile.sessionValid = false
	profile.player:SetAttribute(CurrencyConfig.ATTR_LOADED, false)
	warn(
		(`[Currency] Session invalidated for {profile.player.Name} ({profile.userId}): {reason}`)
	)
end

local function saveProfile(profile, releaseSession: boolean, allowClosing: boolean)
	while profile.saving and not profile.closed do
		task.wait(0.05)
	end
	if profile.closed then
		return false, "PROFILE_CLOSED"
	end
	if profile.closing and not allowClosing then
		return false, "PROFILE_CLOSING"
	end
	if not profile.sessionValid then
		return false, "SESSION_SUPERSEDED"
	end

	profile.saving = true
	local capturedData = CurrencyCore.CloneData(profile.data)
	local capturedRevision = profile.revision
	local ok, reason, savedAt = CurrencyDataStore.Save(
		profile.userId,
		profile.sessionId,
		profile.sessionStart,
		capturedData,
		releaseSession
	)
	profile.saving = false

	if ok then
		profile.lastSavedRevision = math.max(profile.lastSavedRevision, capturedRevision)
		profile.lastSuccessfulSaveUnix = savedAt or os.time()
		if releaseSession then
			profile.sessionValid = false
		end
		return true
	end

	if reason == "NEWER_SESSION_START"
		or reason == "NEWER_SESSION_SAVE"
		or isPermanentDataError(reason) then
		invalidateSession(profile, tostring(reason))
	end
	return false, reason
end

local function scheduleSaveRetry(profile)
	if profile.retryScheduled or profile.closing or profile.closed or not profile.sessionValid then
		return
	end
	profile.retryScheduled = true
	task.delay(CurrencyConfig.FAILED_SAVE_RETRY_SECONDS, function()
		profile.retryScheduled = false
		if profiles[profile.userId] ~= profile
			or profile.closing
			or profile.closed
			or not profile.sessionValid then
			return
		end

		local ok, reason = saveProfile(profile, false, false)
		if not ok and reason ~= "PROFILE_CLOSING" then
			warn(
				(`[Currency] Retry save failed for {profile.player.Name} ({profile.userId}): {tostring(reason)}`)
			)
			scheduleSaveRetry(profile)
		end
	end)
end

scheduleDirtySave = function(profile)
	if profile.dirtySaveScheduled or profile.closing or profile.closed or not profile.sessionValid then
		return
	end
	profile.dirtySaveScheduled = true
	task.delay(CurrencyConfig.DIRTY_SAVE_DELAY_SECONDS, function()
		profile.dirtySaveScheduled = false
		if profiles[profile.userId] ~= profile
			or profile.closing
			or profile.closed
			or not profile.sessionValid
			or profile.revision <= profile.lastSavedRevision then
			return
		end

		local ok, reason = saveProfile(profile, false, false)
		if not ok and reason ~= "PROFILE_CLOSING" then
			warn(
				(`[Currency] Dirty save failed for {profile.player.Name} ({profile.userId}): {tostring(reason)}`)
			)
			scheduleSaveRetry(profile)
		elseif profile.revision > profile.lastSavedRevision then
			scheduleDirtySave(profile)
		end
	end)
end

local function attachLeaderstats(profile)
	local player = profile.player
	local leaderstats = player:FindFirstChild(CurrencyConfig.LEADERSTATS_NAME)
	if leaderstats and not leaderstats:IsA("Folder") then
		error("leaderstats exists but is not a Folder")
	end
	if not leaderstats then
		leaderstats = Instance.new("Folder")
		leaderstats.Name = CurrencyConfig.LEADERSTATS_NAME
		leaderstats.Parent = player
	end

	local currencyValue = leaderstats:FindFirstChild(CurrencyConfig.CURRENCY_VALUE_NAME)
	if currencyValue and not currencyValue:IsA("IntValue") then
		error(`leaderstats.{CurrencyConfig.CURRENCY_VALUE_NAME} exists but is not an IntValue`)
	end
	if not currencyValue then
		currencyValue = Instance.new("IntValue")
		currencyValue.Name = CurrencyConfig.CURRENCY_VALUE_NAME
		currencyValue.Parent = leaderstats
	end

	profile.currencyValue = currencyValue
	setDisplayedCurrency(profile)
	profile.valueConnection = currencyValue:GetPropertyChangedSignal("Value"):Connect(function()
		if profile.closed then
			return
		end
		if currencyValue.Value ~= profile.data.Currency then
			warn(
				(`[Currency] Rejected direct Coins change for {player.Name} ({player.UserId})`)
			)
			currencyValue.Value = profile.data.Currency
		end
	end)
end

local function claimLoadSlot(player: Player): boolean
	local userId = player.UserId
	while not shuttingDown and player.Parent == Players do
		local activeProfile = profiles[userId]
		if activeProfile then
			if activeProfile.player == player then
				return false
			end
			closeProfile(activeProfile)
		else
			local activeLoader = loading[userId]
			if activeLoader and activeLoader ~= player then
				if activeLoader.Parent ~= Players then
					loading[userId] = nil
				else
					task.wait(0.05)
				end
			else
				loading[userId] = player
				return true
			end
		end
	end
	return false
end

closeProfile = function(profile)
	if profile.closed then
		return profile.closeSucceeded
	end
	if profile.closing then
		while not profile.closed do
			task.wait(0.05)
		end
		return profile.closeSucceeded
	end

	profile.closing = true
	profile.player:SetAttribute(CurrencyConfig.ATTR_LOADED, false)
	disconnect(profile.valueConnection)
	profile.valueConnection = nil

	local ok, reason = saveProfile(profile, true, true)
	profile.closeSucceeded = ok
	profile.closed = true
	if profiles[profile.userId] == profile then
		profiles[profile.userId] = nil
	end

	if not ok then
		warn(
			(`[Currency] Final save failed for {profile.player.Name} ({profile.userId}): {tostring(reason)}`)
		)
	end
	return ok
end

local function loadPlayer(player: Player)
	if shuttingDown or player.Parent ~= Players or not claimLoadSlot(player) then
		return
	end

	player:SetAttribute(CurrencyConfig.ATTR_LOADED, false)
	player:SetAttribute(CurrencyConfig.ATTR_LOAD_ERROR, nil)
	local loaded = nil
	local loadError = nil

	while not loaded
		and not shuttingDown
		and player.Parent == Players
		and loading[player.UserId] == player do
		loaded, loadError = CurrencyDataStore.Load(player.UserId)
		if not loaded then
			player:SetAttribute(CurrencyConfig.ATTR_LOAD_ERROR, tostring(loadError))
			warn(
				(`[Currency] Load deferred for {player.Name} ({player.UserId}): {tostring(loadError)}`)
			)
			local delaySeconds = if isPermanentDataError(loadError)
				then CurrencyConfig.PERMANENT_LOAD_RETRY_SECONDS
				else CurrencyConfig.PROFILE_LOAD_RETRY_SECONDS
			task.wait(delaySeconds)
		end
	end

	if not loaded or shuttingDown or player.Parent ~= Players or profiles[player.UserId] then
		if loading[player.UserId] == player then
			loading[player.UserId] = nil
		end
		return
	end

	local profile = {
		player = player,
		userId = player.UserId,
		data = loaded.Data,
		sessionId = loaded.SessionId,
		sessionStart = loaded.SessionStart,
		sessionValid = true,
		revision = 0,
		lastSavedRevision = 0,
		lastSuccessfulSaveUnix = loaded.LoadedAt,
		lastSeenAt = loaded.LastSeenAt,
		isNewProfile = loaded.IsNewProfile == true,
		saving = false,
		closing = false,
		closed = false,
		closeSucceeded = false,
		dirtySaveScheduled = false,
		retryScheduled = false,
		currencyValue = nil,
		valueConnection = nil,
	}

	-- Do not expose mutable player data until this server owns the session.
	local opened, openError = saveProfile(profile, false, false)
	if not opened then
		player:SetAttribute(CurrencyConfig.ATTR_LOAD_ERROR, tostring(openError))
		warn(
			(`[Currency] Session marker failed for {player.Name} ({player.UserId}): {tostring(openError)}`)
		)
		if loading[player.UserId] == player then
			loading[player.UserId] = nil
		end
		if not shuttingDown and player.Parent == Players then
			task.delay(CurrencyConfig.PROFILE_LOAD_RETRY_SECONDS, loadPlayer, player)
		end
		return
	end

	local attached, attachError = pcall(attachLeaderstats, profile)
	if not attached then
		warn(
			(`[Currency] Leaderstats setup failed for {player.Name} ({player.UserId}): {tostring(attachError)}`)
		)
		closeProfile(profile)
		if loading[player.UserId] == player then
			loading[player.UserId] = nil
		end
		return
	end

	if shuttingDown or player.Parent ~= Players or profiles[player.UserId] then
		closeProfile(profile)
		if loading[player.UserId] == player then
			loading[player.UserId] = nil
		end
		return
	end

	profiles[player.UserId] = profile
	if loading[player.UserId] == player then
		loading[player.UserId] = nil
	end
	player:SetAttribute(CurrencyConfig.ATTR_LOADED, true)
	player:SetAttribute(CurrencyConfig.ATTR_LOAD_ERROR, nil)
	print(
		(`[Currency] Loaded {player.Name} ({player.UserId}) with {profile.data.Currency} Coins`)
	)
end

local function onPlayerAdded(player: Player)
	if shuttingDown then
		player:Kick("The server is shutting down. Please rejoin.")
		return
	end
	task.spawn(loadPlayer, player)
end

local function onPlayerRemoving(player: Player)
	player:SetAttribute(CurrencyConfig.ATTR_LOADED, false)
	local profile = profiles[player.UserId]
	if profile and profile.player == player then
		closeProfile(profile)
	end
end

local function applyDelta(player: Player, delta: number, reason: string)
	if not validReason(reason) then
		return false, nil, "INVALID_REASON"
	end
	local profile, profileError = getUsableProfile(player)
	if not profile then
		return false, nil, profileError
	end

	local nextBalance, amountError = CurrencyCore.ApplyDelta(
		profile.data.Currency,
		delta,
		CurrencyConfig.MAX_BALANCE,
		CurrencyConfig.MAX_TRANSACTION
	)
	if not nextBalance then
		return false, profile.data.Currency, amountError
	end

	profile.data.Currency = nextBalance
	profile.revision += 1
	setDisplayedCurrency(profile)
	changedEvent:Fire(player, nextBalance, delta, reason)
	scheduleDirtySave(profile)
	return true, nextBalance, nil
end

function CurrencyService.Start()
	if started then
		return
	end
	started = true
	shuttingDown = false

	playerAddedConnection = Players.PlayerAdded:Connect(onPlayerAdded)
	playerRemovingConnection = Players.PlayerRemoving:Connect(onPlayerRemoving)
	for _, player in ipairs(Players:GetPlayers()) do
		onPlayerAdded(player)
	end

	task.spawn(function()
		while started and not shuttingDown do
			task.wait(CurrencyConfig.AUTOSAVE_INTERVAL_SECONDS)
			if not started or shuttingDown then
				break
			end
			for _, profile in pairs(profiles) do
				task.spawn(function()
					local ok, reason = saveProfile(profile, false, false)
					if not ok and reason ~= "PROFILE_CLOSING" and reason ~= "PROFILE_CLOSED" then
						warn(
							(`[Currency] Autosave failed for {profile.player.Name} ({profile.userId}): {tostring(reason)}`)
						)
						scheduleSaveRetry(profile)
					end
				end)
			end
		end
	end)

	game:BindToClose(function()
		CurrencyService.Shutdown()
	end)
	print("[Currency] Service started")
end

function CurrencyService.IsLoaded(player: Player): boolean
	local profile = profiles[player.UserId]
	return profile ~= nil
		and profile.player == player
		and profile.sessionValid
		and not profile.closing
		and not profile.closed
end

function CurrencyService.AwaitLoaded(player: Player, timeoutSeconds: number?): boolean
	local deadline = os.clock() + (timeoutSeconds or 15)
	repeat
		if CurrencyService.IsLoaded(player) then
			return true
		end
		if player.Parent ~= Players or shuttingDown then
			return false
		end
		task.wait(0.05)
	until os.clock() >= deadline
	return CurrencyService.IsLoaded(player)
end

function CurrencyService.GetCurrency(player: Player): number?
	local profile = getUsableProfile(player)
	return profile and profile.data.Currency or nil
end

function CurrencyService.CanAfford(player: Player, amount: number): boolean
	local profile = getUsableProfile(player)
	return profile ~= nil
		and type(amount) == "number"
		and amount == amount
		and amount % 1 == 0
		and amount >= 0
		and amount <= CurrencyConfig.MAX_TRANSACTION
		and profile.data.Currency >= amount
end

function CurrencyService.AddCurrency(player: Player, amount: number, reason: string)
	if type(amount) ~= "number" or amount <= 0 then
		return false, nil, "INVALID_AMOUNT"
	end
	return applyDelta(player, amount, reason)
end

function CurrencyService.SpendCurrency(player: Player, amount: number, reason: string)
	if type(amount) ~= "number" or amount <= 0 then
		return false, nil, "INVALID_AMOUNT"
	end
	return applyDelta(player, -amount, reason)
end

function CurrencyService.SaveNow(player: Player)
	local profile, profileError = getUsableProfile(player)
	if not profile then
		return false, profileError
	end
	return saveProfile(profile, false, false)
end

function CurrencyService.Shutdown()
	if shuttingDown then
		return
	end
	shuttingDown = true
	started = false
	disconnect(playerAddedConnection)
	disconnect(playerRemovingConnection)
	playerAddedConnection = nil
	playerRemovingConnection = nil

	for _, profile in pairs(profiles) do
		task.spawn(closeProfile, profile)
	end

	local deadline = os.clock() + CurrencyConfig.SHUTDOWN_DEADLINE_SECONDS
	repeat
		if next(profiles) == nil and next(loading) == nil then
			break
		end
		task.wait(0.05)
	until os.clock() >= deadline

	if next(profiles) ~= nil or next(loading) ~= nil then
		warn("[Currency] Shutdown deadline reached before every profile operation completed")
	else
		print("[Currency] Shutdown save completed")
	end
end

return CurrencyService
