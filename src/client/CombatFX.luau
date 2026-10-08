--!strict
--[[
	CombatFX (ModuleScript, StarterPlayerScripts/Client)
	====================================================
	Purely cosmetic, client-side visuals. Nothing here affects gameplay: the
	server decides every outcome, and this module just draws it.

	  * Surge aura: glow + particles on whoever holds the Surge (attribute-driven)
	  * Stun glow, kick trails, parry spark, Perfect-parry red aura
	  * Leg Style effects: Invis-Dash, Shadow Clone decoys, Lag Switch glitch
	  * Toast text ("PERFECT!", "WHIFF", ...)

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

local ATTR = Net.Attributes
local localPlayer = Players.LocalPlayer

local SURGE_COLOR = Color3.fromRGB(255, 120, 40)
local PERFECT_COLOR = Color3.fromRGB(255, 40, 60)
local STUN_COLOR = Color3.fromRGB(255, 230, 90)
local SPARK_TEXTURE = "rbxasset://textures/particles/sparkles_main.dds"

type Aura = {
	highlight: Highlight,
	emitter: ParticleEmitter,
	light: PointLight,
}

local CombatFX = {}

local auras: { [Player]: Aura } = {}
local stunGlows: { [Player]: Highlight } = {}
local hiddenPlayers: { [Player]: boolean } = {}
local cleanups: { [number]: { () -> () } } = {}
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

-- Surge aura ------------------------------------------------------------------------

local function removeAura(player: Player)
	local aura = auras[player]
	if aura then
		aura.highlight:Destroy()
		aura.emitter:Destroy()
		aura.light:Destroy()
		auras[player] = nil
	end
end

local function addAura(player: Player)
	local character = player.Character
	local root = rootOf(player)
	if character == nil or root == nil or auras[player] then
		return
	end

	local highlight = Instance.new("Highlight")
	highlight.FillColor = SURGE_COLOR
	highlight.OutlineColor = Color3.fromRGB(255, 220, 140)
	highlight.FillTransparency = 0.55
	highlight.Adornee = character
	highlight.Parent = character

	local emitter = Instance.new("ParticleEmitter")
	emitter.Texture = SPARK_TEXTURE
	emitter.Color = ColorSequence.new(Color3.fromRGB(255, 200, 80), SURGE_COLOR)
	emitter.LightEmission = 1
	emitter.Rate = 45
	emitter.Lifetime = NumberRange.new(0.3, 0.6)
	emitter.Speed = NumberRange.new(2, 6)
	emitter.SpreadAngle = Vector2.new(180, 180)
	emitter.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.8),
		NumberSequenceKeypoint.new(1, 0),
	})
	emitter.Parent = root

	local light = Instance.new("PointLight")
	light.Color = SURGE_COLOR
	light.Range = 12
	light.Brightness = 2
	light.Parent = root

	auras[player] = { highlight = highlight, emitter = emitter, light = light }
	if hiddenPlayers[player] then
		highlight.Enabled = false
		emitter.Enabled = false
		light.Enabled = false
	end
end

local function refreshPlayer(player: Player)
	if player:GetAttribute(ATTR.Surged) == true then
		addAura(player)
	else
		removeAura(player)
	end

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

local function watchPlayer(player: Player)
	player:GetAttributeChangedSignal(ATTR.Surged):Connect(function()
		refreshPlayer(player)
	end)
	player:GetAttributeChangedSignal(ATTR.Stunned):Connect(function()
		refreshPlayer(player)
	end)
	player.CharacterAdded:Connect(function()
		auras[player] = nil -- old instances died with the old character
		stunGlows[player] = nil
		task.defer(refreshPlayer, player)
	end)
	refreshPlayer(player)
end

-- Leg Style effects --------------------------------------------------------------------

