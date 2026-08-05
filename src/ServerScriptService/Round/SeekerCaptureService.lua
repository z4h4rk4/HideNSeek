--!strict

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Config = require(ReplicatedStorage:WaitForChild("SeekerSearchConfig"))
local SearchGeometry = require(ReplicatedStorage:WaitForChild("SeekerSearchGeometry"))
local CageService = require(script.Parent:WaitForChild("CageService"))
local HiderMapGeometry = require(script.Parent:WaitForChild("HiderMapGeometry"))

local NPC_FOLDER_NAME = "RoundNPCs"
local MANAGED_NPC_ATTRIBUTE = "ManagedRoundNPC"
local ROUND_ROLE_ATTRIBUTE = "RoundRole"
local ROLE_HIDER = "Hider"
local ROLE_SEEKER = "Seeker"
local PHASE_ROUND = "Round"
local CHARACTER_COLLISION_GROUP = "Characters"
local WALLS_CONTAINER_NAME = "Walls"

export type Callbacks = {
	CapturePlayer: (Player) -> (),
	CaptureNpc: (Model) -> (),
	SetNpcCaged: (Model, boolean) -> (),
}

type Actor = {
	owner: Instance,
	model: Model,
	humanoid: Humanoid,
	rootPart: BasePart,
	role: string,
}

type CagedRecord = {
	owner: Instance,
	deadline: number,
	rescueSeconds: number,
	lastRescueSampleAt: number?,
	lastModel: Model?,
	walkSpeed: number,
	autoRotate: boolean,
}

type ArenaGeometry = HiderMapGeometry.ArenaGeometry

local SeekerCaptureService = {}
local callbacks: Callbacks? = nil
local currentPhase = "Waiting"
local activeArena: Instance? = nil
local heartbeatConnection: RBXScriptConnection? = nil
local scanAccumulator = 0
local lastErrorWarningAt = 0
local missingArenaGeometryWarned = false
local cagedRecords: {[Instance]: CagedRecord} = {}
local immunityUntil: {[Instance]: number} = {}

local function getNpcFolder(): Folder?
	local folder = Workspace:FindFirstChild(NPC_FOLDER_NAME)
	return if folder and folder:IsA("Folder") then folder else nil
end

local function getOwnerRole(owner: Instance): any
	if owner:IsA("Player") or owner:IsA("Model") then
		return owner:GetAttribute(ROUND_ROLE_ATTRIBUTE)
	end
	return nil
end

local function ownerIsActiveHider(owner: Instance): boolean
	if owner:IsA("Player") then
		return owner.Parent == Players and owner:GetAttribute(ROUND_ROLE_ATTRIBUTE) == ROLE_HIDER
	end
	return owner:IsA("Model")
		and owner.Parent ~= nil
		and owner:GetAttribute(MANAGED_NPC_ATTRIBUTE) == true
		and owner:GetAttribute(ROUND_ROLE_ATTRIBUTE) == ROLE_HIDER
end

local function makeActor(owner: Instance, model: Model, role: string): Actor?
	local humanoid = model:FindFirstChildOfClass("Humanoid")
	local rootPart = model:FindFirstChild("HumanoidRootPart")
	if not model.Parent
		or not humanoid
		or humanoid.Health <= 0
		or not rootPart
		or not rootPart:IsA("BasePart") then
		return nil
	end
	return {
		owner = owner,
		model = model,
		humanoid = humanoid,
		rootPart = rootPart,
		role = role,
	}
end

local function getActor(owner: Instance): Actor?
	local role = getOwnerRole(owner)
	if role ~= ROLE_HIDER and role ~= ROLE_SEEKER then
		return nil
	end
	if owner:IsA("Player") then
		local character = owner.Character
		return if owner.Parent == Players and character then makeActor(owner, character, role) else nil
	end
	if owner:IsA("Model")
		and owner:GetAttribute(MANAGED_NPC_ATTRIBUTE) == true then
		return makeActor(owner, owner, role)
	end
	return nil
end

local function actorIsInActiveArena(actor: Actor, geometry: ArenaGeometry): boolean
	local position = actor.rootPart.Position
	for _, floor in ipairs(geometry.floors) do
		local localPosition = floor.cframe:PointToObjectSpace(Vector3.new(
			position.X,
			floor.cframe.Position.Y,
			position.Z
		))
		if math.abs(localPosition.X) <= floor.halfX + 0.25
			and math.abs(localPosition.Z) <= floor.halfZ + 0.25
			and math.abs(position.Y - floor.part.Position.Y) <= 15 then
			return true
		end
	end
	return false
