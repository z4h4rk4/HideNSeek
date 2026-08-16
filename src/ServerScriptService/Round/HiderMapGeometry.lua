--!strict

local Workspace = game:GetService("Workspace")

local HiderConfig = require(script.Parent:WaitForChild("HiderConfig"))

export type Rectangle = {
	part: BasePart,
	cframe: CFrame,
	halfX: number,
	halfZ: number,
	hardHalfX: number,
	hardHalfZ: number,
	navHalfX: number,
	navHalfZ: number,
	area: number,
}

export type Ramp = {
	part: BasePart,
	floor: Rectangle,
	bottomPortal: Vector2,
	topPortal: Vector2,
}

export type ArenaGeometry = {
	map: Instance,
	arena: Instance,
	floors: {Rectangle},
	obstacles: {Rectangle},
	ramps: {Ramp},
	wallCount: number,
	totalFloorArea: number,
	minX: number,
	maxX: number,
	minZ: number,
	maxZ: number,
	revision: number,
}

export type Destination = {
	position: Vector3,
	sectorId: string,
}

local HiderMapGeometry = {}
local geometries: {ArenaGeometry} = {}
local trackedConnections: {RBXScriptConnection} = {}
local cacheDirty = true
local revision = 0

local function toPoint2(position: Vector3): Vector2
	return Vector2.new(position.X, position.Z)
end

local function toPoint3(point: Vector2, y: number): Vector3
	return Vector3.new(point.X, y, point.Y)
end

local function isContainer(instance: Instance): boolean
	return instance:IsA("Folder") or instance:IsA("Model") or instance:IsA("BasePart")
end

local function belongsToMap(instance: Instance): boolean
	local current: Instance? = instance
	while current and current ~= Workspace do
		if current.Name == HiderConfig.MAP_CONTAINER_NAME then
			return true
		end
		current = current.Parent
	end
	return false
end

Workspace.DescendantAdded:Connect(function(descendant)
	if belongsToMap(descendant) then
		cacheDirty = true
	end
end)

Workspace.DescendantRemoving:Connect(function(descendant)
	if belongsToMap(descendant) then
		cacheDirty = true
	end
end)

local function collectParts(container: Instance): {BasePart}
	local parts: {BasePart} = {}
	if container:IsA("BasePart") then
		table.insert(parts, container)
	end
	for _, descendant in ipairs(container:GetDescendants()) do
		if descendant:IsA("BasePart") then
			table.insert(parts, descendant)
		end
	end
	return parts
end

local function makeRectangle(part: BasePart, obstacle: boolean): Rectangle?
	if part.Size.X < HiderConfig.MIN_GEOMETRY_SIZE or part.Size.Z < HiderConfig.MIN_GEOMETRY_SIZE then
		return nil
	end
	if math.abs(part.CFrame.UpVector.Y) < HiderConfig.MIN_UP_VECTOR_Y then
		warn(`HiderMapGeometry: skipped tilted part {part:GetFullName()}; the navigation map must be flat`)
		return nil
	end
	local halfX = part.Size.X * 0.5
	local halfZ = part.Size.Z * 0.5
	local hardAddition = if obstacle then HiderConfig.BODY_RADIUS else 0
	local navAddition = if obstacle then HiderConfig.BODY_RADIUS + HiderConfig.SAFETY_MARGIN else 0
	return {
		part = part,
		cframe = part.CFrame,
		halfX = halfX,
		halfZ = halfZ,
		hardHalfX = halfX + hardAddition,
		hardHalfZ = halfZ + hardAddition,
		navHalfX = halfX + navAddition,
		navHalfZ = halfZ + navAddition,
		area = part.Size.X * part.Size.Z,
	}
end

local function makeRampSideObstacle(
	part: BasePart,
	cframe: CFrame,
	halfLength: number
): Rectangle
	local hardAddition = HiderConfig.BODY_RADIUS
	local navAddition = HiderConfig.BODY_RADIUS + HiderConfig.SAFETY_MARGIN
	return {
		part = part,
		cframe = cframe,
		halfX = halfLength,
		halfZ = 0,
		hardHalfX = halfLength + hardAddition,
		hardHalfZ = hardAddition,
		navHalfX = halfLength + navAddition,
		navHalfZ = navAddition,
		area = 0,
	}
end

