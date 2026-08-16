--!strict

local Players = game:GetService("Players")
local KeyframeSequenceProvider = game:GetService("KeyframeSequenceProvider")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local ServerStorage = game:GetService("ServerStorage")
local StarterPlayer = game:GetService("StarterPlayer")
local Workspace = game:GetService("Workspace")

local BatAttackConfig = require(ReplicatedStorage:WaitForChild("BatAttackConfig"))
local CageConfig = require(ReplicatedStorage:WaitForChild("CageConfig"))
local FistConfig = require(ReplicatedStorage:WaitForChild("FistConfig"))
local SearchConfig = require(ReplicatedStorage:WaitForChild("SeekerSearchConfig"))

type Interval = {
	Min: number,
	Max: number,
}

type WeaponSettings = {
	Weight: number,
	Chance: number,
	MinRange: number,
	MaxRange: number,
	MaxVerticalDifference: number?,
	MinFacingDot: number,
	CooldownSeconds: Interval,
	AttackAnimationName: string?,
}

type NPCWeaponConfig = {
	ENABLED: boolean,
	NPC_FOLDER_NAME: string,
	ROUND_STATE_NAME: string,
	MANAGED_NPC_ATTRIBUTE: string,
	ROLE_ATTRIBUTE: string,
	ALLOWED_ATTACKER_ROLES: {[string]: boolean},
	TARGET_ROLES_BY_ATTACKER: {[string]: {[string]: boolean}},
	ACTIVE_PHASES: {[string]: boolean},
	INITIAL_DELAY_SECONDS: Interval,
	THINK_INTERVAL_SECONDS: Interval,
	NO_TARGET_DELAY_SECONDS: Interval,
	REJECTED_ATTACK_DELAY_SECONDS: Interval,
	GLOBAL_ATTACK_GAP_SECONDS: number,
	TARGET_REUSE_DELAY_SECONDS: number,
	EQUIP_LEAD_TIME_SECONDS: number,
	POST_ATTACK_HOLD_SECONDS: number,
	MAX_TARGET_VERTICAL_DIFFERENCE: number,
	WEAPON_ORDER: {string},
	WEAPONS: {[string]: WeaponSettings},
}

local Config = require(script.Parent:WaitForChild("Config")) :: NPCWeaponConfig
local WeaponBridge = require(script.Parent:WaitForChild("WeaponBridge"))

type Controller = {
	npc: Model,
	random: Random,
	running: boolean,
	token: number,
	nextAttemptAt: number,
	tool: Tool?,
	nextPunchIsRight: boolean,
}

type Opportunity = {
	weaponName: string,
	settings: WeaponSettings,
	target: Model,
}

local NPCWeaponService = {}
local controllers: {[Model]: Controller} = {}
local lastTargetAttackAt: {[Model]: number} = {}
local nextGlobalAttackAt = 0
local controllerSerial = 0
local started = false
local studioCharacterAnimations: {[string]: Animation} = {}

local function randomInterval(random: Random, value: Interval): number
	return random:NextNumber(value.Min, value.Max)
end

local function getRoundState(): Instance?
	return ReplicatedStorage:FindFirstChild(Config.ROUND_STATE_NAME)
end

local function systemIsActive(): boolean
	if not Config.ENABLED then
		return false
	end
	local roundState = getRoundState()
	if not roundState or roundState:GetAttribute("NpcAIEnabled") ~= true then
		return false
	end
	local phase = roundState:GetAttribute("Phase")
	return type(phase) == "string" and Config.ACTIVE_PHASES[phase] == true
end

local function getCharacterRole(character: Model): string?
	local player = Players:GetPlayerFromCharacter(character)
	local role = if player
		then player:GetAttribute(Config.ROLE_ATTRIBUTE)
		else character:GetAttribute(Config.ROLE_ATTRIBUTE)
	return if type(role) == "string" then role else nil
end

