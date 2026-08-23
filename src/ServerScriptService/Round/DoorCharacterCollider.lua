--!strict

local PhysicsService = game:GetService("PhysicsService")

local RoundConfig = require(script.Parent:WaitForChild("RoundConfig"))

local DOOR_COLLISION_GROUP = "Doors"
local CHARACTER_COLLISION_GROUP = "Characters"
local NPC_COLLISION_GROUP = "RoundNPCs"
local HUB_COLLISION_GROUP = "HubCharacters"
local PROXY_COLLISION_GROUP = "DoorPushers"
local SEARCH_RAYCAST_COLLISION_GROUP = "SeekerSearchRaycasts"
local PROXY_NAME = "_RoundDoorPusher"
local PROXY_ATTRIBUTE = "RoundDoorPusher"
local VERTICAL_CYLINDER_ROTATION = CFrame.Angles(0, 0, math.pi * 0.5)

type Record = {
	bodyCollisionGroup: string,
	descendantAddedConnection: RBXScriptConnection,
	destroyingConnection: RBXScriptConnection,
}

local records: {[Model]: Record} = {}

local DoorCharacterCollider = {
	DOOR_COLLISION_GROUP = DOOR_COLLISION_GROUP,
	CHARACTER_COLLISION_GROUP = CHARACTER_COLLISION_GROUP,
	NPC_COLLISION_GROUP = NPC_COLLISION_GROUP,
	HUB_COLLISION_GROUP = HUB_COLLISION_GROUP,
	PROXY_COLLISION_GROUP = PROXY_COLLISION_GROUP,
	SEARCH_RAYCAST_COLLISION_GROUP = SEARCH_RAYCAST_COLLISION_GROUP,
}

local function registerCollisionGroup(name: string)
	if PhysicsService:IsCollisionGroupRegistered(name) then
		return
	end
	PhysicsService:RegisterCollisionGroup(name)
end

function DoorCharacterCollider.Configure()
	registerCollisionGroup(DOOR_COLLISION_GROUP)
	registerCollisionGroup(CHARACTER_COLLISION_GROUP)
	registerCollisionGroup(NPC_COLLISION_GROUP)
	registerCollisionGroup(HUB_COLLISION_GROUP)
	registerCollisionGroup(PROXY_COLLISION_GROUP)
	registerCollisionGroup(SEARCH_RAYCAST_COLLISION_GROUP)

	-- Doors and their character proxy only interact with one another. The
	-- visible animated rig keeps its normal collision with the map, while arms,
	-- legs, accessories, and scaled body parts can no longer catch on a leaf.
	for _, group in PhysicsService:GetRegisteredCollisionGroups() do
		PhysicsService:CollisionGroupSetCollidable(DOOR_COLLISION_GROUP, group.name, false)
		PhysicsService:CollisionGroupSetCollidable(PROXY_COLLISION_GROUP, group.name, false)
		PhysicsService:CollisionGroupSetCollidable(
			SEARCH_RAYCAST_COLLISION_GROUP,
			group.name,
			true
		)
	end
	PhysicsService:CollisionGroupSetCollidable(
		DOOR_COLLISION_GROUP,
		PROXY_COLLISION_GROUP,
		true
	)
	-- Search rays still see a closed gate even though animated body parts no
	-- longer collide with it physically.
	PhysicsService:CollisionGroupSetCollidable(
		DOOR_COLLISION_GROUP,
		SEARCH_RAYCAST_COLLISION_GROUP,
		true
	)
	PhysicsService:CollisionGroupSetCollidable(
		PROXY_COLLISION_GROUP,
		SEARCH_RAYCAST_COLLISION_GROUP,
		false
	)

	PhysicsService:CollisionGroupSetCollidable(CHARACTER_COLLISION_GROUP, "Default", true)
	PhysicsService:CollisionGroupSetCollidable(NPC_COLLISION_GROUP, "Default", true)
	PhysicsService:CollisionGroupSetCollidable(HUB_COLLISION_GROUP, "Default", true)
	PhysicsService:CollisionGroupSetCollidable(
		NPC_COLLISION_GROUP,
		CHARACTER_COLLISION_GROUP,
		false
	)
	PhysicsService:CollisionGroupSetCollidable(NPC_COLLISION_GROUP, NPC_COLLISION_GROUP, false)
	PhysicsService:CollisionGroupSetCollidable(HUB_COLLISION_GROUP, HUB_COLLISION_GROUP, false)
	PhysicsService:CollisionGroupSetCollidable(HUB_COLLISION_GROUP, CHARACTER_COLLISION_GROUP, false)
	PhysicsService:CollisionGroupSetCollidable(HUB_COLLISION_GROUP, NPC_COLLISION_GROUP, false)
end

function DoorCharacterCollider.IsProxy(instance: Instance): boolean
	return instance:IsA("BasePart") and instance:GetAttribute(PROXY_ATTRIBUTE) == true
