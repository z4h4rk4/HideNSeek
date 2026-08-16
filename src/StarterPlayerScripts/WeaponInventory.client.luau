--!strict

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local StarterGui = game:GetService("StarterGui")
local Workspace = game:GetService("Workspace")

local Config = require(ReplicatedStorage:WaitForChild("WeaponShopConfig"))
local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")
local remote = ReplicatedStorage:WaitForChild(Config.PURCHASE_REMOTE_NAME) :: RemoteEvent

local INVENTORY_GUI_NAME = "weaponinventory"
local BIND_WAIT_SECONDS = 15
local SELECTED_STROKE_COLOR = Color3.new(1, 1, 1)

type TextObject = TextLabel | TextButton | TextBox
type ItemBinding = {
	item: any,
	button: GuiObject,
	purchaseFrame: GuiObject?,
	timerFrame: GuiObject?,
	timer: TextObject?,
	stroke: UIStroke?,
	defaultStrokeColor: Color3?,
}

local bindings: {ItemBinding} = {}
local bindingConnections: {RBXScriptConnection} = {}
local pending: {[string]: boolean} = {}
local bindGeneration = 0

local function log(message: string)
	if Config.DEBUG_LOGGING then
		print(`[WeaponShop][Client] {message}`)
	end
end

local function normalizeName(name: string): string
	return string.lower(name):gsub("[^%w]", "")
end

local function ownedAttribute(weaponName: string): string
	return Config.OWNED_ATTRIBUTE_PREFIX .. weaponName
end

local function findInventoryGui(): ScreenGui?
	for _, child in ipairs(playerGui:GetChildren()) do
		if child:IsA("ScreenGui")
			and normalizeName(child.Name) == INVENTORY_GUI_NAME then
			return child
		end
	end
	return nil
end

local function findGuiObject(parent: Instance?, name: string?): GuiObject?
	if not parent or not name then
		return nil
	end
	local child = parent:FindFirstChild(name)
	return if child and child:IsA("GuiObject") then child else nil
end

local function findTextObject(parent: Instance?, name: string): TextObject?
	if not parent then
		return nil
	end
	local child = parent:FindFirstChild(name)
	return if child
		and (child:IsA("TextLabel")
			or child:IsA("TextButton")
			or child:IsA("TextBox"))
		then child
		else nil
end

local function disconnectBindings()
	for _, binding in ipairs(bindings) do
		if binding.stroke and binding.defaultStrokeColor and binding.stroke.Parent then
			binding.stroke.Color = binding.defaultStrokeColor
		end
	end
	for _, connection in ipairs(bindingConnections) do
		connection:Disconnect()
	end
	table.clear(bindingConnections)
	table.clear(bindings)
end

local function connectInput(control: GuiObject, callback: () -> ())
	control.Active = true
	if control:IsA("GuiButton") then
		control.Interactable = true
		table.insert(bindingConnections, control.Activated:Connect(callback))
	else
		table.insert(bindingConnections, control.InputBegan:Connect(function(input)
			if input.UserInputType == Enum.UserInputType.MouseButton1
				or input.UserInputType == Enum.UserInputType.Touch then
				callback()
			end
		end))
	end
end

local function connectControl(control: GuiObject, callback: () -> ())
	local lastClickAt = -math.huge
	local function activate()
		local now = os.clock()
		if now - lastClickAt < 0.1 then
			return
		end
		lastClickAt = now
		log(`click {control:GetFullName()}`)
		callback()
	end
	connectInput(control, activate)

	-- The existing Price label can cover an ImageLabel. Listen to that existing
	-- object as well; no helper button or any other GUI is created.
	local price = findGuiObject(control, Config.PRICE_TEXT_NAME)
	if price then
		connectInput(price, activate)
	end
end

local function setPrice(control: GuiObject, text: string): boolean
	local price = findTextObject(control, Config.PRICE_TEXT_NAME)
	if not price then
		return false
	end
	price.Text = text
	log(`price {price:GetFullName()} = {text}`)
	return true
end

local function owns(item: any): boolean
	return item.FREE or player:GetAttribute(ownedAttribute(item.WEAPON_NAME)) == true
end

local function getEquippedWeaponName(): string?
	local character = player.Character
	if not character then
		return nil
	end
	for _, item in ipairs(Config.ITEMS) do
		local tool = character:FindFirstChild(item.WEAPON_NAME)
		if tool and tool:IsA("Tool") then
			return item.WEAPON_NAME
		end
	end
	return nil
end

