--!strict
--[[
	CombatMath (ModuleScript, ReplicatedStorage/Shared)
	===================================================
	Pure, side-effect-free math for the rally.

	No Roblox services, no Roblox datatypes and no requires: the same file runs
	on the server (authoritative), on the client (prediction / UI) and in the
	standalone Luau test runner (tests/CombatMath.spec.luau). Callers pass the
	tuning values in, which keeps this module trivially testable.
]]

local CombatMath = {}

export type SpeedParams = {
	baseSpeed: number,
	growth: number,
	maxMultiplier: number,
	maxSpeed: number,
}

export type Verdict = "Early" | "Late" | "Parry" | "Perfect"

local function isFinite(value: number): boolean
	return value == value and value ~= math.huge and value ~= -math.huge
end
CombatMath.isFinite = isFinite

--[[
	PING-PONG ACCELERATION
	The rally multiplier compounds: every successful parry multiplies speed by
	`growth` (1.10 = +10%).

	    multiplier(n) = min(growth ^ n, maxMultiplier)

	It is computed from the rally COUNT instead of `speed *= 1.1` on every hit,
	so there is no floating-point drift and the server can recompute any step of
	a rally from a single integer.
]]
function CombatMath.rallyMultiplier(rallyCount: number, growth: number, maxMultiplier: number): number
	return math.min(growth ^ math.max(rallyCount, 0), maxMultiplier)
end

--[[
	Final flight speed of one kick:

	    speed = baseSpeed * multiplier(rallyCount) * bonus, clamped to maxSpeed

	`bonus` holds one-shot modifiers that do NOT compound into the rally, e.g.
	the Perfect-parry 1.2x. Because it is applied after the rally multiplier, a
	Perfect parry makes that single counter-dash faster without inflating every
	future kick in the rally.
]]
function CombatMath.kickSpeed(params: SpeedParams, rallyCount: number, bonus: number): number
	local multiplier = CombatMath.rallyMultiplier(rallyCount, params.growth, params.maxMultiplier)
	return math.clamp(params.baseSpeed * multiplier * bonus, 0, params.maxSpeed)
end

--[[
	How fast the gap between kicker and target is shrinking.

	`targetRecedeSpeed` is the target's velocity along the flight direction
	(positive = running away, negative = running at the kicker). This is how
	"distance manipulation" works: backpedalling slows the closing speed (more
	time), stepping in speeds it up (less time).

	It is floored at a fraction of the flight speed because homing always catches
	up eventually, and the ETA must never become infinite or negative.
]]
function CombatMath.closingSpeed(flightSpeed: number, targetRecedeSpeed: number, floorFraction: number): number
	return math.max(flightSpeed - targetRecedeSpeed, flightSpeed * floorFraction)
end

-- Seconds until contact for a given gap (root-to-root) and closing speed.
function CombatMath.timeToImpact(gap: number, impactRadius: number, closing: number): number
	if closing <= 0 then
		return math.huge
	end
	return math.max(gap - impactRadius, 0) / closing
end

--[[
	PARRY TIMING VERDICT
	`tti` is the time-to-impact at the moment the defender pressed Block
	(positive = before contact, negative = after contact).

	    tti >  window              -> "Early"   (whiff, cooldown)
	    tti < -lateGrace           -> "Late"    (too late, you got kicked)
	    tti <= perfectWindow       -> "Perfect" (red aura, +20% counter-dash)
	    otherwise                  -> "Parry"
]]
function CombatMath.parryVerdict(tti: number, window: number, perfectWindow: number, lateGrace: number): Verdict
	if tti ~= tti or tti > window then
		return "Early"
	end
	if tti < -lateGrace then
		return "Late"
	end
	if tti <= perfectWindow then
		return "Perfect"
	end
	return "Parry"
end

--[[
	How far back in time we are willing to believe a client's parry happened.

	    maxRewind = clamp(rtt + jitter + tolerance, 0, cap)

	`rtt` comes from the server's own nonce pings (a client can only make it look
	WORSE, never better), and `cap` bounds even that.
]]
function CombatMath.maxRewind(rtt: number, jitter: number, tolerance: number, cap: number): number
	return math.clamp(rtt + jitter + tolerance, 0, math.max(cap, 0))
end

