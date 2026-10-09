--!strict
--[[
	LobbyController (LocalScript, StarterPlayer/StarterPlayerScripts/Client)
	========================================================================
	The lobby: where the Coins earned in the arena get spent, and where
	eliminated players watch and bet. Built in code from UiTheme (no assets).

	  * Wallet: coins and crate keys, above the dock
	  * Dock: four round buttons, SHOP / STYLES / CRATE / BET, shown only while
	    you're out of the arena (in a fight the combat buttons use that space)
	  * One panel with a tab per screen:
	      SHOP    stat upgrades: level, current -> next value, price
	      STYLES  every Leg Style; owned ones can be equipped, the rest come from crates
	      CRATE   drop odds, keys, buy a key with Coins (or Robux when configured),
	              and a spinning reel that lands on what the server rolled
	      BET     the fighters still alive with live odds; pick one and an amount

	Every number comes from the server: a ProfileSnapshot (GetProfile once,
	then ProfileUpdated pushes) and replicated attributes. Every button is a
	request the server validates; the UI only shows the answer. The odds shown
	before a bet use the same function the server locks them with
	(CombatMath.betMultiplier).
]]

local MarketplaceService = game:GetService("MarketplaceService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")
local GuiService = game:GetService("GuiService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local AbilityData = require(Shared:WaitForChild("AbilityData"))
local CombatMath = require(Shared:WaitForChild("CombatMath"))
local Config = require(Shared:WaitForChild("Config"))
local Net = require(Shared:WaitForChild("Net"))
local Types = require(Shared:WaitForChild("Types"))
local UpgradeData = require(Shared:WaitForChild("UpgradeData"))
local CombatFX = require(script.Parent:WaitForChild("CombatFX"))
local UiTheme = require(script.Parent:WaitForChild("UiTheme"))

local localPlayer = Players.LocalPlayer
local playerGui = localPlayer:WaitForChild("PlayerGui") :: PlayerGui
local remotes = Net.client()
local roundState = Net.stateFolder()
local ATTR = Net.Attributes
local STATE = Net.StateAttributes
local COLORS = UiTheme.Colors

type Tab = "Shop" | "Styles" | "Crate" | "Bet"

local TABS: { Tab } = { "Shop", "Styles", "Crate", "Bet" }
local TAB_LABEL: { [Tab]: string } = { Shop = "SHOP", Styles = "STYLES", Crate = "CRATE", Bet = "BET" }
local TAB_ACCENT: { [Tab]: Color3 } = {
	Shop = COLORS.Kick,
	Styles = COLORS.Skill,
	Crate = COLORS.UltA,
	Bet = COLORS.Dash,
}

-- Layout, in design pixels (the panel scales down on small screens).
local PANEL_WIDTH, PANEL_HEIGHT = 600, 400
local CONTENT_WIDTH, CONTENT_HEIGHT = 568, 300
local DOCK_BUTTON, DOCK_GAP = 56, 12
local DOCK_BOTTOM = 36 -- same baseline as the combat buttons
local REEL_CARD, REEL_GAP, REEL_LENGTH, REEL_RESULT = 96, 8, 36, 30
local REEL_WINDOW = 548
local SPIN_TIME = 2.4
local BET_CHIPS = { 25, 50, 100, 250 }
local BET_REFRESH = 0.25 -- seconds between live updates of the BET tab

type UpgradeInfo = { blurb: string, format: (value: number) -> string }

local UPGRADE_INFO: { [UpgradeData.StatId]: UpgradeInfo } = {
	WalkSpeed = {
		blurb = "Run faster between kicks",
		format = function(value: number): string
			return string.format("%.1f studs/s", value)
		end,
	},
	JumpPower = {
		blurb = "Jump higher",
		format = function(value: number): string
			return tostring(math.floor(value + 0.5))
		end,
	},
	ParryWindow = {
		blurb = "Block counts a little earlier before impact",
		format = function(value: number): string
			return string.format("+%.3f s", value)
		end,
	},
}

type ShopRow = {
	level: TextLabel,
	fill: Frame,
	values: TextLabel,
	buy: TextButton,
}

type StyleCard = {
	style: AbilityData.LegStyle,
	button: TextButton,
	frame: Frame,
}

type BetRow = {
	player: Player,
	button: TextButton,
	stroke: UIStroke,
	name: TextLabel,
	strikes: TextLabel,
	odds: TextLabel,
}

type MyBet = {
	roundId: number,
	targetId: number,
	targetName: string,
	amount: number,
	multiplier: number,
	outcome: Types.BetOutcome?, -- set when the server settles it
}

-- State --------------------------------------------------------------------------------

local profile: Types.ProfileSnapshot? = nil
local activeTab: Tab? = nil -- nil = panel closed
local busy = false -- a lobby request is in flight (one at a time, so no double-buys)
local spinning = false -- the crate reel is playing
local myBet: MyBet? = nil
local betTarget: Player? = nil
local betChoice: number? = 50 -- nil = MAX
local lastTab: Tab = "Shop" -- what the gamepad shortcut reopens
local frozenWallet: string? = nil -- during a crate spin, the wallet line from before it (no spoilers)
local refresh: () -> () -- defined once every widget exists

-- Helpers ------------------------------------------------------------------------------

local function isTrue(name: string): boolean
	return localPlayer:GetAttribute(name) == true
end

local function commas(value: number): string
	local digits = tostring(math.floor(value))
	local grouped = (string.gsub(string.reverse(digits), "(%d%d%d)", "%1,"))
	grouped = string.reverse(grouped)
	if string.sub(grouped, 1, 1) == "," then
		grouped = string.sub(grouped, 2)
	end
	return grouped
end

local function coins(): number
	local snapshot = profile
	return if snapshot then snapshot.coins else 0
end

local function owns(styleId: string): boolean
	local snapshot = profile
	return snapshot ~= nil and table.find(snapshot.ownedStyles, styleId) ~= nil
end

local function rarityRank(rarity: AbilityData.Rarity): number
	return table.find(AbilityData.RarityOrder, rarity) or 0
end

-- Every Leg Style that can drop from a crate, most common first, with its odds.
local function crateTable(): ({ AbilityData.LegStyle }, number)
	local list: { AbilityData.LegStyle } = {}
	local total = 0
	for _, style in AbilityData.Styles do
		if style.dropWeight > 0 then
			table.insert(list, style)
			total += style.dropWeight
		end
	end
	table.sort(list, function(a: AbilityData.LegStyle, b: AbilityData.LegStyle): boolean
		return if a.dropWeight ~= b.dropWeight then a.dropWeight > b.dropWeight else a.displayName < b.displayName
	end)
	return list, total
end

-- A bright pill button (dark text on the accent colour).
local function pillButton(parent: Instance, text: string, accent: Color3, size: UDim2): TextButton
	local button = Instance.new("TextButton")
	button.AutoButtonColor = false
	button.BackgroundColor3 = accent
	button.BorderSizePixel = 0
	button.Size = size
	button.Font = UiTheme.FontHeavy
	button.TextSize = 15
	button.TextColor3 = COLORS.Panel
	button.Text = text
	button.Parent = parent
	UiTheme.corner(button, UDim.new(0.5, 0))
	return button
end

-- Enabled buttons are solid; disabled ones fade. Click handlers re-check on their own.
local function setButton(button: TextButton, text: string, enabled: boolean)
	button.Text = text
	button.BackgroundTransparency = if enabled then 0 else 0.7
	button.TextTransparency = if enabled then 0 else 0.4
end

local function label(
	parent: Instance,
	font: Enum.Font,
	color: Color3,
	size: number,
	position: UDim2,
	box: UDim2
): TextLabel
	local text = UiTheme.text(parent, font, color, size)
	text.Position = position
	text.Size = box
	text.TextXAlignment = Enum.TextXAlignment.Left
	text.TextYAlignment = Enum.TextYAlignment.Center
	return text
end

-- A lighter glass card inside the panel.
local function card(parent: Instance, name: string, size: UDim2): Frame
	local frame = UiTheme.panel(parent, name, UDim.new(0, 12))
	frame.BackgroundTransparency = 0.55
	frame.Size = size
	return frame
end

local function headshot(userId: number): string
	return `rbxthumb://type=AvatarHeadShot&id={userId}&w=60&h=60`
end

-- GUI root ---------------------------------------------------------------------------------

local gui = Instance.new("ScreenGui")
gui.Name = "ClashKickLobby"
gui.ResetOnSpawn = false
gui.IgnoreGuiInset = true
gui.DisplayOrder = 10 -- under the hit card (15) and toasts (20)
gui.Parent = playerGui

-- Dock + wallet ----------------------------------------------------------------------------

-- Keyboard / gamepad: one centred row on the combat buttons' baseline. Touch: a 2x2 grid
-- bottom-right, left of Roblox's Jump button and out of the thumbstick's half of the screen.
local touchOnly = UserInputService.TouchEnabled and not UserInputService.KeyboardEnabled
local dock = Instance.new("Frame")
dock.Name = "Dock"
dock.BackgroundTransparency = 1
dock.Visible = false
dock.Parent = gui
if touchOnly then
	dock.AnchorPoint = Vector2.new(1, 1)
	dock.Position = UDim2.new(1, -184, 1, -28)
	dock.Size = UDim2.fromOffset(2 * DOCK_BUTTON + DOCK_GAP, 2 * DOCK_BUTTON + DOCK_GAP)
	local grid = Instance.new("UIGridLayout")
	grid.CellSize = UDim2.fromOffset(DOCK_BUTTON, DOCK_BUTTON)
	grid.CellPadding = UDim2.fromOffset(DOCK_GAP, DOCK_GAP)
	grid.SortOrder = Enum.SortOrder.LayoutOrder
	grid.Parent = dock
else
	dock.AnchorPoint = Vector2.new(0.5, 1)
	dock.Position = UDim2.new(0.5, 0, 1, -DOCK_BOTTOM)
	dock.Size = UDim2.fromOffset(#TABS * DOCK_BUTTON + (#TABS - 1) * DOCK_GAP, DOCK_BUTTON)
	local row = Instance.new("UIListLayout")
	row.FillDirection = Enum.FillDirection.Horizontal
	row.Padding = UDim.new(0, DOCK_GAP)
	row.SortOrder = Enum.SortOrder.LayoutOrder
	row.Parent = dock
end

local dockButtons: { [Tab]: TextButton } = {}
for index, tab: Tab in TABS do
	local button = Instance.new("TextButton")
	button.Name = TAB_LABEL[tab]
	button.LayoutOrder = index
	button.Size = UDim2.fromOffset(DOCK_BUTTON, DOCK_BUTTON)
	button.BackgroundColor3 = COLORS.Panel
	button.BackgroundTransparency = UiTheme.PanelTransparency
	button.AutoButtonColor = false
	button.Text = ""
	button.Parent = dock
	UiTheme.corner(button, UDim.new(0.5, 0))
	UiTheme.stroke(button, 2.5, TAB_ACCENT[tab])
	local caption = UiTheme.text(button, UiTheme.FontHeavy, COLORS.Text)
	caption.AnchorPoint = Vector2.new(0.5, 0.5)
	caption.Position = UDim2.fromScale(0.5, 0.5)
	caption.Size = UDim2.fromScale(0.8, 0.24)
	caption.Text = TAB_LABEL[tab]
	dockButtons[tab] = button
end

local wallet = UiTheme.panel(gui, "Wallet", UDim.new(0.5, 0))
if touchOnly then
	wallet.AnchorPoint = Vector2.new(1, 1)
	wallet.Position = UDim2.new(1, -184, 1, -(28 + 2 * DOCK_BUTTON + DOCK_GAP + 10))
else
	wallet.AnchorPoint = Vector2.new(0.5, 1)
	wallet.Position = UDim2.new(0.5, 0, 1, -(DOCK_BOTTOM + DOCK_BUTTON + 12))
end
wallet.AutomaticSize = Enum.AutomaticSize.X
wallet.Size = UDim2.fromOffset(0, 30)
wallet.Visible = false
local walletPadding = Instance.new("UIPadding")
walletPadding.PaddingLeft = UDim.new(0, 14)
walletPadding.PaddingRight = UDim.new(0, 14)
walletPadding.Parent = wallet
local walletText = UiTheme.text(wallet, UiTheme.Font, COLORS.Text, 14)
walletText.AutomaticSize = Enum.AutomaticSize.X
walletText.Size = UDim2.fromScale(0, 1)

-- Panel ------------------------------------------------------------------------------------

local holder = Instance.new("Frame")
holder.Name = "LobbyPanel"
holder.AnchorPoint = Vector2.new(0.5, 0) -- top-anchored: fitToScreen places the top edge
holder.Position = UDim2.new(0.5, 0, 0, 62)
holder.Size = UDim2.fromOffset(PANEL_WIDTH, PANEL_HEIGHT)
holder.BackgroundTransparency = 1
holder.Visible = false
holder.Parent = gui
local fitScale = Instance.new("UIScale")
fitScale.Parent = holder

local function fitToScreen()
	local camera = Workspace.CurrentCamera
	if camera then
		local viewport = camera.ViewportSize
		-- As big as fits below Roblox's top bar (the dock hides while the panel is open, so
		-- the bottom of the screen is free); never below 60%. On short phone screens it covers
		-- the phase pill while open, which keeps text ~10 px and buttons tappable.
		local scale = math.clamp(math.min((viewport.Y - 72) / PANEL_HEIGHT, viewport.X * 0.94 / PANEL_WIDTH), 0.6, 1)
		fitScale.Scale = scale
		local top = math.max(62, (viewport.Y - PANEL_HEIGHT * scale) / 2 + 15)
		holder.Position = UDim2.new(0.5, 0, 0, top)
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

local panel = UiTheme.panel(holder, "Panel", UDim.new(0, 16))
panel.Size = UDim2.fromScale(1, 1)
panel.BackgroundTransparency = 0.08
panel.Active = true -- sink drags and the wheel, so the camera / thumbstick don't move underneath

-- Header: tab pills, wallet, close.
local tabButtons: { [Tab]: TextButton } = {}
for index, tab: Tab in TABS do
	local button = Instance.new("TextButton")
	button.Name = TAB_LABEL[tab]
	button.AutoButtonColor = false
	button.Position = UDim2.fromOffset(16 + (index - 1) * 86, 9)
	button.Size = UDim2.fromOffset(80, 36)
	button.BorderSizePixel = 0
	button.Font = UiTheme.FontHeavy
	button.TextSize = 14
	button.Text = TAB_LABEL[tab]
	button.Parent = panel
	UiTheme.corner(button, UDim.new(0.5, 0))
	tabButtons[tab] = button
end

-- Between the tab pills (ending at x 354) and the close button (from x 552).
local headerWallet = label(panel, UiTheme.Font, COLORS.Text, 14, UDim2.fromOffset(362, 12), UDim2.fromOffset(184, 32))
headerWallet.TextXAlignment = Enum.TextXAlignment.Right
headerWallet.TextScaled = true -- big balances shrink instead of running into the tabs
local walletLimit = Instance.new("UITextSizeConstraint")
walletLimit.MaxTextSize = 14
walletLimit.MinTextSize = 9
walletLimit.Parent = headerWallet

local closeButton = Instance.new("TextButton")
closeButton.Name = "Close"
closeButton.AutoButtonColor = false
closeButton.AnchorPoint = Vector2.new(1, 0)
closeButton.Position = UDim2.new(1, -12, 0, 10)
closeButton.Size = UDim2.fromOffset(36, 36)
closeButton.BackgroundColor3 = COLORS.Panel
closeButton.BackgroundTransparency = 0.3
closeButton.Font = UiTheme.FontHeavy
closeButton.TextSize = 16
closeButton.TextColor3 = COLORS.Text
closeButton.Text = "X"
closeButton.Parent = panel
UiTheme.corner(closeButton, UDim.new(0.5, 0))
UiTheme.stroke(closeButton, 1, COLORS.Edge, 0.7)

local divider = Instance.new("Frame")
divider.Position = UDim2.fromOffset(16, 52)
divider.Size = UDim2.new(1, -32, 0, 1)
divider.BackgroundColor3 = COLORS.Edge
divider.BackgroundTransparency = 0.85
divider.BorderSizePixel = 0
divider.Parent = panel

local status = label(
	panel,
	UiTheme.FontBody,
	COLORS.SubText,
	14,
	UDim2.fromOffset(16, PANEL_HEIGHT - 34),
	UDim2.fromOffset(CONTENT_WIDTH, 22)
)
status.TextTruncate = Enum.TextTruncate.AtEnd

local function setStatus(text: string, color: Color3?)
	status.Text = text
	status.TextColor3 = color or COLORS.SubText
end

local pages: { [Tab]: Frame } = {}
local function makePage(tab: Tab): Frame
	local page = Instance.new("Frame")
	page.Name = TAB_LABEL[tab]
	page.Position = UDim2.fromOffset(16, 62)
	page.Size = UDim2.fromOffset(CONTENT_WIDTH, CONTENT_HEIGHT)
	page.BackgroundTransparency = 1
	page.Visible = false
	page.Parent = panel
	pages[tab] = page
	return page
end
local shopPage = makePage("Shop")
local stylesPage = makePage("Styles")
local cratePage = makePage("Crate")
local betPage = makePage("Bet")

--[[
	Run one lobby request. One at a time (busy), any yield-time error caught,
	and the server's answer shown in the status line. The profile itself is
	refreshed by the ProfileUpdated push that follows any change.
]]
local function request(action: () -> (boolean, string)): boolean
	if busy then
		return false
	end
	busy = true
	refresh()
	local ok, success, message = pcall(action)
	busy = false
	if not ok then
		setStatus("Couldn't reach the server. Try again.", COLORS.Danger)
		refresh()
		return false
	end
	setStatus(message, if success then COLORS.Dash else COLORS.Danger)
	refresh()
	return success
end

-- The server answers (ok: boolean, message: string, ...); anything else counts as a failure.
local function answer(ok: unknown, message: unknown): (boolean, string)
	return ok == true, if typeof(message) == "string" then message else "Something went wrong"
end

-- SHOP -------------------------------------------------------------------------------------

local shopRows: { [UpgradeData.StatId]: ShopRow } = {}
for index, stat: UpgradeData.StatId in UpgradeData.Order do
	local def = UpgradeData.Stats[stat]
	local row = card(shopPage, stat, UDim2.fromOffset(CONTENT_WIDTH, 90))
	row.Position = UDim2.fromOffset(0, (index - 1) * 100)

	label(row, UiTheme.FontHeavy, COLORS.Text, 18, UDim2.fromOffset(16, 10), UDim2.fromOffset(280, 24)).Text =
		string.upper(def.displayName)
	label(row, UiTheme.FontBody, COLORS.SubText, 13, UDim2.fromOffset(16, 34), UDim2.fromOffset(280, 18)).Text =
		UPGRADE_INFO[stat].blurb
	local level = label(row, UiTheme.Font, COLORS.SubText, 13, UDim2.fromOffset(16, 58), UDim2.fromOffset(80, 18))

	local bar = Instance.new("Frame")
	bar.Position = UDim2.fromOffset(96, 64)
	bar.Size = UDim2.fromOffset(190, 6)
	bar.BackgroundColor3 = COLORS.Edge
	bar.BackgroundTransparency = 0.85
	bar.BorderSizePixel = 0
	bar.Parent = row
	UiTheme.corner(bar, UDim.new(0.5, 0))
	local fill = Instance.new("Frame")
	fill.Size = UDim2.fromScale(0, 1)
	fill.BackgroundColor3 = COLORS.Kick
	fill.BorderSizePixel = 0
	fill.Parent = bar
	UiTheme.corner(fill, UDim.new(0.5, 0))

	local values = label(row, UiTheme.Font, COLORS.Text, 14, UDim2.fromOffset(300, 14), UDim2.fromOffset(120, 62))
	values.TextWrapped = true
	values.TextXAlignment = Enum.TextXAlignment.Right

	local buy = pillButton(row, "BUY", COLORS.Kick, UDim2.fromOffset(120, 40))
	buy.AnchorPoint = Vector2.new(1, 0.5)
	buy.Position = UDim2.new(1, -16, 0.5, 0)
	buy.Activated:Connect(function()
		local snapshot = profile
		local current = if snapshot then snapshot.upgrades[stat] or 0 else 0
		local cost = UpgradeData.costFor(stat, current)
		if snapshot == nil or cost == nil or busy then
			return
		end
		if snapshot.coins < cost then
			setStatus(`You need {commas(cost - snapshot.coins)} more coins`, COLORS.Danger)
			return
		end
		request(function(): (boolean, string)
			return answer(remotes.PurchaseUpgrade:InvokeServer(stat))
		end)
	end)

	shopRows[stat] = { level = level, fill = fill, values = values, buy = buy }
end

local function refreshShop()
	local snapshot = profile
	for stat: UpgradeData.StatId, row in shopRows do
		local def = UpgradeData.Stats[stat]
		local current = if snapshot then snapshot.upgrades[stat] or 0 else 0
		local info = UPGRADE_INFO[stat]
		local cost = UpgradeData.costFor(stat, current)
		row.level.Text = `LV {current}/{def.maxLevel}`
		row.fill.Size = UDim2.fromScale(current / def.maxLevel, 1)
		local now = info.format(UpgradeData.valueAt(stat, current))
		if cost then
			row.values.Text = `{now}\n→ {info.format(UpgradeData.valueAt(stat, current + 1))}`
			setButton(row.buy, `BUY · {commas(cost)}`, snapshot ~= nil and snapshot.coins >= cost and not busy)
		else
			row.values.Text = now
			setButton(row.buy, "MAXED", false)
		end
	end
end

-- STYLES -----------------------------------------------------------------------------------

local styleList = Instance.new("ScrollingFrame")
styleList.Size = UDim2.fromScale(1, 1)
styleList.BackgroundTransparency = 1
styleList.BorderSizePixel = 0
styleList.ScrollBarThickness = 4
styleList.ScrollBarImageColor3 = COLORS.SubText
styleList.AutomaticCanvasSize = Enum.AutomaticSize.Y
styleList.CanvasSize = UDim2.new()
styleList.Parent = stylesPage
local styleLayout = Instance.new("UIListLayout")
styleLayout.Padding = UDim.new(0, 8)
styleLayout.SortOrder = Enum.SortOrder.LayoutOrder
styleLayout.Parent = styleList

local styleCards: { StyleCard } = {}
do
	local ordered: { AbilityData.LegStyle } = {}
	for _, style in AbilityData.Styles do
		table.insert(ordered, style)
	end
	table.sort(ordered, function(a: AbilityData.LegStyle, b: AbilityData.LegStyle): boolean
		local ra, rb = rarityRank(a.rarity), rarityRank(b.rarity)
		return if ra ~= rb then ra < rb else a.displayName < b.displayName
	end)

	for index, style in ordered do
		local color = AbilityData.RarityColors[style.rarity]
		local frame = card(styleList, style.id, UDim2.new(1, -8, 0, 88))
		frame.LayoutOrder = index

		local stripe = Instance.new("Frame")
		stripe.Position = UDim2.fromOffset(0, 12)
		stripe.Size = UDim2.new(0, 4, 1, -24)
		stripe.BackgroundColor3 = color
		stripe.BorderSizePixel = 0
		stripe.Parent = frame
		UiTheme.corner(stripe, UDim.new(0, 2))

		label(frame, UiTheme.FontHeavy, COLORS.Text, 17, UDim2.fromOffset(18, 8), UDim2.fromOffset(380, 22)).Text =
			string.upper(style.displayName)
		local uses = if style.usesPerRound > 0
			then `{style.usesPerRound} USE{if style.usesPerRound == 1 then "" else "S"} PER ROUND`
			else "NO SKILL"
		label(frame, UiTheme.Font, color, 13, UDim2.fromOffset(18, 30), UDim2.fromOffset(380, 16)).Text =
			`{string.upper(style.rarity)} · {uses}`
		local blurb =
			label(frame, UiTheme.FontBody, COLORS.SubText, 13, UDim2.fromOffset(18, 48), UDim2.fromOffset(400, 34))
		blurb.Text = style.description
		blurb.TextWrapped = true -- two lines fit
		blurb.TextYAlignment = Enum.TextYAlignment.Top

		local button = pillButton(frame, "EQUIP", COLORS.Skill, UDim2.fromOffset(110, 36))
		button.AnchorPoint = Vector2.new(1, 0.5)
		button.Position = UDim2.new(1, -14, 0.5, 0)
		button.Activated:Connect(function()
			local snapshot = profile
			if snapshot == nil or busy or spinning or snapshot.equippedStyle == style.id then
				return
			end
			if not owns(style.id) then
				setStatus(`{style.displayName} comes from crates`, COLORS.SubText)
				return
			end
			request(function(): (boolean, string)
				return answer(remotes.EquipLegStyle:InvokeServer(style.id))
			end)
		end)

		table.insert(styleCards, { style = style, button = button, frame = frame })
	end
end

local function refreshStyles()
	local snapshot = profile
	for _, entry in styleCards do
		local owned = owns(entry.style.id)
		local equipped = snapshot ~= nil and snapshot.equippedStyle == entry.style.id
		entry.frame.BackgroundTransparency = if owned then 0.55 else 0.75
		if equipped then
			setButton(entry.button, "EQUIPPED", false)
		elseif owned then
			setButton(entry.button, "EQUIP", not busy)
		else
			setButton(entry.button, "LOCKED", false)
		end
	end
end

-- CRATE ------------------------------------------------------------------------------------

local crateTile = Instance.new("Frame")
crateTile.Name = "Crate"
crateTile.Position = UDim2.fromOffset(25, 0)
crateTile.Size = UDim2.fromOffset(200, 132)
crateTile.BackgroundColor3 = Color3.new(1, 1, 1)
crateTile.BorderSizePixel = 0
crateTile.Parent = cratePage
UiTheme.corner(crateTile, UDim.new(0, 18))
local crateGradient = Instance.new("UIGradient")
crateGradient.Color = ColorSequence.new(COLORS.UltA, COLORS.UltB)
crateGradient.Rotation = 45
crateGradient.Parent = crateTile
local crateTitle = UiTheme.text(crateTile, UiTheme.FontHeavy, COLORS.Panel, 20)
crateTitle.Size = UDim2.fromScale(1, 1)
crateTitle.Text = "LEG STYLE\nCRATE"

local keysText =
	label(cratePage, UiTheme.FontHeavy, COLORS.Text, 16, UDim2.fromOffset(0, 140), UDim2.fromOffset(250, 24))
keysText.TextXAlignment = Enum.TextXAlignment.Center

local spinButton = pillButton(cratePage, "SPIN", COLORS.UltA, UDim2.fromOffset(200, 40))
spinButton.Position = UDim2.fromOffset(25, 172)

local keyPrice = Config.Monetization.KeyCoinPrice
local buyKeyButton = pillButton(cratePage, "", COLORS.Kick, UDim2.fromOffset(200, 32))
buyKeyButton.Position = UDim2.fromOffset(25, 222)
buyKeyButton.Visible = keyPrice > 0

local productId = Config.Monetization.CrateKeyProductId
local robuxButton = pillButton(cratePage, "GET KEYS (R$)", COLORS.Skill, UDim2.fromOffset(200, 32))
robuxButton.Position = UDim2.fromOffset(25, 262)
robuxButton.Visible = productId ~= 0

-- Odds, from the same weights the server rolls with.
local oddsCard = card(cratePage, "Odds", UDim2.fromOffset(300, CONTENT_HEIGHT))
oddsCard.Position = UDim2.fromOffset(268, 0)
label(oddsCard, UiTheme.FontHeavy, COLORS.Text, 15, UDim2.fromOffset(16, 10), UDim2.fromOffset(268, 22)).Text =
	"DROP ODDS"
do
	local list, total = crateTable()
	for index, style in list do
		local y = 40 + (index - 1) * 34
		local color = AbilityData.RarityColors[style.rarity]
		label(oddsCard, UiTheme.FontHeavy, color, 14, UDim2.fromOffset(16, y), UDim2.fromOffset(180, 18)).Text =
			string.upper(style.displayName)
		label(oddsCard, UiTheme.Font, COLORS.SubText, 12, UDim2.fromOffset(16, y + 17), UDim2.fromOffset(180, 14)).Text =
			string.upper(style.rarity)
		local chance =
			label(oddsCard, UiTheme.FontHeavy, COLORS.Text, 15, UDim2.fromOffset(196, y), UDim2.fromOffset(88, 30))
		chance.TextXAlignment = Enum.TextXAlignment.Right
		chance.Text = string.format("%.0f%%", style.dropWeight / total * 100)
	end
	local note = label(
		oddsCard,
		UiTheme.FontBody,
		COLORS.SubText,
		12,
		UDim2.fromOffset(16, CONTENT_HEIGHT - 50),
		UDim2.fromOffset(268, 40)
	)
	note.TextWrapped = true
	note.Text = `A style you already own refunds {Config.Monetization.DuplicateRefundCoins} coins instead.`
end

-- The reel: a strip of cards that scrolls and lands on what the server rolled.
local reel = Instance.new("Frame")
reel.Name = "Reel"
reel.Size = UDim2.fromScale(1, 1)
reel.BackgroundColor3 = COLORS.Panel
reel.BackgroundTransparency = 0.04
reel.BorderSizePixel = 0
reel.Visible = false
reel.ZIndex = 5
reel.Active = true -- sinks taps, so nothing reaches SPIN / BUY KEY hidden underneath
reel.Parent = cratePage
UiTheme.corner(reel, UDim.new(0, 12))

local reelWindow = Instance.new("Frame")
reelWindow.AnchorPoint = Vector2.new(0.5, 0)
reelWindow.Position = UDim2.new(0.5, 0, 0, 40)
reelWindow.Size = UDim2.fromOffset(REEL_WINDOW, REEL_CARD + 24)
reelWindow.BackgroundTransparency = 0.6
reelWindow.BackgroundColor3 = Color3.new(0, 0, 0)
reelWindow.ClipsDescendants = true
reelWindow.ZIndex = 5
reelWindow.Parent = reel
UiTheme.corner(reelWindow, UDim.new(0, 12))

local strip = Instance.new("Frame")
strip.AnchorPoint = Vector2.new(0, 0.5)
strip.Position = UDim2.new(0, 0, 0.5, 0)
strip.Size = UDim2.fromOffset(REEL_LENGTH * (REEL_CARD + REEL_GAP), REEL_CARD)
strip.BackgroundTransparency = 1
strip.ZIndex = 5
strip.Parent = reelWindow

local reelCards: { { frame: Frame, stroke: UIStroke, name: TextLabel, rarity: TextLabel, pop: UIScale } } = {}
for index = 1, REEL_LENGTH do
	local frame = Instance.new("Frame")
	frame.AnchorPoint = Vector2.new(0.5, 0.5) -- the winner's pop grows from its centre
	frame.Position = UDim2.fromOffset((index - 1) * (REEL_CARD + REEL_GAP) + REEL_CARD / 2, REEL_CARD / 2)
	frame.Size = UDim2.fromOffset(REEL_CARD, REEL_CARD)
	frame.BackgroundColor3 = COLORS.Panel
	frame.BorderSizePixel = 0
	frame.ZIndex = 6
	frame.Parent = strip
	UiTheme.corner(frame, UDim.new(0, 10))
	local stroke = UiTheme.stroke(frame, 2, COLORS.Edge)
	local name = UiTheme.text(frame, UiTheme.FontHeavy, COLORS.Text, 13)
	name.Position = UDim2.fromOffset(6, 20)
	name.Size = UDim2.new(1, -12, 0, 40)
	name.TextWrapped = true
	name.ZIndex = 7
	local rarity = UiTheme.text(frame, UiTheme.Font, COLORS.SubText, 12)
	rarity.Position = UDim2.new(0, 6, 1, -28)
	rarity.Size = UDim2.new(1, -12, 0, 16)
	rarity.ZIndex = 7
	local pop = Instance.new("UIScale")
	pop.Parent = frame
	table.insert(reelCards, { frame = frame, stroke = stroke, name = name, rarity = rarity, pop = pop })
end

local marker = Instance.new("Frame") -- the line the result lands on
marker.AnchorPoint = Vector2.new(0.5, 0.5)
marker.Position = UDim2.fromScale(0.5, 0.5)
marker.Size = UDim2.new(0, 3, 1, -4)
marker.BackgroundColor3 = COLORS.UltA
marker.BorderSizePixel = 0
marker.ZIndex = 9
marker.Parent = reelWindow

local reelResult = UiTheme.text(reel, UiTheme.FontHeavy, COLORS.Text, 20)
reelResult.AnchorPoint = Vector2.new(0.5, 0)
reelResult.Position = UDim2.new(0.5, 0, 0, 176)
reelResult.Size = UDim2.fromOffset(CONTENT_WIDTH - 32, 52)
reelResult.TextWrapped = true
reelResult.ZIndex = 6

local reelDone = pillButton(reel, "OK", COLORS.UltA, UDim2.fromOffset(140, 36))
reelDone.AnchorPoint = Vector2.new(0.5, 0)
reelDone.Position = UDim2.new(0.5, 0, 0, 240)
reelDone.ZIndex = 6
reelDone.Visible = false
reelDone.Activated:Connect(function()
	if not spinning then
		reel.Visible = false
		refresh()
	end
end)

-- A brand-new style can be equipped right from the reveal.
local reelEquip = pillButton(reel, "EQUIP NOW", COLORS.Skill, UDim2.fromOffset(160, 36))
reelEquip.AnchorPoint = Vector2.new(0.5, 0)
reelEquip.Position = UDim2.new(0.5, 86, 0, 240)
reelEquip.ZIndex = 6
reelEquip.Visible = false
local reelStyleId: string? = nil

local function weightedPick(rng: Random): AbilityData.LegStyle
	local list, total = crateTable()
	local roll = rng:NextNumber(0, total)
	for _, style in list do
		roll -= style.dropWeight
		if roll <= 0 then
			return style
		end
	end
	return list[#list]
end

local function setReelCard(index: number, style: AbilityData.LegStyle)
	local entry = reelCards[index]
	local color = AbilityData.RarityColors[style.rarity]
	entry.stroke.Color = color
	entry.name.Text = string.upper(style.displayName)
	entry.rarity.Text = string.upper(style.rarity)
	entry.rarity.TextColor3 = color
	entry.pop.Scale = 1
end

-- The server has already rolled `style`; the reel is just the reveal.
local function playReel(style: AbilityData.LegStyle, duplicate: boolean)
	spinning = true
	reel.Visible = true
	reelDone.Visible = false
	reelEquip.Visible = false
	reelStyleId = if duplicate then nil else style.id
	reelResult.Text = ""
	local rng = Random.new()
	for index = 1, REEL_LENGTH do
		setReelCard(index, if index == REEL_RESULT then style else weightedPick(rng))
	end
	-- Land the result card's centre on the marker, slightly off-centre so it doesn't look canned.
	local step = REEL_CARD + REEL_GAP
	local jitter = rng:NextNumber(-REEL_CARD * 0.35, REEL_CARD * 0.35)
	local landing = REEL_WINDOW / 2 - ((REEL_RESULT - 1) * step + REEL_CARD / 2) + jitter
	strip.Position = UDim2.new(0, 0, 0.5, 0)
	local tween = TweenService:Create(
		strip,
		TweenInfo.new(SPIN_TIME, Enum.EasingStyle.Quint, Enum.EasingDirection.Out),
		{ Position = UDim2.new(0, landing, 0.5, 0) }
	)
	tween.Completed:Once(function()
		local winner = reelCards[REEL_RESULT]
		winner.pop.Scale = 1.12
		TweenService:Create(winner.pop, TweenInfo.new(0.25, Enum.EasingStyle.Back), { Scale = 1.06 }):Play()
		local color = AbilityData.RarityColors[style.rarity]
		reelResult.TextColor3 = if duplicate then COLORS.Text else color
		reelResult.Text = if duplicate
			then `{string.upper(style.displayName)} (already owned)\n+{Config.Monetization.DuplicateRefundCoins} coins`
			else `NEW · {string.upper(style.displayName)}\n{string.upper(style.rarity)}`
		-- One button for a duplicate; OK + EQUIP NOW side by side for a new style.
		reelDone.Position = if duplicate then UDim2.new(0.5, 0, 0, 240) else UDim2.new(0.5, -86, 0, 240)
		reelDone.Visible = true
		reelEquip.Visible = not duplicate
		setStatus(if duplicate then "Duplicate: coins refunded" else `New Leg Style: {style.displayName}`, COLORS.UltA)
		spinning = false
		frozenWallet = nil -- the reveal is done: show the real balance
		refresh()
	end)
	tween:Play()
end

spinButton.Activated:Connect(function()
	local snapshot = profile
	if snapshot == nil or busy or spinning or reel.Visible then
		return
	end
	if snapshot.crateKeys <= 0 then
		setStatus(
			if keyPrice > 0 then "You need a crate key: buy one with coins" else "You need a crate key",
			COLORS.Danger
		)
		return
	end
	busy = true
	-- The spin starts now, not when the reel does: while the request is in flight the
	-- panel stays on CRATE (other tabs would already show the result).
	spinning = true
	-- Hold the wallet line as it was: the profile push for this spin (one key fewer,
	-- maybe a duplicate refund) would otherwise give the result away before the reel lands.
	frozenWallet = headerWallet.Text
	refresh()
	local ok, success, result, duplicate = pcall(function()
		return remotes.SpinCrate:InvokeServer()
	end)
	busy = false
	local style = if ok and success == true and typeof(result) == "string" then AbilityData.get(result) else nil
	if style == nil or isTrue(ATTR.InArena) then
		spinning = false
		frozenWallet = nil
		setStatus(if ok and typeof(result) == "string" then result else "Couldn't spin. Try again.", COLORS.Danger)
		refresh()
		return
	end
	setStatus("Spinning...", COLORS.SubText)
	playReel(style, duplicate == true)
end)

reelEquip.Activated:Connect(function()
	local styleId = reelStyleId
	if styleId == nil or busy or spinning then
		return
	end
	reel.Visible = false
	request(function(): (boolean, string)
		return answer(remotes.EquipLegStyle:InvokeServer(styleId))
	end)
end)

buyKeyButton.Activated:Connect(function()
	if busy or spinning or reel.Visible then
		return
	end
	if coins() < keyPrice then
		setStatus(`You need {commas(keyPrice - coins())} more coins`, COLORS.Danger)
		return
	end
	request(function(): (boolean, string)
		return answer(remotes.BuyCrateKey:InvokeServer())
	end)
end)

robuxButton.Activated:Connect(function()
	if productId ~= 0 and not reel.Visible then
		MarketplaceService:PromptProductPurchase(localPlayer, productId)
	end
end)

local function refreshCrate()
	local snapshot = profile
	local keys = if snapshot then snapshot.crateKeys else 0
	keysText.Text = `{keys} KEY{if keys == 1 then "" else "S"}`
	setButton(spinButton, if spinning then "SPINNING..." else "SPIN", keys > 0 and not busy and not spinning)
	setButton(buyKeyButton, `BUY KEY · {commas(keyPrice)}`, coins() >= keyPrice and not busy and not spinning)
	-- Under the reel these can't be tapped (it sinks input) or reached with a gamepad.
	local covered = reel.Visible
	spinButton.Interactable = not covered
	buyKeyButton.Interactable = not covered
	robuxButton.Interactable = not covered
end

-- BET --------------------------------------------------------------------------------------

local betIntro =
	label(betPage, UiTheme.FontBody, COLORS.SubText, 13, UDim2.fromOffset(0, 0), UDim2.fromOffset(CONTENT_WIDTH, 18))
betIntro.Text = "Back a fighter to win the round. Odds lock when you bet."

local betMessage =
	label(betPage, UiTheme.Font, COLORS.Text, 16, UDim2.fromOffset(0, 90), UDim2.fromOffset(CONTENT_WIDTH, 60))
betMessage.TextXAlignment = Enum.TextXAlignment.Center
betMessage.TextWrapped = true

local betList = Instance.new("ScrollingFrame")
betList.Position = UDim2.fromOffset(0, 26)
betList.Size = UDim2.fromOffset(CONTENT_WIDTH, 196)
betList.BackgroundTransparency = 1
betList.BorderSizePixel = 0
betList.ScrollBarThickness = 4
betList.ScrollBarImageColor3 = COLORS.SubText
betList.AutomaticCanvasSize = Enum.AutomaticSize.Y
betList.CanvasSize = UDim2.new()
betList.Parent = betPage
local betLayout = Instance.new("UIListLayout")
betLayout.Padding = UDim.new(0, 6)
betLayout.SortOrder = Enum.SortOrder.LayoutOrder
betLayout.Parent = betList

local betBar = Instance.new("Frame")
betBar.Position = UDim2.fromOffset(0, 230)
betBar.Size = UDim2.fromOffset(CONTENT_WIDTH, 70)
betBar.BackgroundTransparency = 1
betBar.Parent = betPage

local chipButtons: { { button: TextButton, value: number? } } = {}
do
	local values: { number? } = {}
	for _, value in BET_CHIPS do
		table.insert(values, value)
	end
	table.insert(values, nil) -- MAX
	for index = 1, #BET_CHIPS + 1 do
		local value = values[index]
		local chip = pillButton(betBar, if value then tostring(value) else "MAX", COLORS.Dash, UDim2.fromOffset(62, 38))
		chip.Position = UDim2.fromOffset((index - 1) * 68, 0)
		chip.Activated:Connect(function()
			betChoice = value
			refresh()
		end)
		table.insert(chipButtons, { button = chip, value = value })
	end
end

local payoutText =
	label(betBar, UiTheme.FontHeavy, COLORS.Text, 15, UDim2.fromOffset(350, 0), UDim2.fromOffset(218, 34))
payoutText.TextXAlignment = Enum.TextXAlignment.Right

local placeButton = pillButton(betBar, "PLACE BET", COLORS.Dash, UDim2.fromOffset(200, 34))
placeButton.AnchorPoint = Vector2.new(1, 1)
placeButton.Position = UDim2.fromScale(1, 1)

-- Summary of the bet you placed this round.
local betSummary = card(betPage, "YourBet", UDim2.fromOffset(CONTENT_WIDTH, 120))
betSummary.Position = UDim2.fromOffset(0, 40)
betSummary.Visible = false
local summaryAvatar = Instance.new("ImageLabel")
summaryAvatar.Position = UDim2.fromOffset(18, 20)
summaryAvatar.Size = UDim2.fromOffset(80, 80)
summaryAvatar.BackgroundColor3 = COLORS.Panel
summaryAvatar.Parent = betSummary
UiTheme.corner(summaryAvatar, UDim.new(0.5, 0))
UiTheme.stroke(summaryAvatar, 2, COLORS.Dash)
local summaryTitle =
	label(betSummary, UiTheme.FontHeavy, COLORS.Text, 18, UDim2.fromOffset(116, 26), UDim2.fromOffset(430, 26))
summaryTitle.TextTruncate = Enum.TextTruncate.AtEnd
local summaryDetail =
	label(betSummary, UiTheme.Font, COLORS.Dash, 15, UDim2.fromOffset(116, 56), UDim2.fromOffset(430, 22))
local summaryNote =
	label(betSummary, UiTheme.FontBody, COLORS.SubText, 13, UDim2.fromOffset(116, 80), UDim2.fromOffset(430, 18))

local betRows: { [Player]: BetRow } = {}

local function strikesOf(player: Player): number
	local strikes = player:GetAttribute(ATTR.Strikes)
	return if typeof(strikes) == "number" then strikes else 0
end

local function kicksLeft(player: Player): number
	return math.max(Config.Strikes.ToExplode - strikesOf(player), 1)
end

-- The fighters still in the arena, sorted by name.
local function aliveFighters(): { Player }
	local list: { Player } = {}
	for _, player in Players:GetPlayers() do
		if player:GetAttribute(ATTR.InArena) == true then
			table.insert(list, player)
		end
	end
	table.sort(list, function(a: Player, b: Player): boolean
		return a.DisplayName < b.DisplayName
	end)
	return list
end

-- Exactly the multiplier the server would lock in right now (CombatMath.betMultiplier).
local function oddsFor(target: Player, fighters: { Player }): number
	local total = 0
	for _, fighter in fighters do
		total += kicksLeft(fighter)
	end
	local rewards = Config.Rewards
	return CombatMath.betMultiplier(total, kicksLeft(target), #fighters, rewards.BetHouseEdge, rewards.MinBetMultiplier)
end

local function betAmount(): number
	local choice = betChoice
	local cap = math.min(coins(), Config.Rewards.MaxBet)
	return if choice then math.min(choice, Config.Rewards.MaxBet) else cap
end

local function rowFor(player: Player): BetRow
	local existing = betRows[player]
	if existing then
		return existing
	end
	local button = Instance.new("TextButton")
	button.Name = player.Name
	button.AutoButtonColor = false
	button.Size = UDim2.new(1, -8, 0, 52)
	button.BackgroundColor3 = COLORS.Panel
	button.BackgroundTransparency = 0.55
	button.Text = ""
	button.Parent = betList
	UiTheme.corner(button, UDim.new(0, 12))
	local stroke = UiTheme.stroke(button, 2, COLORS.Dash, 1)

	local avatar = Instance.new("ImageLabel")
	avatar.Position = UDim2.fromOffset(8, 6)
	avatar.Size = UDim2.fromOffset(40, 40)
	avatar.BackgroundColor3 = COLORS.Panel
	avatar.Image = headshot(player.UserId)
	avatar.Parent = button
	UiTheme.corner(avatar, UDim.new(0.5, 0))

	local name = label(button, UiTheme.FontHeavy, COLORS.Text, 15, UDim2.fromOffset(58, 6), UDim2.fromOffset(300, 20))
	name.TextTruncate = Enum.TextTruncate.AtEnd
	local strikes = label(button, UiTheme.Font, COLORS.SubText, 13, UDim2.fromOffset(58, 28), UDim2.fromOffset(300, 16))
	local odds = label(button, UiTheme.FontHeavy, COLORS.Dash, 18, UDim2.new(1, -110, 0, 0), UDim2.fromOffset(96, 52))
	odds.TextXAlignment = Enum.TextXAlignment.Right

	button.Activated:Connect(function()
		betTarget = player
		refresh()
	end)

	local row: BetRow =
		{ player = player, button = button, stroke = stroke, name = name, strikes = strikes, odds = odds }
	betRows[player] = row
	return row
end

placeButton.Activated:Connect(function()
	local target = betTarget
	local amount = betAmount()
	local roundId = roundState:GetAttribute(STATE.RoundId)
	if target == nil or busy or amount < 1 or typeof(roundId) ~= "number" then
		return
	end
	if amount > coins() then
		setStatus("Not enough coins", COLORS.Danger)
		return
	end
	local preview = oddsFor(target, aliveFighters())
	local name = target.DisplayName
	local targetId = target.UserId
	request(function(): (boolean, string)
		local ok, message, multiplier = remotes.PlaceBet:InvokeServer(targetId, amount)
		if ok == true then
			myBet = {
				roundId = roundId,
				targetId = targetId,
				targetName = name,
				amount = amount,
				multiplier = if typeof(multiplier) == "number" then multiplier else preview,
			}
		end
		return answer(ok, message)
	end)
end)

local function refreshBet()
	local phase = roundState:GetAttribute(STATE.Phase)
	local roundId = roundState:GetAttribute(STATE.RoundId)
	local bet = myBet
	if bet and bet.roundId ~= roundId then
		myBet = nil -- a new round: last round's bet has been settled
		bet = nil
	end
	local fighters = aliveFighters()
	-- The server takes bets from the moment the round's fighters are in (Spawning) until the Final Duel.
	local open = (phase == "Spawning" or phase == "Active") and #fighters > 2 and not isTrue(ATTR.InArena)

	betSummary.Visible = bet ~= nil
	betList.Visible = bet == nil and open
	betBar.Visible = bet == nil and open
	betMessage.Visible = bet == nil and not open

	if bet then
		local payout = math.floor(bet.amount * bet.multiplier)
		summaryAvatar.Image = headshot(bet.targetId)
		summaryTitle.Text = `YOUR BET: {string.upper(bet.targetName)}`
		local outcome = bet.outcome
		local inProgress = phase == "Spawning" or phase == "Active" or phase == "FinalDuel"
		if outcome then
			summaryDetail.Text = if outcome.result == "Won"
				then `WON +{commas(outcome.coins)} COINS`
				elseif outcome.result == "Refunded" then `REFUNDED {commas(outcome.coins)} COINS`
				else `LOST {commas(bet.amount)} COINS`
			summaryDetail.TextColor3 = if outcome.result == "Lost" then COLORS.Danger else COLORS.Dash
			summaryNote.Text = "Settled. Bets open again when the next round starts."
		else
			summaryDetail.Text =
				string.format("%s coins at x%.1f · pays %s", commas(bet.amount), bet.multiplier, commas(payout))
			summaryDetail.TextColor3 = COLORS.Dash
			local target = Players:GetPlayerByUserId(bet.targetId)
			summaryNote.Text = if not inProgress
				then "Round over: settling your bet..."
				elseif
					target and target:GetAttribute(ATTR.InArena) == true
				then "Still fighting. Settled when the round ends."
				else "Out of the round. Settled when the round ends."
		end
		return
	end

	if not open then
		betMessage.Text = if phase == "FinalDuel" or (phase == "Active" and #fighters <= 2)
			then "Betting is closed: it's the Final Duel."
			elseif phase == "MatchEnd" then "Round over. Bets open again when the next round starts."
			else "Betting opens once a round starts, and closes at the Final Duel."
		return
	end

	-- Live rows: one per fighter, odds updated as strikes land.
	local alive: { [Player]: boolean } = {}
	for index, fighter in fighters do
		alive[fighter] = true
		local row = rowFor(fighter)
		row.button.LayoutOrder = index
		row.name.Text = fighter.DisplayName
		local left = math.max(Config.Strikes.ToExplode - strikesOf(fighter), 0)
		row.strikes.Text = if left == 1 then "ON THEIR LAST KICK" else `{left} KICKS LEFT`
		row.odds.Text = string.format("x%.1f", oddsFor(fighter, fighters))
		row.stroke.Transparency = if betTarget == fighter then 0 else 1
	end
	for player, row in betRows do
		if not alive[player] then
			row.button:Destroy()
			betRows[player] = nil
		end
	end
	local target = betTarget
	if target and not alive[target] then
		betTarget = nil
		target = nil
	end

	for _, chip in chipButtons do
		local selected = chip.value == betChoice
		chip.button.BackgroundTransparency = if selected then 0 else 0.6
		chip.button.TextColor3 = if selected then COLORS.Panel else COLORS.Text
	end
	local amount = betAmount()
	if target then
		local payout = math.floor(amount * oddsFor(target, fighters))
		payoutText.Text = `{commas(amount)} → PAYS {commas(payout)}`
	else
		payoutText.Text = "PICK A FIGHTER"
	end
	setButton(placeButton, "PLACE BET", target ~= nil and amount >= 1 and amount <= coins() and not busy)
end

-- Open / close / refresh ---------------------------------------------------------------------

function refresh()
	local snapshot = profile
	local inArena = isTrue(ATTR.InArena)
	local tab = activeTab
	local walletLine = frozenWallet
		or if snapshot
			then `{commas(snapshot.coins)} COINS  ·  {snapshot.crateKeys} KEY{if snapshot.crateKeys == 1
				then ""
				else "S"}`
			else "LOADING..."
	local gamepad = string.match(UserInputService:GetLastInputType().Name, "^Gamepad") ~= nil
	walletText.Text = if gamepad then `{walletLine}  ·  D-PAD UP: LOBBY` else walletLine
	headerWallet.Text = walletLine

	dock.Visible = not inArena and tab == nil
	wallet.Visible = not inArena and tab == nil
	holder.Visible = tab ~= nil

	for _, each: Tab in TABS do
		local selected = each == tab
		local button = tabButtons[each]
		button.BackgroundColor3 = if selected then TAB_ACCENT[each] else COLORS.Panel
		button.BackgroundTransparency = if selected then 0 else 0.4
		button.TextColor3 = if selected then COLORS.Panel else COLORS.SubText
		pages[each].Visible = selected
	end

	if tab == "Shop" then
		refreshShop()
	elseif tab == "Styles" then
		refreshStyles()
	elseif tab == "Crate" then
		refreshCrate()
	elseif tab == "Bet" then
		refreshBet()
	end
end

local function usingGamepad(): boolean
	return string.match(UserInputService:GetLastInputType().Name, "^Gamepad") ~= nil
end

local function openTab(tab: Tab)
	if isTrue(ATTR.InArena) or (spinning and tab ~= "Crate") then
		return -- (mid-spin: stay on the reel; the other tabs would show the result early)
	end
	if activeTab == nil then
		setStatus("")
		holder.Visible = true
	end
	activeTab = tab
	lastTab = tab
	refresh()
	if usingGamepad() then
		GuiService.SelectedObject = tabButtons[tab] -- start gamepad navigation inside the panel
	end
end

local function closePanel()
	if spinning then
		return -- let the reel land first; the result is already yours either way
	end
	activeTab = nil
	reel.Visible = false
	local selected = GuiService.SelectedObject
	if selected and selected:IsDescendantOf(gui) then
		GuiService.SelectedObject = nil
	end
	refresh()
end

for _, tab: Tab in TABS do
	dockButtons[tab].Activated:Connect(function()
		openTab(tab)
	end)
	tabButtons[tab].Activated:Connect(function()
		openTab(tab)
	end)
end
closeButton.Activated:Connect(closePanel)

-- Gamepad: D-pad up opens the lobby, L1 / R1 switch tabs, B closes. (Out of the arena
-- none of these are combat inputs.)
UserInputService.InputBegan:Connect(function(input: InputObject, gameProcessed: boolean)
	if isTrue(ATTR.InArena) or GuiService.MenuIsOpen then
		return -- (the Roblox menu uses these buttons too)
	end
	local key = input.KeyCode
	local tab = activeTab
	if tab == nil then
		if key == Enum.KeyCode.DPadUp and not gameProcessed then
			openTab(lastTab)
		end
	elseif key == Enum.KeyCode.ButtonB then
		closePanel()
	elseif key == Enum.KeyCode.ButtonL1 or key == Enum.KeyCode.ButtonR1 then
		local index = table.find(TABS, tab) or 1
		local step = if key == Enum.KeyCode.ButtonR1 then 1 else -1
		openTab(TABS[(index - 1 + step) % #TABS + 1])
	end
end)
UserInputService.LastInputTypeChanged:Connect(function()
	refresh() -- the dock's gamepad hint
end)

-- Going into the arena closes everything (the combat HUD takes over).
localPlayer:GetAttributeChangedSignal(ATTR.InArena):Connect(function()
	if isTrue(ATTR.InArena) then
		spinning = false -- the reel's result is already in the profile
		frozenWallet = nil
		activeTab = nil
		reel.Visible = false
		local selected = GuiService.SelectedObject
		if selected and selected:IsDescendantOf(gui) then
			GuiService.SelectedObject = nil
		end
	end
	refresh()
end)

roundState:GetAttributeChangedSignal(STATE.Phase):Connect(refresh)

-- Profile: one request at start (the server may still be loading it), then pushes.
remotes.ProfileUpdated.OnClientEvent:Connect(
	function(snapshot: Types.ProfileSnapshot, notice: string?, outcome: Types.BetOutcome?)
		profile = snapshot
		local bet = myBet
		if outcome and bet and bet.targetId == outcome.targetId then
			bet.outcome = outcome -- the BET tab's summary now shows how it ended
		end
		if notice then
			CombatFX.toast(string.upper(notice), COLORS.UltA)
			if activeTab then
				setStatus(notice, COLORS.UltA)
			end
		end
		refresh()
	end
)

task.spawn(function()
	for _ = 1, 15 do
		if profile then
			return
		end
		local ok, snapshot = pcall(function()
			return remotes.GetProfile:InvokeServer()
		end)
		if ok and typeof(snapshot) == "table" and profile == nil then
			profile = snapshot :: Types.ProfileSnapshot
			refresh()
			return
		end
		task.wait(2)
	end
end)

-- The BET tab tracks strikes and eliminations live while it's open.
local sinceBetRefresh = 0
RunService.Heartbeat:Connect(function(dt: number)
	sinceBetRefresh += dt
	if sinceBetRefresh >= BET_REFRESH then
		sinceBetRefresh = 0
		if activeTab == "Bet" then
			refreshBet()
		end
	end
end)

refresh()
