--!strict

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")
local SoundService = game:GetService("SoundService")
local Workspace = game:GetService("Workspace")

local HiderEvidenceService = require(
	script.Parent:WaitForChild("Round"):WaitForChild("HiderEvidenceService")
)

local SOURCE_FOLDER_NAME = "Smokes"
local SMOKE_TEMPLATE_NAME = "smoke-01"
local SMOKE_CLIENT_ASSET_NAME = "RandomSmokeTemplate"
local REMOTE_NAME = "RandomSmokeTriggered"
local SMOKE_EFFECT_KIND = "Smoke"
local LEGACY_FART_TEMPLATE_NAME = "fart"
local LEGACY_FART_CLIENT_ASSET_NAME = "FartTemplate"
local LEGACY_FART_SOUND_NAME = "FartSound"
local SMOKE_TURN_ANGLE_DEGREES = 15
local SMOKE_TURN_DOT = math.cos(math.rad(SMOKE_TURN_ANGLE_DEGREES))
local SMOKE_COOLDOWN_SECONDS = 1
local MOVEMENT_SPEED_THRESHOLD = 0.5
local TIMER_STEP_SECONDS = 0.1
local NPC_FOLDER_NAME = "RoundNPCs"
local MANAGED_NPC_ATTRIBUTE = "ManagedRoundNPC"
local ROLE_ATTRIBUTE = "RoundRole"
local HIDER_ROLE = "Hider"

-- Remove obsolete replicated/audio assets even if the Smokes folder itself is
-- missing from an older place version.
local legacyFartClientAsset = ReplicatedStorage:FindFirstChild(LEGACY_FART_CLIENT_ASSET_NAME)
if legacyFartClientAsset then
	legacyFartClientAsset:Destroy()
end
local legacyFartSound = SoundService:FindFirstChild(LEGACY_FART_SOUND_NAME)
if legacyFartSound then
	legacyFartSound:Destroy()
end

local sourceFolder = ServerStorage:WaitForChild(SOURCE_FOLDER_NAME, 10)
if not sourceFolder then
	warn(`RandomSmokeSetup: ServerStorage.{SOURCE_FOLDER_NAME} not found`)
	return
end

-- Remove obsolete assets from older place versions as soon as the server
-- starts. The idle fart mechanic no longer exists.
local legacyFartTemplate = sourceFolder:FindFirstChild(LEGACY_FART_TEMPLATE_NAME)
if legacyFartTemplate then
	legacyFartTemplate:Destroy()
end

local function publishTemplate(sourceName: string, clientName: string): boolean
	local sourceTemplate = sourceFolder:FindFirstChild(sourceName)
	if not sourceTemplate then
		warn(`RandomSmokeSetup: ServerStorage.{SOURCE_FOLDER_NAME}.{sourceName} not found`)
		return false
	end

	local oldTemplate = ReplicatedStorage:FindFirstChild(clientName)
	if oldTemplate then
		oldTemplate:Destroy()
	end

	local clientTemplate = sourceTemplate:Clone()
	clientTemplate.Name = clientName
	clientTemplate.Parent = ReplicatedStorage
	return true
end

if not publishTemplate(SMOKE_TEMPLATE_NAME, SMOKE_CLIENT_ASSET_NAME) then
	return
end

local existingRemote = ReplicatedStorage:FindFirstChild(REMOTE_NAME)
if existingRemote and not existingRemote:IsA("RemoteEvent") then
	error(`ReplicatedStorage.{REMOTE_NAME} must be a RemoteEvent`)
end

local smokeRemote: RemoteEvent
if existingRemote then
	smokeRemote = existingRemote :: RemoteEvent
else
	smokeRemote = Instance.new("RemoteEvent")
	smokeRemote.Name = REMOTE_NAME
	smokeRemote.Parent = ReplicatedStorage
end

type EffectState = {
	lastMoveDirection: Vector3?,
	nextSmokeAt: number,
}

local effectStates: {[Model]: EffectState} = {}

local function isHiderCharacter(character: Model): boolean
	local player = Players:GetPlayerFromCharacter(character)
	if player then
		return player:GetAttribute(ROLE_ATTRIBUTE) == HIDER_ROLE
	end

	local npcFolder = Workspace:FindFirstChild(NPC_FOLDER_NAME)
	return npcFolder ~= nil
		and character.Parent == npcFolder
		and character:GetAttribute(MANAGED_NPC_ATTRIBUTE) == true
		and character:GetAttribute(ROLE_ATTRIBUTE) == HIDER_ROLE
end

local function getCharacterMovement(character: Model): (BasePart?, boolean, Vector3?)
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	local rootPart = character:FindFirstChild("HumanoidRootPart")
	if not character.Parent
		or not humanoid
		or humanoid.Health <= 0
		or not rootPart
		or not rootPart:IsA("BasePart") then
		return nil, false, nil
	end

	local velocity = rootPart.AssemblyLinearVelocity
	local horizontalVelocity = Vector3.new(velocity.X, 0, velocity.Z)
	local horizontalSpeed = horizontalVelocity.Magnitude
	if horizontalSpeed < MOVEMENT_SPEED_THRESHOLD then
		return rootPart, false, nil
	end
	return rootPart, true, horizontalVelocity.Unit
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

task.spawn(function()
	while true do
		task.wait(TIMER_STEP_SECONDS)
		local hiderCharacters = getHiderCharacters()

		for character in pairs(effectStates) do
			if not hiderCharacters[character] then
				effectStates[character] = nil
			end
		end

		for character in pairs(hiderCharacters) do
			local state = effectStates[character]
			if not state then
				state = {
					lastMoveDirection = nil,
					nextSmokeAt = 0,
				}
				effectStates[character] = state
			end

			local rootPart, isMoving, moveDirection = getCharacterMovement(character)
			if not rootPart then
				state.lastMoveDirection = nil
			elseif isMoving and moveDirection then
				local now = Workspace:GetServerTimeNow()
				local lastDirection = state.lastMoveDirection
				if lastDirection
					and lastDirection:Dot(moveDirection) <= SMOKE_TURN_DOT
					and now >= state.nextSmokeAt then
					smokeRemote:FireAllClients(character, SMOKE_EFFECT_KIND)
					HiderEvidenceService.Emit(
						character,
						HiderEvidenceService.KIND_SMOKE,
						rootPart.Position
					)
					state.nextSmokeAt = now + SMOKE_COOLDOWN_SECONDS
				end
				state.lastMoveDirection = moveDirection
			else
				state.lastMoveDirection = nil
			end
		end
	end
end)

print(`[RandomSmoke] Hider {SMOKE_TURN_ANGLE_DEGREES}-degree turn smoke enabled`)
