--!strict

local Debris = game:GetService("Debris")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local SoundService = game:GetService("SoundService")

local PICKUP_REMOTE_NAME = "CollectiblePickedUp"
local SOUND_TEMPLATE_NAME = "GoldSound"
local SOUND_FALLBACK_LIFETIME = 30

local pickupRemote = ReplicatedStorage:WaitForChild(PICKUP_REMOTE_NAME)
if not pickupRemote:IsA("RemoteEvent") then
	error(`ReplicatedStorage.{PICKUP_REMOTE_NAME} must be a RemoteEvent`)
end

local soundTemplate = SoundService:WaitForChild(SOUND_TEMPLATE_NAME)
if not soundTemplate:IsA("Sound") then
	error(`SoundService.{SOUND_TEMPLATE_NAME} must be a Sound`)
end

pickupRemote.OnClientEvent:Connect(function()
	local sound = soundTemplate:Clone()
	sound.Name = SOUND_TEMPLATE_NAME .. "Playback"
	sound.Parent = SoundService
	sound.Ended:Once(function()
		sound:Destroy()
	end)
	Debris:AddItem(sound, SOUND_FALLBACK_LIFETIME)
	sound:Play()
end)
