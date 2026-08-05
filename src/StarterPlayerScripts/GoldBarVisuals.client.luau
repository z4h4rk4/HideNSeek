local CollectionService = game:GetService("CollectionService")
local RunService = game:GetService("RunService")

local VISUAL_TAG = "ClientSpinningGoldBar"
local MIN_ROTATION_SPEED = math.rad(90)
local MAX_ROTATION_SPEED = math.rad(150)
local UPWARD_TILT = math.rad(60)
local MAX_SPIN_DISTANCE = 200
local MAX_SPIN_DISTANCE_SQUARED = MAX_SPIN_DISTANCE ^ 2

local visualRandom = Random.new()
local spinningGoldBars = {}

local function addGoldBar(goldBar: Instance)
	if goldBar:IsA("BasePart") or goldBar:IsA("Model") then
		local pivot = goldBar:GetPivot()
		local center

		if goldBar:IsA("Model") then
			local boundsCFrame = goldBar:GetBoundingBox()
			center = boundsCFrame.Position
		else
			center = goldBar.Position
		end

		local startingAngle = visualRandom:NextNumber(0, math.pi * 2)
		local startingRotation = CFrame.Angles(0, startingAngle, 0)
			* CFrame.Angles(0, 0, UPWARD_TILT)

		goldBar:PivotTo(CFrame.new(center) * startingRotation * CFrame.new(-center) * pivot)
		spinningGoldBars[goldBar] = {
			localCenter = pivot:PointToObjectSpace(center),
			rotationSpeed = visualRandom:NextNumber(MIN_ROTATION_SPEED, MAX_ROTATION_SPEED),
		}
	end
end

local function removeGoldBar(goldBar: Instance)
	spinningGoldBars[goldBar] = nil
end

for _, goldBar in ipairs(CollectionService:GetTagged(VISUAL_TAG)) do
	addGoldBar(goldBar)
end

CollectionService:GetInstanceAddedSignal(VISUAL_TAG):Connect(addGoldBar)
CollectionService:GetInstanceRemovedSignal(VISUAL_TAG):Connect(removeGoldBar)

RunService.RenderStepped:Connect(function(deltaTime)
	local camera = workspace.CurrentCamera
	if not camera then
		return
	end

	for goldBar, visualData in pairs(spinningGoldBars) do
		if goldBar:IsDescendantOf(workspace) then
			local currentPivot = goldBar:GetPivot()
			local center = currentPivot:PointToWorldSpace(visualData.localCenter)
			local cameraOffset = center - camera.CFrame.Position

			if cameraOffset:Dot(cameraOffset) <= MAX_SPIN_DISTANCE_SQUARED then
				local rotation = CFrame.Angles(0, visualData.rotationSpeed * deltaTime, 0)
				local rotatedPivot = CFrame.new(center) * rotation * CFrame.new(-center) * currentPivot
				goldBar:PivotTo(rotatedPivot)
			end
		else
			spinningGoldBars[goldBar] = nil
		end
	end
end)
