--!strict

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage:WaitForChild("RoundResultConfig"))

type RoundResultPayload = {
	UserId: number,
	Name: string,
	Knockouts: number,
	SecondsSurvived: number,
	Coins: number,
}

type ResultUi = {
	Gui: ScreenGui,
	MainFrame: GuiObject,
	TakeButton: GuiButton,
	Photo: Instance,
	Knockouts: Instance,
	PlayerName: Instance,
	SecondsSurvived: Instance,
	Coins: Instance,
}

local localPlayer = Players.LocalPlayer
local playerGui = localPlayer:WaitForChild("PlayerGui")

local currentUi: ResultUi? = nil
local takeButtonConnection: RBXScriptConnection? = nil
local lastPayload: RoundResultPayload? = nil
local warnedGui: Instance? = nil
local avatarImage: string? = nil
local avatarRequestToken = 0

local function disableResultGui(gui: Instance?)
	if gui and gui:IsA("ScreenGui") then
		gui.Enabled = false
		local mainFrame = gui:FindFirstChild(Config.MAIN_FRAME_NAME, true)
		if mainFrame and mainFrame:IsA("GuiObject") then
			mainFrame.Visible = false
		end
	end
end

if not Config.DISPLAY_ENABLED then
	disableResultGui(playerGui:FindFirstChild(Config.GUI_NAME))
	playerGui.ChildAdded:Connect(function(child)
		if child.Name == Config.GUI_NAME then
			disableResultGui(child)
		end
	end)
end

local function isPhotoObject(instance: Instance): boolean
	return instance:IsA("ImageLabel") or instance:IsA("ImageButton")
end

local function isTextObject(instance: Instance): boolean
	return instance:IsA("TextLabel")
		or instance:IsA("TextButton")
		or instance:IsA("TextBox")
end

local function setPhoto(instance: Instance, image: string)
	if instance:IsA("ImageLabel") then
		instance.Image = image
	elseif instance:IsA("ImageButton") then
		instance.Image = image
	end
end

local function setText(instance: Instance, text: string)
	if instance:IsA("TextLabel") then
		instance.Text = text
	elseif instance:IsA("TextButton") then
		instance.Text = text
	elseif instance:IsA("TextBox") then
		instance.Text = text
	end
end

local function wholeNumber(value: any): number
	if type(value) ~= "number" or value ~= value or value == math.huge or value == -math.huge then
		return 0
	end
	return math.max(0, math.floor(value))
end

local function normalizePayload(payload: any): RoundResultPayload?
	if type(payload) ~= "table" then
		return nil
	end
	return {
		UserId = if type(payload.UserId) == "number"
			then math.floor(payload.UserId)
			else localPlayer.UserId,
		Name = if type(payload.Name) == "string" and payload.Name ~= ""
			then payload.Name
			else localPlayer.Name,
		Knockouts = wholeNumber(payload.Knockouts),
		SecondsSurvived = wholeNumber(payload.SecondsSurvived),
		Coins = wholeNumber(payload.Coins),
	}
end

local function requestAvatar(ui: ResultUi)
	if avatarImage then
		setPhoto(ui.Photo, avatarImage)
		return
	end

	avatarRequestToken += 1
	local requestToken = avatarRequestToken
	task.spawn(function()
		local succeeded, image = pcall(function()
			return Players:GetUserThumbnailAsync(
				localPlayer.UserId,
				Enum.ThumbnailType.HeadShot,
				Enum.ThumbnailSize.Size420x420
			)
		end)
		if not succeeded or type(image) ~= "string" or image == "" then
			return
		end
		avatarImage = image
		if requestToken == avatarRequestToken
			and currentUi == ui
			and ui.Photo:IsDescendantOf(playerGui) then
			setPhoto(ui.Photo, image)
		end
	end)
end

local function formatCount(value: number, singular: string, plural: string): string
	return `{value} {if value == 1 then singular else plural}`
end

local function displayPayload(ui: ResultUi, payload: RoundResultPayload)
	if not Config.DISPLAY_ENABLED then
		disableResultGui(ui.Gui)
		return
	end
	setText(ui.PlayerName, `Player: {payload.Name}`)
	setText(ui.Knockouts, formatCount(payload.Knockouts, "Knockout", "Knockouts"))
	setText(
		ui.SecondsSurvived,
		formatCount(payload.SecondsSurvived, "Second Survived", "Seconds Survived")
	)
	setText(ui.Coins, formatCount(payload.Coins, "Coin", "Coins"))
	requestAvatar(ui)
	ui.Gui.Enabled = true
	ui.MainFrame.Visible = true
end

local function reportInvalidGui(gui: Instance, message: string)
	if warnedGui == gui then
		return
	end
	warnedGui = gui
	warn(`{Config.GUI_NAME}: {message}`)
end

