--!strict
--[[
	UpgradeData (ModuleScript, ReplicatedStorage/Shared)
	====================================================
	Soft-currency stat upgrades bought in the lobby with Coins.

	    value(level) = base + perLevel * level
	    cost(level)  = floor(baseCost * costGrowth ^ level)   -- price of the NEXT level

	ParryWindow is a bonus in seconds that CombatService adds to
	Config.Parry.BaseWindow. It is deliberately small ("slightly expand"):
	+0.05 s at max level.
]]

export type StatId = "WalkSpeed" | "JumpPower" | "ParryWindow"

export type UpgradeDef = {
	displayName: string,
	base: number,
	perLevel: number,
	maxLevel: number,
	baseCost: number,
	costGrowth: number,
}

local UpgradeData = {}

local stats: { [StatId]: UpgradeDef } = {
	WalkSpeed = {
		displayName = "Walkspeed",
		base = 16,
		perLevel = 0.6,
		maxLevel = 15,
		baseCost = 40,
		costGrowth = 1.35,
	},
	JumpPower = {
		displayName = "Jump Power",
		base = 50,
		perLevel = 2,
		maxLevel = 10,
		baseCost = 35,
		costGrowth = 1.35,
	},
	ParryWindow = {
		displayName = "Parry Window",
		base = 0,
		perLevel = 0.005,
		maxLevel = 10,
		baseCost = 120,
		costGrowth = 1.5,
	},
}

local order: { StatId } = { "WalkSpeed", "JumpPower", "ParryWindow" }

UpgradeData.Stats = table.freeze(stats)
UpgradeData.Order = table.freeze(order)

-- Validates an untrusted value from the network and narrows it to a StatId.
function UpgradeData.parseStat(value: unknown): StatId?
	if value == "WalkSpeed" or value == "JumpPower" or value == "ParryWindow" then
		return value
	end
	return nil
end

function UpgradeData.valueAt(stat: StatId, level: number): number
	local def = stats[stat]
	return def.base + def.perLevel * math.clamp(level, 0, def.maxLevel)
end

-- Price of the next level, or nil when already maxed.
function UpgradeData.costFor(stat: StatId, currentLevel: number): number?
	local def = stats[stat]
	if currentLevel >= def.maxLevel then
		return nil
	end
	return math.floor(def.baseCost * def.costGrowth ^ currentLevel)
end

return table.freeze(UpgradeData)
