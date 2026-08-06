--!strict

local Debris = game:GetService("Debris")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")
local SoundService = game:GetService("SoundService")
local Workspace = game:GetService("Workspace")

local SeekerSearchConfig = require(ReplicatedStorage:WaitForChild("SeekerSearchConfig"))
local HiderEvidenceService = require(
	script.Parent:WaitForChild("Round"):WaitForChild("HiderEvidenceService")
)

local SOURCE_FOLDER_NAME = "Smokes"
local SMOKE_TEMPLATE_NAME = "smoke-01"
local FART_TEMPLATE_NAME = "fart"
local SMOKE_CLIENT_ASSET_NAME = "RandomSmokeTemplate"
local FART_CLIENT_ASSET_NAME = "FartTemplate"
local REMOTE_NAME = "RandomSmokeTriggered"
local SMOKE_EFFECT_KIND = "Smoke"
local FART_EFFECT_KIND = "Fart"
local FART_SOUND_NAME = "FartSound"
local MIN_INTERVAL_SECONDS = 3
local MAX_INTERVAL_SECONDS = 5
local FART_DELAY_SECONDS = 3
local MOVEMENT_SPEED_THRESHOLD = 0.5
local TIMER_STEP_SECONDS = 0.1
local SOUND_FALLBACK_LIFETIME = 30
local NPC_FOLDER_NAME = "RoundNPCs"
local MANAGED_NPC_ATTRIBUTE = "ManagedRoundNPC"
local ROLE_ATTRIBUTE = "RoundRole"
local HIDER_ROLE = "Hider"

local sourceFolder = ServerStorage:WaitForChild(SOURCE_FOLDER_NAME, 10)
if not sourceFolder then
	warn(`RandomSmokeSetup: ServerStorage.{SOURCE_FOLDER_NAME} not found`)
	return
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

if not publishTemplate(SMOKE_TEMPLATE_NAME, SMOKE_CLIENT_ASSET_NAME)
	or not publishTemplate(FART_TEMPLATE_NAME, FART_CLIENT_ASSET_NAME) then
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

local random = Random.new()
type EffectState = {
	secondsUntilEffect: number,
	standingSeconds: number,
	fartPlayed: boolean,
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

local function getCharacterMovement(character: Model): (BasePart?, boolean)
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	local rootPart = character:FindFirstChild("HumanoidRootPart")
	if not character.Parent
		or not humanoid
		or humanoid.Health <= 0
		or not rootPart
		or not rootPart:IsA("BasePart") then
		return nil, false
	end

	local velocity = rootPart.AssemblyLinearVelocity
	local horizontalSpeed = Vector3.new(velocity.X, 0, velocity.Z).Magnitude
	return rootPart, horizontalSpeed >= MOVEMENT_SPEED_THRESHOLD
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

local function playFartSound(rootPart: BasePart)
	local soundTemplate = SoundService:FindFirstChild(FART_SOUND_NAME)
	if not soundTemplate or not soundTemplate:IsA("Sound") then
		warn(`RandomSmokeSetup: SoundService.{FART_SOUND_NAME} must be a Sound`)
		return
	end
	if soundTemplate.SoundId == "" then
		warn(`RandomSmokeSetup: SoundService.{FART_SOUND_NAME}.SoundId is empty`)
		return
	end

	local sound = soundTemplate:Clone()
	sound.Name = FART_SOUND_NAME .. "Playback"
	sound.Looped = false
	sound.Parent = rootPart
	sound.Ended:Once(function()
		sound:Destroy()
	end)
	Debris:AddItem(sound, SOUND_FALLBACK_LIFETIME)
	sound:Play()
end

task.spawn(function()
	while true do
		local elapsed = task.wait(TIMER_STEP_SECONDS)
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
					secondsUntilEffect = random:NextNumber(MIN_INTERVAL_SECONDS, MAX_INTERVAL_SECONDS),
					standingSeconds = 0,
					fartPlayed = false,
				}
				effectStates[character] = state
			end

			local rootPart, isMoving = getCharacterMovement(character)
			if character:GetAttribute(SeekerSearchConfig.CAGED_ATTRIBUTE) == true then
				state.standingSeconds = 0
				state.fartPlayed = false
			elseif not rootPart then
				state.standingSeconds = 0
				state.fartPlayed = false
			elseif isMoving then
				state.secondsUntilEffect -= elapsed
				state.standingSeconds = 0
				state.fartPlayed = false

				if state.secondsUntilEffect <= 0 then
					smokeRemote:FireAllClients(character, SMOKE_EFFECT_KIND)
					HiderEvidenceService.Emit(
						character,
						HiderEvidenceService.KIND_SMOKE,
						rootPart.Position
					)
					state.secondsUntilEffect = random:NextNumber(MIN_INTERVAL_SECONDS, MAX_INTERVAL_SECONDS)
				end
			elseif not state.fartPlayed then
				state.standingSeconds += elapsed
				if state.standingSeconds >= FART_DELAY_SECONDS then
					smokeRemote:FireAllClients(character, FART_EFFECT_KIND)
					HiderEvidenceService.Emit(
						character,
						HiderEvidenceService.KIND_FART,
						rootPart.Position
					)
					playFartSound(rootPart)
					state.fartPlayed = true
				end
			end
		end
	end
end)

print("[RandomSmoke] Hider movement smoke and idle fart effects enabled")
