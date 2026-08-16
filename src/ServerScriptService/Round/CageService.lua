--!strict

local Debris = game:GetService("Debris")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local ServerStorage = game:GetService("ServerStorage")
local SoundService = game:GetService("SoundService")
local Workspace = game:GetService("Workspace")

local Config = require(ReplicatedStorage:WaitForChild("SeekerSearchConfig"))
local CageConfig = require(ReplicatedStorage:WaitForChild("CageConfig"))
local HiderService = require(script.Parent:WaitForChild("HiderService"))

local FOLDER_NAME = "RoundCages"
local FALLBACK_FOLDER_NAME = "_RoundCages"
local MANAGED_ATTRIBUTE = "ManagedRoundCage"
local OWNER_ATTRIBUTE = "CagedOwner"
local HIDER_POSITION_NAME = "HiderPosition"
local PROMPT_NAME = "RescuePrompt"
local ROLE_ATTRIBUTE = "RoundRole"
local ROLE_HIDER = "Hider"
local CENTER_EXCLUDED_NAME_FRAGMENTS = { "door", "gate", "hinge" }

type CageRecord = {
	cage: Model,
	character: Model,
	humanoid: Humanoid,
	rootPart: BasePart,
	prompt: ProximityPrompt,
	connections: {RBXScriptConnection},
	walkSpeed: number,
	autoRotate: boolean,
	jumpHeight: number,
	jumpPower: number,
	useJumpPower: boolean,
	rootAnchored: boolean,
	expiresAt: number,
}

type TimerVisual = {
	segments: {Frame},
	label: TextLabel,
}

local records: {[Instance]: CageRecord} = {}
local warnedMissingTemplate = false
local warnedInvalidSoundTemplates: {[string]: boolean} = {}

local existingFolder = Workspace:FindFirstChild(FOLDER_NAME)
local cageFolder: Folder
if existingFolder and existingFolder:IsA("Folder") then
	cageFolder = existingFolder
else
	cageFolder = Instance.new("Folder")
	cageFolder.Name = if existingFolder then FALLBACK_FOLDER_NAME else FOLDER_NAME
	cageFolder.Parent = Workspace
end

for _, child in ipairs(cageFolder:GetChildren()) do
	if child:GetAttribute(MANAGED_ATTRIBUTE) == true then
		child:Destroy()
	end
end

local CageService = {}

local function playCageSound(templateName: string, position: Vector3)
	local template = SoundService:FindFirstChild(templateName)
	if not template or not template:IsA("Sound") or template.SoundId == "" then
		if not warnedInvalidSoundTemplates[templateName] then
			warnedInvalidSoundTemplates[templateName] = true
			warn(`CageService: SoundService.{templateName} must be a Sound with a SoundId`)
		end
		return
	end
	warnedInvalidSoundTemplates[templateName] = nil

	local anchor = Instance.new("Part")
	anchor.Name = templateName .. "SoundAnchor"
	anchor.Size = Vector3.one * 0.1
	anchor.CFrame = CFrame.new(position)
	anchor.Anchored = true
	anchor.CanCollide = false
	anchor.CanTouch = false
	anchor.CanQuery = false
	anchor.CastShadow = false
	anchor.Transparency = 1
	anchor.Parent = Workspace

	local sound = template:Clone()
	sound.Name = templateName .. "Playback"
	sound.Looped = false
	sound.PlayOnRemove = false
	sound.Parent = anchor
	sound.Ended:Once(function()
		anchor:Destroy()
	end)
	Debris:AddItem(anchor, CageConfig.SOUND_FALLBACK_LIFETIME_SECONDS)
	sound:Play()
end

local function disconnect(record: CageRecord)
	for _, connection in ipairs(record.connections) do
		connection:Disconnect()
	end
	table.clear(record.connections)
end

function CageService.GetFolder(): Folder
	return cageFolder
end

function CageService.Remove(owner: Instance)
	local record = records[owner]
	if not record then
		return
	end
	records[owner] = nil
	disconnect(record)
	owner:SetAttribute(Config.CAGED_ATTRIBUTE, nil)
	if owner == record.character then
		HiderService.SetCaged(record.character, false)
	elseif record.character.Parent then
		record.character:SetAttribute(Config.CAGED_ATTRIBUTE, nil)
	end
	if record.humanoid.Parent then
		record.humanoid.WalkSpeed = record.walkSpeed
		record.humanoid.AutoRotate = record.autoRotate
		record.humanoid.JumpHeight = record.jumpHeight
		record.humanoid.JumpPower = record.jumpPower
		record.humanoid.UseJumpPower = record.useJumpPower
		record.humanoid.Jump = false
	end
	if record.rootPart.Parent then
		record.rootPart.Anchored = record.rootAnchored
		record.rootPart.AssemblyLinearVelocity = Vector3.zero
		record.rootPart.AssemblyAngularVelocity = Vector3.zero
	end
	playCageSound(
		CageConfig.CAGE_OFF_SOUND_TEMPLATE_NAME,
		record.cage:GetPivot().Position
	)
	record.cage:Destroy()