local function findResultUi(): ResultUi?
	local guiInstance = playerGui:FindFirstChild(Config.GUI_NAME)
	if not guiInstance then
		return nil
	end
	if not guiInstance:IsA("ScreenGui") then
		reportInvalidGui(guiInstance, "must be a ScreenGui")
		return nil
	end

	local mainFrameInstance = guiInstance:FindFirstChild(Config.MAIN_FRAME_NAME, true)
	if not mainFrameInstance or not mainFrameInstance:IsA("GuiObject") then
		reportInvalidGui(guiInstance, `{Config.MAIN_FRAME_NAME} must be a GuiObject`)
		return nil
	end

	local takeButton = mainFrameInstance:FindFirstChild(Config.TAKE_BUTTON_NAME, true)
	local photo = mainFrameInstance:FindFirstChild(Config.PHOTO_NAME, true)
	local knockouts = mainFrameInstance:FindFirstChild(Config.KNOCKOUTS_NAME, true)
	local playerName = mainFrameInstance:FindFirstChild(Config.PLAYER_NAME_NAME, true)
	local secondsSurvived = mainFrameInstance:FindFirstChild(Config.SECONDS_SURVIVED_NAME, true)
	local coins = mainFrameInstance:FindFirstChild(Config.COINS_NAME, true)

	if not takeButton or not takeButton:IsA("GuiButton") then
		reportInvalidGui(guiInstance, `{Config.TAKE_BUTTON_NAME} must be a GuiButton`)
		return nil
	end
	if not photo or not isPhotoObject(photo) then
		reportInvalidGui(guiInstance, `{Config.PHOTO_NAME} must be an ImageLabel or ImageButton`)
		return nil
	end
	if not knockouts or not isTextObject(knockouts) then
		reportInvalidGui(guiInstance, `{Config.KNOCKOUTS_NAME} must be a text GUI object`)
		return nil
	end
	if not playerName or not isTextObject(playerName) then
		reportInvalidGui(guiInstance, `{Config.PLAYER_NAME_NAME} must be a text GUI object`)
		return nil
	end
	if not secondsSurvived or not isTextObject(secondsSurvived) then
		reportInvalidGui(guiInstance, `{Config.SECONDS_SURVIVED_NAME} must be a text GUI object`)
		return nil
	end
	if not coins or not isTextObject(coins) then
		reportInvalidGui(guiInstance, `{Config.COINS_NAME} must be a text GUI object`)
		return nil
	end

	warnedGui = nil
	return {
		Gui = guiInstance,
		MainFrame = mainFrameInstance,
		TakeButton = takeButton,
		Photo = photo,
		Knockouts = knockouts,
		PlayerName = playerName,
		SecondsSurvived = secondsSurvived,
		Coins = coins,
	}
end

local function currentUiIsValid(): boolean
	local ui = currentUi
	return ui ~= nil
		and ui.Gui:IsDescendantOf(playerGui)
		and ui.MainFrame:IsDescendantOf(ui.Gui)
		and ui.TakeButton:IsDescendantOf(ui.MainFrame)
		and ui.Photo:IsDescendantOf(ui.MainFrame)
		and ui.Knockouts:IsDescendantOf(ui.MainFrame)
		and ui.PlayerName:IsDescendantOf(ui.MainFrame)
		and ui.SecondsSurvived:IsDescendantOf(ui.MainFrame)
		and ui.Coins:IsDescendantOf(ui.MainFrame)
end

local function bindResultUi()
	if currentUiIsValid() then
		return
	end
	currentUi = nil
	if takeButtonConnection then
		takeButtonConnection:Disconnect()
		takeButtonConnection = nil
	end

	local ui = findResultUi()
	if not ui then
		return
	end
	currentUi = ui
	if not Config.DISPLAY_ENABLED then
		disableResultGui(ui.Gui)
	end
	takeButtonConnection = ui.TakeButton.Activated:Connect(function()
		ui.MainFrame.Visible = false
	end)

	local payload = lastPayload
	if payload then
		if currentUiIsValid() then
			displayPayload(ui, payload)
			lastPayload = nil
		end
	else
		ui.MainFrame.Visible = false
	end
end

playerGui.DescendantAdded:Connect(function(descendant)
	if descendant.Name == Config.GUI_NAME
		or descendant.Name == Config.MAIN_FRAME_NAME
		or descendant.Name == Config.TAKE_BUTTON_NAME
		or descendant.Name == Config.PHOTO_NAME
		or descendant.Name == Config.KNOCKOUTS_NAME
		or descendant.Name == Config.PLAYER_NAME_NAME
		or descendant.Name == Config.SECONDS_SURVIVED_NAME
		or descendant.Name == Config.COINS_NAME then
		task.defer(bindResultUi)
	end
end)

playerGui.DescendantRemoving:Connect(function(descendant)
	local ui = currentUi
	if ui and (descendant == ui.Gui
		or descendant == ui.MainFrame
		or descendant == ui.TakeButton
		or descendant == ui.Photo
		or descendant == ui.Knockouts
		or descendant == ui.PlayerName
		or descendant == ui.SecondsSurvived
		or descendant == ui.Coins) then
		currentUi = nil
		if takeButtonConnection then
			takeButtonConnection:Disconnect()
			takeButtonConnection = nil
		end
	end
end)

bindResultUi()

task.spawn(function()
	local remoteInstance = ReplicatedStorage:WaitForChild(Config.REMOTE_NAME)
	if not remoteInstance:IsA("RemoteEvent") then
		warn(`ReplicatedStorage.{Config.REMOTE_NAME} must be a RemoteEvent`)
		return
	end
	remoteInstance.OnClientEvent:Connect(function(rawPayload: any)
		local payload = normalizePayload(rawPayload)
		if not payload then
			warn(`ReplicatedStorage.{Config.REMOTE_NAME} received an invalid payload`)
			return
		end
		lastPayload = payload
		bindResultUi()
		local ui = currentUi
		if ui and currentUiIsValid() and lastPayload then
			displayPayload(ui, payload)
			lastPayload = nil
		end
	end)
end)
