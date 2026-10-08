--!strict
--[[
	BettingService (ModuleScript, server)
	=====================================
	Eliminated players (and lobby spectators) bet Coins on who will win the
	current round. Odds are locked when the bet is placed:

	    multiplier = max(MinBetMultiplier, aliveAtBet * BetHouseEdge)

	so an early bet on a crowded arena pays a lot, and a late bet pays little.
	Betting closes at the Final Duel (2 alive) so nobody can farm near-certain
	outcomes. Coins are taken up front; a round with no single winner refunds.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage.Shared
local Config = require(Shared.Config)
local Net = require(Shared.Net)

local Guard = require(script.Parent.Parent.Util.Guard)
local RateLimiter = require(script.Parent.Parent.Util.RateLimiter)
local PlayerDataService = require(script.Parent.PlayerDataService)

type Bet = {
	targetId: number,
	amount: number,
	multiplier: number,
}

local BettingService = {}

local bets: { [Player]: Bet } = {}
local isOpen = false
local isAliveFn: ((Player) -> boolean)? = nil
local aliveCountFn: (() -> number)? = nil
local limiter = RateLimiter.new(Config.RateLimits.Lobby.rate, Config.RateLimits.Lobby.burst)

local function placeBet(player: Player, rawTargetId: unknown, rawAmount: unknown): (boolean, string)
	local isAlive, aliveCount = isAliveFn, aliveCountFn
	if not isOpen or isAlive == nil or aliveCount == nil then
		return false, "Betting is closed"
	end
	if isAlive(player) then
		return false, "You're still fighting!"
	end
	if bets[player] then
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
	local alive = aliveCount()
	if alive <= 2 then
		return false, "Betting closes at the Final Duel"
	end
	if not PlayerDataService.trySpend(player, amount) then
		return false, "Not enough coins"
	end

	local multiplier = math.max(Config.Rewards.MinBetMultiplier, alive * Config.Rewards.BetHouseEdge)
	bets[player] = { targetId = target.UserId, amount = amount, multiplier = multiplier }
	return true, string.format("Bet %d on %s at x%.1f", amount, target.DisplayName, multiplier)
end

-- Called by the RoundManager when a round goes live.
function BettingService.openRound(isAlive: (Player) -> boolean, aliveCount: () -> number)
	table.clear(bets)
	isAliveFn = isAlive
	aliveCountFn = aliveCount
	isOpen = true
end

-- Pays correct bets. `winner == nil` (timeout / no contest) refunds every bet.
function BettingService.settle(winner: Player?)
	isOpen = false
	for bettor, bet in bets do
		if bettor.Parent == nil then
			continue
		end
		if winner == nil then
			PlayerDataService.addCoins(bettor, bet.amount)
		elseif bet.targetId == winner.UserId then
			PlayerDataService.addCoins(bettor, math.floor(bet.amount * bet.multiplier))
		end
	end
	table.clear(bets)
end

function BettingService.init(remotes: Net.Remotes)
	remotes.PlaceBet.OnServerInvoke = function(
		player: Player,
		rawTargetId: unknown,
		rawAmount: unknown
	): (boolean, string)
		if not limiter:check(player) then
			return false, "Slow down"
		end
		return placeBet(player, rawTargetId, rawAmount)
	end
end

return BettingService