end

local function collectActors(geometry: ArenaGeometry): ({Actor}, {Actor})
	local seekers: {Actor} = {}
	local hiders: {Actor} = {}
	for _, player in ipairs(Players:GetPlayers()) do
		local actor = getActor(player)
		if actor and actorIsInActiveArena(actor, geometry) then
			if actor.role == ROLE_SEEKER then
				table.insert(seekers, actor)
			else
				table.insert(hiders, actor)
			end
		end
	end

	local npcFolder = getNpcFolder()
	if npcFolder then
		for _, child in ipairs(npcFolder:GetChildren()) do
			if child:IsA("Model") then
				local actor = getActor(child)
				if actor and actorIsInActiveArena(actor, geometry) then
					if actor.role == ROLE_SEEKER then
						table.insert(seekers, actor)
					else
						table.insert(hiders, actor)
					end
				end
			end
		end
	end
	return seekers, hiders
end

local function getActiveGeometry(arena: Instance): ArenaGeometry?
	for _, geometry in ipairs(HiderMapGeometry.GetAll()) do
		if geometry.arena == arena then
			return geometry
		end
	end
	return nil
end

local function makeLineOfSightParameters(): RaycastParams
	local excluded: {Instance} = { CageService.GetFolder() }
	local npcFolder = getNpcFolder()
	if npcFolder then
		table.insert(excluded, npcFolder)
	end
	for _, player in ipairs(Players:GetPlayers()) do
		if player.Character then
			table.insert(excluded, player.Character)
		end
	end

	local parameters = RaycastParams.new()
	parameters.FilterType = Enum.RaycastFilterType.Exclude
	parameters.FilterDescendantsInstances = excluded
	parameters.IgnoreWater = true
	parameters.RespectCanCollide = true
	parameters.CollisionGroup = CHARACTER_COLLISION_GROUP
	return parameters
end

local function makeWallLineOfSightParameters(geometry: ArenaGeometry): RaycastParams?
	local wallParts: {Instance} = {}
	local wallsContainer = geometry.map:FindFirstChild(WALLS_CONTAINER_NAME)
	if wallsContainer then
		if wallsContainer:IsA("BasePart") then
			table.insert(wallParts, wallsContainer)
		end
		for _, descendant in ipairs(wallsContainer:GetDescendants()) do
			if descendant:IsA("BasePart") then
				table.insert(wallParts, descendant)
			end
		end
	end
	if #wallParts == 0 then
		return nil
	end

	local parameters = RaycastParams.new()
	parameters.FilterType = Enum.RaycastFilterType.Include
	parameters.FilterDescendantsInstances = wallParts
	parameters.IgnoreWater = true
	parameters.RespectCanCollide = false
	parameters.CollisionGroup = CHARACTER_COLLISION_GROUP
	return parameters
end

local function horizontalDistance(first: Vector3, second: Vector3): number
	return Vector2.new(first.X - second.X, first.Z - second.Z).Magnitude
end

local function actorsAreClose(first: Actor, second: Actor, radius: number): boolean
	local firstPosition = first.rootPart.Position
	local secondPosition = second.rootPart.Position
	return math.abs(firstPosition.Y - secondPosition.Y) <= Config.MAX_VERTICAL_DIFFERENCE
		and horizontalDistance(firstPosition, secondPosition) <= radius
end

local function hiderIsInsideSearchField(seeker: Actor, hider: Actor): boolean
	local seekerPosition = seeker.rootPart.Position
	local hiderPosition = hider.rootPart.Position
	if math.abs(seekerPosition.Y - hiderPosition.Y) > Config.MAX_VERTICAL_DIFFERENCE then
		return false
	end

	local direction = hiderPosition - seekerPosition
	local radius = SearchGeometry.GetRadius(seeker.rootPart.CFrame.LookVector, direction)
	return horizontalDistance(seekerPosition, hiderPosition) <= radius
end

