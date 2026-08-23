--!strict

local Players = game:GetService("Players")

local CurrencyConfig = require(script.Parent:WaitForChild("CurrencyConfig"))
local CurrencyCore = require(script.Parent:WaitForChild("CurrencyCore"))
local CurrencyDataStore = require(script.Parent:WaitForChild("CurrencyDataStore"))

local CurrencyService = {}

local profiles: {[number]: any} = {}
local loading: {[number]: Player} = {}
local changedEvent = Instance.new("BindableEvent")
local ownershipChangedEvent = Instance.new("BindableEvent")
local statsChangedEvent = Instance.new("BindableEvent")
local profileSavedEvent = Instance.new("BindableEvent")
local started = false
local shuttingDown = false
local profileSnapshotPublisher: any = nil
local playerAddedConnection: RBXScriptConnection? = nil
local playerRemovingConnection: RBXScriptConnection? = nil

CurrencyService.Changed = changedEvent.Event
CurrencyService.OwnershipChanged = ownershipChangedEvent.Event
CurrencyService.StatsChanged = statsChangedEvent.Event
CurrencyService.ProfileSaved = profileSavedEvent.Event

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

local function validPurchaseId(purchaseId: any): boolean
	return type(purchaseId) == "string" and #purchaseId >= 1 and #purchaseId <= 128
end

local function validWeaponName(weaponName: any): boolean
	return type(weaponName) == "string"
		and #weaponName >= 1
		and #weaponName <= 64
		and string.match(weaponName, "^[%w_%-]+$") ~= nil
end

local function validSkinId(skinId: any): boolean
	return type(skinId) == "string"
		and #skinId >= 1
		and #skinId <= 64
		and string.match(skinId, "^[%w_%-]+$") ~= nil
end

local function validCaseId(caseId: any): boolean
	return type(caseId) == "string"
		and #caseId >= 1
		and #caseId <= 64
		and string.match(caseId, "^[%w_%-]+$") ~= nil
end

local function isPermanentDataError(reason: any): boolean
	return reason == "CORRUPT_DATA"
		or reason == "UNSUPPORTED_VERSION"
		or reason == "INVALID_CURRENCY"
		or reason == "INVALID_WINS"
		or reason == "INVALID_PLAY_TIME"
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

local function getSkinCaseRollCounts(profile): {[string]: number}
	local rollCounts = profile.data.SkinCaseRollCounts
	if type(rollCounts) ~= "table" then
		rollCounts = {}
		profile.data.SkinCaseRollCounts = rollCounts
	end
	return rollCounts
end

local function addSkinCaseRollCount(profile, caseId: string?, rollCount: number)
	if not validCaseId(caseId) or rollCount <= 0 then
		return
	end
	local normalizedCaseId = caseId :: string
	local rollCounts = getSkinCaseRollCounts(profile)
	local current = rollCounts[normalizedCaseId]
	rollCounts[normalizedCaseId] = (if type(current) == "number" and current >= 0 then current else 0)
		+ rollCount
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
		profileSavedEvent:Fire(profile.player, capturedData, releaseSession)
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