local function makeRamp(part: BasePart): (Ramp?, {Rectangle})
	if not part.CanCollide then
		warn(`HiderMapGeometry: skipped ramp {part:GetFullName()}; ramp parts must have CanCollide enabled`)
		return nil, {}
	end
	local upVector = part.CFrame.UpVector
	if upVector.Y < HiderConfig.MIN_RAMP_UP_VECTOR_Y then
		warn(`HiderMapGeometry: skipped ramp {part:GetFullName()}; the slope is too steep`)
		return nil, {}
	end

	local rightVector = part.CFrame.RightVector
	local lookVector = part.CFrame.LookVector
	local rightRise = math.abs(rightVector.Y) * part.Size.X
	local lookRise = math.abs(lookVector.Y) * part.Size.Z
	local slopeAxis: Vector3
	local slopeSize: number
	local widthSize: number
	if rightRise >= lookRise then
		slopeAxis = rightVector
		slopeSize = part.Size.X
		widthSize = part.Size.Z
	else
		slopeAxis = lookVector
		slopeSize = part.Size.Z
		widthSize = part.Size.X
	end
	local rise = math.abs(slopeAxis.Y) * slopeSize
	if rise < HiderConfig.MIN_RAMP_RISE then
		warn(`HiderMapGeometry: skipped ramp {part:GetFullName()}; the part is not tilted`)
		return nil, {}
	end
	if slopeAxis.Y < 0 then
		slopeAxis = -slopeAxis
	end

	local slopeDirection = Vector2.new(slopeAxis.X, slopeAxis.Z)
	local horizontalScale = slopeDirection.Magnitude
	if horizontalScale <= HiderConfig.GEOMETRY_EPSILON then
		warn(`HiderMapGeometry: skipped ramp {part:GetFullName()}; it has no horizontal slope span`)
		return nil, {}
	end
	slopeDirection /= horizontalScale
	local widthDirection = Vector2.new(-slopeDirection.Y, slopeDirection.X)
	local halfLength = slopeSize * horizontalScale * 0.5
	local halfWidth = widthSize * 0.5
	if halfLength < HiderConfig.MIN_GEOMETRY_SIZE
		or halfWidth <= HiderConfig.BODY_RADIUS + HiderConfig.GEOMETRY_EPSILON then
		warn(`HiderMapGeometry: skipped ramp {part:GetFullName()}; it is too small for an NPC`)
		return nil, {}
	end

	local slopeWorld = Vector3.new(slopeDirection.X, 0, slopeDirection.Y)
	local widthWorld = Vector3.new(widthDirection.X, 0, widthDirection.Y)
	local footprintCFrame = CFrame.fromMatrix(
		part.Position,
		slopeWorld,
		Vector3.yAxis,
		widthWorld
	)
	local floor: Rectangle = {
		part = part,
		cframe = footprintCFrame,
		halfX = halfLength,
		halfZ = halfWidth,
		hardHalfX = halfLength,
		hardHalfZ = halfWidth,
		navHalfX = halfLength,
		navHalfZ = halfWidth,
		-- Ramps extend navigable coverage but are not selected as idle wander
		-- destinations. NPCs use them only when a route crosses the surface.
		area = 0,
	}
	local inset = math.min(HiderConfig.RAMP_PORTAL_INSET, halfLength * 0.25)
	local center = Vector2.new(part.Position.X, part.Position.Z)
	local portalOffset = slopeDirection * (halfLength - inset)
	local leftSide = footprintCFrame * CFrame.new(0, 0, -halfWidth)
	local rightSide = footprintCFrame * CFrame.new(0, 0, halfWidth)
	return {
		part = part,
		floor = floor,
		bottomPortal = center - portalOffset,
		topPortal = center + portalOffset,
	}, {
		makeRampSideObstacle(part, leftSide, halfLength),
		makeRampSideObstacle(part, rightSide, halfLength),
	}
end

local function rectangleCorners(rectangle: Rectangle, halfX: number, halfZ: number): {Vector2}
	local corners: {Vector2} = {}
	for _, signs in ipairs({
		Vector2.new(-1, -1),
		Vector2.new(1, -1),
		Vector2.new(1, 1),
		Vector2.new(-1, 1),
	}) do
		local world = rectangle.cframe:PointToWorldSpace(Vector3.new(
			halfX * signs.X,
			0,
			halfZ * signs.Y
		))
		table.insert(corners, toPoint2(world))
	end
	return corners
end

local function updateExtents(
	minX: number,
	maxX: number,
	minZ: number,
	maxZ: number,
	rectangle: Rectangle
): (number, number, number, number)
	for _, corner in ipairs(rectangleCorners(rectangle, rectangle.halfX, rectangle.halfZ)) do
		minX = math.min(minX, corner.X)
		maxX = math.max(maxX, corner.X)
		minZ = math.min(minZ, corner.Y)
		maxZ = math.max(maxZ, corner.Y)
	end
	return minX, maxX, minZ, maxZ
