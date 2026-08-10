local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local SeekerSearchConfig = require(ReplicatedStorage:WaitForChild("SeekerSearchConfig"))
local LeakConfig = require(ReplicatedStorage:WaitForChild("LeakConfig"))

local ASSETS_FOLDER_NAME = "LeaksVisualAssets"
local NPC_FOLDER_NAME = "RoundNPCs"
local MANAGED_NPC_ATTRIBUTE = "ManagedRoundNPC"
local ROLE_ATTRIBUTE = "RoundRole"
local HIDER_ROLE = "Hider"
local PRESERVE_VISUAL_ATTRIBUTE = SeekerSearchConfig.PRESERVE_VISUAL_ATTRIBUTE
local LEAK_NAMES = {
	leak = true,
	leaks = true,
}

local FOOT_SIDE_OFFSET = 0.45
local FOOTPRINT_SIZE = Vector3.new(1, 0.02, 1.7)
local SURFACE_OFFSET = 0.02

local assetsFolder = ReplicatedStorage:WaitForChild(ASSETS_FOLDER_NAME, 10)
if not assetsFolder then
	warn(`LeaksVisuals: ReplicatedStorage.{ASSETS_FOLDER_NAME} not found`)
	return
end

local leaksVfxTemplate = assetsFolder:FindFirstChild("LeaksVFX")
local leftFootprintAsset = assetsFolder:FindFirstChild("Left")
local rightFootprintAsset = assetsFolder:FindFirstChild("Right")

if not leaksVfxTemplate then
	warn("LeaksVisuals: LeaksVFX template not found")
	return
end

local function getFootprintData(asset: Instance?, assetName: string)
	if not asset then
		warn(`LeaksVisuals: {assetName} footprint asset not found`)
		return nil
	end

	local decal = if asset:IsA("Decal") then asset else asset:FindFirstChildWhichIsA("Decal", true)
	if not decal then
		warn(`LeaksVisuals: {assetName} must contain a Decal`)
		return nil
	end

	local footprintSize = FOOTPRINT_SIZE
	if asset:IsA("BasePart") then
		footprintSize = Vector3.new(asset.Size.X, FOOTPRINT_SIZE.Y, asset.Size.Z)
	elseif asset:IsA("Model") then
		local assetSize = asset:GetExtentsSize()
		footprintSize = Vector3.new(assetSize.X, FOOTPRINT_SIZE.Y, assetSize.Z)
	end

	return {
		decal = decal,
		size = footprintSize,
	}
end

local leftFootprint = getFootprintData(leftFootprintAsset, "Left")
local rightFootprint = getFootprintData(rightFootprintAsset, "Right")

local oldFootprintFolder = workspace:FindFirstChild("LocalLeakFootprints")
if oldFootprintFolder then
	oldFootprintFolder:Destroy()
end

local footprintFolder = Instance.new("Folder")
footprintFolder.Name = "LocalLeakFootprints"
footprintFolder.Parent = workspace

local trackers = {}
local pendingCharacters = {}

local function isHiderCharacter(character: Model): boolean
	local player = Players:GetPlayerFromCharacter(character)
	if player then
		return player:GetAttribute(ROLE_ATTRIBUTE) == HIDER_ROLE
	end

	local npcFolder = workspace:FindFirstChild(NPC_FOLDER_NAME)
	return npcFolder ~= nil
		and character.Parent == npcFolder
		and character:GetAttribute(MANAGED_NPC_ATTRIBUTE) == true
		and character:GetAttribute(ROLE_ATTRIBUTE) == HIDER_ROLE
end

local function setVfxEnabled(vfx: Instance, enabled: boolean)
	local function updateObject(object: Instance)
		if
			object:IsA("ParticleEmitter")
			or object:IsA("Trail")
			or object:IsA("Beam")
			or object:IsA("Smoke")
			or object:IsA("Fire")
			or object:IsA("Sparkles")
			or object:IsA("PointLight")
			or object:IsA("SpotLight")
			or object:IsA("SurfaceLight")
			or object:IsA("Highlight")
		then
			object.Enabled = enabled
		end
	end

	updateObject(vfx)
	for _, object in ipairs(vfx:GetDescendants()) do
		updateObject(object)
	end
