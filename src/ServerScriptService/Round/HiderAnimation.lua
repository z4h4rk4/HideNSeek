--!strict

local StarterPlayer = game:GetService("StarterPlayer")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local MovementAnimationConfig = require(ReplicatedStorage:WaitForChild("MovementAnimationConfig"))
local BatAttackConfig = require(ReplicatedStorage:WaitForChild("BatAttackConfig"))

local ROLE_SEEKER = "Seeker"

type AnimationState = {
	connection: RBXScriptConnection,
	knockdownConnection: RBXScriptConnection,
	idleTrack: AnimationTrack?,
	moveTrack: AnimationTrack?,
}

local HiderAnimation = {}
local states: {[Model]: AnimationState} = {}

local function findAnimateTemplate(npc: Model): Instance?
	-- HunterCharacter keeps its own animation data. Search the complete model
	-- so Idle can live either under Animate or alongside it in AnimSaves.
	if npc:GetAttribute("RoundRole") == ROLE_SEEKER then
		return npc
	end

	local embeddedAnimate = npc:FindFirstChild("Animate")
	if embeddedAnimate then
		return embeddedAnimate
	end

	local scripts = StarterPlayer:FindFirstChild("StarterCharacterScripts")
	return if scripts then scripts:FindFirstChild("Animate") else nil
end

local function classify(animation: Animation, animateTemplate: Instance): string?
	local current: Instance? = animation
	while current and current ~= animateTemplate.Parent do
		local name = string.lower(current.Name)
		if string.find(name, "swim", 1, true) then
			-- LowPolyWaterNpcAnimation owns both swim locomotion tracks. Do not
			-- accidentally choose swimIdle as the NPC's normal ground idle.
			return nil
		elseif string.find(name, "idle", 1, true) then
			return "Idle"
		elseif string.find(name, "walk", 1, true) or string.find(name, "run", 1, true) then
			return "Move"
		end
		if current == animateTemplate then
			break
		end
		current = current.Parent
	end
	return nil
end

local function loadTrack(animator: Animator, animation: Animation, priority: Enum.AnimationPriority): AnimationTrack?
	if animation.AnimationId == "" then
		return nil
	end
	local succeeded, result = pcall(function()
		return animator:LoadAnimation(animation)
	end)
	if not succeeded then
		return nil
	end
	local track = result :: AnimationTrack
	track.Priority = priority
	track.Looped = true
	return track
end

function HiderAnimation.Start(npc: Model)
	if states[npc] then
		return
	end
	local humanoid = npc:FindFirstChildOfClass("Humanoid")
	local animateTemplate = findAnimateTemplate(npc)
	if not humanoid or not animateTemplate then
		return
	end
	local animator = humanoid:FindFirstChildOfClass("Animator")
	if not animator then
		animator = Instance.new("Animator")
		animator.Parent = humanoid
	end

	local idleAnimation: Animation? = nil
	local moveAnimation: Animation? = nil
	for _, descendant in ipairs(animateTemplate:GetDescendants()) do
		if descendant:IsA("Animation") then
			local category = classify(descendant, animateTemplate)
			if category == "Idle" and not idleAnimation then
				idleAnimation = descendant
			elseif category == "Move" and not moveAnimation then
				moveAnimation = descendant
			end
		end
	end
	local idleTrack = if idleAnimation
		then loadTrack(animator, idleAnimation, Enum.AnimationPriority.Idle)
		else nil
	local moveTrack = if moveAnimation
		then loadTrack(animator, moveAnimation, Enum.AnimationPriority.Movement)
		else nil
	if idleTrack then
		idleTrack:Play(0.15)
	end

	local function updateTracks(speed: number)
		if npc:GetAttribute(BatAttackConfig.KNOCKDOWN_ATTRIBUTE) == true then
			if idleTrack and idleTrack.IsPlaying then
				idleTrack:Stop(0.05)
			end
			if moveTrack and moveTrack.IsPlaying then
				moveTrack:Stop(0.05)
			end
			return
		end
		if speed > MovementAnimationConfig.MOVING_SPEED_THRESHOLD then
			if idleTrack and idleTrack.IsPlaying then
				idleTrack:Stop(0.15)
			end
			if moveTrack and not moveTrack.IsPlaying then
				moveTrack:Play(0.15)
			end
			if moveTrack then
				moveTrack:AdjustSpeed(MovementAnimationConfig.GetPlaybackSpeed(speed, humanoid.WalkSpeed))
			end
		else
			if moveTrack and moveTrack.IsPlaying then
				moveTrack:Stop(0.15)
			end
			if idleTrack and not idleTrack.IsPlaying then
				idleTrack:Play(0.15)
			end
		end
	end

	local connection = humanoid.Running:Connect(updateTracks)
	local knockdownConnection = npc:GetAttributeChangedSignal(
		BatAttackConfig.KNOCKDOWN_ATTRIBUTE
	):Connect(function()
		updateTracks(0)
	end)
	states[npc] = {
		connection = connection,
		knockdownConnection = knockdownConnection,
		idleTrack = idleTrack,
		moveTrack = moveTrack,
	}
end

function HiderAnimation.Stop(npc: Model)
	local state = states[npc]
	if not state then
		return
	end
	states[npc] = nil
	state.connection:Disconnect()
	state.knockdownConnection:Disconnect()
	if state.idleTrack then
		state.idleTrack:Stop(0)
		state.idleTrack:Destroy()
	end
	if state.moveTrack then
		state.moveTrack:Stop(0)
		state.moveTrack:Destroy()
	end
end

return HiderAnimation
