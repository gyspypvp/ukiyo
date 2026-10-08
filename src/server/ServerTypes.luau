--!strict
--[[
	ServerTypes (ModuleScript, server)
	==================================
	The contracts that make the game modular. CombatService, RoundManager and
	every GameMode only talk to each other through these shapes.

	                 +--------------+  CombatRules (canTarget)   +---------------+
	                 |              | -------------------------> |               |
	                 | RoundManager |                            | CombatService |
	                 |              | <------------------------- |               |
	                 +--------------+  Signals (Defeated, ...)   +---------------+
	                        |  ^                                        ^
	   lifecycle hooks      v  |  RoundContext (eliminate, alive...)    | CombatApi
	                 +--------------+                                   |
	                 |   GameMode   | ----------------------------------+
	                 | Surge / Jugg.|   grantSurge / clearSurge
	                 +--------------+

	A new mode (e.g. Juggernaut) is ONE new file implementing GameMode. Neither
	the combat physics nor the round state machine needs to change.
]]

-- Why a fighter went down. The GameMode decides what each cause means
-- (Surge: always elimination; Juggernaut: maybe the tagger has lives).
export type DefeatCause = "Kick" | "Void" | "Died" | "Left"

-- What CombatService asks the active mode before allowing a kick.
export type CombatRules = {
	canTarget: (attacker: Player, target: Player) -> boolean,
}

-- The slice of CombatService a GameMode is allowed to drive.
export type CombatApi = {
	grantSurge: (player: Player, rally: number?) -> (),
	clearSurge: (player: Player) -> (),
	getSurgeHolders: () -> { Player },
}

-- Handed to a GameMode by the RoundManager for the lifetime of one round.
export type RoundContext = {
	roundId: number,
	getAlive: () -> { Player },
	isAlive: (player: Player) -> boolean,
	isRunning: () -> boolean, -- false once the round has a result or was torn down
	eliminate: (victim: Player, killer: Player?) -> (),
	combat: CombatApi,
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
	canTarget: (self: GameMode, ctx: RoundContext, attacker: Player, target: Player) -> boolean,
	onDefeated: (self: GameMode, ctx: RoundContext, victim: Player, attacker: Player?, cause: DefeatCause) -> (),
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
