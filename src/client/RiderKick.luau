--!strict
--[[
	RiderKick (ModuleScript, StarterPlayerScripts/Client)
	=====================================================
	The flying-kick look, inspired by the finishing kicks of tokusatsu heroes:
	the body angled into the kick, one leg locked straight at the target, the
	other tucked, one arm swept back and the other guarding, and a foot that
	glows hotter the longer the rally runs.

	  * POSE: while a player is a kick (Flying attribute) or diving in an
	    ULTIMATE, their joints are posed procedurally. Motor6D.Transform is
	    written in RunService.Stepped, after the Animator has written it for
	    this frame, and blended in/out so it never snaps. R15 and R6 are both
	    supported (R6 has no knees or elbows, and its limb joints turn about
	    their Z axis with mirrored signs on the left side).
	  * ULTIMATE LEAP: a tucked front flip over the leap (a rotation on the
	    root joint), then the kick pose for the dive.
	  * FOOT GLOW: a light, embers and a trail on the kicking foot (see glow()).

	Everything here is local and cosmetic: Transform writes never replicate,
	and the server's hitbox is the root part, which this never moves. The
	pose numbers are tuning by eye; adjust them freely.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local Net = require(Shared:WaitForChild("Net"))

local ATTR = Net.Attributes
local SPARK_TEXTURE = "rbxasset://textures/particles/sparkles_main.dds"
local BLEND_TIME = 0.08 -- seconds to blend the pose in or out
local LEAN = 0.55 -- radians the body leans into the kick (the kicking hip flexes by the same amount)

type Pose = { [string]: CFrame }
type Mode = "Kick" | "Flip"

type PoseState = {
	weight: number,
	mode: Mode,
	motors: { [string]: Motor6D },
	isR6: boolean,
}

export type Glow = {
	setEnabled: (enabled: boolean) -> (),
	destroy: () -> (),
}

local RiderKick = {}

local function rx(angle: number): CFrame
	return CFrame.Angles(angle, 0, 0)
end

local function rz(angle: number): CFrame
	return CFrame.Angles(0, 0, angle)
end

--[[
	Poses, in each joint's own frame. The server flies the body feet-first
	along the kick, so the root's -Y points at the target. The body leans by
	LEAN and the kicking (right) hip flexes by the same amount, which keeps the
	kicking leg exactly on the flight line while the torso sits back into it.
	R15: +X rotation swings a limb forward. R6: limbs turn about Z, positive is
	forward on the right side and negative on the left; the R6 root joint and
	neck are flipped relative to R15.
]]
local R15_KICK: Pose = {
	Root = rx(-LEAN),
	RightHip = rx(LEAN), -- the kicking leg: straight down the flight line
	RightKnee = CFrame.identity, -- locked
	LeftHip = rx(LEAN + 1.3), -- the other leg tucked up...
	LeftKnee = rx(-2.0), -- ...shin folded back
	Waist = rx(-0.15),
	Neck = rx(-0.45), -- chin down: eyes on the target
	RightShoulder = CFrame.Angles(-0.9, 0, 0.7), -- swept back and out
	RightElbow = rx(0.35),
	LeftShoulder = CFrame.Angles(1.4, 0, 0.3), -- guarding forward, across the body
	LeftElbow = rx(1.1),
}

local R6_KICK: Pose = {
	RootJoint = rx(LEAN),
	["Right Hip"] = rz(LEAN),
	["Left Hip"] = rz(-(LEAN + 0.9)),
	Neck = rx(0.45),
	["Right Shoulder"] = rz(-0.9),
	["Left Shoulder"] = rz(-1.4),
}

-- The tuck held through the ULTIMATE's front flip (the spin itself is added on the root).
local R15_TUCK: Pose = {
	RightHip = rx(1.6),
	LeftHip = rx(1.6),
	RightKnee = rx(-2.1),
	LeftKnee = rx(-2.1),
	Waist = rx(-0.4),
	Neck = rx(-0.3),
	RightShoulder = rx(0.9),
	LeftShoulder = rx(0.9),
	RightElbow = rx(1.2),
	LeftElbow = rx(1.2),
}

local R6_TUCK: Pose = {
	["Right Hip"] = rz(1.5),
	["Left Hip"] = rz(-1.5),
	["Right Shoulder"] = rz(0.9),
	["Left Shoulder"] = rz(-0.9),
	Neck = rx(0.3),
}

local states: { [Model]: PoseState } = {}
type Leap = { startedAt: number, diveAt: number } -- server times
local leaps: { [Player]: Leap } = {} -- ULTIMATE performers mid-leap

local function motorsOf(character: Model): { [string]: Motor6D }
	local motors: { [string]: Motor6D } = {}
	for _, descendant in character:GetDescendants() do
		if descendant:IsA("Motor6D") then
			motors[descendant.Name] = descendant
		end
	end
	return motors
end

local function stateFor(character: Model): PoseState?
	local state = states[character]
	if state then
		return state
	end
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if humanoid == nil then
		return nil
	end
	local created: PoseState = {
		weight = 0,
		mode = "Kick",
		motors = motorsOf(character),
		isR6 = humanoid.RigType == Enum.HumanoidRigType.R6,
	}
	states[character] = created
	return created
end

-- Smooth 0 -> 1 (eases the flip in and out).
local function smoothstep(x: number): number
	local t = math.clamp(x, 0, 1)
	return t * t * (3 - 2 * t)
end

local function applyPose(state: PoseState, pose: Pose, weight: number)
	for name, target in pose do
		local motor = state.motors[name]
		if motor and motor.Parent then
			motor.Transform = motor.Transform:Lerp(target, weight)
		end
	end
end

-- The front flip: the tuck plus a full turn on the root joint, `progress` 0..1 through the leap.
local function applyFlip(state: PoseState, progress: number, weight: number)
	local turn = math.pi * 2 * smoothstep(progress)
	if state.isR6 then
		applyPose(state, R6_TUCK, weight)
		local root = state.motors.RootJoint
		if root then
			root.Transform = root.Transform:Lerp(rx(turn), weight) -- R6 root joint: +X is a front flip
		end
	else
		applyPose(state, R15_TUCK, weight)
		local root = state.motors.Root
		if root then
			root.Transform = root.Transform:Lerp(rx(-turn), weight) -- R15: -X is a front flip
		end
	end
end

local function step(dt: number)
	local t = Workspace:GetServerTimeNow()
	local seen: { [Model]: boolean } = {}
	local blend = math.min(dt / BLEND_TIME, 1)

	for _, player in Players:GetPlayers() do
		local character = player.Character
		if character == nil then
			continue
		end
		local performing = player:GetAttribute(ATTR.Ultimate) == true
		local leap: Leap? = leaps[player]
		if leap and t >= leap.diveAt then
			leaps[player] = nil -- the leap is over (the Dive / Miss / Cancel packet also ends it)
			leap = nil
		end
		local wanted: Mode? = if leap
			then "Flip"
			elseif performing or player:GetAttribute(ATTR.Flying) == true then "Kick"
			else nil

		local existing = states[character]
		if wanted == nil and (existing == nil or existing.weight <= 0) then
			continue -- not posing: leave the Animator alone
		end
		local state = existing or stateFor(character)
		if state == nil then
			continue
		end
		seen[character] = true

		if wanted then
			state.mode = wanted
			state.weight = math.min(state.weight + blend, 1)
		else
			state.weight = math.max(state.weight - blend, 0)
		end
		if state.weight <= 0 then
			continue
		end

		if state.mode == "Flip" and leap then
			-- One flip over LeapTime from the start, then hold the tuck if the leap
			-- hangs at its apex (the server can push the dive back).
			local progress = (t - leap.startedAt) / Config.Ultimate.LeapTime
			applyFlip(state, progress, state.weight)
		else
			applyPose(state, if state.isR6 then R6_KICK else R15_KICK, state.weight)
		end
	end

	-- Forget characters that are gone or no longer posed.
	for character, state in states do
		if not seen[character] and (state.weight <= 0 or character.Parent == nil) then
			states[character] = nil
		end
	end
end

-- Public API ---------------------------------------------------------------------------

-- Colour of a kick by its rally: amber -> red -> white-hot, crimson for a Perfect counter.
function RiderKick.heatColor(rally: number, perfect: boolean): Color3
	if perfect then
		return Color3.fromRGB(255, 40, 70)
	end
	local heat = math.clamp(rally / 10, 0, 1)
	if heat < 0.5 then
		return Color3.fromRGB(255, 176, 64):Lerp(Color3.fromRGB(255, 64, 48), heat * 2)
	end
	return Color3.fromRGB(255, 64, 48):Lerp(Color3.fromRGB(255, 236, 250), (heat - 0.5) * 2)
end

--[[
	Light, embers and a trail on the kicking foot. `power` 0..1 scales the
	light, the ember rate and the trail length. Returns a handle so the caller
	can hide it (Invis-Dash) and remove it when the kick ends.
]]
function RiderKick.glow(character: Model, color: Color3, power: number): Glow?
	local foot = character:FindFirstChild("RightFoot") or character:FindFirstChild("Right Leg")
	if foot == nil or not foot:IsA("BasePart") then
		return nil
	end
	local sole = -foot.Size.Y / 2
	local center = Instance.new("Attachment")
	center.Name = "CK_FootGlow"
	center.Position = Vector3.new(0, sole, 0)
	center.Parent = foot
	local edgeA = Instance.new("Attachment")
	edgeA.Position = Vector3.new(-0.5, sole, 0)
	edgeA.Parent = foot
	local edgeB = Instance.new("Attachment")
	edgeB.Position = Vector3.new(0.5, sole, 0)
	edgeB.Parent = foot

	local light = Instance.new("PointLight")
	light.Color = color
	light.Range = 8 + 8 * power
	light.Brightness = 3 + 4 * power
	light.Parent = center

	local embers = Instance.new("ParticleEmitter")
	embers.Texture = SPARK_TEXTURE
	embers.Color = ColorSequence.new(Color3.new(1, 1, 1), color)
	embers.LightEmission = 1
	embers.Lifetime = NumberRange.new(0.15, 0.3)
	embers.Speed = NumberRange.new(2, 6)
	embers.SpreadAngle = Vector2.new(30, 30)
	embers.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.9 + power),
		NumberSequenceKeypoint.new(1, 0),
	})
	embers.Rate = 40 + 80 * power
	embers.Parent = center

	local trail = Instance.new("Trail")
	trail.Attachment0 = edgeA
	trail.Attachment1 = edgeB
	trail.Lifetime = 0.18 + 0.2 * power
	trail.LightEmission = 1
	trail.FaceCamera = true
	trail.WidthScale = NumberSequence.new(1, 0)
	trail.Color = ColorSequence.new(Color3.new(1, 1, 1), color)
	trail.Transparency = NumberSequence.new(0.05, 1)
	trail.Parent = foot

	return {
		setEnabled = function(enabled: boolean)
			light.Enabled = enabled
			embers.Enabled = enabled
			trail.Enabled = enabled
		end,
		destroy = function()
			trail:Destroy()
			center:Destroy() -- takes the light and the embers with it
			edgeA:Destroy()
			edgeB:Destroy()
		end,
	}
end

-- An ULTIMATE leap started (or was re-synced): flip, hold the tuck until `diveAt`
-- (server time), then the kick pose for the dive. A re-sync keeps the original start.
function RiderKick.startLeap(player: Player, diveAt: number)
	local leap = leaps[player]
	if leap then
		leap.diveAt = diveAt
	else
		leaps[player] = { startedAt = diveAt - Config.Ultimate.LeapTime, diveAt = diveAt }
	end
end

-- The ULTIMATE dived early, missed or was cancelled.
function RiderKick.endLeap(player: Player)
	leaps[player] = nil
end

function RiderKick.init()
	RunService.Stepped:Connect(function(_time: number, dt: number)
		step(dt)
	end)
	Players.PlayerRemoving:Connect(function(player: Player)
		leaps[player] = nil
	end)
end

return RiderKick
