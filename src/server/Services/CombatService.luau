--!strict
--[[
	CombatService (ModuleScript, server)
	====================================
	The authority for everything that happens inside a rally:

	  * Surge ownership (who may launch)
	  * the homing dash-kick: LinearVelocity + AlignOrientation on a
	    SERVER-OWNED character, so the flight can't be speed-hacked or teleported
	  * contact detection, done with server math and never reported by a client
	  * parry validation, lag-compensated and checked on both timing and distance
	  * speed compounding across the rally
	  * stun, ricochet gap and counter-dash (ricochet / redirect)
	  * basic physics-exploit checks (speed/teleport rubber-banding, void KO)

	It knows nothing about rounds, lobbies or win conditions. Those come from a
	CombatRules object injected by the RoundManager, which forwards to the active
	GameMode. A Juggernaut mode can reuse this file untouched; it only swaps
	the rules.

	LIFE OF A KICK
	--------------
	  RequestLaunch --validate--> startFlight --Heartbeat steer--> contact?
	                                                                  |
	              +---------------- "Clash" hold (latency-bounded) ---+
	              |                                                   |
	   RequestParry (valid) -> resolveParry                 no parry -> resolveHit
	     attacker blasted back + stunned mid-air              damage = f(kick speed)
	     defender startFlight(rally + 1) ---> (loops)         0 HP  -> Defeated("Kick")
	                                                          else  -> tumble + Damaged
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
local HEALTH = Config.Health

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

	-- Health (damage scales with kick speed)
	health: number,
	lastHitBy: Player?, -- credited if a hit knocks them off the arena
	lastHitAt: number,

	-- Surge
	surge: boolean,
	surgeSince: number,
	rally: number, -- rally count carried into this fighter's next launch

	-- Kicks
	flight: Flight?, -- the kick this fighter is performing
	incoming: Flight?, -- the kick aimed at this fighter
	lastLaunchAt: number,
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

local CombatService = {}

-- Signals (deferred; see Signal.luau) -------------------------------------------------
local defeated: Signal.Signal<Player, Player?, DefeatCause> = Signal.new()
local damaged: Signal.Signal<Player, Player, number, number> = Signal.new()
local parried: Signal.Signal<Player, Player, boolean, number> = Signal.new()
local launched: Signal.Signal<Player, Player, number, number> = Signal.new()
local flagged: Signal.Signal<Player, string> = Signal.new()

CombatService.Defeated = defeated -- (victim, attacker?, cause): health hit 0 / fell / died / left
CombatService.Damaged = damaged -- (victim, attacker, damage, healthLeft): a kick landed, victim survived
CombatService.Parried = parried -- (defender, attacker, perfect, rallyCount)
CombatService.Launched = launched -- (attacker, target, rallyCount, speed)
CombatService.Flagged = flagged -- (player, reason): integrity heuristics tripped

-- State --------------------------------------------------------------------------
local DEFAULT_RULES: ServerTypes.CombatRules = {
	canTarget = function(_attacker: Player, _target: Player): boolean
		return true
	end,
}

local fighters: { [Player]: Fighter } = {}
local flights: { [number]: Flight } = {}
local integrityByPlayer: { [Player]: Integrity } = {}
local rules: ServerTypes.CombatRules = DEFAULT_RULES
local remotes: Net.Remotes? = nil
local nextKickId = 0
local lastMovementCheck = 0

local launchLimiter = RateLimiter.new(Config.RateLimits.Launch.rate, Config.RateLimits.Launch.burst)
local parryLimiter = RateLimiter.new(Config.RateLimits.Parry.rate, Config.RateLimits.Parry.burst)
local abilityLimiter = RateLimiter.new(Config.RateLimits.Ability.rate, Config.RateLimits.Ability.burst)

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
local function feetFirst(direction: Vector3): CFrame
	local up = if math.abs(direction.Y) > 0.98 then Vector3.zAxis else Vector3.yAxis
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

-- Give physics back to the client (flight over, stun over, or leaving the arena).
local function release(fighter: Fighter)
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
	TUMBLE: a non-lethal hit sends the victim flying along the kick with real
	physics (server-owned, gravity on, constraints off) for HitTumbleTime. The
	victim can't launch until it ends; then stepHolds hands physics back. Near
	an edge a tumble can carry them off the arena, which is credited to the
	attacker as a KO (Config.Health.LastHitCredit).
]]
local function tumble(fighter: Fighter, direction: Vector3)
	local t = now()
	takeOwnership(fighter) -- also PlatformStand: the body goes limp and tumbles
	fighter.stunUntil = t + HEALTH.HitTumbleTime
	fighter.holdUntil = t + HEALTH.HitTumbleTime
	fighter.player:SetAttribute(ATTR.Stunned, true)

	fighter.mover.velocity.Enabled = false
	fighter.mover.align.Enabled = false
	local flat = Vector3.new(direction.X, 0, direction.Z)
	local push = if flat.Magnitude > 1e-3 then flat.Unit else Vector3.zero
	fighter.root.AssemblyLinearVelocity = push * HEALTH.HitFlingSpeed + Vector3.yAxis * HEALTH.HitFlingLift
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
	clients only need it when it meaningfully changes: send at most every
	EtaBroadcastInterval, and only on a drift > EtaBroadcastDrift (or as a
	keep-alive every 4 intervals). It goes over an UnreliableRemoteEvent because
	every update supersedes the previous one. -1 means "frozen / unknown".
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
		net().KickUpdated:FireAllClients(flight.id, eta, t)
	end
