local Players = game:GetService("Players")

local roundModules = script.Parent:WaitForChild("Round")
local RoundConfig = require(roundModules:WaitForChild("RoundConfig"))

local WALK_SPEED = RoundConfig.WALK_SPEED
local JUMP_HEIGHT = 0

local function setupCharacter(character: Model)
	local humanoid = character:WaitForChild("Humanoid", 10)
	if humanoid and humanoid:IsA("Humanoid") then
		humanoid.WalkSpeed = WALK_SPEED
		humanoid.UseJumpPower = false
		humanoid.JumpHeight = JUMP_HEIGHT
	end
end

local function setupPlayer(player: Player)
	player.CharacterAdded:Connect(setupCharacter)

	if player.Character then
		task.spawn(setupCharacter, player.Character)
	end
end

for _, player in ipairs(Players:GetPlayers()) do
	setupPlayer(player)
end

Players.PlayerAdded:Connect(setupPlayer)
