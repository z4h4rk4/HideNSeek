--!strict

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local ServerStorage = game:GetService("ServerStorage")
local StarterPlayer = game:GetService("StarterPlayer")
local Teams = game:GetService("Teams")
local Workspace = game:GetService("Workspace")

local roundModules = script.Parent:WaitForChild("Round")
local RoundConfig = require(roundModules:WaitForChild("RoundConfig"))
local DoorCharacterCollider = require(roundModules:WaitForChild("DoorCharacterCollider"))
local SeekerSearchConfig = require(ReplicatedStorage:WaitForChild("SeekerSearchConfig"))
local HiderEvidenceService = require(roundModules:WaitForChild("HiderEvidenceService"))
local HiderService = require(roundModules:WaitForChild("HiderService"))
local CageService = require(roundModules:WaitForChild("CageService"))
local RoundCharacterState = require(roundModules:WaitForChild("RoundCharacterState"))
local RoundControl = require(roundModules:WaitForChild("RoundControl"))
local SeekerCaptureService = require(roundModules:WaitForChild("SeekerCaptureService"))

local STATE_NAME = "RoundState"
local HIDER_TEAM_NAME = "Hiders"
local SEEKER_TEAM_NAME = "Seekers"
local NPC_FOLDER_NAME = "RoundNPCs"
local STARTER_CHARACTER_NAME = "StarterCharacter"
local HUNTER_CHARACTER_NAME = "HunterCharacter"
local HUB_CONTAINER_NAME = "HUB"
local HUB_SPAWN_NAME = "SpawnHUB"
local ARENA_SPAWN_NAME = "SpawnArena"

local STARTING_DURATION_SECONDS = RoundConfig.STARTING_DURATION_SECONDS
local ROUND_DURATION_SECONDS = RoundConfig.ROUND_DURATION_SECONDS
local ARENA_READY_DURATION_SECONDS = RoundConfig.ARENA_READY_DURATION_SECONDS
local MINIMUM_PLAYERS = RoundConfig.MINIMUM_PLAYERS
local MAX_HIDERS = RoundConfig.MAX_HIDERS
local MAX_SEEKERS = RoundConfig.MAX_SEEKERS
local BOT_SEEKER_MODE = RoundConfig.BOT_SEEKER_MODE
local PLAYER_SEEKER_CHANCE = RoundConfig.PLAYER_SEEKER_CHANCE
local WALK_SPEED = RoundConfig.WALK_SPEED
local SEEKER_WALK_SPEED = RoundConfig.SEEKER_WALK_SPEED
local SEEKER_SCALE_MULTIPLIER = RoundConfig.SEEKER_SCALE_MULTIPLIER
local NPC_SPAWN_SPACING = RoundConfig.NPC.SPAWN_SPACING
local NPC_SPAWN_CLEARANCE = RoundConfig.NPC.SPAWN_CLEARANCE
local MAX_ACTIVE_NPCS = RoundConfig.NPC.MAX_ACTIVE_NPCS
local RECOMMENDED_ARENA_SPAWN_SIZE = 18

local BASE_SCALE_ATTRIBUTE = "RoundBaseScale"
local MANAGED_NPC_ATTRIBUTE = "ManagedRoundNPC"
local ROUND_SPAWN_SLOT_ATTRIBUTE = "RoundArenaSpawnSlot"
local ROUND_CAUGHT_ATTRIBUTE = "RoundCaught"

local ROLE_HIDER = RoundConfig.ROLE_HIDER
local ROLE_SEEKER = RoundConfig.ROLE_SEEKER
local ROLE_SPECTATOR = RoundConfig.ROLE_SPECTATOR

local PHASE_WAITING = RoundConfig.PHASE_WAITING
local PHASE_PREPARING = RoundConfig.PHASE_PREPARING
local PHASE_STARTING = RoundConfig.PHASE_STARTING
local PHASE_ROUND = RoundConfig.PHASE_ROUND
local PHASE_ENDED = RoundConfig.PHASE_ENDED

local random = Random.new()
local phaseEndsAt = 0
local skipCountdownRequested = false
local endRoundRequested = false
local restartRoundRequested = false
local preparingRoundParticipants = false
local startingParticipantsAssigned = false
local pendingHiderReplacements = 0
local caughtHiderCount = 0
local activeArena: Instance? = nil
local activeArenaSpawn: BasePart? = nil
local previousArena: Instance? = nil

type AdminNpcPopulation = {
	Hiders: number,
	Seekers: number,
}

-- This is a server-lifetime testing override. It deliberately is not saved to
-- DataStore, so a bad test setup cannot leak into another server session.
local adminNpcPopulation: AdminNpcPopulation? = nil

type ArenaCandidate = {
	Arena: Instance,
	Spawn: BasePart,
}

local SPAWN_SLOT_COORDINATES = table.freeze({
	Vector2.new(0, 0),
	Vector2.new(-1, 0),
	Vector2.new(1, 0),
	Vector2.new(0, -1),
	Vector2.new(0, 1),
	Vector2.new(-1, -1),
	Vector2.new(1, -1),
	Vector2.new(-1, 1),
	Vector2.new(1, 1),
})

DoorCharacterCollider.Configure()
HiderEvidenceService.Start()

local function getOrCreateTeam(name: string, color: BrickColor): Team
	local existing = Teams:FindFirstChild(name)
	if existing then
		if not existing:IsA("Team") then
			error(`Teams.{name} must be a Team`)
		end
		existing.TeamColor = color
		existing.AutoAssignable = false
		return existing
	end

	local team = Instance.new("Team")
	team.Name = name
	team.TeamColor = color
	team.AutoAssignable = false
	team.Parent = Teams
	return team
end

local hiderTeam = getOrCreateTeam(HIDER_TEAM_NAME, BrickColor.new("Lime green"))
local seekerTeam = getOrCreateTeam(SEEKER_TEAM_NAME, BrickColor.new("Bright orange"))

local existingState = ReplicatedStorage:FindFirstChild(STATE_NAME)
if existingState and not existingState:IsA("Folder") then
	error(`ReplicatedStorage.{STATE_NAME} must be a Folder`)
end

local roundState: Folder
if existingState then
	roundState = existingState :: Folder
else
	roundState = Instance.new("Folder")
	roundState.Name = STATE_NAME
	roundState.Parent = ReplicatedStorage
end

roundState:SetAttribute("MaxHiders", MAX_HIDERS)
roundState:SetAttribute("MaxSeekers", MAX_SEEKERS)
roundState:SetAttribute("BotSeekerMode", BOT_SEEKER_MODE)
roundState:SetAttribute("HiderCount", 0)
roundState:SetAttribute("CaughtHiderCount", 0)
roundState:SetAttribute("SeekerCount", 0)
roundState:SetAttribute("Phase", PHASE_WAITING)
roundState:SetAttribute("EndsAt", 0)
roundState:SetAttribute("NpcAIEnabled", true)
roundState:SetAttribute("NpcPopulationOverrideEnabled", false)
roundState:SetAttribute("NpcTargetHiders", 0)
roundState:SetAttribute("NpcTargetSeekers", 0)
roundState:SetAttribute("MaxAdminNpcs", MAX_ACTIVE_NPCS)
roundState:SetAttribute("ActiveArena", "")
roundState:SetAttribute("ActiveArenaSpawn", "")
roundState:SetAttribute(
	SeekerSearchConfig.SEARCH_SHAPE_VERSION_ATTRIBUTE,
	SeekerSearchConfig.SEARCH_SHAPE_VERSION
)

local existingNpcFolder = Workspace:FindFirstChild(NPC_FOLDER_NAME)
if existingNpcFolder and not existingNpcFolder:IsA("Folder") then
	error(`Workspace.{NPC_FOLDER_NAME} must be a Folder`)
end

local npcFolder: Folder
if existingNpcFolder then
	npcFolder = existingNpcFolder :: Folder
else
	npcFolder = Instance.new("Folder")
	npcFolder.Name = NPC_FOLDER_NAME
	npcFolder.Parent = Workspace
end

local npcSerial = 0
local missingTemplateWarned: {[string]: boolean} = {}
local missingHubSpawnWarned = false
local missingArenaSpawnWarned = false
local warnedSmallArenaSpawns: {[BasePart]: boolean} = {}

local function refreshCharacterRoundState(character: Model, roleValue: any)
	local role = if type(roleValue) == "string" then roleValue else ROLE_SPECTATOR
	local phaseValue = roundState:GetAttribute("Phase")
	local phase = if type(phaseValue) == "string" then phaseValue else PHASE_WAITING
	RoundCharacterState.Apply(character, role, phase, preparingRoundParticipants)
end

