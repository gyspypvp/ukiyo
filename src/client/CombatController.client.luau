--!strict
--[[
	CombatController (LocalScript, StarterPlayer/StarterPlayerScripts/Client)
	=========================================================================
	The player's hands and eyes in a rally:

	  1. TARGETING: every frame, the camera dot-product lock-on picks the player
	     closest to the crosshair and puts the red dot on them
	     (Shared/Targeting.luau has the math).
	  2. INPUT: Click / R2 = Launch, F / L1 = Block (parry), Q / Y = Ability.
	     Mobile gets on-screen BLOCK / ABILITY buttons (plus KICK while
	     holding the Surge).
	  3. NETWORK: fires intent remotes. The client never decides an outcome; it
	     reports WHAT it pressed and WHEN (synced server clock) and the server
	     judges.
	  4. VISUALS: the red "incoming" warning (edge glow + closing ring), driven
	     by the server's impact ETA on the shared clock rather than by the
	     attacker's replicated position. The ring closes on the same moment the
	     server will judge, even though the attacker's model you SEE is ~100 ms
	     behind.

	Anti-exploit note: everything here is advisory. Editing this script (or
	firing the remotes by hand) cannot launch without the Surge, parry outside
	the server's window, or move a server-owned flying body.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local Net = require(Shared:WaitForChild("Net"))
local Targeting = require(Shared:WaitForChild("Targeting"))
local Types = require(Shared:WaitForChild("Types"))
local CombatFX = require(script.Parent:WaitForChild("CombatFX"))
local HitFeedback = require(script.Parent:WaitForChild("HitFeedback"))

local localPlayer = Players.LocalPlayer
local playerGui = localPlayer:WaitForChild("PlayerGui") :: PlayerGui
local remotes = Net.client()
local ATTR = Net.Attributes

--[[
	LATENCY PROBE. Answer the server's ping instantly, with no other work in
	this handler, so the server measures the network and not our frame time.
	Connected before anything else in this script.
]]
remotes.Ping.OnClientEvent:Connect(function(nonce: number)
	remotes.PingReply:FireServer(nonce)
end)

-- How long before impact the warning ring starts closing (purely visual).
local WARNING_LEAD = 1.0
local DOT_COLOR = Color3.fromRGB(255, 45, 45)
local BUTTON_COLOR = Color3.fromRGB(40, 110, 230)

type IncomingKick = {
	kickId: number,
	attackerId: number,
	eta: number, -- server time of predicted impact, -1 while frozen (Lag Switch)
	etaSentAt: number, -- newest KickUpdated applied (unreliable packets can arrive out of order)
}

type Hud = {
	blockButton: TextButton,
	blockCooldown: Frame,
	abilityButton: TextButton,
	kickButton: TextButton,
	warning: Frame,
	warningStroke: UIStroke,
	ring: Frame,
	ringStroke: UIStroke,
	lockDot: BillboardGui,
	lockDotFill: Frame,
}

-- State --------------------------------------------------------------------------------

local lockTarget: Player? = nil
local incoming: IncomingKick? = nil
local parryLockUntil = 0 -- mirror of the server's whiff cooldown (server time)
local pendingLaunch = false -- Kick pressed while still tumbling/stunned: fire it the moment we recover

local losParams = RaycastParams.new()
losParams.FilterType = Enum.RaycastFilterType.Exclude
losParams.IgnoreWater = true

local function serverNow(): number
	return Workspace:GetServerTimeNow()
end

local function rootOf(player: Player): BasePart?
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if root and root:IsA("BasePart") then
		return root
	end
	return nil
end

local function isAliveCharacter(player: Player): boolean
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	return humanoid ~= nil and humanoid.Health > 0
end

-- HUD (built in code so the place file needs no UI assets) -----------------------------------

local function corner(parent: GuiObject, radius: UDim)
	local uiCorner = Instance.new("UICorner")
	uiCorner.CornerRadius = radius
	uiCorner.Parent = parent
end

local function stroke(parent: GuiObject, thickness: number, color: Color3): UIStroke
	local uiStroke = Instance.new("UIStroke")
	uiStroke.Thickness = thickness
	uiStroke.Color = color
	uiStroke.Parent = parent
	return uiStroke
end

-- Square action button in the style of the reference HUD: title above, glyph inside, key badge.
local function actionButton(parent: Instance, title: string, glyph: string, key: string, xOffset: number): TextButton
	local button = Instance.new("TextButton")
	button.Name = title
	button.AnchorPoint = Vector2.new(0.5, 1)
	button.Position = UDim2.new(0.5, xOffset, 1, -24)
	button.Size = UDim2.fromOffset(92, 92)
	button.BackgroundColor3 = BUTTON_COLOR
	button.AutoButtonColor = true
	button.Font = Enum.Font.GothamBlack
	button.Text = glyph
	button.TextScaled = true
	button.TextColor3 = Color3.new(1, 1, 1)
	button.Parent = parent
	corner(button, UDim.new(0, 12))
	stroke(button, 3, Color3.new(1, 1, 1))

	local label = Instance.new("TextLabel")
	label.AnchorPoint = Vector2.new(0.5, 1)
	label.Position = UDim2.new(0.5, 0, 0, -2)
	label.Size = UDim2.new(1.4, 0, 0, 26)
	label.BackgroundTransparency = 1
	label.Font = Enum.Font.LuckiestGuy
	label.Text = title
	label.TextScaled = true
	label.TextColor3 = Color3.new(1, 1, 1)
	label.Parent = button
	stroke(label, 2, Color3.fromRGB(10, 30, 70))

	local badge = Instance.new("TextLabel")
	badge.AnchorPoint = Vector2.new(1, 0)
	badge.Position = UDim2.new(1, -4, 0, 4)
	badge.Size = UDim2.fromOffset(24, 24)
	badge.BackgroundColor3 = Color3.fromRGB(15, 25, 50)
	badge.Font = Enum.Font.GothamBlack
	badge.Text = key
	badge.TextScaled = true
	badge.TextColor3 = Color3.new(1, 1, 1)
	badge.Visible = key ~= ""
	badge.Parent = button
	corner(badge, UDim.new(0, 6))

	return button
end

local function buildHud(): Hud
	local gui = Instance.new("ScreenGui")
	gui.Name = "ClashKickHud"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.Parent = playerGui

	local blockButton = actionButton(gui, "BLOCK", "🛡", "F", -58)
	local abilityButton = actionButton(gui, "ABILITY", "»", "Q", 58)
	local kickButton = actionButton(gui, "KICK", "⚡", "", 0)
	kickButton.AnchorPoint = Vector2.new(1, 1)
	kickButton.Position = UDim2.new(1, -36, 1, -140)
	kickButton.BackgroundColor3 = Color3.fromRGB(230, 70, 40)
	kickButton.Visible = false

	-- Whiff-cooldown shade that drains from the Block button.
	local blockCooldown = Instance.new("Frame")
	blockCooldown.Name = "Cooldown"
	blockCooldown.AnchorPoint = Vector2.new(0, 1)
	blockCooldown.Position = UDim2.fromScale(0, 1)
	blockCooldown.Size = UDim2.fromScale(1, 0)
	blockCooldown.BackgroundColor3 = Color3.new(0, 0, 0)
	blockCooldown.BackgroundTransparency = 0.45
	blockCooldown.Active = false
	blockCooldown.Parent = blockButton
	corner(blockCooldown, UDim.new(0, 12))

	-- Red warning: screen-edge glow + a ring that closes toward the impact moment.
	local warning = Instance.new("Frame")
	warning.Name = "IncomingWarning"
	warning.Size = UDim2.fromScale(1, 1)
	warning.BackgroundTransparency = 1
	warning.Visible = false
	warning.Active = false
	warning.Parent = gui
	local warningStroke = stroke(warning, 22, DOT_COLOR)

	local ring = Instance.new("Frame")
	ring.Name = "Ring"
	ring.AnchorPoint = Vector2.new(0.5, 0.5)
	ring.Position = UDim2.fromScale(0.5, 0.5)
	ring.Size = UDim2.fromOffset(240, 240)
	ring.BackgroundTransparency = 1
	ring.Parent = warning
	corner(ring, UDim.new(0.5, 0))
	local ringStroke = stroke(ring, 4, DOT_COLOR)

	local bang = Instance.new("TextLabel")
	bang.AnchorPoint = Vector2.new(0.5, 1)
	bang.Position = UDim2.new(0.5, 0, 0, -6)
	bang.Size = UDim2.fromOffset(40, 40)
	bang.BackgroundTransparency = 1
	bang.Font = Enum.Font.LuckiestGuy
	bang.Text = "!"
	bang.TextScaled = true
	bang.TextColor3 = DOT_COLOR
	bang.Parent = ring

	-- The red lock-on dot, drawn ON the target (not at screen centre).
	local lockDot = Instance.new("BillboardGui")
	lockDot.Name = "ClashKickLockOn"
	lockDot.Size = UDim2.fromOffset(20, 20)
	lockDot.AlwaysOnTop = true
	lockDot.LightInfluence = 0
	lockDot.ResetOnSpawn = false
	lockDot.Enabled = false
	lockDot.Parent = playerGui
	local lockDotFill = Instance.new("Frame")
	lockDotFill.AnchorPoint = Vector2.new(0.5, 0.5)
	lockDotFill.Position = UDim2.fromScale(0.5, 0.5)
	lockDotFill.Size = UDim2.fromScale(1, 1)
	lockDotFill.BackgroundColor3 = DOT_COLOR
	lockDotFill.Parent = lockDot
	corner(lockDotFill, UDim.new(0.5, 0))
	stroke(lockDotFill, 2, Color3.new(1, 1, 1))

	return {
		blockButton = blockButton,
		blockCooldown = blockCooldown,
		abilityButton = abilityButton,
		kickButton = kickButton,
		warning = warning,
		warningStroke = warningStroke,
		ring = ring,
		ringStroke = ringStroke,
		lockDot = lockDot,
		lockDotFill = lockDotFill,
	}
end

CombatFX.init(playerGui)
HitFeedback.init(playerGui)
local hud = buildHud()

-- 1. TARGETING ----------------------------------------------------------------------------

local function collectCandidates(): { Targeting.Candidate }
	local candidates = {}
	for _, player in Players:GetPlayers() do
		if player ~= localPlayer and player:GetAttribute(ATTR.InArena) == true and isAliveCharacter(player) then
			local root = rootOf(player)
			if root then
				table.insert(candidates, { player = player, root = root })
			end
		end
	end
	return candidates
end

local function updateTargeting(camera: Camera)
	local myRoot = rootOf(localPlayer)
	if myRoot == nil or localPlayer:GetAttribute(ATTR.InArena) ~= true then
		lockTarget = nil
		hud.lockDot.Enabled = false
		return
	end

	local candidates = collectCandidates()

	-- Line of sight ignores every character (bodies don't block a lock-on, walls do).
	local exclude: { Instance } = {}
	if localPlayer.Character then
		table.insert(exclude, localPlayer.Character)
	end
	for _, candidate in candidates do
		local character = candidate.root.Parent
		if character then
			table.insert(exclude, character)
		end
	end
	losParams.FilterDescendantsInstances = exclude

	local options: Targeting.Options = {
		minDot = Config.Targeting.MinDot,
		maxRange = Config.Kick.MaxRange,
		distanceWeight = Config.Targeting.DistanceWeight,
		stickyBonus = Config.Targeting.StickyBonus,
		current = lockTarget,
		lineOfSight = if Config.Targeting.RequireLineOfSight then losParams else nil,
	}
	local target, targetRoot = Targeting.findBest(camera.CFrame, myRoot.Position, candidates, options)

	lockTarget = target
	if targetRoot then
		hud.lockDot.Adornee = targetRoot
	end
	hud.lockDot.Enabled = targetRoot ~= nil
	-- Bigger, fully opaque dot while you hold the Surge (you're the one aiming).
	local surged = localPlayer:GetAttribute(ATTR.Surged) == true
	hud.lockDot.Size = if surged then UDim2.fromOffset(22, 22) else UDim2.fromOffset(14, 14)
	hud.lockDotFill.BackgroundTransparency = if surged then 0 else 0.35
end

-- 4. VISUALS: the incoming warning ---------------------------------------------------------

local function updateWarning(t: number)
	local kick = incoming
	if kick == nil then
		hud.warning.Visible = false
		return
	end
	hud.warning.Visible = true

	if kick.eta < 0 then
		-- Lag Switch freeze: the ETA is unknowable, so the ring glitches.
		local jitter = math.random()
		hud.ring.Size = UDim2.fromOffset(80 + jitter * 160, 80 + jitter * 160)
		hud.ringStroke.Transparency = jitter * 0.6
		hud.warningStroke.Transparency = 0.4 + jitter * 0.4
		return
	end

	local tti = kick.eta - t
	local urgency = 1 - math.clamp(tti / WARNING_LEAD, 0, 1)
	local size = 240 - 184 * urgency -- 240 px -> 56 px at impact
	hud.ring.Size = UDim2.fromOffset(size, size)
	hud.ringStroke.Transparency = 0.7 * (1 - urgency)
	hud.warningStroke.Transparency = 0.85 - 0.75 * urgency
end

local function updateButtons(t: number)
	local remaining = math.max(parryLockUntil - t, 0)
	hud.blockCooldown.Size = UDim2.fromScale(1, math.clamp(remaining / Config.Parry.WhiffCooldown, 0, 1))

	local flying = localPlayer:GetAttribute(ATTR.Flying) == true
	hud.abilityButton.BackgroundTransparency = if flying then 0 else 0.45

	local surged = localPlayer:GetAttribute(ATTR.Surged) == true
	local stunned = localPlayer:GetAttribute(ATTR.Stunned) == true
	hud.kickButton.Visible = UserInputService.TouchEnabled and surged and not flying
	hud.kickButton.BackgroundTransparency = if stunned then 0.55 else 0 -- greyed out while recovering
end

RunService:BindToRenderStep("ClashKickCombat", Enum.RenderPriority.Camera.Value + 1, function()
	-- Runs right after the camera updates, so the lock-on uses this frame's camera.
	local camera = Workspace.CurrentCamera
	if camera then
		updateTargeting(camera)
	end
	local t = serverNow()
	updateWarning(t)
	updateButtons(t)
end)

-- 2 + 3. INPUT -> REMOTES -------------------------------------------------------------------

-- Launch: only meaningful while holding the Surge. Sends WHO the dot is on plus the
-- camera, so the server can re-run the same dot-product check.
local function requestLaunch()
	if localPlayer:GetAttribute(ATTR.Surged) ~= true or localPlayer:GetAttribute(ATTR.Flying) == true then
		return
	end
	if localPlayer:GetAttribute(ATTR.Stunned) == true then
		-- The server refuses launches while you're tumbling or stunned. Instead of
		-- silently dropping the press, remember it and kick as soon as you recover.
		pendingLaunch = true
		return
	end
	local camera = Workspace.CurrentCamera
	local target = lockTarget
	if target == nil or camera == nil then
		CombatFX.toast("NO TARGET", Color3.fromRGB(200, 200, 200))
		return
	end
	remotes.RequestLaunch:FireServer(target.UserId, camera.CFrame)
end

--[[
	Block / parry. Sends:
	  * kickId of the kick we know is coming (0 = "whatever is coming": the
	    press can beat the KickStarted packet),
	  * the press time on the SYNCED clock (the server clamps it to our
	    measured latency, so lying here buys nothing),
	  * whoever our lock-on dot is on, for the server to use as a redirect
	    if it differs from the attacker.
]]
local function requestParry()
	if localPlayer:GetAttribute(ATTR.InArena) ~= true then
		return
	end
	local t = serverNow()
	if t < parryLockUntil then
		return -- still in whiff cooldown; the shaded button shows it
	end
	local kick = incoming
	if kick == nil then
		-- Optimistic mirror of the server's whiff lock; ParryFeedback corrects it either way.
		parryLockUntil = t + Config.Parry.WhiffCooldown
	end
	remotes.RequestParry:FireServer(if kick then kick.kickId else 0, t, if lockTarget then lockTarget.UserId else nil)
	CombatFX.parrySwing(localPlayer)
end

local function requestAbility()
	if localPlayer:GetAttribute(ATTR.Flying) == true then
		remotes.RequestAbility:FireServer()
	end
end

UserInputService.InputBegan:Connect(function(input: InputObject, gameProcessed: boolean)
	if gameProcessed then
		return -- typing in chat, clicking a GUI button, etc.
	end
	local keyCode = input.KeyCode
	if input.UserInputType == Enum.UserInputType.MouseButton1 or keyCode == Enum.KeyCode.ButtonR2 then
		requestLaunch()
	elseif keyCode == Enum.KeyCode.F or keyCode == Enum.KeyCode.ButtonL1 then
		requestParry()
	elseif keyCode == Enum.KeyCode.Q or keyCode == Enum.KeyCode.ButtonY then
		requestAbility()
	end
end)

-- On-screen buttons fire on PRESS (InputBegan), not release: parry timing is
-- measured in tens of milliseconds and a tap's release can come 100 ms later.
local function onPress(button: GuiButton, action: () -> ())
	button.InputBegan:Connect(function(input: InputObject)
		local inputType = input.UserInputType
		if inputType == Enum.UserInputType.Touch or inputType == Enum.UserInputType.MouseButton1 then
			action()
		end
	end)
end
onPress(hud.blockButton, requestParry)
onPress(hud.abilityButton, requestAbility)
onPress(hud.kickButton, requestLaunch)

-- SERVER -> CLIENT ---------------------------------------------------------------------------

remotes.KickStarted.OnClientEvent:Connect(function(payload: Types.KickStartedPayload)
	if payload.targetId == localPlayer.UserId then
		incoming = {
			kickId = payload.kickId,
			attackerId = payload.attackerId,
			eta = payload.eta,
			etaSentAt = payload.startedAt,
		}
		HitFeedback.hideCard() -- never let the last hit's card cover the parry ring
	end
	CombatFX.onKickStarted(payload)
end)

-- Unreliable + possibly out of order: only accept updates newer than what we have.
remotes.KickUpdated.OnClientEvent:Connect(function(kickId: number, eta: number, sentAt: number)
	local kick = incoming
	if kick and kick.kickId == kickId and sentAt >= kick.etaSentAt then
		kick.eta = eta
		kick.etaSentAt = sentAt
	end
end)

remotes.KickResolved.OnClientEvent:Connect(function(payload: Types.KickResolvedPayload)
	local kick = incoming
	if kick and kick.kickId == payload.kickId then
		incoming = nil
	end

	if payload.outcome == "Hit" and payload.targetId == localPlayer.UserId and payload.lethal then
		-- Cosmetic KO fling. We own our character's physics, so we launch ourselves;
		-- the server has already eliminated us and will teleport us to the lobby.
		-- (A hit you survive is a server-side tumble instead.)
		local root = rootOf(localPlayer)
		local character = localPlayer.Character
		local humanoid = character and character:FindFirstChildOfClass("Humanoid")
		if root and humanoid then
			humanoid:ChangeState(Enum.HumanoidStateType.FallingDown)
			local fling = Config.Kick.HitFlingSpeed
			root.AssemblyLinearVelocity = payload.direction * fling + Vector3.new(0, fling * 0.6, 0)
		end
	end

	CombatFX.onKickResolved(payload)
	HitFeedback.onKickResolved(payload) -- hit card: who hit you, how much, why
end)

remotes.RoundEvent.OnClientEvent:Connect(function(payload: Types.RoundEventPayload)
	HitFeedback.onRoundEvent(payload) -- e.g. "KNOCKED OFF BY ..." cards
end)

local FEEDBACK_TEXT: { [Types.ParryResult]: { text: string, color: Color3 } } = {
	Perfect = { text = "PERFECT!", color = Color3.fromRGB(255, 50, 70) },
	Parry = { text = "PARRY!", color = Color3.fromRGB(110, 200, 255) },
	Early = { text = "TOO EARLY", color = Color3.fromRGB(200, 200, 200) },
	Late = { text = "TOO LATE", color = Color3.fromRGB(200, 200, 200) },
	NoThreat = { text = "WHIFF", color = Color3.fromRGB(170, 170, 170) },
	TooFar = { text = "TOO FAR", color = Color3.fromRGB(200, 200, 200) },
	Cooldown = { text = "", color = Color3.new(1, 1, 1) },
}

remotes.ParryFeedback.OnClientEvent:Connect(function(payload: Types.ParryFeedbackPayload)
	-- The server's lockUntil is authoritative; this also undoes a wrong optimistic lock.
	parryLockUntil = payload.lockUntil
	local feedback = FEEDBACK_TEXT[payload.result]
	if feedback and feedback.text ~= "" then
		CombatFX.toast(feedback.text, feedback.color)
	end
end)

remotes.Effect.OnClientEvent:Connect(function(payload: Types.EffectPayload)
	CombatFX.onEffect(payload)
end)

localPlayer:GetAttributeChangedSignal(ATTR.Surged):Connect(function()
	if localPlayer:GetAttribute(ATTR.Surged) ~= true then
		pendingLaunch = false
		return
	end
	if localPlayer:GetAttribute(ATTR.Flying) == true then
		return
	end
	local recovering = localPlayer:GetAttribute(ATTR.Stunned) == true
	if HitFeedback.isCardVisible() then
		-- Just got hit and infected: say it on the card instead of stacking a toast on top of it.
		HitFeedback.setCardTip(
			if recovering
				then "You caught the Surge! Kick someone as soon as you land."
				else "You caught the Surge! Kick someone now."
		)
		return
	end
	local kick = if UserInputService.TouchEnabled then "TAP KICK" else "CLICK TO KICK"
	CombatFX.toast(
		if recovering then `SURGED! {kick} WHEN YOU LAND` else `SURGED! {kick}!`,
		Color3.fromRGB(255, 150, 40)
	)
end)

-- Recovered from a tumble/stun: fire the kick that was pressed during it.
localPlayer:GetAttributeChangedSignal(ATTR.Stunned):Connect(function()
	if localPlayer:GetAttribute(ATTR.Stunned) ~= true and pendingLaunch then
		pendingLaunch = false
		requestLaunch()
	end
end)

localPlayer:GetAttributeChangedSignal(ATTR.InArena):Connect(function()
	if localPlayer:GetAttribute(ATTR.InArena) ~= true then
		incoming = nil
		lockTarget = nil
		pendingLaunch = false
	end
end)