local function hasLineOfSight(
	first: Actor,
	second: Actor,
	parameters: RaycastParams,
	wallParameters: RaycastParams?
): boolean
	local firstFloorY = first.rootPart.Position.Y
		- math.max(0, first.humanoid.HipHeight)
		- first.rootPart.Size.Y * 0.5
	local secondFloorY = second.rootPart.Position.Y
		- math.max(0, second.humanoid.HipHeight)
		- second.rootPart.Size.Y * 0.5
	local origin = Vector3.new(
		first.rootPart.Position.X,
		firstFloorY + Config.LINE_OF_SIGHT_HEIGHT,
		first.rootPart.Position.Z
	)
	local destination = Vector3.new(
		second.rootPart.Position.X,
		secondFloorY + Config.LINE_OF_SIGHT_HEIGHT,
		second.rootPart.Position.Z
	)
	local direction = destination - origin
	if direction.Magnitude <= 0.05 then
		return true
	end
	if Workspace:Raycast(origin, direction, parameters) then
		return false
	end
	return not wallParameters or Workspace:Raycast(origin, direction, wallParameters) == nil
end

local function setCaptureAttributes(instance: Instance, caged: boolean, deadline: number?, progress: number?)
	if not instance.Parent then
		return
	end
	instance:SetAttribute(Config.CAGED_ATTRIBUTE, if caged then true else nil)
	instance:SetAttribute(Config.CAGED_UNTIL_ATTRIBUTE, if caged then deadline else nil)
	instance:SetAttribute(Config.RESCUE_PROGRESS_ATTRIBUTE, if caged then progress or 0 else nil)
end

local function releaseModel(
	model: Model,
	owner: Instance,
	walkSpeed: number?,
	autoRotate: boolean?
)
	setCaptureAttributes(model, false, nil, nil)
	local humanoid = model:FindFirstChildOfClass("Humanoid")
	local rootPart = model:FindFirstChild("HumanoidRootPart")
	if rootPart and rootPart:IsA("BasePart") then
		rootPart.Anchored = false
		rootPart.AssemblyLinearVelocity = Vector3.zero
		rootPart.AssemblyAngularVelocity = Vector3.zero
		pcall(function()
			if owner:IsA("Player") then
				rootPart:SetNetworkOwnershipAuto()
			else
				rootPart:SetNetworkOwner(nil)
			end
		end)
	end
	if humanoid then
		humanoid.WalkSpeed = walkSpeed or Config.NORMAL_WALK_SPEED
		humanoid.AutoRotate = if type(autoRotate) == "boolean" then autoRotate else true
		humanoid.Sit = false
		humanoid.PlatformStand = false
		if humanoid.Health > 0 then
			humanoid:ChangeState(Enum.HumanoidStateType.Running)
		end
	end
end

local function applyCagedState(record: CagedRecord, actor: Actor): boolean
	if record.lastModel and record.lastModel ~= actor.model then
		CageService.Remove(record.owner)
		releaseModel(record.lastModel, record.owner, record.walkSpeed, record.autoRotate)
	end
	record.lastModel = actor.model

	-- Stop the actor completely before reading its position for the cage. Player
	-- characters are normally client-owned, so also take temporary server ownership
	-- before anchoring to prevent a late movement packet from shifting the root.
	actor.humanoid.WalkSpeed = 0
	actor.humanoid.AutoRotate = false
	actor.humanoid.Sit = false
	actor.humanoid.PlatformStand = false
	actor.humanoid:Move(Vector3.zero, false)
	actor.rootPart.AssemblyLinearVelocity = Vector3.zero
	actor.rootPart.AssemblyAngularVelocity = Vector3.zero
	pcall(function()
		actor.rootPart:SetNetworkOwner(nil)
	end)
	actor.rootPart.Anchored = true
	actor.rootPart.AssemblyLinearVelocity = Vector3.zero
	actor.rootPart.AssemblyAngularVelocity = Vector3.zero

	if not CageService.Attach(record.owner, actor.model, actor.humanoid, actor.rootPart) then
		releaseModel(actor.model, record.owner, record.walkSpeed, record.autoRotate)
		setCaptureAttributes(record.owner, false, nil, nil)
		return false
	end
	setCaptureAttributes(record.owner, true, record.deadline, record.rescueSeconds / Config.RESCUE_HOLD_SECONDS)
	setCaptureAttributes(actor.model, true, record.deadline, record.rescueSeconds / Config.RESCUE_HOLD_SECONDS)

	local serviceCallbacks = callbacks
	if actor.owner:IsA("Model") and serviceCallbacks then
		serviceCallbacks.SetNpcCaged(actor.owner, true)
	end
	return true
end

