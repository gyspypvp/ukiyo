--!strict
--[[
	CombatController (LocalScript, StarterPlayer/StarterPlayerScripts/Client)
	=========================================================================
	The player's hands and eyes in a fight. Anyone can kick and Block at any
	moment; several kicks may be coming at you at once.

	  1. TARGETING: every frame, the camera dot-product lock-on picks the player
	     closest to the crosshair and puts the red dot on them
	     (Shared/Targeting.luau has the math).
	  2. INPUT: five actions, each on a round on-screen button that shows its
	     cooldown (built from UiTheme):
	         KICK      Left click / R2   homing flying kick at the dot
	         BLOCK     F / L1            parry the kick about to land
	         DASH      Q / B             quick dodge burst (movement direction)
	         SKILL     E / Y             your Leg Style, mid-kick
	         ULTIMATE  R / X             charged, unblockable leap-and-dive kick
	     A Kick pressed while stunned or still cooling down is buffered briefly
	     and fires the moment it's allowed. Inside a DUEL (right after a parry
	     you were part of) Block can be mashed freely, as the server allows.
	  3. NETWORK: fires intent remotes. The client never decides an outcome; it
	     reports WHAT it pressed and WHEN (synced server clock) and the server
	     judges.
	  4. VISUALS: the red "incoming" warning (edge glow + closing ring, plus an
	     "x2" count when several kicks are coming) for the kick closest to
	     landing, driven by the server's impact ETA on the shared clock rather
	     than by the attacker's replicated position, so the ring closes on the
	     same moment the server will judge. An ULTIMATE aimed at you prompts
	     "DASH!" and lights up the DASH button instead: it can't be blocked.

	Anti-exploit note: everything here is advisory. Editing this script (or
	firing the remotes by hand) cannot kick during a cooldown, parry outside
	the server's window, dash further, charge the meter, or move a
	server-owned body.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local AbilityData = require(Shared:WaitForChild("AbilityData"))
local Config = require(Shared:WaitForChild("Config"))
local Net = require(Shared:WaitForChild("Net"))
local Targeting = require(Shared:WaitForChild("Targeting"))
local Types = require(Shared:WaitForChild("Types"))
local CombatFX = require(script.Parent:WaitForChild("CombatFX"))
local HitFeedback = require(script.Parent:WaitForChild("HitFeedback"))
local UiTheme = require(script.Parent:WaitForChild("UiTheme"))

local localPlayer = Players.LocalPlayer
local playerGui = localPlayer:WaitForChild("PlayerGui") :: PlayerGui
local remotes = Net.client()
local ATTR = Net.Attributes
local STATE = Net.StateAttributes
local COLORS = UiTheme.Colors
local roundState = Net.stateFolder()

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
local LAUNCH_BUFFER = 0.75 -- a Kick pressed this long before it's allowed still fires
local DASH_BUFFER = 0.4 -- a DASH pressed this long before it's allowed still fires
local PARRY_MIN_INTERVAL = 1 / 15 -- mash cap, safely under the server's Parry rate limit
local DOT_COLOR = Color3.fromRGB(255, 45, 45)

type IncomingKick = {
	kickId: number,
	attackerId: number,
	eta: number, -- server time of predicted impact, -1 while frozen (Lag Switch)
	etaSentAt: number, -- newest KickUpdated applied (unreliable packets can arrive out of order)
}

type ActionButton = {
	button: TextButton,
	ring: UIStroke,
	shade: UIGradient, -- cooldown shade: covers the remaining fraction, from the top
	caption: TextLabel,
	timer: TextLabel, -- cooldown seconds, ULTIMATE %, "MASH", ...
	scale: UIScale,
	hint: TextLabel?, -- the key hint under the button (none on touch-only devices)
	keyboardKey: string,
	gamepadKey: string,
}

type Hud = {
	kick: ActionButton,
	block: ActionButton,
	dash: ActionButton,
	skill: ActionButton,
	ultimate: ActionButton,
	ultFill: UIGradient,
	ringCount: TextLabel,
	warning: Frame,
	warningStroke: UIStroke,
	ring: Frame,
	ringStroke: UIStroke,
	lockDot: BillboardGui,
	lockDotFill: Frame,
}

-- State --------------------------------------------------------------------------------

local lockTarget: Player? = nil
local incomingKicks: { [number]: IncomingKick } = {} -- every kick aimed at us, by kick id
local ultimateThreat: Types.UltimatePayload? = nil -- an ULTIMATE aimed at us (Leap or Dive)
local parryLockUntil = 0 -- mirror of the server's whiff cooldown (server time)
local parryLockOptimistic = false -- parryLockUntil is our own guess, not yet confirmed by ParryFeedback
local duelUntil = 0 -- mirror of the server's duel window: misses cost nothing until then
local lastParrySent = 0 -- os.clock() of the last Block sent (mash cap)
local pendingLaunchUntil = 0 -- a buffered Kick fires if it becomes allowed before this (local clock)
local pendingDashUntil = 0 -- same for DASH (e.g. pressed while still tumbling from a hit)
local requestLaunch: () -> () -- defined with the other input handlers below
local requestDash: () -> ()

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

local function isTrue(name: string): boolean
	return localPlayer:GetAttribute(name) == true
end

local function numberAttr(name: string): number
	local value = localPlayer:GetAttribute(name)
	return if typeof(value) == "number" then value else 0
end

-- The kick aimed at us that will land first (frozen Lag Switch kicks count as last), and how many there are.
local function soonestIncoming(): (IncomingKick?, number)
	local soonest: IncomingKick? = nil
	local soonestEta = math.huge
	local count = 0
	for _, kick in incomingKicks do
		count += 1
		local eta = if kick.eta < 0 then math.huge else kick.eta
		if soonest == nil or eta < soonestEta then
			soonest, soonestEta = kick, eta
		end
	end
	return soonest, count
end

-- In the arena, the round is live, and not busy being a missile, stunned or mid-ULTIMATE.
local function free(): boolean
	local phase = roundState:GetAttribute(STATE.Phase)
	return isTrue(ATTR.InArena)
		and (phase == "Active" or phase == "FinalDuel") -- nothing during the spawn countdown
		and not isTrue(ATTR.Flying)
		and not isTrue(ATTR.Stunned)
		and not isTrue(ATTR.Ultimate)
end

-- Can we start a kick right now? (The server re-checks all of this.)
local function canKickNow(t: number): boolean
	return free() and t >= numberAttr(ATTR.KickReadyAt)
end

local function canDashNow(t: number): boolean
	return isTrue(ATTR.InArena)
		and not isTrue(ATTR.Flying)
		and not isTrue(ATTR.Stunned)
		and not isTrue(ATTR.Ultimate)
		and t >= numberAttr(ATTR.DashReadyAt)
end

-- The equipped Leg Style and how many activations it has left this round.
local function skillUsesLeft(): (AbilityData.LegStyle?, number)
	local styleId = localPlayer:GetAttribute(ATTR.LegStyle)
	local style = AbilityData.get(if typeof(styleId) == "string" then styleId else AbilityData.DefaultStyleId)
	if style == nil then
		return nil, 0
	end
	return style, math.max(style.usesPerRound - numberAttr(ATTR.SkillUsed), 0)
end

local function isAliveCharacter(player: Player): boolean
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	return humanoid ~= nil and humanoid.Health > 0
end

-- HUD (built in code from UiTheme, so the place file needs no UI assets) ---------------------

--[[
	A round action button: glass disc, accent ring, the action's name inside,
	a cooldown shade that retreats as it comes back, and (on keyboard / gamepad)
	a small key hint under it.
]]
local function actionButton(
	parent: Instance,
	name: string,
	accent: Color3,
	diameter: number,
	keyboardKey: string,
	gamepadKey: string,
	touchOnly: boolean
): ActionButton
	local button = Instance.new("TextButton")
	button.Name = name
	button.Size = UDim2.fromOffset(diameter, diameter)
	button.BackgroundColor3 = COLORS.Panel
	button.BackgroundTransparency = UiTheme.PanelTransparency
	button.AutoButtonColor = false
	button.Text = ""
	button.Parent = parent
	UiTheme.corner(button, UDim.new(0.5, 0))
	local ring = UiTheme.stroke(button, 2.5, accent)
	local scale = Instance.new("UIScale")
	scale.Parent = button

	local shadeFrame = Instance.new("Frame")
	shadeFrame.Name = "Cooldown"
	shadeFrame.Size = UDim2.fromScale(1, 1)
	shadeFrame.BackgroundColor3 = Color3.new(0, 0, 0)
	shadeFrame.BackgroundTransparency = 0.4
	shadeFrame.ZIndex = 3
	shadeFrame.Parent = button
	UiTheme.corner(shadeFrame, UDim.new(0.5, 0))
	local shade = Instance.new("UIGradient")
	shade.Rotation = 90 -- starts at the top: the shade covers the top part and retreats upward
	shade.Parent = shadeFrame
	UiTheme.setFill(shade, 0)

	local caption = UiTheme.text(button, UiTheme.FontHeavy, COLORS.Text)
	caption.Name = "Caption"
	caption.AnchorPoint = Vector2.new(0.5, 0.5)
	caption.Position = UDim2.fromScale(0.5, 0.46)
	caption.Size = UDim2.fromScale(0.74, 0.22)
	caption.Text = name
	caption.ZIndex = 4

	local timer = UiTheme.text(button, UiTheme.Font, COLORS.SubText)
	timer.Name = "Timer"
	timer.AnchorPoint = Vector2.new(0.5, 0)
	timer.Position = UDim2.fromScale(0.5, 0.6)
	timer.Size = UDim2.fromScale(0.6, 0.16)
	timer.ZIndex = 4

	local hintText: TextLabel? = nil
	if not touchOnly then
		local hint = UiTheme.panel(button, "Key", UDim.new(0, 6))
		hint.AnchorPoint = Vector2.new(0.5, 0)
		hint.Position = UDim2.new(0.5, 0, 1, 5)
		hint.Size = UDim2.fromOffset(36, 17)
		local text = UiTheme.text(hint, UiTheme.Font, COLORS.SubText, 11)
		text.Size = UDim2.fromScale(1, 1)
		text.Text = keyboardKey
		hintText = text
	end

	return {
		button = button,
		ring = ring,
		shade = shade,
		caption = caption,
		timer = timer,
		scale = scale,
		hint = hintText,
		keyboardKey = keyboardKey,
		gamepadKey = gamepadKey,
	}
end

local function buildHud(): Hud
	local gui = Instance.new("ScreenGui")
	gui.Name = "ClashKickHud"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.Parent = playerGui

	local touchOnly = UserInputService.TouchEnabled and not UserInputService.KeyboardEnabled
	local big, small = if touchOnly then 84 else 76, if touchOnly then 60 else 62
	local block = actionButton(gui, "BLOCK", COLORS.Block, big, "F", "L1", touchOnly)
	local kick = actionButton(gui, "KICK", COLORS.Kick, big, "LMB", "R2", touchOnly)
	local dash = actionButton(gui, "DASH", COLORS.Dash, small, "Q", "B", touchOnly)
	local skill = actionButton(gui, "SKILL", COLORS.Skill, small, "E", "Y", touchOnly)
	local ultimate = actionButton(gui, "ULT", COLORS.UltA, if touchOnly then 66 else 70, "R", "X", touchOnly)

	-- The ULTIMATE meter: a gradient fill that rises inside its button as it charges.
	local fillFrame = Instance.new("Frame")
	fillFrame.Name = "Charge"
	fillFrame.Size = UDim2.fromScale(1, 1)
	fillFrame.BackgroundColor3 = Color3.new(1, 1, 1)
	fillFrame.BackgroundTransparency = 0.35
	fillFrame.ZIndex = 2
	fillFrame.Parent = ultimate.button
	UiTheme.corner(fillFrame, UDim.new(0.5, 0))
	local ultFill = Instance.new("UIGradient")
	ultFill.Rotation = -90 -- starts at the bottom: fills upward
	ultFill.Color = ColorSequence.new(COLORS.UltA, COLORS.UltB)
	ultFill.Parent = fillFrame
	UiTheme.setFill(ultFill, 0)

	if touchOnly then
		-- Phones/tablets: everything under the RIGHT thumb, two rows. The left of the
		-- screen belongs to the movement thumbstick, and the cluster's right edge
		-- (W-184) stays clear of Roblox's Jump button on both phone and tablet layouts.
		for _, action in { block, kick, dash, skill, ultimate } do
			action.button.AnchorPoint = Vector2.new(1, 1)
		end
		kick.button.Position = UDim2.new(1, -184, 1, -28)
		block.button.Position = UDim2.new(1, -282, 1, -28)
		ultimate.button.Position = UDim2.new(1, -184, 1, -128)
		skill.button.Position = UDim2.new(1, -262, 1, -132)
		dash.button.Position = UDim2.new(1, -334, 1, -132)
	else
		-- Keyboard / gamepad: one centred row, bottoms aligned, key hints underneath.
		local row = { block, kick, dash, skill, ultimate }
		local gap = 14
		local total = -gap
		for _, action in row do
			total += action.button.Size.X.Offset + gap
		end
		local x = -total / 2
		for _, action in row do
			local width = action.button.Size.X.Offset
			action.button.AnchorPoint = Vector2.new(0.5, 1)
			action.button.Position = UDim2.new(0.5, x + width / 2, 1, -36)
			x += width + gap
		end
	end

	-- Red warning: screen-edge glow + a ring that closes toward the impact moment.
	local warning = Instance.new("Frame")
	warning.Name = "IncomingWarning"
	warning.Size = UDim2.fromScale(1, 1)
	warning.BackgroundTransparency = 1
	warning.Visible = false
	warning.Parent = gui
	local warningStroke = UiTheme.stroke(warning, 14, COLORS.Danger)

	local ring = Instance.new("Frame")
	ring.Name = "Ring"
	ring.AnchorPoint = Vector2.new(0.5, 0.5)
	ring.Position = UDim2.fromScale(0.5, 0.5)
	ring.Size = UDim2.fromOffset(240, 240)
	ring.BackgroundTransparency = 1
	ring.Parent = warning
	UiTheme.corner(ring, UDim.new(0.5, 0))
	local ringStroke = UiTheme.stroke(ring, 3, COLORS.Danger)

	-- "x2", "x3": how many kicks are coming at you right now.
	local ringCount = UiTheme.text(ring, UiTheme.FontHeavy, COLORS.Danger, 22)
	ringCount.AnchorPoint = Vector2.new(0, 0.5)
	ringCount.Position = UDim2.new(1, 10, 0.5, 0) -- beside the ring, never down on the buttons
	ringCount.Size = UDim2.fromOffset(60, 30)
	ringCount.TextXAlignment = Enum.TextXAlignment.Left

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
	UiTheme.corner(lockDotFill, UDim.new(0.5, 0))
	UiTheme.stroke(lockDotFill, 2, Color3.new(1, 1, 1))

	return {
		kick = kick,
		block = block,
		dash = dash,
		skill = skill,
		ultimate = ultimate,
		ultFill = ultFill,
		ringCount = ringCount,
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

-- Key hints follow whatever the player is using right now: keyboard keys, gamepad
-- buttons, or nothing for touch.
local function refreshKeyHints()
	local lastInput = UserInputService:GetLastInputType()
	local gamepad = string.match(lastInput.Name, "^Gamepad") ~= nil
	local touch = lastInput == Enum.UserInputType.Touch
	for _, action in { hud.block, hud.kick, hud.dash, hud.skill, hud.ultimate } do
		local hint = action.hint
		local panel = hint and hint.Parent
		if hint and panel and panel:IsA("GuiObject") then
			hint.Text = if gamepad then action.gamepadKey else action.keyboardKey
			panel.Visible = not touch
		end
	end
end
UserInputService.LastInputTypeChanged:Connect(refreshKeyHints)
refreshKeyHints()

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
	if myRoot == nil or not isTrue(ATTR.InArena) then
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
	-- Big, solid dot when you can kick right now; small and faded otherwise
	-- (cooling down, stunned, mid-flight, or the round hasn't started).
	local ready = canKickNow(serverNow())
	hud.lockDot.Size = if ready then UDim2.fromOffset(22, 22) else UDim2.fromOffset(14, 14)
	hud.lockDotFill.BackgroundTransparency = if ready then 0 else 0.45
end

-- 4. VISUALS: the incoming warning and the buttons -----------------------------------------

local function updateWarning(t: number)
	local kick, count = soonestIncoming()
	if kick == nil then
		hud.warning.Visible = false
		return
	end
	hud.warning.Visible = true
	hud.ringCount.Text = if count > 1 then `x{count}` else ""

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
	hud.warningStroke.Transparency = 0.88 - 0.72 * urgency
end

-- Shade + dimming + timer text for a button on a cooldown that ends at `readyAt`.
local function showCooldown(action: ActionButton, t: number, readyAt: number, duration: number, usable: boolean)
	local remaining = math.max(readyAt - t, 0)
	UiTheme.setFill(action.shade, if duration > 0 then remaining / duration else 0)
	action.timer.Text = if remaining > 0.05 then string.format("%.1f", remaining) else ""
	action.button.BackgroundTransparency = if usable then UiTheme.PanelTransparency else 0.55
	action.ring.Transparency = if usable then 0 else 0.55
end

local function updateButtons(t: number)
	local inArena = isTrue(ATTR.InArena)
	-- Combat buttons only exist in the arena; the lobby is for shopping and spectating.
	for _, action in { hud.kick, hud.block, hud.dash, hud.skill, hud.ultimate } do
		action.button.Visible = inArena
	end
	if not inArena then
		return
	end

	showCooldown(hud.kick, t, numberAttr(ATTR.KickReadyAt), Config.Kick.Cooldown, canKickNow(t))

	-- BLOCK: the whiff lockout, or "MASH" while a duel makes misses free. (A lockout
	-- from before the duel still stands on the server, so it still shows here.)
	showCooldown(hud.block, t, parryLockUntil, Config.Parry.WhiffCooldown, true)
	if t < duelUntil and t >= parryLockUntil then
		hud.block.timer.Text = "MASH"
		hud.block.ring.Thickness = 2.5 + 2 * (0.5 + 0.5 * math.sin(t * 30))
	else
		hud.block.ring.Thickness = 2.5
	end

	-- DASH: pulses when an ULTIMATE's marker is on you (Block can't stop that one).
	showCooldown(hud.dash, t, numberAttr(ATTR.DashReadyAt), Config.Dash.Cooldown, canDashNow(t))
	local threat = ultimateThreat
	local mustDodge = threat ~= nil and threat.stage == "Dive"
	hud.dash.scale.Scale = if mustDodge then 1.08 + 0.06 * math.sin(t * 24) else 1
	hud.dash.ring.Thickness = if mustDodge then 4.5 else 2.5

	-- SKILL: your Leg Style, mid-kick, a few times per round (server-checked):
	-- "x2" uses left, or NONE without a style (equip one in the lobby).
	local style, usesLeft = skillUsesLeft()
	showCooldown(hud.skill, t, 0, 0, isTrue(ATTR.Flying) and usesLeft > 0)
	hud.skill.timer.Text = if style == nil or style.usesPerRound <= 0 then "NONE" else `x{usesLeft}`

	-- ULTIMATE: the meter fills the button; full = pulsing ring.
	local charge = numberAttr(ATTR.UltCharge)
	UiTheme.setFill(hud.ultFill, charge)
	local ready = charge >= 1
	hud.ultimate.timer.Text = if isTrue(ATTR.Ultimate)
		then "GO"
		elseif ready then "READY"
		else `{math.floor(charge * 100)}%`
	hud.ultimate.timer.TextColor3 = if ready then COLORS.Text else COLORS.SubText
	hud.ultimate.ring.Color = if ready then COLORS.UltA:Lerp(COLORS.UltB, 0.5 + 0.5 * math.sin(t * 6)) else COLORS.UltA
	hud.ultimate.ring.Thickness = if ready then 3.5 else 2.5
	hud.ultimate.button.BackgroundTransparency = if ready and free() then UiTheme.PanelTransparency else 0.45
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
	-- Fire a buffered Kick the moment it becomes allowed.
	if pendingLaunchUntil > 0 and canKickNow(t) then
		local stillWanted = os.clock() <= pendingLaunchUntil
		pendingLaunchUntil = 0
		if stillWanted then
			requestLaunch()
		end
	end
	-- ...and a buffered DASH (a dodge pressed while still tumbling must not be lost).
	if pendingDashUntil > 0 and canDashNow(t) then
		local stillWanted = os.clock() <= pendingDashUntil
		pendingDashUntil = 0
		if stillWanted then
			requestDash()
		end
	end
end)

-- 2 + 3. INPUT -> REMOTES -------------------------------------------------------------------

-- Kick: anyone, any time (one kick in the air at a time, short cooldown). Sends WHO
-- the dot is on plus the camera, so the server can re-run the same dot-product check.
function requestLaunch()
	if not isTrue(ATTR.InArena) or isTrue(ATTR.Flying) or isTrue(ATTR.Ultimate) then
		return
	end
	if not canKickNow(serverNow()) then
		-- Stunned, tumbling or cooling down: the server would refuse it. Instead of
		-- silently dropping the press, buffer it briefly and kick the moment it's allowed.
		pendingLaunchUntil = os.clock() + LAUNCH_BUFFER
		return
	end
	local camera = Workspace.CurrentCamera
	local target = lockTarget
	if target == nil or camera == nil then
		CombatFX.toast("NO TARGET", COLORS.SubText)
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
	Mid-duel there is no lockout to mirror, so presses go straight through
	(capped at PARRY_MIN_INTERVAL, under the server's rate limit).
]]
local function requestParry()
	if not isTrue(ATTR.InArena) or isTrue(ATTR.Ultimate) then
		return -- (mid-ULTIMATE you're committed: the server ignores Block)
	end
	local clock = os.clock()
	if clock - lastParrySent < PARRY_MIN_INTERVAL then
		return
	end
	local t = serverNow()
	local dueling = t < duelUntil
	if t < parryLockUntil then
		return -- still in whiff cooldown (one from before a duel still counts); the shaded button shows it
	end
	local kick = soonestIncoming() -- the server answers the kick closest to landing too
	if kick == nil and not dueling then
		-- Optimistic mirror of the server's whiff lock; ParryFeedback corrects it either way.
		parryLockUntil = t + Config.Parry.WhiffCooldown
		parryLockOptimistic = true
	end
	lastParrySent = clock
	remotes.RequestParry:FireServer(if kick then kick.kickId else 0, t, if lockTarget then lockTarget.UserId else nil)
	CombatFX.parrySwing(localPlayer)
end

-- Dash where you're moving (thumbstick / WASD), or where the camera faces if standing still.
function requestDash()
	if not canDashNow(serverNow()) then
		if isTrue(ATTR.InArena) and not isTrue(ATTR.Ultimate) then
			pendingDashUntil = os.clock() + DASH_BUFFER -- stunned / tumbling / cooling down: buffer it
		end
		return
	end
	local character = localPlayer.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	local direction = if humanoid then humanoid.MoveDirection else Vector3.zero
	if direction.Magnitude < 0.1 then
		local camera = Workspace.CurrentCamera
		local look = if camera then camera.CFrame.LookVector else Vector3.zero
		direction = Vector3.new(look.X, 0, look.Z)
	end
	remotes.RequestDash:FireServer(direction)
end

-- SKILL: the equipped Leg Style, mid-kick only.
local function requestSkill()
	if not isTrue(ATTR.InArena) then
		return
	end
	local style, usesLeft = skillUsesLeft()
	if style == nil or style.usesPerRound <= 0 then
		CombatFX.toast("NO LEG STYLE: EQUIP ONE IN THE LOBBY", COLORS.SubText)
	elseif usesLeft <= 0 then
		CombatFX.toast("SKILL USED UP THIS ROUND", COLORS.SubText)
	elseif not isTrue(ATTR.Flying) then
		CombatFX.toast("SKILL WORKS MID-KICK", COLORS.SubText)
	else
		remotes.RequestAbility:FireServer()
	end
end

-- ULTIMATE: needs a full meter and a target on the dot within ULTIMATE range.
local function requestUltimate()
	if not free() then
		return
	end
	if numberAttr(ATTR.UltCharge) < 1 then
		CombatFX.toast("ULTIMATE CHARGING", COLORS.SubText)
		return
	end
	local camera = Workspace.CurrentCamera
	local target = lockTarget
	if target == nil or camera == nil then
		CombatFX.toast("NO TARGET", COLORS.SubText)
		return
	end
	local myRoot, targetRoot = rootOf(localPlayer), rootOf(target)
	if myRoot and targetRoot and (targetRoot.Position - myRoot.Position).Magnitude > Config.Ultimate.MaxRange then
		CombatFX.toast("TOO FAR", COLORS.SubText)
		return
	end
	remotes.RequestUltimate:FireServer(target.UserId, camera.CFrame)
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
	elseif keyCode == Enum.KeyCode.Q or keyCode == Enum.KeyCode.ButtonB then
		requestDash()
	elseif keyCode == Enum.KeyCode.E or keyCode == Enum.KeyCode.ButtonY then
		requestSkill()
	elseif keyCode == Enum.KeyCode.R or keyCode == Enum.KeyCode.ButtonX then
		requestUltimate()
	end
end)

