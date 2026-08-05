--!strict

local ServerStorage = game:GetService("ServerStorage")
local Workspace = game:GetService("Workspace")

local TEMPLATE_NAME = "cage"
local FOLDER_NAME = "RoundCages"
local FALLBACK_FOLDER_NAME = "_RoundCages"
local OWNER_ATTRIBUTE = "CagedOwner"
local MANAGED_ATTRIBUTE = "ManagedRoundCage"
local HIDER_POSITION_NAME = "HiderPosition"
local ANCHOR_EXCLUDED_NAME_FRAGMENTS = { "door", "gate", "hinge" }

type CageRecord = {
	cage: Model,
	character: Model,
	ownerDestroyingConnection: RBXScriptConnection?,
	characterDestroyingConnection: RBXScriptConnection?,
}

local records: {[Instance]: CageRecord} = {}
local missingTemplateWarned = false
local invalidClassWarned = false
local emptyTemplateWarned = false
local cloneFailedWarned = false

local existingFolder = Workspace:FindFirstChild(FOLDER_NAME)
local cageFolder: Folder
if existingFolder and existingFolder:IsA("Folder") then
	cageFolder = existingFolder
else
	if existingFolder then
		warn(`CageService: Workspace.{FOLDER_NAME} must be a Folder; using {FALLBACK_FOLDER_NAME}`)
	end
	cageFolder = Instance.new("Folder")
	cageFolder.Name = if existingFolder then FALLBACK_FOLDER_NAME else FOLDER_NAME
	cageFolder.Parent = Workspace
end

for _, child in ipairs(cageFolder:GetChildren()) do
	if child:GetAttribute(MANAGED_ATTRIBUTE) == true then
		child:Destroy()
	end
end

local function disconnectRecord(record: CageRecord)
	if record.ownerDestroyingConnection then
		record.ownerDestroyingConnection:Disconnect()
		record.ownerDestroyingConnection = nil
	end
	if record.characterDestroyingConnection then
		record.characterDestroyingConnection:Disconnect()
		record.characterDestroyingConnection = nil
	end
end

local CageService = {}

function CageService.GetFolder(): Folder
	return cageFolder
end

function CageService.Remove(owner: Instance)
	local record = records[owner]
	if not record then
		return
	end
	records[owner] = nil
	disconnectRecord(record)
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
	for _, child in ipairs(cageFolder:GetChildren()) do
		if child:GetAttribute(MANAGED_ATTRIBUTE) == true then
			child:Destroy()
		end
	end
end

local function getTemplate(): Model?
	local template = ServerStorage:FindFirstChild(TEMPLATE_NAME)
	if not template then
		if not missingTemplateWarned then
			missingTemplateWarned = true
			warn(`CageService: ServerStorage.{TEMPLATE_NAME} was not found`)
		end
		return nil
	end
	missingTemplateWarned = false
	if not template:IsA("Model") then
		if not invalidClassWarned then
			invalidClassWarned = true
			warn(`CageService: ServerStorage.{TEMPLATE_NAME} must be a Model`)
		end
		return nil
	end
	invalidClassWarned = false
	return template
end

local function prepareCage(cage: Model): boolean
	local partCount = 0
	for _, object in ipairs(cage:GetDescendants()) do
		if object:IsA("BasePart") then
			partCount += 1
			object.Anchored = true
			object.CanCollide = false
			object.CanTouch = false
			object.CanQuery = false
			object.Massless = true
			object.AssemblyLinearVelocity = Vector3.zero
			object.AssemblyAngularVelocity = Vector3.zero
		end
	end
	return partCount > 0
end

local function getPositionMarker(cage: Model): Instance?
	for _, descendant in ipairs(cage:GetDescendants()) do
		if descendant.Name == HIDER_POSITION_NAME
			and (descendant:IsA("Attachment") or descendant:IsA("BasePart")) then
			return descendant
		end
	end
	return nil
end

local function median(values: {number}): number
	table.sort(values)
	local count = #values
	local middle = math.floor((count + 1) * 0.5)
	if count % 2 == 1 then
		return values[middle]
	end
	return (values[middle] + values[middle + 1]) * 0.5
end

