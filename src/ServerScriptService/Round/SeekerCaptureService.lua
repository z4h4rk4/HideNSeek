--!strict

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Config = require(ReplicatedStorage:WaitForChild("SeekerSearchConfig"))
local SearchGeometry = require(ReplicatedStorage:WaitForChild("SeekerSearchGeometry"))
local HiderMapGeometry = require(script.Parent:WaitForChild("HiderMapGeometry"))

local NPC_FOLDER_NAME = "RoundNPCs"
local MANAGED_NPC_ATTRIBUTE = "ManagedRoundNPC"
local ROUND_ROLE_ATTRIBUTE = "RoundRole"
local ROLE_HIDER = "Hider"
local ROLE_SEEKER = "Seeker"
local PHASE_ROUND = "Round"
local WALLS_CONTAINER_NAME = "Walls"

export type Callbacks = {
	CapturePlayer: (Player) -> (),
	CaptureNpc: (Model) -> (),
}

type Actor = {
	owner: Instance,
	model: Model,
	humanoid: Humanoid,
	rootPart: BasePart,
	role: string,
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
local caughtOwners: {[Instance]: boolean} = {}

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
	if owner:IsA("Model") and owner:GetAttribute(MANAGED_NPC_ATTRIBUTE) == true then
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
			local roleActors = if actor.role == ROLE_SEEKER then seekers else hiders
			table.insert(roleActors, actor)
		end
	end

	local npcFolder = getNpcFolder()
	if npcFolder then
		for _, child in ipairs(npcFolder:GetChildren()) do
			if child:IsA("Model") then
				local actor = getActor(child)
				if actor and actorIsInActiveArena(actor, geometry) then
					local roleActors = if actor.role == ROLE_SEEKER then seekers else hiders
					table.insert(roleActors, actor)
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
	local excluded: {Instance} = {}
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
	parameters.CollisionGroup = Config.RAYCAST_COLLISION_GROUP
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
	parameters.CollisionGroup = Config.RAYCAST_COLLISION_GROUP
	return parameters
end

local function actorsAreInCaptureArea(seeker: Actor, hider: Actor): boolean
	local offset = hider.rootPart.Position - seeker.rootPart.Position
	local horizontalDistance = Vector2.new(offset.X, offset.Z).Magnitude
	local visibleRadius = SearchGeometry.GetRadius(seeker.rootPart.CFrame.LookVector, offset)
	return math.abs(offset.Y) <= Config.MAX_VERTICAL_DIFFERENCE
		and horizontalDistance <= visibleRadius
end

local function lineOfSightPosition(actor: Actor): Vector3
	if actor.humanoid.PlatformStand then
		-- A knocked-down root is already close to the floor. Subtracting HipHeight
		-- again would put the capture ray below the map and make the Hider immune.
		return actor.rootPart.Position + Vector3.yAxis * 0.5
	end
	local floorY = actor.rootPart.Position.Y
		- math.max(0, actor.humanoid.HipHeight)
		- actor.rootPart.Size.Y * 0.5
	return Vector3.new(
		actor.rootPart.Position.X,
		floorY + Config.LINE_OF_SIGHT_HEIGHT,
		actor.rootPart.Position.Z
	)
end

local function hasLineOfSight(
	first: Actor,
	second: Actor,
	parameters: RaycastParams,
	wallParameters: RaycastParams?
): boolean
	local origin = lineOfSightPosition(first)
	local direction = lineOfSightPosition(second) - origin
	if direction.Magnitude <= 0.05 then
		return true
	end
	if Workspace:Raycast(origin, direction, parameters) then
		return false
	end
	return not wallParameters or Workspace:Raycast(origin, direction, wallParameters) == nil
end

local function captureHider(hider: Actor)
	if caughtOwners[hider.owner] then
		return
	end
	caughtOwners[hider.owner] = true
	local serviceCallbacks = callbacks
	if not serviceCallbacks then
		return
	end
	if hider.owner:IsA("Player") then
		serviceCallbacks.CapturePlayer(hider.owner)
	elseif hider.owner:IsA("Model") then
		serviceCallbacks.CaptureNpc(hider.owner)
	end
end

local function detectCaptureAreas(
	seekers: {Actor},
	hiders: {Actor},
	parameters: RaycastParams,
	wallParameters: RaycastParams?
)
	for _, hider in ipairs(hiders) do
		if caughtOwners[hider.owner] then
			continue
		end
		for _, seeker in ipairs(seekers) do
			-- Only the managed NPC Seeker can eliminate Hiders. Player Seeker roles
			-- are not part of the normal round configuration.
			if not seeker.owner:IsA("Model")
				or seeker.owner:GetAttribute(MANAGED_NPC_ATTRIBUTE) ~= true then
				continue
			end
			if actorsAreInCaptureArea(seeker, hider)
				and hasLineOfSight(seeker, hider, parameters, wallParameters) then
				captureHider(hider)
				break
			end
		end
	end
end

local function scan()
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
	detectCaptureAreas(
		seekers,
		hiders,
		makeLineOfSightParameters(),
		makeWallLineOfSightParameters(geometry)
	)
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
		local succeeded, message = xpcall(scan, debug.traceback)
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
	caughtOwners[owner] = nil
end

function SeekerCaptureService.CancelAll()
	table.clear(caughtOwners)
end

return SeekerCaptureService
