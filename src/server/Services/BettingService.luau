--!strict
--[[
	BettingService (ModuleScript, server)
	=====================================
	Eliminated players (and lobby spectators) bet Coins on who will win the
	current round. Odds are locked when the bet is placed and priced by the
	target's share of the kicks the arena can still take before exploding
	(strikes are public, so flat odds would make backing the untouched fighter
	free money); see CombatMath.betMultiplier, which the lobby UI also uses
	for its preview:

	    multiplier = clamp(BetHouseEdge * totalKicksLeft / targetKicksLeft,
	                       MinBetMultiplier, aliveAtBet * BetHouseEdge)

	With nobody struck yet that is aliveAtBet * BetHouseEdge: an early bet on a
	crowded arena pays a lot. An untouched favourite pays less, and an
	underdog's payout never exceeds the crowded-arena maximum. Every bettor
	still in the server is told how their bet ended (PlayerDataService.notify).
	Bets are keyed by UserId, so a bettor who drops and rejoins mid-round is
	still settled (and can't bet twice).
	Betting closes at the Final Duel (2 alive) so nobody can farm near-certain
	outcomes. Coins are taken up front; a round with no single winner refunds.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Players = game:GetService("Players")

local Shared = ReplicatedStorage.Shared
local CombatMath = require(Shared.CombatMath)
local Config = require(Shared.Config)
local Net = require(Shared.Net)
local Types = require(Shared.Types)

local Guard = require(script.Parent.Parent.Util.Guard)
local RateLimiter = require(script.Parent.Parent.Util.RateLimiter)
local PlayerDataService = require(script.Parent.PlayerDataService)

type Bet = {
	targetId: number,
	targetName: string,
	amount: number,
	multiplier: number,
}

local BettingService = {}

local bets: { [number]: Bet } = {} -- by bettor UserId
local isOpen = false
local isAliveFn: ((Player) -> boolean)? = nil
local getAliveFn: (() -> { Player })? = nil
local limiter = RateLimiter.new(Config.RateLimits.Lobby.rate, Config.RateLimits.Lobby.burst)

local function placeBet(player: Player, rawTargetId: unknown, rawAmount: unknown): (boolean, string, number?)
	local isAlive, getAlive = isAliveFn, getAliveFn
	if not isOpen or isAlive == nil or getAlive == nil then
		return false, "Betting is closed"
	end
	if isAlive(player) then
		return false, "You're still fighting!"
	end
	if bets[player.UserId] then
		return false, "You already placed a bet this round"
	end
	local target = Guard.player(rawTargetId)
	if target == nil or not isAlive(target) then
		return false, "That fighter isn't in the arena"
	end
	local amount = Guard.integer(rawAmount, 1, Config.Rewards.MaxBet)
	if amount == nil then
		return false, "Invalid amount"
	end
	local alivePlayers = getAlive()
	local alive = #alivePlayers
	if alive <= 2 then
		return false, "Betting closes at the Final Duel"
	end
	if not PlayerDataService.trySpend(player, amount) then
		return false, "Not enough coins"
	end

	-- Kicks a fighter can still take before exploding. The strike count is a
	-- server-set attribute, so it can be trusted here.
	local function kicksLeft(player: Player): number
		local strikes = player:GetAttribute(Net.Attributes.Strikes)
		local taken = if typeof(strikes) == "number" then strikes else 0
		return math.max(Config.Strikes.ToExplode - taken, 1)
	end
	local totalLeft = 0
	for _, player in alivePlayers do
		totalLeft += kicksLeft(player)
	end
	local rewards = Config.Rewards
	local multiplier =
		CombatMath.betMultiplier(totalLeft, kicksLeft(target), alive, rewards.BetHouseEdge, rewards.MinBetMultiplier)
	bets[player.UserId] = {
		targetId = target.UserId,
		targetName = target.DisplayName,
		amount = amount,
		multiplier = multiplier,
	}
	return true, string.format("Bet %d on %s at x%.1f", amount, target.DisplayName, multiplier), multiplier
end

-- Called by the RoundManager when a round goes live.
function BettingService.openRound(isAlive: (Player) -> boolean, getAlive: () -> { Player })
	table.clear(bets)
	isAliveFn = isAlive
	getAliveFn = getAlive
	isOpen = true
end

--[[
	Pays correct bets. `winner == nil` refunds every bet; `refundReason` says why
	("Time ran out", "It ended in a draw", ...). Bettors who left the server are
	skipped: their profile is already saved and released.
]]
function BettingService.settle(winner: Player?, refundReason: string?)
	isOpen = false
	for bettorId, bet in bets do
		local bettor = Players:GetPlayerByUserId(bettorId)
		if bettor == nil or not PlayerDataService.isLoaded(bettor) then
			continue
		end
		local outcome: Types.BetOutcome
		if winner == nil then
			PlayerDataService.addCoins(bettor, bet.amount)
			outcome = { result = "Refunded", coins = bet.amount, targetId = bet.targetId }
			PlayerDataService.notify(
				bettor,
				`{refundReason or "No winner"}: your {bet.amount} coins are refunded`,
				outcome
			)
		elseif bet.targetId == winner.UserId then
			local payout = math.floor(bet.amount * bet.multiplier)
			PlayerDataService.addCoins(bettor, payout)
			outcome = { result = "Won", coins = payout, targetId = bet.targetId }
			PlayerDataService.notify(bettor, `Your bet on {bet.targetName} won: +{payout} coins`, outcome)
		else
			outcome = { result = "Lost", coins = 0, targetId = bet.targetId }
			PlayerDataService.notify(bettor, `Your bet on {bet.targetName} lost`, outcome)
		end
	end
	table.clear(bets)
end

function BettingService.init(remotes: Net.Remotes)
	remotes.PlaceBet.OnServerInvoke = function(
		player: Player,
		rawTargetId: unknown,
		rawAmount: unknown
	): (boolean, string, number?)
		if not limiter:check(player) then
			return false, "Slow down", nil
		end
		return placeBet(player, rawTargetId, rawAmount)
	end
end

return BettingService