end

local function setVfxColor(vfx: Instance, color: Color3)
	local function updateObject(object: Instance)
		if object:IsA("BasePart") then
			object.Color = color
		elseif object:IsA("ParticleEmitter") or object:IsA("Trail") or object:IsA("Beam") then
			object.Color = ColorSequence.new(color)
		elseif object:IsA("PointLight") or object:IsA("SpotLight") or object:IsA("SurfaceLight") then
			object.Color = color
		elseif object:IsA("Smoke") then
			object.Color = color
		elseif object:IsA("Fire") then
			object.Color = color
			object.SecondaryColor = color
		elseif object:IsA("Sparkles") then
			object.SparkleColor = color
		end
	end

	updateObject(vfx)
	for _, object in ipairs(vfx:GetDescendants()) do
		updateObject(object)
	end
end

local function createVfx(character: Model, rootPart: BasePart, humanoid: Humanoid): Instance
	local feetOffset = Vector3.new(0, -(humanoid.HipHeight + rootPart.Size.Y / 2) + 0.15, 0)
	local vfx = leaksVfxTemplate:Clone()
	vfx:SetAttribute(PRESERVE_VISUAL_ATTRIBUTE, true)

	if vfx:IsA("Attachment") then
		vfx.Position += feetOffset
		vfx.Parent = rootPart
	elseif vfx:IsA("ParticleEmitter") then
		local attachment = Instance.new("Attachment")
		attachment.Name = "LeaksVFXAttachment"
		attachment.Position = feetOffset
		attachment.Parent = rootPart
		vfx.Parent = attachment
		vfx = attachment
	elseif vfx:IsA("Model") then
		local targetCFrame = rootPart.CFrame * CFrame.new(feetOffset)
		vfx.Parent = character
		vfx:PivotTo(targetCFrame)

		local boundsCFrame = vfx:GetBoundingBox()
		vfx:PivotTo(vfx:GetPivot() + (targetCFrame.Position - boundsCFrame.Position))

		for _, object in ipairs(vfx:GetDescendants()) do
			if object:IsA("BasePart") then
				object.Anchored = false
				object.CanCollide = false
				object.CanTouch = false
				object.CanQuery = false
				object.Massless = true

				local weld = Instance.new("WeldConstraint")
				weld.Part0 = rootPart
				weld.Part1 = object
				weld.Parent = object
			end
		end
	elseif vfx:IsA("BasePart") then
		vfx.Anchored = false
		vfx.CanCollide = false
		vfx.CanTouch = false
		vfx.CanQuery = false
		vfx.Massless = true
		vfx.CFrame = rootPart.CFrame * CFrame.new(feetOffset)
		vfx.Parent = character

		local weld = Instance.new("WeldConstraint")
		weld.Part0 = rootPart
		weld.Part1 = vfx
		weld.Parent = vfx
	else
		local attachment = Instance.new("Attachment")
		attachment.Name = "LeaksVFXAttachment"
		attachment.Position = feetOffset
		attachment.Parent = rootPart
		vfx.Parent = attachment
		vfx = attachment
	end

	setVfxEnabled(vfx, false)
	return vfx
end

local function isLeakPart(part: BasePart): boolean
	local current: Instance? = part

	while current and current ~= workspace do
		if LEAK_NAMES[string.lower(current.Name)] or current:GetAttribute("IsLeak") == true then
			return true
		end

		current = current.Parent
	end

	return false
end

local function getFloorHit(tracker)
	local rayLength = tracker.humanoid.HipHeight
		+ tracker.rootPart.Size.Y / 2
		+ LeakConfig.RAY_EXTRA_DISTANCE
	return workspace:Raycast(
		tracker.rootPart.Position,
		Vector3.new(0, -rayLength, 0),
		tracker.raycastParams
	)
