--!strict
--[[
	CombatFX (ModuleScript, StarterPlayerScripts/Client)
	====================================================
	Purely cosmetic, client-side visuals. Nothing here affects gameplay: the
	server decides every outcome, and this module just draws it.

	  * Stun glow (attribute-driven), glowing kick foot and pose (RiderKick),
	    parry shockwave + sparks, head-on clash burst, Perfect-parry red aura
	  * Duels: a rally counter between the two fighters that ticks up per parry
	  * Strikes: "STRIKE 1" / "STRIKE 2" popups, and on the finishing strike an
	    explosion (fireball, shock ring, smoke, embers, light, camera shake)
	    that hides the exploded body until the server moves it to the lobby
	  * ULTIMATE: the performer's aura and the impact marker on the ground,
	    filling up until the dive lands; DASH: a short trail
	  * Leg Style effects: Invis-Dash, Shadow Clone decoys, Lag Switch glitch
	  * Toast text ("PERFECT!", "DASH!", ...)

	Every effect tied to a kick registers a cleanup under its kickId, run when
	KickResolved arrives (with a timeout failsafe if that packet is ever lost).
]]

local Debris = game:GetService("Debris")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local CombatMath = require(Shared:WaitForChild("CombatMath"))
local Config = require(Shared:WaitForChild("Config"))
local Net = require(Shared:WaitForChild("Net"))
local Types = require(Shared:WaitForChild("Types"))
local RiderKick = require(script.Parent:WaitForChild("RiderKick"))
local UiTheme = require(script.Parent:WaitForChild("UiTheme"))

local ATTR = Net.Attributes
local COLORS = UiTheme.Colors
local localPlayer = Players.LocalPlayer

local KICK_COLOR = COLORS.Kick
local PERFECT_COLOR = Color3.fromRGB(255, 40, 60)
local STUN_COLOR = Color3.fromRGB(255, 230, 90)
local SPARK_TEXTURE = "rbxasset://textures/particles/sparkles_main.dds"
local SMOKE_TEXTURE = "rbxasset://textures/particles/smoke_main.dds"
local FIRE_TEXTURE = "rbxasset://textures/particles/fire_main.dds"
local EXPLOSION_HIDE_TIME = 1.4 -- the server moves an exploded player to the lobby after ~1.25 s
local SHAKE_RANGE = 90 -- studs: explosions closer than this shake your camera

local CombatFX = {}

local stunGlows: { [Player]: Highlight } = {}
local cleanups: { [number]: { () -> () } } = {}
-- Per-kick visuals that would give away an Invis-Dash kicker (hidden when it activates).
local kickGlows: { [number]: RiderKick.Glow } = {}
local kickMarks: { [number]: Highlight } = {}
local ultimateZones: { [number]: () -> () } = {} -- ULTIMATE id -> removes its impact marker
local toastLabel: TextLabel? = nil

-- Helpers ---------------------------------------------------------------------------

local function rootOf(player: Player?): BasePart?
	local character = player and player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if root and root:IsA("BasePart") then
		return root
	end
	return nil
end

local function addCleanup(kickId: number, cleanup: () -> ())
	local list = cleanups[kickId]
	if list == nil then
		local created: { () -> () } = {}
		list = created
		cleanups[kickId] = created
		-- Failsafe: never leak an effect if KickResolved is lost.
		task.delay(Config.Kick.MaxFlightTime + 2, function()
			CombatFX.cleanupKick(kickId)
		end)
	end
	table.insert(list :: { () -> () }, cleanup)
end

-- Anchored, non-interactive part for one-shot effects (excluded from raycasts).
local function effectPart(position: Vector3): Part
	local part = Instance.new("Part")
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.Transparency = 1
	part.Size = Vector3.one
	part.CFrame = CFrame.new(position)
	part.Parent = Workspace
	return part
end