end

local function trackPart(part: BasePart)
	for _, property in ipairs({ "CFrame", "Size", "CanCollide", "CanQuery" }) do
		table.insert(trackedConnections, part:GetPropertyChangedSignal(property):Connect(function()
			cacheDirty = true
		end))
	end
end

local function rebuildCache()
	for _, connection in ipairs(trackedConnections) do
		connection:Disconnect()
	end
	trackedConnections = {}
	revision += 1
	local rebuilt: {ArenaGeometry} = {}

	for _, instance in ipairs(Workspace:GetDescendants()) do
		if instance.Name ~= HiderConfig.MAP_CONTAINER_NAME or not isContainer(instance) then
			continue
		end
		local floorContainer = instance:FindFirstChild(HiderConfig.MAP_FLOOR_NAME)
		local wallsContainer = instance:FindFirstChild(HiderConfig.MAP_WALLS_NAME)
		local rampsContainer = instance:FindFirstChild(HiderConfig.MAP_RAMPS_NAME)
		if not floorContainer or not wallsContainer then
			continue
		end

		local floors: {Rectangle} = {}
		local obstacles: {Rectangle} = {}
		local ramps: {Ramp} = {}
		local totalFloorArea = 0
		local minX = math.huge
		local maxX = -math.huge
		local minZ = math.huge
		local maxZ = -math.huge

		for _, part in ipairs(collectParts(floorContainer)) do
			local rectangle = makeRectangle(part, false)
			if rectangle then
				table.insert(floors, rectangle)
				totalFloorArea += rectangle.area
				minX, maxX, minZ, maxZ = updateExtents(minX, maxX, minZ, maxZ, rectangle)
				trackPart(part)
			end
		end
		for _, part in ipairs(collectParts(wallsContainer)) do
			-- Every BasePart placed in Map/Walls is authoritative wall geometry.
			-- Search-field raycasts must see it even when the designer made the
			-- wall non-collidable for another gameplay system.
			if not part.CanQuery then
				part.CanQuery = true
			end
			local rectangle = makeRectangle(part, true)
			if rectangle then
				table.insert(obstacles, rectangle)
				trackPart(part)
			end
		end
		if rampsContainer then
			for _, part in ipairs(collectParts(rampsContainer)) do
				local ramp, sideObstacles = makeRamp(part)
				if ramp then
					table.insert(ramps, ramp)
					table.insert(floors, ramp.floor)
					for _, sideObstacle in ipairs(sideObstacles) do
						table.insert(obstacles, sideObstacle)
					end
					minX, maxX, minZ, maxZ = updateExtents(
						minX,
						maxX,
						minZ,
						maxZ,
						ramp.floor
					)
					trackPart(part)
				end
			end
		end

		if #floors > 0 and totalFloorArea > 0 then
			table.insert(rebuilt, {
				map = instance,
				arena = instance.Parent or Workspace,
				floors = floors,
				obstacles = obstacles,
				ramps = ramps,
				wallCount = #obstacles - #ramps * 2,
				totalFloorArea = totalFloorArea,
				minX = minX,
				maxX = maxX,
				minZ = minZ,
				maxZ = maxZ,
				revision = revision,
			})
		end
	end

	geometries = rebuilt
	cacheDirty = false
end

local function getGeometries(): {ArenaGeometry}
	if cacheDirty then
		rebuildCache()
	end
	return geometries
end

local function localPoint(rectangle: Rectangle, point: Vector2): Vector2
	local transformed = rectangle.cframe:PointToObjectSpace(toPoint3(point, rectangle.cframe.Position.Y))
	return Vector2.new(transformed.X, transformed.Z)
end

local function pointInsideRectangle(
	rectangle: Rectangle,
	point: Vector2,
	halfX: number,
	halfZ: number,
	epsilon: number?
): boolean
	local localPosition = localPoint(rectangle, point)
	local extra = epsilon or 0
	return math.abs(localPosition.X) <= halfX + extra
		and math.abs(localPosition.Y) <= halfZ + extra
end