end

local function createFootprint(
	tracker,
	raycastResult: RaycastResult,
	direction: Vector3,
	now: number
)
	local remainingWetSeconds = math.max(0, tracker.wetUntil - now)
	if remainingWetSeconds <= 0 then
		return
	end

	local normal = raycastResult.Normal
	local forward = direction - normal * direction:Dot(normal)
	if forward.Magnitude < 0.01 then
		return
	end

	forward = forward.Unit
	local right = forward:Cross(normal).Unit
	local isLeftFoot = tracker.nextFootIsLeft
	local footprint = if isLeftFoot then leftFootprint else rightFootprint
	if not footprint then
		return
	end
	local sideOffset = if isLeftFoot then -FOOT_SIDE_OFFSET else FOOT_SIDE_OFFSET
	local position = raycastResult.Position
		+ right * sideOffset
		+ normal * (footprint.size.Y / 2 + SURFACE_OFFSET)

	local holder = Instance.new("Part")
	holder.Name = if isLeftFoot then "LeftFootprint" else "RightFootprint"
	holder.Size = footprint.size
	holder.CFrame = CFrame.lookAt(position, position - forward, normal)
	holder.Anchored = true
	holder.CanCollide = false
	holder.CanTouch = false
	holder.CanQuery = false
	holder.CastShadow = false
	holder.Transparency = 1
	holder.Parent = footprintFolder

	local decal = footprint.decal:Clone()
	decal.Face = Enum.NormalId.Top
	decal.Color3 = tracker.leakColor
	local baseTransparency = decal.Transparency
	local recoveryAlpha = LeakConfig.GetRecoveryAlpha(remainingWetSeconds)
	decal.Transparency = baseTransparency + (1 - baseTransparency) * recoveryAlpha
	decal.Parent = holder

	local footprintRecord = {
		holder = holder,
		decal = decal,
		baseTransparency = baseTransparency,
		expiresAt = tracker.wetUntil,
	}
	table.insert(tracker.footprints, footprintRecord)

	tracker.nextFootIsLeft = not isLeftFoot
	tracker.lastFootprintPosition = raycastResult.Position
end

local function updateFootprints(tracker, now: number)
	for index = #tracker.footprints, 1, -1 do
		local footprint = tracker.footprints[index]
		local remainingWetSeconds = math.max(0, footprint.expiresAt - now)
		if remainingWetSeconds <= 0 or not footprint.holder.Parent then
			footprint.holder:Destroy()
			table.remove(tracker.footprints, index)
		else
			local recoveryAlpha = LeakConfig.GetRecoveryAlpha(remainingWetSeconds)
			footprint.decal.Transparency = footprint.baseTransparency
				+ (1 - footprint.baseTransparency) * recoveryAlpha
		end
	end
end

local function removeCharacter(character: Model)
	pendingCharacters[character] = nil

	local tracker = trackers[character]
	if not tracker then
		return
	end

	tracker.vfx:Destroy()
	for _, footprint in ipairs(tracker.footprints) do
		footprint.holder:Destroy()
	end

	trackers[character] = nil
end

local function trackCharacter(character: Model)
	if trackers[character] or pendingCharacters[character] or not isHiderCharacter(character) then
		return
	end

	local pendingToken = {}
	pendingCharacters[character] = pendingToken

	task.spawn(function()
		local humanoid = character:WaitForChild("Humanoid", 10)
		local rootPart = character:WaitForChild("HumanoidRootPart", 10)
		if pendingCharacters[character] ~= pendingToken then
			return
		end
		pendingCharacters[character] = nil

		if
			not character.Parent
			or not isHiderCharacter(character)
			or not humanoid
			or not humanoid:IsA("Humanoid")
			or humanoid.Health <= 0
			or not rootPart
			or not rootPart:IsA("BasePart")
		then
			return
		end

		local raycastParams = RaycastParams.new()
		raycastParams.FilterType = Enum.RaycastFilterType.Exclude
		raycastParams.FilterDescendantsInstances = { character, footprintFolder }

		trackers[character] = {
			character = character,
			humanoid = humanoid,
			rootPart = rootPart,
			raycastParams = raycastParams,
			vfx = createVfx(character, rootPart, humanoid),
			wasOnLeak = false,
			trailActive = false,
			wetUntil = 0,
			leakColor = Color3.new(1, 1, 1),
			lastFootprintPosition = nil,
			nextFootIsLeft = true,
			footprints = {},
		}
	end)