local function burst(position: Vector3, color: Color3, count: number, speed: number)
	local part = effectPart(position)
	local emitter = Instance.new("ParticleEmitter")
	emitter.Texture = SPARK_TEXTURE
	emitter.Color = ColorSequence.new(Color3.new(1, 1, 1), color)
	emitter.LightEmission = 1
	emitter.Lifetime = NumberRange.new(0.2, 0.45)
	emitter.Speed = NumberRange.new(speed * 0.5, speed)
	emitter.SpreadAngle = Vector2.new(180, 180)
	emitter.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 1.2),
		NumberSequenceKeypoint.new(1, 0),
	})
	emitter.Rate = 0
	emitter.Parent = part

	local light = Instance.new("PointLight")
	light.Color = color
	light.Range = 16
	light.Brightness = 6
	light.Parent = part
	TweenService:Create(light, TweenInfo.new(0.3), { Brightness = 0 }):Play()

	emitter:Emit(count)
	Debris:AddItem(part, 1)
end

-- A flat neon disc that expands and fades: the shockwave of a parry or an explosion.
-- `normal` is the axis the disc faces (the kick direction; straight up for a ground ring).
local function shockRing(
	position: Vector3,
	normal: Vector3,
	color: Color3,
	fromSize: number,
	toSize: number,
	time: number
)
	local axis = if normal.Magnitude > 1e-3 then normal.Unit else Vector3.yAxis
	local up = if math.abs(axis.Y) > 0.98 then Vector3.zAxis else Vector3.yAxis
	local ring = effectPart(position)
	ring.Shape = Enum.PartType.Cylinder -- a cylinder's axis is its X axis
	ring.Material = Enum.Material.Neon
	ring.Color = color
	ring.Transparency = 0.25
	ring.Size = Vector3.new(0.25, fromSize, fromSize)
	ring.CFrame = CFrame.lookAt(position, position + axis, up) * CFrame.Angles(0, math.pi / 2, 0)
	TweenService:Create(ring, TweenInfo.new(time, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
		Size = Vector3.new(0.25, toSize, toSize),
		Transparency = 1,
	}):Play()
	Debris:AddItem(ring, time + 0.05)
end

-- A world-space popup ("STRIKE 2", "x7") that drifts up and fades.
local function popup(position: Vector3, text: string, color: Color3, height: number, rise: number)
	local part = effectPart(position)
	local gui = Instance.new("BillboardGui")
	gui.Size = UDim2.fromOffset(height * 5, height)
	gui.AlwaysOnTop = true
	gui.LightInfluence = 0
	gui.Parent = part

	local label = UiTheme.text(gui, UiTheme.FontHeavy, color)
	label.Size = UDim2.fromScale(1, 1)
	label.Text = text
	local outline = UiTheme.stroke(label, 1.5, Color3.new(0, 0, 0), 0.35)

	TweenService:Create(gui, TweenInfo.new(0.9, Enum.EasingStyle.Quad), { StudsOffset = Vector3.new(0, rise, 0) })
		:Play()
	local fade = TweenInfo.new(0.4, Enum.EasingStyle.Quad, Enum.EasingDirection.In, 0, false, 0.5)
	TweenService:Create(label, fade, { TextTransparency = 1 }):Play()
	TweenService:Create(outline, fade, { Transparency = 1 }):Play()
	Debris:AddItem(part, 1)
end

-- Briefly shake the local camera, stronger the closer the blast.
local shakeToken = 0
local function shakeCamera(origin: Vector3, strength: number, duration: number)
	local camera = Workspace.CurrentCamera
	if camera == nil then
		return
	end
	local distance = (camera.CFrame.Position - origin).Magnitude
	if distance > SHAKE_RANGE then
		return
	end
	local amplitude = strength * (1 - distance / SHAKE_RANGE)
	shakeToken += 1
	local token = shakeToken
	local startedAt = os.clock()
	local name = `CK_Shake{token}`
	RunService:BindToRenderStep(name, Enum.RenderPriority.Camera.Value + 2, function()
		local elapsed = os.clock() - startedAt
		local current = Workspace.CurrentCamera
		if elapsed >= duration or token ~= shakeToken or current == nil then
			RunService:UnbindFromRenderStep(name)
			return
		end
		-- Applied after the camera script each frame, so it never accumulates.
		local decay = amplitude * (1 - elapsed / duration)
		current.CFrame = current.CFrame * CFrame.Angles((math.random() - 0.5) * decay, (math.random() - 0.5) * decay, 0)
	end)
end

local function pulseHighlight(character: Model, color: Color3, duration: number)
	local highlight = Instance.new("Highlight")
	highlight.FillColor = color
	highlight.OutlineColor = color
	highlight.FillTransparency = 0.2
	highlight.OutlineTransparency = 0
	highlight.Adornee = character
	highlight.Parent = character
	TweenService:Create(highlight, TweenInfo.new(duration), { FillTransparency = 1, OutlineTransparency = 1 }):Play()
	Debris:AddItem(highlight, duration)
