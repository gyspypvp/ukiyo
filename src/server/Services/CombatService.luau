--!strict
--[[
	CombatService (ModuleScript, server)
	====================================
	The authority for everything that happens in a fight. Anyone may kick at
	any moment (one flight at a time, a short cooldown after each), so many
	kicks can be in the air at once and several can chase the same player.

	  * the homing dash-kick: LinearVelocity + AlignOrientation on a
	    SERVER-OWNED character, so the flight can't be speed-hacked or teleported
	  * contact detection, done with server math and never reported by a client
	  * parry validation, lag-compensated and checked on both timing and distance
	  * speed compounding across the rally
	  * stun, ricochet gap and counter-dash (ricochet / redirect)
	  * head-on clashes (two players kicking each other bounce apart)
	  * duels: each parry in a rally pulls the two closer, and mashing Block is
	    free inside a duel (Blade Ball-style close-range exchanges)
	  * strikes: every landed kick is one; Config.Strikes.ToExplode explodes you
	  * DASH (server-driven dodge burst) and ULTIMATE (charged, unblockable
	    leap-and-dive kick that doesn't home during the dive)
	  * basic physics-exploit checks (speed/teleport rubber-banding, void KO)

	It knows nothing about rounds, lobbies or win conditions. Those come from a
	CombatRules object injected by the RoundManager, which forwards to the active
	GameMode (who may kick, who may be kicked). A Juggernaut mode can reuse this
	file untouched; it only swaps the rules.

	LIFE OF A KICK
	--------------
	  RequestLaunch --validate--> startFlight --Heartbeat steer--> contact?
	                                                                  |
	          target kicking us back at the same time? -> head-on clash, both bounce
	                                                                  |
	              +---------------- "Clash" hold (latency-bounded) ---+
	              |                                                   |
	   RequestParry (valid) -> resolveParry                 no parry -> resolveHit
	     attacker blasted back (duel-tightened gap)           +1 strike
	     defender startFlight(rally + 1) ---> (loops)         3rd strike -> explode (Defeated "Kick")
	                                                          else       -> tumble + Struck
]]

local Players = game:GetService("Players")
local PhysicsService = game:GetService("PhysicsService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage.Shared
local CombatMath = require(Shared.CombatMath)
local Config = require(Shared.Config)
local Net = require(Shared.Net)
local Signal = require(Shared.Signal)
local Targeting = require(Shared.Targeting)
local Types = require(Shared.Types)

local Server = script.Parent.Parent
local Guard = require(Server.Util.Guard)
local RateLimiter = require(Server.Util.RateLimiter)
local ServerTypes = require(Server.ServerTypes)
local AbilityService = require(script.Parent.AbilityService)
local LatencyService = require(script.Parent.LatencyService)
local PlayerDataService = require(script.Parent.PlayerDataService)

local ATTR = Net.Attributes
local KICK = Config.Kick
local PARRY = Config.Parry
local STRIKES = Config.Strikes
local DUEL = Config.Duel
local DASH = Config.Dash
local ULT = Config.Ultimate

-- Gap history kept per flight for the parry distance check. At 60 Hz this is
-- ~1.5 s, far more than the largest lag compensation we ever allow.
local SAMPLE_CAPACITY = 90

local SPEED_PARAMS: CombatMath.SpeedParams = {
	baseSpeed = KICK.BaseSpeed,
	growth = KICK.RallyGrowth,
	maxMultiplier = KICK.MaxRallyMultiplier,
	maxSpeed = KICK.MaxSpeed,
}

type DefeatCause = ServerTypes.DefeatCause

type Mover = {
	attachment: Attachment,
	velocity: LinearVelocity,
	align: AlignOrientation,
}

type Integrity = {
	timings: { number }, -- time-to-impact of recent successful parries
	perfects: { boolean },
	fast: { boolean }, -- reaction faster than humanly possible
	nextSlot: number,
	flagged: boolean,
}

type Fighter = {
	player: Player,
	character: Model,
	humanoid: Humanoid,
	root: BasePart,
	mover: Mover,
	connections: { RBXScriptConnection },
	defeated: boolean,

	-- Strikes (every landed kick is one; ToExplode and you explode)
	strikes: number,
	lastHitBy: Player?, -- credited if a hit knocks them off the arena
	lastHitAt: number,

	-- Duel / DASH / ULTIMATE
	duelUntil: number, -- inside a duel until this time: a missed Block costs no lockout
	dashReadyAt: number,
	ultCharge: number, -- 0..1, ULTIMATE ready at 1
	ultPublished: number, -- last ultCharge written to the attribute (throttles replication)
	parryCharge: number, -- meter earned from parries this round (capped by ULT.MaxParryChargePerRound)
	ultimate: UltimateState?, -- the ULTIMATE this fighter is performing

	-- Kicks
	flight: Flight?, -- the kick this fighter is performing (at most one)
	incoming: { [number]: Flight }, -- every kick currently aimed at this fighter, by kick id
	kickReadyAt: number, -- server time when this fighter may start a new kick
	parryLockUntil: number, -- whiff cooldown

	-- Server-driven physics (flight + stun)
	serverOwned: boolean,
	stunUntil: number,
	holdUntil: number,

	-- Movement sanity
	releaseGraceUntil: number,
	lastGoodPosition: Vector3,
	lastCheckPosition: Vector3,
	lastCheckAt: number,
	violations: number,
}

type FlightPhase = "Flying" | "Frozen" | "Clash"

type Flight = {
	id: number,
	active: boolean,
	attacker: Fighter,
	target: Fighter,
	rally: number,
	speed: number,
	perfect: boolean,
	predictable: boolean, -- a ricochet straight back at the previous attacker (anticipation is legit)
	startedAt: number,
	phase: FlightPhase,
	direction: Vector3,
	eta: number, -- predicted impact (server time)
	impactAt: number?, -- actual contact (server time)
	resolveAt: number, -- when an un-parried clash becomes a hit
	frozenUntil: number,
	afterFreeze: (() -> ())?,
	lane: number, -- Shadow Clone lane of the real hitbox
	laneSpread: number,
	laneStartGap: number,
	sampleTimes: { number },
	sampleGaps: { number },
	nextSample: number,
	lastEtaSent: number,
	lastEtaSentAt: number,
	abilityUsed: boolean,
}

type UltimateStage = "Leap" | "Dive"

type UltimateState = {
	id: number,
	attacker: Fighter,
	target: Fighter,
	stage: UltimateStage,
	diveAt: number,
	apex: Vector3,
	direction: Vector3,
	heading: Vector3, -- flat direction of the leap (keeps the body's facing through a steep dive)
	apexHoldUntil: number, -- the leap may hang at its apex until here, waiting for a stunned target
	impactPoint: Vector3, -- locked at the top of the leap; the dive flies straight at it
	impactAt: number,
	speed: number, -- dive speed (studs/s), for the hit card
	held: boolean, -- paused because a kick has made contact with the performer
}

local CombatService = {}

-- Signals (deferred; see Signal.luau) -------------------------------------------------
local defeated: Signal.Signal<Player, Player?, DefeatCause> = Signal.new()
local struck: Signal.Signal<Player, Player, number> = Signal.new()
local parried: Signal.Signal<Player, Player, boolean, number> = Signal.new()
local launched: Signal.Signal<Player, Player, number, number> = Signal.new()
local flagged: Signal.Signal<Player, string> = Signal.new()

CombatService.Defeated = defeated -- (victim, attacker?, cause): exploded / fell / died / left
CombatService.Struck = struck -- (victim, attacker, strikes): a kick landed, victim survived it
CombatService.Parried = parried -- (defender, attacker, perfect, rallyCount)
CombatService.Launched = launched -- (attacker, target, rallyCount, speed)
CombatService.Flagged = flagged -- (player, reason): integrity heuristics tripped

-- State --------------------------------------------------------------------------
local DEFAULT_RULES: ServerTypes.CombatRules = {
	canLaunch = function(_player: Player): boolean
		return true
	end,
	canTarget = function(_attacker: Player, _target: Player): boolean
		return true
	end,
}

local fighters: { [Player]: Fighter } = {}
local flights: { [number]: Flight } = {}
local ultimates: { [number]: UltimateState } = {}
local integrityByPlayer: { [Player]: Integrity } = {}
local rules: ServerTypes.CombatRules = DEFAULT_RULES
local remotes: Net.Remotes? = nil
local nextKickId = 0
local lastMovementCheck = 0

local launchLimiter = RateLimiter.new(Config.RateLimits.Launch.rate, Config.RateLimits.Launch.burst)
local parryLimiter = RateLimiter.new(Config.RateLimits.Parry.rate, Config.RateLimits.Parry.burst)
local abilityLimiter = RateLimiter.new(Config.RateLimits.Ability.rate, Config.RateLimits.Ability.burst)
local dashLimiter = RateLimiter.new(Config.RateLimits.Dash.rate, Config.RateLimits.Dash.burst)
local ultimateLimiter = RateLimiter.new(Config.RateLimits.Ultimate.rate, Config.RateLimits.Ultimate.burst)

-- Small helpers ----------------------------------------------------------------------

-- One clock for everything: the same synced clock clients read with
-- workspace:GetServerTimeNow(), so timestamps compare directly across the wire.
local function now(): number
	return Workspace:GetServerTimeNow()
end

local function net(): Net.Remotes
	return assert(remotes, "CombatService.init() has not run")
end

local function isAlive(fighter: Fighter): boolean
	return not fighter.defeated
		and fighters[fighter.player] == fighter
		and fighter.humanoid.Health > 0
		and fighter.root:IsDescendantOf(Workspace)
end

local function setCollisionGroup(character: Model, group: string)
	for _, descendant in character:GetDescendants() do
		if descendant:IsA("BasePart") then
			descendant.CollisionGroup = group
		end
	end
end

-- Orientation that points the FEET along `direction` (a flying dropkick).
-- lookAt aims -Z along the direction; rotating +90° about X turns -Y (feet) onto it.
-- `facing` (optional, horizontal) picks which way the chest turns for a near-vertical
-- direction, e.g. an ULTIMATE diving almost straight down keeps its leap heading.
local function feetFirst(direction: Vector3, facing: Vector3?): CFrame
	local up = if math.abs(direction.Y) > 0.98 then (facing or Vector3.zAxis) else Vector3.yAxis
	return CFrame.lookAt(Vector3.zero, direction, up) * CFrame.Angles(math.pi / 2, 0, 0)
end

-- Rotate `current` toward `desired` by at most `maxAngle` radians (slerp). Both unit vectors.
local function steer(current: Vector3, desired: Vector3, maxAngle: number): Vector3
	local angle = math.acos(math.clamp(current:Dot(desired), -1, 1))
	if angle <= maxAngle then
		return desired
	end
	local sinAngle = math.sin(angle)
	if sinAngle < 1e-4 then
		return desired -- exactly opposite: no unique arc, snap
	end
	local t = maxAngle / angle
	return ((current * math.sin((1 - t) * angle) + desired * math.sin(t * angle)) / sinAngle).Unit
end

-- Fastest a fighter could legitimately run (studs/s, horizontal).
local function runCap(fighter: Fighter): number
	return fighter.humanoid.WalkSpeed * 1.25 + 4
end

--[[
	A client-owned character's velocity is reported by that client, so it is
	UNTRUSTED. Before it feeds any math (ETA, ricochet gap) it is clamped to
	what this humanoid could legitimately be doing. A server-owned (flying /
	stunned) fighter's velocity is ours and is used as-is.
]]
local function trustedVelocity(fighter: Fighter): Vector3
	local velocity = fighter.root.AssemblyLinearVelocity
	if fighter.serverOwned then
		return velocity
	end
	local horizontal = Vector3.new(velocity.X, 0, velocity.Z)
	local cap = runCap(fighter)
	if horizontal.Magnitude > cap then
		horizontal = horizontal.Unit * cap
	end
	local verticalCap = Config.Movement.VerticalSpeedCap
	return horizontal + Vector3.new(0, math.clamp(velocity.Y, -verticalCap, verticalCap), 0)
end

-- Raycast params that see the map but not any fighter.
local function excludeFighters(): RaycastParams
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	local exclude: { Instance } = {}
	for _, fighter in fighters do
		table.insert(exclude, fighter.character)
	end
	params.FilterDescendantsInstances = exclude
	return params
end

local function integrityFor(player: Player): Integrity
	local integrity = integrityByPlayer[player]
	if integrity == nil then
		integrity = { timings = {}, perfects = {}, fast = {}, nextSlot = 1, flagged = false }
		integrityByPlayer[player] = integrity
	end
	return integrity :: Integrity
end

-- Physics authority ---------------------------------------------------------------

--[[
	Hand the character's physics to the server. While a fighter is a missile (or
	stunned mid-air) the SERVER simulates its assembly, so nothing the client does
	locally (speed hacks, teleports, deleting the constraint, anchoring) has any
	effect on where it actually is.
]]
local function takeOwnership(fighter: Fighter)
	if fighter.serverOwned then
		return
	end
	fighter.serverOwned = true
	fighter.humanoid.PlatformStand = true -- stop the Humanoid fighting the constraints
	local ok, err = pcall(function()
		fighter.root:SetNetworkOwner(nil)
	end)
	if not ok then
		warn(`[CombatService] could not take network ownership of {fighter.player.Name}: {err}`)
	end
end

-- Give physics back to the client (flight, stun, dash or ULTIMATE over, or leaving
-- the arena). `facing` optionally sets the heading the body stands up with.
local function release(fighter: Fighter, facing: Vector3?)
	local mover = fighter.mover
	mover.velocity.Enabled = false
	mover.velocity.VectorVelocity = Vector3.zero
	mover.align.Enabled = false
	fighter.holdUntil = 0
	fighter.stunUntil = 0
	fighter.player:SetAttribute(ATTR.Stunned, false)

	if not fighter.serverOwned then
		return
	end
	fighter.serverOwned = false
	local root = fighter.root

	-- Stand the body back up (keep position and heading). A flight leaves it
	-- feet-first and a tumble leaves it toppled; handing a tilted, spinning body
	-- to the client makes the Humanoid flop around for a second.
	-- Heading = Up x Right. Flights (feetFirst) and most tumbles only pitch the body
	-- about its right axis, which stays horizontal, so this is the forward direction
	-- at ANY pitch (for an upright body it equals the flat LookVector). Using
	-- LookVector directly would face the body backwards after an upward kick.
	local cframe = root.CFrame
	local heading = Vector3.yAxis:Cross(cframe.RightVector)
	heading = Vector3.new(heading.X, 0, heading.Z)
	if heading.Magnitude < 0.2 then
		local down = -cframe.UpVector -- rolled onto its side: Right is near vertical
		heading = Vector3.new(down.X, 0, down.Z)
	end
	local flatFacing = if facing then Vector3.new(facing.X, 0, facing.Z) else Vector3.zero
	if flatFacing.Magnitude > 1e-3 then
		heading = flatFacing
	end
	if heading.Magnitude > 1e-3 then
		-- If the body is lying on the floor, stand it at proper height so the legs don't sink in.
		local position = root.Position
		local humanoid = fighter.humanoid
		local legs = if humanoid.RigType == Enum.HumanoidRigType.R6 then 2 else humanoid.HipHeight
		local standHeight = legs + root.Size.Y / 2
		local params = RaycastParams.new()
		params.FilterType = Enum.RaycastFilterType.Exclude
		params.FilterDescendantsInstances = { fighter.character }
		local floor = Workspace:Raycast(position, Vector3.new(0, -(standHeight + 0.5), 0), params)
		if floor then
			position = Vector3.new(position.X, floor.Position.Y + standHeight, position.Z)
		end
		root.CFrame = CFrame.lookAt(position, position + heading.Unit)
	end

	-- No spin, no horizontal or upward momentum (the client can't inherit a 400
	-- stud/s fling), but keep any downward speed so a mid-air release keeps falling
	-- instead of stopping dead.
	root.AssemblyAngularVelocity = Vector3.zero
	root.AssemblyLinearVelocity = Vector3.new(0, math.min(root.AssemblyLinearVelocity.Y, 0), 0)
	fighter.humanoid.PlatformStand = false
	setCollisionGroup(fighter.character, Config.CollisionGroups.Characters)
	if fighter.root:IsDescendantOf(Workspace) then
		pcall(function()
			fighter.root:SetNetworkOwner(fighter.player)
		end)
	end
	-- Ownership hand-back causes a small replication hitch; don't flag it as a speed hack.
	fighter.releaseGraceUntil = now() + Config.Movement.ReleaseGrace
end

--[[
	STUN: momentum cancelled, frozen mid-air for `duration`. A zero-velocity
	LinearVelocity with infinite force holds the body perfectly still against
	gravity. A stunned fighter cannot launch or move, but CAN still parry.
	Without that, any counter-dash that arrives inside 0.5 s would be an
	unanswerable kill and the ping-pong could never happen.
]]
local function stun(fighter: Fighter, duration: number, facing: Vector3)
	local t = now()
	takeOwnership(fighter)
	fighter.stunUntil = t + duration
	fighter.holdUntil = t + duration
	fighter.player:SetAttribute(ATTR.Stunned, true)

	local mover = fighter.mover
	mover.velocity.VectorVelocity = Vector3.zero
	mover.velocity.Enabled = true
	local flat = Vector3.new(facing.X, 0, facing.Z)
	if flat.Magnitude > 1e-3 then
		mover.align.CFrame = CFrame.lookAt(Vector3.zero, flat.Unit)
	end
	mover.align.Enabled = true
end

--[[
	TUMBLE: a strike that doesn't explode the victim sends them flying along the
	kick with real physics (server-owned, gravity on, constraints off) for
	HitTumbleTime. The victim can't launch until it ends; then stepHolds hands
	physics back. Near an edge a tumble can carry them off the arena, which is
	credited to the attacker as a KO (Config.Strikes.LastHitCredit).
]]
local function tumble(fighter: Fighter, direction: Vector3)
	local t = now()
	takeOwnership(fighter) -- also PlatformStand: the body goes limp and tumbles
	fighter.stunUntil = t + STRIKES.HitTumbleTime
	fighter.holdUntil = t + STRIKES.HitTumbleTime
	fighter.player:SetAttribute(ATTR.Stunned, true)

	fighter.mover.velocity.Enabled = false
	fighter.mover.align.Enabled = false
	local flat = Vector3.new(direction.X, 0, direction.Z)
	local push = if flat.Magnitude > 1e-3 then flat.Unit else Vector3.zero
	fighter.root.AssemblyLinearVelocity = push * STRIKES.HitFlingSpeed + Vector3.yAxis * STRIKES.HitFlingLift
	fighter.root.AssemblyAngularVelocity = push:Cross(Vector3.yAxis) * -6 -- head-over-heels spin
end

-- The LinearVelocity rig, created once per arena entry and toggled on/off.
local function createMover(root: BasePart): Mover
	local attachment = Instance.new("Attachment")
	attachment.Name = "CK_KickAttachment"
	attachment.Parent = root

	local velocity = Instance.new("LinearVelocity")
	velocity.Name = "CK_KickVelocity"
	velocity.Attachment0 = attachment
	velocity.RelativeTo = Enum.ActuatorRelativeTo.World
	velocity.VelocityConstraintMode = Enum.VelocityConstraintMode.Vector
	velocity.MaxForce = math.huge -- overrides gravity: the kick flies dead straight
	velocity.VectorVelocity = Vector3.zero
	velocity.Enabled = false
	velocity.Parent = root

	local align = Instance.new("AlignOrientation")
	align.Name = "CK_KickAlign"
	align.Mode = Enum.OrientationAlignmentMode.OneAttachment
	align.Attachment0 = attachment
	align.RigidityEnabled = true
	align.Enabled = false
	align.Parent = root

	return { attachment = attachment, velocity = velocity, align = align }
end

-- Network ----------------------------------------------------------------------------

local function recordSample(flight: Flight, t: number, gap: number)
	local slot = flight.nextSample
	flight.sampleTimes[slot] = t
	flight.sampleGaps[slot] = gap
	flight.nextSample = slot % SAMPLE_CAPACITY + 1
end

-- The gap (studs) the server measured at time `at`: newest sample at or before it.
local function gapAt(flight: Flight, at: number): number
	local bestTime, bestGap = -math.huge, math.huge
	local oldestTime, oldestGap = math.huge, math.huge
	for index, sampleTime in flight.sampleTimes do
		if sampleTime <= at and sampleTime > bestTime then
			bestTime, bestGap = sampleTime, flight.sampleGaps[index]
		end
		if sampleTime < oldestTime then
			oldestTime, oldestGap = sampleTime, flight.sampleGaps[index]
		end
	end
	return if bestTime > -math.huge then bestGap else oldestGap
end

--[[
	ETA sync. The impact ETA changes every frame as the target moves, but
	only the TARGET draws a warning ring from it, so it goes to the target alone
	(with many kicks in the air, broadcasting every ETA to everyone would waste
	bandwidth). Sent at most every EtaBroadcastInterval, and only on a drift >
	EtaBroadcastDrift (or as a keep-alive every 4 intervals), over an
	UnreliableRemoteEvent because every update supersedes the previous one.
	-1 means "frozen / unknown".
]]
local function broadcastEta(flight: Flight, t: number, force: boolean?)
	local eta = if flight.phase == "Frozen" then -1 else flight.eta
	local sinceLast = t - flight.lastEtaSentAt
	local drifted = math.abs(eta - flight.lastEtaSent) > KICK.EtaBroadcastDrift
	if
		force or (sinceLast >= KICK.EtaBroadcastInterval and (drifted or sinceLast >= KICK.EtaBroadcastInterval * 4))
	then
		flight.lastEtaSent = eta
		flight.lastEtaSentAt = t
		net().KickUpdated:FireClient(flight.target.player, flight.id, eta, t)
	end
end

-- The rally / speed / strike numbers are what the victim's hit card shows, so
-- "who hit me and why" is always answered.
local function broadcastResolved(
	flight: Flight,
	outcome: Types.KickOutcome,
	perfect: boolean,
	at: Vector3? -- where it happened (defaults to the kicker's position)
)
	local target = flight.target
	local payload: Types.KickResolvedPayload = {
		kickId = flight.id,
		outcome = outcome,
		attackerId = flight.attacker.player.UserId,
		targetId = target.player.UserId,
		perfect = perfect,
		direction = flight.direction,
		position = at or flight.attacker.root.Position,
		rally = flight.rally,
		speed = flight.speed,
		strikes = target.strikes,
		exploded = outcome == "Hit" and target.strikes >= STRIKES.ToExplode,
		ultimate = false,
	}
	net().KickResolved:FireAllClients(payload)
end

-- A landed ULTIMATE shares KickResolved (and so all of the hit feedback) with kicks.
local function broadcastUltimateHit(ult: UltimateState, exploded: boolean)
	local payload: Types.KickResolvedPayload = {
		kickId = ult.id,
		outcome = "Hit",
		attackerId = ult.attacker.player.UserId,
		targetId = ult.target.player.UserId,
		perfect = false,
		direction = ult.direction,
		position = ult.impactPoint,
		rally = 0,
		speed = ult.speed,
		strikes = ult.target.strikes,
		exploded = exploded,
		ultimate = true,
	}
	net().KickResolved:FireAllClients(payload)
end

-- The ULTIMATE telegraph every client draws (leap, impact marker, miss, cancel).
local function fireUltimate(ult: UltimateState, stage: Types.UltimateStage)
	local diving = ult.stage == "Dive"
	local payload: Types.UltimatePayload = {
		stage = stage,
		id = ult.id,
		userId = ult.attacker.player.UserId,
		targetId = ult.target.player.UserId,
		diveAt = ult.diveAt,
		impactPoint = if diving then ult.impactPoint else nil,
		impactAt = if diving then ult.impactAt else nil,
		radius = ULT.Radius,
	}
	net().Ultimate:FireAllClients(payload)
end

local function sendParryFeedback(fighter: Fighter, result: Types.ParryResult, kickId: number)
	local payload: Types.ParryFeedbackPayload = {
		result = result,
		kickId = kickId,
		lockUntil = fighter.parryLockUntil,
	}
	net().ParryFeedback:FireClient(fighter.player, payload)
end

-- Defeat ---------------------------------------------------------------------------

local function defeat(fighter: Fighter, attacker: Player?, cause: DefeatCause)
	if fighter.defeated then
		return
	end
	fighter.defeated = true
	defeated:Fire(fighter.player, attacker, cause)
end

--[[
	Who should be credited if this fighter goes down without a lethal kick
	(knocked off the arena, then fell, reset or left)? Whoever last displaced
	them (a hit tumble or a parry blast) within LastHitCredit seconds. It's
	cleared as soon as the fighter launches again, so an old hit never gets
	credit for a fall the fighter caused themselves.
]]
local function recentAttacker(fighter: Fighter): Player?
	local by = fighter.lastHitBy
	if by and now() - fighter.lastHitAt <= STRIKES.LastHitCredit then
		return by
	end
	return nil
end

-- Targets ----------------------------------------------------------------------------

-- Several kicks may chase the same target; anyone alive and in range is fair game.
local function isEligibleTarget(attacker: Fighter, target: Fighter): boolean
	return target ~= attacker
		and isAlive(target)
		and (target.root.Position - attacker.root.Position).Magnitude <= KICK.MaxRange
		and rules.canTarget(attacker.player, target.player)
end

-- When this kick would land (math.huge while frozen by a Lag Switch).
local function impactTimeOf(flight: Flight): number
	return if flight.phase == "Frozen" then math.huge else (flight.impactAt or flight.eta)
end

-- Has a kick already made contact with this fighter (its clash frame is running)?
local function beingStruck(fighter: Fighter): boolean
	for _, incoming in fighter.incoming do
		if incoming.active and incoming.phase == "Clash" then
			return true
		end
	end
	return false
end

--[[
	Blast a fighter back so it ends up `gap` studs from `origin` along `axis`,
	unless it is already further away. The move is an instant server-side
	reposition, not a glide: after a parry the counter-dash launches on the same
	frame, and a glide would be overtaken at high rally speeds, turning every late
	parry into a point-blank, unanswerable kill.
	A raycast stops the blast at walls and floors.
]]
local function blastBack(fighter: Fighter, origin: Vector3, axis: Vector3, gap: number)
	local start = fighter.root.Position
	local destination = origin + axis * gap
	if (start - origin).Magnitude >= gap then
		return
	end

	local hit = Workspace:Raycast(start, destination - start, excludeFighters())
	if hit then
		destination = hit.Position - axis * 2 -- stop just short of the wall
	end
	fighter.root.CFrame = CFrame.new(destination) * fighter.root.CFrame.Rotation
end

-- Is there ground somewhere below `position` (not the void past an arena edge)?
local GROUND_PROBE = 50
local function hasGround(position: Vector3): boolean
	return Workspace:Raycast(position, Vector3.new(0, -GROUND_PROBE, 0), excludeFighters()) ~= nil
end

-- Flights ----------------------------------------------------------------------------

-- Forward declaration: startFlight (a parry made mid-flight) needs finishFlight, defined below it.
local finishFlight: (flight: Flight) -> ()

--[[
	LAUNCH: the kicker becomes a human missile.
	  1. take server ownership of the kicker's physics,
	  2. drive it with a world-space LinearVelocity (infinite force, no gravity)
	     and an AlignOrientation that keeps it feet-first,
	  3. move it into the "Flying" collision group so it passes through bystanders
	     (contact is decided by math, not by Touched).
]]
local function startFlight(
	attacker: Fighter,
	target: Fighter,
	rally: number,
	perfect: boolean,
	predictable: boolean
): Flight
	local t = now()
	nextKickId += 1

	-- Parrying while already flying: the ricochet replaces your current kick.
	local previous = attacker.flight
	if previous then
		finishFlight(previous)
		broadcastResolved(previous, "Cancelled", false)
	end

	-- Too close to react to? Hop back to MinKickDistance first, so every kick has
	-- travel time to parry. (A ricochet straight back at the parried attacker is
	-- exempt: the ricochet gap already sets that distance.)
	takeOwnership(attacker)
	if not predictable then
		local away = attacker.root.Position - target.root.Position
		if away.Magnitude < KICK.MinKickDistance then
			local axis = if away.Magnitude > 1e-3 then away.Unit else -attacker.root.CFrame.LookVector
			blastBack(attacker, target.root.Position, axis, KICK.MinKickDistance)
		end
	end

	local offset = target.root.Position - attacker.root.Position
	local gap = offset.Magnitude
	local direction = if gap > 1e-3 then offset / gap else attacker.root.CFrame.LookVector
	local speed = CombatMath.kickSpeed(SPEED_PARAMS, rally, if perfect then PARRY.PerfectBoost else 1)

	local flight: Flight = {
		id = nextKickId,
		active = true,
		attacker = attacker,
		target = target,
		rally = rally,
		speed = speed,
		perfect = perfect,
		predictable = predictable,
		startedAt = t,
		phase = "Flying",
		direction = direction,
		eta = t + CombatMath.timeToImpact(gap, KICK.ImpactRadius, speed),
		impactAt = nil,
		resolveAt = math.huge,
		frozenUntil = 0,
		afterFreeze = nil,
		lane = 0,
		laneSpread = 0,
		laneStartGap = gap,
		sampleTimes = table.create(SAMPLE_CAPACITY),
		sampleGaps = table.create(SAMPLE_CAPACITY),
		nextSample = 1,
		lastEtaSent = 0,
		lastEtaSentAt = t,
		abilityUsed = false,
	}

	-- A counter-dash launched from mid-air supersedes the stun hover.
	attacker.stunUntil = 0
	attacker.holdUntil = 0
	attacker.lastHitBy = nil -- acting again: an old hit no longer gets credit for a later fall
	attacker.player:SetAttribute(ATTR.Stunned, false)

	takeOwnership(attacker)
	local mover = attacker.mover
	mover.velocity.VectorVelocity = direction * speed
	mover.align.CFrame = feetFirst(direction)
	mover.velocity.Enabled = true
	mover.align.Enabled = true
	setCollisionGroup(attacker.character, Config.CollisionGroups.Flying)

	attacker.flight = flight
	target.incoming[flight.id] = flight
	flights[flight.id] = flight
	recordSample(flight, t, gap)

	attacker.player:SetAttribute(ATTR.Flying, true)

	local payload: Types.KickStartedPayload = {
		kickId = flight.id,
		attackerId = attacker.player.UserId,
		targetId = target.player.UserId,
		rally = rally,
		speed = speed,
		startedAt = t,
		eta = flight.eta,
		perfect = perfect,
	}
	net().KickStarted:FireAllClients(payload)
	launched:Fire(attacker.player, target.player, rally, speed)
	return flight
end

-- Detach a flight from both fighters and start the kicker's cooldown.
-- Does NOT release the kicker's physics.
function finishFlight(flight: Flight)
	flight.active = false
	flights[flight.id] = nil
	local attacker = flight.attacker
	if attacker.flight == flight then
		attacker.flight = nil
	end
	flight.target.incoming[flight.id] = nil
	attacker.kickReadyAt = now() + KICK.Cooldown
	attacker.player:SetAttribute(ATTR.KickReadyAt, attacker.kickReadyAt)
	attacker.mover.velocity.VectorVelocity = Vector3.zero
	attacker.player:SetAttribute(ATTR.Flying, false)
	if attacker.character.Parent then
		setCollisionGroup(attacker.character, Config.CollisionGroups.Characters)
	end
end

-- Abort a kick (target gone, timeout, ...). The kicker lands and may kick again after the cooldown.
local function cancelFlight(flight: Flight)
	finishFlight(flight)
	release(flight.attacker)
	broadcastResolved(flight, "Cancelled", false)
end

-- Strikes and the ULTIMATE meter -------------------------------------------------------

--[[
	ULTIMATE meter (0..1). It fills from landed kicks, parries and slowly over
	time. The attribute is only written in 2% steps (or when it empties or
	fills), so the passive trickle doesn't replicate every frame.
]]
local function setCharge(fighter: Fighter, value: number)
	fighter.ultCharge = math.clamp(value, 0, 1)
	local charge = fighter.ultCharge
	if charge >= 1 or charge == 0 or math.abs(charge - fighter.ultPublished) >= 0.02 then
		fighter.ultPublished = charge
		fighter.player:SetAttribute(ATTR.UltCharge, charge)
	end
end

-- Returns true if it charged. Only fighters the mode lets attack charge at all (a
-- Juggernaut runner, who can never fire an ULTIMATE, doesn't), and not mid-ULTIMATE.
local function addCharge(fighter: Fighter, amount: number): boolean
	if fighter.ultimate ~= nil or fighter.ultCharge >= 1 or not rules.canLaunch(fighter.player) then
		return false
	end
	setCharge(fighter, fighter.ultCharge + amount)
	return true
end

-- Drop an ULTIMATE from the registries (no broadcast, no physics change).
local function endUltimate(ult: UltimateState)
	ultimates[ult.id] = nil
	local attacker = ult.attacker
	if attacker.ultimate == ult then
		attacker.ultimate = nil
	end
	attacker.player:SetAttribute(ATTR.Ultimate, false)
end

-- Abort the ULTIMATE this fighter is performing, if any. Does NOT release their
-- physics. `refund` gives the meter back (the abort wasn't their fault).
local function cancelUltimate(fighter: Fighter, refund: boolean)
	local ult = fighter.ultimate
	if ult == nil then
		return
	end
	endUltimate(ult)
	if refund then
		setCharge(fighter, 1)
	end
	fireUltimate(ult, "Cancelled")
end

-- A strike knocks the victim out of whatever they were doing: their own kick
-- (cancelled) and their ULTIMATE (cancelled, no refund).
local function interrupt(target: Fighter)
	local ownKick = target.flight
	if ownKick then
		finishFlight(ownKick)
		broadcastResolved(ownKick, "Cancelled", false)
	end
	cancelUltimate(target, false)
end

-- Land `count` strikes on `target` (1 per kick, ULT.Strikes for an ULTIMATE).
-- Returns true if that was the finishing strike.
local function addStrikes(attacker: Fighter, target: Fighter, count: number): boolean
	target.strikes = math.min(target.strikes + count, STRIKES.ToExplode)
	target.lastHitBy = attacker.player
	target.lastHitAt = now()
	target.player:SetAttribute(ATTR.Strikes, target.strikes)
	return target.strikes >= STRIKES.ToExplode
end

--[[
	After a strike has been broadcast.
	  * The finishing strike explodes the victim: Defeated(victim, attacker,
	    "Kick"), the mode eliminates them and every client plays the explosion.
	    The kicker carries THROUGH the blast and lands FinisherPushBack studs past
	    it, standing with their back to it (the classic finisher pose).
	  * Any other strike sends the victim tumbling along the kick, and the mode
	    hears about it through Struck.
]]
local function afterStrike(
	attacker: Fighter,
	target: Fighter,
	direction: Vector3,
	exploded: boolean,
	facing: Vector3? -- how the attacker stands back up (default: its own heading)
)
	if not exploded then
		release(attacker, facing)
		tumble(target, direction)
		struck:Fire(target.player, attacker.player, target.strikes)
		return
	end
	local flat = Vector3.new(direction.X, 0, direction.Z)
	local look = attacker.root.CFrame.LookVector
	local through = if flat.Magnitude > 1e-3 then flat.Unit else Vector3.new(look.X, 0, look.Z)
	if through.Magnitude > 1e-3 then
		through = through.Unit
		-- Carry through only as far as there is ground to land on: near an open edge
		-- a blind push would drop the kicker who just won the exchange into the void.
		local origin = target.root.Position
		local distance = STRIKES.FinisherPushBack
		while distance > 0 and not hasGround(origin + through * distance) do
			distance -= 1.5
		end
		if distance > 0 then
			blastBack(attacker, origin, through, distance)
		end
	end
	release(attacker, through)
	defeat(target, attacker.player, "Kick")
end

--[[
	No valid parry arrived during the clash window: the kick lands. One strike.
	The third explodes the victim; otherwise they tumble away. A victim who was
	mid-kick (or mid-ULTIMATE) is knocked out of it.
]]
local function resolveHit(flight: Flight)
	local attacker, target = flight.attacker, flight.target
	finishFlight(flight)
	interrupt(target)
	local exploded = addStrikes(attacker, target, 1)
	addCharge(attacker, ULT.ChargePerHit)
	broadcastResolved(flight, "Hit", flight.perfect) -- perfect: it was a Perfect counter-dash
	afterStrike(attacker, target, flight.direction, exploded)
end

--[[
	SUCCESSFUL PARRY
	  1. The attacker's momentum is cancelled: blasted back to the RICOCHET GAP
	     set by the defender's stance (CombatMath.ricochetGap), tightened by the
	     DUEL rule (each parry in the rally pulls the pair closer, see
	     CombatMath.duelGap), then stunned mid-air for StunTime.
	  2. The defender instantly ricochets (even if they were mid-kick themselves),
	     at the attacker or at the redirect target it was locked onto, with
	     rally + 1 (compounding +10%) and the one-shot Perfect boost if earned.
	  3. Both are now "in a duel" for SpamWindow: a Block that misses costs them
	     nothing, so the exchange turns into the close-range mash of kicks.
]]
local function resolveParry(flight: Flight, perfect: boolean, redirectTo: Fighter?)
	local attacker, defender = flight.attacker, flight.target
	finishFlight(flight)

	local axis = attacker.root.Position - defender.root.Position
	axis = if axis.Magnitude > 1e-3 then axis.Unit else -flight.direction
	local approachSpeed = trustedVelocity(defender):Dot(axis) -- > 0: stepping in, < 0: backpedalling
	local stanceGap = CombatMath.ricochetGap(
		approachSpeed,
		PARRY.RicochetGap,
		PARRY.StanceFactor,
		PARRY.RicochetGapMin,
		PARRY.RicochetGapMax
	)
	local gap = CombatMath.duelGap(stanceGap, flight.rally + 1, DUEL.GapShrink, DUEL.MinGap)
	local t = now()
	attacker.duelUntil = t + DUEL.SpamWindow
	defender.duelUntil = t + DUEL.SpamWindow
	attacker.lastHitBy = defender.player -- if the blast knocks them off the arena, the defender gets the credit
	attacker.lastHitAt = t
	local parryGain = math.min(ULT.ChargePerParry, ULT.MaxParryChargePerRound - defender.parryCharge)
	if parryGain > 0 and addCharge(defender, parryGain) then
		defender.parryCharge += parryGain
	end
	stun(attacker, PARRY.StunTime, -axis)
	blastBack(attacker, defender.root.Position, axis, gap)

	broadcastResolved(flight, "Parried", perfect)

	local rally = flight.rally + 1
	if redirectTo and isEligibleTarget(defender, redirectTo) then
		startFlight(defender, redirectTo, rally, perfect, false)
	else
		-- The ricochet is a core mechanic, so it ignores rules.canTarget.
		startFlight(defender, attacker, rally, perfect, true)
	end
	parried:Fire(defender.player, attacker.player, perfect, rally)
end

--[[
	HEAD-ON CLASH: two fighters kicking EACH OTHER meet in the middle. Neither
	kick lands: both bounce apart and hang stunned for a beat, no strike for either, and
	the rally ends. Without this rule, whichever flight the server happened to
	step first would win.
]]
local function resolveHeadOn(a: Flight, b: Flight)
	local first, second = a.attacker, b.attacker
	finishFlight(a)
	finishFlight(b)
	local axis = first.root.Position - second.root.Position
	axis = if axis.Magnitude > 1e-3 then axis.Unit else -a.direction
	local middle = (first.root.Position + second.root.Position) / 2
	local t = now()
	first.lastHitBy, first.lastHitAt = second.player, t -- a bounce off the edge credits the other kicker
	second.lastHitBy, second.lastHitAt = first.player, t
	stun(first, KICK.ClashStun, -axis)
	stun(second, KICK.ClashStun, axis)
	blastBack(first, middle, axis, KICK.ClashGap / 2)
	blastBack(second, middle, -axis, KICK.ClashGap / 2)
	broadcastResolved(a, "Clashed", false, middle) -- spark where they met, not where they bounced to
	broadcastResolved(b, "Clashed", false, middle)
end

-- Contact reached: hold the "clash frame" while a late-arriving parry can still land.
local function enterClash(flight: Flight, t: number)
	local attacker, target = flight.attacker, flight.target
	flight.phase = "Clash"
	flight.impactAt = t
	flight.eta = t
	--[[
		The verdict waits for the DEFENDER's latency (bounded by MaxCompensation):
		a Block pressed in time on their screen but still in transit is honoured.
		The server never rewinds positions; it delays the verdict. That is why
		nobody rubber-bands.
	]]
	flight.resolveAt = t + KICK.ClashHoldBase + LatencyService.getMaxRewind(target.player)

	-- Pin the kicker's feet against the target so every client sees the clash.
	local offset = target.root.Position - attacker.root.Position
	local direction = if offset.Magnitude > 1e-3 then offset.Unit else flight.direction
	attacker.mover.velocity.VectorVelocity = Vector3.zero
	attacker.root.CFrame = CFrame.new(target.root.Position - direction * KICK.ImpactRadius * 0.8)
		* attacker.root.CFrame.Rotation
	-- A target that was mid-kick stops dead: their kick waits for this verdict
	-- (a hit cancels it, a Block replaces it with a ricochet).
	local ownKick = target.flight
	if ownKick and ownKick.phase ~= "Clash" then
		target.mover.velocity.VectorVelocity = Vector3.zero
	end
	broadcastEta(flight, t, true)
end

-- Shadow Clone: aim at a lateral lane that converges on the target as the gap closes.
local function aimPoint(flight: Flight, targetPosition: Vector3, attackerPosition: Vector3, gap: number): Vector3
	if flight.lane == 0 then
		return targetPosition
	end
	local flat = Vector3.new(targetPosition.X - attackerPosition.X, 0, targetPosition.Z - attackerPosition.Z)
	local lateral = if flat.Magnitude > 1e-3 then flat.Unit:Cross(Vector3.yAxis) else Vector3.xAxis
	local decay = CombatMath.laneDecay(gap, flight.laneStartGap, KICK.ImpactRadius * 2)
	return targetPosition + lateral * (flight.lane * flight.laneSpread * decay)
end

-- One Heartbeat of one flight.
local function stepFlight(flight: Flight, t: number, dt: number)
	local attacker, target = flight.attacker, flight.target
	if not isAlive(attacker) then
		cancelFlight(flight)
		return
	end
	if not isAlive(target) then
		cancelFlight(flight) -- target gone: land, and kick someone else after the cooldown
		return
	end
	if t - flight.startedAt > KICK.MaxFlightTime then
		cancelFlight(flight)
		return
	end
	if flight.phase ~= "Clash" and beingStruck(attacker) then
		-- Our kicker has just been struck: this kick hangs until that verdict.
		-- (A kick that landed FIRST, already in its own clash frame, still resolves.)
		attacker.mover.velocity.VectorVelocity = Vector3.zero
		return
	end

	local velocity = attacker.mover.velocity
	local attackerPosition = attacker.root.Position
	local targetPosition = target.root.Position
	local gap = (targetPosition - attackerPosition).Magnitude
	recordSample(flight, t, gap)

	if flight.phase == "Clash" then
		velocity.VectorVelocity = Vector3.zero
		if gap > KICK.ImpactRadius * 2 then
			-- The target was blasted or carried away (a parry, a clash, another hit):
			-- this contact is stale, so home in again instead of landing from afar.
			flight.phase = "Flying"
			flight.impactAt = nil
			flight.resolveAt = math.huge
			return
		end
		-- Keep the clash frame glued to the target, so what everyone sees is what lands.
		local pin = if gap > 1e-3 then (targetPosition - attackerPosition) / gap else flight.direction
		attacker.root.CFrame = CFrame.new(targetPosition - pin * KICK.ImpactRadius * 0.8)
			* attacker.root.CFrame.Rotation
		if t >= flight.resolveAt then
			resolveHit(flight)
		end
		return
	end

	if flight.phase == "Frozen" then
		velocity.VectorVelocity = Vector3.zero
		if t < flight.frozenUntil then
			broadcastEta(flight, t) -- sends -1: "unknown" while frozen
			return
		end
		flight.phase = "Flying"
		local after = flight.afterFreeze
		flight.afterFreeze = nil
		if after then
			after() -- e.g. Lag Switch blink
		end
		-- The pre-freeze ETA is now in the past: re-predict from the new position
		-- before any parry is judged against it, and push it to clients immediately.
		local newGap = (target.root.Position - attacker.root.Position).Magnitude
		flight.eta = t + CombatMath.timeToImpact(newGap, KICK.ImpactRadius, flight.speed)
		broadcastEta(flight, t, true)
		return
	end

	-- Homing: steer toward the aim point, turn-rate limited until close
	-- (pure homing inside PureHomingDistance so the kick can never orbit).
	local toAim = aimPoint(flight, targetPosition, attackerPosition, gap) - attackerPosition
	local desired = if toAim.Magnitude > 1e-3 then toAim.Unit else flight.direction
	local maxTurn = if gap <= KICK.PureHomingDistance then math.pi else KICK.MaxTurnRate * dt
	flight.direction = steer(flight.direction, desired, maxTurn)

	-- Live ETA. The target running away (positive recede) buys time; this is
	-- the "walk backward to buy time" half of distance manipulation.
	local recedeSpeed = trustedVelocity(target):Dot(flight.direction)
	local closing = CombatMath.closingSpeed(flight.speed, recedeSpeed, KICK.ClosingFloor)
	flight.eta = t + CombatMath.timeToImpact(gap, KICK.ImpactRadius, closing)

	-- Contact if inside the radius OR reachable within this frame, so a 400 stud/s
	-- kick (~7 studs per frame) can't tunnel through the target between Heartbeats.
	if gap <= KICK.ImpactRadius + flight.speed * dt then
		local counter = target.flight
		if counter and counter.active and counter.target == attacker and counter.phase ~= "Clash" then
			resolveHeadOn(flight, counter) -- we kicked each other: bounce, no strike
		else
			enterClash(flight, t)
		end
		return
	end

	velocity.VectorVelocity = flight.direction * flight.speed
	attacker.mover.align.CFrame = feetFirst(flight.direction)
	broadcastEta(flight, t)
end

-- ULTIMATE ------------------------------------------------------------------------------

--[[
	ULTIMATE: a charged, unblockable finisher kick in two telegraphed stages.
	  Leap  (LeapTime): the performer springs up and forward toward the target
	         (clients play the flip). Every client already sees it coming.
	  Dive  (DiveTime): at the top of the leap the impact point LOCKS where the
	         target stands, a marker appears there, and the performer dives at
	         it in a straight line. It does NOT home: the counterplay is to DASH
	         (or run) out of the marked zone before it lands.
	It is not a Flight and never enters the target's `incoming`, so Block can't
	touch it. The performer is committed (no Block, no kicks), and a kick that
	lands on them during either stage cancels it.
]]
local function startUltimate(attacker: Fighter, target: Fighter, t: number)
	nextKickId += 1
	setCharge(attacker, 0)

	local start = attacker.root.Position
	local offset = target.root.Position - start
	local flat = Vector3.new(offset.X, 0, offset.Z)
	local look = Vector3.new(attacker.root.CFrame.LookVector.X, 0, attacker.root.CFrame.LookVector.Z)
	local heading = if flat.Magnitude > 1e-3
		then flat.Unit
		elseif look.Magnitude > 1e-3 then look.Unit
		else Vector3.zAxis
	local apex = start + flat * ULT.LeapForward + Vector3.yAxis * ULT.LeapHeight
	local ceiling = Workspace:Raycast(start, apex - start, excludeFighters())
	if ceiling then
		apex = ceiling.Position - (apex - start).Unit * 2 -- don't leap into a roof
	end

	local ult: UltimateState = {
		id = nextKickId,
		attacker = attacker,
		target = target,
		stage = "Leap",
		diveAt = t + ULT.LeapTime,
		apex = apex,
		direction = heading,
		heading = heading,
		apexHoldUntil = t + ULT.LeapTime + ULT.MaxApexHold,
		impactPoint = target.root.Position,
		impactAt = t + ULT.LeapTime + ULT.DiveTime,
		speed = 0,
		held = false,
	}
	attacker.ultimate = ult
	ultimates[ult.id] = ult
	attacker.lastHitBy = nil -- acting again: an old hit no longer gets credit for a later fall
	attacker.holdUntil = 0 -- supersedes a dash in progress

	takeOwnership(attacker)
	local mover = attacker.mover
	mover.velocity.VectorVelocity = (apex - start) / ULT.LeapTime
	mover.velocity.Enabled = true
	mover.align.CFrame = CFrame.lookAt(Vector3.zero, heading)
	mover.align.Enabled = true
	setCollisionGroup(attacker.character, Config.CollisionGroups.Flying)
	attacker.player:SetAttribute(ATTR.Ultimate, true)
	fireUltimate(ult, "Leap")
end

-- The dive has arrived: the target is struck if still inside the zone.
local function resolveUltimate(ult: UltimateState)
	local attacker, target = ult.attacker, ult.target
	endUltimate(ult)
	attacker.mover.velocity.VectorVelocity = Vector3.zero
	attacker.root.CFrame = CFrame.new(ult.impactPoint) * attacker.root.CFrame.Rotation
	attacker.kickReadyAt = now() + KICK.Cooldown
	attacker.player:SetAttribute(ATTR.KickReadyAt, attacker.kickReadyAt)

	-- A cylinder, so jumping straight up doesn't dodge it: only leaving the zone does.
	local offset = target.root.Position - ult.impactPoint
	local inZone = isAlive(target)
		and Vector3.new(offset.X, 0, offset.Z).Magnitude <= ULT.Radius
		and math.abs(offset.Y) <= ULT.Radius
	-- A dive that was clamped against a wall or roof doesn't strike through it.
	if inZone and Workspace:Raycast(ult.impactPoint, offset, excludeFighters()) then
		inZone = false
	end
	if not inZone then
		attacker.kickReadyAt += ULT.MissRecovery -- whiffed a finisher: an opening for the dodger
		attacker.player:SetAttribute(ATTR.KickReadyAt, attacker.kickReadyAt)
		fireUltimate(ult, "Miss")
		release(attacker, ult.heading)
		return
	end

	-- Land just short of the victim, like a kick's clash frame, not inside their body
	-- (and not inside cover right behind them: stop in front of it, or stay put).
	local flat = Vector3.new(ult.direction.X, 0, ult.direction.Z)
	local back = if flat.Magnitude > 1e-3 then flat.Unit else ult.heading
	local standOff = -back * KICK.ImpactRadius * 0.8
	local cover = Workspace:Raycast(target.root.Position, standOff, excludeFighters())
	local spot = if cover == nil
		then target.root.Position + standOff
		elseif cover.Distance > 2.5 then cover.Position + back * 1.5
		else ult.impactPoint
	attacker.root.CFrame = CFrame.new(spot) * attacker.root.CFrame.Rotation
	interrupt(target)
	local exploded = addStrikes(attacker, target, ULT.Strikes)
	broadcastUltimateHit(ult, exploded)
	afterStrike(attacker, target, ult.direction, exploded, ult.heading)
end

-- One Heartbeat of one ULTIMATE.
local function stepUltimate(ult: UltimateState, t: number, dt: number)
	local attacker, target = ult.attacker, ult.target
	if not isAlive(attacker) then
		endUltimate(ult) -- (defeat / unregistering releases the physics)
		fireUltimate(ult, "Cancelled")
		return
	end

	local mover = attacker.mover
	if beingStruck(attacker) then
		-- A kick has made contact with the performer: hang until that verdict
		-- (a hit cancels the ULTIMATE). The clock pauses with it.
		mover.velocity.VectorVelocity = Vector3.zero
		ult.diveAt += dt
		ult.impactAt += dt
		ult.held = true
		return
	end
	if ult.held then
		ult.held = false
		fireUltimate(ult, ult.stage) -- the timings moved: re-sync every client's telegraph
	end

	if not isAlive(target) then
		-- The target left, or someone else exploded them first: not the performer's
		-- fault, so it's a cancel with a refund, not a Miss.
		cancelUltimate(attacker, true)
		release(attacker, ult.heading)
		return
	end

	if ult.stage == "Leap" then
		if t < ult.diveAt then
			-- Arrive at the apex exactly at diveAt, whatever the frame rate.
			mover.velocity.VectorVelocity = (ult.apex - attacker.root.Position) / math.max(ult.diveAt - t, dt)
			return
		end
		-- A stunned or tumbling target (say, a kick just landed on them) can't DASH
		-- yet. Hang at the apex until they can (capped), so the dive's dodge window
		-- always starts with them free to move. Clients re-sync to the new dive time.
		-- (stunUntil, not holdUntil: a target mid-DASH is already dodging and must not
		-- be waited out and then locked onto where the dash ends.)
		local freeAt = math.min(target.stunUntil, ult.apexHoldUntil)
		if target.flight == nil and freeAt > t then
			mover.velocity.VectorVelocity = Vector3.zero
			if ult.diveAt ~= freeAt then
				ult.diveAt = freeAt
				fireUltimate(ult, "Leap") -- once per new dive time, not every frame
			end
			return
		end

		-- Top of the leap: lock the impact point where the target stands NOW.
		local from = attacker.root.Position
		local aim = target.root.Position
		local blocked = Workspace:Raycast(from, aim - from, excludeFighters())
		if blocked then
			aim = blocked.Position - (aim - from).Unit * 2 -- dive into the wall, not through it
		end
		local path = aim - from
		ult.stage = "Dive"
		ult.impactPoint = aim
		ult.impactAt = t + ULT.DiveTime
		ult.direction = if path.Magnitude > 1e-3 then path.Unit else -Vector3.yAxis
		ult.speed = path.Magnitude / ULT.DiveTime
		mover.align.CFrame = feetFirst(ult.direction, ult.heading)
		fireUltimate(ult, "Dive")
	end

	if t < ult.impactAt then
		-- Straight line, arriving exactly at impactAt (the marker's countdown).
		mover.velocity.VectorVelocity = (ult.impactPoint - attacker.root.Position) / math.max(ult.impactAt - t, dt)
		return
	end
	resolveUltimate(ult)
end

-- Leg Style handle --------------------------------------------------------------------

local function controlFor(flight: Flight): ServerTypes.FlightControl
	local function currentGap(): number
		return (flight.target.root.Position - flight.attacker.root.Position).Magnitude
	end

	return {
		kickId = flight.id,
		attacker = flight.attacker.player,
		target = flight.target.player,
		isActive = function(): boolean
			return flight.active
		end,
		freeze = function(duration: number, after: (() -> ())?)
			if not flight.active or flight.phase ~= "Flying" then
				return
			end
			flight.phase = "Frozen"
			flight.frozenUntil = now() + duration
			flight.afterFreeze = after
			flight.attacker.mover.velocity.VectorVelocity = Vector3.zero
		end,
		blinkToward = function(leadTime: number)
			if not flight.active then
				return
			end
			local targetPosition = flight.target.root.Position
			local offset = targetPosition - flight.attacker.root.Position
			local gap = offset.Magnitude
			local keepGap = KICK.ImpactRadius + flight.speed * leadTime
			if gap <= keepGap then
				return
			end
			local direction = offset / gap
			flight.direction = direction
			-- Server-owned assembly: this teleport is authoritative and replicates to everyone.
			flight.attacker.root.CFrame = CFrame.new(targetPosition - direction * keepGap) * feetFirst(direction)
		end,
		setLane = function(lane: number, spread: number)
			flight.lane = math.clamp(lane, -1, 1)
			flight.laneSpread = spread
			flight.laneStartGap = currentGap()
		end,
		currentGap = currentGap,
	}
end

-- Integrity (auto-parry heuristics) -------------------------------------------------------

local function flagPlayer(player: Player, integrity: Integrity, reason: string)
	integrity.flagged = true
	player:SetAttribute(ATTR.Flagged, reason)
	warn(`[CombatService] integrity flag on {player.Name}: {reason}`)
	flagged:Fire(player, reason)
	if Config.Integrity.KickOnFlag then
		player:Kick("Unusual parry timing detected.")
	end
end

--[[
	An auto-parry script has the same information the client has, so it can
	always press "in time". What it can't easily fake is being HUMAN:
	  * Metronome timing: nearly every parry Perfect, with a tiny spread. Humans
	    scatter by tens of milliseconds.
	  * Inhuman reactions: parrying an UNPREDICTABLE kick (opening kick or a
	    redirect, not the inevitable ricochet back at you) faster than
	    MinHumanReaction after it became visible.
	This only flags (attribute + warn + Flagged signal); punishment is a policy
	decision for moderation tooling once thresholds are tuned on real data.
]]
local function recordIntegrity(player: Player, flight: Flight, tti: number, perfect: boolean, pressedAt: number)
	local integrity = integrityFor(player)
	local settings = Config.Integrity
	local visibleAt = flight.startedAt + LatencyService.getRtt(player) / 2

	local slot = integrity.nextSlot
	integrity.timings[slot] = tti
	integrity.perfects[slot] = perfect
	integrity.fast[slot] = not flight.predictable and (pressedAt - visibleAt) < settings.MinHumanReaction
	integrity.nextSlot = slot % settings.SampleSize + 1

	if integrity.flagged or #integrity.timings < settings.SampleSize then
		return
	end

	local perfectCount, fastCount = 0, 0
	for index = 1, settings.SampleSize do
		if integrity.perfects[index] then
			perfectCount += 1
		end
		if integrity.fast[index] then
			fastCount += 1
		end
	end
	local spread = CombatMath.standardDeviation(integrity.timings)

	if perfectCount / settings.SampleSize >= settings.PerfectRatioFlag and spread <= settings.StdDevFlag then
		flagPlayer(
			player,
			integrity,
			string.format(
				"metronome parries: %d/%d perfect, spread %.1f ms",
				perfectCount,
				settings.SampleSize,
				spread * 1000
			)
		)
	elseif fastCount >= settings.FastReactionFlag then
		flagPlayer(player, integrity, `{fastCount} inhuman reactions in the last {settings.SampleSize} parries`)
	end
end

-- Remote handlers ------------------------------------------------------------------------

-- The claimed camera must be near the body (exploits often "aim" from the target),
-- and the target inside a generous cone of it (the same dot product the client uses).
local function cameraPlausible(attacker: Fighter, camera: CFrame, targetPosition: Vector3): boolean
	local maxCameraDistance = attacker.player.CameraMaxZoomDistance + Config.Targeting.CameraSlack
	if (camera.Position - attacker.root.Position).Magnitude > maxCameraDistance then
		return false
	end
	return Targeting.isPlausible(camera, targetPosition, Config.Targeting.ServerMinDot)
end

--[[
	RequestLaunch(targetUserId, cameraCFrame)
	The client says who its lock-on dot is on. The server re-checks EVERYTHING:
	the mode allows this player to kick, not already flying, not stunned, kick
	cooldown over, target eligibility (alive, in range, mode rules) and that the
	target sits plausibly inside the camera the client claims to have.
]]
local function onLaunchRequest(player: Player, rawTargetId: unknown, rawCamera: unknown)
	if not launchLimiter:check(player) then
		return
	end
	local attacker = fighters[player]
	if attacker == nil or not isAlive(attacker) or not rules.canLaunch(player) then
		return
	end
	local t = now()
	if
		attacker.flight
		or attacker.ultimate
		or t < attacker.stunUntil
		or t < attacker.kickReadyAt
		or beingStruck(attacker)
	then
		return -- (being struck: a kick has already made contact; only a Block can still save you)
	end

	local targetPlayer = Guard.player(rawTargetId)
	local camera = Guard.cframe(rawCamera)
	local target = if targetPlayer then fighters[targetPlayer] else nil
	if target == nil or camera == nil or not isEligibleTarget(attacker, target) then
		return
	end

	-- Their kick is about to land on you: the answer is Block, not a counter-kick.
	-- Otherwise kicking back would be a timing-free way to turn any kick into a
	-- harmless head-on clash. (An EARLY counter is allowed, and the original
	-- attacker can parry it mid-flight.)
	local threat = target.flight
	if
		threat
		and threat.active
		and threat.target == attacker
		and impactTimeOf(threat) - t <= PARRY.BaseWindow + PlayerDataService.getParryWindowBonus(player)
	then
		return
	end

	if not cameraPlausible(attacker, camera, target.root.Position) then
		return
	end

	startFlight(attacker, target, 0, false, false) -- a fresh kick starts a new rally at base speed
end

-- A Block that parried nothing. Mid-duel, mashing Block IS the game, so a miss
-- costs nothing (and says nothing); otherwise it costs WhiffCooldown.
local function whiff(defender: Fighter, t: number, result: Types.ParryResult, kickId: number)
	if t < defender.duelUntil then
		return
	end
	defender.parryLockUntil = t + PARRY.WhiffCooldown
	sendParryFeedback(defender, result, kickId)
end

local function resolveRedirect(defender: Fighter, attacker: Fighter, rawLockId: unknown): Fighter?
	local lockPlayer = Guard.player(rawLockId)
	if lockPlayer == nil or lockPlayer == attacker.player then
		return nil
	end
	local candidate = fighters[lockPlayer]
	if candidate and isEligibleTarget(defender, candidate) then
		return candidate
	end
	return nil
end

--[[
	RequestParry(kickId, pressServerTime, lockUserId?)

	THE PARRY VALIDATION MATH
	-------------------------
	1. Lag compensation. The client stamps the press with its synced clock.
	   The server never trusts that stamp blindly; it clamps it into
	       [receivedAt - maxRewind, receivedAt]
	   where maxRewind = clamp(rtt + jitter + tolerance, 0, MaxCompensation)
	   and rtt comes from nonce pings the client can't fake LOW.

	2. Timing. tti = impactTime - pressedAt, where impactTime is the actual
	   contact time if the clash has started, otherwise the freshest server
	   prediction.
	       tti > window                 -> Early (whiff + cooldown)
	       tti < -LateGrace             -> Late
	       tti <= PerfectWindow (0.1 s) -> Perfect
	   window = BaseWindow + the player's ParryWindow upgrade.

	3. Distance. The server's own recorded gap at pressedAt must be reachable
	   inside the window:
	       gap <= ImpactRadius + (kickSpeed + runCap) * (window + maxRewind) + slack
	   A forged stamp or a manipulated ETA fails here even if step 2 passed.

	4. Anti-spam. Any Block that parries nothing costs WhiffCooldown, so mashing
	   F (or a naive macro) locks you out exactly when the kick arrives. The
	   exception is a DUEL (SpamWindow after a parry you were part of): a
	   close-range exchange is too fast to time, so there mashing is free, and
	   the timing and distance checks still decide every parry.

	With several kicks incoming, Block answers the one the client named, or if
	that one is gone or wasn't named, the one closest to landing.
]]
local function onParryRequest(player: Player, rawKickId: unknown, rawStamp: unknown, rawLockId: unknown)
	local receivedAt = now()
	if not parryLimiter:check(player) then
		return
	end
	local defender = fighters[player]
	if defender == nil or not isAlive(defender) or defender.ultimate then
		return -- (mid-ULTIMATE: committed, no blocking)
	end
	if receivedAt < defender.parryLockUntil then
		sendParryFeedback(defender, "Cooldown", 0)
		return
	end

	local kickId = Guard.integer(rawKickId, 0, 2 ^ 31) or 0
	-- kickId 0 = "whatever is coming at me": the press may beat KickStarted to the client.
	local flight: Flight? = defender.incoming[kickId]
	if flight == nil or not flight.active then
		flight = nil
		local soonest = math.huge
		for _, candidate in defender.incoming do
			local impact = impactTimeOf(candidate)
			if candidate.active and (flight == nil or impact < soonest) then
				flight, soonest = candidate, impact
			end
		end
	end
	if flight == nil then
		whiff(defender, receivedAt, "NoThreat", kickId)
		return
	end

	-- 1. Lag compensation
	local maxRewind = LatencyService.getMaxRewind(player)
	local pressedAt = CombatMath.compensatedPressTime(
		Guard.number(rawStamp),
		receivedAt,
		maxRewind,
		LatencyService.getRtt(player) / 2
	)
	if pressedAt < flight.startedAt then
		-- Pressed before this kick existed: a guess, not a parry.
		whiff(defender, receivedAt, "Early", flight.id)
		return
	end

	-- 2. Timing
	local tti = impactTimeOf(flight) - pressedAt
	local window = PARRY.BaseWindow + PlayerDataService.getParryWindowBonus(player)
	local verdict: CombatMath.Verdict = CombatMath.parryVerdict(tti, window, PARRY.PerfectWindow, PARRY.LateGrace)
	if verdict == "Early" or verdict == "Late" then
		whiff(defender, receivedAt, verdict, flight.id)
		return
	end

	-- 3. Distance
	local gap = gapAt(flight, pressedAt)
	-- The defender may be flying too (blocking mid-kick): count their real speed, not just running speed.
	local defenderSpeed = math.max(runCap(defender), trustedVelocity(defender).Magnitude)
	local reach = KICK.ImpactRadius + (flight.speed + defenderSpeed) * (window + maxRewind) + PARRY.DistanceSlack
	if gap > reach then
		whiff(defender, receivedAt, "TooFar", flight.id)
		return
	end

	local perfect = verdict == "Perfect"
	if not flight.predictable and receivedAt >= defender.duelUntil then
		-- Duel mashing lands near-identical "perfect" timings by design, and a
		-- ricochet straight back at you is anticipated; only genuine reads count.
		recordIntegrity(player, flight, tti, perfect, pressedAt)
	end
	sendParryFeedback(defender, verdict, flight.id)
	resolveParry(flight, perfect, resolveRedirect(defender, flight.attacker, rawLockId))
end

-- RequestAbility(): activate the equipped Leg Style on the current flight (once per kick).
local function onAbilityRequest(player: Player)
	if not abilityLimiter:check(player) then
		return
	end
	local fighter = fighters[player]
	local flight = if fighter then fighter.flight else nil
	if flight == nil or flight.phase ~= "Flying" or flight.abilityUsed then
		return
	end
	local payload = AbilityService.tryActivate(player, controlFor(flight))
	if payload then
		flight.abilityUsed = true
		net().Effect:FireAllClients(payload)
	end
end

--[[
	RequestDash(direction)
	A quick dodge burst: DASH.Distance studs in DASH.Time along the requested
	direction (flattened; the body's facing if it's zero). The SERVER moves the
	body (it takes ownership for the burst, like a flight), so the client can't
	stretch it, and it stops short of walls. Not while flying, mid-ULTIMATE,
	stunned / tumbling, or already struck. Juggernaut runners may dash too: it
	is a dodge, not an attack.
]]
local function onDashRequest(player: Player, rawDirection: unknown)
	if not dashLimiter:check(player) then
		return
	end
	local fighter = fighters[player]
	if fighter == nil or not isAlive(fighter) then
		return
	end
	local t = now()
	if t < fighter.dashReadyAt or fighter.flight or fighter.ultimate or fighter.serverOwned or beingStruck(fighter) then
		return -- (serverOwned: stunned, tumbling or already dashing)
	end

	local raw = Guard.vector3(rawDirection)
	local flat = if raw then Vector3.new(raw.X, 0, raw.Z) else Vector3.zero
	if flat.Magnitude < 1e-3 then
		local look = fighter.root.CFrame.LookVector
		flat = Vector3.new(look.X, 0, look.Z)
		if flat.Magnitude < 1e-3 then
			return
		end
	end
	local direction = flat.Unit
	local distance = DASH.Distance
	local wall = Workspace:Raycast(fighter.root.Position, direction * distance, excludeFighters())
	if wall then
		distance = wall.Distance - 2
	end
	if distance < 1 then
		return -- pressed into a wall: nothing to do, keep the cooldown
	end

	fighter.dashReadyAt = t + DASH.Cooldown
	player:SetAttribute(ATTR.DashReadyAt, fighter.dashReadyAt) -- clients draw the trail from this too
	takeOwnership(fighter)
	fighter.holdUntil = t + DASH.Time * distance / DASH.Distance -- stepHolds hands physics back after
	local mover = fighter.mover
	mover.velocity.VectorVelocity = direction * (DASH.Distance / DASH.Time)
	mover.velocity.Enabled = true
	mover.align.CFrame = CFrame.lookAt(Vector3.zero, direction)
	mover.align.Enabled = true
	setCollisionGroup(fighter.character, Config.CollisionGroups.Flying) -- slip past bodies
end

--[[
	RequestUltimate(targetUserId, cameraCFrame)
	The meter must be full and the mode must let this player attack
	(rules.canLaunch, so a Juggernaut runner can't). The target is re-checked
	like a kick (alive, in ULT.MaxRange, mode rules, camera plausibility). The
	kick cooldown does NOT apply: the meter is the gate.
]]
local function onUltimateRequest(player: Player, rawTargetId: unknown, rawCamera: unknown)
	if not ultimateLimiter:check(player) then
		return
	end
	local attacker = fighters[player]
	if attacker == nil or not isAlive(attacker) or not rules.canLaunch(player) then
		return
	end
	local t = now()
	if
		attacker.ultCharge < 1
		or attacker.ultimate
		or attacker.flight
		or t < attacker.stunUntil
		or beingStruck(attacker)
	then
		return
	end

	local targetPlayer = Guard.player(rawTargetId)
	local camera = Guard.cframe(rawCamera)
	local target = if targetPlayer then fighters[targetPlayer] else nil
	if target == nil or camera == nil or not isEligibleTarget(attacker, target) then
		return
	end
	if (target.root.Position - attacker.root.Position).Magnitude > ULT.MaxRange then
		return
	end
	if not cameraPlausible(attacker, camera, target.root.Position) then
		return
	end
	startUltimate(attacker, target, t)
end

-- Per-frame systems ------------------------------------------------------------------------

local function stepHolds(t: number)
	for _, fighter in fighters do
		if fighter.holdUntil > 0 and fighter.flight == nil and fighter.ultimate == nil and t >= fighter.holdUntil then
			release(fighter) -- stun / tumble / dash over: physics back to the client, gravity takes over
		end
	end
end

-- The ULTIMATE meter's slow passive fill, for anyone the mode lets attack.
local function stepCharge(dt: number)
	for player, fighter in fighters do
		if not fighter.defeated and rules.canLaunch(player) then
			addCharge(fighter, ULT.ChargePerSecond * dt)
		end
	end
end

--[[
	Basic physics-exploit protection for CLIENT-owned characters (everyone who
	isn't flying or stunned):
	  * speed check: horizontal speed between samples must stay under
	    WalkSpeed * tolerance + slack; repeated or extreme violations rubber-band
	    to the last legitimate position (a server CFrame write overrides the client);
	  * void check: falling below KillY is a KO.
]]
local function stepMovement(t: number)
	local settings = Config.Movement
	if t - lastMovementCheck < settings.CheckInterval then
		return
	end
	lastMovementCheck = t

	for _, fighter in fighters do
		if fighter.defeated then
			continue
		end
		local position = fighter.root.Position
		if position.Y < settings.KillY then
			-- Knocked off by a recent hit? Credit the attacker, so the victim sees who did it.
			defeat(fighter, recentAttacker(fighter), "Void")
			continue
		end
		if fighter.serverOwned or t < fighter.releaseGraceUntil then
			fighter.lastGoodPosition = position
			fighter.lastCheckPosition = position
			fighter.lastCheckAt = t
			fighter.violations = 0
			continue
		end

		local elapsed = math.max(t - fighter.lastCheckAt, 1e-3)
		local delta = position - fighter.lastCheckPosition
		local horizontalSpeed = Vector3.new(delta.X, 0, delta.Z).Magnitude / elapsed
		local allowed = fighter.humanoid.WalkSpeed * settings.SpeedTolerance + settings.SpeedSlack
		fighter.lastCheckPosition = position
		fighter.lastCheckAt = t

		if horizontalSpeed <= allowed then
			fighter.violations = 0
			fighter.lastGoodPosition = position
			continue
		end

		fighter.violations += 1
		if horizontalSpeed > allowed * settings.TeleportFactor or fighter.violations >= settings.MaxViolations then
			fighter.root.CFrame = CFrame.new(fighter.lastGoodPosition) * fighter.root.CFrame.Rotation
			fighter.root.AssemblyLinearVelocity = Vector3.zero
			fighter.lastCheckPosition = fighter.lastGoodPosition
			fighter.violations = 0
		end
	end
end

local function onHeartbeat(dt: number)
	local t = now()

	-- Snapshot: resolving one flight can start another (ricochet / redirect).
	local active = {}
	for _, flight in flights do
		table.insert(active, flight)
	end
	for _, flight in active do
		if flight.active then
			stepFlight(flight, t, dt)
		end
	end

	local performing = {}
	for _, ult in ultimates do
		table.insert(performing, ult)
	end
	for _, ult in performing do
		if ultimates[ult.id] == ult then
			stepUltimate(ult, t, dt)
		end
	end

	stepHolds(t)
	stepCharge(dt)
	stepMovement(t)
end

-- Public API ------------------------------------------------------------------------------

--[[
	Add a player to the fight. Call AFTER teleporting them into the arena.
	Returns false if the character isn't in a usable state.
]]
function CombatService.registerCombatant(player: Player): boolean
	if fighters[player] then
		return true
	end
	local character = player.Character
	if character == nil then
		return false
	end
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	local root = character:FindFirstChild("HumanoidRootPart")
	if humanoid == nil or humanoid.Health <= 0 or root == nil or not root:IsA("BasePart") then
		return false
	end

	local t = now()
	local fighter: Fighter = {
		player = player,
		character = character,
		humanoid = humanoid,
		root = root,
		mover = createMover(root),
		connections = {},
		defeated = false,
		strikes = 0,
		lastHitBy = nil,
		lastHitAt = 0,
		duelUntil = 0,
		dashReadyAt = 0,
		ultCharge = 0,
		ultPublished = 0,
		parryCharge = 0,
		ultimate = nil,
		flight = nil,
		incoming = {},
		kickReadyAt = 0,
		parryLockUntil = 0,
		serverOwned = false,
		stunUntil = 0,
		holdUntil = 0,
		releaseGraceUntil = t + Config.Movement.ReleaseGrace, -- the arena teleport is still replicating
		lastGoodPosition = root.Position,
		lastCheckPosition = root.Position,
		lastCheckAt = t,
		violations = 0,
	}
	fighters[player] = fighter

	setCollisionGroup(character, Config.CollisionGroups.Characters)
	table.insert(
		fighter.connections,
		character.DescendantAdded:Connect(function(descendant: Instance)
			if descendant:IsA("BasePart") then
				descendant.CollisionGroup = if fighter.flight or fighter.ultimate
					then Config.CollisionGroups.Flying
					else Config.CollisionGroups.Characters
			end
		end)
	)
	table.insert(
		fighter.connections,
		humanoid.Died:Connect(function()
			defeat(fighter, recentAttacker(fighter), "Died")
		end)
	)
	table.insert(
		fighter.connections,
		character.AncestryChanged:Connect(function(_, parent: Instance?)
			if parent == nil then
				defeat(fighter, recentAttacker(fighter), "Died")
			end
		end)
	)

	player:SetAttribute(ATTR.StrikesToExplode, STRIKES.ToExplode)
	player:SetAttribute(ATTR.Strikes, 0)
	player:SetAttribute(ATTR.KickReadyAt, 0)
	player:SetAttribute(ATTR.DashReadyAt, 0)
	player:SetAttribute(ATTR.UltCharge, 0) -- the meter starts empty every round
	player:SetAttribute(ATTR.Ultimate, false)
	player:SetAttribute(ATTR.InArena, true)
	return true
end

-- Remove a player from the fight (eliminated, left, round over). Idempotent.
function CombatService.unregisterCombatant(player: Player)
	local fighter = fighters[player]
	if fighter == nil then
		return
	end
	fighters[player] = nil

	if fighter.flight then
		cancelFlight(fighter.flight)
	end
	cancelUltimate(fighter, false)
	-- Every kick still chasing them lands harmlessly (snapshot: cancelling edits the map).
	local chasing = {}
	for _, flight in fighter.incoming do
		table.insert(chasing, flight)
	end
	for _, flight in chasing do
		if flight.active then
			cancelFlight(flight)
		end
	end

	release(fighter)
	for _, connection in fighter.connections do
		connection:Disconnect()
	end
	fighter.mover.align:Destroy()
	fighter.mover.velocity:Destroy()
	fighter.mover.attachment:Destroy()
	if fighter.character.Parent then
		setCollisionGroup(fighter.character, "Default")
	end

	player:SetAttribute(ATTR.InArena, false)
	player:SetAttribute(ATTR.KickReadyAt, nil)
	player:SetAttribute(ATTR.Flying, false)
	player:SetAttribute(ATTR.Stunned, false)
	player:SetAttribute(ATTR.Strikes, nil) -- strike pips only exist in the arena
	player:SetAttribute(ATTR.StrikesToExplode, nil)
	player:SetAttribute(ATTR.DashReadyAt, nil)
	player:SetAttribute(ATTR.UltCharge, nil)
	player:SetAttribute(ATTR.Ultimate, nil)
	AbilityService.forget(player)
end

-- Cancel every flight and remove every combatant (round teardown).
function CombatService.reset()
	for _, flight in flights do
		cancelFlight(flight)
	end
	local everyone = {}
	for player in fighters do
		table.insert(everyone, player)
	end
	for _, player in everyone do
		CombatService.unregisterCombatant(player)
	end
	table.clear(ultimates)
end

-- Injected by the RoundManager: the active GameMode's launch/targeting rules.
function CombatService.setRules(newRules: ServerTypes.CombatRules?)
	rules = newRules or DEFAULT_RULES
end

-- Who would be credited if this combatant went down right now (see recentAttacker).
function CombatService.getRecentAttacker(player: Player): Player?
	local fighter = fighters[player]
	return if fighter then recentAttacker(fighter) else nil
end

-- Strikes a combatant has taken (nil if not in the arena). Used for the round-timeout tiebreak.
function CombatService.getStrikes(player: Player): number?
	local fighter = fighters[player]
	return if fighter then fighter.strikes else nil
end

-- Exposed for UI / tests: the exact speed the server would use.
function CombatService.computeSpeed(rallyCount: number, perfect: boolean): number
	return CombatMath.kickSpeed(SPEED_PARAMS, rallyCount, if perfect then PARRY.PerfectBoost else 1)
end

function CombatService.init(netRemotes: Net.Remotes)
	remotes = netRemotes

	local groups = Config.CollisionGroups
	for _, group in { groups.Characters, groups.Flying } do
		if not PhysicsService:IsCollisionGroupRegistered(group) then
			PhysicsService:RegisterCollisionGroup(group)
		end
	end
	-- Missiles fly through bodies and each other; contact is resolved by math.
	PhysicsService:CollisionGroupSetCollidable(groups.Flying, groups.Characters, false)
	PhysicsService:CollisionGroupSetCollidable(groups.Flying, groups.Flying, false)

	netRemotes.RequestLaunch.OnServerEvent:Connect(onLaunchRequest)
	netRemotes.RequestParry.OnServerEvent:Connect(onParryRequest)
	netRemotes.RequestAbility.OnServerEvent:Connect(onAbilityRequest)
	netRemotes.RequestDash.OnServerEvent:Connect(onDashRequest)
	netRemotes.RequestUltimate.OnServerEvent:Connect(onUltimateRequest)

	Players.PlayerRemoving:Connect(function(player: Player)
		local fighter = fighters[player]
		if fighter then
			defeat(fighter, recentAttacker(fighter), "Left") -- rage-quitting after a knock-off still credits the attacker
			CombatService.unregisterCombatant(player)
		end
		integrityByPlayer[player] = nil
	end)

	RunService.Heartbeat:Connect(onHeartbeat)
end

return CombatService
