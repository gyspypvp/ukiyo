--!strict
--[[
	Types (ModuleScript, ReplicatedStorage/Shared)
	==============================================
	Network payload shapes shared by server and client. Every payload that
	crosses the wire is described here, so both ends agree on the contract.

	All times are SERVER time (workspace:GetServerTimeNow()). Using one shared
	clock is what lets the client draw the warning ring for the exact moment the
	server will judge the parry (see docs/NETWORK_BRIDGE.md).
]]

export type Phase = "Waiting" | "Intermission" | "Spawning" | "Active" | "FinalDuel" | "MatchEnd"

-- Server -> all clients when a kick launches (opening kick OR counter-dash).
export type KickStartedPayload = {
	kickId: number,
	attackerId: number,
	targetId: number,
	rally: number, -- successful parries so far in this rally
	speed: number, -- studs/s
	startedAt: number, -- server time
	eta: number, -- predicted impact, server time
	perfect: boolean, -- launched by a Perfect parry (red aura)
}

-- Clashed: two players kicked EACH OTHER and met head-on; both bounce apart, no strike.
export type KickOutcome = "Parried" | "Hit" | "Clashed" | "Cancelled"

-- Server -> all clients when a kick ends.
export type KickResolvedPayload = {
	kickId: number,
	outcome: KickOutcome,
	attackerId: number,
	targetId: number,
	perfect: boolean, -- Parried: the parry was Perfect. Hit: the kick was a Perfect counter-dash (hits harder)
	direction: Vector3, -- flight direction at the end (used for the KO fling / spark)
	position: Vector3, -- contact point
	-- Context for the victim's hit card:
	rally: number, -- parries in the rally that produced this kick
	speed: number, -- studs/s of this kick
	strikes: number, -- target's strikes after this kick (a "Hit" adds one, an ULTIMATE more)
	exploded: boolean, -- this was the finishing strike: the target explodes
	ultimate: boolean, -- landed by an ULTIMATE (unblockable, worth Config.Ultimate.Strikes)
}

export type ParryResult = "Parry" | "Perfect" | "Early" | "Late" | "NoThreat" | "Cooldown" | "TooFar"

-- Server -> the presser only.
export type ParryFeedbackPayload = {
	result: ParryResult,
	kickId: number,
	lockUntil: number, -- server time; the client mirrors the whiff cooldown with this
}

export type EffectKind = "LagSwitch" | "Invis" | "ShadowClone"

-- Server -> all clients: Leg Style (ability) visuals.
export type EffectPayload = {
	kind: EffectKind,
	kickId: number,
	userId: number, -- the kicker using the style
	targetId: number,
	duration: number?, -- LagSwitch freeze length
	realLane: number?, -- ShadowClone: lane of the real hitbox (-1, 0, 1)
	spread: number?, -- ShadowClone: lateral studs between lanes
	initialGap: number?, -- ShadowClone: gap at activation (lanes converge as it shrinks)
}

export type UltimateStage = "Leap" | "Dive" | "Miss" | "Cancelled"

-- Server -> all clients: an ULTIMATE's telegraph. A landed ultimate arrives as a
-- KickResolvedPayload with ultimate = true (same id), so hit feedback is shared.
export type UltimatePayload = {
	stage: UltimateStage,
	id: number, -- shares the kick id space
	userId: number, -- the player performing it
	targetId: number,
	diveAt: number?, -- Leap: server time the dive begins
	impactPoint: Vector3?, -- Dive / Miss: where it lands
	impactAt: number?, -- Dive: server time it lands
	radius: number?, -- Dive: hit radius around impactPoint
}

export type RoundEventKind = "Winner" | "Draw" | "Eliminated" | "NoContest"

-- Why a fighter went down. The GameMode decides what each cause means.
export type DefeatCause = "Kick" | "Void" | "Died" | "Left"

-- Server -> all clients: one-off round announcements (persistent state uses attributes).
export type RoundEventPayload = {
	kind: RoundEventKind,
	userId: number?,
	killerId: number?, -- for Void: the last attacker who knocked them off, if recent
	displayName: string?, -- Draw: all winners' names joined with " & "
	cause: DefeatCause?, -- Eliminated only
}

-- Types-only module: requiring it is free; the table is never used at runtime.
return {}
