--!strict
--[[
	HitFeedback (ModuleScript, StarterPlayerScripts/Client)
	=======================================================
	Answers "who hit me, and why did it hurt that much?" the moment it happens.

	  * HUD health bar for the local player (with a trailing "damage ghost"),
	    plus overhead health bars on everyone else in the arena
	  * Hit card: attacker avatar + name, damage taken, and the reason
	    ("6-parry rally · 133 studs/s · faster rallies hit harder") plus a parry tip
	  * Red screen flash on every hit
	  * Kill-cam: when you're eliminated, the camera follows whoever did it for
	    a couple of seconds before handing back control

	Purely presentation: every number shown comes from the server's
	KickResolved / RoundEvent payloads.
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

type Widgets = {
	healthFrame: Frame,
	healthFill: Frame,
	healthGhost: Frame,
	healthLabel: TextLabel,
	card: Frame,
	cardScale: UIScale,
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

-- Helpers ---------------------------------------------------------------------------

local function label(parent: Instance, font: Enum.Font, color: Color3, position: UDim2, size: UDim2): TextLabel
	local text = Instance.new("TextLabel")
	text.BackgroundTransparency = 1
	text.Font = font
	text.TextColor3 = color
	text.TextScaled = true
	text.TextXAlignment = Enum.TextXAlignment.Left
	text.Position = position
	text.Size = size
	text.Text = ""
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
HitFeedback.healthColor = healthColor

local function parryTip(): string
	return if UserInputService.TouchEnabled
		then "Tip: tap BLOCK right before the kick lands to parry it"
		else "Tip: press F right before the kick lands to parry it"
end

local function playerName(userId: number?): string
	local player = if userId then Players:GetPlayerByUserId(userId) else nil
	return if player then player.DisplayName else "someone"
end

-- "6-parry rally · 133 studs/s · faster rallies hit harder"
local function describeKick(payload: Types.KickResolvedPayload): string
	local rally = if payload.rally <= 0 then "Opening kick" else `{payload.rally}-parry rally`
	local speed = `{math.floor(payload.speed + 0.5)} studs/s`
	return if payload.rally <= 0 then `{rally} · {speed}` else `{rally} · {speed} · faster rallies hit harder`
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

-- Overhead bars on other players (yours is the HUD bar).
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
		gui.AlwaysOnTop = true
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
	current.fill.BackgroundColor3 = healthColor(fraction)
	TweenService:Create(current.fill, TweenInfo.new(0.15), { Size = UDim2.fromScale(fraction, 1) }):Play()
end

local function watchOverhead(player: Player)
	player:GetAttributeChangedSignal(ATTR.Health):Connect(function()
		refreshOverhead(player)
	end)
	player:GetAttributeChangedSignal(ATTR.MaxHealth):Connect(function()
		refreshOverhead(player)
	end)
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

	ui.card.Visible = true
	ui.card.BackgroundTransparency = 0.2
	ui.cardScale.Scale = 1.25
	TweenService:Create(ui.cardScale, TweenInfo.new(0.2, Enum.EasingStyle.Back), { Scale = 1 }):Play()

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

-- A kick resolved somewhere. Only hits on the local player produce feedback here.
function HitFeedback.onKickResolved(payload: Types.KickResolvedPayload)
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
	else
		showCard(
			payload.attackerId,
			`KICKED BY {attacker}`,
			`-{payload.damage} HP`,
			describeKick(payload),
			"You caught the Surge: kick someone back!"
		)
	end
end

-- Eliminations that weren't a lethal kick (knocked off the arena, died) get their own card.
function HitFeedback.onRoundEvent(payload: Types.RoundEventPayload)
	if payload.kind ~= "Eliminated" or payload.userId ~= localPlayer.UserId or payload.cause == "Kick" then
		return
	end
	if payload.cause == "Void" and payload.killerId then
		showCard(
			payload.killerId,
			`KNOCKED OFF BY {string.upper(playerName(payload.killerId))}`,
			"",
			"Their kick sent you flying off the arena",
			"Tip: fight away from the edges when you're low on HP"
		)
		killCam(payload.killerId)
	elseif payload.cause == "Void" then
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
	healthFrame.Position = UDim2.new(0.5, 0, 1, -150)
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
	healthLabel.ZIndex = 3
	local labelStroke = Instance.new("UIStroke")
	labelStroke.Thickness = 1.5
	labelStroke.Parent = healthLabel

	-- Hit card: who, how much, why.
	local card = Instance.new("Frame")
	card.Name = "HitCard"
	card.AnchorPoint = Vector2.new(0.5, 0)
	card.Position = UDim2.new(0.5, 0, 0, 130)
	card.Size = UDim2.fromOffset(440, 118)
	card.BackgroundColor3 = Color3.fromRGB(25, 10, 12)
	card.Visible = false
	card.Parent = gui
	corner(card, UDim.new(0, 12))
	local cardStroke = Instance.new("UIStroke")
	cardStroke.Thickness = 3
	cardStroke.Color = HIT_RED
	cardStroke.Parent = card
	local cardScale = Instance.new("UIScale")
	cardScale.Parent = card

	local cardAvatar = Instance.new("ImageLabel")
	cardAvatar.Name = "Attacker"
	cardAvatar.Position = UDim2.fromOffset(12, 12)
	cardAvatar.Size = UDim2.fromOffset(94, 94)
	cardAvatar.BackgroundColor3 = Color3.fromRGB(60, 20, 25)
	cardAvatar.Parent = card
	corner(cardAvatar, UDim.new(0.5, 0))

	local textLeft = 118
	local cardTitle = label(
		card,
		Enum.Font.LuckiestGuy,
		Color3.new(1, 1, 1),
		UDim2.fromOffset(textLeft, 10),
		UDim2.fromOffset(310, 30)
	)
	local cardDamage =
		label(card, Enum.Font.LuckiestGuy, HIT_RED, UDim2.fromOffset(textLeft, 40), UDim2.fromOffset(200, 30))
	local cardReason = label(
		card,
		Enum.Font.GothamBold,
		Color3.fromRGB(255, 210, 200),
		UDim2.fromOffset(textLeft, 72),
		UDim2.fromOffset(310, 18)
	)
	local cardTip = label(
		card,
		Enum.Font.Gotham,
		Color3.fromRGB(190, 190, 200),
		UDim2.fromOffset(textLeft, 92),
		UDim2.fromOffset(310, 16)
	)

	widgets = {
		healthFrame = healthFrame,
		healthFill = healthFill,
		healthGhost = healthGhost,
		healthLabel = healthLabel,
		card = card,
		cardScale = cardScale,
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