local function setCharacterHidden(player: Player, hidden: boolean)
	local character = player.Character
	if character == nil then
		return
	end
	-- The kicker still sees a ghost of themselves; everyone else sees nothing.
	local modifier = if not hidden then 0 elseif player == localPlayer then 0.6 else 1
	for _, descendant in character:GetDescendants() do
		if descendant:IsA("BasePart") then
			descendant.LocalTransparencyModifier = modifier
		elseif descendant:IsA("Decal") then
			descendant.LocalTransparencyModifier = modifier -- faces
		end
	end
	if hidden then
		hiddenPlayers[player] = true
	else
		hiddenPlayers[player] = nil
	end
	local aura = auras[player]
	if aura then
		aura.highlight.Enabled = not hidden
		aura.emitter.Enabled = not hidden
		aura.light.Enabled = not hidden
	end
end

local function invisDash(payload: Types.EffectPayload)
	local player = Players:GetPlayerByUserId(payload.userId)
	if player == nil then
		return
	end
	setCharacterHidden(player, true)
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

-- Big center-screen text: "PERFECT!", "WHIFF", "NO TARGET"...
function CombatFX.toast(text: string, color: Color3)
	local label = toastLabel
	if label == nil then
		return
	end
	label.Text = text
	label.TextColor3 = color
	label.TextTransparency = 0
	label.Size = UDim2.fromScale(0.5, 0.11)
	TweenService:Create(label, TweenInfo.new(0.12, Enum.EasingStyle.Back), { Size = UDim2.fromScale(0.42, 0.09) })
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

	-- Speed trail, hotter as the rally accelerates.
	local top = Instance.new("Attachment")
	top.Position = Vector3.new(0, 1.5, 0)
	top.Parent = root
	local bottom = Instance.new("Attachment")
	bottom.Position = Vector3.new(0, -1.5, 0)
	bottom.Parent = root
	local heat = math.clamp(payload.rally / 10, 0, 1)
	local trail = Instance.new("Trail")
	trail.Attachment0 = top
	trail.Attachment1 = bottom
	trail.Lifetime = 0.25
	trail.LightEmission = 1
	trail.Color = ColorSequence.new(Color3.fromRGB(255, 200, 80):Lerp(PERFECT_COLOR, heat), SURGE_COLOR)
	trail.Transparency = NumberSequence.new(0.1, 1)
	trail.Parent = root
	addCleanup(payload.kickId, function()
		trail:Destroy()
		top:Destroy()
		bottom:Destroy()
	end)

	-- Perfect parry: red aura on the counter-dasher.
	if payload.perfect and attacker.Character then
		pulseHighlight(attacker.Character, PERFECT_COLOR, 0.7)
	end
end

function CombatFX.onKickResolved(payload: Types.KickResolvedPayload)
	CombatFX.cleanupKick(payload.kickId)
	if payload.outcome == "Parried" then
		-- The clash: sparks where the feet met the block.
		burst(payload.position, if payload.perfect then PERFECT_COLOR else SURGE_COLOR, 40, 30)
	elseif payload.outcome == "Hit" then
		burst(payload.position, Color3.fromRGB(255, 255, 255), 70, 45)
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

	local label = Instance.new("TextLabel")
	label.Name = "Toast"
	label.AnchorPoint = Vector2.new(0.5, 0.5)
	label.Position = UDim2.fromScale(0.5, 0.32)
	label.Size = UDim2.fromScale(0.42, 0.09)
	label.BackgroundTransparency = 1
	label.Font = Enum.Font.LuckiestGuy
	label.TextScaled = true
	label.TextTransparency = 1
	label.Text = ""
	label.Parent = gui
	local stroke = Instance.new("UIStroke")
	stroke.Thickness = 3
	stroke.Color = Color3.fromRGB(40, 10, 0)
	stroke.Parent = label
	toastLabel = label

	Players.PlayerAdded:Connect(watchPlayer)
	for _, player in Players:GetPlayers() do
		watchPlayer(player)
	end
	Players.PlayerRemoving:Connect(function(player: Player)
		removeAura(player)
		stunGlows[player] = nil
		hiddenPlayers[player] = nil
	end)
end

return CombatFX
