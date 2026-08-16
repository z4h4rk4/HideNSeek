--!strict

local MarketplaceService = game:GetService("MarketplaceService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage:WaitForChild("WeaponShopConfig"))
local CurrencyService = require(
	script.Parent.Parent:WaitForChild("Currency"):WaitForChild("CurrencyService")
)

local Service = {}
local started = false
local remote: RemoteEvent? = nil
local lastRequest: {[Player]: number} = {}
local gamePassItems: {[number]: any} = {}

local function log(message: string)
	if Config.DEBUG_LOGGING then
		print(`[WeaponShop][Server] {message}`)
	end
end

local function ownedAttribute(weaponName: string): string
	return Config.OWNED_ATTRIBUTE_PREFIX .. weaponName
end

local function setOwned(player: Player, weaponName: string, owned: boolean)
	player:SetAttribute(ownedAttribute(weaponName), if owned then true else nil)
end

local function reply(player: Player, weaponName: string, success: boolean, reason: any)
	if remote then
		remote:FireClient(player, weaponName, success, tostring(reason or "OK"))
	end
end

local function syncPlayer(player: Player)
	player:SetAttribute(Config.OWNERSHIP_READY_ATTRIBUTE, false)
	while player.Parent == Players and not CurrencyService.AwaitLoaded(player, 30) do
		task.wait(0.5)
	end
	if player.Parent ~= Players then
		return
	end
	local ownedWeapons = CurrencyService.GetOwnedWeapons(player) or {}
	for _, item in ipairs(Config.ITEMS) do
		setOwned(player, item.WEAPON_NAME, item.FREE or ownedWeapons[item.WEAPON_NAME] == true)
	end
	for gamePassId, item in pairs(gamePassItems) do
		local ok, ownsPass = pcall(
			MarketplaceService.UserOwnsGamePassAsync,
			MarketplaceService,
			player.UserId,
			gamePassId
		)
		if ok and ownsPass then
			CurrencyService.GrantWeapon(player, item.WEAPON_NAME, "GamePassOwnershipSync")
			setOwned(player, item.WEAPON_NAME, true)
		end
	end
	player:SetAttribute(Config.OWNERSHIP_READY_ATTRIBUTE, true)
	log(`synced {player.Name}, balance={tostring(CurrencyService.GetCurrency(player))}`)
end

local function purchase(player: Player, action: any, weaponName: any)
	log(`request {player.Name}: {tostring(action)}, {tostring(weaponName)}`)
	if action ~= Config.PURCHASE_ACTION or type(weaponName) ~= "string" then
		return
	end
	local now = os.clock()
	if lastRequest[player] and now - lastRequest[player] < Config.REQUEST_COOLDOWN_SECONDS then
		reply(player, weaponName, false, "TOO_FAST")
		return
	end
	lastRequest[player] = now
	local item = Config.BY_WEAPON[weaponName]
	if not item or item.FREE then
		reply(player, weaponName, false, "INVALID_WEAPON")
		return
	end
	if player:GetAttribute(ownedAttribute(weaponName)) == true then
		reply(player, weaponName, true, "ALREADY_OWNED")
		return
	end
	local success, balance, reason = CurrencyService.PurchaseWeapon(
		player,
		weaponName,
		item.CURRENCY_PRICE,
		`WeaponPurchase:{weaponName}`
	)
	if success then
		setOwned(player, weaponName, true)
	end
	log(
		`result {player.Name}/{weaponName}: success={tostring(success)}, `
			.. `balance={tostring(balance)}, reason={tostring(reason)}`
	)
	reply(player, weaponName, success, reason)
end

function Service.Start()
	if started then
		return
	end
	started = true
	for _, item in ipairs(Config.ITEMS) do
		if not item.FREE and item.GAME_PASS_ID > 0 then
			gamePassItems[item.GAME_PASS_ID] = item
		end
	end
	local existing = ReplicatedStorage:FindFirstChild(Config.PURCHASE_REMOTE_NAME)
	if existing and not existing:IsA("RemoteEvent") then
		error(`ReplicatedStorage.{Config.PURCHASE_REMOTE_NAME} must be a RemoteEvent`)
	end
	if existing then
		remote = existing :: RemoteEvent
	else
		local created = Instance.new("RemoteEvent")
		created.Name = Config.PURCHASE_REMOTE_NAME
		created.Parent = ReplicatedStorage
		remote = created
	end
	(remote :: RemoteEvent).OnServerEvent:Connect(purchase)
	CurrencyService.OwnershipChanged:Connect(function(player, weaponName, owned)
		if player.Parent == Players and Config.BY_WEAPON[weaponName] then
			setOwned(player, weaponName, owned)
		end
	end)
	MarketplaceService.PromptGamePassPurchaseFinished:Connect(function(player, gamePassId, purchased)
		local item = gamePassItems[gamePassId]
		if not purchased or not item or player.Parent ~= Players then
			return
		end
		task.spawn(function()
			if CurrencyService.AwaitLoaded(player, 30) and player.Parent == Players then
				local granted = CurrencyService.GrantWeapon(
					player,
					item.WEAPON_NAME,
					"GamePassPurchase"
				)
				if granted then
					setOwned(player, item.WEAPON_NAME, true)
				end
			end
		end)
	end)
	Players.PlayerAdded:Connect(function(player)
		task.spawn(syncPlayer, player)
	end)
	Players.PlayerRemoving:Connect(function(player)
		lastRequest[player] = nil
	end)
	for _, player in ipairs(Players:GetPlayers()) do
		task.spawn(syncPlayer, player)
	end
	log(`started with {#Config.ITEMS} item(s)`)
end

return Service
