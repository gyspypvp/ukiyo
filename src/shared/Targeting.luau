--!strict
--[[
	Targeting (ModuleScript, ReplicatedStorage/Shared)
	==================================================
	Camera dot-product lock-on. Used by the CombatController to pick the target
	under the crosshair, and by the server to sanity-check the target a client
	claims it locked onto.

	THE MATH
	--------
	Camera at C, looking along the unit vector L. Candidate root at P.

	    d         = (P - C) / |P - C|      -- unit direction camera -> candidate
	    alignment = L · d = cos(theta)      -- 1 = dead centre, 0 = 90° off-axis

	A candidate is eligible when alignment >= minDot (theta inside the cone) and
	it is within range of the CHARACTER (not the camera, which may be zoomed out).
	Among eligible candidates the highest score wins:

	    score = alignment - range * distanceWeight (+ stickyBonus if already locked)

	which reads as "closest to the centre of the screen, slightly preferring
	nearer players, and reluctant to drop the current lock". The sticky bonus is
	hysteresis: without it the red dot flickers between two players standing side
	by side.

	Why a dot product instead of WorldToViewportPoint? It is cheaper, independent
	of FOV and aspect ratio, and identical on server and client, so the server can
	run the exact same check against the camera CFrame the client reports.
]]

local Workspace = game:GetService("Workspace")

local Targeting = {}

export type Candidate = {
	player: Player,
	root: BasePart,
}

export type Options = {
	minDot: number, -- cos(cone half-angle)
	maxRange: number, -- studs, measured from `origin`
	distanceWeight: number,
	stickyBonus: number,
	current: Player?, -- the player locked last frame (gets the sticky bonus)
	lineOfSight: RaycastParams?, -- nil skips the occlusion check
}

-- cos(angle) between the camera's look vector and the direction to `point`.
function Targeting.alignment(cameraCFrame: CFrame, point: Vector3): number
	local offset = point - cameraCFrame.Position
	local distance = offset.Magnitude
	if distance < 1e-4 then
		return 1
	end
	return cameraCFrame.LookVector:Dot(offset / distance)
end

-- Score for one candidate, or nil when it is outside the cone or out of range.
function Targeting.score(cameraCFrame: CFrame, origin: Vector3, point: Vector3, options: Options): number?
	local alignment = Targeting.alignment(cameraCFrame, point)
	if alignment < options.minDot then
		return nil
	end
	local range = (point - origin).Magnitude
	if range > options.maxRange then
		return nil
	end
	return alignment - range * options.distanceWeight
end

local function hasLineOfSight(origin: Vector3, point: Vector3, params: RaycastParams): boolean
	-- `params` must exclude every character, so any hit means a wall is in the way.
	return Workspace:Raycast(origin, point - origin, params) == nil
end

--[[
	Best target under the crosshair, or nil.
	`origin` is the local character's root (range + line of sight are measured
	from the body, while the angle is measured from the camera).
]]
function Targeting.findBest(
	cameraCFrame: CFrame,
	origin: Vector3,
	candidates: { Candidate },
	options: Options
): (Player?, BasePart?)
	local bestPlayer: Player? = nil
	local bestRoot: BasePart? = nil
	local bestScore = -math.huge

	for _, candidate in candidates do
		local score = Targeting.score(cameraCFrame, origin, candidate.root.Position, options)
		if score == nil then
			continue
		end
		if candidate.player == options.current then
			score += options.stickyBonus
		end
		-- Raycast only candidates that would actually win; usually 1-2 rays a frame.
		if score > bestScore then
			local params = options.lineOfSight
			if params == nil or hasLineOfSight(origin, candidate.root.Position, params) then
				bestPlayer, bestRoot, bestScore = candidate.player, candidate.root, score
			end
		end
	end

	return bestPlayer, bestRoot
end

--[[
	Server plausibility check: is `point` inside a (generous) cone of the camera
	the client claims it had? This stops naive "fire the remote at any UserId"
	scripts. It cannot stop a client that also forges its camera; the hard
	limits (holder check, range, rules.canTarget) still apply to those.
]]
function Targeting.isPlausible(cameraCFrame: CFrame, point: Vector3, minDot: number): boolean
	return Targeting.alignment(cameraCFrame, point) >= minDot
end

return table.freeze(Targeting)