-- On-screen buttons fire on PRESS (InputBegan), not release: parry timing is
-- measured in tens of milliseconds and a tap's release can come 100 ms later.
local function onPress(action: ActionButton, handler: () -> ())
	action.button.InputBegan:Connect(function(input: InputObject)
		local inputType = input.UserInputType
		if inputType == Enum.UserInputType.Touch or inputType == Enum.UserInputType.MouseButton1 then
			handler()
		end
	end)
end
onPress(hud.kick, requestLaunch)
onPress(hud.block, requestParry)
onPress(hud.dash, requestDash)
onPress(hud.skill, requestSkill)
onPress(hud.ultimate, requestUltimate)

-- SERVER -> CLIENT ---------------------------------------------------------------------------

remotes.KickStarted.OnClientEvent:Connect(function(payload: Types.KickStartedPayload)
	if payload.targetId == localPlayer.UserId then
		incomingKicks[payload.kickId] = {
			kickId = payload.kickId,
			attackerId = payload.attackerId,
			eta = payload.eta,
			etaSentAt = payload.startedAt,
		}
		if HitFeedback.coversRing() then
			HitFeedback.hideCard() -- on short screens the card would sit over the parry ring
		end
	end
	CombatFX.onKickStarted(payload)
end)

-- Unreliable + possibly out of order: only accept updates newer than what we have.
remotes.KickUpdated.OnClientEvent:Connect(function(kickId: number, eta: number, sentAt: number)
	local kick = incomingKicks[kickId]
	if kick and sentAt >= kick.etaSentAt then
		kick.eta = eta
		kick.etaSentAt = sentAt
	end
end)

