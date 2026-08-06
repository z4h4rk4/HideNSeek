--!strict

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local SeekerSearchConfig = require(ReplicatedStorage:WaitForChild("SeekerSearchConfig"))
local HiderMapGeometry = require(script.Parent:WaitForChild("HiderMapGeometry"))

local NPC_FOLDER_NAME = "RoundNPCs"
local MANAGED_NPC_ATTRIBUTE = "ManagedRoundNPC"
local ROLE_ATTRIBUTE = "RoundRole"
local ROLE_HIDER = "Hider"
local PHASE_ROUND = "Round"

local KIND_SMOKE = "Smoke"
local KIND_FART = "Fart"
local KIND_LEAK = "Leak"

local LEAK_NAMES: {[string]: boolean} = table.freeze({
	leak = true,
	leaks = true,
})
local LEAK_SAMPLE_INTERVAL = 0.1
local LEAK_TRAIL_DURATION = 5
local LEAK_MIN_MOVE_SPEED = 1
local LEAK_STEP_DISTANCE = 2.2
local LEAK_RAY_EXTRA_DISTANCE = 4

type SignalSettings = {
	duration: number,
	priority: number,
	detectionDistance: number,
}

local SIGNAL_SETTINGS: {[string]: SignalSettings} = {
	[KIND_SMOKE] = {
		duration = 1.75,
		priority = 1,
		detectionDistance = 12,
	},
	[KIND_FART] = {
		duration = 4,
		priority = 2,
		detectionDistance = 22,
	},
	[KIND_LEAK] = {
		duration = 5,
		priority = 3,
		detectionDistance = math.huge,
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

function HiderEvidenceService.Emit(character: Model, kind: string, position: Vector3)
	local settings = SIGNAL_SETTINGS[kind]
	if currentPhase ~= PHASE_ROUND
		or not settings
		or not isHiderCharacter(character)
		or character:GetAttribute(SeekerSearchConfig.CAGED_ATTRIBUTE) == true then
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
	-- Only the newest signal of each kind is needed. For Leak it acts as a
	-- lightweight permission timer: every new footprint refreshes tracking and
	-- the final footprint's expiry is exactly when no live trail remains.
	records[kind] = {
		owner = character,
		kind = kind,
		position = position,
		createdAt = now,
		expiresAt = now + settings.duration,
		serial = nextSerial,
	}
end

function HiderEvidenceService.Clear(character: Model)
	evidenceByOwner[character] = nil
	leakTrackers[character] = nil
end

function HiderEvidenceService.ClearAll()
	table.clear(evidenceByOwner)
	table.clear(leakTrackers)
end

function HiderEvidenceService.GetClosest(
	seekerPosition: Vector3,
	geometry: HiderMapGeometry.ArenaGeometry,
	now: number
): Target?
	if currentPhase ~= PHASE_ROUND then
		return nil
	end

	local best: Target? = nil
	local bestPriority = -math.huge
	local bestDistance = math.huge
	for owner, records in pairs(evidenceByOwner) do
		local humanoid, rootPart = getLivingParts(owner)
		if not humanoid
			or not rootPart
			or not isHiderCharacter(owner)
			or owner:GetAttribute(SeekerSearchConfig.CAGED_ATTRIBUTE) == true then
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
			local signalDistance = planarDistance(seekerPosition, evidence.position)
			if signalDistance > settings.detectionDistance then
				continue
			end
			local ownerDistance = planarDistance(seekerPosition, ownerPosition)

			if settings.priority > bestPriority
				or (settings.priority == bestPriority and ownerDistance < bestDistance)
				or (settings.priority == bestPriority
					and math.abs(ownerDistance - bestDistance) <= 0.001
					and (not best or evidence.createdAt > best.createdAt)) then
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
	}
end

local function updateLeakTracker(character: Model, tracker: LeakTracker, now: number)
	local rootPart = tracker.rootPart
	local rayLength = tracker.humanoid.HipHeight + rootPart.Size.Y * 0.5 + LEAK_RAY_EXTRA_DISTANCE
	local raycastResult = Workspace:Raycast(
		rootPart.Position,
		Vector3.new(0, -rayLength, 0),
		tracker.parameters
	)
	local isOnLeak = raycastResult ~= nil and isLeakPart(raycastResult.Instance)
	if isOnLeak then
		tracker.wetUntil = now + LEAK_TRAIL_DURATION
		if not tracker.wasOnLeak then
			tracker.lastEvidencePosition = nil
		end
	end

	local velocity = rootPart.AssemblyLinearVelocity
	local isMoving = Vector2.new(velocity.X, velocity.Z).Magnitude >= LEAK_MIN_MOVE_SPEED
	local trailIsActive = now < tracker.wetUntil
	if not isOnLeak and trailIsActive and isMoving and raycastResult then
		local footprintPosition = raycastResult.Position
		local lastPosition = tracker.lastEvidencePosition
		if not lastPosition
			or (footprintPosition - lastPosition).Magnitude >= LEAK_STEP_DISTANCE then
			HiderEvidenceService.Emit(character, KIND_LEAK, footprintPosition)
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
			task.wait(LEAK_SAMPLE_INTERVAL)
			if currentPhase ~= PHASE_ROUND then
				continue
			end

			local activeCharacters = getHiderCharacters()
			for character in pairs(leakTrackers) do
				if not activeCharacters[character] then
					leakTrackers[character] = nil
				end
			end

			local now = Workspace:GetServerTimeNow()
			for character in pairs(activeCharacters) do
				if character:GetAttribute(SeekerSearchConfig.CAGED_ATTRIBUTE) == true then
					leakTrackers[character] = nil
					continue
				end
				local humanoid, rootPart = getLivingParts(character)
				if not humanoid or not rootPart then
					leakTrackers[character] = nil
					continue
				end
				local tracker = leakTrackers[character]
				if not tracker or tracker.humanoid ~= humanoid or tracker.rootPart ~= rootPart then
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
