--!strict

local SoundService = game:GetService("SoundService")
local TweenService = game:GetService("TweenService")

local HiderConfig = require(script.Parent:WaitForChild("HiderConfig"))

type AlertRecord = {
	gui: BillboardGui,
	scale: UIScale,
	sound: Sound,
	active: boolean,
	generation: number,
}

local HunterAggroPresentation = {}
local records: {[Model]: AlertRecord} = setmetatable({}, { __mode = "k" }) :: any
local warnedInvalidSoundTemplate = false

local function getIndicatorHeight(npc: Model, rootPart: BasePart): number
	local boundingCFrame, boundingSize = npc:GetBoundingBox()
	local modelTop = boundingCFrame.Position.Y + boundingSize.Y * 0.5
	return math.max(
		HiderConfig.SEEKER_AGGRO_INDICATOR_MIN_HEIGHT,
		modelTop - rootPart.Position.Y + HiderConfig.SEEKER_AGGRO_INDICATOR_TOP_PADDING
	)
end

local function createSound(rootPart: BasePart): Sound
	local template = SoundService:FindFirstChild(HiderConfig.SEEKER_AGGRO_SOUND_TEMPLATE_NAME)
	local sound: Sound
	if template and template:IsA("Sound") and template.SoundId ~= "" then
		warnedInvalidSoundTemplate = false
		sound = template:Clone()
	else
		if template and not warnedInvalidSoundTemplate then
			warnedInvalidSoundTemplate = true
			warn(
				`HunterAggroPresentation: SoundService.{HiderConfig.SEEKER_AGGRO_SOUND_TEMPLATE_NAME} `
					.. "must be a Sound with a non-empty SoundId; using the built-in fallback"
			)
		end
		sound = Instance.new("Sound")
		sound.SoundId = HiderConfig.SEEKER_AGGRO_FALLBACK_SOUND_ID
		sound.Volume = HiderConfig.SEEKER_AGGRO_SOUND_VOLUME
		sound.PlaybackSpeed = HiderConfig.SEEKER_AGGRO_SOUND_PLAYBACK_SPEED
		sound.RollOffMode = Enum.RollOffMode.InverseTapered
		sound.RollOffMinDistance = HiderConfig.SEEKER_AGGRO_SOUND_ROLLOFF_MIN_DISTANCE
		sound.RollOffMaxDistance = HiderConfig.SEEKER_AGGRO_SOUND_ROLLOFF_MAX_DISTANCE
	end
	sound.Name = HiderConfig.SEEKER_AGGRO_SOUND_TEMPLATE_NAME .. "Playback"
	sound.Looped = false
	sound.PlayOnRemove = false
	sound.Parent = rootPart
	return sound
end

local function createRecord(npc: Model, rootPart: BasePart): AlertRecord
	local gui = Instance.new("BillboardGui")
	gui.Name = "HunterAggroIndicator"
	gui.Adornee = rootPart
	gui.AlwaysOnTop = true
	gui.LightInfluence = 0
	gui.MaxDistance = HiderConfig.SEEKER_AGGRO_INDICATOR_MAX_DISTANCE
	gui.Size = UDim2.fromOffset(
		HiderConfig.SEEKER_AGGRO_INDICATOR_WIDTH,
		HiderConfig.SEEKER_AGGRO_INDICATOR_HEIGHT
	)
	gui.StudsOffsetWorldSpace = Vector3.new(0, getIndicatorHeight(npc, rootPart), 0)
	gui.Enabled = false
	gui.Parent = npc

	local container = Instance.new("Frame")
	container.Name = "PopContainer"
	container.BackgroundTransparency = 1
	container.Size = UDim2.fromScale(1, 1)
	container.Parent = gui

	local scale = Instance.new("UIScale")
	scale.Scale = 1
	scale.Parent = container

	local label = Instance.new("TextLabel")
	label.Name = "Exclamation"
	label.BackgroundTransparency = 1
	label.Size = UDim2.fromScale(1, 1)
	label.Font = Enum.Font.GothamBlack
	label.Text = "!"
	label.TextColor3 = HiderConfig.SEEKER_AGGRO_INDICATOR_COLOR
	label.TextScaled = true
	label.TextStrokeColor3 = Color3.fromRGB(20, 8, 8)
	label.TextStrokeTransparency = 0
	label.Parent = container

	return {
		gui = gui,
		scale = scale,
		sound = createSound(rootPart),
		active = false,
		generation = 0,
	}
end

local function getRecord(npc: Model, rootPart: BasePart): AlertRecord
	local record = records[npc]
	if record and record.gui.Parent and record.sound.Parent then
		return record
	end
	if record then
		if record.gui.Parent then
			record.gui:Destroy()
		end
		if record.sound.Parent then
			record.sound:Destroy()
		end
	end
	record = createRecord(npc, rootPart)
	records[npc] = record
	return record
end

function HunterAggroPresentation.Show(npc: Model, rootPart: BasePart)
	local record = getRecord(npc, rootPart)
	record.active = true
	record.generation += 1
	local generation = record.generation
	record.gui.StudsOffsetWorldSpace = Vector3.new(0, getIndicatorHeight(npc, rootPart), 0)
	record.gui.Enabled = true
	record.scale.Scale = 0.35

	TweenService:Create(
		record.scale,
		TweenInfo.new(
			HiderConfig.SEEKER_AGGRO_INDICATOR_POP_SECONDS,
			Enum.EasingStyle.Back,
			Enum.EasingDirection.Out
		),
		{ Scale = 1.2 }
	):Play()
	task.delay(HiderConfig.SEEKER_AGGRO_INDICATOR_POP_SECONDS, function()
		if records[npc] ~= record or not record.active or record.generation ~= generation then
			return
		end
		TweenService:Create(
			record.scale,
			TweenInfo.new(
				HiderConfig.SEEKER_AGGRO_INDICATOR_SETTLE_SECONDS,
				Enum.EasingStyle.Quad,
				Enum.EasingDirection.Out
			),
			{ Scale = 1 }
		):Play()
	end)

	pcall(function()
		if record.sound.IsPlaying then
			record.sound:Stop()
		end
		record.sound.TimePosition = 0
		record.sound:Play()
	end)
end

function HunterAggroPresentation.Hide(npc: Model)
	local record = records[npc]
	if not record then
		return
	end
	record.active = false
	record.generation += 1
	record.gui.Enabled = false
	record.scale.Scale = 1
end

function HunterAggroPresentation.Destroy(npc: Model)
	local record = records[npc]
	if not record then
		return
	end
	records[npc] = nil
	record.active = false
	record.generation += 1
	if record.gui.Parent then
		record.gui:Destroy()
	end
	if record.sound.Parent then
		record.sound:Destroy()
	end
end

return table.freeze(HunterAggroPresentation)
