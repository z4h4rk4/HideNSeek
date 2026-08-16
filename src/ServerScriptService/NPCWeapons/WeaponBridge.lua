--!strict

export type Adapter = {
	EquipWeapon: (character: Model, weaponName: string) -> Tool?,
	Attack: (character: Model, requestedDirection: any, requestedTarget: any) -> boolean,
}

local adapter: Adapter? = nil
local WeaponBridge = {}

function WeaponBridge.SetAdapter(nextAdapter: Adapter)
	adapter = nextAdapter
end

function WeaponBridge.IsReady(): boolean
	return adapter ~= nil
end

function WeaponBridge.EquipWeapon(character: Model, weaponName: string): Tool?
	local currentAdapter = adapter
	return if currentAdapter then currentAdapter.EquipWeapon(character, weaponName) else nil
end

function WeaponBridge.Attack(
	character: Model,
	requestedDirection: any,
	requestedTarget: any
): boolean
	local currentAdapter = adapter
	return currentAdapter ~= nil
		and currentAdapter.Attack(character, requestedDirection, requestedTarget)
end

return table.freeze(WeaponBridge)