local function characterIsCaged(character: Model): boolean
	if character:GetAttribute(SearchConfig.CAGED_ATTRIBUTE) == true then
		return true
	end
	local player = Players:GetPlayerFromCharacter(character)
	return player ~= nil and player:GetAttribute(SearchConfig.CAGED_ATTRIBUTE) == true
end

local function getLivingRoot(character: Model): BasePart?
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	local rootPart = character:FindFirstChild("HumanoidRootPart")
	if not character.Parent
		or not humanoid
		or humanoid.Health <= 0
		or humanoid.PlatformStand
		or character:GetAttribute(BatAttackConfig.KNOCKDOWN_ATTRIBUTE) == true
		or characterIsCaged(character)
		or not rootPart
		or not rootPart:IsA("BasePart")
		or rootPart.Anchored then
		return nil
	end
	return rootPart
end

local function npcCanAttack(npc: Model): boolean
	local npcFolder = Workspace:FindFirstChild(Config.NPC_FOLDER_NAME)
	local role = getCharacterRole(npc)
	return systemIsActive()
		and npcFolder ~= nil
		and npc.Parent == npcFolder
		and npc:GetAttribute(Config.MANAGED_NPC_ATTRIBUTE) == true
		and role ~= nil
		and Config.ALLOWED_ATTACKER_ROLES[role] == true
		and getLivingRoot(npc) ~= nil
end

local function targetIsAvailable(
	attacker: Model,
	target: Model,
	allowedRoles: {[string]: boolean},
	now: number
): boolean
	if target == attacker or not allowedRoles[getCharacterRole(target) or ""] then
		return false
	end
	local lastAttackAt = lastTargetAttackAt[target]
	if lastAttackAt and now - lastAttackAt < Config.TARGET_REUSE_DELAY_SECONDS then
		return false
	end
	return getLivingRoot(target) ~= nil
end

local function hasLineOfSight(attacker: Model, target: Model): boolean
	local attackerRoot = attacker:FindFirstChild("HumanoidRootPart")
	local targetRoot = target:FindFirstChild("HumanoidRootPart")
	if not attackerRoot or not attackerRoot:IsA("BasePart")
		or not targetRoot or not targetRoot:IsA("BasePart") then
		return false
	end
	local direction = targetRoot.Position - attackerRoot.Position
	if direction.Magnitude <= 0.05 then
		return true
	end
	local parameters = RaycastParams.new()
	parameters.FilterType = Enum.RaycastFilterType.Exclude
	parameters.FilterDescendantsInstances = { attacker }
	parameters.IgnoreWater = true
	parameters.RespectCanCollide = true
	local result = Workspace:Raycast(attackerRoot.Position, direction, parameters)
	return result == nil or result.Instance:IsDescendantOf(target)
end

local function targetFitsWeapon(
	attacker: Model,
	target: Model,
	settings: WeaponSettings,
	allowedRoles: {[string]: boolean},
	now: number
): (boolean, number)
	if not targetIsAvailable(attacker, target, allowedRoles, now) then
		return false, math.huge
	end
	local attackerRoot = getLivingRoot(attacker)
	local targetRoot = getLivingRoot(target)
	if not attackerRoot or not targetRoot then
		return false, math.huge
	end
	local offset = targetRoot.Position - attackerRoot.Position
	local maximumVerticalDifference = settings.MaxVerticalDifference
		or Config.MAX_TARGET_VERTICAL_DIFFERENCE
	if math.abs(offset.Y) > maximumVerticalDifference then
		return false, math.huge
	end
	local horizontalOffset = Vector3.new(offset.X, 0, offset.Z)
	local distance = horizontalOffset.Magnitude
	if distance < settings.MinRange or distance > settings.MaxRange then
		return false, distance
	end
	if distance > 0.05 then
		local look = attackerRoot.CFrame.LookVector
		local horizontalLook = Vector3.new(look.X, 0, look.Z)
		if horizontalLook.Magnitude <= 0.05
			or horizontalLook.Unit:Dot(horizontalOffset.Unit) < settings.MinFacingDot then
			return false, distance
		end
	end
	return hasLineOfSight(attacker, target), distance