local function equip(item: any)
	if not owns(item) then
		return
	end
	local character = player.Character
	local humanoid = if character then character:FindFirstChildOfClass("Humanoid") else nil
	local backpack = player:FindFirstChildOfClass("Backpack")
	if not character or not humanoid or humanoid.Health <= 0 or not backpack then
		return
	end
	local tool = character:FindFirstChild(item.WEAPON_NAME)
		or backpack:FindFirstChild(item.WEAPON_NAME)
	if tool and tool:IsA("Tool") then
		humanoid:EquipTool(tool)
	end
end

local function refresh(binding: ItemBinding)
	local isOwned = owns(binding.item)
	if binding.purchaseFrame then
		binding.purchaseFrame.Visible = not isOwned
	end
	binding.button:SetAttribute("WeaponOwned", isOwned)
end

local function collectBinding(iconFrame: GuiObject, item: any): ItemBinding?
	local button = findGuiObject(iconFrame, item.BUTTON_NAME)
	if not button then
		return nil
	end
	local purchaseFrame = findGuiObject(button, item.PURCHASE_FRAME_NAME)
	local timerFrame = findGuiObject(button, item.TIMER_FRAME_NAME)
	local stroke = button:FindFirstChildOfClass("UIStroke")
	return {
		item = item,
		button = button,
		purchaseFrame = purchaseFrame,
		timerFrame = timerFrame,
		timer = findTextObject(timerFrame, Config.TIMER_TEXT_NAME),
		stroke = stroke,
		defaultStrokeColor = if stroke then stroke.Color else nil,
	}
end

local function bindingIsComplete(binding: ItemBinding): boolean
	local item = binding.item
	if item.PURCHASE_FRAME_NAME then
		local frame = binding.purchaseFrame
		local buyButton = findGuiObject(frame, Config.BUY_BUTTON_NAME)
		if not frame or not buyButton then
			return false
		end
		if not findTextObject(buyButton, Config.PRICE_TEXT_NAME) then
			return false
		end
	end
	if item.TIMER_FRAME_NAME then
		return binding.timerFrame ~= nil and binding.timer ~= nil
	end
	return true
end

local function reportMissing(screenGui: ScreenGui)
	local iconFrame = findGuiObject(screenGui, Config.ICON_FRAME_NAME)
	if not iconFrame then
		warn(`[WeaponShop][Client] {screenGui:GetFullName()}.IconFrame not found`)
		return
	end
	for _, item in ipairs(Config.ITEMS) do
		local binding = collectBinding(iconFrame, item)
		if not binding then
			warn(`[WeaponShop][Client] {iconFrame:GetFullName()}.{item.BUTTON_NAME} not found`)
			continue
		end
		if item.PURCHASE_FRAME_NAME then
			local frame = binding.purchaseFrame
			if not frame then
				warn(`[WeaponShop][Client] {binding.button:GetFullName()}.{item.PURCHASE_FRAME_NAME} not found`)
			else
				local buyButton = findGuiObject(frame, Config.BUY_BUTTON_NAME)
				if not buyButton then
					warn(`[WeaponShop][Client] {frame:GetFullName()}.{Config.BUY_BUTTON_NAME} not found`)
				elseif not findTextObject(buyButton, Config.PRICE_TEXT_NAME) then
					warn(`[WeaponShop][Client] {buyButton:GetFullName()}.Price not found`)
				end
			end
		end
		if item.TIMER_FRAME_NAME then
			if not binding.timerFrame then
				warn(`[WeaponShop][Client] {binding.button:GetFullName()}.{item.TIMER_FRAME_NAME} not found`)
			elseif not binding.timer then
				warn(`[WeaponShop][Client] {binding.timerFrame:GetFullName()}.Timer not found`)
			end
		end
		if not binding.stroke then
			warn(`[WeaponShop][Client] {binding.button:GetFullName()}.UIStroke not found`)
		end
	end
end

local function connectBinding(binding: ItemBinding)
	local item = binding.item
	local purchaseFrame = binding.purchaseFrame
	connectControl(binding.button, function()
		if owns(item) then
			equip(item)
		elseif purchaseFrame then
			purchaseFrame.Visible = true
		end
	end)

	if purchaseFrame then
		local buyButton = findGuiObject(purchaseFrame, Config.BUY_BUTTON_NAME) :: GuiObject
		setPrice(buyButton, tostring(item.CURRENCY_PRICE))
		connectControl(buyButton, function()
			if owns(item) or pending[item.WEAPON_NAME] then
				return
			end
			pending[item.WEAPON_NAME] = true
			log(`cash request {item.WEAPON_NAME}, price={item.CURRENCY_PRICE}`)
			remote:FireServer(Config.PURCHASE_ACTION, item.WEAPON_NAME)
			task.delay(5, function()
				pending[item.WEAPON_NAME] = nil
			end)
		end)
	end

	table.insert(
		bindingConnections,
		player:GetAttributeChangedSignal(ownedAttribute(item.WEAPON_NAME)):Connect(function()
			log(`ownership {item.WEAPON_NAME} = {tostring(owns(item))}`)
			refresh(binding)
		end)
	)
	refresh(binding)
	log(`connected {binding.button:GetFullName()}`)
