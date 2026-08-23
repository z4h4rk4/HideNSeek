--!strict

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local SeekerSearchConfig = require(ReplicatedStorage:WaitForChild("SeekerSearchConfig"))

local TELEPORT_CONTAINER_NAME = "Teleport Pads"
local PAD_ONE_NAME = "Pad1"
local PAD_TWO_NAME = "Pad2"
local TELEPORT_REMOTE_NAME = "ArenaTeleported"
local TELEPORT_COOLDOWN_SECONDS = 10
local DESTINATION_CLEARANCE = 0.5
local TELEPORT_EXIT_MARGIN = 1.25
local COOLDOWN_ATTRIBUTE = "ArenaTeleportCooldownUntil"
local MANAGED_NPC_ATTRIBUTE = "ManagedRoundNPC"
local ROLE_ATTRIBUTE = "RoundRole"
local ROLE_SEEKER = "Seeker"

export type TeleportLink = {
	Entry: BasePart,
	Exit: BasePart,
}

type PairRecord = {
	connections: {RBXScriptConnection},
	padOne: BasePart,
	padTwo: BasePart,
}

local ArenaTeleportService = {
	COOLDOWN_ATTRIBUTE = COOLDOWN_ATTRIBUTE,
}
local registeredPairs: {[Instance]: PairRecord} = {}
local started = false
local teleportRemote: RemoteEvent? = nil
local teleportExitLocks: {[Model]: BasePart} = {}
local teleportExitLockConnections: {[Model]: RBXScriptConnection} = {}

local function getOrCreateRemote(): RemoteEvent
	local existing = ReplicatedStorage:FindFirstChild(TELEPORT_REMOTE_NAME)
	if existing then
		if not existing:IsA("RemoteEvent") then
			error(`ReplicatedStorage.{TELEPORT_REMOTE_NAME} must be a RemoteEvent`)
		end
		return existing
	end

	local remote = Instance.new("RemoteEvent")
	remote.Name = TELEPORT_REMOTE_NAME
	remote.Parent = ReplicatedStorage
	return remote
end

local function getTeleportCharacter(hit: BasePart): Model?
	local current: Instance? = hit.Parent
	while current and current ~= workspace do
		if current:IsA("Model") then
			local isPlayerCharacter = Players:GetPlayerFromCharacter(current) ~= nil
			local isNpcSeeker = current:GetAttribute(MANAGED_NPC_ATTRIBUTE) == true
				and current:GetAttribute(ROLE_ATTRIBUTE) == ROLE_SEEKER
			if isPlayerCharacter or isNpcSeeker then
				return current
			end
		end
		current = current.Parent
	end
	return nil
end

local function clearTeleportExitLock(character: Model)
	teleportExitLocks[character] = nil
	local connection = teleportExitLockConnections[character]
	if connection then
		connection:Disconnect()
		teleportExitLockConnections[character] = nil
	end
end

local function characterIsOverPad(character: Model, pad: BasePart): boolean
	local rootPart = character:FindFirstChild("HumanoidRootPart")
	if not rootPart or not rootPart:IsA("BasePart") or not pad:IsDescendantOf(workspace) then
		return false
	end

	local localPosition = pad.CFrame:PointToObjectSpace(rootPart.Position)
	local halfX = pad.Size.X * 0.5 + TELEPORT_EXIT_MARGIN
	local halfZ = pad.Size.Z * 0.5 + TELEPORT_EXIT_MARGIN
	return math.abs(localPosition.X) <= halfX and math.abs(localPosition.Z) <= halfZ
end

local function isWaitingForTeleportExit(character: Model): boolean
	local lockedPad = teleportExitLocks[character]
	if not lockedPad or not lockedPad.Parent or not character.Parent then
		clearTeleportExitLock(character)
		return false
	end
	if not characterIsOverPad(character, lockedPad) then
		clearTeleportExitLock(character)
		return false
	end
	return true
end

local function lockTeleportUntilExit(character: Model, destination: BasePart)
	teleportExitLocks[character] = destination
	if not teleportExitLockConnections[character] then
		teleportExitLockConnections[character] = character.Destroying:Connect(function()
			clearTeleportExitLock(character)
		end)
	end
end

