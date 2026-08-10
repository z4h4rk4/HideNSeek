--!strict

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local HiderMapGeometry = require(script.Parent:WaitForChild("HiderMapGeometry"))
local RoundConfig = require(script.Parent:WaitForChild("RoundConfig"))
local LeakConfig = require(ReplicatedStorage:WaitForChild("LeakConfig"))

local NPC_FOLDER_NAME = "RoundNPCs"
local MANAGED_NPC_ATTRIBUTE = "ManagedRoundNPC"
local ROLE_ATTRIBUTE = "RoundRole"
local ROLE_HIDER = RoundConfig.ROLE_HIDER
local PHASE_STARTING = RoundConfig.PHASE_STARTING
local PHASE_ROUND = RoundConfig.PHASE_ROUND

local KIND_SMOKE = "Smoke"
local KIND_FART = "Fart"
local KIND_LEAK = "Leak"

local LEAK_NAMES: {[string]: boolean} = table.freeze({
	leak = true,
	leaks = true,
})
type SignalSettings = {
	duration: number,
	priority: number,
}

local SIGNAL_SETTINGS: {[string]: SignalSettings} = {
	[KIND_SMOKE] = {
		duration = 1.75,
		priority = 1,
	},
	[KIND_FART] = {
		duration = 4,
		priority = 2,
	},
	[KIND_LEAK] = {
		duration = LeakConfig.TRAIL_DURATION_SECONDS,
		priority = 3,
	},
}

type EvidenceRecord = {
	owner: Model,
	kind: string,
	position: Vector3,
	createdAt: number,
	expiresAt: number,
	serial: number,
}

type LeakTracker = {
	humanoid: Humanoid,
	rootPart: BasePart,
	parameters: RaycastParams,
	wetUntil: number,
	wasOnLeak: boolean,
	lastEvidencePosition: Vector3?,
	slowActive: boolean,
}

export type Target = {
	owner: Model,
	kind: string,
	position: Vector3,
	createdAt: number,
	expiresAt: number,
	serial: number,
	distance: number,
}

local HiderEvidenceService = {
	KIND_SMOKE = KIND_SMOKE,
	KIND_FART = KIND_FART,
	KIND_LEAK = KIND_LEAK,
}

local evidenceByOwner: {[Model]: {[string]: EvidenceRecord}} = {}
local leakTrackers: {[Model]: LeakTracker} = {}
local currentPhase = "Waiting"
local nextSerial = 0
local trackerRunning = false

local function planarDistance(left: Vector3, right: Vector3): number
	return Vector2.new(left.X - right.X, left.Z - right.Z).Magnitude
end

local function isHiderCharacter(character: Model): boolean
	local player = Players:GetPlayerFromCharacter(character)
	if player then
		return player:GetAttribute(ROLE_ATTRIBUTE) == ROLE_HIDER
	end

	local npcFolder = Workspace:FindFirstChild(NPC_FOLDER_NAME)
	return npcFolder ~= nil
		and character.Parent == npcFolder
		and character:GetAttribute(MANAGED_NPC_ATTRIBUTE) == true
		and character:GetAttribute(ROLE_ATTRIBUTE) == ROLE_HIDER
end

local function getLivingParts(character: Model): (Humanoid?, BasePart?)
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	local rootPart = character:FindFirstChild("HumanoidRootPart")
	if not character.Parent
		or not humanoid
		or humanoid.Health <= 0
		or not rootPart
		or not rootPart:IsA("BasePart") then
		return nil, nil
	end
	return humanoid, rootPart
end

local function getHiderCharacters(): {[Model]: boolean}
	local characters: {[Model]: boolean} = {}
	for _, player in ipairs(Players:GetPlayers()) do
		local character = player.Character
		if character and isHiderCharacter(character) then
			characters[character] = true
		end
	end

	local npcFolder = Workspace:FindFirstChild(NPC_FOLDER_NAME)
	if npcFolder then
		for _, child in ipairs(npcFolder:GetChildren()) do
			if child:IsA("Model") and isHiderCharacter(child) then
				characters[child] = true
			end
		end
	end
	return characters
end

local function restoreLeakSpeed(character: Model, tracker: LeakTracker)
	tracker.slowActive = false
	character:SetAttribute(LeakConfig.SLOW_MULTIPLIER_ATTRIBUTE, nil)
	if tracker.humanoid.Parent then
		local player = Players:GetPlayerFromCharacter(character)
		local role = if player
			then player:GetAttribute(ROLE_ATTRIBUTE)
			else character:GetAttribute(ROLE_ATTRIBUTE)
		tracker.humanoid.WalkSpeed = if role == RoundConfig.ROLE_SEEKER
			then RoundConfig.SEEKER_WALK_SPEED
			else RoundConfig.WALK_SPEED
	end
