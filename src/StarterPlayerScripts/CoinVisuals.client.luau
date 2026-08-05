local CollectionService = game:GetService("CollectionService")
local RunService = game:GetService("RunService")

local COIN_TAG = "ClientSpinningCoin"
local MIN_ROTATION_SPEED = math.rad(130)
local MAX_ROTATION_SPEED = math.rad(150)
local UPWARD_TILT = math.rad(60)
local MAX_SPIN_DISTANCE = 200
local MAX_SPIN_DISTANCE_SQUARED = MAX_SPIN_DISTANCE ^ 2

local visualRandom = Random.new()
local spinningCoins = {}

local function addCoin(coin: Instance)
	if coin:IsA("BasePart") or coin:IsA("Model") then
		local pivot = coin:GetPivot()
		local center

		if coin:IsA("Model") then
			local boundsCFrame = coin:GetBoundingBox()
			center = boundsCFrame.Position
		else
			center = coin.Position
		end

		local startingAngle = visualRandom:NextNumber(0, math.pi * 2)
		local startingRotation = CFrame.Angles(0, startingAngle, 0)
			* CFrame.Angles(0, 0, UPWARD_TILT)

		coin:PivotTo(CFrame.new(center) * startingRotation * CFrame.new(-center) * pivot)
		spinningCoins[coin] = {
			localCenter = pivot:PointToObjectSpace(center),
			rotationSpeed = visualRandom:NextNumber(MIN_ROTATION_SPEED, MAX_ROTATION_SPEED),
		}
	end
end

local function removeCoin(coin: Instance)
	spinningCoins[coin] = nil
end

for _, coin in ipairs(CollectionService:GetTagged(COIN_TAG)) do
	addCoin(coin)
end

CollectionService:GetInstanceAddedSignal(COIN_TAG):Connect(addCoin)
CollectionService:GetInstanceRemovedSignal(COIN_TAG):Connect(removeCoin)

RunService.RenderStepped:Connect(function(deltaTime)
	local camera = workspace.CurrentCamera
	if not camera then
		return
	end

	for coin, visualData in pairs(spinningCoins) do
		if coin:IsDescendantOf(workspace) then
			local currentPivot = coin:GetPivot()
			local center = currentPivot:PointToWorldSpace(visualData.localCenter)
			local cameraOffset = center - camera.CFrame.Position

			if cameraOffset:Dot(cameraOffset) <= MAX_SPIN_DISTANCE_SQUARED then
				local rotation = CFrame.Angles(0, visualData.rotationSpeed * deltaTime, 0)
				local rotatedPivot = CFrame.new(center) * rotation * CFrame.new(-center) * currentPivot
				coin:PivotTo(rotatedPivot)
			end
		else
			spinningCoins[coin] = nil
		end
	end
end)