local function refreshPlayerRoundState(player: Player)
	local character = player.Character
	if character then
		refreshCharacterRoundState(character, player:GetAttribute("RoundRole"))
	end
end

local function refreshAllCharacterRoundStates()
	for _, player in ipairs(Players:GetPlayers()) do
		refreshPlayerRoundState(player)
	end
	for _, child in ipairs(npcFolder:GetChildren()) do
		if child:IsA("Model") and child:GetAttribute(MANAGED_NPC_ATTRIBUTE) == true then
			refreshCharacterRoundState(child, child:GetAttribute("RoundRole"))
		end
	end
end

local function tryNpcCleanupStep(npc: Model, stepName: string, callback: () -> ())
	local succeeded, message = pcall(callback)
	if not succeeded then
		warn(`RoundManager: {stepName} cleanup failed for {npc.Name}: {tostring(message)}`)
	end
end

local function safelyDestroyManagedNpc(npc: Model): boolean
	tryNpcCleanupStep(npc, "capture", function()
		SeekerCaptureService.ClearOwner(npc)
	end)
	tryNpcCleanupStep(npc, "cage", function()
		CageService.Remove(npc)
	end)
	tryNpcCleanupStep(npc, "evidence", function()
		HiderEvidenceService.Clear(npc)
	end)
	tryNpcCleanupStep(npc, "AI", function()
		HiderService.Stop(npc)
	end)
	tryNpcCleanupStep(npc, "round state", function()
		RoundCharacterState.Clear(npc)
	end)
	local destroyed, message = pcall(function()
		npc:Destroy()
	end)
	if not destroyed then
		warn(`RoundManager: destroy failed for managed NPC {npc.Name}: {tostring(message)}`)
	end
	return destroyed
end

local function clearNpcs()
	for _, child in ipairs(npcFolder:GetChildren()) do
		if child:GetAttribute(MANAGED_NPC_ATTRIBUTE) == true then
			if child:IsA("Model") then
				safelyDestroyManagedNpc(child)
			else
				local destroyed, message = pcall(function()
					child:Destroy()
				end)
				if not destroyed then
					warn(`RoundManager: destroy failed for managed instance {child.Name}: {tostring(message)}`)
				end
			end
		end
	end
end

local function getHubSpawn(): BasePart?
	local hubContainer = Workspace:FindFirstChild(HUB_CONTAINER_NAME)
	local hubSpawn = if hubContainer then hubContainer:FindFirstChild(HUB_SPAWN_NAME) else nil
	if hubSpawn and hubSpawn:IsA("BasePart") then
		if hubSpawn:IsA("SpawnLocation") then
			hubSpawn.Enabled = true
			hubSpawn.Neutral = true
			hubSpawn.AllowTeamChangeOnTouch = false
		end
		missingHubSpawnWarned = false
		return hubSpawn
	end
	if not missingHubSpawnWarned then
		missingHubSpawnWarned = true
		warn(
			`RoundManager: Workspace.{HUB_CONTAINER_NAME}.{HUB_SPAWN_NAME} `
				.. "must be a BasePart used as the hub spawn"
		)
	end
	return nil
end

local function getArenaForSpawn(instance: Instance): Instance?
	local directParent = instance.Parent
	local current = directParent
	while current and current ~= Workspace do
		if current:FindFirstChild("Map") then
			return current
		end
		current = current.Parent
	end
	if directParent and directParent ~= Workspace then
		return directParent
	end
	return if instance.Parent == Workspace then instance else nil
end

local function getArenaCandidates(): {ArenaCandidate}
	local candidates: {ArenaCandidate} = {}
	local seenArenas: {[Instance]: boolean} = {}
	local arenaSpawns: {BasePart} = {}
	for _, descendant in ipairs(Workspace:GetDescendants()) do
		if descendant.Name == ARENA_SPAWN_NAME and descendant:IsA("BasePart") then
			table.insert(arenaSpawns, descendant)
		end
	end
	table.sort(arenaSpawns, function(left, right)
		return left:GetFullName() < right:GetFullName()
	end)

	for _, arenaSpawn in ipairs(arenaSpawns) do
		if arenaSpawn:IsA("SpawnLocation") then
			-- Arena spawns are controlled by this server. Roblox's automatic
			-- spawning must only use the hub SpawnHUB.
			arenaSpawn.Enabled = false
		end
		local arena = getArenaForSpawn(arenaSpawn)
		if arena and not seenArenas[arena] then
			seenArenas[arena] = true
			table.insert(candidates, {
				Arena = arena,
				Spawn = arenaSpawn,
			})
		end
	end
	return candidates
end

local function activeArenaIsAvailable(): boolean
	local arena = activeArena
	local arenaSpawn = activeArenaSpawn
	return arena ~= nil
		and arena.Parent ~= nil
		and arenaSpawn ~= nil
		and arenaSpawn.Parent ~= nil
		and arenaSpawn:IsDescendantOf(Workspace)
end

