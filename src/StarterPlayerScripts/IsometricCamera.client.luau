local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local CAMERA_OFFSET = Vector3.new(0, 40, 10)
local FOCUS_OFFSET = Vector3.new(0, 3, 0)
local FIELD_OF_VIEW = 35
local FOLLOW_SHARPNESS = 10

local localPlayer = Players.LocalPlayer
local rootPart: BasePart? = nil
local smoothedFocus: Vector3? = nil

local function setCharacter(character: Model)
	rootPart = nil

	local characterRoot = character:WaitForChild("HumanoidRootPart", 10)
	if character ~= localPlayer.Character or not characterRoot or not characterRoot:IsA("BasePart") then
		return
	end

	rootPart = characterRoot
	smoothedFocus = characterRoot.Position + FOCUS_OFFSET
end

localPlayer.CharacterAdded:Connect(function(character)
	task.spawn(setCharacter, character)
end)

localPlayer.CharacterRemoving:Connect(function(character)
	if rootPart and rootPart:IsDescendantOf(character) then
		rootPart = nil
	end
end)

if localPlayer.Character then
	task.spawn(setCharacter, localPlayer.Character)
end

RunService:BindToRenderStep("IsometricCamera", Enum.RenderPriority.Camera.Value + 1, function(deltaTime)
	local camera = workspace.CurrentCamera
	if not camera or not rootPart or not rootPart.Parent then
		return
	end

	local targetFocus = rootPart.Position + FOCUS_OFFSET
	local followAlpha = 1 - math.exp(-FOLLOW_SHARPNESS * deltaTime)
	smoothedFocus = if smoothedFocus then smoothedFocus:Lerp(targetFocus, followAlpha) else targetFocus

	camera.CameraType = Enum.CameraType.Scriptable
	camera.FieldOfView = FIELD_OF_VIEW
	camera.CFrame = CFrame.lookAt(smoothedFocus + CAMERA_OFFSET, smoothedFocus)
	camera.Focus = CFrame.new(smoothedFocus)
end)