end

local function findTarget(
	attacker: Model,
	settings: WeaponSettings,
	allowedRoles: {[string]: boolean},
	now: number
): Model?
	local bestTarget: Model? = nil
	local bestDistance = math.huge
	local checked: {[Model]: boolean} = {}
	local function consider(target: Model?)
		if not target or checked[target] then
			return
		end
		checked[target] = true
		local fits, distance = targetFitsWeapon(attacker, target, settings, allowedRoles, now)
		if fits and distance < bestDistance then
			bestDistance = distance
			bestTarget = target
		end
	end

	for _, player in ipairs(Players:GetPlayers()) do
		consider(player.Character)
	end
	local npcFolder = Workspace:FindFirstChild(Config.NPC_FOLDER_NAME)
	if npcFolder then
		for _, child in ipairs(npcFolder:GetChildren()) do
			if child:IsA("Model") then
				consider(child)
			end
		end
	end
	return bestTarget
end

local function chooseOpportunity(controller: Controller, now: number): Opportunity?
	local attackerRole = getCharacterRole(controller.npc)
	local allowedRoles = if attackerRole
		then Config.TARGET_ROLES_BY_ATTACKER[attackerRole]
		else nil
	if not allowedRoles then
		return nil
	end

	local opportunities: {Opportunity} = {}
	local totalWeight = 0
	for _, weaponName in ipairs(Config.WEAPON_ORDER) do
		local settings = Config.WEAPONS[weaponName] :: WeaponSettings
		local target = findTarget(controller.npc, settings, allowedRoles, now)
		if target then
			totalWeight += settings.Weight
			table.insert(opportunities, {
				weaponName = weaponName,
				settings = settings,
				target = target,
			})
		end
	end
	if totalWeight <= 0 then
		return nil
	end

	local roll = controller.random:NextNumber(0, totalWeight)
	for _, opportunity in ipairs(opportunities) do
		roll -= opportunity.settings.Weight
		if roll <= 0 then
			return opportunity
		end
	end
	return opportunities[#opportunities]
end

local function destroyTool(controller: Controller)
	local tool = controller.tool
	controller.tool = nil
	if tool then
		tool:Destroy()
	end
	if controller.npc.Parent
		and (controllers[controller.npc] == controller or controllers[controller.npc] == nil) then
		controller.npc:SetAttribute("NpcWeaponName", nil)
		controller.npc:SetAttribute("NpcWeaponBusy", nil)
	end
end

local function setState(controller: Controller, state: string, target: Model?)
	if not controller.npc.Parent or controllers[controller.npc] ~= controller then
		return
	end
	controller.npc:SetAttribute("NpcWeaponState", state)
	controller.npc:SetAttribute("NpcWeaponTarget", if target then target.Name else nil)
	controller.npc:SetAttribute("NpcWeaponNextAttackAt", controller.nextAttemptAt)
end

local function controllerIsCurrent(controller: Controller, token: number): boolean
	return controller.running
		and controller.token == token
		and controllers[controller.npc] == controller
		and controller.npc.Parent ~= nil
end

local function faceTarget(attacker: Model, target: Model): Vector3?
	local attackerRoot = attacker:FindFirstChild("HumanoidRootPart")
	local targetRoot = target:FindFirstChild("HumanoidRootPart")
	if not attackerRoot or not attackerRoot:IsA("BasePart")
		or not targetRoot or not targetRoot:IsA("BasePart") then
		return nil
	end
	local offset = targetRoot.Position - attackerRoot.Position
	local direction = Vector3.new(offset.X, 0, offset.Z)
	if direction.Magnitude <= 0.05 then
		return nil
	end
	direction = direction.Unit
	local orientation = attackerRoot:FindFirstChild("NpcSmoothTurnOrientation")
	if orientation and orientation:IsA("AlignOrientation") then
		orientation.CFrame = CFrame.lookAt(Vector3.zero, direction)
	end
	return direction
end

local function findAnimation(root: Instance, animationName: string): Animation?
	for _, descendant in ipairs(root:GetDescendants()) do
		if descendant:IsA("Animation")
			and descendant.AnimationId ~= ""
			and string.lower(descendant.Name) == string.lower(animationName) then
			return descendant
		end
	end
	return nil
end

local function findKeyframeSequence(
	root: Instance,
	animationName: string
): KeyframeSequence?
	local lowerName = string.lower(animationName)
	for _, descendant in ipairs(root:GetDescendants()) do
		if descendant:IsA("KeyframeSequence")
			and string.lower(descendant.Name) == lowerName then
			return descendant
		elseif descendant:IsA("ObjectValue")
			and string.lower(descendant.Name) == lowerName
			and descendant.Value
			and descendant.Value:IsA("KeyframeSequence") then
			return descendant.Value
		end
	end
	return nil
end

local function findCharacterAnimation(character: Model, animationName: string): Animation?
	local animate = character:FindFirstChild("Animate")
	local starterScripts = StarterPlayer:FindFirstChild("StarterCharacterScripts")
	local starterAnimate = if starterScripts
		then starterScripts:FindFirstChild("Animate")
		else nil
	local containers: {Instance} = {}
	if animate then
		table.insert(containers, animate)
	end
	table.insert(containers, character)
	if starterAnimate then
		table.insert(containers, starterAnimate)
	end
	for _, container in ipairs(containers) do
		local animation = findAnimation(container, animationName)
		if animation then
			return animation
		end
	end

	local cacheKey = string.lower(animationName)
	if studioCharacterAnimations[cacheKey] then
		return studioCharacterAnimations[cacheKey]
	end
	if not RunService:IsStudio() then
		return nil
	end
	local sequence: KeyframeSequence? = nil
	for _, container in ipairs(containers) do
		sequence = findKeyframeSequence(container, animationName)
		if sequence then
			break
		end
	end
	if not sequence then
		return nil
	end
	local succeeded, temporaryId = pcall(function()
		return KeyframeSequenceProvider:RegisterKeyframeSequence(sequence)
	end)
	if not succeeded then
		return nil
	end
	local animation = Instance.new("Animation")
	animation.Name = animationName
	animation.AnimationId = temporaryId
	studioCharacterAnimations[cacheKey] = animation
	return animation
end

local function playAttackAnimation(
	controller: Controller,
	tool: Tool,
	settings: WeaponSettings
)
	local isFistAttack = tool.Name == FistConfig.WEAPON_MODEL_NAME
	local animationName = if isFistAttack
		then (if controller.nextPunchIsRight
			then FistConfig.RIGHT_PUNCH_ANIMATION_NAME
			else FistConfig.LEFT_PUNCH_ANIMATION_NAME)
		else settings.AttackAnimationName
	if not animationName then
		return
	end
	local animation = if isFistAttack
		then findCharacterAnimation(controller.npc, animationName)
		else findAnimation(tool, animationName)
	if not animation and tool.Name == CageConfig.WEAPON_MODEL_NAME then
		local batTemplate = ServerStorage:FindFirstChild(BatAttackConfig.BAT_MODEL_NAME)
		if batTemplate then
			animation = findAnimation(batTemplate, animationName)
		end
	end
	local humanoid = controller.npc:FindFirstChildOfClass("Humanoid")
	local animator = if humanoid then humanoid:FindFirstChildOfClass("Animator") else nil
	if not animation or not humanoid or humanoid.Health <= 0 or not animator then
		return
	end
	local succeeded, track = pcall(function()
		return animator:LoadAnimation(animation)
	end)
	if not succeeded or not track then
		return
	end
	if isFistAttack then
		controller.nextPunchIsRight = not controller.nextPunchIsRight
	end
	track.Priority = if isFistAttack
		then FistConfig.ATTACK_ANIMATION_PRIORITY
		else Enum.AnimationPriority.Action
	track.Looped = false
	track:Play(
		if isFistAttack then FistConfig.ATTACK_FADE_SECONDS else 0.05,
		1,
		if isFistAttack then FistConfig.ATTACK_ANIMATION_SPEED else 1
	)
	track.Ended:Once(function()
		track:Destroy()
	end)
end

local function rememberTargetAttack(target: Model, now: number)
	if lastTargetAttackAt[target] == nil then
		target.Destroying:Connect(function()
			lastTargetAttackAt[target] = nil
		end)
	end
	lastTargetAttackAt[target] = now
end

local function scheduleDelay(controller: Controller, value: Interval, state: string)
	controller.nextAttemptAt = os.clock() + randomInterval(controller.random, value)
	setState(controller, state, nil)
end

local function performAttempt(controller: Controller)
	destroyTool(controller)
	if not npcCanAttack(controller.npc) or not WeaponBridge.IsReady() then
		scheduleDelay(controller, Config.NO_TARGET_DELAY_SECONDS, "Waiting")
		return
	end

	local now = os.clock()
	if now < nextGlobalAttackAt then
		controller.nextAttemptAt = nextGlobalAttackAt
			+ controller.random:NextNumber(0, Config.THINK_INTERVAL_SECONDS.Max)
		setState(controller, "Waiting", nil)
		return
	end
	local opportunity = chooseOpportunity(controller, now)
	if not opportunity or controller.random:NextNumber() > opportunity.settings.Chance then
		scheduleDelay(controller, Config.NO_TARGET_DELAY_SECONDS, "Watching")
		return
	end

	-- Reserve the shared window before yielding for equip/aim. This prevents
	-- several NPC coroutines from preparing attacks at the same time.
	nextGlobalAttackAt = now + Config.GLOBAL_ATTACK_GAP_SECONDS
	controller.token += 1
	local token = controller.token
	controller.npc:SetAttribute("NpcWeaponBusy", true)
	setState(controller, "Equipping", opportunity.target)

	local tool = WeaponBridge.EquipWeapon(controller.npc, opportunity.weaponName)
	if not tool or not controllerIsCurrent(controller, token) then
		if tool then
			tool:Destroy()
		end
		destroyTool(controller)
		scheduleDelay(controller, Config.REJECTED_ATTACK_DELAY_SECONDS, "Waiting")
		return
	end
	controller.tool = tool
	controller.npc:SetAttribute("NpcWeaponName", opportunity.weaponName)
	faceTarget(controller.npc, opportunity.target)
	task.wait(Config.EQUIP_LEAD_TIME_SECONDS)

	local attackerRole = getCharacterRole(controller.npc)
	local allowedRoles = if attackerRole
		then Config.TARGET_ROLES_BY_ATTACKER[attackerRole]
		else nil
	local targetStillFits = false
	if allowedRoles then
		targetStillFits = targetFitsWeapon(
			controller.npc,
			opportunity.target,
			opportunity.settings,
			allowedRoles,
			os.clock()
		)
	end
	if not controllerIsCurrent(controller, token)
		or not npcCanAttack(controller.npc)
		or tool.Parent ~= controller.npc
		or not targetStillFits then
		destroyTool(controller)
		scheduleDelay(controller, Config.REJECTED_ATTACK_DELAY_SECONDS, "Waiting")
		return
	end

	local direction = faceTarget(controller.npc, opportunity.target)
	if not direction then
		destroyTool(controller)
		scheduleDelay(controller, Config.REJECTED_ATTACK_DELAY_SECONDS, "Waiting")
		return
	end
	playAttackAnimation(controller, tool, opportunity.settings)
	setState(controller, "Attacking", opportunity.target)
	local accepted = WeaponBridge.Attack(controller.npc, direction, opportunity.target)
	if accepted then
		local attackTime = os.clock()
		rememberTargetAttack(opportunity.target, attackTime)
		controller.nextAttemptAt = attackTime
			+ randomInterval(controller.random, opportunity.settings.CooldownSeconds)
		setState(controller, "Cooldown", nil)
	else
		scheduleDelay(controller, Config.REJECTED_ATTACK_DELAY_SECONDS, "Waiting")
	end

	task.wait(Config.POST_ATTACK_HOLD_SECONDS)
	if controllerIsCurrent(controller, token) then
		destroyTool(controller)
		setState(controller, if accepted then "Cooldown" else "Waiting", nil)
	end
end

local function runController(controller: Controller)
	while controller.running
		and controller.npc.Parent
		and controllers[controller.npc] == controller do
		if os.clock() >= controller.nextAttemptAt then
			local succeeded, message = xpcall(function()
				performAttempt(controller)
			end, debug.traceback)
			if not succeeded then
				warn(`NPC weapon error for {controller.npc:GetFullName()}:\n{message}`)
				destroyTool(controller)
				scheduleDelay(controller, Config.REJECTED_ATTACK_DELAY_SECONDS, "Waiting")
			end
		end
		task.wait(randomInterval(controller.random, Config.THINK_INTERVAL_SECONDS))
	end
end

function NPCWeaponService.StartNpc(npc: Model)
	local npcFolder = Workspace:FindFirstChild(Config.NPC_FOLDER_NAME)
	if controllers[npc]
		or npcFolder == nil
		or npc.Parent ~= npcFolder
		or npc:GetAttribute(Config.MANAGED_NPC_ATTRIBUTE) ~= true
		or Config.ALLOWED_ATTACKER_ROLES[getCharacterRole(npc) or ""] ~= true then
		return
	end
	controllerSerial += 1
	local seed = math.floor(os.clock() * 1000000 + controllerSerial * 130363)
		% 2147483647
	local random = Random.new(math.max(seed, 1))
	local controller: Controller = {
		npc = npc,
		random = random,
		running = true,
		token = 0,
		nextAttemptAt = os.clock() + randomInterval(random, Config.INITIAL_DELAY_SECONDS),
		tool = nil,
		nextPunchIsRight = true,
	}
	controllers[npc] = controller
	setState(controller, "Waiting", nil)
	task.spawn(runController, controller)
end

function NPCWeaponService.StopNpc(npc: Model)
	local controller = controllers[npc]
	if not controller then
		return
	end
	controllers[npc] = nil
	controller.running = false
	controller.token += 1
	destroyTool(controller)
	if npc.Parent then
		npc:SetAttribute("NpcWeaponState", nil)
		npc:SetAttribute("NpcWeaponTarget", nil)
		npc:SetAttribute("NpcWeaponNextAttackAt", nil)
	end
end

function NPCWeaponService.Start()
	if started then
		return
	end
	started = true
	local folderInstance = Workspace:WaitForChild(Config.NPC_FOLDER_NAME)
	if not folderInstance:IsA("Folder") then
		warn(`NPCWeapons: Workspace.{Config.NPC_FOLDER_NAME} must be a Folder`)
		return
	end
	local npcFolder = folderInstance
	npcFolder.ChildAdded:Connect(function(child)
		if child:IsA("Model") then
			task.defer(NPCWeaponService.StartNpc, child)
		end
	end)
	npcFolder.ChildRemoved:Connect(function(child)
		if child:IsA("Model") then
			NPCWeaponService.StopNpc(child)
		end
	end)
	for _, child in ipairs(npcFolder:GetChildren()) do
		if child:IsA("Model") then
			task.defer(NPCWeaponService.StartNpc, child)
		end
	end
end

return NPCWeaponService
