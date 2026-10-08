--!strict
--[[
	AbilityData (ModuleScript, ReplicatedStorage/Shared)
	====================================================
	Leg Styles: the premium-gacha active abilities that break the rhythm of a
	rally. Pure data. The behaviour lives in ServerScriptService/Server/Services/
	AbilityService (server truth) and the client CombatFX (visuals).

	Adding a style:
	  1. add an entry here,
	  2. add a behaviour in AbilityService.Behaviors,
	  3. (optional) add a visual in CombatFX.onEffect.
]]

export type Rarity = "Common" | "Rare" | "Epic" | "Legendary" | "Mythic"

export type LegStyle = {
	id: string,
	displayName: string,
	rarity: Rarity,
	dropWeight: number, -- relative crate weight; 0 = not in the crate
	usesPerRound: number, -- activations allowed per round
	description: string,
	params: { [string]: number },
}

local AbilityData = {}

AbilityData.DefaultStyleId = "Default"

local styles: { [string]: LegStyle } = {
	Default = {
		id = "Default",
		displayName = "Standard Kick",
		rarity = "Common",
		dropWeight = 0,
		usesPerRound = 0,
		description = "A clean, honest dash-kick.",
		params = {},
	},

	ShadowClone = {
		id = "ShadowClone",
		displayName = "Shadow Clone",
		rarity = "Epic",
		dropWeight = 70,
		usesPerRound = 2,
		description = "Split into three flying copies. Only one of them is the real hitbox.",
		params = {
			LaneSpread = 8, -- studs between lanes at activation
			Lanes = 3, -- total models (1 real + 2 decoys)
		},
	},

	InvisDash = {
		id = "InvisDash",
		displayName = "Invis-Dash",
		rarity = "Legendary",
		dropWeight = 25,
		usesPerRound = 2,
		description = "Your body vanishes for the rest of the flight.",
		params = {},
	},

	LagSwitch = {
		id = "LagSwitch",
		displayName = "Lag Switch Kick",
		rarity = "Mythic",
		dropWeight = 5,
		usesPerRound = 1,
		description = "Freeze mid-flight, then blink straight to your target.",
		params = {
			FreezeTime = 0.5, -- seconds frozen mid-air (baits early parries)
			LeadTime = 0.12, -- the blink leaves this much flight time so a sharp parry can still answer it
		},
	},
}

AbilityData.Styles = table.freeze(styles)

AbilityData.RarityOrder = table.freeze({ "Common", "Rare", "Epic", "Legendary", "Mythic" } :: { Rarity })

AbilityData.RarityColors = table.freeze({
	Common = Color3.fromRGB(200, 200, 200),
	Rare = Color3.fromRGB(70, 150, 255),
	Epic = Color3.fromRGB(170, 80, 255),
	Legendary = Color3.fromRGB(255, 190, 40),
	Mythic = Color3.fromRGB(255, 50, 80),
} :: { [Rarity]: Color3 })

function AbilityData.get(styleId: string): LegStyle?
	return styles[styleId]
end

--[[
	Weighted crate roll. The SERVER calls this with its own Random object; the
	client only reads `dropWeight` to display odds. Iteration order is made
	deterministic (sorted ids) so a seeded Random gives reproducible rolls in tests.
]]
function AbilityData.rollCrate(rng: Random): LegStyle
	local ids = {}
	local totalWeight = 0
	for id, style in styles do
		if style.dropWeight > 0 then
			table.insert(ids, id)
			totalWeight += style.dropWeight
		end
	end
	table.sort(ids)

	local roll = rng:NextNumber(0, totalWeight)
	for _, id in ids do
		local style = styles[id]
		roll -= style.dropWeight
		if roll <= 0 then
			return style
		end
	end
	return styles[ids[#ids]]
end

return table.freeze(AbilityData)