local function accruePlayTime(profile, shouldScheduleSave: boolean): number
	if profile.closing or profile.closed or not profile.sessionValid then
		return 0
	end
	local now = os.clock()
	local checkpoint = profile.playTimeCheckpoint
	if type(checkpoint) ~= "number" then
		profile.playTimeCheckpoint = now
		return 0
	end

	local wholeSeconds = math.floor(now - checkpoint)
	if wholeSeconds <= 0 then
		return 0
	end
	profile.playTimeCheckpoint = checkpoint + wholeSeconds

	local available = CurrencyConfig.MAX_STAT_VALUE - profile.data.PlayTimeSeconds
	local addedSeconds = math.min(wholeSeconds, available)
	if addedSeconds <= 0 then
		return 0
	end

	profile.data.PlayTimeSeconds += addedSeconds
	profile.revision += 1
	statsChangedEvent:Fire(
		profile.player,
		"PlayTimeSeconds",
		profile.data.PlayTimeSeconds,
		addedSeconds,
		"ConnectedPlayTime"
	)
	if shouldScheduleSave then
		scheduleDirtySave(profile)
	end
	return addedSeconds
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

	accruePlayTime(profile, false)
	profile.closing = true
	profile.player:SetAttribute(CurrencyConfig.ATTR_LOADED, false)
	disconnect(profile.valueConnection)
	profile.valueConnection = nil

	-- Persist the final values while this server still owns the session, then
	-- publish the same snapshot to the ordered leaderboards. Only after both
	-- steps do we release the profile for another server.
	local staged = true
	local stagedReason: any = nil
	if profileSnapshotPublisher then
		staged, stagedReason = saveProfile(profile, false, true)
	end
	if staged and profileSnapshotPublisher then
		local snapshot = CurrencyCore.CloneData(profile.data)
		local publishCallOk, published, publishReason = pcall(
			profileSnapshotPublisher,
			profile.userId,
			snapshot
		)
		if not publishCallOk or published == false then
			warn(
				(`[Currency] Final leaderboard publish failed for {profile.player.Name} `
					.. `({profile.userId}): {tostring(if publishCallOk then publishReason else published)}`)
			)
		end
	end

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
	elseif not staged then
		warn(
			(`[Currency] Pre-release save failed for {profile.player.Name} `
				.. `({profile.userId}): {tostring(stagedReason)}`)
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
		playTimeCheckpoint = nil,
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

	profile.playTimeCheckpoint = os.clock()
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

local function getDeveloperProductReceipts(profile): {[string]: number}
	local receipts = profile.data.DeveloperProductReceipts
	if type(receipts) ~= "table" then
		receipts = {}
		profile.data.DeveloperProductReceipts = receipts
	end
	return receipts
end

local function getOwnedSkins(profile): {[string]: boolean}
	local ownedSkins = profile.data.OwnedSkins
	if type(ownedSkins) ~= "table" then
		ownedSkins = {}
		profile.data.OwnedSkins = ownedSkins
	end
	return ownedSkins
end

local function copyOwnedSkins(raw: {[string]: boolean}): {[string]: boolean}
	local copy: {[string]: boolean} = {}
	for skinId, owned in pairs(raw) do
		if owned == true then
			copy[skinId] = true
		end
	end
	return copy
end

local function pruneDeveloperProductReceipts(receipts: {[string]: number})
	local count = 0
	for _ in pairs(receipts) do
		count += 1
	end

	local maxReceipts = CurrencyConfig.MAX_DEVELOPER_PRODUCT_RECEIPTS
	while count > maxReceipts do
		local oldestId: string? = nil
		local oldestTime: number? = nil
		for purchaseId, processedAt in pairs(receipts) do
			if oldestTime == nil or processedAt < oldestTime then
				oldestId = purchaseId
				oldestTime = processedAt
			end
		end
		if not oldestId then
			return
		end
		receipts[oldestId] = nil
		count -= 1
	end
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
					accruePlayTime(profile, false)
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

function CurrencyService.SetProfileSnapshotPublisher(publisher: any)
	if publisher ~= nil and type(publisher) ~= "function" then
		return false, "INVALID_PUBLISHER"
	end
	profileSnapshotPublisher = publisher
	return true, nil
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

function CurrencyService.GetWins(player: Player): number?
	local profile = getUsableProfile(player)
	return profile and profile.data.Wins or nil
end

function CurrencyService.GetPlayTimeSeconds(player: Player): number?
	local profile = getUsableProfile(player)
	if not profile then
		return nil
	end
	local checkpoint = profile.playTimeCheckpoint
	local liveSeconds = if type(checkpoint) == "number"
		then math.max(0, math.floor(os.clock() - checkpoint))
		else 0
	return math.min(
		CurrencyConfig.MAX_STAT_VALUE,
		profile.data.PlayTimeSeconds + liveSeconds
	)
end

function CurrencyService.GetStatsSnapshot(player: Player): {[string]: number}?
	local profile = getUsableProfile(player)
	if not profile then
		return nil
	end
	local playTimeSeconds = CurrencyService.GetPlayTimeSeconds(player)
	return {
		Currency = profile.data.Currency,
		Wins = profile.data.Wins,
		PlayTimeSeconds = playTimeSeconds or profile.data.PlayTimeSeconds,
	}
end

function CurrencyService.RecordWin(player: Player, reason: string)
	if not validReason(reason) then
		return false, nil, "INVALID_REASON"
	end
	local profile, profileError = getUsableProfile(player)
	if not profile then
		return false, nil, profileError
	end
	if profile.data.Wins >= CurrencyConfig.MAX_STAT_VALUE then
		return false, profile.data.Wins, "STAT_LIMIT"
	end

	profile.data.Wins += 1
	profile.revision += 1
	statsChangedEvent:Fire(player, "Wins", profile.data.Wins, 1, reason)
	scheduleDirtySave(profile)
	return true, profile.data.Wins, nil
end

function CurrencyService.CommitPlayTime(player: Player): number?
	local profile = getUsableProfile(player)
	if not profile then
		return nil
	end
	accruePlayTime(profile, true)
	return profile.data.PlayTimeSeconds
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

function CurrencyService.HasWeapon(player: Player, weaponName: string): boolean
	if not validWeaponName(weaponName) then
		return false
	end
	local profile = getUsableProfile(player)
	return profile ~= nil and profile.data.OwnedWeapons[weaponName] == true
end

function CurrencyService.GetOwnedWeapons(player: Player): {[string]: boolean}?
	local profile = getUsableProfile(player)
	if not profile then
		return nil
	end
	local copy: {[string]: boolean} = {}
	for weaponName, owned in pairs(profile.data.OwnedWeapons) do
		if owned == true then
			copy[weaponName] = true
		end
	end
	return copy
end

function CurrencyService.GetOwnedSkins(player: Player): {[string]: boolean}?
	local profile = getUsableProfile(player)
	if not profile then
		return nil
	end
	return copyOwnedSkins(getOwnedSkins(profile))
end

function CurrencyService.GetEquippedSkin(player: Player): string?
	local profile = getUsableProfile(player)
	if not profile then
		return nil
	end
	local equippedSkin = profile.data.EquippedSkin
	return if type(equippedSkin) == "string" then equippedSkin else nil
end

function CurrencyService.GetSkinCaseRollCount(player: Player, caseId: string): number
	if not validCaseId(caseId) then
		return 0
	end
	local profile = getUsableProfile(player)
	if not profile then
		return 0
	end
	local rollCount = getSkinCaseRollCounts(profile)[caseId]
	return if type(rollCount) == "number" and rollCount >= 0 then rollCount else 0
end

function CurrencyService.EquipSkin(player: Player, skinId: string, reason: string)
	if not validSkinId(skinId) or not validReason(reason) then
		return false, "INVALID_EQUIP"
	end
	local profile, profileError = getUsableProfile(player)
	if not profile then
		return false, profileError
	end
	local ownedSkins = getOwnedSkins(profile)
	if ownedSkins[skinId] ~= true then
		return false, "NOT_OWNED"
	end
	if profile.data.EquippedSkin == skinId then
		return true, nil
	end

	profile.data.EquippedSkin = skinId
	profile.revision += 1
	scheduleDirtySave(profile)
	return true, nil
end

function CurrencyService.PurchaseSkinCaseRolls(
	player: Player,
	price: number,
	skinIds: {string},
	duplicateRewards: {[string]: number},
	reason: string,
	caseId: string?
)
	if type(price) ~= "number"
		or price ~= price
		or price % 1 ~= 0
		or price <= 0
		or price > CurrencyConfig.MAX_TRANSACTION
		or not validReason(reason) then
		return false, nil, "INVALID_PURCHASE"
	end
	if #skinIds < 1 then
		return false, nil, "INVALID_ROLLS"
	end
	for _, skinId in ipairs(skinIds) do
		if not validSkinId(skinId) then
			return false, nil, "INVALID_SKIN"
		end
	end

	local profile, profileError = getUsableProfile(player)
	if not profile then
		return false, nil, profileError
	end

	local nextBalance, amountError = CurrencyCore.ApplyDelta(
		profile.data.Currency,
		-price,
		CurrencyConfig.MAX_BALANCE,
		CurrencyConfig.MAX_TRANSACTION
	)
	if not nextBalance then
		return false, profile.data.Currency, amountError
	end

	local ownedSkins = getOwnedSkins(profile)
	local results = {}
	local duplicateCoins = 0
	for _, skinId in ipairs(skinIds) do
		local duplicate = ownedSkins[skinId] == true
		if duplicate then
			local reward = duplicateRewards[skinId] or 0
			if reward > 0 then
				duplicateCoins += reward
			end
		else
			ownedSkins[skinId] = true
		end
		table.insert(results, {
			SkinId = skinId,
			Duplicate = duplicate,
			DuplicateCoins = if duplicate then duplicateRewards[skinId] or 0 else 0,
		})
	end

	if duplicateCoins > 0 then
		local rewardedBalance, rewardError = CurrencyCore.ApplyDelta(
			nextBalance,
			duplicateCoins,
			CurrencyConfig.MAX_BALANCE,
			CurrencyConfig.MAX_TRANSACTION
		)
		if not rewardedBalance then
			return false, profile.data.Currency, rewardError
		end
		nextBalance = rewardedBalance
	end

	profile.data.Currency = nextBalance
	addSkinCaseRollCount(profile, caseId, #skinIds)
	profile.revision += 1
	setDisplayedCurrency(profile)
	changedEvent:Fire(player, nextBalance, -price + duplicateCoins, reason)
	scheduleDirtySave(profile)

	local saved, saveError = saveProfile(profile, false, false)
	if not saved then
		warn(`[Currency] Skin case save deferred for {player.Name}: {tostring(saveError)}`)
	end
	return true, {
		Balance = nextBalance,
		Results = results,
		OwnedSkins = copyOwnedSkins(ownedSkins),
		EquippedSkin = CurrencyService.GetEquippedSkin(player),
		DuplicateCoins = duplicateCoins,
	}, nil
end

function CurrencyService.PurchaseWeapon(
	player: Player,
	weaponName: string,
	price: number,
	reason: string
)
	if not validWeaponName(weaponName) or not validReason(reason) then
		return false, nil, "INVALID_PURCHASE"
	end
	if type(price) ~= "number"
		or price ~= price
		or price % 1 ~= 0
		or price <= 0
		or price > CurrencyConfig.MAX_TRANSACTION then
		return false, nil, "INVALID_PRICE"
	end

	local profile, profileError = getUsableProfile(player)
	if not profile then
		return false, nil, profileError
	end
	if profile.data.OwnedWeapons[weaponName] == true then
		return true, profile.data.Currency, "ALREADY_OWNED"
	end

	local nextBalance, amountError = CurrencyCore.ApplyDelta(
		profile.data.Currency,
		-price,
		CurrencyConfig.MAX_BALANCE,
		CurrencyConfig.MAX_TRANSACTION
	)
	if not nextBalance then
		return false, profile.data.Currency, amountError
	end

	profile.data.Currency = nextBalance
	profile.data.OwnedWeapons[weaponName] = true
	profile.revision += 1
	setDisplayedCurrency(profile)
	changedEvent:Fire(player, nextBalance, -price, reason)
	ownershipChangedEvent:Fire(player, weaponName, true, reason)
	scheduleDirtySave(profile)
	return true, nextBalance, nil
end

function CurrencyService.GrantWeapon(player: Player, weaponName: string, reason: string)
	if not validWeaponName(weaponName) or not validReason(reason) then
		return false, "INVALID_GRANT"
	end
	local profile, profileError = getUsableProfile(player)
	if not profile then
		return false, profileError
	end
	if profile.data.OwnedWeapons[weaponName] == true then
		return true, "ALREADY_OWNED"
	end

	profile.data.OwnedWeapons[weaponName] = true
	profile.revision += 1
	ownershipChangedEvent:Fire(player, weaponName, true, reason)
	scheduleDirtySave(profile)
	return true, nil
end

function CurrencyService.ResetOwnedWeapons(player: Player, reason: string)
	if not validReason(reason) then
		return false, 0, "INVALID_REASON"
	end
	local profile, profileError = getUsableProfile(player)
	if not profile then
		return false, 0, profileError
	end

	local removedWeapons: {string} = {}
	for weaponName, owned in pairs(profile.data.OwnedWeapons) do
		if owned == true then
			table.insert(removedWeapons, weaponName)
		end
	end
	if #removedWeapons == 0 then
		return true, 0, nil
	end

	table.clear(profile.data.OwnedWeapons)
	profile.revision += 1
	table.sort(removedWeapons)
	for _, weaponName in ipairs(removedWeapons) do
		ownershipChangedEvent:Fire(player, weaponName, false, reason)
	end
	scheduleDirtySave(profile)
	return true, #removedWeapons, nil
end

function CurrencyService.AddCurrency(player: Player, amount: number, reason: string)
	if type(amount) ~= "number" or amount <= 0 then
		return false, nil, "INVALID_AMOUNT"
	end
	return applyDelta(player, amount, reason)
end

function CurrencyService.GrantDeveloperProduct(
	player: Player,
	purchaseId: string,
	amount: number,
	reason: string
)
	if not validPurchaseId(purchaseId) then
		return false, nil, "INVALID_PURCHASE_ID"
	end
	if type(amount) ~= "number" or amount <= 0 then
		return false, nil, "INVALID_AMOUNT"
	end
	if not validReason(reason) then
		return false, nil, "INVALID_REASON"
	end

	local profile, profileError = getUsableProfile(player)
	if not profile then
		return false, nil, profileError
	end

	local receipts = getDeveloperProductReceipts(profile)
	if receipts[purchaseId] ~= nil then
		local saved, saveError = saveProfile(profile, false, false)
		if not saved then
			return false, profile.data.Currency, saveError
		end
		return true, profile.data.Currency, "ALREADY_GRANTED"
	end

	local nextBalance, amountError = CurrencyCore.ApplyDelta(
		profile.data.Currency,
		amount,
		CurrencyConfig.MAX_BALANCE,
		CurrencyConfig.MAX_TRANSACTION
	)
	if not nextBalance then
		return false, profile.data.Currency, amountError
	end

	profile.data.Currency = nextBalance
	receipts[purchaseId] = os.time()
	pruneDeveloperProductReceipts(receipts)
	profile.revision += 1
	setDisplayedCurrency(profile)
	changedEvent:Fire(player, nextBalance, amount, reason)

	local saved, saveError = saveProfile(profile, false, false)
	if not saved then
		return false, profile.data.Currency, saveError
	end
	return true, nextBalance, nil
end

function CurrencyService.GrantDeveloperProductSkinCaseRoll(
	player: Player,
	purchaseId: string,
	skinId: string,
	duplicateReward: number,
	reason: string,
	caseId: string?
)
	if not validPurchaseId(purchaseId) then
		return false, nil, "INVALID_PURCHASE_ID"
	end
	if not validSkinId(skinId) or not validReason(reason) then
		return false, nil, "INVALID_SKIN"
	end
	if type(duplicateReward) ~= "number"
		or duplicateReward ~= duplicateReward
		or duplicateReward % 1 ~= 0
		or duplicateReward < 0
		or duplicateReward > CurrencyConfig.MAX_TRANSACTION then
		return false, nil, "INVALID_DUPLICATE_REWARD"
	end

	local profile, profileError = getUsableProfile(player)
	if not profile then
		return false, nil, profileError
	end

	local receipts = getDeveloperProductReceipts(profile)
	if receipts[purchaseId] ~= nil then
		local saved, saveError = saveProfile(profile, false, false)
		if not saved then
			return false, nil, saveError
		end
		return true, {
			Balance = profile.data.Currency,
			AlreadyGranted = true,
			OwnedSkins = copyOwnedSkins(getOwnedSkins(profile)),
			EquippedSkin = CurrencyService.GetEquippedSkin(player),
		}, "ALREADY_GRANTED"
	end

	local ownedSkins = getOwnedSkins(profile)
	local duplicate = ownedSkins[skinId] == true
	local nextBalance = profile.data.Currency
	if duplicate and duplicateReward > 0 then
		local rewardedBalance, rewardError = CurrencyCore.ApplyDelta(
			nextBalance,
			duplicateReward,
			CurrencyConfig.MAX_BALANCE,
			CurrencyConfig.MAX_TRANSACTION
		)
		if not rewardedBalance then
			return false, nil, rewardError
		end
		nextBalance = rewardedBalance
	else
		ownedSkins[skinId] = true
	end

	profile.data.Currency = nextBalance
	addSkinCaseRollCount(profile, caseId, 1)
	receipts[purchaseId] = os.time()
	pruneDeveloperProductReceipts(receipts)
	profile.revision += 1
	if duplicate and duplicateReward > 0 then
		setDisplayedCurrency(profile)
		changedEvent:Fire(player, nextBalance, duplicateReward, reason)
	end
	scheduleDirtySave(profile)

	local saved, saveError = saveProfile(profile, false, false)
	if not saved then
		return false, nil, saveError
	end
	return true, {
		Balance = nextBalance,
		Result = {
			SkinId = skinId,
			Duplicate = duplicate,
			DuplicateCoins = if duplicate then duplicateReward else 0,
		},
		OwnedSkins = copyOwnedSkins(ownedSkins),
		EquippedSkin = CurrencyService.GetEquippedSkin(player),
		DuplicateCoins = if duplicate then duplicateReward else 0,
	}, nil
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
	accruePlayTime(profile, false)
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
