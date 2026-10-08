--!strict
--[[
	Unit tests for src/shared/CombatMath.luau.

	CombatMath has no Roblox dependencies, so these run with the standalone
	Luau CLI (https://github.com/luau-lang/luau/releases):

	    luau tests/CombatMath.spec.luau

	Exit code is non-zero if any test fails.
]]

local CombatMath = require("../src/shared/CombatMath")

local passed, failed = 0, 0

local function test(name: string, body: () -> ())
	local ok, err = pcall(body)
	if ok then
		passed += 1
	else
		failed += 1
		print(`FAIL  {name}\n      {err}`)
	end
end

local function near(actual: number, expected: number, epsilon: number?)
	local tolerance = epsilon or 1e-9
	if math.abs(actual - expected) > tolerance then
		error(`expected {expected}, got {actual}`, 2)
	end
end

local function equal<T>(actual: T, expected: T)
	if actual ~= expected then
		error(`expected {tostring(expected)}, got {tostring(actual)}`, 2)
	end
end

local SPEED: CombatMath.SpeedParams = { baseSpeed = 75, growth = 1.1, maxMultiplier = 5, maxSpeed = 420 }

-- Ping-pong acceleration -----------------------------------------------------------------

test("opening kick flies at base speed", function()
	near(CombatMath.kickSpeed(SPEED, 0, 1), 75)
end)

test("each parry compounds speed by 10%", function()
	near(CombatMath.kickSpeed(SPEED, 1, 1), 82.5)
	near(CombatMath.kickSpeed(SPEED, 2, 1), 90.75)
	near(CombatMath.kickSpeed(SPEED, 3, 1), 99.825)
end)

test("compounding matches repeated multiplication (no drift)", function()
	local speed = 75
	for _ = 1, 12 do
		speed *= 1.1
	end
	near(CombatMath.kickSpeed(SPEED, 12, 1), math.min(speed, 75 * 5), 1e-9)
end)

test("rally multiplier is capped", function()
	near(CombatMath.rallyMultiplier(100, 1.1, 5), 5)
end)

test("perfect boost is one-shot on top of the rally", function()
	near(CombatMath.kickSpeed(SPEED, 2, 1.2), 90.75 * 1.2)
end)

test("speed never exceeds the hard cap", function()
	near(CombatMath.kickSpeed(SPEED, 50, 1.2), 420)
end)

test("negative rally counts are treated as zero", function()
	near(CombatMath.kickSpeed(SPEED, -3, 1), 75)
end)

-- Damage scales with speed ----------------------------------------------------------------------

local function damageAtRally(rally: number, bonus: number): number
	return CombatMath.hitDamage(CombatMath.kickSpeed(SPEED, rally, bonus), 75, 25, 1.5)
end

test("an opening kick chips 25 HP", function()
	equal(damageAtRally(0, 1), 25)
end)

test("damage ramps up as the rally speeds up", function()
	equal(damageAtRally(5, 1), 51)
	equal(damageAtRally(9, 1), 91)
end)

test("a 10-parry rally one-shots a full 100 HP bar (8 if the last parry was Perfect)", function()
	equal(damageAtRally(10, 1), 104)
	equal(damageAtRally(8, 1.2), 103)
	equal(damageAtRally(7, 1.2), 89)
end)

test("a Perfect counter-dash hits harder than a normal one", function()
	equal(damageAtRally(3, 1), 38)
	equal(damageAtRally(3, 1.2), 50)
end)

test("damage is a whole number and never below 1", function()
	equal(CombatMath.hitDamage(80, 75, 25, 1.5), 28)
	equal(CombatMath.hitDamage(0, 75, 25, 1.5), 1)
end)

-- Closing speed / time to impact ---------------------------------------------------------------

test("backpedalling slows the closing speed (buys time)", function()
	near(CombatMath.closingSpeed(100, 20, 0.25), 80)
end)

test("stepping in speeds up the closing speed", function()
	near(CombatMath.closingSpeed(100, -20, 0.25), 120)
end)

test("closing speed is floored so the ETA stays finite", function()
	near(CombatMath.closingSpeed(100, 500, 0.25), 25)
end)

test("time to impact subtracts the contact radius", function()
	near(CombatMath.timeToImpact(54.5, 4.5, 100), 0.5)
	near(CombatMath.timeToImpact(3, 4.5, 100), 0)
end)

test("zero closing speed means never", function()
	equal(CombatMath.timeToImpact(10, 4.5, 0), math.huge)
end)

-- Parry verdicts ---------------------------------------------------------------------------------

test("press too early whiffs", function()
	equal(CombatMath.parryVerdict(0.31, 0.30, 0.10, 0.03), "Early")
end)

test("press inside the window parries", function()
	equal(CombatMath.parryVerdict(0.25, 0.30, 0.10, 0.03), "Parry")
	equal(CombatMath.parryVerdict(0.30, 0.30, 0.10, 0.03), "Parry")
end)

test("press within 0.1 s of impact is Perfect", function()
	equal(CombatMath.parryVerdict(0.10, 0.30, 0.10, 0.03), "Perfect")
	equal(CombatMath.parryVerdict(0.0, 0.30, 0.10, 0.03), "Perfect")
end)

test("tiny late error is forgiven, real lateness is not", function()
	equal(CombatMath.parryVerdict(-0.02, 0.30, 0.10, 0.03), "Perfect")
	equal(CombatMath.parryVerdict(-0.05, 0.30, 0.10, 0.03), "Late")
end)

test("NaN or infinite time-to-impact is never a parry", function()
	equal(CombatMath.parryVerdict(0 / 0, 0.30, 0.10, 0.03), "Early")
	equal(CombatMath.parryVerdict(math.huge, 0.30, 0.10, 0.03), "Early")
end)

-- Lag compensation --------------------------------------------------------------------------------

test("max rewind is rtt + jitter + tolerance, capped", function()
	near(CombatMath.maxRewind(0.1, 0.01, 0.02, 0.25), 0.13)
	near(CombatMath.maxRewind(0.9, 0.2, 0.02, 0.25), 0.25)
end)

test("an honest stamp is used as-is", function()
	near(CombatMath.compensatedPressTime(99.95, 100, 0.13, 0.05), 99.95)
end)

test("a stamp from too far in the past is clamped to the latency envelope", function()
	-- An auto-parry claiming it pressed 1 s ago only gets the measured 0.13 s.
	near(CombatMath.compensatedPressTime(99.0, 100, 0.13, 0.05), 99.87)
end)

test("a stamp from the future is clamped to the receive time", function()
	near(CombatMath.compensatedPressTime(150, 100, 0.13, 0.05), 100)
end)

test("missing or garbage stamps fall back to receive time minus one-way latency", function()
	near(CombatMath.compensatedPressTime(nil, 100, 0.13, 0.05), 99.95)
	near(CombatMath.compensatedPressTime(0 / 0, 100, 0.13, 0.05), 99.95)
	near(CombatMath.compensatedPressTime(math.huge, 100, 0.13, 0.5), 99.87)
end)

-- Distance manipulation (ricochet gap) -------------------------------------------------------------------

test("standing still gives the base ricochet gap", function()
	near(CombatMath.ricochetGap(0, 26, 0.75, 12, 40), 26)
end)

test("walking backward blasts the attacker further away (buys time)", function()
	near(CombatMath.ricochetGap(-16, 26, 0.75, 12, 40), 38)
	near(CombatMath.ricochetGap(-40, 26, 0.75, 12, 40), 40)
end)

test("walking forward keeps them close (spike), down to the minimum", function()
	near(CombatMath.ricochetGap(8, 26, 0.75, 12, 40), 20)
	near(CombatMath.ricochetGap(40, 26, 0.75, 12, 40), 12)
end)

-- Shadow Clone lanes ------------------------------------------------------------------------------------

test("lanes start fully spread and converge on the target", function()
	near(CombatMath.laneDecay(50, 50, 9), 1)
	near(CombatMath.laneDecay(29.5, 50, 9), 0.5)
	near(CombatMath.laneDecay(5, 50, 9), 0)
end)

-- Statistics --------------------------------------------------------------------------------------------

test("median handles odd, even and empty inputs", function()
	near(CombatMath.median({ 3, 1, 2 }), 2)
	near(CombatMath.median({ 4, 1, 3, 2 }), 2.5)
	near(CombatMath.median({}), 0)
end)

test("median ignores a single lag spike", function()
	near(CombatMath.median({ 0.1, 0.1, 0.11, 0.09, 2.0 }), 0.1)
end)

test("median absolute deviation measures jitter", function()
	near(CombatMath.medianAbsoluteDeviation({ 0.1, 0.12, 0.08, 0.1, 0.1 }), 0)
	near(CombatMath.medianAbsoluteDeviation({ 1, 2, 3, 4, 5 }), 1)
end)

test("standard deviation (sample)", function()
	near(CombatMath.standardDeviation({ 2, 4, 4, 4, 5, 5, 7, 9 }), 2.138089935299395, 1e-12)
	near(CombatMath.standardDeviation({ 5 }), 0)
end)

print(`{passed} passed, {failed} failed`)
if failed > 0 then
	error("CombatMath tests failed")
end
