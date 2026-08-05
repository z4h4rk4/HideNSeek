--!strict

local DataStoreService = game:GetService("DataStoreService")
local HttpService = game:GetService("HttpService")

local CurrencyConfig = require(script.Parent:WaitForChild("CurrencyConfig"))
local CurrencyCore = require(script.Parent:WaitForChild("CurrencyCore"))

local CurrencyDataStore = {}

local store = DataStoreService:GetDataStore(
	CurrencyConfig.DATASTORE_NAME,
	CurrencyConfig.DATASTORE_SCOPE
)
local serverSessionId = (`{game.JobId}:{HttpService:GenerateGUID(false)}`)

local function keyFor(userId: number): string
	return CurrencyConfig.KEY_PREFIX .. tostring(userId)
end

local function retryDelay(attempt: number): number
	return math.min(
		CurrencyConfig.SAVE_RETRY_BASE_SECONDS * (2 ^ (attempt - 1)),
		CurrencyConfig.SAVE_RETRY_MAX_SECONDS
	)
end

local function normalizeStored(raw: any)
	return CurrencyCore.NormalizeStored(
		raw,
		CurrencyConfig.DATA_VERSION,
		CurrencyConfig.STARTING_CURRENCY,
		CurrencyConfig.MAX_BALANCE
	)
end

function CurrencyDataStore.Load(userId: number)
	local key = keyFor(userId)
	local lastError = "LOAD_FAILED"

	for attempt = 1, CurrencyConfig.LOAD_ATTEMPTS do
		local ok, result = pcall(function()
			return store:GetAsync(key)
		end)

		if ok then
			local isNewProfile = result == nil
			local stored, normalizeError = normalizeStored(result)
			if not stored then
				return nil, normalizeError
			end

			if not stored.Closed then
				local handoffDeadline = os.clock() + CurrencyConfig.RECONNECT_HANDOFF_WAIT_SECONDS
				repeat
					task.wait(CurrencyConfig.RECONNECT_HANDOFF_POLL_SECONDS)
					local refreshOk, refreshedRaw = pcall(function()
						return store:GetAsync(key)
					end)
					if refreshOk then
						local refreshed, refreshError = normalizeStored(refreshedRaw)
						if not refreshed then
							return nil, refreshError
						end
						stored = refreshed
					else
						lastError = tostring(refreshedRaw)
					end
				until stored.Closed or os.clock() >= handoffDeadline
			end

			return {
				Data = CurrencyCore.CloneData(stored.Data),
				SessionId = (`{serverSessionId}:{userId}:{HttpService:GenerateGUID(false)}`),
				SessionStart = DateTime.now().UnixTimestampMillis,
				LoadedAt = os.time(),
				LastSeenAt = stored.UpdatedAt,
				IsNewProfile = isNewProfile,
			}
		end

		lastError = tostring(result)
		if attempt < CurrencyConfig.LOAD_ATTEMPTS then
			task.wait(CurrencyConfig.LOAD_RETRY_DELAY_SECONDS)
		end
	end

	return nil, lastError
end

function CurrencyDataStore.Save(
	userId: number,
	sessionId: string,
	sessionStart: number,
	profileData: {[string]: any},
	releaseSession: boolean
)
	local key = keyFor(userId)
	local lastError = "SAVE_FAILED"

	for attempt = 1, CurrencyConfig.SAVE_ATTEMPTS do
		local deniedReason: string? = nil
		local now = os.time()
		local saveTime = DateTime.now().UnixTimestampMillis
		local ok, result = pcall(function()
			return store:UpdateAsync(key, function(raw)
				deniedReason = nil
				local stored, normalizeError = normalizeStored(raw)
				if not stored then
					deniedReason = normalizeError
					return nil
				end

				local canWrite, writeReason = CurrencyCore.CanWriteSave(
					raw,
					sessionId,
					sessionStart,
					saveTime
				)
				if not canWrite then
					deniedReason = writeReason
					return raw
				end

				stored.Data = CurrencyCore.CloneData(profileData)
				stored.SessionId = sessionId
				stored.SessionStart = sessionStart
				stored.SaveTime = saveTime
				stored.Closed = releaseSession
				stored.UpdatedAt = now
				return stored
			end)
		end)

		if ok and deniedReason == nil and type(result) == "table" then
			return true, nil, now
		end
		if ok and deniedReason == "OLDER_SAME_SESSION_SAVE" then
			return true, nil, now
		end
		if deniedReason then
			lastError = deniedReason
			if deniedReason == "NEWER_SESSION_START"
				or deniedReason == "NEWER_SESSION_SAVE"
				or deniedReason == "CORRUPT_DATA"
				or deniedReason == "UNSUPPORTED_VERSION"
				or deniedReason == "INVALID_CURRENCY" then
				break
			end
		else
			lastError = tostring(result)
		end

		if attempt < CurrencyConfig.SAVE_ATTEMPTS then
			task.wait(retryDelay(attempt))
		end
	end

	return false, lastError, nil
end

return CurrencyDataStore
