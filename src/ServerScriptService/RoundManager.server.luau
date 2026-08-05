--!strict

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local StarterPlayer = game:GetService("StarterPlayer")
local Teams = game:GetService("Teams")
local Workspace = game:GetService("Workspace")

local roundModules = script.Parent:WaitForChild("Round")
local RoundConfig = require(roundModules:WaitForChild("RoundConfig"))
local DoorCharacterCollider = require(roundModules:WaitForChild("DoorCharacterCollider"))
local SeekerSearchConfig = require(ReplicatedStorage:WaitForChild("SeekerSearchConfig"))
local HiderService = require(roundModules:WaitForChild("HiderService"))
local RoundCharacterState = require(roundModules:WaitForChild("RoundCharacterState"))
local RoundControl = require(roundModules:WaitForChild("RoundControl"))
local SeekerCaptureService = require(roundModules:WaitForChild("SeekerCaptureService"))

local STATE_NAME = "RoundState"
local HIDER_TEAM_NAME = "Hiders"
local SEEKER_TEAM_NAME = "Seekers"
local NPC_FOLDER_NAME = "RoundNPCs"
local STARTER_CHARACTER_NAME = "StarterCharacter"
local HUB_CONTAINER_NAME = "HUB"
local HUB_SPAWN_NAME = "SpawnHUB"
local ARENA_SPAWN_NAME = "SpawnArena"

local STARTING_DURATION_SECONDS = RoundConfig.STARTING_DURATION_SECONDS
local ROUND_DURATION_SECONDS = RoundConfig.ROUND_DURATION_SECONDS
local ROUND_END_DURATION_SECONDS = RoundConfig.ROUND_END_DURATION_SECONDS
local MINIMUM_PLAYERS = RoundConfig.MINIMUM_PLAYERS
local MAX_HIDERS = RoundConfig.MAX_HIDERS
local MAX_SEEKERS = RoundConfig.MAX_SEEKERS
local WALK_SPEED = RoundConfig.WALK_SPEED
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
local PHASE_STARTING = RoundConfig.PHASE_STARTING
local PHASE_ROUND = RoundConfig.PHASE_ROUND
local PHASE_ENDED = RoundConfig.PHASE_ENDED

local random = Random.new()
local phaseEndsAt = 0
local skipCountdownRequested = false
local endRoundRequested = false
local restartRoundRequested = false
local preparingRoundParticipants = false
local pendingHiderReplacements = 0
local caughtHiderCount = 0
local activeArena: Instance? = nil
local activeArenaSpawn: BasePart? = nil
local previousArena: Instance? = nil

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
roundState:SetAttribute("HiderCount", 0)
roundState:SetAttribute("CaughtHiderCount", 0)
roundState:SetAttribute("SeekerCount", 0)
roundState:SetAttribute("Phase", PHASE_WAITING)
roundState:SetAttribute("EndsAt", 0)
roundState:SetAttribute("NpcAIEnabled", true)
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
local missingTemplateWarned = false
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

local function clearNpcs()
	for _, child in ipairs(npcFolder:GetChildren()) do
		if child:GetAttribute(MANAGED_NPC_ATTRIBUTE) == true then
			SeekerCaptureService.ClearOwner(child)
			if child:IsA("Model") then
				HiderService.Stop(child)
				RoundCharacterState.Clear(child)
			end
			child:Destroy()
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
	local maximumSlots = MAX_HIDERS + MAX_SEEKERS
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

	local targetScale = if role == ROLE_SEEKER then baseScale * SEEKER_SCALE_MULTIPLIER else baseScale
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
		humanoid.WalkSpeed = WALK_SPEED
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
	SeekerCaptureService.CancelAll()
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

local function getManagedNpcCount(): number
	local count = 0
	for _, child in ipairs(npcFolder:GetChildren()) do
		if child:IsA("Model") and child:GetAttribute(MANAGED_NPC_ATTRIBUTE) == true then
			count += 1
		end
	end
	return count
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
	caughtHiderCount = math.min(MAX_HIDERS, caughtHiderCount + 1)
	roundState:SetAttribute("CaughtHiderCount", caughtHiderCount)
end

local function shufflePlayers(players: {Player})
	for index = #players, 2, -1 do
		local swapIndex = random:NextInteger(1, index)
		players[index], players[swapIndex] = players[swapIndex], players[index]
	end
end

local function shuffleRoles(roles: {string})
	for index = #roles, 2, -1 do
		local swapIndex = random:NextInteger(1, index)
		roles[index], roles[swapIndex] = roles[swapIndex], roles[index]
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