end

-- Stun glow ---------------------------------------------------------------------------

local function refreshPlayer(player: Player)
	local stunned = player:GetAttribute(ATTR.Stunned) == true
	local glow: Highlight? = stunGlows[player]
	if stunned and glow == nil and player.Character then
		local highlight = Instance.new("Highlight")
		highlight.FillTransparency = 1
		highlight.OutlineColor = STUN_COLOR
		highlight.Adornee = player.Character
		highlight.Parent = player.Character
		stunGlows[player] = highlight
	elseif not stunned and glow then
		glow:Destroy()
		stunGlows[player] = nil
	end
end

-- DASH: a short trail on whoever dashed. Every client sees DashReadyAt change,
-- so no extra remote is needed: a fresh cooldown means a dash just started.
local function dashTrail(player: Player)
	local readyAt = player:GetAttribute(ATTR.DashReadyAt)
	if typeof(readyAt) ~= "number" or readyAt - Config.Dash.Cooldown < Workspace:GetServerTimeNow() - 0.25 then
		return
	end
	local root = rootOf(player)
	if root == nil then
		return
	end
	local top = Instance.new("Attachment")
	top.Position = Vector3.new(0, 1.4, 0)
	top.Parent = root
	local bottom = Instance.new("Attachment")
	bottom.Position = Vector3.new(0, -1.6, 0)
	bottom.Parent = root
	local trail = Instance.new("Trail")
	trail.Attachment0 = top
	trail.Attachment1 = bottom
	trail.Lifetime = 0.2
	trail.LightEmission = 0.6
	trail.Color = ColorSequence.new(COLORS.Dash)
	trail.Transparency = NumberSequence.new(0.3, 1)
	trail.Parent = root
	task.delay(Config.Dash.Time + 0.05, function()
		trail.Enabled = false
	end)
	Debris:AddItem(trail, 0.6)
	Debris:AddItem(top, 0.6)
	Debris:AddItem(bottom, 0.6)
end

local function watchPlayer(player: Player)
	player:GetAttributeChangedSignal(ATTR.Stunned):Connect(function()
		refreshPlayer(player)
	end)
	player:GetAttributeChangedSignal(ATTR.DashReadyAt):Connect(function()
		dashTrail(player)
	end)
	player.CharacterAdded:Connect(function()
		stunGlows[player] = nil -- the old glow died with the old character
		task.defer(refreshPlayer, player)
	end)
	refreshPlayer(player)
end

-- Leg Style effects --------------------------------------------------------------------

local function setBodyTransparency(character: Model, modifier: number)
	for _, descendant in character:GetDescendants() do
		if descendant:IsA("BasePart") then
			descendant.LocalTransparencyModifier = modifier
		elseif descendant:IsA("Decal") then
			descendant.LocalTransparencyModifier = modifier -- faces
		end
	end
end

local function setCharacterHidden(player: Player, hidden: boolean)
	local character = player.Character
	if character == nil then
		return
	end
	-- The kicker still sees a ghost of themselves; everyone else sees nothing.
	setBodyTransparency(character, if not hidden then 0 elseif player == localPlayer then 0.6 else 1)
end

local function invisDash(payload: Types.EffectPayload)
	local player = Players:GetPlayerByUserId(payload.userId)
	if player == nil then
		return
	end
	setCharacterHidden(player, true)
	-- The glowing foot and the "kicking you" outline would give the invisible kicker away.
	local glow, mark = kickGlows[payload.kickId], kickMarks[payload.kickId]
	if glow then
		glow.setEnabled(false)
	end
	if mark then
		mark.Enabled = false
	end
	addCleanup(payload.kickId, function()
		setCharacterHidden(player, false)
	end)
end

-- Decoys are local clones: no physics, no hitbox, no replication cost.
local function prepareDecoy(decoy: Model)
	for _, descendant in decoy:GetDescendants() do
		if descendant:IsA("BaseScript") or descendant:IsA("ModuleScript") or descendant:IsA("Constraint") then
			descendant:Destroy()
		elseif descendant:IsA("BasePart") then
			descendant.Anchored = true
			descendant.CanCollide = false
			descendant.CanQuery = false
			descendant.CanTouch = false
		elseif descendant:IsA("Highlight") then
			descendant.Adornee = decoy -- the cloned aura must outline the clone
		end
	end