end

local function setCollisionGroup(instance: Instance, bodyCollisionGroup: string)
	if not instance:IsA("BasePart") then
		return
	end
	instance.CollisionGroup = if DoorCharacterCollider.IsProxy(instance)
		then PROXY_COLLISION_GROUP
		else bodyCollisionGroup
end

local function clearRecord(character: Model)
	local record = records[character]
	if not record then
		return
	end
	records[character] = nil
	record.descendantAddedConnection:Disconnect()
	record.destroyingConnection:Disconnect()
end

local function ensureRecord(character: Model, bodyCollisionGroup: string)
	local record = records[character]
	if record then
		record.bodyCollisionGroup = bodyCollisionGroup
		return
	end

	local newRecord: Record
	newRecord = {
		bodyCollisionGroup = bodyCollisionGroup,
		descendantAddedConnection = character.DescendantAdded:Connect(function(descendant)
			if records[character] == newRecord then
				setCollisionGroup(descendant, newRecord.bodyCollisionGroup)
			end
		end),
		destroyingConnection = character.Destroying:Connect(function()
			if records[character] == newRecord then
				clearRecord(character)
			end
		end),
	}
	records[character] = newRecord
end

local function findProxy(character: Model): BasePart?
	local selected: BasePart? = nil
	for _, descendant in character:GetDescendants() do
		if DoorCharacterCollider.IsProxy(descendant) then
			if selected then
				descendant:Destroy()
			else
				selected = descendant :: BasePart
			end
		end
	end
	return selected
end

local function configureProxy(proxy: Part, character: Model, rootPart: BasePart)
	local diameter = math.max(
		RoundConfig.DOOR_COLLIDER.MIN_DIAMETER,
		math.max(rootPart.Size.X, rootPart.Size.Z)
			* RoundConfig.DOOR_COLLIDER.DIAMETER_MULTIPLIER
	)
	local height = math.max(
		RoundConfig.DOOR_COLLIDER.MIN_HEIGHT,
		rootPart.Size.Y * RoundConfig.DOOR_COLLIDER.HEIGHT_MULTIPLIER
	)

	proxy.Name = PROXY_NAME
	proxy:SetAttribute(PROXY_ATTRIBUTE, true)
	proxy.Shape = Enum.PartType.Cylinder
	proxy.Size = Vector3.new(height, diameter, diameter)
	proxy.Anchored = false
	proxy.Massless = true
	proxy.CanCollide = true
	-- Keep touch-based gate scripts working: the proxy remains a direct child
	-- of the character, just like HumanoidRootPart.
	proxy.CanTouch = true
	proxy.CanQuery = false
	proxy.CastShadow = false
	proxy.Transparency = 1
	proxy.RootPriority = -127
	proxy.CollisionGroup = PROXY_COLLISION_GROUP
	proxy.CustomPhysicalProperties = PhysicalProperties.new(0.01, 0, 0, 100, 100)

	for _, child in proxy:GetChildren() do
		if child:IsA("WeldConstraint") then
			child:Destroy()
		end
	end

	proxy.Parent = character
	proxy.CFrame = rootPart.CFrame * VERTICAL_CYLINDER_ROTATION
	local weld = Instance.new("WeldConstraint")
	weld.Name = "RootWeld"
	weld.Part0 = rootPart
	weld.Part1 = proxy
	weld.Parent = proxy
end

function DoorCharacterCollider.Refresh(
	character: Model,
	bodyCollisionGroup: string
): BasePart?
	DoorCharacterCollider.Configure()
	if bodyCollisionGroup ~= CHARACTER_COLLISION_GROUP
		and bodyCollisionGroup ~= NPC_COLLISION_GROUP
		and bodyCollisionGroup ~= HUB_COLLISION_GROUP then
		error(`Unsupported character collision group: {bodyCollisionGroup}`)
	end
	local rootPart = character:FindFirstChild("HumanoidRootPart")
	if not rootPart or not rootPart:IsA("BasePart") then
		return nil
	end
	ensureRecord(character, bodyCollisionGroup)
	for _, descendant in character:GetDescendants() do
		setCollisionGroup(descendant, bodyCollisionGroup)
	end

	local existing = findProxy(character)
	local proxy: Part
	if existing and existing:IsA("Part") then
		proxy = existing
	else
		if existing then
			existing:Destroy()
		end
		proxy = Instance.new("Part")
		proxy:SetAttribute(PROXY_ATTRIBUTE, true)
		proxy.Parent = character
	end
	configureProxy(proxy, character, rootPart)
	return proxy
end

function DoorCharacterCollider.Destroy(character: Model)
	clearRecord(character)
	for _, descendant in character:GetDescendants() do
		if DoorCharacterCollider.IsProxy(descendant) then
			descendant:Destroy()
		end
	end
end

return DoorCharacterCollider