local function spawnNpc(role: string): boolean
	local arenaSpawn = activeArenaSpawn
	if not activeArenaIsAvailable() or not arenaSpawn then
		return false
	end

	local template = StarterPlayer:FindFirstChild(STARTER_CHARACTER_NAME)
	if not template or not template:IsA("Model") then
		if not missingTemplateWarned then
			missingTemplateWarned = true
			warn(`RoundManager: StarterPlayer.{STARTER_CHARACTER_NAME} must be a Model to fill empty slots`)
		end
		return false
	end

	missingTemplateWarned = false
	npcSerial += 1
	local spawnSlot = getAvailableRoundSpawnSlot(nil, nil)
	local npc = template:Clone()
	npc.Name = `NPC_{role}_{npcSerial}`
	npc:SetAttribute(MANAGED_NPC_ATTRIBUTE, true)
	npc:SetAttribute("RoundRole", role)
	npc:SetAttribute(ROUND_SPAWN_SLOT_ATTRIBUTE, spawnSlot)
	local humanoid = npc:FindFirstChildOfClass("Humanoid")
	local rootPart = npc:FindFirstChild("HumanoidRootPart")
	if not humanoid or not rootPart or not rootPart:IsA("BasePart") then
		warn(`RoundManager: StarterPlayer.{STARTER_CHARACTER_NAME} needs Humanoid and HumanoidRootPart`)
		npc:Destroy()
		return false
	end
	rootPart.Anchored = true
	npc.Parent = npcFolder
	applyCharacterRoleScale(npc, role)

	humanoid.DisplayName = if role == ROLE_SEEKER then "NPC Seeker" else "NPC Hider"
	humanoid.WalkSpeed = WALK_SPEED
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

	rootPart.CFrame = getSpawnRootCFrame(arenaSpawn, spawnSlot, humanoid, rootPart)
	applyNpcColor(npc, npcSerial)
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

local function fillNpcSlots(): (number, boolean)
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
			SeekerCaptureService.ClearOwner(child)
			HiderService.Stop(child)
			RoundCharacterState.Clear(child)
			child:Destroy()
			removed += 1
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

