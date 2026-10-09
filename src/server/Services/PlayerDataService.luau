--!strict
--[[
	PlayerDataService (ModuleScript, server)
	========================================
	Coins, stat upgrades, owned/equipped Leg Styles and crate keys.

	Persistence here is deliberately simple (DataStore Get/Set with retries) so
	the foundations run anywhere, including Studio without API access. Before
	launch, swap the load/save internals for a session-locked library such as
	ProfileStore; the public API below does not need to change.

	Every economy action is server-side: the client only *asks* through the
	lobby RemoteFunctions, and every argument is validated and rate-limited.
	Whenever a profile changes, its owner is sent a fresh snapshot
	(ProfileUpdated, coalesced to one per frame), so the lobby UI never polls.
]]

local DataStoreService = game:GetService("DataStoreService")
local MarketplaceService = game:GetService("MarketplaceService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage.Shared
local AbilityData = require(Shared.AbilityData)
local Config = require(Shared.Config)
local Net = require(Shared.Net)
local Types = require(Shared.Types)
local UpgradeData = require(Shared.UpgradeData)

local Guard = require(script.Parent.Parent.Util.Guard)
local RateLimiter = require(script.Parent.Parent.Util.RateLimiter)

local STORE_NAME = "ClashKick_Profiles_v1"
local AUTOSAVE_INTERVAL = 120
local LOAD_RETRIES = 3
local MAX_RECEIPT_HISTORY = 50

export type Profile = {
	Coins: number,
	CrateKeys: number,
	Upgrades: { [string]: number }, -- StatId -> level
	OwnedStyles: { [string]: boolean },
	EquippedStyle: string,
	Wins: number,
	Kills: number,
	Receipts: { string }, -- recent PurchaseIds, makes ProcessReceipt idempotent
}

export type ProfileSnapshot = Types.ProfileSnapshot

local PlayerDataService = {}

local profiles: { [Player]: Profile } = {}
local remotes: Net.Remotes? = nil
type PendingPush = { notice: string?, bet: Types.BetOutcome? }
local pendingPush: { [Player]: PendingPush } = {} -- coalesces pushes to one per frame
local lobbyLimiter = RateLimiter.new(Config.RateLimits.Lobby.rate, Config.RateLimits.Lobby.burst)
local rng = Random.new()

local store: DataStore? = nil
do
	-- GetDataStore throws in Studio when API access is disabled; play on with in-memory data.
	local ok, result = pcall(function(): DataStore
		return DataStoreService:GetDataStore(STORE_NAME)
	end)
	if ok then
		store = result
	else
		warn("[PlayerDataService] DataStore unavailable, using in-memory profiles:", result)
	end
end

local function defaultProfile(): Profile
	return {
		Coins = 0,
		CrateKeys = 0,
		Upgrades = { WalkSpeed = 0, JumpPower = 0, ParryWindow = 0 },
		OwnedStyles = { [AbilityData.DefaultStyleId] = true },
		EquippedStyle = AbilityData.DefaultStyleId,
		Wins = 0,
		Kills = 0,
		Receipts = {},
	}
end

local function nonNegativeInteger(value: unknown, fallback: number): number
	if typeof(value) == "number" and value == value and value >= 0 and value < 2 ^ 53 then
		return math.floor(value)
	end
	return fallback
end

-- Rebuilds a profile from whatever was stored, dropping anything malformed.
local function reconcile(raw: unknown): Profile
	local profile = defaultProfile()
	if typeof(raw) ~= "table" then
		return profile
	end
	local data = raw :: { [string]: unknown }

	profile.Coins = nonNegativeInteger(data.Coins, 0)
	profile.CrateKeys = nonNegativeInteger(data.CrateKeys, 0)
	profile.Wins = nonNegativeInteger(data.Wins, 0)
	profile.Kills = nonNegativeInteger(data.Kills, 0)

	local upgrades = data.Upgrades
	if typeof(upgrades) == "table" then
		for _, stat: UpgradeData.StatId in UpgradeData.Order do
			local level = nonNegativeInteger((upgrades :: { [string]: unknown })[stat], 0)
			profile.Upgrades[stat] = math.min(level, UpgradeData.Stats[stat].maxLevel)
		end
	end

	local owned = data.OwnedStyles
	if typeof(owned) == "table" then
		for styleId, isOwned in owned :: { [unknown]: unknown } do
			if typeof(styleId) == "string" and isOwned == true and AbilityData.get(styleId) then
				profile.OwnedStyles[styleId] = true
			end
		end
	end

	local equipped = data.EquippedStyle
	if typeof(equipped) == "string" and profile.OwnedStyles[equipped] then
		profile.EquippedStyle = equipped
	end

	local receipts = data.Receipts
	if typeof(receipts) == "table" then
		for _, purchaseId in receipts :: { unknown } do
			if typeof(purchaseId) == "string" then
				table.insert(profile.Receipts, purchaseId)
			end
		end
	end

	return profile
end

local function keyFor(player: Player): string
	return "Player_" .. player.UserId
end

local function loadProfile(player: Player): Profile
	local dataStore = store
	if dataStore == nil then
		return defaultProfile()
	end
	for attempt = 1, LOAD_RETRIES do
		local ok, result = pcall(function(): unknown
			return dataStore:GetAsync(keyFor(player))
		end)
		if ok then
			return reconcile(result)
		end
		warn(`[PlayerDataService] load attempt {attempt} failed for {player.Name}: {result}`)
		task.wait(attempt)
	end
	return defaultProfile()
end

local function saveProfile(player: Player)
	local dataStore = store
	local profile = profiles[player]
	if dataStore == nil or profile == nil then
		return
	end
	local ok, err = pcall(function()
		dataStore:SetAsync(keyFor(player), profile, { player.UserId })
	end)
	if not ok then
		warn(`[PlayerDataService] save failed for {player.Name}: {err}`)
	end
end

local function getOrCreateValue(parent: Instance, name: string): IntValue
	local existing = parent:FindFirstChild(name)
	if existing and existing:IsA("IntValue") then
		return existing
	end
	local value = Instance.new("IntValue")
	value.Name = name
	value.Parent = parent
	return value
end

-- leaderstats drives the default player list and the coin counter in the HUD.
local function syncLeaderstats(player: Player)
	local profile = profiles[player]
	if profile == nil then
		return
	end
	local folder = player:FindFirstChild("leaderstats")
	if folder == nil then
		local created = Instance.new("Folder")
		created.Name = "leaderstats"
		created.Parent = player
		folder = created
	end
	assert(folder, "leaderstats folder")
	getOrCreateValue(folder, "Coins").Value = profile.Coins
	getOrCreateValue(folder, "Wins").Value = profile.Wins
end

-- Applies upgrade levels to the humanoid. The server sets these; the movement
-- sanity check in CombatService catches a client that raises them locally.
local function applyStats(player: Player)
	local profile = profiles[player]
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if profile == nil or humanoid == nil then
		return
	end
	humanoid.WalkSpeed = UpgradeData.valueAt("WalkSpeed", profile.Upgrades.WalkSpeed or 0)
	humanoid.UseJumpPower = true
	humanoid.JumpPower = UpgradeData.valueAt("JumpPower", profile.Upgrades.JumpPower or 0)
end

local function snapshot(profile: Profile): ProfileSnapshot
	local owned = {}
	for styleId in profile.OwnedStyles do
		table.insert(owned, styleId)
	end
	table.sort(owned)
	return {
		coins = profile.Coins,
		crateKeys = profile.CrateKeys,
		upgrades = table.clone(profile.Upgrades),
		ownedStyles = owned,
		equippedStyle = profile.EquippedStyle,
		wins = profile.Wins,
		kills = profile.Kills,
	}
end

--[[
	Send the owner a fresh snapshot. Many changes can land in one frame (a kill
	pays coins, a bet settles), so pushes are coalesced: the first change in a
	frame schedules one deferred send, and the latest notice wins.
]]
local function pushProfile(player: Player, notice: string?, bet: Types.BetOutcome?)
	local pending = pendingPush[player]
	if pending then
		pending.notice = notice or pending.notice
		pending.bet = bet or pending.bet
		return
	end
	pendingPush[player] = { notice = notice, bet = bet }
	task.defer(function()
		local entry = pendingPush[player]
		pendingPush[player] = nil
		local profile = profiles[player]
		local net = remotes
		if entry and profile and net and player.Parent then
			net.ProfileUpdated:FireClient(player, snapshot(profile), entry.notice, entry.bet)
		end
	end)
end

-- Public API -------------------------------------------------------------------

-- Tell the owner something about their coins (e.g. "Your bet won +240"); also refreshes their
-- snapshot. `bet` carries a settled bet's outcome for the lobby's bet summary.
function PlayerDataService.notify(player: Player, notice: string, bet: Types.BetOutcome?)
	if profiles[player] then
		pushProfile(player, notice, bet)
	end
end

function PlayerDataService.get(player: Player): Profile?
	return profiles[player]
end

function PlayerDataService.isLoaded(player: Player): boolean
	return profiles[player] ~= nil
end

function PlayerDataService.addCoins(player: Player, amount: number)
	local profile = profiles[player]
	if profile == nil or amount == 0 then
		return
	end
	profile.Coins = math.max(0, profile.Coins + math.floor(amount))
	syncLeaderstats(player)
	pushProfile(player)
end

-- Deducts `amount` only if the player can afford it. Returns success.
function PlayerDataService.trySpend(player: Player, amount: number): boolean
	local profile = profiles[player]
	if profile == nil or amount < 0 or profile.Coins < amount then
		return false
	end
	profile.Coins -= amount
	syncLeaderstats(player)
	pushProfile(player)
	return true
end

function PlayerDataService.recordWin(player: Player)
	local profile = profiles[player]
	if profile then
		profile.Wins += 1
		syncLeaderstats(player)
		pushProfile(player)
	end
end

function PlayerDataService.recordKill(player: Player)
	local profile = profiles[player]
	if profile then
		profile.Kills += 1
		pushProfile(player)
	end
end

-- Seconds added to Config.Parry.BaseWindow for this player.
function PlayerDataService.getParryWindowBonus(player: Player): number
	local profile = profiles[player]
	return if profile then UpgradeData.valueAt("ParryWindow", profile.Upgrades.ParryWindow or 0) else 0
end

function PlayerDataService.getEquippedStyle(player: Player): string
	local profile = profiles[player]
	return if profile then profile.EquippedStyle else AbilityData.DefaultStyleId
end

-- Lobby remote handlers ------------------------------------------------------------

local function purchaseUpgrade(player: Player, rawStat: unknown): (boolean, string)
	local profile = profiles[player]
	local stat: UpgradeData.StatId? = UpgradeData.parseStat(rawStat)
	if profile == nil or stat == nil then
		return false, "Invalid upgrade"
	end
	local level = profile.Upgrades[stat] or 0
	local cost = UpgradeData.costFor(stat, level)
	if cost == nil then
		return false, "Already maxed"
	end
	if not PlayerDataService.trySpend(player, cost) then
		return false, "Not enough coins"
	end
	profile.Upgrades[stat] = level + 1
	applyStats(player)
	pushProfile(player)
	return true, `{UpgradeData.Stats[stat].displayName} is now level {level + 1}`
end

local function spinCrate(player: Player): (boolean, string, boolean)
	local profile = profiles[player]
	if profile == nil or profile.CrateKeys <= 0 then
		return false, "No crate keys", false
	end
	profile.CrateKeys -= 1
	local style = AbilityData.rollCrate(rng)
	local duplicate = profile.OwnedStyles[style.id] == true
	if duplicate then
		PlayerDataService.addCoins(player, Config.Monetization.DuplicateRefundCoins)
	else
		profile.OwnedStyles[style.id] = true
	end
	pushProfile(player)
	return true, style.id, duplicate
end

-- The free path to crates: one key for Config.Monetization.KeyCoinPrice Coins (0 disables it).
local function buyCrateKey(player: Player): (boolean, string)
	local profile = profiles[player]
	local price = Config.Monetization.KeyCoinPrice
	if profile == nil then
		return false, "Profile still loading"
	end
	if price <= 0 then
		return false, "Keys can't be bought with Coins"
	end
	if not PlayerDataService.trySpend(player, price) then
		return false, "Not enough coins"
	end
	profile.CrateKeys += 1
	pushProfile(player)
	return true, "Crate key bought"
end

local function equipStyle(player: Player, rawStyleId: unknown): (boolean, string)
	local profile = profiles[player]
	local styleId = Guard.shortString(rawStyleId, 32)
	if profile == nil or styleId == nil or not profile.OwnedStyles[styleId] then
		return false, "You don't own that style"
	end
	-- Uses per round are counted against whatever is equipped, so swapping mid-round
	-- would let one round stack two styles' activations. Change styles in the lobby.
	if player:GetAttribute(Net.Attributes.InArena) == true then
		return false, "Change styles between rounds"
	end
	profile.EquippedStyle = styleId
	player:SetAttribute(Net.Attributes.LegStyle, styleId)
	pushProfile(player)
	local style = AbilityData.get(styleId)
	return true, `{if style then style.displayName else styleId} equipped`
end

-- Developer Product receipts (crate keys). Idempotent via the receipt history.
local function processReceipt(receiptInfo: { [string]: any }): Enum.ProductPurchaseDecision
	local player = Players:GetPlayerByUserId(receiptInfo.PlayerId)
	local profile = player and profiles[player]
	if player == nil or profile == nil then
		return Enum.ProductPurchaseDecision.NotProcessedYet -- retried on next join
	end
	local purchaseId = tostring(receiptInfo.PurchaseId)
	if table.find(profile.Receipts, purchaseId) then
		return Enum.ProductPurchaseDecision.PurchaseGranted
	end
	if receiptInfo.ProductId ~= Config.Monetization.CrateKeyProductId then
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end

	profile.CrateKeys += Config.Monetization.KeysPerPurchase
	table.insert(profile.Receipts, purchaseId)
	if #profile.Receipts > MAX_RECEIPT_HISTORY then
		table.remove(profile.Receipts, 1)
	end
	saveProfile(player)
	pushProfile(player, "Crate key added")
	return Enum.ProductPurchaseDecision.PurchaseGranted
end

function PlayerDataService.init(netRemotes: Net.Remotes)
	remotes = netRemotes
	local function onPlayerAdded(player: Player)
		local profile = loadProfile(player)
		if player.Parent == nil then
			return -- left while loading
		end
		profiles[player] = profile
		syncLeaderstats(player)
		player:SetAttribute(Net.Attributes.LegStyle, profile.EquippedStyle)
		pushProfile(player) -- the client may have asked GetProfile before this loaded
		player.CharacterAdded:Connect(function()
			applyStats(player)
		end)
		applyStats(player)
	end

	Players.PlayerAdded:Connect(onPlayerAdded)
	for _, player in Players:GetPlayers() do
		task.spawn(onPlayerAdded, player)
	end

	Players.PlayerRemoving:Connect(function(player: Player)
		saveProfile(player)
		profiles[player] = nil
		pendingPush[player] = nil
	end)

	game:BindToClose(function()
		for player in profiles do
			task.spawn(saveProfile, player)
		end
		task.wait(3)
	end)

	task.spawn(function()
		while true do
			task.wait(AUTOSAVE_INTERVAL)
			for player in profiles do
				task.spawn(saveProfile, player)
			end
		end
	end)

	-- Every lobby RemoteFunction is rate-limited and returns plain data only.
	netRemotes.GetProfile.OnServerInvoke = function(player: Player): ProfileSnapshot?
		local profile = profiles[player]
		if profile == nil or not lobbyLimiter:check(player) then
			return nil
		end
		return snapshot(profile)
	end
	netRemotes.PurchaseUpgrade.OnServerInvoke = function(player: Player, rawStat: unknown): (boolean, string)
		if not lobbyLimiter:check(player) then
			return false, "Slow down"
		end
		return purchaseUpgrade(player, rawStat)
	end
	netRemotes.SpinCrate.OnServerInvoke = function(player: Player): (boolean, string, boolean)
		if not lobbyLimiter:check(player) then
			return false, "Slow down", false
		end
		return spinCrate(player)
	end
	netRemotes.BuyCrateKey.OnServerInvoke = function(player: Player): (boolean, string)
		if not lobbyLimiter:check(player) then
			return false, "Slow down"
		end
		return buyCrateKey(player)
	end
	netRemotes.EquipLegStyle.OnServerInvoke = function(player: Player, rawStyleId: unknown): (boolean, string)
		if not lobbyLimiter:check(player) then
			return false, "Slow down"
		end
		return equipStyle(player, rawStyleId)
	end

	MarketplaceService.ProcessReceipt = processReceipt
end

return PlayerDataService