end

local function refreshCharacter(character: Model)
	if isHiderCharacter(character) then
		trackCharacter(character)
	else
		removeCharacter(character)
	end
end

local function setupPlayer(player: Player)
	player.CharacterAdded:Connect(refreshCharacter)
	player.CharacterRemoving:Connect(removeCharacter)
	player:GetAttributeChangedSignal(ROLE_ATTRIBUTE):Connect(function()
		if player.Character then
			refreshCharacter(player.Character)
		end
	end)

	if player.Character then
		refreshCharacter(player.Character)
	end
end

for _, player in ipairs(Players:GetPlayers()) do
	setupPlayer(player)
end

Players.PlayerAdded:Connect(setupPlayer)

local function refreshEligibleCharacters()
	for _, player in ipairs(Players:GetPlayers()) do
		if player.Character then
			refreshCharacter(player.Character)
		end
	end

	local npcFolder = workspace:FindFirstChild(NPC_FOLDER_NAME)
	if npcFolder then
		for _, child in ipairs(npcFolder:GetChildren()) do
			if child:IsA("Model") then
				refreshCharacter(child)
			end
		end
	end
end

local function updateTracker(tracker, now: number)
	updateFootprints(tracker, now)
	local raycastResult = getFloorHit(tracker)
	local isOnLeak = raycastResult ~= nil and isLeakPart(raycastResult.Instance)
	local velocity = tracker.rootPart.AssemblyLinearVelocity
	local horizontalVelocity = Vector3.new(velocity.X, 0, velocity.Z)
	local isMoving = horizontalVelocity.Magnitude >= LeakConfig.MIN_MOVE_SPEED

	if isOnLeak and raycastResult then
		local leakColor = raycastResult.Instance.Color
		if tracker.leakColor ~= leakColor then
			tracker.leakColor = leakColor
			setVfxColor(tracker.vfx, leakColor)
		end

		tracker.wetUntil = now + LeakConfig.TRAIL_DURATION_SECONDS
		tracker.trailActive = true

		if not tracker.wasOnLeak then
			tracker.lastFootprintPosition = nil
		end
	end

	setVfxEnabled(tracker.vfx, isOnLeak)

	if
		not isOnLeak
		and tracker.trailActive
		and now < tracker.wetUntil
		and isMoving
		and raycastResult
	then
		local lastPosition = tracker.lastFootprintPosition
		if
			not lastPosition
			or (raycastResult.Position - lastPosition).Magnitude >= LeakConfig.STEP_DISTANCE
		then
			createFootprint(tracker, raycastResult, horizontalVelocity.Unit, now)
		end
	elseif tracker.trailActive and now >= tracker.wetUntil then
		tracker.trailActive = false
		tracker.lastFootprintPosition = nil
	end

	tracker.wasOnLeak = isOnLeak
end

local accumulatedTime = 0

RunService.Heartbeat:Connect(function(deltaTime)
	accumulatedTime += deltaTime
	if accumulatedTime < LeakConfig.CLIENT_CHECK_INTERVAL_SECONDS then
		return
	end

	accumulatedTime %= LeakConfig.CLIENT_CHECK_INTERVAL_SECONDS
	local now = workspace:GetServerTimeNow()
	refreshEligibleCharacters()

	for character, tracker in pairs(trackers) do
		if character.Parent and tracker.humanoid.Health > 0 and isHiderCharacter(character) then
			updateTracker(tracker, now)
		else
			removeCharacter(character)
		end
	end
end)