end

local function shadowClone(payload: Types.EffectPayload)
	local attacker = Players:GetPlayerByUserId(payload.userId)
	local target = Players:GetPlayerByUserId(payload.targetId)
	local character = attacker and attacker.Character
	if attacker == nil or target == nil or character == nil then
		return
	end
	local realLane = payload.realLane or 0
	local spread = payload.spread or 8
	local initialGap = payload.initialGap or 30

	local wasArchivable = character.Archivable
	character.Archivable = true -- player characters can't be cloned otherwise
	local decoys: { { model: Model, lane: number } } = {}
	for lane = -1, 1 do
		if lane ~= realLane then
			local clone = character:Clone()
			prepareDecoy(clone)
			clone.Parent = Workspace
			table.insert(decoys, { model = clone, lane = lane })
		end
	end
	character.Archivable = wasArchivable

	-- Same lane math as the server (CombatMath.laneDecay): lanes converge on the target.
	local connection = RunService.RenderStepped:Connect(function()
		local attackerRoot, targetRoot = rootOf(attacker), rootOf(target)
		if attackerRoot == nil or targetRoot == nil then
			return
		end
		local offset = targetRoot.Position - attackerRoot.Position
		local flat = Vector3.new(offset.X, 0, offset.Z)
		local lateral = if flat.Magnitude > 1e-3 then flat.Unit:Cross(Vector3.yAxis) else Vector3.xAxis
		local decay = CombatMath.laneDecay(offset.Magnitude, initialGap, Config.Kick.ImpactRadius * 2)
		for _, decoy in decoys do
			decoy.model:PivotTo(attackerRoot.CFrame + lateral * ((decoy.lane - realLane) * spread * decay))
		end
	end)

	addCleanup(payload.kickId, function()
		connection:Disconnect()
		for _, decoy in decoys do
			local root = decoy.model:FindFirstChild("HumanoidRootPart")
			if root and root:IsA("BasePart") then
				burst(root.Position, Color3.fromRGB(120, 60, 200), 12, 12)
			end
			decoy.model:Destroy()
		end
	end)
end

local function lagSwitch(payload: Types.EffectPayload)
	local player = Players:GetPlayerByUserId(payload.userId)
	local character = player and player.Character
	if character == nil then
		return
	end
	local highlight = Instance.new("Highlight")
	highlight.FillColor = Color3.new(1, 1, 1)
	highlight.OutlineColor = Color3.fromRGB(0, 255, 200)
	highlight.Adornee = character
	highlight.Parent = character

	local running = true
	task.spawn(function()
		local endsAt = os.clock() + (payload.duration or 0.5)
		while running and os.clock() < endsAt do
			highlight.Enabled = not highlight.Enabled
			highlight.FillTransparency = math.random() * 0.6
			task.wait(0.04)
		end
		highlight:Destroy()
	end)
	addCleanup(payload.kickId, function()
		running = false
	end)
end

-- Public API --------------------------------------------------------------------------

function CombatFX.cleanupKick(kickId: number)
	local list = cleanups[kickId]
	cleanups[kickId] = nil
	if list then
		for _, cleanup in list do
			task.spawn(cleanup)
		end
	end
end

-- Big center-screen text: "PERFECT!", "DASH!", "NO TARGET"...
function CombatFX.toast(text: string, color: Color3)
	local label = toastLabel
	if label == nil then
		return
	end
	label.Text = text
	label.TextColor3 = color
	label.TextTransparency = 0
	label.Size = UDim2.fromScale(0.48, 0.085)
	TweenService:Create(label, TweenInfo.new(0.12, Enum.EasingStyle.Back), { Size = UDim2.fromScale(0.42, 0.07) })
		:Play()
	TweenService:Create(label, TweenInfo.new(0.5, Enum.EasingStyle.Quad, Enum.EasingDirection.In, 0, false, 0.45), {
		TextTransparency = 1,
	}):Play()
end