local function clearCagedRecord(owner: Instance, grantImmunity: boolean)
	local record = cagedRecords[owner]
	local hadCagedState = record ~= nil or owner:GetAttribute(Config.CAGED_ATTRIBUTE) == true
	if record then
		cagedRecords[owner] = nil
		CageService.Remove(owner)
		if record.lastModel then
			releaseModel(record.lastModel, owner, record.walkSpeed, record.autoRotate)
		end
	else
		CageService.Remove(owner)
	end
	if owner:IsA("Player") and owner.Character and (not record or owner.Character ~= record.lastModel) then
		if hadCagedState or owner.Character:GetAttribute(Config.CAGED_ATTRIBUTE) == true then
			releaseModel(
				owner.Character,
				owner,
				if record then record.walkSpeed else nil,
				if record then record.autoRotate else nil
			)
		end
	elseif owner:IsA("Model") and (not record or owner ~= record.lastModel) then
		if hadCagedState or owner:GetAttribute(Config.CAGED_ATTRIBUTE) == true then
			releaseModel(
				owner,
				owner,
				if record then record.walkSpeed else nil,
				if record then record.autoRotate else nil
			)
		end
	end
	setCaptureAttributes(owner, false, nil, nil)

	local serviceCallbacks = callbacks
	if owner:IsA("Model") and serviceCallbacks and hadCagedState then
		serviceCallbacks.SetNpcCaged(owner, false)
	end
	if grantImmunity then
		immunityUntil[owner] = Workspace:GetServerTimeNow() + Config.POST_RESCUE_IMMUNITY_SECONDS
	else
		immunityUntil[owner] = nil
	end
end

local function cageActor(actor: Actor, now: number)
	if cagedRecords[actor.owner] or (immunityUntil[actor.owner] or 0) > now then
		return
	end
	local record: CagedRecord = {
		owner = actor.owner,
		deadline = now + Config.CAGE_DURATION_SECONDS,
		rescueSeconds = 0,
		lastRescueSampleAt = nil,
		lastModel = actor.model,
		walkSpeed = actor.humanoid.WalkSpeed,
		autoRotate = actor.humanoid.AutoRotate,
	}
	if applyCagedState(record, actor) then
		cagedRecords[actor.owner] = record
	end
end

local function detectHiders(
	seekers: {Actor},
	hiders: {Actor},
	parameters: RaycastParams,
	wallParameters: RaycastParams?,
	now: number
)
	for _, hider in ipairs(hiders) do
		if not cagedRecords[hider.owner] and (immunityUntil[hider.owner] or 0) <= now then
			for _, seeker in ipairs(seekers) do
				if hiderIsInsideSearchField(seeker, hider)
					and hasLineOfSight(seeker, hider, parameters, wallParameters) then
					cageActor(hider, now)
					break
				end
			end
		end
	end
end

local function updateRescues(
	hiders: {Actor},
	parameters: RaycastParams,
	wallParameters: RaycastParams?,
	now: number
)
	local owners: {Instance} = {}
	for owner in pairs(cagedRecords) do
		table.insert(owners, owner)
	end

	for _, owner in ipairs(owners) do
		local record = cagedRecords[owner]
		local cagedActor = if record then getActor(owner) else nil
		if record and cagedActor and now < record.deadline then
			local rescuerFound = false
			for _, possibleRescuer in ipairs(hiders) do
				if possibleRescuer.owner ~= owner
					and not cagedRecords[possibleRescuer.owner]
					and actorsAreClose(possibleRescuer, cagedActor, Config.RESCUE_RADIUS)
					and hasLineOfSight(possibleRescuer, cagedActor, parameters, wallParameters) then
					rescuerFound = true
					break
				end
			end

			if rescuerFound then
				local lastSampleAt = record.lastRescueSampleAt
				if lastSampleAt then
					local sampleGap = now - lastSampleAt
					if sampleGap <= Config.SERVER_SCAN_INTERVAL * 2.5 then
						record.rescueSeconds = math.min(
							Config.RESCUE_HOLD_SECONDS,
							record.rescueSeconds + math.min(sampleGap, Config.SERVER_SCAN_INTERVAL * 1.5)
						)
					else
						-- A long server hitch is not proof that the rescuer stayed nearby.
						record.rescueSeconds = 0
					end
				end
				record.lastRescueSampleAt = now
			else
				record.rescueSeconds = 0
				record.lastRescueSampleAt = nil
			end
			local cageApplied = applyCagedState(record, cagedActor)
			if not cageApplied then
				clearCagedRecord(owner, false)
			elseif record.rescueSeconds >= Config.RESCUE_HOLD_SECONDS then
				clearCagedRecord(owner, true)
			end
		elseif record and not ownerIsActiveHider(owner) then
			clearCagedRecord(owner, false)
		end
	end