remotes.KickResolved.OnClientEvent:Connect(function(payload: Types.KickResolvedPayload)
	incomingKicks[payload.kickId] = nil
	local threat = ultimateThreat
	if threat and threat.id == payload.kickId then
		ultimateThreat = nil
	end

	local mine = payload.attackerId == localPlayer.UserId or payload.targetId == localPlayer.UserId
	if payload.outcome == "Parried" and mine then
		-- We're in a duel now: mirror the server's free-mash window. The server opened it
		-- when it resolved the parry and judges presses by when they ARRIVE, so end ours
		-- a round trip early; a press past the real window just gets a ParryFeedback lock.
		local margin = math.min(localPlayer:GetNetworkPing() * 2, 0.3)
		duelUntil = serverNow() + Config.Duel.SpamWindow - margin
		if parryLockOptimistic then
			-- A Block pressed just as the duel opened guessed a whiff lock, but the server
			-- judged it inside the duel (no lock, and so no ParryFeedback to correct us).
			parryLockUntil = 0
			parryLockOptimistic = false
		end
	end

	-- Head-on: we kicked each other. Each kick resolves separately, so only toast for the one we threw.
	if payload.outcome == "Clashed" and payload.attackerId == localPlayer.UserId then
		CombatFX.toast("CLASH!", Color3.fromRGB(255, 230, 160))
	end

	-- An exploded player's body is hidden by CombatFX for everyone (the server moves
	-- them to the lobby); a strike you survive is a server-side tumble.
	CombatFX.onKickResolved(payload)
	-- Hit card: who hit you, which strike it was, why (held back on short screens while more kicks are coming).
	HitFeedback.onKickResolved(payload, next(incomingKicks) ~= nil)
