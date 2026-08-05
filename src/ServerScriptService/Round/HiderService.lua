--!strict

local RunService = game:GetService("RunService")

local HiderAnimation = require(script.Parent:WaitForChild("HiderAnimation"))
local HiderBrain = require(script.Parent:WaitForChild("HiderBrain"))
local HiderConfig = require(script.Parent:WaitForChild("HiderConfig"))
local HiderVisibilityGraph = require(script.Parent:WaitForChild("HiderVisibilityGraph"))

local HiderService = {}
local controllers: {[Model]: HiderBrain.Controller} = {}
local cagedNpcs: {[Model]: boolean} = {}
local currentPhase = "Waiting"
local adminEnabled = true

task.defer(function()
	local succeeded, message = xpcall(HiderVisibilityGraph.PrepareAll, debug.traceback)
	if not succeeded then
		warn(`Hider navigation graph preparation failed:\n{message}`)
	end
end)

local function shouldNpcMove(npc: Model): boolean
	if not adminEnabled or cagedNpcs[npc] == true then
		return false
	end
	if currentPhase == HiderConfig.ROUND_PHASE then
		return true
	end
	return currentPhase == HiderConfig.STARTING_PHASE
		and npc:GetAttribute("RoundRole") == HiderConfig.ROLE_HIDER
end

local function run(controller: HiderBrain.Controller)
	while controller.running and controller.npc.Parent and controllers[controller.npc] == controller do
		local succeeded, message = xpcall(function()
			HiderBrain.Step(controller)
		end, debug.traceback)
		if not succeeded then
			warn(`Round NPC AI error in {controller.npc:GetFullName()}:\n{message}`)
			task.wait(0.5)
		else
			RunService.Heartbeat:Wait()
		end
	end
end

function HiderService.Start(npc: Model)
	local role = npc:GetAttribute("RoundRole")
	if controllers[npc]
		or (role ~= HiderConfig.ROLE_HIDER and role ~= HiderConfig.ROLE_SEEKER) then
		return
	end
	local controller = HiderBrain.New(npc)
	if not controller then
		warn(`Round NPC service: {npc:GetFullName()} needs a living Humanoid and HumanoidRootPart`)
		return
	end
	controllers[npc] = controller
	HiderAnimation.Start(npc)
	HiderBrain.SetActive(controller, shouldNpcMove(npc))
	task.spawn(run, controller)
end

function HiderService.Stop(npc: Model)
	cagedNpcs[npc] = nil
	local controller = controllers[npc]
	if controller then
		controllers[npc] = nil
		HiderBrain.Destroy(controller)
	end
	HiderAnimation.Stop(npc)
end

function HiderService.SetPhase(phase: string)
	currentPhase = phase
	for npc, controller in pairs(controllers) do
		HiderBrain.SetActive(controller, shouldNpcMove(npc))
	end
end

function HiderService.SetAdminEnabled(enabled: boolean)
	adminEnabled = enabled
	for npc, controller in pairs(controllers) do
		HiderBrain.SetActive(controller, shouldNpcMove(npc))
	end
end

function HiderService.SetCaged(npc: Model, caged: boolean)
	if caged then
		cagedNpcs[npc] = true
	else
		cagedNpcs[npc] = nil
	end
	local controller = controllers[npc]
	if controller then
		HiderBrain.SetActive(controller, shouldNpcMove(npc))
	end
end

function HiderService.IsAdminEnabled(): boolean
	return adminEnabled
end

return HiderService
