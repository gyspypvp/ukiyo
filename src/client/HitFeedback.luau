--!strict
--[[
	HitFeedback (ModuleScript, StarterPlayerScripts/Client)
	=======================================================
	Answers "who hit me, and how close am I to exploding?" the moment it happens.

	  * Strike pips: one per strike it takes to explode you (Config.Strikes),
	    filling red as kicks land. Yours sit on the HUD; everyone else in the
	    arena has a small row over their head.
	  * Hit card: attacker avatar + name, which strike it was and how many you
	    have left, the context ("6-parry rally at speed 133") and a tip
	  * Red screen flash on every hit
	  * Kill-cam: when you're eliminated, the camera follows whoever did it for
	    a couple of seconds before handing back control

	Layout rules: on normal screens the card sits below the phase label and
	kill feed; on short (landscape phone) screens it moves to the very top so it
	never covers the strike pips, and it never shrinks below 70% so its text
	stays readable. It gets out of the way as soon as another kick targets you
	(the parry ring must never be covered) and drops below the WINS banner at
	round end.

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
local UiTheme = require(script.Parent:WaitForChild("UiTheme"))

local ATTR = Net.Attributes
local COLORS = UiTheme.Colors
local localPlayer = Players.LocalPlayer

local CARD_TIME = 2.8 -- seconds the hit card stays up
local KILL_CAM_TIME = 2.6 -- seconds the camera follows your eliminator
local CARD_WIDTH, CARD_HEIGHT = 460, 150
local SHORT_SCREEN = 600 -- below this height (landscape phones) the card moves to the top edge
local CARD_TOP, CARD_TOP_SHORT = 124, 6 -- px from the top: below the phase label / at the very top
local ROUND_END_TOP = 0.32 -- fraction of screen height: below the "X WINS!" banner
local PIP_SIZE, PIP_GAP = 16, 8

type Pips = {
	frame: Frame, -- holds one circle per strike
	pips: { Frame },
	size: number,
}

type Widgets = {
	cardHolder: Frame,
	strikes: Frame,
	strikePips: Pips,
	strikeLabel: TextLabel,
	card: Frame,
	cardPop: UIScale,
	cardAvatar: ImageLabel,
	cardTitle: TextLabel,
	cardStrikes: TextLabel,
	cardReason: TextLabel,
	cardTip: TextLabel,
	flash: Frame,
}

type Overhead = {
	gui: BillboardGui,
	pips: Pips,
}

local HitFeedback = {}

local widgets: Widgets? = nil
local overheads: { [Player]: Overhead } = {}
local guiRoot: PlayerGui? = nil
local cardToken = 0 -- newer cards cancel the fade-out of older ones
local cardTop = CARD_TOP -- updated with the screen size

-- Helpers ---------------------------------------------------------------------------

-- A left/top-aligned card label: fixed text size, wrapped.
local function cardLabel(
	parent: Instance,
	font: Enum.Font,
	color: Color3,
	position: UDim2,
	size: UDim2,
	textSize: number
)
	local text = UiTheme.text(parent, font, color, textSize)
	text.TextXAlignment = Enum.TextXAlignment.Left
	text.TextYAlignment = Enum.TextYAlignment.Top
	text.TextWrapped = true
	text.Position = position
	text.Size = size
	return text
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

local function dashHint(): string
	local lastInput = UserInputService:GetLastInputType()
	if lastInput == Enum.UserInputType.Touch then
		return "tap DASH"
	elseif string.match(lastInput.Name, "^Gamepad") then
		return "press B"
	end
	return "press Q"
end

local function parryTip(): string
	return `Tip: {blockHint()} right before the kick lands to parry it`
end

local function playerName(userId: number?): string
	local player = if userId then Players:GetPlayerByUserId(userId) else nil
	return if player then player.DisplayName else "someone"
end

local function strikeCounts(player: Player): (number?, number?)
	local taken = player:GetAttribute(ATTR.Strikes)
	local limit = player:GetAttribute(ATTR.StrikesToExplode)
	if typeof(taken) ~= "number" or typeof(limit) ~= "number" or limit <= 0 then
		return nil, nil
	end
	return taken, limit
end

-- Context for the card: what kind of kick it was.
local function describeKick(payload: Types.KickResolvedPayload): string
	local speed = math.floor(payload.speed + 0.5)
	if payload.ultimate then
		return "Their charged ULTIMATE: it can't be blocked and counts as two strikes"
	elseif payload.perfect then
		return `A Perfect counter-dash at speed {speed}`
	elseif payload.rally <= 0 then
		return `Opening kick at speed {speed}`
	end
	return `{payload.rally}-parry rally at speed {speed}`
end

-- Strike pips ----------------------------------------------------------------------------

-- A row of `count` circles inside `parent` (rebuilt only when the count changes).
local function buildPips(parent: Instance, size: number, gap: number): Pips
	local frame = Instance.new("Frame")
	frame.Name = "Pips"
	frame.BackgroundTransparency = 1
	frame.AutomaticSize = Enum.AutomaticSize.XY
	frame.Parent = parent
	local layout = Instance.new("UIListLayout")
	layout.FillDirection = Enum.FillDirection.Horizontal
	layout.HorizontalAlignment = Enum.HorizontalAlignment.Center
	layout.VerticalAlignment = Enum.VerticalAlignment.Center
	layout.Padding = UDim.new(0, gap)
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Parent = frame
	return { frame = frame, pips = {}, size = size }
end

-- Fill the first `taken` of `limit` pips; the newest filled pip pops if `animate`.
local function setPips(pips: Pips, taken: number, limit: number, animate: boolean)
	while #pips.pips < limit do
		local pip = Instance.new("Frame")
		pip.Name = `Pip{#pips.pips + 1}`
		pip.LayoutOrder = #pips.pips + 1
		pip.Size = UDim2.fromOffset(pips.size, pips.size)
		pip.BackgroundColor3 = COLORS.Panel
		pip.BackgroundTransparency = 0.35 -- empty
		pip.BorderSizePixel = 0
		pip.Parent = pips.frame
		UiTheme.corner(pip, UDim.new(0.5, 0))
		UiTheme.stroke(pip, 1.5, COLORS.Text, 0.2)
		local pop = Instance.new("UIScale")
		pop.Parent = pip
		table.insert(pips.pips, pip)
	end
	while #pips.pips > limit do
		local pip = table.remove(pips.pips)
		if pip then
			pip:Destroy()
		end
	end
	for index, pip in pips.pips do
		local filled = index <= taken
		local wasFilled = pip.BackgroundTransparency < 0.5
		pip.BackgroundColor3 = if filled then COLORS.Danger else COLORS.Panel
		pip.BackgroundTransparency = if filled then 0 else 0.35
		local pop = pip:FindFirstChildOfClass("UIScale")
		if animate and filled and not wasFilled and pop then
			pop.Scale = 1.8
			TweenService:Create(pop, TweenInfo.new(0.3, Enum.EasingStyle.Back), { Scale = 1 }):Play()
		end
	end
end

local function refreshStrikes()
	local ui = widgets
	if ui == nil then
		return
	end
	local taken, limit = strikeCounts(localPlayer)
	if taken == nil or limit == nil then
		ui.strikes.Visible = false
		return
	end
	local wasHidden = not ui.strikes.Visible
	ui.strikes.Visible = true
	setPips(ui.strikePips, taken, limit, not wasHidden) -- fresh round: no pop
	local left = math.max(limit - taken, 0)
	ui.strikeLabel.Text = if left == 1 then "LAST KICK" else `{left} KICKS LEFT`
	ui.strikeLabel.TextColor3 = if left == 1 then COLORS.Danger else COLORS.SubText
end

--[[
	Pips over other players (yours are on the HUD).
	Hidden while that player is FLYING: they would give away an Invis-Dash
	kicker and mark which Shadow Clone lane is real. Not AlwaysOnTop, so they
	never reveal anyone through walls.
]]
local function refreshOverhead(player: Player)
	if player == localPlayer then
		return
	end
	local taken, limit = strikeCounts(player)
	local character = player.Character
	local anchor = if character
		then character:FindFirstChild("Head") or character:FindFirstChild("HumanoidRootPart")
		else nil
	local overhead = overheads[player]

	if taken == nil or limit == nil or anchor == nil then
		if overhead then
			overhead.gui:Destroy()
			overheads[player] = nil
		end
		return
	end

	if overhead == nil then
		local gui = Instance.new("BillboardGui")
		gui.Name = `Strikes_{player.UserId}`
		gui.Size = UDim2.fromOffset(80, 14)
		gui.StudsOffset = Vector3.new(0, 2.3, 0)
		gui.AlwaysOnTop = false
		gui.MaxDistance = 140
		gui.LightInfluence = 0
		gui.ResetOnSpawn = false
		gui.Parent = guiRoot
		local pips = buildPips(gui, 10, 5)
		pips.frame.AnchorPoint = Vector2.new(0.5, 0.5)
		pips.frame.Position = UDim2.fromScale(0.5, 0.5)
		local created: Overhead = { gui = gui, pips = pips }
		overheads[player] = created
		overhead = created
	end

	local current = overhead :: Overhead
	current.gui.Adornee = anchor
	current.gui.Enabled = player:GetAttribute(ATTR.Flying) ~= true
	setPips(current.pips, taken, limit, true)
end

local function watchOverhead(player: Player)
	for _, attribute in { ATTR.Strikes, ATTR.StrikesToExplode, ATTR.Flying } do
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
	ui.flash.BackgroundTransparency = 0.6
	TweenService:Create(ui.flash, TweenInfo.new(0.45), { BackgroundTransparency = 1 }):Play()
end

local function showCard(attackerId: number?, title: string, strikes: string, reason: string, tip: string)
	local ui = widgets
	if ui == nil then
		return
	end
	cardToken += 1
	local token = cardToken

	ui.cardAvatar.Image = if attackerId then `rbxthumb://type=AvatarHeadShot&id={attackerId}&w=150&h=150` else ""
	ui.cardAvatar.Visible = attackerId ~= nil
	ui.cardTitle.Text = title
	ui.cardStrikes.Text = strikes
	ui.cardStrikes.Visible = strikes ~= ""
	ui.cardReason.Text = reason
	ui.cardTip.Text = tip

	ui.cardHolder.Position = UDim2.new(0.5, 0, 0, cardTop)
	ui.card.Visible = true
	ui.cardPop.Scale = 1.12
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

-- Does the card overlap the parry ring? (Only on short screens, where it sits at the top edge.)
function HitFeedback.coversRing(): boolean
	return cardTop == CARD_TOP_SHORT
end

-- Hide the card now (another kick is coming at you, or the round ended).
function HitFeedback.hideCard()
	cardToken += 1
	local ui = widgets
	if ui then
		ui.card.Visible = false
	end
end

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
	local _, limit = strikeCounts(localPlayer)
	local total = limit or payload.strikes
	local tip = if payload.ultimate then `Tip: {dashHint()} out of the marked zone to dodge an ULTIMATE` else parryTip()
	flash()
	if payload.exploded then
		showCard(
			payload.attackerId,
			`EXPLODED BY {attacker}`,
			`STRIKE {payload.strikes} OF {total}`,
			describeKick(payload),
			tip
		)
		killCam(payload.attackerId)
	elseif othersIncoming and HitFeedback.coversRing() then
		return -- the flash and the HUD strike pips still show the hit
	else
		local left = math.max(total - payload.strikes, 0)
		showCard(
			payload.attackerId,
			if payload.ultimate then `ULTIMATE BY {attacker}` else `KICKED BY {attacker}`,
			`STRIKE {payload.strikes} OF {total} · {if left == 1 then "1 MORE EXPLODES YOU" else `{left} LEFT`}`,
			describeKick(payload),
			tip
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
			"Their kick sent you over the edge of the arena",
			"Tip: keep away from the edges once you've taken a strike"
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
	flashFrame.BackgroundColor3 = COLORS.Danger
	flashFrame.BackgroundTransparency = 1
	flashFrame.Parent = gui

	-- Strike pips: centred above the action row on keyboard/gamepad. On touch the
	-- bottom of a phone is full (thumbstick left, the button cluster reaching past
	-- the centre on the right), so a compact pips-only panel sits top-left, under
	-- Roblox's top bar and clear of the hit card even on the narrowest phones.
	local touchOnly = UserInputService.TouchEnabled and not UserInputService.KeyboardEnabled
	local strikes = UiTheme.panel(gui, "Strikes", UDim.new(0.5, 0))
	if touchOnly then
		strikes.AnchorPoint = Vector2.new(0, 0)
		strikes.Position = UDim2.fromOffset(12, 64)
		strikes.Size = UDim2.fromOffset(88, 28)
	else
		strikes.AnchorPoint = Vector2.new(0.5, 1)
		strikes.Position = UDim2.new(0.5, 0, 1, -128)
		strikes.Size = UDim2.fromOffset(196, 28)
	end
	strikes.Visible = false
	local strikePips = buildPips(strikes, PIP_SIZE, PIP_GAP)
	strikePips.frame.AnchorPoint = Vector2.new(0, 0.5)
	strikePips.frame.Position = UDim2.new(0, 12, 0.5, 0)
	local strikeLabel = UiTheme.text(strikes, UiTheme.Font, COLORS.SubText, 12)
	strikeLabel.AnchorPoint = Vector2.new(1, 0.5)
	strikeLabel.Position = UDim2.new(1, -12, 0.5, 0)
	strikeLabel.Size = UDim2.fromOffset(96, 16)
	strikeLabel.TextXAlignment = Enum.TextXAlignment.Right
	strikeLabel.Visible = not touchOnly

	-- Hit card: who, which strike, why. A holder carries the screen-size scale so
	-- the card's own pop-in tween can animate its scale independently.
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
			-- Shrink to fit short or narrow screens, but never below 70% (15 px text -> 10.5 px).
			-- The card is centred and at most 460 px wide, so on a 568 px phone its left edge
			-- is at 120 px, clear of the touch strike pips (x 12-100, y 64-92).
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

	local card = UiTheme.panel(holder, "HitCard", UDim.new(0, 14))
	card.AnchorPoint = Vector2.new(0.5, 0.5) -- the pop-in scales around the card's centre
	card.Position = UDim2.fromScale(0.5, 0.5)
	card.Size = UDim2.fromScale(1, 1)
	card.BackgroundTransparency = 0.12
	card.Visible = false
	local accent = Instance.new("Frame") -- a slim red bar down the left edge
	accent.Name = "Accent"
	accent.Position = UDim2.fromOffset(0, 14)
	accent.Size = UDim2.new(0, 4, 1, -28)
	accent.BackgroundColor3 = COLORS.Danger
	accent.BorderSizePixel = 0
	accent.Parent = card
	UiTheme.corner(accent, UDim.new(0, 2))
	local cardPop = Instance.new("UIScale")
	cardPop.Parent = card

	local cardAvatar = Instance.new("ImageLabel")
	cardAvatar.Name = "Attacker"
	cardAvatar.Position = UDim2.fromOffset(18, 16)
	cardAvatar.Size = UDim2.fromOffset(88, 88)
	cardAvatar.BackgroundColor3 = Color3.fromRGB(40, 44, 56)
	cardAvatar.Parent = card
	UiTheme.corner(cardAvatar, UDim.new(0.5, 0))
	UiTheme.stroke(cardAvatar, 2, COLORS.Danger)

	local textLeft, textWidth = 122, CARD_WIDTH - 136
	local cardTitle = cardLabel(
		card,
		UiTheme.FontHeavy,
		COLORS.Text,
		UDim2.fromOffset(textLeft, 14),
		UDim2.fromOffset(textWidth, 26),
		22
	)
	cardTitle.TextWrapped = false
	cardTitle.TextTruncate = Enum.TextTruncate.AtEnd -- long display names: "KICKED BY SUPERLONGNA..."
	local cardStrikes = cardLabel(
		card,
		UiTheme.FontHeavy,
		COLORS.Danger,
		UDim2.fromOffset(textLeft, 44),
		UDim2.fromOffset(textWidth, 22),
		17
	)
	cardStrikes.TextWrapped = false
	cardStrikes.TextTruncate = Enum.TextTruncate.AtEnd
	local cardReason =
		cardLabel(card, UiTheme.Font, COLORS.Text, UDim2.fromOffset(textLeft, 72), UDim2.fromOffset(textWidth, 38), 15)
	local cardTip = cardLabel(
		card,
		UiTheme.FontBody,
		COLORS.SubText,
		UDim2.fromOffset(18, 118),
		UDim2.fromOffset(CARD_WIDTH - 36, 20),
		14
	)

	widgets = {
		cardHolder = holder,
		strikes = strikes,
		strikePips = strikePips,
		strikeLabel = strikeLabel,
		card = card,
		cardPop = cardPop,
		cardAvatar = cardAvatar,
		cardTitle = cardTitle,
		cardStrikes = cardStrikes,
		cardReason = cardReason,
		cardTip = cardTip,
		flash = flashFrame,
	}

	localPlayer:GetAttributeChangedSignal(ATTR.Strikes):Connect(refreshStrikes)
	localPlayer:GetAttributeChangedSignal(ATTR.StrikesToExplode):Connect(refreshStrikes)
	refreshStrikes()

	Players.PlayerAdded:Connect(watchOverhead)
	for _, player in Players:GetPlayers() do
		watchOverhead(player)
	end
	Players.PlayerRemoving:Connect(function(player: Player)
		local overhead = overheads[player]
		if overhead then
			overhead.gui:Destroy()
			overheads[player] = nil
		end
	end)
end

return HitFeedback