end

local function bindInventoryGui(screenGui: ScreenGui)
	bindGeneration += 1
	local generation = bindGeneration
	disconnectBindings()
	log(`found inventory GUI: {screenGui:GetFullName()} [ScreenGui]`)

	task.spawn(function()
		local deadline = os.clock() + BIND_WAIT_SECONDS
		local readyBindings: {ItemBinding}? = nil
		repeat
			local iconFrame = findGuiObject(screenGui, Config.ICON_FRAME_NAME)
			if iconFrame then
				local candidate: {ItemBinding} = {}
				local complete = true
				for _, item in ipairs(Config.ITEMS) do
					local binding = collectBinding(iconFrame, item)
					if not binding or not bindingIsComplete(binding) then
						complete = false
						break
					end
					table.insert(candidate, binding)
				end
				if complete then
					readyBindings = candidate
					break
				end
			end
			task.wait(0.1)
		until os.clock() >= deadline
			or generation ~= bindGeneration
			or not screenGui.Parent

		if generation ~= bindGeneration or not screenGui.Parent then
			return
		end
		if not readyBindings then
			reportMissing(screenGui)
			return
		end
		for _, binding in ipairs(readyBindings) do
			table.insert(bindings, binding)
			connectBinding(binding)
		end
		log(`inventory ready: {#readyBindings} item(s)`)
	end)
end

remote.OnClientEvent:Connect(function(weaponName: any, success: any, reason: any)
	if type(weaponName) ~= "string" then
		return
	end
	pending[weaponName] = nil
	log(`response {weaponName}: success={tostring(success)}, reason={tostring(reason)}`)
	if success ~= true then
		warn(`[WeaponShop][Client] purchase failed: {weaponName}, {tostring(reason)}`)
	end
end)

playerGui.ChildAdded:Connect(function(child)
	if child:IsA("ScreenGui") and normalizeName(child.Name) == INVENTORY_GUI_NAME then
		bindInventoryGui(child)
	end
end)

playerGui.ChildRemoved:Connect(function(child)
	if child:IsA("ScreenGui") and normalizeName(child.Name) == INVENTORY_GUI_NAME then
		bindGeneration += 1
		disconnectBindings()
	end
end)

task.spawn(function()
	for _ = 1, 10 do
		if pcall(function()
			StarterGui:SetCoreGuiEnabled(Enum.CoreGuiType.Backpack, false)
		end) then
			break
		end
		task.wait(0.25)
	end
end)

RunService.RenderStepped:Connect(function()
	local now = Workspace:GetServerTimeNow()
	local equipped = getEquippedWeaponName()
	for _, binding in ipairs(bindings) do
		refresh(binding)
		local isEquipped = equipped == binding.item.WEAPON_NAME
		binding.button:SetAttribute(
			"WeaponEquipped",
			isEquipped
		)
		if binding.stroke and binding.defaultStrokeColor then
			binding.stroke.Color = if isEquipped
				then SELECTED_STROKE_COLOR
				else binding.defaultStrokeColor
		end
		local deadline = player:GetAttribute(
			Config.COOLDOWN_ATTRIBUTE_PREFIX .. binding.item.WEAPON_NAME
		)
		local remaining = if type(deadline) == "number"
			then math.max(0, deadline - now)
			else 0
		if binding.timerFrame then
			binding.timerFrame.Visible = remaining > 0
		end
		if binding.timer and remaining > 0 then
			binding.timer.Text = tostring(math.ceil(remaining))
		end
	end
end)

local inventoryGui = findInventoryGui()
if inventoryGui then
	bindInventoryGui(inventoryGui)
else
	local names: {string} = {}
	for _, child in ipairs(playerGui:GetChildren()) do
		if child:IsA("ScreenGui") then
			table.insert(names, `{child.Name} -> {normalizeName(child.Name)}`)
		end
	end
	log(`waiting for ScreenGui "WeaponInventory"; current ScreenGui: {table.concat(names, ", ")}`)
end