end

function CageService.RemoveAll()
	local owners: {Instance} = {}
	for owner in pairs(records) do
		table.insert(owners, owner)
	end
	for _, owner in ipairs(owners) do
		CageService.Remove(owner)
	end
end

local function getTemplate(): Model?
	local template = ServerStorage:FindFirstChild(CageConfig.TEMPLATE_MODEL_NAME)
	if not template or not template:IsA("Model") then
		if not warnedMissingTemplate then
			warnedMissingTemplate = true
			warn(`CageService: ServerStorage.{CageConfig.TEMPLATE_MODEL_NAME} must be a Model`)
		end
		return nil
	end
	warnedMissingTemplate = false
	return template
end

local function prepare(cage: Model): BasePart?
	local firstPart: BasePart? = nil
	for _, object in ipairs(cage:GetDescendants()) do
		if object:IsA("BasePart") then
			firstPart = firstPart or object
			object.Anchored = true
			object.CanCollide = false
			object.CanTouch = false
			object.CanQuery = false
			object.AssemblyLinearVelocity = Vector3.zero
			object.AssemblyAngularVelocity = Vector3.zero
		end
	end
	return firstPart
end

local function findMarker(cage: Model): Instance?
	for _, object in ipairs(cage:GetDescendants()) do
		if object.Name == HIDER_POSITION_NAME
			and (object:IsA("Attachment") or object:IsA("BasePart")) then
			return object
		end
	end
	return nil
end