--[[
	LAG-COMPENSATED PRESS TIME
	`clientStamp` is the client's synced clock (workspace:GetServerTimeNow()) at
	the key press. It is UNTRUSTED. `receivedAt` is the server clock when the
	remote arrived, which is trusted.

	An honest stamp lands in [receivedAt - maxRewind, receivedAt]. A forged stamp
	is clamped into that envelope, so lying can buy at most `maxRewind`, and that
	value is bounded by measured latency plus a hard cap. A missing or garbage
	stamp falls back to "received minus one-way latency".
]]
function CombatMath.compensatedPressTime(
	clientStamp: number?,
	receivedAt: number,
	maxRewind: number,
	fallbackOneWay: number
): number
	local rewind = math.max(maxRewind, 0)
	if clientStamp == nil or not isFinite(clientStamp) then
		return receivedAt - math.clamp(fallbackOneWay, 0, rewind)
	end
	return math.clamp(clientStamp, receivedAt - rewind, receivedAt)
end

--[[
	RICOCHET GAP ("distance manipulation", part 2)
	How far from the defender the parried attacker ends up, which is the
	distance the counter-dash has to fly. `approachSpeed` is the defender's
	velocity component TOWARD the attacker at the moment of the parry
	(negative = walking backward).

	    gap = clamp(base - approachSpeed * factor, min, max)

	Walking backward blasts the attacker further away, so the counter-dash has
	a longer flight: it buys time and resets the tempo. Walking forward keeps
	them close, so the counter-dash lands fast and the opponent gets less
	reaction time.
]]
function CombatMath.ricochetGap(
	approachSpeed: number,
	base: number,
	factor: number,
	minDistance: number,
	maxDistance: number
): number
	return math.clamp(base - approachSpeed * factor, minDistance, maxDistance)
end

--[[
	DUEL TIGHTENING (Blade Ball-style close-range exchanges)
	The ricochet gap for the `rally`-th parry of a rally (1 = first parry):

	    gap = max(minGap, stanceGap * shrink ^ (rally - 1))

	The first parry uses the stance gap unchanged; every further parry pulls the
	two fighters closer, so a long rally turns into a fast close-range kick duel.
	A gap the stance already made smaller than minGap is kept (stepping in still spikes).
]]
function CombatMath.duelGap(stanceGap: number, rally: number, shrink: number, minGap: number): number
	local tightened = stanceGap * shrink ^ math.max(rally - 1, 0)
	return math.min(stanceGap, math.max(minGap, tightened))
end

--[[
	Bet odds, locked when a bet is placed. Priced by the target's share of the
	kicks the arena can still take before exploding (strikes are public, so flat
	odds would make backing the untouched fighter free money):

	    multiplier = clamp(edge * totalKicksLeft / targetKicksLeft,
	                       minMultiplier, max(alive * edge, minMultiplier))

	Shared so the lobby's odds preview is exactly what the server will lock in.
]]
function CombatMath.betMultiplier(
	totalKicksLeft: number,
	targetKicksLeft: number,
	alive: number,
	edge: number,
	minMultiplier: number
): number
	local cap = math.max(alive * edge, minMultiplier)
	return math.clamp(edge * totalKicksLeft / math.max(targetKicksLeft, 1), minMultiplier, cap)
end

--[[
	Shadow Clone lanes converge on the target: full lateral spread at activation,
	zero spread once the gap shrinks to `convergeDistance`.
]]
function CombatMath.laneDecay(gap: number, initialGap: number, convergeDistance: number): number
	local span = math.max(initialGap - convergeDistance, 1e-3)
	return math.clamp((gap - convergeDistance) / span, 0, 1)
end

-- Robust statistics (latency estimator + integrity checks) ----------------------------

function CombatMath.median(values: { number }): number
	local count = #values
	if count == 0 then
		return 0
	end
	local sorted = table.clone(values)
	table.sort(sorted)
	local middle = count // 2
	if count % 2 == 1 then
		return sorted[middle + 1]
	end
	return (sorted[middle] + sorted[middle + 1]) / 2
end

-- Median absolute deviation: a jitter estimate that ignores one-off spikes.
function CombatMath.medianAbsoluteDeviation(values: { number }): number
	local center = CombatMath.median(values)
	local deviations = table.create(#values, 0)
	for index, value in values do
		deviations[index] = math.abs(value - center)
	end
	return CombatMath.median(deviations)
end

function CombatMath.mean(values: { number }): number
	local count = #values
	if count == 0 then
		return 0
	end
	local total = 0
	for _, value in values do
		total += value
	end
	return total / count
end

function CombatMath.standardDeviation(values: { number }): number
	local count = #values
	if count < 2 then
		return 0
	end
	local average = CombatMath.mean(values)
	local sumSquares = 0
	for _, value in values do
		sumSquares += (value - average) ^ 2
	end
	return math.sqrt(sumSquares / (count - 1))
end

return table.freeze(CombatMath)