end

-- `damage` is only set for a "Hit". The rally/speed/damage numbers are what the
-- victim's hit card shows, so "who hit me and why" is always answered.
local function broadcastResolved(flight: Flight, outcome: Types.KickOutcome, perfect: boolean, damage: number?)
	local target = flight.target
	local payload: Types.KickResolvedPayload = {
		kickId = flight.id,
		outcome = outcome,
		attackerId = flight.attacker.player.UserId,
		targetId = target.player.UserId,
		perfect = perfect,
		direction = flight.direction,
		position = flight.attacker.root.Position,
		rally = flight.rally,
		speed = flight.speed,
		damage = damage or 0,
		health = target.health,
		lethal = outcome == "Hit" and target.health <= 0,
	}
	net().KickResolved:FireAllClients(payload)
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
	if by and now() - fighter.lastHitAt <= HEALTH.LastHitCredit then
		return by
	end
	return nil
end

-- Targets ----------------------------------------------------------------------------

local function isEligibleTarget(attacker: Fighter, target: Fighter): boolean
	return target ~= attacker
		and isAlive(target)
		and target.incoming == nil
		and (target.root.Position - attacker.root.Position).Magnitude <= KICK.MaxRange
		and rules.canTarget(attacker.player, target.player)
end

-- Nearest eligible target (auto-launch, or retarget when the target vanishes).
local function pickAutoTarget(attacker: Fighter): Fighter?
	local best: Fighter? = nil
	local bestDistance = math.huge
	for _, candidate in fighters do
		if isEligibleTarget(attacker, candidate) then
			local distance = (candidate.root.Position - attacker.root.Position).Magnitude
			if distance < bestDistance then
				best, bestDistance = candidate, distance
			end
		end
	end
	return best
end

-- Flights ----------------------------------------------------------------------------

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
	attacker.surge = true
	attacker.rally = rally
	attacker.lastLaunchAt = t
	target.incoming = flight
	flights[flight.id] = flight
	recordSample(flight, t, gap)

	attacker.player:SetAttribute(ATTR.Surged, true)
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

-- Detach a flight from both fighters. Does NOT release the kicker's physics.
local function finishFlight(flight: Flight)
	flight.active = false
	flights[flight.id] = nil
	local attacker = flight.attacker
	if attacker.flight == flight then
		attacker.flight = nil
	end
	if flight.target.incoming == flight then
		flight.target.incoming = nil
	end
	attacker.mover.velocity.VectorVelocity = Vector3.zero
	attacker.player:SetAttribute(ATTR.Flying, false)
	if attacker.character.Parent then
		setCollisionGroup(attacker.character, Config.CollisionGroups.Characters)
	end
end