local function median(values: {number}): number
	table.sort(values)
	local middle = math.floor((#values + 1) * 0.5)
	if #values % 2 == 1 then
		return values[middle]
	end
	return (values[middle] + values[middle + 1]) * 0.5
end

local function canDefineCenter(part: BasePart): boolean
	if part.Name == HIDER_POSITION_NAME or part.Transparency >= 0.99 then
		return false
	end
	local lowerName = string.lower(part.Name)
	for _, fragment in ipairs(CENTER_EXCLUDED_NAME_FRAGMENTS) do
		if string.find(lowerName, fragment, 1, true) then
			return false
		end
	end
	return true
end

local function getStructuralCenter(cage: Model, pivot: CFrame): Vector3
	local localX: {number} = {}
	local localZ: {number} = {}
	for _, object in ipairs(cage:GetDescendants()) do
		if object:IsA("BasePart") and canDefineCenter(object) then
			local position = pivot:PointToObjectSpace(object.Position)
			table.insert(localX, position.X)
			table.insert(localZ, position.Z)
		end
	end
	if #localX == 0 then
		return pivot.Position
	end
	return pivot:PointToWorldSpace(Vector3.new(median(localX), 0, median(localZ)))
end

local function getFloorY(character: Model, humanoid: Humanoid, rootPart: BasePart): number
	local parameters = RaycastParams.new()
	parameters.FilterType = Enum.RaycastFilterType.Exclude
	parameters.FilterDescendantsInstances = { character }
	parameters.IgnoreWater = true
	local castDistance = math.max(12, humanoid.HipHeight + rootPart.Size.Y + 8)
	local result = Workspace:Raycast(
		rootPart.Position + Vector3.yAxis * 2,
		-Vector3.yAxis * castDistance,
		parameters
	)
	if result then
		return result.Position.Y
	end
	return rootPart.Position.Y - math.max(0, humanoid.HipHeight) - rootPart.Size.Y * 0.5
end

local function getVisibleBottomY(cage: Model): number?
	local bottomY = math.huge
	for _, object in ipairs(cage:GetDescendants()) do
		if object:IsA("BasePart")
			and object.Name ~= HIDER_POSITION_NAME
			and object.Transparency < 0.99 then
			local halfSize = object.Size * 0.5
			local frame = object.CFrame
			local verticalExtent = math.abs(frame.RightVector.Y) * halfSize.X
				+ math.abs(frame.UpVector.Y) * halfSize.Y
				+ math.abs(frame.LookVector.Y) * halfSize.Z
			bottomY = math.min(bottomY, object.Position.Y - verticalExtent)
		end
	end
	return if bottomY < math.huge then bottomY else nil
end

local function alignCageToFloor(cage: Model, floorY: number)
	local bottomY = getVisibleBottomY(cage)
	if bottomY then
		cage:PivotTo(
			cage:GetPivot() + Vector3.yAxis * (floorY + CageConfig.FLOOR_CLEARANCE - bottomY)
		)
	end
end

local function moveCharacterToCaptureCenter(
	character: Model,
	humanoid: Humanoid,
	rootPart: BasePart,
	captureCenter: Vector3
)
	local horizontalOffset = Vector3.new(
		captureCenter.X - rootPart.Position.X,
		0,
		captureCenter.Z - rootPart.Position.Z
	)
	character:PivotTo(character:GetPivot() + horizontalOffset)

	local floorY = getFloorY(character, humanoid, rootPart)
	local desiredRootY = floorY + math.max(0, humanoid.HipHeight) + rootPart.Size.Y * 0.5
	character:PivotTo(character:GetPivot() + Vector3.yAxis * (desiredRootY - rootPart.Position.Y))
	rootPart.AssemblyLinearVelocity = Vector3.zero
	rootPart.AssemblyAngularVelocity = Vector3.zero
end

local function positionCage(
	cage: Model,
	character: Model,
	humanoid: Humanoid,
	rootPart: BasePart
)
	local floorY = getFloorY(character, humanoid, rootPart)
	local marker = findMarker(cage)
	local markerCFrame: CFrame? = nil
	if marker and marker:IsA("Attachment") then
		markerCFrame = marker.WorldCFrame
	elseif marker and marker:IsA("BasePart") then
		markerCFrame = marker.CFrame
	end
	if markerCFrame then
		local pivotToMarker = cage:GetPivot():ToObjectSpace(markerCFrame)
		cage:PivotTo(rootPart.CFrame * pivotToMarker:Inverse())
		alignCageToFloor(cage, floorY)
		return
	end

	local pivot = cage:GetPivot()
	local structuralCenter = getStructuralCenter(cage, pivot)
	cage:PivotTo(pivot + Vector3.new(
		rootPart.Position.X - structuralCenter.X,
		0,
		rootPart.Position.Z - structuralCenter.Z
	))
	alignCageToFloor(cage, floorY)
end

local function makePrompt(cage: Model, fallbackPart: BasePart, owner: Instance): ProximityPrompt
	local existingPrompt = cage:FindFirstChild(PROMPT_NAME, true)
	if existingPrompt and existingPrompt:IsA("ProximityPrompt") then
		existingPrompt:Destroy()
	end
	local parent: Instance = cage:FindFirstChild("Door", true)
		or cage:FindFirstChild("Gate", true)
		or fallbackPart
	if not (parent:IsA("BasePart") or parent:IsA("Attachment")) then
		parent = fallbackPart
	end
	local prompt = Instance.new("ProximityPrompt")
	prompt.Name = PROMPT_NAME
	prompt.ActionText = "FREE HIDER"
	prompt.ObjectText = owner.Name
	prompt.HoldDuration = CageConfig.RESCUE_HOLD_SECONDS
	prompt.MaxActivationDistance = CageConfig.RESCUE_RADIUS
	prompt.RequiresLineOfSight = true
	prompt.Exclusivity = Enum.ProximityPromptExclusivity.OnePerButton
	prompt.Parent = parent
	return prompt
end

local function makeTimerVisual(cage: Model): TimerVisual
	local pivot = cage:GetPivot()
	local structuralCenter = getStructuralCenter(cage, pivot)
	local topY = -math.huge
	for _, object in ipairs(cage:GetDescendants()) do
		if object:IsA("BasePart") and canDefineCenter(object) then
			local halfSize = object.Size * 0.5
			local frame = object.CFrame
			local verticalExtent = math.abs(frame.RightVector.Y) * halfSize.X
				+ math.abs(frame.UpVector.Y) * halfSize.Y
				+ math.abs(frame.LookVector.Y) * halfSize.Z
			topY = math.max(topY, object.Position.Y + verticalExtent)
		end
	end
	if topY == -math.huge then
		topY = pivot.Position.Y
	end
	local anchor = Instance.new("Part")
	anchor.Name = "CageTimerAnchor"
	anchor.Size = Vector3.one * 0.1
	anchor.CFrame = CFrame.new(Vector3.new(
		structuralCenter.X,
		topY + CageConfig.TIMER_HEIGHT_PADDING_STUDS,
		structuralCenter.Z
	))
	anchor.Anchored = true
	anchor.CanCollide = false
	anchor.CanTouch = false
	anchor.CanQuery = false
	anchor.CastShadow = false
	anchor.Transparency = 1
	anchor.Parent = cage

	local billboard = Instance.new("BillboardGui")
	billboard.Name = "CageTimer"
	billboard.AlwaysOnTop = true
	billboard.LightInfluence = 0
	billboard.MaxDistance = 80
	billboard.Size = UDim2.fromOffset(
		CageConfig.TIMER_SIZE_PIXELS,
		CageConfig.TIMER_SIZE_PIXELS
	)
	billboard.Parent = anchor

	local center = CageConfig.TIMER_SIZE_PIXELS * 0.5
	local segments: {Frame} = {}
	for index = 1, CageConfig.TIMER_SEGMENT_COUNT do
		local angle = -math.pi * 0.5
			+ (index - 1) / CageConfig.TIMER_SEGMENT_COUNT * math.pi * 2
		local segment = Instance.new("Frame")
		segment.Name = `Segment{index}`
		segment.AnchorPoint = Vector2.new(0.5, 0.5)
		segment.Position = UDim2.fromOffset(
			center + math.cos(angle) * CageConfig.TIMER_RADIUS_PIXELS,
			center + math.sin(angle) * CageConfig.TIMER_RADIUS_PIXELS
		)
		segment.Size = UDim2.fromOffset(
			CageConfig.TIMER_SEGMENT_WIDTH_PIXELS,
			CageConfig.TIMER_SEGMENT_HEIGHT_PIXELS
		)
		segment.Rotation = math.deg(angle) + 90
		segment.BackgroundColor3 = CageConfig.TIMER_ACTIVE_COLOR
		segment.BorderSizePixel = 0
		segment.Parent = billboard
		local corner = Instance.new("UICorner")
		corner.CornerRadius = UDim.new(1, 0)
		corner.Parent = segment
		table.insert(segments, segment)
	end

	local label = Instance.new("TextLabel")
	label.Name = "Seconds"
	label.AnchorPoint = Vector2.new(0.5, 0.5)
	label.Position = UDim2.fromScale(0.5, 0.5)
	label.Size = UDim2.fromOffset(30, 18)
	label.BackgroundTransparency = 1
	label.Font = Enum.Font.GothamBold
	label.TextColor3 = Color3.new(1, 1, 1)
	label.TextStrokeColor3 = Color3.new(0, 0, 0)
	label.TextStrokeTransparency = 0.25
	label.TextScaled = true
	label.Parent = billboard
	return {
		segments = segments,
		label = label,
	}
end

local function updateTimerVisual(visual: TimerVisual, remaining: number, duration: number)
	local ratio = if duration > 0 then math.clamp(remaining / duration, 0, 1) else 0
	local activeCount = math.ceil(ratio * #visual.segments)
	for index, segment in ipairs(visual.segments) do
		local active = index <= activeCount
		segment.BackgroundColor3 = if active
			then CageConfig.TIMER_ACTIVE_COLOR
			else CageConfig.TIMER_INACTIVE_COLOR
		segment.BackgroundTransparency = if active then 0.05 else 0.65
	end
	visual.label.Text = string.format("%.1f", math.max(0, remaining))
end

local function startCageTimer(
	owner: Instance,
	record: CageRecord,
	visual: TimerVisual,
	duration: number
)
	task.spawn(function()
		while records[owner] == record do
			local remaining = record.expiresAt - Workspace:GetServerTimeNow()
			updateTimerVisual(visual, remaining, duration)
			if remaining <= 0 then
				CageService.Remove(owner)
				return
			end
			task.wait(math.min(CageConfig.TIMER_UPDATE_INTERVAL_SECONDS, remaining))
		end
	end)
end

local function playerCanRescue(player: Player, owner: Instance): boolean
	if player == owner
		or player:GetAttribute(ROLE_ATTRIBUTE) ~= ROLE_HIDER
		or player:GetAttribute(Config.CAGED_ATTRIBUTE) == true then
		return false
	end
	local character = player.Character
	if not character or character:GetAttribute(Config.CAGED_ATTRIBUTE) == true then
		return false
	end
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	return humanoid ~= nil and humanoid.Health > 0
end

function CageService.Attach(
	owner: Instance,
	character: Model,
	humanoid: Humanoid,
	rootPart: BasePart,
	captureCenter: Vector3?,
	durationSeconds: number?
): (Model?, ProximityPrompt?)
	local existing = records[owner]
	if existing and existing.character == character and existing.cage.Parent then
		positionCage(existing.cage, character, humanoid, rootPart)
		return existing.cage, existing.prompt
	end
	local duration = durationSeconds
	if duration == nil and existing then
		duration = math.max(0, existing.expiresAt - Workspace:GetServerTimeNow())
	end
	duration = duration or CageConfig.CAGE_DURATION_SECONDS
	CageService.Remove(owner)
	if duration <= 0 then
		return nil, nil
	end

	local template = getTemplate()
	if not template then
		return nil, nil
	end
	local cage = template:Clone()
	local firstPart = prepare(cage)
	if not firstPart then
		cage:Destroy()
		warn(`CageService: ServerStorage.{CageConfig.TEMPLATE_MODEL_NAME} contains no BasePart`)
		return nil, nil
	end
	local savedWalkSpeed = humanoid.WalkSpeed
	local savedAutoRotate = humanoid.AutoRotate
	local savedJumpHeight = humanoid.JumpHeight
	local savedJumpPower = humanoid.JumpPower
	local savedUseJumpPower = humanoid.UseJumpPower
	local savedRootAnchored = rootPart.Anchored
	humanoid:Move(Vector3.zero, false)
	humanoid.WalkSpeed = 0
	humanoid.AutoRotate = false
	humanoid.JumpHeight = 0
	humanoid.JumpPower = 0
	humanoid.Jump = false
	rootPart.AssemblyLinearVelocity = Vector3.zero
	rootPart.AssemblyAngularVelocity = Vector3.zero
	rootPart.Anchored = true
	if captureCenter then
		moveCharacterToCaptureCenter(character, humanoid, rootPart, captureCenter)
	end
	positionCage(cage, character, humanoid, rootPart)
	cage.Name = `Cage_{owner.Name}`
	cage:SetAttribute(OWNER_ATTRIBUTE, owner.Name)
	cage:SetAttribute(MANAGED_ATTRIBUTE, true)
	cage.Parent = cageFolder
	playCageSound(CageConfig.CAGE_ON_SOUND_TEMPLATE_NAME, cage:GetPivot().Position)

	local prompt = makePrompt(cage, firstPart, owner)
	local timerVisual = makeTimerVisual(cage)
	local record: CageRecord = {
		cage = cage,
		character = character,
		humanoid = humanoid,
		rootPart = rootPart,
		prompt = prompt,
		connections = {},
		walkSpeed = savedWalkSpeed,
		autoRotate = savedAutoRotate,
		jumpHeight = savedJumpHeight,
		jumpPower = savedJumpPower,
		useJumpPower = savedUseJumpPower,
		rootAnchored = savedRootAnchored,
		expiresAt = Workspace:GetServerTimeNow() + duration,
	}
	records[owner] = record
	owner:SetAttribute(Config.CAGED_ATTRIBUTE, true)
	if owner == character then
		HiderService.SetCaged(character, true)
	else
		character:SetAttribute(Config.CAGED_ATTRIBUTE, true)
	end
	startCageTimer(owner, record, timerVisual, duration)
	table.insert(record.connections, humanoid:GetPropertyChangedSignal("WalkSpeed"):Connect(function()
		if records[owner] == record and humanoid.WalkSpeed ~= 0 then
			record.walkSpeed = humanoid.WalkSpeed
			humanoid.WalkSpeed = 0
		end
	end))
	table.insert(record.connections, rootPart:GetPropertyChangedSignal("Anchored"):Connect(function()
		if records[owner] == record and not rootPart.Anchored then
			rootPart.Anchored = true
		end
	end))
	table.insert(record.connections, prompt.Triggered:Connect(function(player)
		if records[owner] == record and playerCanRescue(player, owner) then
			CageService.Remove(owner)
		end
	end))
	table.insert(record.connections, owner.Destroying:Connect(function()
		if records[owner] == record then
			CageService.Remove(owner)
		end
	end))
	if owner:IsA("Player") then
		table.insert(record.connections, owner.CharacterAdded:Connect(function(newCharacter)
			task.spawn(function()
				local newHumanoid = newCharacter:WaitForChild("Humanoid", 10)
				local newRootPart = newCharacter:WaitForChild("HumanoidRootPart", 10)
				task.wait()
				if records[owner] == record
					and owner.Character == newCharacter
					and newHumanoid and newHumanoid:IsA("Humanoid")
					and newRootPart and newRootPart:IsA("BasePart") then
					local remaining = math.max(
						0,
						record.expiresAt - Workspace:GetServerTimeNow()
					)
					CageService.Attach(
						owner,
						newCharacter,
						newHumanoid,
						newRootPart,
						nil,
						remaining
					)
				end
			end)
		end))
	elseif owner ~= character then
		table.insert(record.connections, character.Destroying:Connect(function()
			if records[owner] == record then
				CageService.Remove(owner)
			end
		end))
	end
	return cage, prompt
end

return CageService
