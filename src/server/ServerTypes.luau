--!strict
--[[
	ServerTypes (ModuleScript, server)
	==================================
	The contracts that make the game modular. CombatService, RoundManager and
	every GameMode only talk to each other through these shapes.

	                 +--------------+  CombatRules (canLaunch,   +---------------+
	                 |              |   canTarget)               |               |
	                 |              | -------------------------> |               |
	                 | RoundManager |                            | CombatService |
	                 |              | <------------------------- |               |
	                 +--------------+  Signals (Defeated, ...)   +---------------+
	                        |  ^                                        ^
	   lifecycle hooks      v  |  RoundContext (eliminate, alive...)
	                 +--------------+
	                 |   GameMode   |   decides who may kick, who may be kicked,
	                 | Surge / Jugg.|   what a KO means, and how a round is won
	                 +--------------+

	A new mode (e.g. Juggernaut) is ONE new file implementing GameMode. Neither
	the combat physics nor the round state machine needs to change.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Types = require(ReplicatedStorage.Shared.Types)

-- Why a fighter went down (exploded by strikes, fell off, died, left). The GameMode
-- decides what each cause means. Defined in Shared/Types so clients can show it.
export type DefeatCause = Types.DefeatCause

-- What CombatService asks the active mode before allowing a kick.
export type CombatRules = {
	canLaunch: (player: Player) -> boolean, -- may this player start a kick right now? (cooldowns are CombatService's)
	canTarget: (attacker: Player, target: Player) -> boolean,
}

-- Handed to a GameMode by the RoundManager for the lifetime of one round.
export type RoundContext = {
	roundId: number,
	getAlive: () -> { Player },
	isAlive: (player: Player) -> boolean,
	isRunning: () -> boolean, -- false once the round has a result or was torn down
	eliminate: (victim: Player, killer: Player?, cause: DefeatCause?) -> (),
}

export type RoundResult = {
	winners: { Player },
	reason: string,
}

export type GameMode = {
	name: string,
	minPlayers: number,

	-- Lifecycle -------------------------------------------------------------
	onRoundStart: (self: GameMode, ctx: RoundContext) -> (),
	onTick: (self: GameMode, ctx: RoundContext, dt: number) -> (),
	onRoundEnd: (self: GameMode, ctx: RoundContext) -> (),

	-- Combat hooks ----------------------------------------------------------
	-- Surge: anyone alive may kick. Juggernaut: only the Juggernaut kicks; runners can only parry.
	canLaunch: (self: GameMode, ctx: RoundContext, player: Player) -> boolean,
	canTarget: (self: GameMode, ctx: RoundContext, attacker: Player, target: Player) -> boolean,
	onDefeated: (self: GameMode, ctx: RoundContext, victim: Player, attacker: Player?, cause: DefeatCause) -> (),
	-- A strike landed but didn't explode the victim (`strikes` = their total now).
	onStruck: (self: GameMode, ctx: RoundContext, victim: Player, attacker: Player, strikes: number) -> (),
	onParried: (self: GameMode, ctx: RoundContext, defender: Player, attacker: Player, perfect: boolean) -> (),

	-- Win conditions --------------------------------------------------------
	getResult: (self: GameMode, ctx: RoundContext) -> RoundResult?, -- nil while undecided
	isFinalPhase: (self: GameMode, ctx: RoundContext) -> boolean, -- drives the Final Duel FOV/music
}

-- The limited handle a Leg Style behaviour gets on the flight it modifies.
export type FlightControl = {
	kickId: number,
	attacker: Player,
	target: Player,
	isActive: () -> boolean,
	-- Freeze mid-air for `duration` seconds, then run `after` (if the flight survived).
	freeze: (duration: number, after: (() -> ())?) -> (),
	-- Teleport along the flight path, leaving `leadTime` seconds of travel.
	blinkToward: (leadTime: number) -> (),
	-- Offset the real hitbox into a lateral lane (-1, 0, 1) that converges on the target.
	setLane: (lane: number, spread: number) -> (),
	-- Gap (studs) between kicker and target right now.
	currentGap: () -> number,
}

return {}