-- Abort a kick (target left, timeout, ...). The kicker keeps the Surge and may relaunch.
local function cancelFlight(flight: Flight)
	finishFlight(flight)
	release(flight.attacker)
	broadcastResolved(flight, "Cancelled", false)
end

-- The target vanished mid-flight: home in on the next best target instead.
local function redirectFlight(flight: Flight, newTarget: Fighter)
	finishFlight(flight)
	broadcastResolved(flight, "Cancelled", false)
	startFlight(flight.attacker, newTarget, flight.rally, false, false)
end

--[[
	No valid parry arrived during the clash window: the kick lands.
	Damage scales with the kick's speed (CombatMath.hitDamage), so a fast rally
	hurts far more than an opening kick. At 0 HP the victim is Defeated;
	otherwise they tumble away and the GameMode hears about it via Damaged
	(Surge mode passes the Surge to them).
]]
local function resolveHit(flight: Flight)
	local attacker, target = flight.attacker, flight.target
	finishFlight(flight)
	attacker.surge = false -- the Surge is spent; the GameMode decides who gets it next
	attacker.player:SetAttribute(ATTR.Surged, false)
	release(attacker)

	local damage = CombatMath.hitDamage(flight.speed, KICK.BaseSpeed, HEALTH.BaseDamage, HEALTH.DamageExponent)
	target.health = math.max(target.health - damage, 0)
	target.lastHitBy = attacker.player
	target.lastHitAt = now()
	target.player:SetAttribute(ATTR.Health, target.health)
	broadcastResolved(flight, "Hit", flight.perfect, damage) -- perfect: a Perfect counter-dash (hits harder)

	if target.health <= 0 then
		defeat(target, attacker.player, "Kick")
	else
		tumble(target, flight.direction)
		damaged:Fire(target.player, attacker.player, damage, target.health)
	end
end

--[[
	Blast a parried attacker back so it ends up `gap` studs from the defender
	along the incoming axis, unless it is already further away. The move is an
	instant server-side reposition, not a glide: the counter-dash launches on
	the same frame, and a glide would be overtaken at high rally speeds, turning
	every late parry into a point-blank, unanswerable kill.
	A raycast stops the blast at walls and floors.
]]
local function blastBack(attacker: Fighter, defender: Fighter, axis: Vector3, gap: number)
	local origin = attacker.root.Position
	local destination = defender.root.Position + axis * gap
	if (origin - defender.root.Position).Magnitude >= gap then
		return
	end

	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	local exclude: { Instance } = {}
	for _, fighter in fighters do
		table.insert(exclude, fighter.character)
	end
	params.FilterDescendantsInstances = exclude

	local hit = Workspace:Raycast(origin, destination - origin, params)
	if hit then
		destination = hit.Position - axis * 2 -- stop just short of the wall
	end
	attacker.root.CFrame = CFrame.new(destination) * attacker.root.CFrame.Rotation
end

--[[
	SUCCESSFUL PARRY
	  1. The attacker's momentum is cancelled: blasted back to the RICOCHET GAP
	     set by the defender's stance (CombatMath.ricochetGap), then stunned
	     mid-air for StunTime.
	  2. The defender absorbs the Surge and instantly ricochets, at the attacker
	     or at the redirect target it was locked onto, with rally + 1
	     (compounding +10%) and the one-shot Perfect boost if earned.
]]
local function resolveParry(flight: Flight, perfect: boolean, redirectTo: Fighter?)
	local attacker, defender = flight.attacker, flight.target
	finishFlight(flight)

	local axis = attacker.root.Position - defender.root.Position
	axis = if axis.Magnitude > 1e-3 then axis.Unit else -flight.direction
	local approachSpeed = trustedVelocity(defender):Dot(axis) -- > 0: stepping in, < 0: backpedalling
	local gap = CombatMath.ricochetGap(
		approachSpeed,
		PARRY.RicochetGap,
		PARRY.StanceFactor,
		PARRY.RicochetGapMin,
		PARRY.RicochetGapMax
	)
	attacker.surge = false
	attacker.player:SetAttribute(ATTR.Surged, false)
	attacker.lastHitBy = defender.player -- if the blast knocks them off the arena, the defender gets the credit
	attacker.lastHitAt = now()
	stun(attacker, PARRY.StunTime, -axis)
	blastBack(attacker, defender, axis, gap)

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
		local replacement = pickAutoTarget(attacker)
		if replacement then
			redirectFlight(flight, replacement)
		else
			cancelFlight(flight)
		end
		return
	end
	if t - flight.startedAt > KICK.MaxFlightTime then
		cancelFlight(flight)
		return
	end

	local velocity = attacker.mover.velocity
	local attackerPosition = attacker.root.Position
	local targetPosition = target.root.Position
	local gap = (targetPosition - attackerPosition).Magnitude
	recordSample(flight, t, gap)

	if flight.phase == "Clash" then
		velocity.VectorVelocity = Vector3.zero
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
		enterClash(flight, t)
		return
	end

	velocity.VectorVelocity = flight.direction * flight.speed
	attacker.mover.align.CFrame = feetFirst(flight.direction)
	broadcastEta(flight, t)
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

