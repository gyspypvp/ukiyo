--!strict
--[[
	Config (ModuleScript, ReplicatedStorage/Shared)
	===============================================
	Every gameplay tuning value in Clash Kick lives here.

	The module is shared on purpose:
	  * the SERVER treats these numbers as the rules and enforces them;
	  * the CLIENT only uses them to *predict* (cooldown mirrors, warning ring),
	    so editing this file on an exploited client gains nothing: every
	    decision is re-checked on the server.

	Every table is frozen so no module can mutate tuning at runtime.
]]

local Config = {}

-- Round flow ----------------------------------------------------------------
Config.Round = table.freeze({
	IntermissionTime = 15, -- seconds in the lobby between matches (upgrade / spin time)
	SpawnPhaseTime = 4, -- seconds between the arena teleport and the first Surge
	MatchEndTime = 6, -- seconds the "X WINS!" banner stays up
	MaxPlayers = 15, -- extra players sit the round out in the lobby
	MaxActiveTime = 300, -- failsafe: no round can run longer than this
	SurgeRespawnDelay = 1.5, -- after a KO, delay before the Surge re-infects someone
	EliminationReturnDelay = 1.25, -- ragdoll beat before a KO'd player is sent to the lobby
	ModeRotation = table.freeze({ "Surge" }), -- GameMode names the RoundManager cycles through
})

-- The homing dash-kick --------------------------------------------------------
Config.Kick = table.freeze({
	BaseSpeed = 75, -- studs/s of the opening kick of a rally
	MaxSpeed = 420, -- hard ceiling so the physics never tunnels or desyncs
	RallyGrowth = 1.10, -- every successful parry compounds speed by +10%
	MaxRallyMultiplier = 5, -- ceiling for RallyGrowth ^ rallyCount
	ImpactRadius = 4.5, -- root-to-root distance that counts as contact
	MaxTurnRate = math.rad(540), -- homing steering limit (radians/second)
	PureHomingDistance = 20, -- inside this gap the turn limit is dropped (no orbiting)
	MaxRange = 260, -- longest legal lock-on / launch distance
	MaxFlightTime = 8, -- failsafe: a flight older than this is cancelled
	ClashHoldBase = 0.05, -- minimum "clash frame" before a hit is confirmed
	AutoLaunchTime = 5, -- a Surge holder who stalls longer than this is auto-launched
	LaunchCooldown = 0.25, -- minimum gap between two launches by the same player
	ClosingFloor = 0.25, -- closing speed never drops below this fraction of flight speed
	EtaBroadcastInterval = 1 / 20, -- KickUpdated cadence (seconds)...
	EtaBroadcastDrift = 0.015, -- ...or sooner if the ETA moved by more than this
	HitFlingSpeed = 70, -- cosmetic fling applied to the KO'd player
})

-- The counter-dash (parry) ---------------------------------------------------
Config.Parry = table.freeze({
	BaseWindow = 0.30, -- Block counts if pressed up to this long before impact (before upgrades)
	PerfectWindow = 0.10, -- within this long of impact = Perfect parry
	PerfectBoost = 1.20, -- one-shot +20% speed for a Perfect counter-dash
	LateGrace = 0.03, -- tolerated "after impact" error (clock sync + frame rounding)
	WhiffCooldown = 0.45, -- lockout after a Block that didn't parry anything (anti-spam)
	StunTime = 0.5, -- a parried attacker hangs frozen mid-air for this long
	-- After a parry the stunned attacker is blasted back to this gap from the defender,
	-- so the counter-dash always has real distance to cover (and a reaction window).
	RicochetGap = 26, -- studs, defender standing still
	RicochetGapMin = 12, -- stepping in shrinks it down to this ("spike")
	RicochetGapMax = 40, -- backpedalling grows it up to this ("buy time")
	StanceFactor = 0.75, -- studs of gap per stud/s of defender stance velocity
	DistanceSlack = 3, -- extra studs tolerated by the parry distance check
})