-- Local feedback the instant Block is pressed (never predicts the OUTCOME).
function CombatFX.parrySwing(player: Player)
	local root = rootOf(player)
	if root == nil then
		return
	end
	local shield = effectPart(root.Position)
	shield.Shape = Enum.PartType.Ball
	shield.Size = Vector3.one * 6
	shield.Material = Enum.Material.ForceField
	shield.Color = Color3.fromRGB(90, 170, 255)
	shield.Transparency = 0.2
	TweenService:Create(shield, TweenInfo.new(0.18), { Size = Vector3.one * 9, Transparency = 1 }):Play()
	Debris:AddItem(shield, 0.2)
end

function CombatFX.onKickStarted(payload: Types.KickStartedPayload)
	local attacker = Players:GetPlayerByUserId(payload.attackerId)
	local root = rootOf(attacker)
	if attacker == nil or root == nil then
		return
	end

	-- The kicking foot glows, hotter as the rally accelerates (the pose itself is
	-- RiderKick's, driven by the Flying attribute).
	local color = RiderKick.heatColor(payload.rally, payload.perfect)
	local character = attacker.Character
	local glow = if character then RiderKick.glow(character, color, math.clamp(payload.rally / 10, 0, 1)) else nil
	if glow then
		kickGlows[payload.kickId] = glow
		addCleanup(payload.kickId, function()
			kickGlows[payload.kickId] = nil
			glow.destroy()
		end)
	end

	-- Duel rally counter: "x2", "x3"... between the two fighters, bigger as it climbs.
	local targetRoot = rootOf(Players:GetPlayerByUserId(payload.targetId))
	if payload.rally >= 2 and targetRoot then
		local midpoint = (root.Position + targetRoot.Position) / 2 + Vector3.new(0, 4, 0)
		popup(midpoint, `x{payload.rally}`, color, math.clamp(30 + payload.rally * 2, 30, 56), 1.5)
	end

	-- With several fliers in the air, outline the ones kicking YOU until their kick resolves.
	if payload.targetId == localPlayer.UserId and character then
		local mark = Instance.new("Highlight")
		mark.Name = "CK_KickingYou"
		mark.FillTransparency = 1
		mark.OutlineColor = PERFECT_COLOR
		mark.OutlineTransparency = 0
		mark.Adornee = character
		mark.Parent = character
		kickMarks[payload.kickId] = mark
		addCleanup(payload.kickId, function()
			kickMarks[payload.kickId] = nil
			mark:Destroy()
		end)
	end

	-- Perfect parry: red aura on the counter-dasher.
	if payload.perfect and attacker.Character then
		pulseHighlight(attacker.Character, PERFECT_COLOR, 0.7)
	end
end

--[[
	The finishing strike: the victim explodes. A neon fireball and white core,
	a ground shock ring, smoke, fire and embers, a flash of light and a camera
	shake for anyone nearby. The body is hidden for EXPLOSION_HIDE_TIME (the
	server moves the player to the lobby in the meantime). Purely local.
]]
local function explode(victim: Player?, position: Vector3, color: Color3)
	local fireball = effectPart(position)
	fireball.Shape = Enum.PartType.Ball
	fireball.Material = Enum.Material.Neon
	fireball.Color = color
	fireball.Size = Vector3.one * 2
	fireball.Transparency = 0.05
	TweenService:Create(fireball, TweenInfo.new(0.5, Enum.EasingStyle.Quart, Enum.EasingDirection.Out), {
		Size = Vector3.one * 20,
		Transparency = 1,
	}):Play()
	Debris:AddItem(fireball, 0.6)

	local core = effectPart(position)
	core.Shape = Enum.PartType.Ball
	core.Material = Enum.Material.Neon
	core.Color = Color3.new(1, 1, 1)
	core.Size = Vector3.one * 3
	TweenService:Create(core, TweenInfo.new(0.25, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
		Size = Vector3.one * 10,
		Transparency = 1,
	}):Play()
	Debris:AddItem(core, 0.3)

	shockRing(position - Vector3.new(0, 2.5, 0), Vector3.yAxis, color, 4, 40, 0.6)

	local emitterPart = effectPart(position)
	local smoke = Instance.new("ParticleEmitter")
	smoke.Texture = SMOKE_TEXTURE
	smoke.Color = ColorSequence.new(Color3.fromRGB(90, 85, 85), Color3.fromRGB(40, 38, 40))
	smoke.Lifetime = NumberRange.new(1, 1.7)
	smoke.Speed = NumberRange.new(6, 16)
	smoke.SpreadAngle = Vector2.new(180, 180)
	smoke.Drag = 3
	smoke.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 4),
		NumberSequenceKeypoint.new(1, 11),
	})
	smoke.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.25),
		NumberSequenceKeypoint.new(1, 1),
	})
	smoke.Rate = 0
	smoke.Parent = emitterPart
	smoke:Emit(26)

	local fire = Instance.new("ParticleEmitter")
	fire.Texture = FIRE_TEXTURE
	fire.Color = ColorSequence.new(Color3.fromRGB(255, 230, 160), color)
	fire.LightEmission = 1
	fire.Lifetime = NumberRange.new(0.35, 0.6)
	fire.Speed = NumberRange.new(10, 24)
	fire.SpreadAngle = Vector2.new(180, 180)
	fire.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 5),
		NumberSequenceKeypoint.new(1, 1),
	})
	fire.Rate = 0
	fire.Parent = emitterPart
	fire:Emit(34)

	local light = Instance.new("PointLight")
	light.Color = color
	light.Range = 40
	light.Brightness = 10
	light.Parent = emitterPart
	TweenService:Create(light, TweenInfo.new(0.7), { Brightness = 0 }):Play()
	Debris:AddItem(emitterPart, 2.2)

	burst(position, color, 90, 60)
	shakeCamera(position, 0.09, 0.45)

	local character = victim and victim.Character
	if character then
		setBodyTransparency(character, 1)
		task.delay(EXPLOSION_HIDE_TIME, function()
			if victim and victim.Character == character then
				setBodyTransparency(character, 0)
			end
		end)
	end