end

local function captureExpiredHiders(now: number)
	local expiredOwners: {Instance} = {}
	for owner, record in pairs(cagedRecords) do
		if now >= record.deadline then
			table.insert(expiredOwners, owner)
		end
	end

	for _, owner in ipairs(expiredOwners) do
		if cagedRecords[owner] then
			local shouldCapture = ownerIsActiveHider(owner)
			clearCagedRecord(owner, false)
			local serviceCallbacks = callbacks
			if shouldCapture and serviceCallbacks then
				if owner:IsA("Player") then
					serviceCallbacks.CapturePlayer(owner)
				elseif owner:IsA("Model") then
					serviceCallbacks.CaptureNpc(owner)
				end
			end
		end
	end
end

local function cleanupInvalidState(now: number)
	local invalidOwners: {Instance} = {}
	for owner in pairs(cagedRecords) do
		if not ownerIsActiveHider(owner) then
			table.insert(invalidOwners, owner)
		end
	end
	for _, owner in ipairs(invalidOwners) do
		clearCagedRecord(owner, false)
	end
	for owner, deadline in pairs(immunityUntil) do
		if deadline <= now or not ownerIsActiveHider(owner) then
			immunityUntil[owner] = nil
		end
	end
end

local function scan()
	local now = Workspace:GetServerTimeNow()
	cleanupInvalidState(now)
	captureExpiredHiders(now)

	local arena = activeArena
	if currentPhase ~= PHASE_ROUND or not arena or not arena.Parent then
		return
	end
	local geometry = getActiveGeometry(arena)
	if not geometry then
		if not missingArenaGeometryWarned then
			missingArenaGeometryWarned = true
			warn(`SeekerCaptureService: {arena:GetFullName()} needs Map/Floor geometry`)
		end
		return
	end
	missingArenaGeometryWarned = false
	local seekers, hiders = collectActors(geometry)
	local parameters = makeLineOfSightParameters()
	local wallParameters = makeWallLineOfSightParameters(geometry)
	detectHiders(seekers, hiders, parameters, wallParameters, now)
	updateRescues(hiders, parameters, wallParameters, now)
end

function SeekerCaptureService.Start(serviceCallbacks: Callbacks)
	if heartbeatConnection then
		error("SeekerCaptureService.Start may only be called once")
	end
	callbacks = serviceCallbacks
	heartbeatConnection = RunService.Heartbeat:Connect(function(deltaTime)
		scanAccumulator += deltaTime
		if scanAccumulator < Config.SERVER_SCAN_INTERVAL then
			return
		end
		scanAccumulator = 0
		local succeeded, message = xpcall(function()
			scan()
		end, debug.traceback)
		if not succeeded then
			local now = os.clock()
			if now - lastErrorWarningAt >= 2 then
				lastErrorWarningAt = now
				warn(`SeekerCaptureService scan failed:\n{message}`)
			end
		end
	end)
end

function SeekerCaptureService.SetPhase(phase: string)
	currentPhase = phase
	if phase ~= PHASE_ROUND then
		SeekerCaptureService.CancelAll()
	end
end

function SeekerCaptureService.SetArena(arena: Instance?)
	activeArena = arena
	missingArenaGeometryWarned = false
	if not arena then
		SeekerCaptureService.CancelAll()
	end
end

function SeekerCaptureService.ClearOwner(owner: Instance)
	clearCagedRecord(owner, false)
end

function SeekerCaptureService.Reapply(owner: Instance)
	local record = cagedRecords[owner]
	local actor = if record then getActor(owner) else nil
	if record and actor then
		if not applyCagedState(record, actor) then
			clearCagedRecord(owner, false)
		end
	end
end

function SeekerCaptureService.CancelAll()
	local owners: {Instance} = {}
	for owner in pairs(cagedRecords) do
		table.insert(owners, owner)
	end
	for _, owner in ipairs(owners) do
		clearCagedRecord(owner, false)
	end
	CageService.RemoveAll()
	table.clear(immunityUntil)
end

function SeekerCaptureService.IsCaged(owner: Instance): boolean
	return cagedRecords[owner] ~= nil
end

return SeekerCaptureService
