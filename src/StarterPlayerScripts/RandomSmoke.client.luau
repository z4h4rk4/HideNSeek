--!strict

local Debris = game:GetService("Debris")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local SeekerSearchConfig = require(ReplicatedStorage:WaitForChild("SeekerSearchConfig"))

local SMOKE_CLIENT_ASSET_NAME = "RandomSmokeTemplate"
local FART_CLIENT_ASSET_NAME = "FartTemplate"
local REMOTE_NAME = "RandomSmokeTriggered"
local FART_EFFECT_KIND = "Fart"
local MANAGED_NPC_ATTRIBUTE = "ManagedRoundNPC"
local ROLE_ATTRIBUTE = "RoundRole"
local HIDER_ROLE = "Hider"
local PRESERVE_VISUAL_ATTRIBUTE = SeekerSearchConfig.PRESERVE_VISUAL_ATTRIBUTE
local DEFAULT_EMIT_COUNT = 1
local CLEANUP_PADDING_SECONDS = 0.5

local smokeTemplate = ReplicatedStorage:WaitForChild(SMOKE_CLIENT_ASSET_NAME)
local fartTemplate = ReplicatedStorage:WaitForChild(FART_CLIENT_ASSET_NAME)
local smokeRemote = ReplicatedStorage:WaitForChild(REMOTE_NAME)
if not smokeRemote:IsA("RemoteEvent") then
	error(`ReplicatedStorage.{REMOTE_NAME} must be a RemoteEvent`)
end

local function forEachEmitter(root: Instance, callback: (ParticleEmitter) -> ())
	if root:IsA("ParticleEmitter") then
		callback(root)
	end
	for _, descendant in ipairs(root:GetDescendants()) do
		if descendant:IsA("ParticleEmitter") then
			callback(descendant)
		end
	end
end

local function disableEmitters(root: Instance)
	forEachEmitter(root, function(emitter)
		emitter.Enabled = false
	end)
end

local function preparePart(part: BasePart, rootPart: BasePart)
	part.Anchored = false
	part.CanCollide = false
	part.CanTouch = false
	part.CanQuery = false
	part.Massless = true

	local weld = Instance.new("WeldConstraint")
	weld.Part0 = rootPart
	weld.Part1 = part
	weld.Parent = part
end

local function attachEffect(template: Instance, character: Model, rootPart: BasePart): Instance
	local effect = template:Clone()
	effect:SetAttribute(PRESERVE_VISUAL_ATTRIBUTE, true)
	disableEmitters(effect)

	if effect:IsA("Attachment") then
		effect.Parent = rootPart
	elseif effect:IsA("ParticleEmitter") then
		local attachment = Instance.new("Attachment")
		attachment.Name = "RandomSmokeAttachment"
		attachment.Parent = rootPart
		effect.Parent = attachment
		effect = attachment
	elseif effect:IsA("BasePart") then
		effect.CFrame = rootPart.CFrame
		effect.Parent = character
		preparePart(effect, rootPart)
	elseif effect:IsA("Model") then
		effect.Parent = character
		effect:PivotTo(rootPart.CFrame)
		for _, descendant in ipairs(effect:GetDescendants()) do
			if descendant:IsA("BasePart") then
				preparePart(descendant, rootPart)
			end
		end
	else
		local attachment = Instance.new("Attachment")
		attachment.Name = "RandomSmokeAttachment"
		attachment.Parent = rootPart
		forEachEmitter(effect, function(emitter)
			emitter:Clone().Parent = attachment
		end)
		effect:Destroy()
		effect = attachment
	end

	return effect
end

local function resolveCharacter(subject: Instance): Model?
	if subject:IsA("Model") then
		return subject
	end
	if subject:IsA("Player") then
		return subject.Character
	end
	return nil
end

local function isHiderCharacter(character: Model): boolean
	local player = Players:GetPlayerFromCharacter(character)
	if player then
		return player:GetAttribute(ROLE_ATTRIBUTE) == HIDER_ROLE
	end
	return character:GetAttribute(MANAGED_NPC_ATTRIBUTE) == true
		and character:GetAttribute(ROLE_ATTRIBUTE) == HIDER_ROLE
end

local function emitEffect(subject: Instance, template: Instance): BasePart?
	local character = resolveCharacter(subject)
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	local rootPart = character and character:FindFirstChild("HumanoidRootPart")
	if not character
		or not isHiderCharacter(character)
		or not character.Parent
		or not humanoid
		or humanoid.Health <= 0
		or not rootPart
		or not rootPart:IsA("BasePart") then
		return nil
	end

	local effect = attachEffect(template, character, rootPart)
	local emitterCount = 0
	local longestLifetime = 0
	forEachEmitter(effect, function(emitter)
		emitterCount += 1
		longestLifetime = math.max(longestLifetime, emitter.Lifetime.Max)
		local configuredCount = emitter:GetAttribute("EmitCount")
		local emitCount = if type(configuredCount) == "number"
			and configuredCount > 0
			and configuredCount % 1 == 0
			then configuredCount
			else DEFAULT_EMIT_COUNT
		emitter:Emit(emitCount)
	end)

	if emitterCount == 0 then
		warn(`RandomSmoke: {template.Name} contains no ParticleEmitter`)
		effect:Destroy()
		return rootPart
	end
	Debris:AddItem(effect, longestLifetime + CLEANUP_PADDING_SECONDS)
	return rootPart
end

smokeRemote.OnClientEvent:Connect(function(subject, effectKind)
	if typeof(subject) == "Instance" and (subject:IsA("Model") or subject:IsA("Player")) then
		if effectKind == FART_EFFECT_KIND then
			emitEffect(subject, fartTemplate)
		else
			emitEffect(subject, smokeTemplate)
		end
	end
end)
