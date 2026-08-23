local Players = game:GetService("Players")

local roundModules = script.Parent:WaitForChild("Round")
local RoundConfig = require(roundModules:WaitForChild("RoundConfig"))
local DoorCharacterCollider = require(roundModules:WaitForChild("DoorCharacterCollider"))

DoorCharacterCollider.Configure()

local function getPlayerCollisionGroup(player: Player): string
	local role = player:GetAttribute("RoundRole")
	return if role == RoundConfig.ROLE_HIDER or role == RoundConfig.ROLE_SEEKER
		then DoorCharacterCollider.CHARACTER_COLLISION_GROUP
		else DoorCharacterCollider.HUB_COLLISION_GROUP
end

local function setupCharacter(player: Player, character: Model)
	local function attach()
		if character.Parent then
			DoorCharacterCollider.Refresh(
				character,
				getPlayerCollisionGroup(player)
			)
		end
	end
	if character:FindFirstChild("HumanoidRootPart") then
		attach()
	else
		task.spawn(function()
			character:WaitForChild("HumanoidRootPart", 10)
			attach()
		end)
	end
end

local function setupPlayer(player: Player)
	player.CharacterAdded:Connect(function(character)
		setupCharacter(player, character)
	end)
	player:GetAttributeChangedSignal("RoundRole"):Connect(function()
		if player.Character then
			setupCharacter(player, player.Character)
		end
	end)

	if player.Character then
		setupCharacter(player, player.Character)
	end
end

for _, player in ipairs(Players:GetPlayers()) do
	setupPlayer(player)
end

Players.PlayerAdded:Connect(setupPlayer)
