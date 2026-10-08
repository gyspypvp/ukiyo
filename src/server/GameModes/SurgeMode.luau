--!strict
--[[
	SurgeMode (ModuleScript, server): Free-For-All Rally
	=====================================================
	The mode we are shipping first.

	  * Round start: a random survivor is infected with the Surge.
	  * Anyone may target anyone (camera lock-on decides).
	  * Every KO (kick, void, death, leaving) is an elimination.
	  * When nobody holds the Surge (after a KO), it re-infects a random
	    survivor after SurgeRespawnDelay, starting a fresh rally at base speed.
	  * Two left: Final Duel. One left: they win.

	Everything here goes through the GameMode contract (ServerTypes); there is
	no direct dependency on CombatService or RoundManager internals.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage.Shared.Config)
local ServerTypes = require(script.Parent.Parent.ServerTypes)

type RoundContext = ServerTypes.RoundContext

local rng = Random.new()
local surgeLostAt: number? = nil

local function infectRandomSurvivor(ctx: RoundContext)
	local alive = ctx.getAlive()
	if #alive >= 2 then
		ctx.combat.grantSurge(alive[rng:NextInteger(1, #alive)], 0)
	end
end

local SurgeMode: ServerTypes.GameMode = {
	name = "Surge",
	minPlayers = 2,

	onRoundStart = function(_self: ServerTypes.GameMode, ctx: RoundContext)
		surgeLostAt = nil
		infectRandomSurvivor(ctx)
	end,

	-- Surge watchdog: covers every way the Surge can disappear (KO, holder left,
	-- holder fell into the void) without each path needing its own re-grant.
	onTick = function(_self: ServerTypes.GameMode, ctx: RoundContext, _dt: number)
		if #ctx.combat.getSurgeHolders() > 0 then
			surgeLostAt = nil
			return
		end
		local clock = os.clock()
		if surgeLostAt == nil then
			surgeLostAt = clock
		elseif clock - (surgeLostAt :: number) >= Config.Round.SurgeRespawnDelay then
			surgeLostAt = nil
			infectRandomSurvivor(ctx)
		end
	end,

	onRoundEnd = function(_self: ServerTypes.GameMode, _ctx: RoundContext)
		surgeLostAt = nil
	end,

	canTarget = function(_self: ServerTypes.GameMode, ctx: RoundContext, attacker: Player, target: Player): boolean
		return attacker ~= target and ctx.isAlive(target)
	end,

	onDefeated = function(
		_self: ServerTypes.GameMode,
		ctx: RoundContext,
		victim: Player,
		attacker: Player?,
		_cause: ServerTypes.DefeatCause
	)
		ctx.eliminate(victim, attacker)
	end,

	onParried = function(
		_self: ServerTypes.GameMode,
		_ctx: RoundContext,
		_defender: Player,
		_attacker: Player,
		_perfect: boolean
	)
		-- Coins for parries are handled generically by the RoundManager.
	end,

	getResult = function(_self: ServerTypes.GameMode, ctx: RoundContext): ServerTypes.RoundResult?
		local alive = ctx.getAlive()
		if #alive == 1 then
			return { winners = alive, reason = "LastStanding" }
		elseif #alive == 0 then
			return { winners = {}, reason = "NoSurvivors" }
		end
		return nil
	end,

	isFinalPhase = function(_self: ServerTypes.GameMode, ctx: RoundContext): boolean
		return #ctx.getAlive() == 2
	end,
}

return SurgeMode
