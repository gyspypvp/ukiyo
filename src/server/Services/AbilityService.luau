--!strict
--[[
	AbilityService (ModuleScript, server)
	=====================================
	Server truth for Leg Styles. CombatService calls `tryActivate` when a flying
	kicker presses Ability (Q); the behaviour receives a narrow FlightControl
	handle (see ServerTypes) instead of the raw flight, so a style can bend a
	kick but never break CombatService's invariants (ownership, cleanup,
	parry bookkeeping).

	Visuals are NOT done here. Each behaviour returns an Effect payload that
	CombatService broadcasts; clients render it in CombatFX. Invisibility and
	decoys are therefore purely cosmetic: the server's hitbox, contact math and
	parry validation are unchanged, so no style can be exploited into an
	unparryable kick.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage.Shared
local AbilityData = require(Shared.AbilityData)
local Types = require(Shared.Types)

local PlayerDataService = require(script.Parent.PlayerDataService)
local ServerTypes = require(script.Parent.Parent.ServerTypes)

type FlightControl = ServerTypes.FlightControl
type Behavior = (control: FlightControl, style: AbilityData.LegStyle) -> Types.EffectPayload

local AbilityService = {}

local usesThisRound: { [Player]: number } = {}
local rng = Random.new()

local function basePayload(kind: Types.EffectKind, control: FlightControl): Types.EffectPayload
	return {
		kind = kind,
		kickId = control.kickId,
		userId = control.attacker.UserId,
		targetId = control.target.UserId,
	}
end

AbilityService.Behaviors = table.freeze({
	-- Mythic: freeze for 0.5 s (baits an early, whiffed parry), then blink so only
	-- `LeadTime` of flight remains. The defender still gets a real, if brutal, window.
	LagSwitch = function(control: FlightControl, style: AbilityData.LegStyle): Types.EffectPayload
		local freezeTime = style.params.FreezeTime or 0.5
		local leadTime = style.params.LeadTime or 0.12
		control.freeze(freezeTime, function()
			control.blinkToward(leadTime)
		end)
		local payload = basePayload("LagSwitch", control)
		payload.duration = freezeTime
		return payload
	end,

	-- Legendary: the body turns invisible for the rest of the flight (client-side).
	InvisDash = function(control: FlightControl, _style: AbilityData.LegStyle): Types.EffectPayload
		return basePayload("Invis", control)
	end,

	-- Epic: three models, one real hitbox. The REAL kicker moves into a random
	-- lane; clients draw decoys in the other lanes. All lanes converge on the target.
	ShadowClone = function(control: FlightControl, style: AbilityData.LegStyle): Types.EffectPayload
		local spread = style.params.LaneSpread or 8
		local realLane = rng:NextInteger(-1, 1)
		control.setLane(realLane, spread)
		local payload = basePayload("ShadowClone", control)
		payload.realLane = realLane
		payload.spread = spread
		payload.initialGap = control.currentGap()
		return payload
	end,
} :: { [string]: Behavior })

--[[
	Runs the player's equipped style on their current flight.
	Returns the Effect payload to broadcast, or nil if nothing happened
	(no style equipped, out of uses, unknown behaviour).
]]
function AbilityService.tryActivate(player: Player, control: FlightControl): Types.EffectPayload?
	local style = AbilityData.get(PlayerDataService.getEquippedStyle(player))
	if style == nil or style.usesPerRound <= 0 then
		return nil
	end
	local used = usesThisRound[player] or 0
	if used >= style.usesPerRound then
		return nil
	end
	local behavior = AbilityService.Behaviors[style.id]
	if behavior == nil then
		return nil
	end
	usesThisRound[player] = used + 1
	return behavior(control, style)
end

function AbilityService.resetRound()
	table.clear(usesThisRound)
end

function AbilityService.forget(player: Player)
	usesThisRound[player] = nil
end

return AbilityService