local function segmentRectangleInterval(
	rectangle: Rectangle,
	startPoint: Vector2,
	endPoint: Vector2,
	halfX: number,
	halfZ: number
): (number?, number?)
	local startLocal = localPoint(rectangle, startPoint)
	local endLocal = localPoint(rectangle, endPoint)
	local delta = endLocal - startLocal
	local tMinimum = 0
	local tMaximum = 1

	local function clipAxis(startValue: number, deltaValue: number, halfExtent: number): boolean
		if math.abs(deltaValue) <= HiderConfig.GEOMETRY_EPSILON then
			return math.abs(startValue) <= halfExtent
		end
		local first = (-halfExtent - startValue) / deltaValue
		local second = (halfExtent - startValue) / deltaValue
		if first > second then
			first, second = second, first
		end
		tMinimum = math.max(tMinimum, first)
		tMaximum = math.min(tMaximum, second)
		return tMinimum <= tMaximum + HiderConfig.GEOMETRY_EPSILON
	end

	if not clipAxis(startLocal.X, delta.X, halfX)
		or not clipAxis(startLocal.Y, delta.Y, halfZ) then
		return nil, nil
	end
	return math.max(0, tMinimum), math.min(1, tMaximum)
end

local function pointInsideFloor(geometry: ArenaGeometry, point: Vector2): boolean
	for _, floor in ipairs(geometry.floors) do
		if pointInsideRectangle(floor, point, floor.halfX, floor.halfZ, HiderConfig.GEOMETRY_EPSILON) then
			return true
		end
	end
	return false
end

local function floorCoversSegment(geometry: ArenaGeometry, startPoint: Vector2, endPoint: Vector2): boolean
	local intervals: {{startAt: number, endAt: number}} = {}
	for _, floor in ipairs(geometry.floors) do
		local enterAt, exitAt = segmentRectangleInterval(
			floor,
			startPoint,
			endPoint,
			floor.halfX,
			floor.halfZ
		)
		if enterAt and exitAt then
			table.insert(intervals, { startAt = enterAt, endAt = exitAt })
		end
	end
	if #intervals == 0 then
		return false
	end
	table.sort(intervals, function(left, right)
		return left.startAt < right.startAt
	end)
	local coveredUntil = 0
	for _, interval in ipairs(intervals) do
		if interval.startAt > coveredUntil + HiderConfig.GEOMETRY_EPSILON then
			return false
		end
		coveredUntil = math.max(coveredUntil, interval.endAt)
		if coveredUntil >= 1 - HiderConfig.GEOMETRY_EPSILON then
			return true
		end
	end
	return false
end

local function obstacleBlocksSegment(
	obstacle: Rectangle,
	startPoint: Vector2,
	endPoint: Vector2,
	allowStartEscape: boolean
): boolean
	local navEnter = segmentRectangleInterval(
		obstacle,
		startPoint,
		endPoint,
		obstacle.navHalfX,
		obstacle.navHalfZ
	)
	if not navEnter then
		return false
	end

	local startInsideNav = pointInsideRectangle(
		obstacle,
		startPoint,
		obstacle.navHalfX,
		obstacle.navHalfZ
	)
	local endInsideNav = pointInsideRectangle(
		obstacle,
		endPoint,
		obstacle.navHalfX,
		obstacle.navHalfZ
	)
	if allowStartEscape and startInsideNav and not endInsideNav then
		-- A spawn may already overlap the preferred body/safety band. Let the
		-- first dynamic edge leave that band, but never let it cross the real
		-- wall footprint. Without this exception Start has zero graph links.
		local realWallEnter = segmentRectangleInterval(
			obstacle,
			startPoint,
			endPoint,
			obstacle.halfX,
			obstacle.halfZ
		)
		return realWallEnter ~= nil
	end
	return true
end

function HiderMapGeometry.GetRevision(): number
	if cacheDirty then
		rebuildCache()
	end
	return revision
end

function HiderMapGeometry.GetAll(): {ArenaGeometry}
	return getGeometries()
end

function HiderMapGeometry.GetForPosition(position: Vector3): ArenaGeometry?
	local point = toPoint2(position)
	local selected: ArenaGeometry? = nil
	local bestDistance = HiderConfig.MAX_ARENA_DISTANCE
	for _, geometry in ipairs(getGeometries()) do
		for _, floor in ipairs(geometry.floors) do
			local localPosition = localPoint(floor, point)
			local dx = math.max(0, math.abs(localPosition.X) - floor.halfX)
			local dz = math.max(0, math.abs(localPosition.Y) - floor.halfZ)
			local vertical = math.abs(position.Y - floor.part.Position.Y)
			local distance = Vector2.new(dx, dz).Magnitude + vertical * 0.25
			if distance < bestDistance then
				bestDistance = distance
				selected = geometry
			end
		end
	end
	return selected
end

