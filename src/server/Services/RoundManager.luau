--!strict
--[[
	RoundManager (ModuleScript, server)
	===================================
	The game-loop state machine. It owns WHEN things happen; the active
	GameMode owns WHAT the rules are.

	    Waiting --(enough players)--> Intermission (15 s, lobby: upgrade / spin)
	      --> Spawning (teleport to arena) --> Active --(mode says final)--> FinalDuel
	      --(mode returns a result)--> MatchEnd (payouts, bets) --> Intermission ...

	Mode-agnostic responsibilities:
	  * choosing participants, teleporting, registering combatants
	  * the round context handed to the mode (alive set, eliminate())
	  * rewards for kills / parries / wins, bet settlement
	  * replicating phase state through attributes (late-join safe)

	Everything mode-specific (who may kick, who may be kicked, what a KO
	means, how a round is won) is delegated through the GameMode contract in
	ServerTypes. Adding Juggernaut = register one more GameMode.
]]

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage.Shared
local Config = require(Shared.Config)
local Net = require(Shared.Net)
local Types = require(Shared.Types)

local ServerTypes = require(script.Parent.Parent.ServerTypes)
local AbilityService = require(script.Parent.AbilityService)
local BettingService = require(script.Parent.BettingService)
local CombatService = require(script.Parent.CombatService)
local PlayerDataService = require(script.Parent.PlayerDataService)

type GameMode = ServerTypes.GameMode
type RoundContext = ServerTypes.RoundContext
type RoundResult = ServerTypes.RoundResult

type Round = {
	id: number,
	mode: GameMode,
	alive: { [Player]: boolean },
	participants: { Player },
	parryCoins: { [Player]: number }, -- parry income this round (capped)
	running: boolean,
}

local TICK = 0.1
local STATE = Net.StateAttributes

local RoundManager = {}

local modes: { [string]: GameMode } = {}
local rotationIndex = 0
local roundCounter = 0
local phase: Types.Phase = "Waiting"
local currentRound: Round? = nil
local currentContext: RoundContext? = nil
local remotes: Net.Remotes? = nil
local rng = Random.new()

local function now(): number
	return Workspace:GetServerTimeNow()
end

local function net(): Net.Remotes
	return assert(remotes, "RoundManager.init() has not run")
end

-- Replicated state ---------------------------------------------------------------------

local function setPhase(newPhase: Types.Phase, duration: number?)
	phase = newPhase
	local folder = Net.stateFolder()
	folder:SetAttribute(STATE.Phase, newPhase)
	folder:SetAttribute(STATE.PhaseEndsAt, if duration then now() + duration else 0)
end

local function countAlive(round: Round): number
	local count = 0
	for _ in round.alive do
		count += 1
	end
	return count
end

local function publishAliveCount(round: Round)
	Net.stateFolder():SetAttribute(STATE.AliveCount, countAlive(round))
end

-- Players & places ---------------------------------------------------------------------

local function hasLiveCharacter(player: Player): boolean
	local character = player.Character
	if character == nil then
		return false
	end
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	return humanoid ~= nil and humanoid.Health > 0 and character:FindFirstChild("HumanoidRootPart") ~= nil
end

local function eligiblePlayers(): { Player }
	local list = {}
	for _, player in Players:GetPlayers() do
		if PlayerDataService.isLoaded(player) and hasLiveCharacter(player) then
			table.insert(list, player)
		end
	end
	return list
end

local function shuffle<T>(list: { T })
	for index = #list, 2, -1 do
		local swap = rng:NextInteger(1, index)
		list[index], list[swap] = list[swap], list[index]
	end
end

-- Map authoring: tag BaseParts with Config.Tags.ArenaSpawn / LobbySpawn.
local function taggedParts(tag: string): { BasePart }
	local parts = {}
	for _, instance in CollectionService:GetTagged(tag) do
		if instance:IsA("BasePart") then
			table.insert(parts, instance)
		end
	end
	return parts
end