end

function CombatFX.onKickResolved(payload: Types.KickResolvedPayload)
	CombatFX.cleanupKick(payload.kickId)
	if payload.outcome == "Parried" then
		-- The clash: a shockwave off the block and sparks where the feet met it.
		local color = if payload.perfect then PERFECT_COLOR else COLORS.Block
		shockRing(payload.position, payload.direction, color, 3, 16, 0.25)
		burst(payload.position, if payload.perfect then PERFECT_COLOR else KICK_COLOR, 40, 30)
	elseif payload.outcome == "Clashed" then
		-- Two kicks met head-on: a bigger white-hot burst, no strike for either.
		shockRing(payload.position, payload.direction, Color3.fromRGB(255, 240, 200), 4, 22, 0.3)
		burst(payload.position, Color3.fromRGB(255, 240, 200), 55, 40)
	elseif payload.outcome == "Hit" then
		local victim = Players:GetPlayerByUserId(payload.targetId)
		local color = if payload.ultimate then COLORS.UltA else RiderKick.heatColor(payload.rally, payload.perfect)
		if payload.exploded then
			explode(victim, payload.position, color)
		else
			burst(payload.position, Color3.new(1, 1, 1), 70, 45)
			shockRing(payload.position, payload.direction, color, 2, 12, 0.22)
			local label = if payload.ultimate
				then `ULTIMATE · STRIKE {payload.strikes}`
				else `STRIKE {payload.strikes}`
			popup(payload.position + Vector3.new(0, 2, 0), label, COLORS.Danger, 34, 4)
		end
		-- If YOU were hit, flash the attacker red: "that's who did it".
		local attacker = Players:GetPlayerByUserId(payload.attackerId)
		if payload.targetId == localPlayer.UserId and attacker and attacker.Character then
			pulseHighlight(attacker.Character, PERFECT_COLOR, 1.5)
		end
	end
end