local function assignRoles()
	local players = Players:GetPlayers()
	shufflePlayers(players)

	for _, player in ipairs(players) do
		setSpectator(player)
	end

	local roleSlots: {string} = {}
	for _ = 1, MAX_HIDERS do
		table.insert(roleSlots, ROLE_HIDER)
	end
	for _ = 1, MAX_SEEKERS do
		table.insert(roleSlots, ROLE_SEEKER)
	end
	shuffleRoles(roleSlots)

	local participantCount = math.min(#players, #roleSlots)
	for index = 1, participantCount do
		setPlayerRole(players[index], roleSlots[index], index)
	end
	fillNpcSlots()

	updateRoleCounts()
end

local function setPhase(phase: string, durationSeconds: number)
	roundState:SetAttribute("Phase", phase)
	phaseEndsAt = if durationSeconds > 0 then workspace:GetServerTimeNow() + durationSeconds else 0
	roundState:SetAttribute("EndsAt", phaseEndsAt)
	refreshAllCharacterRoundStates()
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
		if (phase == PHASE_STARTING or phase == PHASE_ROUND) and not activeArenaIsAvailable() then
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
			or (skipCountdownRequested and (phase == PHASE_STARTING or phase == PHASE_ENDED)) then
			return true
		end
		task.wait(0.25)
	until workspace:GetServerTimeNow() >= phaseEndsAt

	return true
end

local function replaceNpcWithPlayer(player: Player): boolean
	if roundState:GetAttribute("Phase") ~= PHASE_STARTING then
		return false
	end

	for _, child in ipairs(npcFolder:GetChildren()) do
		local role = child:GetAttribute("RoundRole")
		if child:IsA("Model")
			and child:GetAttribute(MANAGED_NPC_ATTRIBUTE) == true
			and (role == ROLE_HIDER or role == ROLE_SEEKER) then
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
				SeekerCaptureService.Reapply(player)
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
	local wasCaged = SeekerCaptureService.IsCaged(player)
	local departurePhase = roundState:GetAttribute("Phase")
	local shouldReplace = not wasCaged
		and (departingRole == ROLE_HIDER or departingRole == ROLE_SEEKER)
		and (departurePhase == PHASE_STARTING or departurePhase == PHASE_ROUND)
	if shouldReplace and departingRole == ROLE_HIDER then
		pendingHiderReplacements += 1
	elseif wasCaged and departingRole == ROLE_HIDER and departurePhase == PHASE_ROUND then
		recordCaughtHider()
	end
	SeekerCaptureService.ClearOwner(player)
	task.spawn(function()
		task.wait()
		local phase = roundState:GetAttribute("Phase")
		if shouldReplace and (phase == PHASE_STARTING or phase == PHASE_ROUND) then
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

local function captureNpcAsCaught(npc: Model)
	if npc.Parent ~= npcFolder
		or npc:GetAttribute(MANAGED_NPC_ATTRIBUTE) ~= true
		or npc:GetAttribute("RoundRole") ~= ROLE_HIDER then
		return
	end

	SeekerCaptureService.ClearOwner(npc)
	HiderService.Stop(npc)
	recordCaughtHider()
	npc:SetAttribute(ROUND_SPAWN_SLOT_ATTRIBUTE, nil)
	RoundCharacterState.Clear(npc)
	npc:Destroy()
	updateRoleCounts()
end

SeekerCaptureService.Start({
	CapturePlayer = function(player: Player)
		if player.Parent == Players and player:GetAttribute("RoundRole") == ROLE_HIDER then
			recordCaughtHider()
			setSpectator(player, true)
			updateRoleCounts()
		end
	end,
	CaptureNpc = captureNpcAsCaught,
	SetNpcCaged = function(npc: Model, caged: boolean)
		HiderService.SetCaged(npc, caged)
	end,
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
			NpcCount = getManagedNpcCount(),
			NpcHiderCount = npcHiders,
			NpcSeekerCount = npcSeekers,
			NpcAIEnabled = HiderService.IsAdminEnabled(),
		}
	end

	if action == "SetRole" then
		local target = validateControlTarget(arguments)
		local role = arguments.Role
		if not target
			or (role ~= ROLE_HIDER and role ~= ROLE_SEEKER and role ~= ROLE_SPECTATOR) then
			return false, "Invalid player or role.", nil
		end
		local currentRole = target:GetAttribute("RoundRole")
		if currentRole ~= role and role ~= ROLE_SPECTATOR then
			local hiderCount, seekerCount = getRoleCounts()
			local destinationIsFull = (role == ROLE_HIDER and hiderCount + caughtHiderCount >= MAX_HIDERS)
				or (role == ROLE_SEEKER and seekerCount >= MAX_SEEKERS)
			if destinationIsFull and removeManagedNpcs(role, 1) == 0 then
				return false, `The {role} player slots are already full.`, nil
			end
		end
		if role == ROLE_SPECTATOR then
			setSpectator(target)
		else
			setPlayerRole(target, role)
		end
		trimNpcRoleOverflow()
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
		return true, `{target.Name}'s movement was normalized to {WALK_SPEED}.`, nil
	end

	if action == "StartRoundNow" then
		local phase = roundState:GetAttribute("Phase")
		if phase == PHASE_ROUND then
			return false, "The round is already running.", nil
		end
		skipCountdownRequested = true
		endRoundRequested = false
		if phase == PHASE_STARTING or phase == PHASE_ENDED then
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
		if phase ~= PHASE_STARTING and phase ~= PHASE_ROUND and phase ~= PHASE_ENDED then
			return false, "The current phase does not have a timer.", nil
		end
		phaseEndsAt = workspace:GetServerTimeNow() + seconds
		roundState:SetAttribute("EndsAt", phaseEndsAt)
		return true, `The current phase now has {seconds} second(s) remaining.`, nil
	end

	if action == "FillNpcSlots" then
		local added, completed = fillNpcSlots()
		if not completed then
			return false, "NPC filling requires an active SpawnArena and a valid StarterCharacter.", nil
		end
		return true, `Filled all available NPC slots; added {added} NPC(s).`, { Added = added }
	end

	if action == "ClearNpcs" then
		local removed = getManagedNpcCount()
		clearNpcs()
		updateRoleCounts()
		return true, `Removed {removed} managed NPC(s).`, { Removed = removed }
	end

	if action == "SpawnNpc" then
		local role = arguments.Role
		if role ~= ROLE_HIDER and role ~= ROLE_SEEKER then
			return false, "Invalid NPC role.", nil
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

	preparingRoundParticipants = true
	assignRoles()
	preparingRoundParticipants = false
	if skipCountdownRequested then
		skipCountdownRequested = false
	else
		if not runTimedPhase(PHASE_STARTING, STARTING_DURATION_SECONDS, true) then
			continue
		end
		if restartRoundRequested then
			continue
		end
		skipCountdownRequested = false
	end

	if not endRoundRequested then
		if not runTimedPhase(PHASE_ROUND, ROUND_DURATION_SECONDS, true) then
			continue
		end
		if restartRoundRequested then
			continue
		end
	end

	endRoundRequested = false
	resetRoles(true)
	runTimedPhase(PHASE_ENDED, ROUND_END_DURATION_SECONDS, false)
end