local function teleport(player: Player, spawnPart: BasePart?)
	local character = player.Character
	if character == nil then
		return
	end
	local destination = if spawnPart then spawnPart.CFrame + Vector3.new(0, 4, 0) else CFrame.new(0, 10, 0)
	character:PivotTo(destination)
end

local function sendToLobby(player: Player)
	if player.Parent == nil then
		return
	end
	local spawns = taggedParts(Config.Tags.LobbySpawn)
	teleport(player, if #spawns > 0 then spawns[rng:NextInteger(1, #spawns)] else nil)
end

-- Round context (what a GameMode is allowed to do) -----------------------------------------------

local function eliminate(round: Round, victim: Player, killer: Player?, cause: ServerTypes.DefeatCause?)
	if not round.alive[victim] then
		return
	end
	round.alive[victim] = nil
	CombatService.unregisterCombatant(victim)
	publishAliveCount(round)

	if killer and killer ~= victim and killer.Parent then
		PlayerDataService.addCoins(killer, Config.Rewards.CoinsPerKill)
		PlayerDataService.recordKill(killer)
	end

	local payload: Types.RoundEventPayload = {
		kind = "Eliminated",
		userId = victim.UserId,
		killerId = if killer then killer.UserId else nil,
		displayName = victim.DisplayName,
		cause = cause,
	}
	net().RoundEvent:FireAllClients(payload)

	-- Let the KO fling play, then send them to the lobby to spectate and bet.
	task.delay(Config.Round.EliminationReturnDelay, function()
		local active = currentRound
		if active == nil or not active.alive[victim] then
			sendToLobby(victim)
		end
	end)
end

local function makeContext(round: Round): RoundContext
	return {
		roundId = round.id,
		getAlive = function(): { Player }
			local list = {}
			for player in round.alive do
				table.insert(list, player)
			end
			return list
		end,
		isAlive = function(player: Player): boolean
			return round.alive[player] == true
		end,
		isRunning = function(): boolean
			return round.running and currentRound == round
		end,
		eliminate = function(victim: Player, killer: Player?, cause: ServerTypes.DefeatCause?)
			eliminate(round, victim, killer, cause)
		end,
	}
end

-- Phases ---------------------------------------------------------------------------

local function nextMode(): GameMode
	local rotation = Config.Round.ModeRotation
	for _ = 1, #rotation do
		rotationIndex = rotationIndex % #rotation + 1
		local mode = modes[rotation[rotationIndex]]
		if mode then
			return mode
		end
	end
	error("RoundManager: no registered GameMode matches Config.Round.ModeRotation")
end

local function waitForPlayers(minPlayers: number)
	if #eligiblePlayers() >= minPlayers then
		return
	end
	setPhase("Waiting")
	repeat
		task.wait(1)
	until #eligiblePlayers() >= minPlayers
end

-- Runs a timed phase. Returns false if `abortIf` fired before the timer ran out.
local function countdown(newPhase: Types.Phase, duration: number, abortIf: (() -> boolean)?): boolean
	setPhase(newPhase, duration)
	local endsAt = now() + duration
	while now() < endsAt do
		if abortIf and abortIf() then
			return false
		end
		task.wait(TICK)
	end
	return true
end

-- Ticks the mode until it reports a result (or the failsafe timer expires).
local function runActive(round: Round, ctx: RoundContext): RoundResult
	setPhase("Active")
	round.mode:onRoundStart(ctx)

	local startedAt = now()
	local lastTick = os.clock()
	while true do
		local result = round.mode:getResult(ctx)
		if result then
			return result
		end
		if now() - startedAt > Config.Round.MaxActiveTime then
			-- Out of time: the survivor(s) with the fewest strikes win, rather than a NO
			-- CONTEST that erases a long round. An exact tie shares the payout (and refunds bets).
			local best, winners = math.huge, {}
			for _, player in ctx.getAlive() do
				local strikes = CombatService.getStrikes(player) or math.huge
				if strikes < best then
					best, winners = strikes, { player }
				elseif strikes == best then
					table.insert(winners, player)
				end
			end
			return { winners = winners, reason = "Timeout" }
		end
		if phase == "Active" and round.mode:isFinalPhase(ctx) then
			setPhase("FinalDuel") -- clients shift FOV + swap music on this attribute
		end

		local clock = os.clock()
		round.mode:onTick(ctx, clock - lastTick)
		lastTick = clock
		task.wait(TICK)
	end
end

local function finishRound(round: Round, ctx: RoundContext, result: RoundResult)
	round.running = false
	round.mode:onRoundEnd(ctx)
	CombatService.setRules(nil)
	CombatService.reset()

	local winners = result.winners
	for _, winner in winners do
		if winner.Parent then
			PlayerDataService.addCoins(winner, math.floor(Config.Rewards.WinPayout / #winners))
			PlayerDataService.recordWin(winner)
		end
	end
	for _, participant in round.participants do
		if participant.Parent then
			PlayerDataService.addCoins(participant, Config.Rewards.Participation)
		end
	end
	-- A timeout is decided by visible strikes, so a last-second bet on the leader would be
	-- free money: refund every bet on a timeout, pay out only real last-standing wins.
	BettingService.settle(if #winners == 1 and result.reason ~= "Timeout" then winners[1] else nil)

	local payload: Types.RoundEventPayload
	if #winners == 1 then
		payload = { kind = "Winner", userId = winners[1].UserId, displayName = winners[1].DisplayName }
	elseif #winners > 1 then
		local names = {}
		for _, winner in winners do
			table.insert(names, winner.DisplayName)
		end
		payload = { kind = "Draw", displayName = table.concat(names, " & ") }
	else
		payload = { kind = "NoContest" }
	end
	net().RoundEvent:FireAllClients(payload)

	countdown("MatchEnd", Config.Round.MatchEndTime)
	-- Eliminated players are already in the lobby; bring the survivors home.
	for survivor in round.alive do
		sendToLobby(survivor)
	end
	currentRound = nil
	currentContext = nil
end

local function runRound()
	local mode = nextMode()
	Net.stateFolder():SetAttribute(STATE.Mode, mode.name)

	-- 1. Intermission (restarts if the lobby empties out mid-countdown)
	waitForPlayers(mode.minPlayers)
	local tooFew = function(): boolean
		return #eligiblePlayers() < mode.minPlayers
	end
	if not countdown("Intermission", Config.Round.IntermissionTime, tooFew) then
		return
	end

	local arenaSpawns = taggedParts(Config.Tags.ArenaSpawn)
	if #arenaSpawns == 0 then
		warn(`[RoundManager] no BaseParts tagged "{Config.Tags.ArenaSpawn}"; cannot start a round`)
		task.wait(5)
		return
	end

	-- 2. Spawn phase: pick up to MaxPlayers, teleport, then hand them to CombatService
	local candidates = eligiblePlayers()
	shuffle(candidates)
	shuffle(arenaSpawns)

	roundCounter += 1
	local round: Round =
		{ id = roundCounter, mode = mode, alive = {}, participants = {}, parryCoins = {}, running = true }
	local ctx = makeContext(round)
	currentRound = round
	currentContext = ctx

	for index, player in candidates do
		if index > Config.Round.MaxPlayers then
			break
		end
		teleport(player, arenaSpawns[(index - 1) % #arenaSpawns + 1])
		if CombatService.registerCombatant(player) then
			round.alive[player] = true
			table.insert(round.participants, player)
		end
	end

	if countAlive(round) < mode.minPlayers then
		CombatService.reset()
		for _, participant in round.participants do
			sendToLobby(participant)
		end
		currentRound = nil
		currentContext = nil
		return
	end

	Net.stateFolder():SetAttribute(STATE.RoundId, round.id)
	publishAliveCount(round)
	AbilityService.resetRound()
	BettingService.openRound(ctx.isAlive, ctx.getAlive)
	CombatService.setRules({
		-- Nobody kicks during the spawn countdown; once the fight is on, the mode decides.
		canLaunch = function(player: Player): boolean
			return round.running
				and (phase == "Active" or phase == "FinalDuel")
				and round.alive[player] == true
				and mode:canLaunch(ctx, player)
		end,
		canTarget = function(attacker: Player, target: Player): boolean
			return round.alive[attacker] == true
				and round.alive[target] == true
				and mode:canTarget(ctx, attacker, target)
		end,
	})

	countdown("Spawning", Config.Round.SpawnPhaseTime)

	-- 3-4. Active (+ Final Duel), 5. Match end
	local result = runActive(round, ctx)
	finishRound(round, ctx, result)
end

-- Public API -------------------------------------------------------------------------

function RoundManager.registerMode(mode: GameMode)
	assert(modes[mode.name] == nil, `GameMode "{mode.name}" registered twice`)
	modes[mode.name] = mode
end

function RoundManager.getPhase(): Types.Phase
	return phase
end

function RoundManager.init(netRemotes: Net.Remotes)
	remotes = netRemotes
	setPhase("Waiting")

	-- Combat -> mode: what a KO means is the mode's call.
	CombatService.Defeated:Connect(function(victim: Player, attacker: Player?, cause: ServerTypes.DefeatCause)
		local round, ctx = currentRound, currentContext
		if round and ctx and round.running and round.alive[victim] then
			round.mode:onDefeated(ctx, victim, attacker, cause)
		end
	end)

	-- A strike landed but the victim survived it: pay the attacker, let the mode react.
	CombatService.Struck:Connect(function(victim: Player, attacker: Player, strikes: number)
		local round, ctx = currentRound, currentContext
		if round == nil or ctx == nil or not round.running or not round.alive[victim] then
			return
		end
		if attacker.Parent then
			PlayerDataService.addCoins(attacker, Config.Rewards.CoinsPerHit)
		end
		round.mode:onStruck(ctx, victim, attacker, strikes)
	end)

	-- Combat -> economy + mode
	CombatService.Parried:Connect(function(defender: Player, attacker: Player, perfect: boolean, _rally: number)
		local round, ctx = currentRound, currentContext
		if round == nil or ctx == nil or not round.running then
			return
		end
		-- Capped per round: with everyone able to kick, friends could otherwise trade
		-- parries (and harmless head-on clashes) all round for unlimited coins.
		local earned = round.parryCoins[defender] or 0
		local reward = math.min(
			Config.Rewards.CoinsPerParry + (if perfect then Config.Rewards.CoinsPerPerfect else 0),
			Config.Rewards.MaxParryCoinsPerRound - earned
		)
		if reward > 0 then
			round.parryCoins[defender] = earned + reward
			PlayerDataService.addCoins(defender, reward)
		end
		round.mode:onParried(ctx, defender, attacker, perfect)
	end)

	-- Safety net: a player who leaves is always removed from the alive set,
	-- even if the mode forgot to eliminate them.
	Players.PlayerRemoving:Connect(function(player: Player)
		-- Read the kill credit NOW: if this handler runs before CombatService's,
		-- the fighter (and who knocked them off) is still tracked. Leaving right
		-- after being knocked off must still pay the attacker.
		local credit = CombatService.getRecentAttacker(player)
		task.defer(function()
			local round = currentRound
			if round and round.alive[player] then
				eliminate(round, player, credit, "Left")
			end
		end)
	end)
end

function RoundManager.start()
	task.spawn(function()
		while true do
			-- A bug in one round must never kill the server's game loop.
			local ok = xpcall(runRound, function(err: unknown)
				warn("[RoundManager] round crashed:", err, debug.traceback())
			end)
			if not ok then
				CombatService.setRules(nil)
				CombatService.reset()
				currentRound = nil
				currentContext = nil
				task.wait(3)
			end
		end
	end)
end

return RoundManager
