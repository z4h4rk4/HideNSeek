--!strict

local Debris = game:GetService("Debris")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local SoundService = game:GetService("SoundService")

local TELEPORT_REMOTE_NAME = "ArenaTeleported"
local SOUND_TEMPLATE_NAME = "TeleportSound"
local SOUND_FALLBACK_LIFETIME = 30

local teleportRemoteInstance = ReplicatedStorage:WaitForChild(TELEPORT_REMOTE_NAME, 10)
if not teleportRemoteInstance then
	warn(`TeleportSound: ReplicatedStorage.{TELEPORT_REMOTE_NAME} was not created by the server`)
	return
end
if not teleportRemoteInstance:IsA("RemoteEvent") then
	warn(`TeleportSound: ReplicatedStorage.{TELEPORT_REMOTE_NAME} must be a RemoteEvent`)
	return
end
local teleportRemote = teleportRemoteInstance

local soundTemplate = SoundService:WaitForChild(SOUND_TEMPLATE_NAME)
if not soundTemplate:IsA("Sound") then
	error(`SoundService.{SOUND_TEMPLATE_NAME} must be a Sound`)
end

teleportRemote.OnClientEvent:Connect(function()
	local sound = soundTemplate:Clone()
	sound.Name = SOUND_TEMPLATE_NAME .. "Playback"
	sound.Parent = SoundService
	sound.Ended:Once(function()
		sound:Destroy()
	end)
	Debris:AddItem(sound, SOUND_FALLBACK_LIFETIME)
	sound:Play()
end)