end

local function updateLeakSpeed(
	character: Model,
	tracker: LeakTracker,
	isOnLeak: boolean,
	now: number
)
	local remainingWetSeconds = math.max(0, tracker.wetUntil - now)
	if not isOnLeak and remainingWetSeconds <= 0 then
		if tracker.slowActive then
			restoreLeakSpeed(character, tracker)
		end
		return
	end

	local recoveryAlpha = if isOnLeak
		then 0
		else LeakConfig.GetRecoveryAlpha(remainingWetSeconds)
	local multiplier = if isOnLeak
		then LeakConfig.ON_LEAK_SPEED_MULTIPLIER
		else LeakConfig.AFTER_EXIT_SPEED_MULTIPLIER
			+ (1 - LeakConfig.AFTER_EXIT_SPEED_MULTIPLIER) * recoveryAlpha
	local targetWalkSpeed = RoundConfig.WALK_SPEED * multiplier
	tracker.slowActive = true
	character:SetAttribute(LeakConfig.SLOW_MULTIPLIER_ATTRIBUTE, multiplier)
	if math.abs(tracker.humanoid.WalkSpeed - targetWalkSpeed) >= 0.01 then
		tracker.humanoid.WalkSpeed = targetWalkSpeed
	end
end

local function isLeakPart(part: BasePart): boolean
	local current: Instance? = part
	while current and current ~= Workspace do
		if LEAK_NAMES[string.lower(current.Name)] or current:GetAttribute("IsLeak") == true then
			return true
		end
		current = current.Parent
	end
	return false
end

function HiderEvidenceService.Emit(
	character: Model,
	kind: string,
	position: Vector3,
	durationSeconds: number?
)
	local settings = SIGNAL_SETTINGS[kind]
	if currentPhase ~= PHASE_ROUND
		or not settings
		or not isHiderCharacter(character) then
		return
	end
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if not humanoid or humanoid.Health <= 0 then
		return
	end

	local now = Workspace:GetServerTimeNow()
	nextSerial += 1
	local records = evidenceByOwner[character]
	if not records then
		records = {}
		evidenceByOwner[character] = records
	end
	-- Smoke and Fart refresh one signal. Every Leak footprint stays independent,
	-- allowing a nearby Seeker to discover any still-visible part of the trail.
	local recordKey = if kind == KIND_LEAK then `{kind}:{nextSerial}` else kind
	records[recordKey] = {
		owner = character,
		kind = kind,
		position = position,
		createdAt = now,
		expiresAt = now + math.max(0, durationSeconds or settings.duration),
		serial = nextSerial,
	}
end

function HiderEvidenceService.Clear(character: Model)
	evidenceByOwner[character] = nil
	local tracker = leakTrackers[character]
	if tracker then
		restoreLeakSpeed(character, tracker)
	end
	leakTrackers[character] = nil
end

function HiderEvidenceService.ClearAll()
	table.clear(evidenceByOwner)
	for character, tracker in pairs(leakTrackers) do
		restoreLeakSpeed(character, tracker)
	end
	table.clear(leakTrackers)
end

function HiderEvidenceService.GetClosest(
	seekerPosition: Vector3,
	geometry: HiderMapGeometry.ArenaGeometry,
	now: number,
	preferredOwner: Model?
): Target?
	if currentPhase ~= PHASE_ROUND then
		return nil
	end

	local best: Target? = nil
	local bestIsPreferred = false
	local bestPriority = -math.huge
	local bestDistance = math.huge
	for owner, records in pairs(evidenceByOwner) do
		local humanoid, rootPart = getLivingParts(owner)
		if not humanoid
			or not rootPart
			or not isHiderCharacter(owner) then
			evidenceByOwner[owner] = nil
			continue
		end

		for recordKey, evidence in pairs(records) do
			local settings = SIGNAL_SETTINGS[evidence.kind]
			if not settings or evidence.expiresAt <= now then
				records[recordKey] = nil
				continue
			end
			local signalGeometry = HiderMapGeometry.GetForPosition(evidence.position)
			local ownerPosition = rootPart.Position
			local ownerGeometry = HiderMapGeometry.GetForPosition(ownerPosition)
			if not signalGeometry
				or signalGeometry.map ~= geometry.map
				or not ownerGeometry
				or ownerGeometry.map ~= geometry.map then
				continue
			end
			local ownerDistance = planarDistance(seekerPosition, ownerPosition)
			local ownerIsPreferred = owner == preferredOwner

			if (ownerIsPreferred and not bestIsPreferred)
				or (ownerIsPreferred == bestIsPreferred
					and (ownerDistance < bestDistance - 0.001
						or (math.abs(ownerDistance - bestDistance) <= 0.001
							and settings.priority > bestPriority)
						or (math.abs(ownerDistance - bestDistance) <= 0.001
							and settings.priority == bestPriority
							and (not best or evidence.createdAt > best.createdAt)))) then
				bestIsPreferred = ownerIsPreferred
				bestPriority = settings.priority
				bestDistance = ownerDistance
				best = {
					owner = owner,
					kind = evidence.kind,
					-- Evidence only grants temporary knowledge. While it exists the
					-- Seeker tracks the owner's live root; when it expires GetClosest
					-- stops returning that owner altogether.
					position = ownerPosition,
					createdAt = evidence.createdAt,
					expiresAt = evidence.expiresAt,
					serial = evidence.serial,
					distance = ownerDistance,
				}
			end
		end
		if next(records) == nil then
			evidenceByOwner[owner] = nil
		end
	end
	return best