function ArenaTeleportService.TeleportCharacter(
	character: Model,
	destination: BasePart,
	source: BasePart?
): boolean
	if character:GetAttribute(SeekerSearchConfig.CAGED_ATTRIBUTE) == true then
		return false
	end
	if source and isWaitingForTeleportExit(character) then
		return false
	end

	local now = workspace:GetServerTimeNow()
	local cooldownValue = character:GetAttribute(COOLDOWN_ATTRIBUTE)
	local cooldownUntil = if type(cooldownValue) == "number" then cooldownValue else 0
	if now < cooldownUntil then
		return false
	end

	local humanoid = character:FindFirstChildOfClass("Humanoid")
	local rootPart = character:FindFirstChild("HumanoidRootPart")
	if not humanoid
		or humanoid.Health <= 0
		or not rootPart
		or not rootPart:IsA("BasePart")
		or not destination:IsDescendantOf(workspace) then
		return false
	end

	local destinationTop = destination.Position.Y + destination.Size.Y * 0.5
	local rootHeight = math.max(0, humanoid.HipHeight) + rootPart.Size.Y * 0.5
	local targetPosition = Vector3.new(
		destination.Position.X,
		destinationTop + rootHeight + DESTINATION_CLEARANCE,
		destination.Position.Z
	)
	local horizontalLook = Vector3.new(rootPart.CFrame.LookVector.X, 0, rootPart.CFrame.LookVector.Z)
	if horizontalLook.Magnitude < 0.001 then
		horizontalLook = Vector3.new(0, 0, -1)
	else
		horizontalLook = horizontalLook.Unit
	end

	character:SetAttribute(COOLDOWN_ATTRIBUTE, now + TELEPORT_COOLDOWN_SECONDS)
	rootPart.CFrame = CFrame.lookAt(targetPosition, targetPosition + horizontalLook)
	lockTeleportUntilExit(character, destination)
	rootPart.AssemblyLinearVelocity = Vector3.zero
	rootPart.AssemblyAngularVelocity = Vector3.zero
	humanoid.Sit = false
	humanoid.PlatformStand = false
	humanoid:ChangeState(Enum.HumanoidStateType.Running)

	local player = Players:GetPlayerFromCharacter(character)
	if player and teleportRemote then
		teleportRemote:FireClient(player)
	end
	return true
end

local function unregisterPair(container: Instance)
	local record = registeredPairs[container]
	if not record then
		return
	end
	for _, connection in ipairs(record.connections) do
		connection:Disconnect()
	end
	registeredPairs[container] = nil
end

local function connectTeleportPad(source: BasePart, destination: BasePart, connections: {RBXScriptConnection})
	source.CanTouch = true
	table.insert(connections, source.Touched:Connect(function(hit)
		local character = getTeleportCharacter(hit)
		if character then
			ArenaTeleportService.TeleportCharacter(character, destination, source)
		end
	end))
end

local function registerPair(container: Instance): boolean
	if registeredPairs[container]
		or container.Name ~= TELEPORT_CONTAINER_NAME
		or not (container:IsA("Folder") or container:IsA("Model")) then
		return false
	end

	local padOne = container:FindFirstChild(PAD_ONE_NAME)
	local padTwo = container:FindFirstChild(PAD_TWO_NAME)
	if not padOne or not padOne:IsA("BasePart") or not padTwo or not padTwo:IsA("BasePart") then
		return false
	end

	local connections: {RBXScriptConnection} = {}
	registeredPairs[container] = {
		connections = connections,
		padOne = padOne,
		padTwo = padTwo,
	}
	connectTeleportPad(padOne, padTwo, connections)
	connectTeleportPad(padTwo, padOne, connections)

	local function unregister()
		unregisterPair(container)
	end
	table.insert(connections, container.Destroying:Connect(unregister))
	table.insert(connections, padOne.Destroying:Connect(unregister))
	table.insert(connections, padTwo.Destroying:Connect(unregister))
	return true
end

local function findTeleportContainer(instance: Instance): Instance?
	local current: Instance? = instance
	while current and current ~= workspace do
		if current.Name == TELEPORT_CONTAINER_NAME
			and (current:IsA("Folder") or current:IsA("Model")) then
			return current
		end
		current = current.Parent
	end
	return nil
end

function ArenaTeleportService.GetLinks(): {TeleportLink}
	ArenaTeleportService.Start()
	local links: {TeleportLink} = {}
	for _, record in pairs(registeredPairs) do
		if record.padOne:IsDescendantOf(workspace) and record.padTwo:IsDescendantOf(workspace) then
			table.insert(links, { Entry = record.padOne, Exit = record.padTwo })
			table.insert(links, { Entry = record.padTwo, Exit = record.padOne })
		end
	end
	return links
end

function ArenaTeleportService.Start()
	if started then
		return
	end
	started = true
	teleportRemote = getOrCreateRemote()

	for _, object in ipairs(workspace:GetDescendants()) do
		if object.Name == TELEPORT_CONTAINER_NAME then
			registerPair(object)
		end
	end
	workspace.DescendantAdded:Connect(function(descendant)
		local container = findTeleportContainer(descendant)
		if container then
			registerPair(container)
		end
	end)

	local pairCount = 0
	for _ in pairs(registeredPairs) do
		pairCount += 1
	end
	print(`[ArenaTeleport] Connected {pairCount} teleport pair(s)`)
end

return ArenaTeleportService