local function partCanDefineInterior(part: BasePart): boolean
	if part.Name == HIDER_POSITION_NAME or part.Transparency >= 0.99 then
		return false
	end
	local lowerName = string.lower(part.Name)
	for _, fragment in ipairs(ANCHOR_EXCLUDED_NAME_FRAGMENTS) do
		if string.find(lowerName, fragment, 1, true) then
			return false
		end
	end
	return true
end

local function getStructuralCenter(cage: Model, pivot: CFrame): Vector3
	local localX: {number} = {}
	local localZ: {number} = {}
	for _, descendant in ipairs(cage:GetDescendants()) do
		if descendant:IsA("BasePart") and partCanDefineInterior(descendant) then
			local localPosition = pivot:PointToObjectSpace(descendant.Position)
			table.insert(localX, localPosition.X)
			table.insert(localZ, localPosition.Z)
		end
	end
	if #localX == 0 then
		return pivot.Position
	end
	return pivot:PointToWorldSpace(Vector3.new(median(localX), 0, median(localZ)))
end

local function positionCage(cage: Model, humanoid: Humanoid, rootPart: BasePart)
	local positionMarker = getPositionMarker(cage)
	local markerCFrame: CFrame? = nil
	if positionMarker and positionMarker:IsA("Attachment") then
		markerCFrame = positionMarker.WorldCFrame
	elseif positionMarker and positionMarker:IsA("BasePart") then
		markerCFrame = positionMarker.CFrame
	end
	if markerCFrame then
		local pivotToMarker = cage:GetPivot():ToObjectSpace(markerCFrame)
		cage:PivotTo(rootPart.CFrame * pivotToMarker:Inverse())
		return
	end

	-- The full bounds may include an open door or decoration outside the cage.
	-- Use the median center of the structural parts for X/Z so one displaced
	-- object cannot move the Hider outside. Bounds are used only for floor Y.
	local pivot = cage:GetPivot()
	local structuralCenter = getStructuralCenter(cage, pivot)
	local boundsCFrame, boundsSize = cage:GetBoundingBox()
	local sourceBottomY = boundsCFrame.Position.Y - boundsSize.Y * 0.5
	local floorY = rootPart.Position.Y
		- math.max(0, humanoid.HipHeight)
		- rootPart.Size.Y * 0.5
	local offset = Vector3.new(
		rootPart.Position.X - structuralCenter.X,
		floorY - sourceBottomY,
		rootPart.Position.Z - structuralCenter.Z
	)
	cage:PivotTo(pivot + offset)
end

function CageService.Attach(
	owner: Instance,
	character: Model,
	humanoid: Humanoid,
	rootPart: BasePart
): Model?
	local existing = records[owner]
	if existing and existing.character == character and existing.cage.Parent then
		positionCage(existing.cage, humanoid, rootPart)
		return existing.cage
	end
	CageService.Remove(owner)

	local template = getTemplate()
	if not template then
		return nil
	end
	local cloneSucceeded, cage = pcall(function(): Model?
		return template:Clone()
	end)
	if not cloneSucceeded or not cage then
		if not cloneFailedWarned then
			cloneFailedWarned = true
			warn(`CageService: ServerStorage.{TEMPLATE_NAME} could not be cloned`)
		end
		return nil
	end
	cloneFailedWarned = false
	if not prepareCage(cage) then
		cage:Destroy()
		if not emptyTemplateWarned then
			emptyTemplateWarned = true
			warn(`CageService: ServerStorage.{TEMPLATE_NAME} contains no BasePart`)
		end
		return nil
	end
	emptyTemplateWarned = false
	positionCage(cage, humanoid, rootPart)
	cage.Name = `Cage_{owner.Name}`
	cage:SetAttribute(OWNER_ATTRIBUTE, owner.Name)
	cage:SetAttribute(MANAGED_ATTRIBUTE, true)
	cage.Parent = cageFolder

	local record: CageRecord = {
		cage = cage,
		character = character,
		ownerDestroyingConnection = nil,
		characterDestroyingConnection = nil,
	}
	records[owner] = record
	record.ownerDestroyingConnection = owner.Destroying:Connect(function()
		if records[owner] == record then
			CageService.Remove(owner)
		end
	end)
	if owner ~= character then
		record.characterDestroyingConnection = character.Destroying:Connect(function()
			if records[owner] == record then
				CageService.Remove(owner)
			end
		end)
	end
	return cage
end

return CageService