--[[
	ULTIMATE telegraph.
	  Leap: a gold aura on the performer (and the flip, via RiderKick).
	  Dive: the impact zone on the ground, an outer ring plus an inner disc that
	        fills it exactly as the dive lands. It sits on the floor below the
	        locked point, so everyone sees where NOT to be.
	  Miss / Cancelled / landed (KickResolved with the same id): cleaned up.
]]
function CombatFX.onUltimate(payload: Types.UltimatePayload)
	local performer = Players:GetPlayerByUserId(payload.userId)
	if payload.stage == "Leap" then
		local character = performer and performer.Character
		if performer and payload.diveAt then
			RiderKick.startLeap(performer, payload.diveAt) -- (a re-sync only moves the dive time)
		end
		if character and not cleanups[payload.id] then
			pulseHighlight(character, COLORS.UltA, Config.Ultimate.LeapTime + Config.Ultimate.DiveTime)
			local glow = RiderKick.glow(character, COLORS.UltB, 1)
			if glow then
				addCleanup(payload.id, glow.destroy)
			end
		end
		return
	end

	if performer then
		RiderKick.endLeap(performer)
	end
	if payload.stage ~= "Dive" then
		if payload.stage == "Miss" and payload.impactPoint then
			burst(payload.impactPoint, Color3.fromRGB(200, 190, 170), 30, 20) -- a dusty thud
		end
		CombatFX.cleanupKick(payload.id)
		return
	end

	local impact = payload.impactPoint
	local impactAt = payload.impactAt
	if impact == nil or impactAt == nil then
		return
	end
	local previous = ultimateZones[payload.id]
	if previous then
		previous() -- a re-sync (the performer was briefly held): redraw with the new timing
	else
		addCleanup(payload.id, function()
			local remove = ultimateZones[payload.id]
			ultimateZones[payload.id] = nil
			if remove then
				remove()
			end
		end)
	end
	local radius = payload.radius or Config.Ultimate.Radius
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	local exclude: { Instance } = {}
	for _, player in Players:GetPlayers() do
		if player.Character then
			table.insert(exclude, player.Character)
		end
	end
	params.FilterDescendantsInstances = exclude
	local floor = Workspace:Raycast(impact + Vector3.new(0, 2, 0), Vector3.new(0, -40, 0), params)
	local center = if floor then floor.Position + Vector3.new(0, 0.06, 0) else impact - Vector3.new(0, 3, 0)
	local flat = CFrame.new(center) * CFrame.Angles(0, 0, math.pi / 2) -- cylinder axis (X) pointing up

	local zone = effectPart(center)
	zone.Shape = Enum.PartType.Cylinder
	zone.Material = Enum.Material.Neon
	zone.Color = COLORS.Danger
	zone.Transparency = 0.55
	zone.Size = Vector3.new(0.12, radius * 2, radius * 2)
	zone.CFrame = flat

	local fill = effectPart(center)
	fill.Shape = Enum.PartType.Cylinder
	fill.Material = Enum.Material.Neon
	fill.Color = COLORS.UltA
	fill.Transparency = 0.25
	fill.Size = Vector3.new(0.14, 0.5, 0.5)
	fill.CFrame = flat
	local remaining = math.max(impactAt - Workspace:GetServerTimeNow(), 0.05)
	TweenService:Create(fill, TweenInfo.new(remaining, Enum.EasingStyle.Linear), {
		Size = Vector3.new(0.14, radius * 2, radius * 2),
	}):Play()

	ultimateZones[payload.id] = function()
		zone:Destroy()
		fill:Destroy()
	end
end

function CombatFX.onEffect(payload: Types.EffectPayload)
	if payload.kind == "Invis" then
		invisDash(payload)
	elseif payload.kind == "ShadowClone" then
		shadowClone(payload)
	elseif payload.kind == "LagSwitch" then
		lagSwitch(payload)
	end
end

function CombatFX.init(playerGui: PlayerGui)
	local gui = Instance.new("ScreenGui")
	gui.Name = "ClashKickToasts"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.DisplayOrder = 20
	gui.Parent = playerGui

	local label = UiTheme.text(gui, UiTheme.FontHeavy, COLORS.Text)
	label.Name = "Toast"
	label.AnchorPoint = Vector2.new(0.5, 0.5)
	label.Position = UDim2.fromScale(0.5, 0.32)
	label.Size = UDim2.fromScale(0.42, 0.07)
	label.TextTransparency = 1
	local textLimit = Instance.new("UITextSizeConstraint")
	textLimit.MaxTextSize = 44
	textLimit.Parent = label
	local stroke = UiTheme.stroke(label, 1.5, Color3.new(0, 0, 0), 0.4)
	stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Contextual
	toastLabel = label
	RiderKick.init()

	Players.PlayerAdded:Connect(watchPlayer)
	for _, player in Players:GetPlayers() do
		watchPlayer(player)
	end
	Players.PlayerRemoving:Connect(function(player: Player)
		stunGlows[player] = nil
	end)
end

return CombatFX
