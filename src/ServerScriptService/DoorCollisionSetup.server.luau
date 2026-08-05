local Players = game:GetService("Players")

local roundModules = script.Parent:WaitForChild("Round")
local DoorCharacterCollider = require(roundModules:WaitForChild("DoorCharacterCollider"))

DoorCharacterCollider.Configure()

local function setupCharacter(character: Model)
	local function attach()
		if character.Parent then
			DoorCharacterCollider.Refresh(
				character,
				DoorCharacterCollider.CHARACTER_COLLISION_GROUP
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
	player.CharacterAdded:Connect(setupCharacter)

	if player.Character then
		setupCharacter(player.Character)
	end
end

for _, player in ipairs(Players:GetPlayers()) do
	setupPlayer(player)
end

Players.PlayerAdded:Connect(setupPlayer)