--[[
	RequestLaunch(targetUserId, cameraCFrame)
	The client says who its lock-on dot is on. The server re-checks EVERYTHING:
	Surge holder, not flying, not stunned, cooldown, target eligibility (alive,
	in range, mode rules) and that the target sits plausibly inside the camera
	the client claims to have.
]]
local function onLaunchRequest(player: Player, rawTargetId: unknown, rawCamera: unknown)
	if not launchLimiter:check(player) then
		return
	end
	local attacker = fighters[player]
	if attacker == nil or not isAlive(attacker) or not attacker.surge then
		return
	end
	local t = now()
	if
		attacker.flight
		or attacker.incoming
		or t < attacker.stunUntil
		or t - attacker.lastLaunchAt < KICK.LaunchCooldown
	then
		return
	end

	local targetPlayer = Guard.player(rawTargetId)
	local camera = Guard.cframe(rawCamera)
	local target = if targetPlayer then fighters[targetPlayer] else nil
	if target == nil or camera == nil or not isEligibleTarget(attacker, target) then
		return
	end

	-- The claimed camera must be near the body (exploits often "aim" from the target)...
	local maxCameraDistance = player.CameraMaxZoomDistance + Config.Targeting.CameraSlack
	if (camera.Position - attacker.root.Position).Magnitude > maxCameraDistance then
		return
	end
	-- ...and the target inside a generous cone of that camera (same dot product as the client).
	if not Targeting.isPlausible(camera, target.root.Position, Config.Targeting.ServerMinDot) then
		return
	end

	startFlight(attacker, target, attacker.rally, false, false)
end

local function whiff(defender: Fighter, t: number, result: Types.ParryResult, kickId: number)
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
	   F (or a naive macro) locks you out exactly when the kick arrives.
]]
local function onParryRequest(player: Player, rawKickId: unknown, rawStamp: unknown, rawLockId: unknown)
	local receivedAt = now()
	if not parryLimiter:check(player) then
		return
	end
	local defender = fighters[player]
	if defender == nil or not isAlive(defender) then
		return
	end
	if receivedAt < defender.parryLockUntil then
		sendParryFeedback(defender, "Cooldown", 0)
		return
	end

	local kickId = Guard.integer(rawKickId, 0, 2 ^ 31) or 0
	local flight = defender.incoming
	-- kickId 0 = "whatever is coming at me": the press may beat KickStarted to the client.
	if flight == nil or not flight.active or (kickId ~= 0 and kickId ~= flight.id) then
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
	local impactTime = if flight.phase == "Frozen" then math.huge else (flight.impactAt or flight.eta)
	local tti = impactTime - pressedAt
	local window = PARRY.BaseWindow + PlayerDataService.getParryWindowBonus(player)
	local verdict: CombatMath.Verdict = CombatMath.parryVerdict(tti, window, PARRY.PerfectWindow, PARRY.LateGrace)
	if verdict == "Early" or verdict == "Late" then
		whiff(defender, receivedAt, verdict, flight.id)
		return
	end

	-- 3. Distance
	local gap = gapAt(flight, pressedAt)
	local reach = KICK.ImpactRadius + (flight.speed + runCap(defender)) * (window + maxRewind) + PARRY.DistanceSlack
	if gap > reach then
		whiff(defender, receivedAt, "TooFar", flight.id)
		return
	end

	local perfect = verdict == "Perfect"
	recordIntegrity(player, flight, tti, perfect, pressedAt)
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