local function selectActiveArena(): boolean
	local candidates = getArenaCandidates()
	if #candidates == 0 then
		if not missingArenaSpawnWarned then
			missingArenaSpawnWarned = true
			warn(`RoundManager: every arena needs one BasePart named {ARENA_SPAWN_NAME}; the round will wait`)
		end
		return false
	end

	missingArenaSpawnWarned = false
	local selectable: {ArenaCandidate} = {}
	for _, candidate in ipairs(candidates) do
		if #candidates == 1 or candidate.Arena ~= previousArena then
			table.insert(selectable, candidate)
		end
	end
	local chosen = selectable[random:NextInteger(1, #selectable)]
	activeArena = chosen.Arena
	activeArenaSpawn = chosen.Spawn
	previousArena = chosen.Arena
	SeekerCaptureService.SetArena(chosen.Arena)
	if not warnedSmallArenaSpawns[chosen.Spawn]
		and (chosen.Spawn.Size.X < RECOMMENDED_ARENA_SPAWN_SIZE
			or chosen.Spawn.Size.Z < RECOMMENDED_ARENA_SPAWN_SIZE) then
		warnedSmallArenaSpawns[chosen.Spawn] = true
		warn(
			`RoundManager: {chosen.Spawn:GetFullName()} should be at least `
				.. `{RECOMMENDED_ARENA_SPAWN_SIZE} x {RECOMMENDED_ARENA_SPAWN_SIZE} studs `
				.. "to keep all participant spawn slots separate"
		)
	end
	roundState:SetAttribute("ActiveArena", chosen.Arena.Name)
	roundState:SetAttribute("ActiveArenaSpawn", chosen.Spawn:GetFullName())
	return true
end

local function clearActiveArena()
	SeekerCaptureService.SetArena(nil)
	activeArena = nil
	activeArenaSpawn = nil
	roundState:SetAttribute("ActiveArena", "")
	roundState:SetAttribute("ActiveArenaSpawn", "")
end

local function getSpawnRaycastParameters(): RaycastParams
	local excluded: {Instance} = { npcFolder }
	for _, player in ipairs(Players:GetPlayers()) do
		if player.Character then
			table.insert(excluded, player.Character)
		end
	end
	local parameters = RaycastParams.new()
	parameters.FilterType = Enum.RaycastFilterType.Exclude
	parameters.FilterDescendantsInstances = excluded
	parameters.IgnoreWater = true
	return parameters
end

local function findGroundPosition(candidate: Vector3, fallbackY: number): Vector3
	local origin = Vector3.new(candidate.X, fallbackY + 12, candidate.Z)
	local result = Workspace:Raycast(origin, Vector3.new(0, -80, 0), getSpawnRaycastParameters())
	local groundY = if result then result.Position.Y else fallbackY
	return Vector3.new(candidate.X, groundY, candidate.Z)
end

local function getSpawnSlotCoordinate(slot: number): Vector2
	local fixedCoordinate = SPAWN_SLOT_COORDINATES[slot]
	if fixedCoordinate then
		return fixedCoordinate
	end

	local extraIndex = slot - #SPAWN_SLOT_COORDINATES - 1
	local positionsPerRing = 12
	local ring = 2 + math.floor(extraIndex / positionsPerRing)
	local angle = (extraIndex % positionsPerRing) / positionsPerRing * math.pi * 2
	return Vector2.new(math.cos(angle), math.sin(angle)) * ring
end

local function getSpawnRootCFrame(
	spawnPart: BasePart,
	slot: number,
	humanoid: Humanoid,
	rootPart: BasePart
): CFrame
	local coordinate = getSpawnSlotCoordinate(math.max(1, slot))
	local characterRadius = math.max(rootPart.Size.X, rootPart.Size.Z) * 0.5 + 0.5
	local availableHalfX = math.max(0, spawnPart.Size.X * 0.5 - characterRadius)
	local availableHalfZ = math.max(0, spawnPart.Size.Z * 0.5 - characterRadius)
	local localOffset = Vector3.new(
		math.clamp(coordinate.X * NPC_SPAWN_SPACING, -availableHalfX, availableHalfX),
		0,
		math.clamp(coordinate.Y * NPC_SPAWN_SPACING, -availableHalfZ, availableHalfZ)
	)
	local worldOffset = spawnPart.CFrame:VectorToWorldSpace(localOffset)
	local spawnTop = spawnPart.Position.Y + spawnPart.Size.Y * 0.5
	local groundPosition = findGroundPosition(spawnPart.Position + worldOffset, spawnTop)
	local rootHeight = math.max(0, humanoid.HipHeight)
		+ rootPart.Size.Y * 0.5
		+ NPC_SPAWN_CLEARANCE
	local rootPosition = groundPosition + Vector3.new(0, rootHeight, 0)
	local forward = Vector3.new(spawnPart.CFrame.LookVector.X, 0, spawnPart.CFrame.LookVector.Z)
	if forward.Magnitude < 0.001 then
		forward = Vector3.new(0, 0, -1)
	else
		forward = forward.Unit
	end
	return CFrame.lookAt(rootPosition, rootPosition + forward)
end

local function placeCharacterAtSpawn(character: Model, spawnPart: BasePart, slot: number): boolean
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	local rootPart = character:FindFirstChild("HumanoidRootPart")
	if not humanoid or not rootPart or not rootPart:IsA("BasePart") then
		return false
	end

	humanoid.Sit = false
	humanoid.PlatformStand = false
	humanoid.Jump = false
	rootPart.Anchored = false
	local rootToPivot = rootPart.CFrame:ToObjectSpace(character:GetPivot())
	local destinationRoot = getSpawnRootCFrame(spawnPart, slot, humanoid, rootPart)
	character:PivotTo(destinationRoot * rootToPivot)
	rootPart.AssemblyLinearVelocity = Vector3.zero
	rootPart.AssemblyAngularVelocity = Vector3.zero
	humanoid:ChangeState(Enum.HumanoidStateType.Running)
	return true
end

local function isValidSpawnSlot(value: any): boolean
	return type(value) == "number" and value % 1 == 0 and value >= 1
end

local function spawnSlotIsUsed(slot: number, ignored: Instance?): boolean
	for _, player in ipairs(Players:GetPlayers()) do
		if player ~= ignored and player:GetAttribute(ROUND_SPAWN_SLOT_ATTRIBUTE) == slot then
			return true
		end
	end
	for _, npc in ipairs(npcFolder:GetChildren()) do
		if npc ~= ignored
			and npc:GetAttribute(MANAGED_NPC_ATTRIBUTE) == true
			and npc:GetAttribute(ROUND_SPAWN_SLOT_ATTRIBUTE) == slot then
			return true
		end
	end
	return false
end

local function getAvailableRoundSpawnSlot(preferred: any, ignored: Instance?): number
	if isValidSpawnSlot(preferred) and not spawnSlotIsUsed(preferred, ignored) then
		return preferred
	end
	-- Exact admin NPC composition can coexist with the normal player roster.
	-- Reserve enough unique slots so several Hunters do not stack together.
	local maximumSlots = MAX_HIDERS + MAX_SEEKERS + MAX_ACTIVE_NPCS * 2
	for slot = 1, maximumSlots do
		if not spawnSlotIsUsed(slot, ignored) then
			return slot
		end
	end
	return maximumSlots + 1
end

local function getHubSpawnSlot(player: Player): number
	local players = Players:GetPlayers()
	table.sort(players, function(left, right)
		return left.UserId < right.UserId
	end)
	for index, candidate in ipairs(players) do
		if candidate == player then
			return index
		end
	end
	return 1
end

local function setHubRespawnLocation(player: Player)
	local hubSpawn = getHubSpawn()
	if hubSpawn and hubSpawn:IsA("SpawnLocation") then
		player.RespawnLocation = hubSpawn
	else
		player.RespawnLocation = nil
	end
end

local function applyCharacterRoleScale(character: Model, role: string)
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	local configuredBaseScale = character:GetAttribute(BASE_SCALE_ATTRIBUTE)
	local baseScale: number
	if type(configuredBaseScale) == "number" and configuredBaseScale > 0 then
		baseScale = configuredBaseScale
	else
		baseScale = character:GetScale()
		character:SetAttribute(BASE_SCALE_ATTRIBUTE, baseScale)
	end

	local isManagedNpcSeeker = role == ROLE_SEEKER
		and character:GetAttribute(MANAGED_NPC_ATTRIBUTE) == true
	local targetScale = if role == ROLE_SEEKER and not isManagedNpcSeeker
		then baseScale * SEEKER_SCALE_MULTIPLIER
		else baseScale
	local scaleChanged = math.abs(character:GetScale() - targetScale) >= 0.001
	if scaleChanged then
		local succeeded, message = pcall(function()
			local oldHeight = character:GetExtentsSize().Y
			character:ScaleTo(targetScale)
			local heightDifference = character:GetExtentsSize().Y - oldHeight
			character:PivotTo(character:GetPivot() + Vector3.new(0, heightDifference * 0.5, 0))
		end)
		if not succeeded then
			warn(`RoundManager: could not scale {character:GetFullName()}: {message}`)
			scaleChanged = false
		end
	end

	-- ScaleTo also scales spatial Humanoid properties. Normalize movement only
	-- after scaling so players and NPCs keep the same real speed at every size.
	if humanoid then
		humanoid.WalkSpeed = if role == ROLE_SEEKER then SEEKER_WALK_SPEED else WALK_SPEED
		humanoid.UseJumpPower = false
		humanoid.JumpHeight = 0
	end
	if scaleChanged then
		local rootPart = character:FindFirstChild("HumanoidRootPart")
		if rootPart and rootPart:IsA("BasePart") then
			local velocity = rootPart.AssemblyLinearVelocity
			rootPart.AssemblyLinearVelocity = Vector3.new(0, velocity.Y, 0)
			rootPart.AssemblyAngularVelocity = Vector3.zero
		end
	end
	DoorCharacterCollider.Refresh(
		character,
		if character:GetAttribute(MANAGED_NPC_ATTRIBUTE) == true
			then DoorCharacterCollider.NPC_COLLISION_GROUP
			else DoorCharacterCollider.CHARACTER_COLLISION_GROUP
	)
end

local function applyPlayerRoleScale(player: Player)
	local character = player.Character
	if character then
		local role = player:GetAttribute("RoundRole")
		applyCharacterRoleScale(character, if type(role) == "string" then role else ROLE_SPECTATOR)
	end
end

local function relocatePlayerForCurrentState(player: Player)
	setHubRespawnLocation(player)
	local character = player.Character
	if not character then
		return
	end

	local role = player:GetAttribute("RoundRole")
	local phase = roundState:GetAttribute("Phase")
	local participantPhase = preparingRoundParticipants
		or phase == PHASE_PREPARING
		or phase == PHASE_STARTING
		or phase == PHASE_ROUND
	local arenaSpawn = activeArenaSpawn
	if participantPhase
		and (role == ROLE_HIDER or role == ROLE_SEEKER)
		and activeArenaIsAvailable()
		and arenaSpawn then
		local slot = getAvailableRoundSpawnSlot(
			player:GetAttribute(ROUND_SPAWN_SLOT_ATTRIBUTE),
			player
		)
		player:SetAttribute(ROUND_SPAWN_SLOT_ATTRIBUTE, slot)
		placeCharacterAtSpawn(character, arenaSpawn, slot)
		return
	end

	local hubSpawn = getHubSpawn()
	if hubSpawn then
		placeCharacterAtSpawn(character, hubSpawn, getHubSpawnSlot(player))
	end
end

local function setSpectator(player: Player, caught: boolean?)
	SeekerCaptureService.ClearOwner(player)
	CageService.Remove(player)
	player:SetAttribute(ROUND_CAUGHT_ATTRIBUTE, if caught == true then true else nil)
	player:SetAttribute("RoundRole", ROLE_SPECTATOR)
	player:SetAttribute(ROUND_SPAWN_SLOT_ATTRIBUTE, nil)
	player.Team = nil
	player.Neutral = true
	applyPlayerRoleScale(player)
	relocatePlayerForCurrentState(player)
	refreshPlayerRoundState(player)
end

local function setPlayerRole(player: Player, role: string, preferredSpawnSlot: number?)
	SeekerCaptureService.ClearOwner(player)
	CageService.Remove(player)
	player:SetAttribute(ROUND_CAUGHT_ATTRIBUTE, nil)
	local slot = getAvailableRoundSpawnSlot(
		preferredSpawnSlot or player:GetAttribute(ROUND_SPAWN_SLOT_ATTRIBUTE),
		player
	)
	player:SetAttribute(ROUND_SPAWN_SLOT_ATTRIBUTE, slot)
	player:SetAttribute("RoundRole", role)
	player.Team = if role == ROLE_SEEKER then seekerTeam else hiderTeam
	player.Neutral = false
	applyPlayerRoleScale(player)
	relocatePlayerForCurrentState(player)
	refreshPlayerRoundState(player)
end

local function resetRoles(preserveCaughtResults: boolean?)
	startingParticipantsAssigned = false
	SeekerCaptureService.CancelAll()
	CageService.RemoveAll()
	clearNpcs()
	for _, player in ipairs(Players:GetPlayers()) do
		setSpectator(player)
	end
	clearActiveArena()
	if preserveCaughtResults ~= true then
		caughtHiderCount = 0
	end
	roundState:SetAttribute("HiderCount", 0)
	roundState:SetAttribute("CaughtHiderCount", caughtHiderCount)
	roundState:SetAttribute("SeekerCount", 0)
end

local function getRoleCounts(): (number, number)
	local hiderCount = 0
	local seekerCount = 0
	for _, player in ipairs(Players:GetPlayers()) do
		local role = player:GetAttribute("RoundRole")
		if role == ROLE_HIDER then
			hiderCount += 1
		elseif role == ROLE_SEEKER then
			seekerCount += 1
		end
	end
	for _, npc in ipairs(npcFolder:GetChildren()) do
		if npc:GetAttribute(MANAGED_NPC_ATTRIBUTE) == true then
			local role = npc:GetAttribute("RoundRole")
			if role == ROLE_HIDER then
				hiderCount += 1
			elseif role == ROLE_SEEKER then
				seekerCount += 1
			end
		end
	end
	return hiderCount, seekerCount
end

local function getPlayerRoleCounts(): (number, number)
	local hiders = 0
	local seekers = 0
	for _, player in ipairs(Players:GetPlayers()) do
		local role = player:GetAttribute("RoundRole")
		if role == ROLE_HIDER then
			hiders += 1
		elseif role == ROLE_SEEKER then
			seekers += 1
		end
	end
	return hiders, seekers
end

local function getManagedNpcCount(): number
	local count = 0
	for _, child in ipairs(npcFolder:GetChildren()) do
		if child:IsA("Model") and child:GetAttribute(MANAGED_NPC_ATTRIBUTE) == true then
			count += 1
		end
	end
	return count
end

local function getNpcRoleCounts(): (number, number)
	local hiders = 0
	local seekers = 0
	for _, npc in ipairs(npcFolder:GetChildren()) do
		if npc:IsA("Model") and npc:GetAttribute(MANAGED_NPC_ATTRIBUTE) == true then
			local role = npc:GetAttribute("RoundRole")
			if role == ROLE_HIDER then
				hiders += 1
			elseif role == ROLE_SEEKER then
				seekers += 1
			end
		end
	end
	return hiders, seekers
end

local function chooseNpcRole(): string?
	local hiderCount, seekerCount = getRoleCounts()
	local usedHiderSlots = hiderCount + caughtHiderCount
	if usedHiderSlots >= MAX_HIDERS and seekerCount >= MAX_SEEKERS then
		return nil
	end
	if hiderCount == 0 and usedHiderSlots < MAX_HIDERS then
		return ROLE_HIDER
	end
	if seekerCount == 0 and seekerCount < MAX_SEEKERS then
		return ROLE_SEEKER
	end

	local hiderFill = usedHiderSlots / MAX_HIDERS
	local seekerFill = seekerCount / MAX_SEEKERS
	if usedHiderSlots < MAX_HIDERS and (seekerCount >= MAX_SEEKERS or hiderFill <= seekerFill) then
		return ROLE_HIDER
	end
	if seekerCount < MAX_SEEKERS then
		return ROLE_SEEKER
	end
	return nil
end

local function updateRoleCounts()
	local hiderCount, seekerCount = getRoleCounts()
	roundState:SetAttribute("HiderCount", hiderCount)
	roundState:SetAttribute("CaughtHiderCount", caughtHiderCount)
	roundState:SetAttribute("SeekerCount", seekerCount)
end

local function recordCaughtHider()
	caughtHiderCount += 1
	roundState:SetAttribute("CaughtHiderCount", caughtHiderCount)
end

local function shufflePlayers(players: {Player})
	for index = #players, 2, -1 do
		local swapIndex = random:NextInteger(1, index)
		players[index], players[swapIndex] = players[swapIndex], players[index]
	end
end

local function applyNpcColor(npc: Model, colorIndex: number)
	local colors = RoundConfig.NPC.COLORS
	local color = colors[((colorIndex - 1) % #colors) + 1]
	for _, descendant in ipairs(npc:GetDescendants()) do
		if descendant:IsA("BasePart")
			and descendant.Name ~= "HumanoidRootPart"
			and descendant.Transparency < 1 then
			descendant.Color = color
		end
	end

	local highlight = Instance.new("Highlight")
	highlight.Name = "NpcColorHighlight"
	highlight.FillColor = color
	highlight.FillTransparency = 0.82
	highlight.OutlineColor = color
	highlight.OutlineTransparency = 0.15
	highlight.DepthMode = Enum.HighlightDepthMode.Occluded
	highlight.Parent = npc
end

local function getValidatedNpcTemplate(role: string): (Model?, string)
	local isHunter = role == ROLE_SEEKER
	local templateContainer: Instance = if isHunter then ServerStorage else StarterPlayer
	local templateName = if isHunter then HUNTER_CHARACTER_NAME else STARTER_CHARACTER_NAME
	local templatePath = if isHunter
		then `ServerStorage.{HUNTER_CHARACTER_NAME}`
		else `StarterPlayer.{STARTER_CHARACTER_NAME}`
	local template = templateContainer:FindFirstChild(templateName)
	if not template or not template:IsA("Model") then
		return nil, `{templatePath} must be a Model`
	end
	local humanoid = template:FindFirstChildOfClass("Humanoid")
	local rootPart = template:FindFirstChild("HumanoidRootPart")
	if not humanoid or not rootPart or not rootPart:IsA("BasePart") then
		return nil, `{templatePath} needs Humanoid and HumanoidRootPart`
	end
	if isHunter then
		local baseBody = template:FindFirstChild("BaseBody")
		if not baseBody or not baseBody:IsA("BasePart") then
			return nil, `{templatePath} needs a BasePart named BaseBody`
		end
	end
	return template, templatePath
end

local function spawnNpc(role: string): boolean
	local arenaSpawn = activeArenaSpawn
	if not activeArenaIsAvailable() or not arenaSpawn then
		return false
	end

	local template, templatePath = getValidatedNpcTemplate(role)
	if not template then
		if not missingTemplateWarned[role] then
			missingTemplateWarned[role] = true
			warn(`RoundManager: {templatePath}`)
		end
		return false
	end

	missingTemplateWarned[role] = false
	template.Archivable = true
	npcSerial += 1
	local spawnSlot = getAvailableRoundSpawnSlot(nil, nil)
	local npc = template:Clone()
	npc.Name = `NPC_{role}_{npcSerial}`
	npc:SetAttribute(MANAGED_NPC_ATTRIBUTE, true)
	npc:SetAttribute("RoundRole", role)
	npc:SetAttribute(
		SeekerSearchConfig.HIDER_INVISIBLE_ATTRIBUTE,
		if role == ROLE_HIDER then true else nil
	)
	npc:SetAttribute(ROUND_SPAWN_SLOT_ATTRIBUTE, spawnSlot)
	local humanoid = npc:FindFirstChildOfClass("Humanoid")
	local rootPart = npc:FindFirstChild("HumanoidRootPart")
	assert(humanoid and rootPart and rootPart:IsA("BasePart"))
	if role == ROLE_SEEKER then
		-- HunterCharacter is a single-body rig without a Head/Neck. Disable the
		-- standard neck requirement before parenting it to Workspace, otherwise
		-- its Humanoid can die as soon as the clone enters the world.
		humanoid.RequiresNeck = false
		humanoid.BreakJointsOnDeath = false
		if humanoid.MaxHealth <= 0 then
			humanoid.MaxHealth = 100
		end
		humanoid.Health = humanoid.MaxHealth

		local baseBody = npc:FindFirstChild("BaseBody")
		if not baseBody or not baseBody:IsA("BasePart") then
			warn(`RoundManager: {templatePath} needs a BasePart named BaseBody`)
			npc:Destroy()
			return false
		end
		local bodyWeld = rootPart:FindFirstChildOfClass("WeldConstraint")
		if not bodyWeld then
			bodyWeld = Instance.new("WeldConstraint")
			bodyWeld.Name = "BodyWeld"
			bodyWeld.Parent = rootPart
		end
		bodyWeld.Part0 = rootPart
		bodyWeld.Part1 = baseBody
		rootPart.RootPriority = 127
		rootPart.CanCollide = false
		baseBody.Anchored = false
		baseBody.Massless = true
		baseBody.CanCollide = false
		baseBody.CanTouch = true
		baseBody.CanQuery = true
		local bodyHalfHeight = math.abs(baseBody.CFrame.RightVector.Y) * baseBody.Size.X * 0.5
			+ math.abs(baseBody.CFrame.UpVector.Y) * baseBody.Size.Y * 0.5
			+ math.abs(baseBody.CFrame.LookVector.Y) * baseBody.Size.Z * 0.5
		local rootHeightAboveBodyBottom = rootPart.Position.Y
			- (baseBody.Position.Y - bodyHalfHeight)
		humanoid.HipHeight = math.max(
			humanoid.HipHeight,
			rootHeightAboveBodyBottom - rootPart.Size.Y * 0.5,
			0
		)
	end
	rootPart.Anchored = true
	npc.Parent = npcFolder
	applyCharacterRoleScale(npc, role)

	humanoid.DisplayName = if role == ROLE_SEEKER then "NPC Seeker" else "NPC Hider"
	humanoid.WalkSpeed = if role == ROLE_SEEKER then SEEKER_WALK_SPEED else WALK_SPEED
	humanoid.UseJumpPower = false
	humanoid.JumpHeight = 0
	humanoid.AutoRotate = true
	humanoid.Sit = false
	humanoid.PlatformStand = false
	humanoid:SetStateEnabled(Enum.HumanoidStateType.FallingDown, false)
	humanoid:SetStateEnabled(Enum.HumanoidStateType.Ragdoll, false)

	for _, descendant in ipairs(npc:GetDescendants()) do
		if descendant:IsA("BasePart") then
			if descendant ~= rootPart then
				descendant.Anchored = false
			end
			descendant.AssemblyLinearVelocity = Vector3.zero
			descendant.AssemblyAngularVelocity = Vector3.zero
		end
	end

	local rootToPivot = rootPart.CFrame:ToObjectSpace(npc:GetPivot())
	local destinationRoot = getSpawnRootCFrame(arenaSpawn, spawnSlot, humanoid, rootPart)
	npc:PivotTo(destinationRoot * rootToPivot)
	if role == ROLE_HIDER then
		applyNpcColor(npc, npcSerial)
	end
	refreshCharacterRoundState(npc, role)
	task.spawn(function()
		RunService.Heartbeat:Wait()
		if not npc.Parent or not rootPart:IsDescendantOf(npc) then
			return
		end
		rootPart.AssemblyLinearVelocity = Vector3.zero
		rootPart.AssemblyAngularVelocity = Vector3.zero
		rootPart.Anchored = false
		pcall(function()
			rootPart:SetNetworkOwner(nil)
		end)
		refreshCharacterRoundState(npc, role)
		if not RoundCharacterState.IsSeekerLocked(npc) then
			humanoid:ChangeState(Enum.HumanoidStateType.GettingUp)
		end
		RunService.Heartbeat:Wait()
		if not npc.Parent then
			return
		end
		if not RoundCharacterState.IsSeekerLocked(npc) then
			humanoid:ChangeState(Enum.HumanoidStateType.Running)
		end
		HiderService.Start(npc)
	end)
	return true
end

local function removeManagedNpcs(role: string?, maximumToRemove: number?): number
	local removed = 0
	local limit = maximumToRemove or math.huge
	for _, child in ipairs(npcFolder:GetChildren()) do
		if removed >= limit then
			break
		end
		if child:IsA("Model")
			and child:GetAttribute(MANAGED_NPC_ATTRIBUTE) == true
			and (role == nil or child:GetAttribute("RoundRole") == role) then
			if safelyDestroyManagedNpc(child) then
				removed += 1
			end
		end
	end
	updateRoleCounts()
	return removed
end

local function trimNpcRoleOverflow()
	local hiderCount, seekerCount = getRoleCounts()
	if hiderCount + caughtHiderCount > MAX_HIDERS then
		removeManagedNpcs(ROLE_HIDER, hiderCount + caughtHiderCount - MAX_HIDERS)
	end
	if seekerCount > MAX_SEEKERS then
		removeManagedNpcs(ROLE_SEEKER, seekerCount - MAX_SEEKERS)
	end
	local extraNpcs = getManagedNpcCount() - MAX_ACTIVE_NPCS
	if extraNpcs > 0 then
		removeManagedNpcs(nil, extraNpcs)
	end
end

local function publishAdminNpcPopulation()
	local population = adminNpcPopulation
	roundState:SetAttribute("NpcPopulationOverrideEnabled", population ~= nil)
	roundState:SetAttribute("NpcTargetHiders", if population then population.Hiders else 0)
	roundState:SetAttribute("NpcTargetSeekers", if population then population.Seekers else 0)
end

local function reconcileAdminNpcPopulation(): (number, number, boolean, string?)
	local population = adminNpcPopulation
	if not population then
		return 0, 0, true, nil
	end

	local currentHiders, currentSeekers = getNpcRoleCounts()
	local hidersToAdd = math.max(0, population.Hiders - currentHiders)
	local seekersToAdd = math.max(0, population.Seekers - currentSeekers)
	if hidersToAdd + seekersToAdd > 0 then
		if hidersToAdd > 0 then
			local hiderTemplate = getValidatedNpcTemplate(ROLE_HIDER)
			if not hiderTemplate then
				return 0, 0, false, "INVALID_HIDER_TEMPLATE"
			end
		end
		if seekersToAdd > 0 then
			local seekerTemplate = getValidatedNpcTemplate(ROLE_SEEKER)
			if not seekerTemplate then
				return 0, 0, false, "INVALID_SEEKER_TEMPLATE"
			end
		end
		local phase = roundState:GetAttribute("Phase")
		if phase == PHASE_STARTING
			and not preparingRoundParticipants
			and not startingParticipantsAssigned then
			return 0, 0, false, "PARTICIPANTS_NOT_READY"
		end
		if not activeArenaIsAvailable() or not activeArenaSpawn then
			return 0, 0, false, "NO_ACTIVE_ARENA"
		end
	end

	local added = 0
	local removed = 0
	for _ = currentHiders + 1, population.Hiders do
		local callSucceeded, spawned = pcall(spawnNpc, ROLE_HIDER)
		if not callSucceeded or not spawned then
			if not callSucceeded then
				warn(`RoundManager: exact Hider spawn failed: {tostring(spawned)}`)
			end
			updateRoleCounts()
			return added, removed, false, "SPAWN_FAILED"
		end
		added += 1
	end
	for _ = currentSeekers + 1, population.Seekers do
		local callSucceeded, spawned = pcall(spawnNpc, ROLE_SEEKER)
		if not callSucceeded or not spawned then
			if not callSucceeded then
				warn(`RoundManager: exact Hunter spawn failed: {tostring(spawned)}`)
			end
			updateRoleCounts()
			return added, removed, false, "SPAWN_FAILED"
		end
		added += 1
	end

	-- Remove old-role excess only after every required clone succeeded. If a
	-- clone fails, rollback only has to delete newly added NPCs and never needs
	-- to recreate an NPC that was already present before this request.
	if currentHiders > population.Hiders then
		removed += removeManagedNpcs(ROLE_HIDER, currentHiders - population.Hiders)
	end
	if currentSeekers > population.Seekers then
		removed += removeManagedNpcs(ROLE_SEEKER, currentSeekers - population.Seekers)
	end

	updateRoleCounts()
	local finalHiders, finalSeekers = getNpcRoleCounts()
	if finalHiders ~= population.Hiders or finalSeekers ~= population.Seekers then
		return added, removed, false, "REMOVE_FAILED"
	end
	return added, removed, true, nil
end

local function applyAdminNpcPopulation(
	hiderTarget: number,
	seekerTarget: number
): (boolean, {[string]: any}, string?)
	if hiderTarget % 1 ~= 0
		or seekerTarget % 1 ~= 0
		or hiderTarget < 0
		or seekerTarget < 0
		or hiderTarget + seekerTarget > MAX_ACTIVE_NPCS then
		return false, {}, "INVALID_POPULATION"
	end

	local previous = adminNpcPopulation
	local originalHiders, originalSeekers = getNpcRoleCounts()
	adminNpcPopulation = {
		Hiders = hiderTarget,
		Seekers = seekerTarget,
	}
	publishAdminNpcPopulation()

	local added, removed, completed, problem = reconcileAdminNpcPopulation()
	local deferred = problem == "NO_ACTIVE_ARENA" or problem == "PARTICIPANTS_NOT_READY"
	if not completed and not deferred then
		-- Rebuild the exact pre-request live composition first, then restore the
		-- previous policy. This keeps a rare partial clone failure transactional.
		adminNpcPopulation = {
			Hiders = originalHiders,
			Seekers = originalSeekers,
		}
		local _, _, rollbackCompleted, rollbackProblem = reconcileAdminNpcPopulation()
		adminNpcPopulation = previous
		publishAdminNpcPopulation()
		if not rollbackCompleted then
			warn(`RoundManager: exact NPC rollback failed: {tostring(rollbackProblem)}`)
		end
		return false, {
			Added = added,
			Removed = removed,
			RollbackCompleted = rollbackCompleted,
		}, problem
	end

	return true, {
		Added = added,
		Removed = removed,
		Deferred = deferred,
		HiderTarget = hiderTarget,
		SeekerTarget = seekerTarget,
	}, nil
end

local function fillNpcSlots(): (number, boolean)
	local phase = roundState:GetAttribute("Phase")
	if phase == PHASE_STARTING
		and not preparingRoundParticipants
		and not startingParticipantsAssigned then
		return 0, false
	end
	if adminNpcPopulation then
		local added, _, completed = reconcileAdminNpcPopulation()
		return added, completed
	end

	local before = getManagedNpcCount()
	local spawnFailed = false
	while getManagedNpcCount() < MAX_ACTIVE_NPCS do
		local role = chooseNpcRole()
		if not role then
			break
		end
		if not spawnNpc(role) then
			spawnFailed = true
			break
		end
	end
	updateRoleCounts()
	return getManagedNpcCount() - before, not spawnFailed
end

local function assignRoles(): boolean
	local players = Players:GetPlayers()
	shufflePlayers(players)

	for _, player in ipairs(players) do
		setSpectator(player)
	end

	if BOT_SEEKER_MODE then
		local participantCount = math.min(#players, MAX_HIDERS)
		for index = 1, participantCount do
			setPlayerRole(players[index], ROLE_HIDER, index)
		end
	else
		-- Decide independently whether this round's Seeker is human or an NPC.
		-- Players were shuffled above, so a human Seeker is random as well.
		local playerSeekerCount = if #players > 0
			and random:NextNumber() < PLAYER_SEEKER_CHANCE
			then math.min(#players, MAX_SEEKERS)
			else 0
		local participantCount = math.min(#players, MAX_HIDERS + playerSeekerCount)
		for index = 1, participantCount do
			setPlayerRole(
				players[index],
				if index <= playerSeekerCount then ROLE_SEEKER else ROLE_HIDER,
				index
			)
		end
	end
	local _, populationCompleted = fillNpcSlots()

	updateRoleCounts()
	return populationCompleted
end

local function setPhase(phase: string, durationSeconds: number)
	roundState:SetAttribute("Phase", phase)
	phaseEndsAt = if durationSeconds > 0 then workspace:GetServerTimeNow() + durationSeconds else 0
	roundState:SetAttribute("EndsAt", phaseEndsAt)
	refreshAllCharacterRoundStates()
	HiderEvidenceService.SetPhase(phase)
	HiderService.SetPhase(phase)
	SeekerCaptureService.SetPhase(phase)
end

local function runTimedPhase(phase: string, durationSeconds: number, requirePlayers: boolean): boolean
	setPhase(phase, durationSeconds)

	repeat
		updateRoleCounts()
		if requirePlayers and #Players:GetPlayers() < MINIMUM_PLAYERS then
			return false
		end
		if (phase == PHASE_PREPARING or phase == PHASE_STARTING or phase == PHASE_ROUND)
			and not activeArenaIsAvailable() then
			warn("RoundManager: the active SpawnArena was removed; returning everyone to the hub")
			return false
		end
		if phase == PHASE_ROUND
			and roundState:GetAttribute("HiderCount") == 0
			and pendingHiderReplacements == 0 then
			return true
		end
		if restartRoundRequested
			or endRoundRequested
			or (skipCountdownRequested
				and (phase == PHASE_PREPARING or phase == PHASE_STARTING or phase == PHASE_ENDED)) then
			return true
		end
		task.wait(0.25)
	until workspace:GetServerTimeNow() >= phaseEndsAt

	return true
end

local function runStartingPhase(): boolean
	setPhase(PHASE_STARTING, STARTING_DURATION_SECONDS)
	startingParticipantsAssigned = false
	local participantsAssigned = false

	repeat
		updateRoleCounts()
		if #Players:GetPlayers() < MINIMUM_PLAYERS then
			return false
		end
		if not activeArenaIsAvailable() then
			warn("RoundManager: the active SpawnArena was removed; returning everyone to the hub")
			return false
		end
		if restartRoundRequested or endRoundRequested then
			return true
		end

		local remainingSeconds = phaseEndsAt - workspace:GetServerTimeNow()
		if not participantsAssigned
			and (remainingSeconds <= ARENA_READY_DURATION_SECONDS or skipCountdownRequested) then
			-- Keep everyone in HUB for the first part of the same visible countdown.
			-- Assigning roles relocates players and spawns NPCs on the arena.
			preparingRoundParticipants = true
			local assigned = assignRoles()
			preparingRoundParticipants = false
			if not assigned then
				warn("RoundManager: NPC population assignment failed; cancelling this round start")
				return false
			end
			participantsAssigned = true
			startingParticipantsAssigned = true
		end

		if skipCountdownRequested then
			return true
		end
		task.wait(0.25)
	until workspace:GetServerTimeNow() >= phaseEndsAt

	-- This only matters if an administrator shortened the phase between ticks.
	if not participantsAssigned then
		preparingRoundParticipants = true
		local assigned = assignRoles()
		preparingRoundParticipants = false
		if not assigned then
			warn("RoundManager: NPC population assignment failed; cancelling this round start")
			return false
		end
		startingParticipantsAssigned = true
	end
	return true
end

local function replaceNpcWithPlayer(player: Player): boolean
	local phase = roundState:GetAttribute("Phase")
	if phase ~= PHASE_PREPARING and phase ~= PHASE_STARTING then
		return false
	end
	if adminNpcPopulation then
		-- Keep the exact NPC target untouched while still admitting a late human
		-- participant into an available Hider player slot.
		if not startingParticipantsAssigned then
			return false
		end
		local playerHiders = select(1, getPlayerRoleCounts())
		if playerHiders >= MAX_HIDERS then
			return false
		end
		setPlayerRole(player, ROLE_HIDER)
		updateRoleCounts()
		return true
	end

	for _, child in ipairs(npcFolder:GetChildren()) do
		local role = child:GetAttribute("RoundRole")
		if child:IsA("Model")
			and child:GetAttribute(MANAGED_NPC_ATTRIBUTE) == true
			and (role == ROLE_HIDER or (not BOT_SEEKER_MODE and role == ROLE_SEEKER)) then
			local npcSpawnSlot = child:GetAttribute(ROUND_SPAWN_SLOT_ATTRIBUTE)
			HiderService.Stop(child)
			RoundCharacterState.Clear(child)
			child:Destroy()
			setPlayerRole(
				player,
				role,
				if isValidSpawnSlot(npcSpawnSlot) then npcSpawnSlot else nil
			)
			updateRoleCounts()
			return true
		end
	end

	return false
end

local function setupPlayer(player: Player)
	setHubRespawnLocation(player)
	setSpectator(player)
	player.CharacterAdded:Connect(function(character)
		task.spawn(function()
			character:WaitForChild("HumanoidRootPart", 10)
			character:WaitForChild("Humanoid", 10)
			if player.Character == character then
				applyPlayerRoleScale(player)
				relocatePlayerForCurrentState(player)
				refreshPlayerRoundState(player)
			end
		end)
	end)
	player:GetAttributeChangedSignal("RoundRole"):Connect(function()
		task.defer(function()
			if player.Parent == Players then
				local role = player:GetAttribute("RoundRole")
				if role == ROLE_HIDER or role == ROLE_SEEKER then
					player.Team = if role == ROLE_SEEKER then seekerTeam else hiderTeam
					player.Neutral = false
				else
					player:SetAttribute(ROUND_SPAWN_SLOT_ATTRIBUTE, nil)
					player.Team = nil
					player.Neutral = true
				end
				applyPlayerRoleScale(player)
				relocatePlayerForCurrentState(player)
				refreshPlayerRoundState(player)
			end
		end)
	end)
	task.defer(function()
		if player.Parent == Players then
			replaceNpcWithPlayer(player)
		end
	end)
end

Players.PlayerAdded:Connect(setupPlayer)

Players.PlayerRemoving:Connect(function(player)
	local departingRole = player:GetAttribute("RoundRole")
	local departurePhase = roundState:GetAttribute("Phase")
	local shouldReplace = (departingRole == ROLE_HIDER or departingRole == ROLE_SEEKER)
		and (departurePhase == PHASE_PREPARING
			or departurePhase == PHASE_STARTING
			or departurePhase == PHASE_ROUND)
	if shouldReplace and departingRole == ROLE_HIDER then
		pendingHiderReplacements += 1
	end
	SeekerCaptureService.ClearOwner(player)
	CageService.Remove(player)
	task.spawn(function()
		task.wait()
		local phase = roundState:GetAttribute("Phase")
		if shouldReplace
			and not adminNpcPopulation
			and (phase == PHASE_PREPARING or phase == PHASE_STARTING or phase == PHASE_ROUND) then
			spawnNpc(departingRole)
		end
		if shouldReplace and departingRole == ROLE_HIDER then
			pendingHiderReplacements = math.max(0, pendingHiderReplacements - 1)
		end
		updateRoleCounts()
	end)
end)

for _, player in ipairs(Players:GetPlayers()) do
	setupPlayer(player)
end

local function captureNpcAsCaught(npc: Model)
	if npc.Parent ~= npcFolder
		or npc:GetAttribute(MANAGED_NPC_ATTRIBUTE) ~= true
		or npc:GetAttribute("RoundRole") ~= ROLE_HIDER then
		return
	end
	SeekerCaptureService.ClearOwner(npc)
	CageService.Remove(npc)
	HiderEvidenceService.Clear(npc)
	HiderService.Stop(npc)
	recordCaughtHider()
	npc:SetAttribute(ROUND_CAUGHT_ATTRIBUTE, true)
	npc:SetAttribute(ROUND_SPAWN_SLOT_ATTRIBUTE, nil)
	RoundCharacterState.Clear(npc)
	npc:Destroy()
	updateRoleCounts()
end

SeekerCaptureService.Start({
	CapturePlayer = function(player: Player)
		if roundState:GetAttribute("Phase") == PHASE_ROUND
			and player.Parent == Players
			and player:GetAttribute("RoundRole") == ROLE_HIDER then
			recordCaughtHider()
			setSpectator(player, true)
			updateRoleCounts()
		end
	end,
	CaptureNpc = captureNpcAsCaught,
})

local function validateControlTarget(arguments: {[string]: any}): Player?
	local target = arguments.Target
	return if typeof(target) == "Instance" and target:IsA("Player") and target.Parent == Players
		then target
		else nil
end

local function setPhaseEndNow()
	phaseEndsAt = workspace:GetServerTimeNow()
	roundState:SetAttribute("EndsAt", phaseEndsAt)
end

RoundControl.Register(function(action: string, arguments: {[string]: any}): (boolean, string, any?)
	if action == "GetState" then
		local npcHiders, npcSeekers = getNpcRoleCounts()
		return true, "Round state loaded.", {
			Phase = roundState:GetAttribute("Phase"),
			EndsAt = roundState:GetAttribute("EndsAt"),
			ActiveArena = roundState:GetAttribute("ActiveArena"),
			ActiveArenaSpawn = roundState:GetAttribute("ActiveArenaSpawn"),
			HiderCount = roundState:GetAttribute("HiderCount"),
			CaughtHiderCount = roundState:GetAttribute("CaughtHiderCount"),
			SeekerCount = roundState:GetAttribute("SeekerCount"),
			MaxHiders = MAX_HIDERS,
			MaxSeekers = MAX_SEEKERS,
			BotSeekerMode = BOT_SEEKER_MODE,
			NpcCount = getManagedNpcCount(),
			NpcHiderCount = npcHiders,
			NpcSeekerCount = npcSeekers,
			NpcAIEnabled = HiderService.IsAdminEnabled(),
			NpcPopulationOverrideEnabled = adminNpcPopulation ~= nil,
			NpcTargetHiders = if adminNpcPopulation then adminNpcPopulation.Hiders else 0,
			NpcTargetSeekers = if adminNpcPopulation then adminNpcPopulation.Seekers else 0,
			MaxAdminNpcs = MAX_ACTIVE_NPCS,
		}
	end

	if action == "SetRole" then
		local target = validateControlTarget(arguments)
		local role = arguments.Role
		if not target
			or (role ~= ROLE_HIDER and role ~= ROLE_SEEKER and role ~= ROLE_SPECTATOR) then
			return false, "Invalid player or role.", nil
		end
		if BOT_SEEKER_MODE and role == ROLE_SEEKER then
			return false, "Player Hunters are disabled while NPC Hunter mode is active.", nil
		end
		local phase = roundState:GetAttribute("Phase")
		if phase == PHASE_STARTING and not startingParticipantsAssigned then
			return false, "Player roles can be changed after the arena participants are assigned.", nil
		end
		local currentRole = target:GetAttribute("RoundRole")
		if currentRole == role then
			return true, `{target.Name} is already a {role}.`, nil
		end
		if currentRole ~= role and role ~= ROLE_SPECTATOR then
			if adminNpcPopulation then
				local playerHiders, playerSeekers = getPlayerRoleCounts()
				local playerRoleIsFull = (role == ROLE_HIDER and playerHiders >= MAX_HIDERS)
					or (role == ROLE_SEEKER and playerSeekers >= MAX_SEEKERS)
				if playerRoleIsFull then
					return false, `The player {role} slots are already full.`, nil
				end
			else
				local hiderCount, seekerCount = getRoleCounts()
				local destinationIsFull = (role == ROLE_HIDER and hiderCount + caughtHiderCount >= MAX_HIDERS)
					or (role == ROLE_SEEKER and seekerCount >= MAX_SEEKERS)
				if destinationIsFull and removeManagedNpcs(role, 1) == 0 then
					return false, `The {role} player slots are already full.`, nil
				end
			end
		end
		if role == ROLE_SPECTATOR then
			setSpectator(target)
		else
			if target:GetAttribute(ROUND_CAUGHT_ATTRIBUTE) == true then
				caughtHiderCount = math.max(0, caughtHiderCount - 1)
				roundState:SetAttribute("CaughtHiderCount", caughtHiderCount)
			end
			setPlayerRole(target, role)
		end
		if not adminNpcPopulation then
			trimNpcRoleOverflow()
			local phase = roundState:GetAttribute("Phase")
			if phase == PHASE_ROUND or getManagedNpcCount() > 0 then
				fillNpcSlots()
			end
		end
		updateRoleCounts()
		return true, `{target.Name} is now a {role}.`, nil
	end

	if action == "NormalizeMovement" then
		local target = validateControlTarget(arguments)
		if not target then
			return false, "The target player is no longer in this server.", nil
		end
		applyPlayerRoleScale(target)
		refreshPlayerRoundState(target)
		local targetWalkSpeed = if target:GetAttribute("RoundRole") == ROLE_SEEKER
			then SEEKER_WALK_SPEED
			else WALK_SPEED
		return true, `{target.Name}'s movement was normalized to {targetWalkSpeed}.`, nil
	end

	if action == "StartRoundNow" then
		local phase = roundState:GetAttribute("Phase")
		if phase == PHASE_ROUND then
			return false, "The round is already running.", nil
		end
		skipCountdownRequested = true
		endRoundRequested = false
		if phase == PHASE_PREPARING or phase == PHASE_STARTING or phase == PHASE_ENDED then
			setPhaseEndNow()
		end
		return true, "The active countdown will be skipped.", nil
	end

	if action == "EndRound" then
		local phase = roundState:GetAttribute("Phase")
		if phase ~= PHASE_STARTING and phase ~= PHASE_ROUND then
			return false, "There is no active round to end.", nil
		end
		endRoundRequested = true
		skipCountdownRequested = false
		setPhaseEndNow()
		return true, "The round will end now.", nil
	end

	if action == "RestartRound" then
		if roundState:GetAttribute("Phase") == PHASE_WAITING then
			return false, "The server is already waiting for the next round.", nil
		end
		restartRoundRequested = true
		endRoundRequested = false
		skipCountdownRequested = false
		setPhaseEndNow()
		return true, "The round will restart with a new countdown.", nil
	end

	if action == "SetRemainingTime" then
		local seconds = arguments.Seconds
		local phase = roundState:GetAttribute("Phase")
		if type(seconds) ~= "number" or seconds % 1 ~= 0 or seconds < 1 or seconds > 600 then
			return false, "Time must be a whole number from 1 to 600.", nil
		end
		if phase ~= PHASE_PREPARING
			and phase ~= PHASE_STARTING
			and phase ~= PHASE_ROUND
			and phase ~= PHASE_ENDED then
			return false, "The current phase does not have a timer.", nil
		end
		phaseEndsAt = workspace:GetServerTimeNow() + seconds
		roundState:SetAttribute("EndsAt", phaseEndsAt)
		return true, `The current phase now has {seconds} second(s) remaining.`, nil
	end

	if action == "SetNpcPopulation" then
		local hiderTarget = arguments.HiderCount
		local seekerTarget = arguments.SeekerCount
		if type(hiderTarget) ~= "number"
			or type(seekerTarget) ~= "number"
			or hiderTarget % 1 ~= 0
			or seekerTarget % 1 ~= 0
			or hiderTarget < 0
			or seekerTarget < 0
			or hiderTarget + seekerTarget > MAX_ACTIVE_NPCS then
			return false, `NPC counts must be whole numbers with a combined maximum of {MAX_ACTIVE_NPCS}.`, nil
		end
		local applied, data, problem = applyAdminNpcPopulation(hiderTarget, seekerTarget)
		if not applied then
			local message = if problem == "INVALID_HIDER_TEMPLATE"
				then "The Hider NPC template is invalid."
				elseif problem == "INVALID_SEEKER_TEMPLATE"
					then "ServerStorage.HunterCharacter is invalid."
					else "The exact NPC population could not be applied."
			return false, message, data
		end
		local message = if data.Deferred == true
			then `Saved exact NPC population: {hiderTarget} Hider(s), {seekerTarget} Hunter(s). It will apply when the arena is ready.`
			else `Exact NPC population applied: {hiderTarget} Hider(s), {seekerTarget} Hunter(s).`
		return true, message, data
	end

	if action == "ClearNpcPopulationOverride" then
		if not adminNpcPopulation then
			return true, "NPC population is already automatic.", nil
		end
		adminNpcPopulation = nil
		publishAdminNpcPopulation()
		trimNpcRoleOverflow()
		local phase = roundState:GetAttribute("Phase")
		local added = 0
		local completed = true
		if phase == PHASE_PREPARING or phase == PHASE_STARTING or phase == PHASE_ROUND then
			added, completed = fillNpcSlots()
		else
			updateRoleCounts()
		end
		if not completed then
			return true, "Automatic population was restored; some NPC slots could not be filled yet.", {
				Added = added,
				Completed = false,
			}
		end
		return true, "Automatic NPC population restored.", {
			Added = added,
			Completed = true,
		}
	end

	if action == "FillNpcSlots" then
		local phase = roundState:GetAttribute("Phase")
		if phase == PHASE_STARTING and not startingParticipantsAssigned then
			return false, "NPCs will be assigned during the final arena countdown.", nil
		end
		local added, completed = fillNpcSlots()
		if not completed then
			return false, "NPC filling requires an active SpawnArena and valid NPC character templates.", nil
		end
		local message = if adminNpcPopulation
			then `Reapplied the exact NPC population; added {added} NPC(s).`
			else `Filled all available NPC slots; added {added} NPC(s).`
		return true, message, { Added = added }
	end

	if action == "ClearNpcs" then
		if adminNpcPopulation then
			local applied, data = applyAdminNpcPopulation(0, 0)
			if not applied then
				return false, "The exact NPC population could not be cleared.", data
			end
			return true, "Cleared all managed NPCs and set the exact targets to zero.", data
		end
		local phase = roundState:GetAttribute("Phase")
		local preserveBotSeeker = BOT_SEEKER_MODE
			and (phase == PHASE_PREPARING or phase == PHASE_STARTING or phase == PHASE_ROUND)
		local removed = if preserveBotSeeker
			then removeManagedNpcs(ROLE_HIDER)
			else getManagedNpcCount()
		if not preserveBotSeeker then
			clearNpcs()
		end
		updateRoleCounts()
		local message = if preserveBotSeeker
			then `Removed {removed} managed Hider NPC(s); kept the bot Seeker.`
			else `Removed {removed} managed NPC(s).`
		return true, message, { Removed = removed }
	end

	if action == "SpawnNpc" then
		local role = arguments.Role
		if role ~= ROLE_HIDER and role ~= ROLE_SEEKER then
			return false, "Invalid NPC role.", nil
		end
		if adminNpcPopulation then
			local hiderTarget = adminNpcPopulation.Hiders + (if role == ROLE_HIDER then 1 else 0)
			local seekerTarget = adminNpcPopulation.Seekers + (if role == ROLE_SEEKER then 1 else 0)
			local applied, data, problem = applyAdminNpcPopulation(hiderTarget, seekerTarget)
			if not applied then
				local message = if problem == "INVALID_HIDER_TEMPLATE"
					then "The Hider NPC template is invalid."
					elseif problem == "INVALID_SEEKER_TEMPLATE"
						then "ServerStorage.HunterCharacter is invalid."
						else `The exact population allows at most {MAX_ACTIVE_NPCS} managed NPCs.`
				return false, message, data
			end
			local message = if data.Deferred == true
				then `Queued one NPC {role}; it will spawn when the arena is ready.`
				else `Added one NPC {role} to the exact population.`
			return true, message, data
		end
		local phase = roundState:GetAttribute("Phase")
		if phase == PHASE_STARTING and not startingParticipantsAssigned then
			return false, "NPCs can be spawned after the arena participants are assigned.", nil
		end
		local hiderCount, seekerCount = getRoleCounts()
		local roleIsFull = (role == ROLE_HIDER and hiderCount + caughtHiderCount >= MAX_HIDERS)
			or (role == ROLE_SEEKER and seekerCount >= MAX_SEEKERS)
		if getManagedNpcCount() >= MAX_ACTIVE_NPCS or roleIsFull then
			return false, "That NPC slot is already full.", nil
		end
		if not spawnNpc(role) then
			return false, "The NPC could not be spawned.", nil
		end
		updateRoleCounts()
		return true, `Spawned one NPC {role}.`, nil
	end

	if action == "RemoveNpcs" then
		local role = arguments.Role
		if role ~= ROLE_HIDER and role ~= ROLE_SEEKER then
			return false, "Invalid NPC role.", nil
		end
		if adminNpcPopulation then
			local hiderTarget = if role == ROLE_HIDER then 0 else adminNpcPopulation.Hiders
			local seekerTarget = if role == ROLE_SEEKER then 0 else adminNpcPopulation.Seekers
			local applied, data = applyAdminNpcPopulation(hiderTarget, seekerTarget)
			if not applied then
				return false, `NPC {role}s could not be removed.`, data
			end
			return true, `Removed all NPC {role}s from the exact population.`, data
		end
		local phase = roundState:GetAttribute("Phase")
		if BOT_SEEKER_MODE
			and role == ROLE_SEEKER
			and (phase == PHASE_PREPARING or phase == PHASE_STARTING or phase == PHASE_ROUND) then
			return false, "The bot Seeker is required while the round is active.", nil
		end
		local removed = removeManagedNpcs(role)
		return true, `Removed {removed} NPC {role}(s).`, { Removed = removed }
	end

	if action == "SetNpcAIEnabled" then
		local enabled = arguments.Enabled
		if type(enabled) ~= "boolean" then
			return false, "Invalid NPC AI state.", nil
		end
		HiderService.SetAdminEnabled(enabled)
		roundState:SetAttribute("NpcAIEnabled", enabled)
		local message = if enabled then "NPC AI resumed." else "NPC AI paused."
		return true, message, nil
	end

	return false, "Unknown round-control action.", nil
end)

while true do
	restartRoundRequested = false
	endRoundRequested = false
	resetRoles()
	setPhase(PHASE_WAITING, 0)
	while #Players:GetPlayers() < MINIMUM_PLAYERS do
		task.wait(0.5)
	end

	while #Players:GetPlayers() >= MINIMUM_PLAYERS do
		if getHubSpawn() and selectActiveArena() then
			break
		end
		task.wait(1)
	end
	if #Players:GetPlayers() < MINIMUM_PLAYERS then
		continue
	end

	if not runStartingPhase() then
		continue
	end
	if restartRoundRequested then
		continue
	end
	skipCountdownRequested = false

	if not endRoundRequested then
		if not runTimedPhase(PHASE_ROUND, ROUND_DURATION_SECONDS, true) then
			continue
		end
		if restartRoundRequested then
			continue
		end
	end

	endRoundRequested = false
	setPhase(PHASE_ENDED, 0)
	resetRoles(true)
end