-- Latency / lag compensation ---------------------------------------------------
Config.Latency = table.freeze({
	PingInterval = 1, -- seconds between nonce pings
	SampleCount = 9, -- RTT = median of the last N samples (spike resistant)
	DefaultRtt = 0.12, -- assumed RTT until real samples arrive
	MaxCompensation = 0.25, -- never rewind a parry further than this, however laggy the player
	JitterTolerance = 0.02, -- extra slack on top of measured jitter
	PingTimeout = 3, -- unanswered pings older than this are discarded
})

-- Camera dot-product lock-on -------------------------------------------------------
Config.Targeting = table.freeze({
	MinDot = math.cos(math.rad(28)), -- client lock-on cone (28° half-angle around the crosshair)
	ServerMinDot = math.cos(math.rad(75)), -- server plausibility cone (looser: ping + camera smoothing)
	DistanceWeight = 0.0006, -- prefer nearer players when two are equally centred
	StickyBonus = 0.015, -- hysteresis so the dot doesn't flicker between neighbours
	RequireLineOfSight = true,
	CameraSlack = 12, -- studs beyond CameraMaxZoomDistance the claimed camera may sit
})

-- Server-side anti-cheat heuristics ------------------------------------------------
Config.Integrity = table.freeze({
	SampleSize = 12, -- rolling window of successful parries to analyse
	PerfectRatioFlag = 0.9, -- flag if >= this share of the window is Perfect...
	StdDevFlag = 0.012, -- ...AND the timing spread is tighter than this (bots are metronomes)
	MinHumanReaction = 0.1, -- parries faster than this after the kick became visible are "inhuman"
	FastReactionFlag = 4, -- flag after this many inhuman reactions inside the window
	KickOnFlag = false, -- foundations only log; flip once thresholds are tuned on real data
})

Config.Movement = table.freeze({
	CheckInterval = 0.5, -- seconds between movement sanity checks
	SpeedTolerance = 1.6, -- allowed horizontal speed = WalkSpeed * tolerance + slack
	SpeedSlack = 6,
	TeleportFactor = 4, -- a single sample this many times over the limit snaps back instantly
	MaxViolations = 3, -- consecutive violations before rubber-banding
	ReleaseGrace = 0.75, -- skip checks right after the server hands physics back
	KillY = -60, -- falling below this height while in the arena = KO
	VerticalSpeedCap = 80, -- clamp used when reading client-reported velocity
})

-- Economy ---------------------------------------------------------------------
Config.Rewards = table.freeze({
	CoinsPerKill = 15,
	CoinsPerParry = 2,
	CoinsPerPerfect = 3, -- on top of CoinsPerParry
	WinPayout = 250, -- "massive" last-player-standing payout
	Participation = 5,
	MaxBet = 500,
	BetHouseEdge = 0.8, -- bet multiplier = max(MinBetMultiplier, aliveAtBet * edge)
	MinBetMultiplier = 1.2,
})

Config.Monetization = table.freeze({
	CrateKeyProductId = 0, -- TODO: your Developer Product id for one Leg Style crate key
	KeysPerPurchase = 1,
	DuplicateRefundCoins = 100, -- coins granted when a crate rolls a style you already own
})

-- Presentation ----------------------------------------------------------------
Config.Camera = table.freeze({
	DefaultFov = 70,
	FinalDuelFov = 84,
	FovTweenTime = 0.8,
})

-- Engine plumbing ---------------------------------------------------------------
Config.CollisionGroups = table.freeze({
	Characters = "CK_Characters",
	Flying = "CK_Flying", -- flying kickers pass through bystanders; contact is decided by math
})

Config.Tags = table.freeze({
	ArenaSpawn = "CK_ArenaSpawn", -- tag BaseParts in the arena with this
	LobbySpawn = "CK_LobbySpawn", -- tag BaseParts in the lobby with this
})

-- Token buckets: `rate` requests/second sustained, `burst` requests at once.
Config.RateLimits = table.freeze({
	Launch = table.freeze({ rate = 4, burst = 4 }),
	Parry = table.freeze({ rate = 6, burst = 6 }),
	Ability = table.freeze({ rate = 2, burst = 3 }),
	PingReply = table.freeze({ rate = 3, burst = 5 }),
	Lobby = table.freeze({ rate = 4, burst = 8 }),
})

return table.freeze(Config)