end

local function makeLeakTracker(humanoid: Humanoid, rootPart: BasePart, character: Model): LeakTracker
	local parameters = RaycastParams.new()
	parameters.FilterType = Enum.RaycastFilterType.Exclude
	parameters.FilterDescendantsInstances = { character }
	parameters.IgnoreWater = true
	return {
		humanoid = humanoid,
		rootPart = rootPart,
		parameters = parameters,
		wetUntil = 0,
		wasOnLeak = false,
		lastEvidencePosition = nil,
		slowActive = false,
	}
end

local function updateLeakTracker(character: Model, tracker: LeakTracker, now: number)
	local rootPart = tracker.rootPart
	local rayLength = tracker.humanoid.HipHeight
		+ rootPart.Size.Y * 0.5
		+ LeakConfig.RAY_EXTRA_DISTANCE
	local raycastResult = Workspace:Raycast(
		rootPart.Position,
		Vector3.new(0, -rayLength, 0),
		tracker.parameters
	)
	local isOnLeak = raycastResult ~= nil and isLeakPart(raycastResult.Instance)
	if isOnLeak then
		tracker.wetUntil = now + LeakConfig.TRAIL_DURATION_SECONDS
		if not tracker.wasOnLeak then
			tracker.lastEvidencePosition = nil
		end
	end
	updateLeakSpeed(character, tracker, isOnLeak, now)

	local velocity = rootPart.AssemblyLinearVelocity
	local isMoving = Vector2.new(velocity.X, velocity.Z).Magnitude >= LeakConfig.MIN_MOVE_SPEED
	local trailIsActive = now < tracker.wetUntil
	if not isOnLeak and trailIsActive and isMoving and raycastResult then
		local footprintPosition = raycastResult.Position
		local lastPosition = tracker.lastEvidencePosition
		if not lastPosition
			or (footprintPosition - lastPosition).Magnitude >= LeakConfig.STEP_DISTANCE then
			HiderEvidenceService.Emit(
				character,
				KIND_LEAK,
				footprintPosition,
				math.max(0, tracker.wetUntil - now)
			)
			tracker.lastEvidencePosition = footprintPosition
		end
	elseif not trailIsActive then
		tracker.lastEvidencePosition = nil
	end
	tracker.wasOnLeak = isOnLeak
end

function HiderEvidenceService.Start()
	if trackerRunning then
		return
	end
	trackerRunning = true
	task.spawn(function()
		while trackerRunning do
			task.wait(LeakConfig.SERVER_SAMPLE_INTERVAL_SECONDS)
			if currentPhase ~= PHASE_STARTING and currentPhase ~= PHASE_ROUND then
				continue
			end

			local activeCharacters = getHiderCharacters()
			for character, tracker in pairs(leakTrackers) do
				if not activeCharacters[character] then
					restoreLeakSpeed(character, tracker)
					leakTrackers[character] = nil
				end
			end

			local now = Workspace:GetServerTimeNow()
			for character in pairs(activeCharacters) do
				local humanoid, rootPart = getLivingParts(character)
				if not humanoid or not rootPart then
					local oldTracker = leakTrackers[character]
					if oldTracker then
						restoreLeakSpeed(character, oldTracker)
					end
					leakTrackers[character] = nil
					continue
				end
				local tracker = leakTrackers[character]
				if not tracker or tracker.humanoid ~= humanoid or tracker.rootPart ~= rootPart then
					if tracker then
						restoreLeakSpeed(character, tracker)
					end
					tracker = makeLeakTracker(humanoid, rootPart, character)
					leakTrackers[character] = tracker
				end
				updateLeakTracker(character, tracker, now)
			end
		end
	end)
end

function HiderEvidenceService.SetPhase(phase: string)
	if phase ~= currentPhase then
		HiderEvidenceService.ClearAll()
	end
	currentPhase = phase
end

return HiderEvidenceService