-- Per-frame systems ------------------------------------------------------------------------

local function stepHolds(t: number)
	for _, fighter in fighters do
		if fighter.holdUntil > 0 and fighter.flight == nil and t >= fighter.holdUntil then
			release(fighter) -- stun over: physics back to the client, gravity takes over
		end
	end
end

-- A Surge holder who stalls is launched at the nearest eligible target.
local function stepSurgeHolders(t: number)
	for _, fighter in fighters do
		if
			fighter.surge
			and fighter.flight == nil
			and isAlive(fighter)
			and t >= fighter.stunUntil
			and t - fighter.surgeSince > KICK.AutoLaunchTime
		then
			local target = pickAutoTarget(fighter)
			if target then
				startFlight(fighter, target, fighter.rally, false, false)
			else
				fighter.surgeSince = t
			end
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

	stepHolds(t)
	stepSurgeHolders(t)
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
		health = HEALTH.MaxHealth,
		lastHitBy = nil,
		lastHitAt = 0,
		surge = false,
		surgeSince = 0,
		rally = 0,
		flight = nil,
		incoming = nil,
		lastLaunchAt = 0,
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
				descendant.CollisionGroup = if fighter.flight
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

	player:SetAttribute(ATTR.MaxHealth, HEALTH.MaxHealth)
	player:SetAttribute(ATTR.Health, HEALTH.MaxHealth)
	player:SetAttribute(ATTR.InArena, true)
	return true
end

-- Remove a player from the fight (eliminated, left, round over). Idempotent.
function CombatService.unregisterCombatant(player: Player)
	local fighter = fighters[player]
	if fighter == nil then
		return
	end
	fighters[player] = nil -- first, so retargeting below can't pick them

	if fighter.flight then
		cancelFlight(fighter.flight)
	end
	local incoming = fighter.incoming
	if incoming and incoming.active then
		local replacement = pickAutoTarget(incoming.attacker)
		if replacement then
			redirectFlight(incoming, replacement)
		else
			cancelFlight(incoming)
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
	player:SetAttribute(ATTR.Surged, false)
	player:SetAttribute(ATTR.Flying, false)
	player:SetAttribute(ATTR.Stunned, false)
	player:SetAttribute(ATTR.Health, nil) -- health bars only exist in the arena
	player:SetAttribute(ATTR.MaxHealth, nil)
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
end

-- Injected by the RoundManager: the active GameMode's targeting rules.
function CombatService.setRules(newRules: ServerTypes.CombatRules?)
	rules = newRules or DEFAULT_RULES
end

function CombatService.grantSurge(player: Player, rally: number?)
	local fighter = fighters[player]
	if fighter == nil or not isAlive(fighter) then
		return
	end
	fighter.surge = true
	fighter.rally = rally or 0
	fighter.surgeSince = now()
	player:SetAttribute(ATTR.Surged, true)
end

function CombatService.clearSurge(player: Player)
	local fighter = fighters[player]
	if fighter and fighter.flight == nil then
		fighter.surge = false
		player:SetAttribute(ATTR.Surged, false)
	end
end

-- Who would be credited if this combatant went down right now (see recentAttacker).
function CombatService.getRecentAttacker(player: Player): Player?
	local fighter = fighters[player]
	return if fighter then recentAttacker(fighter) else nil
end

-- Current HP of a combatant (nil if not in the arena). Used for the round-timeout tiebreak.
function CombatService.getHealth(player: Player): number?
	local fighter = fighters[player]
	return if fighter then fighter.health else nil
end

function CombatService.getSurgeHolders(): { Player }
	local holders = {}
	for player, fighter in fighters do
		if fighter.surge and isAlive(fighter) then
			table.insert(holders, player)
		end
	end
	return holders
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
