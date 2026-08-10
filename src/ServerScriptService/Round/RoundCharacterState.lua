--!strict

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local RoundConfig = require(script.Parent:WaitForChild("RoundConfig"))
local SeekerSearchConfig = require(ReplicatedStorage:WaitForChild("SeekerSearchConfig"))

local INVISIBLE_ATTRIBUTE = SeekerSearchConfig.HIDER_INVISIBLE_ATTRIBUTE
local SEEKER_LOCKED_ATTRIBUTE = "RoundSeekerLocked"

type SeekerLockRecord = {
	walkSpeed: number,
	autoRotate: boolean,
	walkSpeedConnection: RBXScriptConnection?,
	autoRotateConnection: RBXScriptConnection?,
	anchoredConnection: RBXScriptConnection?,
	destroyingConnection: RBXScriptConnection?,
}

local seekerLockRecords: {[Model]: SeekerLockRecord} = {}

local function clearSeekerLockRecord(character: Model): SeekerLockRecord?
	local record = seekerLockRecords[character]
	if record then
		seekerLockRecords[character] = nil
		if record.walkSpeedConnection then
			record.walkSpeedConnection:Disconnect()
			record.walkSpeedConnection = nil
		end
		if record.autoRotateConnection then
			record.autoRotateConnection:Disconnect()
			record.autoRotateConnection = nil
		end
		if record.anchoredConnection then
			record.anchoredConnection:Disconnect()
			record.anchoredConnection = nil
		end
		if record.destroyingConnection then
			record.destroyingConnection:Disconnect()
			record.destroyingConnection = nil
		end
	end
	return record
end

local function setSeekerLocked(character: Model, locked: boolean)
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	local rootPart = character:FindFirstChild("HumanoidRootPart")
	if locked then
		if not humanoid or not rootPart or not rootPart:IsA("BasePart") then
			return
		end

		local record = seekerLockRecords[character]
		if not record then
			record = {
				walkSpeed = humanoid.WalkSpeed,
				autoRotate = humanoid.AutoRotate,
				walkSpeedConnection = nil,
				autoRotateConnection = nil,
				anchoredConnection = nil,
				destroyingConnection = nil,
			}
			seekerLockRecords[character] = record
			record.walkSpeedConnection = humanoid:GetPropertyChangedSignal("WalkSpeed"):Connect(function()
				if seekerLockRecords[character] == record and humanoid.WalkSpeed ~= 0 then
					record.walkSpeed = humanoid.WalkSpeed
					humanoid.WalkSpeed = 0
				end
			end)
			record.autoRotateConnection = humanoid:GetPropertyChangedSignal("AutoRotate"):Connect(function()
				if seekerLockRecords[character] == record and humanoid.AutoRotate then
					record.autoRotate = true
					humanoid.AutoRotate = false
				end
			end)
			record.anchoredConnection = rootPart:GetPropertyChangedSignal("Anchored"):Connect(function()
				if seekerLockRecords[character] == record and not rootPart.Anchored then
					rootPart.Anchored = true
				end
			end)
			record.destroyingConnection = character.Destroying:Connect(function()
				clearSeekerLockRecord(character)
			end)
		end

		character:SetAttribute(SEEKER_LOCKED_ATTRIBUTE, true)
		humanoid:Move(Vector3.zero, false)
		humanoid.WalkSpeed = 0
		humanoid.AutoRotate = false
		humanoid.Jump = false
		rootPart.AssemblyLinearVelocity = Vector3.zero
		rootPart.AssemblyAngularVelocity = Vector3.zero
		rootPart.Anchored = true
		return
	end

	local record = clearSeekerLockRecord(character)
	character:SetAttribute(SEEKER_LOCKED_ATTRIBUTE, nil)
	if not record then
		return
	end
	if rootPart and rootPart:IsA("BasePart") then
		rootPart.Anchored = false
		rootPart.AssemblyLinearVelocity = Vector3.zero
		rootPart.AssemblyAngularVelocity = Vector3.zero
		pcall(function()
			if Players:GetPlayerFromCharacter(character) then
				rootPart:SetNetworkOwnershipAuto()
			else
				rootPart:SetNetworkOwner(nil)
			end
		end)
	end
	if humanoid then
		humanoid.WalkSpeed = record.walkSpeed
		humanoid.AutoRotate = record.autoRotate
		humanoid:Move(Vector3.zero, false)
		if humanoid.Health > 0 then
			humanoid:ChangeState(Enum.HumanoidStateType.Running)
		end
	end
end

local RoundCharacterState = {}

function RoundCharacterState.Apply(
	character: Model,
	role: string,
	phase: string,
	preparing: boolean
)
	character:SetAttribute(
		INVISIBLE_ATTRIBUTE,
		if role == RoundConfig.ROLE_HIDER and phase == RoundConfig.PHASE_ROUND then true else nil
	)
	setSeekerLocked(
		character,
		role == RoundConfig.ROLE_SEEKER
			and (preparing
				or phase == RoundConfig.PHASE_PREPARING
				or phase == RoundConfig.PHASE_STARTING)
	)
end

function RoundCharacterState.Clear(character: Model)
	character:SetAttribute(INVISIBLE_ATTRIBUTE, nil)
	setSeekerLocked(character, false)
end

function RoundCharacterState.IsSeekerLocked(character: Model): boolean
	return seekerLockRecords[character] ~= nil
end

return RoundCharacterState