function HiderMapGeometry.ContainsPosition(
	geometry: ArenaGeometry,
	position: Vector3
): boolean
	return pointInsideFloor(geometry, toPoint2(position))
end

function HiderMapGeometry.PointIsNavigable(geometry: ArenaGeometry, point: Vector2): boolean
	if not pointInsideFloor(geometry, point) then
		return false
	end
	for _, obstacle in ipairs(geometry.obstacles) do
		if pointInsideRectangle(
			obstacle,
			point,
			obstacle.navHalfX,
			obstacle.navHalfZ,
			HiderConfig.GEOMETRY_EPSILON
		) then
			return false
		end
	end
	return true
end

function HiderMapGeometry.SegmentIsNavigable(
	geometry: ArenaGeometry,
	startPoint: Vector2,
	endPoint: Vector2,
	allowStartEscape: boolean?
): boolean
	local offset = endPoint - startPoint
	if offset.Magnitude <= HiderConfig.GEOMETRY_EPSILON then
		return HiderMapGeometry.PointIsNavigable(geometry, endPoint)
	end

	if not floorCoversSegment(geometry, startPoint, endPoint) then
		return false
	end
	local right = Vector2.new(-offset.Y, offset.X).Unit * HiderConfig.FLOOR_EDGE_CLEARANCE
	if not floorCoversSegment(geometry, startPoint + right, endPoint + right)
		or not floorCoversSegment(geometry, startPoint - right, endPoint - right) then
		return false
	end

	for _, obstacle in ipairs(geometry.obstacles) do
		if obstacleBlocksSegment(obstacle, startPoint, endPoint, allowStartEscape == true) then
			return false
		end
	end
	return true
end

function HiderMapGeometry.GetNavigationCorners(obstacle: Rectangle, outset: number): {Vector2}
	return rectangleCorners(
		obstacle,
		obstacle.navHalfX + outset,
		obstacle.navHalfZ + outset
	)
end

function HiderMapGeometry.GetNavigationBoundary(obstacle: Rectangle): {Vector2}
	return rectangleCorners(obstacle, obstacle.navHalfX, obstacle.navHalfZ)
end

function HiderMapGeometry.GetSectorId(geometry: ArenaGeometry, position: Vector3): string
	local point = toPoint2(position)
	local xRatio = math.clamp(
		(point.X - geometry.minX) / math.max(geometry.maxX - geometry.minX, 0.01),
		0,
		0.999
	)
	local zRatio = math.clamp(
		(point.Y - geometry.minZ) / math.max(geometry.maxZ - geometry.minZ, 0.01),
		0,
		0.999
	)
	local sectorX = math.floor(xRatio * HiderConfig.WANDER_SECTOR_COUNT)
	local sectorZ = math.floor(zRatio * HiderConfig.WANDER_SECTOR_COUNT)
	return `{geometry.map:GetFullName()}:{sectorX}:{sectorZ}`
end

function HiderMapGeometry.SampleDestination(
	geometry: ArenaGeometry,
	random: Random
): Destination?
	for _ = 1, HiderConfig.FLOOR_SAMPLE_ATTEMPTS do
		local roll = random:NextNumber(0, geometry.totalFloorArea)
		local selected = geometry.floors[#geometry.floors]
		local accumulated = 0
		for _, floor in ipairs(geometry.floors) do
			accumulated += floor.area
			if roll <= accumulated then
				selected = floor
				break
			end
		end

		local margin = HiderConfig.FLOOR_TARGET_EDGE_MARGIN
		local halfX = math.max(0, selected.halfX - math.min(margin, selected.halfX * 0.45))
		local halfZ = math.max(0, selected.halfZ - math.min(margin, selected.halfZ * 0.45))
		local localX = random:NextNumber(-halfX, halfX)
		local localZ = random:NextNumber(-halfZ, halfZ)
		local world = selected.cframe:PointToWorldSpace(Vector3.new(localX, selected.part.Size.Y * 0.5, localZ))
		local point = toPoint2(world)

		local overlapCount = 0
		for _, floor in ipairs(geometry.floors) do
			if pointInsideRectangle(floor, point, floor.halfX, floor.halfZ) then
				overlapCount += 1
			end
		end
		if overlapCount > 1 and random:NextNumber() > 1 / overlapCount then
			continue
		end
		if not HiderMapGeometry.PointIsNavigable(geometry, point) then
			continue
		end

		return {
			position = world,
			sectorId = HiderMapGeometry.GetSectorId(geometry, world),
		}
	end
	return nil
end

return HiderMapGeometry
