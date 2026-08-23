local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local ROUND_STATE_NAME = "RoundState"
local ROLE_ATTRIBUTE = "RoundRole"
local ROLE_HIDER = "Hider"
local ROLE_SEEKER = "Seeker"
local PHASE_STARTING = "Starting"
local PHASE_ROUND = "Round"

local CAMERA_OFFSET = Vector3.new(0, 45, 13)
local FOCUS_OFFSET = Vector3.new(0, 3, 0)
local FIELD_OF_VIEW = 35
local FOLLOW_SHARPNESS = 10
local DEFAULT_CAMERA_DISTANCE = 12
local DEFAULT_CAMERA_HEIGHT = 4
local DEFAULT_CAMERA_FOCUS_HEIGHT = 2.5

local localPlayer = Players.LocalPlayer
local roundState = ReplicatedStorage:WaitForChild(ROUND_STATE_NAME)
local rootPart: BasePart? = nil
local smoothedFocus: Vector3? = nil
local controlledCamera: Camera? = nil
local previousFieldOfView = 70

local function getCharacterHumanoid(): Humanoid?
	local character = localPlayer.Character
	return if character then character:FindFirstChildOfClass("Humanoid") else nil
end

local function getCharacterRootPart(): BasePart?
	local character = localPlayer.Character
	local characterRoot = character and character:FindFirstChild("HumanoidRootPart")
	return if characterRoot and characterRoot:IsA("BasePart") then characterRoot else nil
end

local function shouldUseIsometricCamera(): boolean
	local role = localPlayer:GetAttribute(ROLE_ATTRIBUTE)
	if role ~= ROLE_HIDER and role ~= ROLE_SEEKER then
		return false
	end

	local phase = roundState:GetAttribute("Phase")
	return phase == PHASE_STARTING or phase == PHASE_ROUND
end

local function bindDefaultCameraSubject(camera: Camera?)
	if not camera then
		return
	end

	camera.CameraType = Enum.CameraType.Custom
	local humanoid = getCharacterHumanoid()
	if humanoid then
		camera.CameraSubject = humanoid
	end
end

local function resetDefaultCameraCFrame(camera: Camera)
	local characterRoot = getCharacterRootPart()
	if not characterRoot then
		return
	end

	local lookDirection = Vector3.new(characterRoot.CFrame.LookVector.X, 0, characterRoot.CFrame.LookVector.Z)
	if lookDirection.Magnitude < 0.001 then
		lookDirection = Vector3.zAxis
	else
		lookDirection = lookDirection.Unit
	end

	local focusPosition = characterRoot.Position + Vector3.new(0, DEFAULT_CAMERA_FOCUS_HEIGHT, 0)
	local cameraPosition = characterRoot.Position
		- lookDirection * DEFAULT_CAMERA_DISTANCE
		+ Vector3.new(0, DEFAULT_CAMERA_HEIGHT, 0)
	camera.CFrame = CFrame.lookAt(cameraPosition, focusPosition)
	camera.Focus = CFrame.new(focusPosition)
end

local function restoreDefaultCamera()
	local camera = controlledCamera or workspace.CurrentCamera
	local wasControlled = controlledCamera ~= nil
	controlledCamera = nil
	smoothedFocus = nil
	if not camera then
		return
	end

	if wasControlled then
		camera.FieldOfView = previousFieldOfView
	end
	bindDefaultCameraSubject(camera)
	if wasControlled then
		resetDefaultCameraCFrame(camera)
	end
end

local function beginIsometricCamera(camera: Camera)
	if controlledCamera == camera then
		return
	end
	if controlledCamera then
		restoreDefaultCamera()
	end

	controlledCamera = camera
	previousFieldOfView = camera.FieldOfView
	if rootPart then
		smoothedFocus = rootPart.Position + FOCUS_OFFSET
	end
end

local function setCharacter(character: Model)
	rootPart = nil

	local humanoid = character:WaitForChild("Humanoid", 10)
	local characterRoot = character:WaitForChild("HumanoidRootPart", 10)
	if character ~= localPlayer.Character
		or not humanoid
		or not humanoid:IsA("Humanoid")
		or not characterRoot
		or not characterRoot:IsA("BasePart") then
		return
	end

	rootPart = characterRoot
	smoothedFocus = characterRoot.Position + FOCUS_OFFSET
	if not shouldUseIsometricCamera() then
		bindDefaultCameraSubject(workspace.CurrentCamera)
	end
end

localPlayer.CharacterAdded:Connect(function(character)
	task.spawn(setCharacter, character)
end)

localPlayer.CharacterRemoving:Connect(function(character)
	if rootPart and rootPart:IsDescendantOf(character) then
		rootPart = nil
	end
	restoreDefaultCamera()
end)

if localPlayer.Character then
	task.spawn(setCharacter, localPlayer.Character)
end

workspace:GetPropertyChangedSignal("CurrentCamera"):Connect(function()
	if not shouldUseIsometricCamera() then
		bindDefaultCameraSubject(workspace.CurrentCamera)
	end
end)

RunService:BindToRenderStep("IsometricCamera", Enum.RenderPriority.Camera.Value + 1, function(deltaTime)
	local camera = workspace.CurrentCamera
	if not camera then
		restoreDefaultCamera()
		return
	end
	if not shouldUseIsometricCamera() or not rootPart or not rootPart.Parent then
		restoreDefaultCamera()
		return
	end
	beginIsometricCamera(camera)

	local targetFocus = rootPart.Position + FOCUS_OFFSET
	local followAlpha = 1 - math.exp(-FOLLOW_SHARPNESS * deltaTime)
	smoothedFocus = if smoothedFocus then smoothedFocus:Lerp(targetFocus, followAlpha) else targetFocus

	camera.CameraType = Enum.CameraType.Scriptable
	camera.FieldOfView = FIELD_OF_VIEW
	camera.CFrame = CFrame.lookAt(smoothedFocus + CAMERA_OFFSET, smoothedFocus)
	camera.Focus = CFrame.new(smoothedFocus)
end)
