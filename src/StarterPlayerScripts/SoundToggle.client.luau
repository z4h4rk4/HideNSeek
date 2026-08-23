--!strict

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local SoundService = game:GetService("SoundService")
local Workspace = game:GetService("Workspace")

local ICONS_GUI_NAME = "IconsGui"
local MAIN_FRAME_NAME = "MainFrame"
local SOUND_BUTTON_NAME = "Sound"
local MAIN_SONG_NAME = "MainSong"
local SOUND_ON_TEXT = "🔊"
local SOUND_OFF_TEXT = "🔈"
local DEFAULT_VOLUME = 1
local BIND_TIMEOUT_SECONDS = 20

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

local bindRevision = 0
local buttonConnection: RBXScriptConnection? = nil
local volumeConnection: RBXScriptConnection? = nil
local songAncestryConnection: RBXScriptConnection? = nil
local activeButton: TextButton? = nil
local activeSong: Sound? = nil
local lastAudibleVolume = DEFAULT_VOLUME

local function findSoundButton(): TextButton?
	local iconsGui = playerGui:FindFirstChild(ICONS_GUI_NAME)
	local mainFrame = iconsGui and iconsGui:FindFirstChild(MAIN_FRAME_NAME)
	local button = mainFrame and mainFrame:FindFirstChild(SOUND_BUTTON_NAME)
	return if button and button:IsA("TextButton") then button else nil
end

local function findMainSong(): Sound?
	local direct = SoundService:FindFirstChild(MAIN_SONG_NAME)
	if direct and direct:IsA("Sound") then
		return direct
	end

	for _, root in ipairs({ SoundService, Workspace, ReplicatedStorage, playerGui }) do
		local found = root:FindFirstChild(MAIN_SONG_NAME, true)
		if found and found:IsA("Sound") then
			return found
		end
	end
	return nil
end

local function refreshButton()
	local button = activeButton
	if not button or not button.Parent then
		return
	end

	local song = activeSong
	if song and song.Parent and song.Volume > 0 then
		lastAudibleVolume = song.Volume
		button.Text = SOUND_ON_TEXT
	else
		button.Text = SOUND_OFF_TEXT
	end
end

local function toggleSound()
	local song = activeSong or findMainSong()
	if not song then
		refreshButton()
		warn("SoundToggle: expected a Sound named MainSong")
		return
	end
	activeSong = song

	if song.Volume > 0 then
		lastAudibleVolume = song.Volume
		song.Volume = 0
	else
		song.Volume = math.max(lastAudibleVolume, DEFAULT_VOLUME)
		if not song.IsPlaying then
			song:Play()
		end
	end
	refreshButton()
end

local function disconnect()
	if buttonConnection then
		buttonConnection:Disconnect()
		buttonConnection = nil
	end
	if volumeConnection then
		volumeConnection:Disconnect()
		volumeConnection = nil
	end
	if songAncestryConnection then
		songAncestryConnection:Disconnect()
		songAncestryConnection = nil
	end
	activeButton = nil
	activeSong = nil
end

local function bind()
	bindRevision += 1
	local revision = bindRevision
	disconnect()

	task.spawn(function()
		local deadline = os.clock() + BIND_TIMEOUT_SECONDS
		repeat
			local button = findSoundButton()
			local song = findMainSong()
			if button and song then
				if revision ~= bindRevision then
					return
				end

				activeButton = button
				activeSong = song
				if song.Volume > 0 then
					lastAudibleVolume = song.Volume
				end
				buttonConnection = button.Activated:Connect(toggleSound)
				volumeConnection = song:GetPropertyChangedSignal("Volume"):Connect(refreshButton)
				songAncestryConnection = song.AncestryChanged:Connect(function()
					if not song:IsDescendantOf(game) then
						task.defer(bind)
					end
				end)
				refreshButton()
				return
			end
			task.wait(0.1)
		until revision ~= bindRevision or os.clock() >= deadline

		if revision == bindRevision then
			warn("SoundToggle: expected PlayerGui.IconsGui.MainFrame.Sound and a Sound named MainSong")
		end
	end)
end

playerGui.DescendantAdded:Connect(function(descendant)
	if descendant.Name == ICONS_GUI_NAME
		or descendant.Name == MAIN_FRAME_NAME
		or descendant.Name == SOUND_BUTTON_NAME
		or descendant.Name == MAIN_SONG_NAME then
		task.defer(bind)
	end
end)

SoundService.DescendantAdded:Connect(function(descendant)
	if descendant.Name == MAIN_SONG_NAME then
		task.defer(bind)
	end
end)

Workspace.DescendantAdded:Connect(function(descendant)
	if descendant.Name == MAIN_SONG_NAME then
		task.defer(bind)
	end
end)

ReplicatedStorage.DescendantAdded:Connect(function(descendant)
	if descendant.Name == MAIN_SONG_NAME then
		task.defer(bind)
	end
end)

playerGui.DescendantRemoving:Connect(function(descendant)
	local button = activeButton
	local song = activeSong
	if (button and (descendant == button or descendant:IsAncestorOf(button)))
		or (song and (descendant == song or descendant:IsAncestorOf(song))) then
		task.defer(bind)
	end
end)

bind()
