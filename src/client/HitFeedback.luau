--!strict
--[[
	HitFeedback (ModuleScript, StarterPlayerScripts/Client)
	=======================================================
	Answers "who hit me, and why did it hurt that much?" the moment it happens.

	  * HUD health bar for the local player (with a trailing "damage ghost"),
	    plus overhead health bars on everyone else in the arena
	  * Hit card: attacker avatar + name, damage taken and HP left, the reason
	    ("6-parry rally at speed 133: faster rallies hit harder") and a parry tip
	  * Red screen flash on every hit
	  * Kill-cam: when you're eliminated, the camera follows whoever did it for
	    a couple of seconds before handing back control

	Layout rules: on normal screens the card sits below the phase label and
	kill feed; on short (landscape phone) screens it moves to the very top so it
	never covers the HP bar, and it never shrinks below 70% so its text stays
	readable. It gets out of the way as soon as another kick targets you (the
	parry ring must never be covered) and drops below the WINS banner at round end.

	Purely presentation: every number shown comes from the server's
	KickResolved / RoundEvent payloads and server-set attributes.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Net = require(Shared:WaitForChild("Net"))
local Types = require(Shared:WaitForChild("Types"))

local ATTR = Net.Attributes
local localPlayer = Players.LocalPlayer

local CARD_TIME = 2.8 -- seconds the hit card stays up
local KILL_CAM_TIME = 2.6 -- seconds the camera follows your eliminator
local HIT_RED = Color3.fromRGB(255, 60, 60)
local CARD_WIDTH, CARD_HEIGHT = 460, 150
local SHORT_SCREEN = 600 -- below this height (landscape phones) the card moves to the top edge
local CARD_TOP, CARD_TOP_SHORT = 124, 6 -- px from the top: below the phase label / at the very top
local ROUND_END_TOP = 0.32 -- fraction of screen height: below the "X WINS!" banner

type Widgets = {
	cardHolder: Frame,
	healthFrame: Frame,
	healthFill: Frame,
	healthGhost: Frame,
	healthLabel: TextLabel,
	card: Frame,
	cardPop: UIScale,
	cardAvatar: ImageLabel,
	cardTitle: TextLabel,
	cardDamage: TextLabel,
	cardReason: TextLabel,
	cardTip: TextLabel,
	flash: Frame,
}

type OverheadBar = {
	gui: BillboardGui,
	fill: Frame,
}

local HitFeedback = {}

local widgets: Widgets? = nil
local overheadBars: { [Player]: OverheadBar } = {}
local guiRoot: PlayerGui? = nil
local cardToken = 0 -- newer cards cancel the fade-out of older ones
local cardTop = CARD_TOP -- updated with the screen size

-- Helpers ---------------------------------------------------------------------------

-- `textSize` given: fixed, wrapped text that stays readable. Omitted: scales to fit its box.
local function label(
	parent: Instance,
	font: Enum.Font,
	color: Color3,
	position: UDim2,
	size: UDim2,
	textSize: number?
): TextLabel
	local text = Instance.new("TextLabel")
	text.BackgroundTransparency = 1
	text.Font = font
	text.TextColor3 = color
	text.TextXAlignment = Enum.TextXAlignment.Left
	text.TextYAlignment = Enum.TextYAlignment.Top
	text.Position = position
	text.Size = size
	text.Text = ""
	if textSize then
		text.TextScaled = false
		text.TextSize = textSize
		text.TextWrapped = true
	else
		text.TextScaled = true
	end
	text.Parent = parent
	return text
end

local function corner(parent: GuiObject, radius: UDim)
	local uiCorner = Instance.new("UICorner")
	uiCorner.CornerRadius = radius
	uiCorner.Parent = parent
end

-- Green -> yellow -> red as health drops.
local function healthColor(fraction: number): Color3
	if fraction > 0.5 then
		return Color3.fromRGB(255, 220, 60):Lerp(Color3.fromRGB(80, 220, 100), (fraction - 0.5) * 2)
	end
	return HIT_RED:Lerp(Color3.fromRGB(255, 220, 60), fraction * 2)
end

-- The Block input for whatever the player is actually using right now.
local function blockHint(): string
	local lastInput = UserInputService:GetLastInputType()
	if lastInput == Enum.UserInputType.Touch then
		return "tap BLOCK"
	elseif string.match(lastInput.Name, "^Gamepad") then
		return "press L1"
	end
	return "press F"
end

local function parryTip(): string
	return `Tip: {blockHint()} right before the kick lands to parry it`
end

local function playerName(userId: number?): string
	local player = if userId then Players:GetPlayerByUserId(userId) else nil
	return if player then player.DisplayName else "someone"
end

-- The "why": what made this kick hurt as much as it did.
local function describeKick(payload: Types.KickResolvedPayload): string
	local speed = math.floor(payload.speed + 0.5)
	if payload.perfect then
		return `A Perfect counter-dash at speed {speed}: perfect parries hit harder`
	elseif payload.rally <= 0 then
		return `Opening kick at speed {speed}`
	end
	return `{payload.rally}-parry rally at speed {speed}: faster rallies hit harder`
end

-- Health bar ---------------------------------------------------------------------------

local function refreshHealth()
	local ui = widgets
	if ui == nil then
		return
	end
	local health = localPlayer:GetAttribute(ATTR.Health)
	local maxHealth = localPlayer:GetAttribute(ATTR.MaxHealth)
	if typeof(health) ~= "number" or typeof(maxHealth) ~= "number" or maxHealth <= 0 then
		ui.healthFrame.Visible = false
		return
	end

	local wasHidden = not ui.healthFrame.Visible
	ui.healthFrame.Visible = true
	local fraction = math.clamp(health / maxHealth, 0, 1)
	ui.healthLabel.Text = `{math.floor(health)} / {math.floor(maxHealth)}`
	ui.healthFill.BackgroundColor3 = healthColor(fraction)

	if wasHidden then
		-- Fresh round: snap to full, no animation.
		ui.healthFill.Size = UDim2.fromScale(fraction, 1)
		ui.healthGhost.Size = UDim2.fromScale(fraction, 1)
		return
	end
	-- The fill drops at once; the white ghost drains after it, so you can SEE the chunk you lost.
	TweenService:Create(ui.healthFill, TweenInfo.new(0.12), { Size = UDim2.fromScale(fraction, 1) }):Play()
	TweenService:Create(
		ui.healthGhost,
		TweenInfo.new(0.5, Enum.EasingStyle.Quad, Enum.EasingDirection.Out, 0, false, 0.45),
		{ Size = UDim2.fromScale(fraction, 1) }
	):Play()
end

--[[
	Overhead bars on other players (yours is the HUD bar).
	Hidden while that player is FLYING: a bar would give away an Invis-Dash
	kicker and mark which Shadow Clone lane is real. Not AlwaysOnTop, so bars
	never reveal anyone through walls.
]]
local function refreshOverhead(player: Player)
	if player == localPlayer then
		return
	end
	local health = player:GetAttribute(ATTR.Health)
	local maxHealth = player:GetAttribute(ATTR.MaxHealth)
	local character = player.Character
	local anchor = if character
		then character:FindFirstChild("Head") or character:FindFirstChild("HumanoidRootPart")
		else nil
	local bar = overheadBars[player]

	if typeof(health) ~= "number" or typeof(maxHealth) ~= "number" or maxHealth <= 0 or anchor == nil then
		if bar then
			bar.gui:Destroy()
			overheadBars[player] = nil
		end
		return
	end

	if bar == nil then
		local gui = Instance.new("BillboardGui")
		gui.Name = `Health_{player.UserId}`
		gui.Size = UDim2.fromOffset(76, 9)
		gui.StudsOffset = Vector3.new(0, 2.2, 0)
		gui.AlwaysOnTop = false
		gui.MaxDistance = 140
		gui.LightInfluence = 0
		gui.ResetOnSpawn = false
		gui.Parent = guiRoot
		local back = Instance.new("Frame")
		back.Size = UDim2.fromScale(1, 1)
		back.BackgroundColor3 = Color3.fromRGB(20, 20, 30)
		back.BackgroundTransparency = 0.25
		back.Parent = gui
		corner(back, UDim.new(0.5, 0))
		local fill = Instance.new("Frame")
		fill.Size = UDim2.fromScale(1, 1)
		fill.Parent = back
		corner(fill, UDim.new(0.5, 0))
		local created: OverheadBar = { gui = gui, fill = fill }
		overheadBars[player] = created
		bar = created
	end

	local current = bar :: OverheadBar
	local fraction = math.clamp(health / maxHealth, 0, 1)
	current.gui.Adornee = anchor
	current.gui.Enabled = player:GetAttribute(ATTR.Flying) ~= true
	current.fill.BackgroundColor3 = healthColor(fraction)
	TweenService:Create(current.fill, TweenInfo.new(0.15), { Size = UDim2.fromScale(fraction, 1) }):Play()
end

local function watchOverhead(player: Player)
	for _, attribute in { ATTR.Health, ATTR.MaxHealth, ATTR.Flying } do
		player:GetAttributeChangedSignal(attribute):Connect(function()
			refreshOverhead(player)
		end)
	end
	player.CharacterAdded:Connect(function()
		task.defer(refreshOverhead, player)
	end)
	refreshOverhead(player)
end

-- Hit card + flash ----------------------------------------------------------------------

local function flash()
	local ui = widgets
	if ui == nil then
		return
	end
	ui.flash.BackgroundTransparency = 0.55
	TweenService:Create(ui.flash, TweenInfo.new(0.45), { BackgroundTransparency = 1 }):Play()
end

local function showCard(attackerId: number?, title: string, damage: string, reason: string, tip: string)
	local ui = widgets
	if ui == nil then
		return
	end
	cardToken += 1
	local token = cardToken

	ui.cardAvatar.Image = if attackerId then `rbxthumb://type=AvatarHeadShot&id={attackerId}&w=150&h=150` else ""
	ui.cardAvatar.Visible = attackerId ~= nil
	ui.cardTitle.Text = title
	ui.cardDamage.Text = damage
	ui.cardDamage.Visible = damage ~= ""
	ui.cardReason.Text = reason
	ui.cardTip.Text = tip

	ui.cardHolder.Position = UDim2.new(0.5, 0, 0, cardTop)
	ui.card.Visible = true
	ui.cardPop.Scale = 1.2
	TweenService:Create(ui.cardPop, TweenInfo.new(0.2, Enum.EasingStyle.Back), { Scale = 1 }):Play()

	task.delay(CARD_TIME, function()
		if token == cardToken then
			ui.card.Visible = false
		end
	end)
end

-- The camera follows whoever eliminated you, then hands control back.
local function killCam(attackerId: number?)
	local attacker = if attackerId then Players:GetPlayerByUserId(attackerId) else nil
	local character = attacker and attacker.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	local camera = Workspace.CurrentCamera
	if humanoid == nil or camera == nil then
		return
	end
	camera.CameraSubject = humanoid
	task.delay(KILL_CAM_TIME, function()
		if camera.CameraSubject == humanoid then
			local ownCharacter = localPlayer.Character
			local own = ownCharacter and ownCharacter:FindFirstChildOfClass("Humanoid")
			if own then
				camera.CameraSubject = own
			end
		end
	end)
end

-- Public API -----------------------------------------------------------------------------

-- Hide the card now (another kick is coming at you, or the round ended).
-- Does the card overlap the parry ring? (Only on short screens, where it sits at the top edge.)
function HitFeedback.coversRing(): boolean
	return cardTop == CARD_TOP_SHORT
end

function HitFeedback.hideCard()
	cardToken += 1
	local ui = widgets
	if ui then
		ui.card.Visible = false
	end
end

HitFeedback.blockHint = blockHint

--[[
	A kick resolved somewhere. Only hits on the local player produce feedback here.
	`othersIncoming`: more kicks are still coming at us. On short screens a card
	would cover the parry ring they need, so a survivable hit only flashes then.
]]
function HitFeedback.onKickResolved(payload: Types.KickResolvedPayload, othersIncoming: boolean?)
	if payload.outcome ~= "Hit" or payload.targetId ~= localPlayer.UserId then
		return
	end
	local attacker = string.upper(playerName(payload.attackerId))
	flash()
	if payload.lethal then
		showCard(
			payload.attackerId,
			`ELIMINATED BY {attacker}`,
			`-{payload.damage} HP`,
			describeKick(payload),
			parryTip()
		)
		killCam(payload.attackerId)
	elseif othersIncoming and HitFeedback.coversRing() then
		return -- the flash and the HUD health bar still show the hit
	else
		showCard(
			payload.attackerId,
			`KICKED BY {attacker}`,
			`-{payload.damage} HP · {payload.health} left`,
			describeKick(payload),
			parryTip()
		)
	end
end

-- Round announcements: keep the deciding hit readable at round end; explain non-kick eliminations.
function HitFeedback.onRoundEvent(payload: Types.RoundEventPayload)
	if payload.kind == "Winner" or payload.kind == "Draw" or payload.kind == "NoContest" then
		-- The final elimination's card arrives ~0.1 s before the banner. Move it below
		-- the "X WINS!" banner instead of hiding it; its normal timeout still applies.
		local ui = widgets
		if ui and ui.card.Visible then
			ui.cardHolder.Position = UDim2.new(0.5, 0, ROUND_END_TOP, 0)
		end
		return
	end
	if payload.kind ~= "Eliminated" or payload.userId ~= localPlayer.UserId or payload.cause ~= "Void" then
		return
	end
	if payload.killerId then
		showCard(
			payload.killerId,
			`KNOCKED OFF BY {string.upper(playerName(payload.killerId))}`,
			"",
			"They knocked you off the edge of the arena",
			"Tip: stay away from the edges when you're low on HP"
		)
		killCam(payload.killerId)
	else
		showCard(nil, "YOU FELL OFF THE ARENA", "", "Falling off the edge counts as a knockout", "")
	end
end

function HitFeedback.init(playerGui: PlayerGui)
	guiRoot = playerGui
	local gui = Instance.new("ScreenGui")
	gui.Name = "ClashKickHitFeedback"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.DisplayOrder = 15
	gui.Parent = playerGui

	-- Red screen flash (under everything else on this layer).
	local flashFrame = Instance.new("Frame")
	flashFrame.Name = "Flash"
	flashFrame.Size = UDim2.fromScale(1, 1)
	flashFrame.BackgroundColor3 = HIT_RED
	flashFrame.BackgroundTransparency = 1
	flashFrame.Active = false
	flashFrame.Parent = gui

	-- Health bar, just above the BLOCK / ABILITY buttons.
	local healthFrame = Instance.new("Frame")
	healthFrame.Name = "Health"
	healthFrame.AnchorPoint = Vector2.new(0.5, 1)
	healthFrame.Position = UDim2.new(0.5, 0, 1, -162)
	healthFrame.Size = UDim2.fromOffset(260, 20)
	healthFrame.BackgroundColor3 = Color3.fromRGB(20, 20, 30)
	healthFrame.BackgroundTransparency = 0.2
	healthFrame.Visible = false
	healthFrame.Parent = gui
	corner(healthFrame, UDim.new(0, 6))
	local healthStroke = Instance.new("UIStroke")
	healthStroke.Thickness = 2
	healthStroke.Color = Color3.new(1, 1, 1)
	healthStroke.Parent = healthFrame

	local healthGhost = Instance.new("Frame")
	healthGhost.Name = "Ghost"
	healthGhost.Size = UDim2.fromScale(1, 1)
	healthGhost.BackgroundColor3 = Color3.new(1, 1, 1)
	healthGhost.BackgroundTransparency = 0.25
	healthGhost.Parent = healthFrame
	corner(healthGhost, UDim.new(0, 6))

	local healthFill = Instance.new("Frame")
	healthFill.Name = "Fill"
	healthFill.Size = UDim2.fromScale(1, 1)
	healthFill.BackgroundColor3 = healthColor(1)
	healthFill.Parent = healthFrame
	corner(healthFill, UDim.new(0, 6))

	local healthLabel =
		label(healthFrame, Enum.Font.GothamBlack, Color3.new(1, 1, 1), UDim2.fromScale(0, 0), UDim2.fromScale(1, 1))
	healthLabel.TextXAlignment = Enum.TextXAlignment.Center
	healthLabel.TextYAlignment = Enum.TextYAlignment.Center
	healthLabel.ZIndex = 3
	local labelStroke = Instance.new("UIStroke")
	labelStroke.Thickness = 1.5
	labelStroke.Parent = healthLabel

	-- Hit card: who, how much, why. A holder carries the screen-size scale so the
	-- card's own pop-in tween can animate its scale independently.
	local holder = Instance.new("Frame")
	holder.Name = "HitCardHolder"
	holder.AnchorPoint = Vector2.new(0.5, 0)
	holder.Position = UDim2.new(0.5, 0, 0, CARD_TOP)
	holder.Size = UDim2.fromOffset(CARD_WIDTH, CARD_HEIGHT)
	holder.BackgroundTransparency = 1
	holder.Parent = gui
	local fitScale = Instance.new("UIScale")
	fitScale.Parent = holder

	local function fitToScreen()
		local camera = Workspace.CurrentCamera
		if camera then
			local viewport = camera.ViewportSize
			local short = viewport.Y < SHORT_SCREEN
			cardTop = if short then CARD_TOP_SHORT else CARD_TOP
			if holder.Position.Y.Scale == 0 then
				holder.Position = UDim2.new(0.5, 0, 0, cardTop)
			end
			-- Shrink to fit short or narrow screens, but never below 70% (16 px text -> 11 px).
			-- At 360 px tall the card spans 6-126 px, well clear of the HP bar (H-182 to H-162).
			fitScale.Scale = math.clamp(math.min(viewport.Y / 450, viewport.X * 0.92 / CARD_WIDTH), 0.7, 1)
		end
	end
	local function watchCamera()
		local camera = Workspace.CurrentCamera
		if camera then
			camera:GetPropertyChangedSignal("ViewportSize"):Connect(fitToScreen)
		end
		fitToScreen()
	end
	Workspace:GetPropertyChangedSignal("CurrentCamera"):Connect(watchCamera)
	watchCamera()

	local card = Instance.new("Frame")
	card.Name = "HitCard"
	card.AnchorPoint = Vector2.new(0.5, 0.5) -- the pop-in scales around the card's centre
	card.Position = UDim2.fromScale(0.5, 0.5)
	card.Size = UDim2.fromScale(1, 1)
	card.BackgroundColor3 = Color3.fromRGB(25, 10, 12)
	card.BackgroundTransparency = 0.15
	card.Visible = false
	card.Parent = holder
	corner(card, UDim.new(0, 12))
	local cardStroke = Instance.new("UIStroke")
	cardStroke.Thickness = 3
	cardStroke.Color = HIT_RED
	cardStroke.Parent = card
	local cardPop = Instance.new("UIScale")
	cardPop.Parent = card

	local cardAvatar = Instance.new("ImageLabel")
	cardAvatar.Name = "Attacker"
	cardAvatar.Position = UDim2.fromOffset(12, 14)
	cardAvatar.Size = UDim2.fromOffset(96, 96)
	cardAvatar.BackgroundColor3 = Color3.fromRGB(60, 20, 25)
	cardAvatar.Parent = card
	corner(cardAvatar, UDim.new(0.5, 0))

	local textLeft, textWidth = 120, CARD_WIDTH - 132
	local cardTitle = label(
		card,
		Enum.Font.LuckiestGuy,
		Color3.new(1, 1, 1),
		UDim2.fromOffset(textLeft, 10),
		UDim2.fromOffset(textWidth, 30),
		26
	)
	cardTitle.TextWrapped = false
	cardTitle.TextTruncate = Enum.TextTruncate.AtEnd -- long display names: "KICKED BY SUPERLONGNA..."
	local cardDamage =
		label(card, Enum.Font.LuckiestGuy, HIT_RED, UDim2.fromOffset(textLeft, 42), UDim2.fromOffset(textWidth, 28), 24)
	cardDamage.TextWrapped = false
	local cardReason = label(
		card,
		Enum.Font.GothamBold,
		Color3.fromRGB(255, 210, 200),
		UDim2.fromOffset(textLeft, 74),
		UDim2.fromOffset(textWidth, 40),
		16
	)
	local cardTip = label(
		card,
		Enum.Font.GothamMedium,
		Color3.fromRGB(200, 200, 210),
		UDim2.fromOffset(12, 118),
		UDim2.fromOffset(CARD_WIDTH - 24, 22),
		15
	)

	widgets = {
		cardHolder = holder,
		healthFrame = healthFrame,
		healthFill = healthFill,
		healthGhost = healthGhost,
		healthLabel = healthLabel,
		card = card,
		cardPop = cardPop,
		cardAvatar = cardAvatar,
		cardTitle = cardTitle,
		cardDamage = cardDamage,
		cardReason = cardReason,
		cardTip = cardTip,
		flash = flashFrame,
	}

	localPlayer:GetAttributeChangedSignal(ATTR.Health):Connect(refreshHealth)
	localPlayer:GetAttributeChangedSignal(ATTR.MaxHealth):Connect(refreshHealth)
	refreshHealth()

	Players.PlayerAdded:Connect(watchOverhead)
	for _, player in Players:GetPlayers() do
		watchOverhead(player)
	end
	Players.PlayerRemoving:Connect(function(player: Player)
		local bar = overheadBars[player]
		if bar then
			bar.gui:Destroy()
			overheadBars[player] = nil
		end
	end)
end

return HitFeedback