end)

remotes.Ultimate.OnClientEvent:Connect(function(payload: Types.UltimatePayload)
	CombatFX.onUltimate(payload)
	if payload.targetId ~= localPlayer.UserId then
		return
	end
	if payload.stage == "Leap" then
		ultimateThreat = payload
		CombatFX.toast("ULTIMATE INCOMING", COLORS.UltA)
	elseif payload.stage == "Dive" then
		ultimateThreat = payload
		CombatFX.toast("DASH!", COLORS.Dash) -- unblockable: get out of the marked zone
	else
		local threat = ultimateThreat
		if threat and threat.id == payload.id then
			ultimateThreat = nil
		end
		if payload.stage == "Miss" then
			CombatFX.toast("DODGED!", COLORS.Dash)
		end
	end
end)

remotes.RoundEvent.OnClientEvent:Connect(function(payload: Types.RoundEventPayload)
	HitFeedback.onRoundEvent(payload) -- e.g. "KNOCKED OFF BY ..." cards
end)

local FEEDBACK_TEXT: { [Types.ParryResult]: { text: string, color: Color3 } } = {
	Perfect = { text = "PERFECT!", color = Color3.fromRGB(255, 50, 70) },
	Parry = { text = "PARRY!", color = COLORS.Block },
	Early = { text = "TOO EARLY", color = COLORS.SubText },
	Late = { text = "TOO LATE", color = COLORS.SubText },
	NoThreat = { text = "WHIFF", color = COLORS.SubText },
	TooFar = { text = "TOO FAR", color = COLORS.SubText },
	Cooldown = { text = "", color = COLORS.Text },
}

remotes.ParryFeedback.OnClientEvent:Connect(function(payload: Types.ParryFeedbackPayload)
	-- The server's lockUntil is authoritative; this also undoes a wrong optimistic lock.
	parryLockUntil = payload.lockUntil
	parryLockOptimistic = false
	local feedback = FEEDBACK_TEXT[payload.result]
	-- Mid-duel the counter-dash itself is the feedback; a toast per mashed parry is noise.
	if feedback and feedback.text ~= "" and serverNow() >= duelUntil then
		CombatFX.toast(feedback.text, feedback.color)
	end
end)

remotes.Effect.OnClientEvent:Connect(function(payload: Types.EffectPayload)
	CombatFX.onEffect(payload)
end)

localPlayer:GetAttributeChangedSignal(ATTR.InArena):Connect(function()
	if not isTrue(ATTR.InArena) then
		table.clear(incomingKicks)
		ultimateThreat = nil
		lockTarget = nil
		pendingLaunchUntil = 0
		pendingDashUntil = 0
		duelUntil = 0
		parryLockOptimistic = false
	end
end)
