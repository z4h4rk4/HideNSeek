local Players = game:GetService("Players")
local PhysicsService = game:GetService("PhysicsService")

local DOOR_GROUP = "Doors"
local CHARACTER_GROUP = "Characters"
local NPC_GROUP = "RoundNPCs"

-- =========================================================
-- СОЗДАЁМ ГРУППЫ
-- =========================================================

pcall(function()
	PhysicsService:RegisterCollisionGroup(DOOR_GROUP)
end)

pcall(function()
	PhysicsService:RegisterCollisionGroup(CHARACTER_GROUP)
end)

pcall(function()
	PhysicsService:RegisterCollisionGroup(NPC_GROUP)
end)

-- =========================================================
-- DOORS ИГНОРИРУЕТ ВСЁ
-- =========================================================

for _, group in ipairs(PhysicsService:GetRegisteredCollisionGroups()) do
	PhysicsService:CollisionGroupSetCollidable(DOOR_GROUP, group.name, false)
end

-- =========================================================
-- DOORS PHYSICALLY INTERACT WITH PLAYERS AND ROUND NPCS
-- =========================================================

PhysicsService:CollisionGroupSetCollidable(DOOR_GROUP, CHARACTER_GROUP, true)
PhysicsService:CollisionGroupSetCollidable(DOOR_GROUP, NPC_GROUP, true)

-- =========================================================
-- ПЕРСОНАЖИ СОХРАНЯЮТ ОБЫЧНУЮ КОЛЛИЗИЮ С МИРОМ
-- =========================================================

PhysicsService:CollisionGroupSetCollidable(CHARACTER_GROUP, "Default", true)
PhysicsService:CollisionGroupSetCollidable(NPC_GROUP, "Default", true)
PhysicsService:CollisionGroupSetCollidable(NPC_GROUP, CHARACTER_GROUP, false)
PhysicsService:CollisionGroupSetCollidable(NPC_GROUP, NPC_GROUP, false)

-- =========================================================
-- НАЗНАЧЕНИЕ CHARACTER COLLISION GROUP
-- =========================================================

local function setupCharacter(character: Model)
	local function setupPart(object: Instance)
		if object:IsA("BasePart") then
			object.CollisionGroup = CHARACTER_GROUP
		end
	end

	-- Уже существующие части персонажа
	for _, object in ipairs(character:GetDescendants()) do
		setupPart(object)
	end

	-- Аксессуары / новые части, которые появятся позже
	character.DescendantAdded:Connect(setupPart)
end

-- =========================================================
-- PLAYERS
-- =========================================================

local function setupPlayer(player: Player)
	player.CharacterAdded:Connect(setupCharacter)

	if player.Character then
		setupCharacter(player.Character)
	end
end

for _, player in ipairs(Players:GetPlayers()) do
	setupPlayer(player)
end

Players.PlayerAdded:Connect(setupPlayer)
