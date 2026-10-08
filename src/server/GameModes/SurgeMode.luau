--!strict
--[[
	SurgeMode (ModuleScript, server): Free-For-All Rally
	=====================================================
	The mode we are shipping first.

	  * Everyone can kick anyone at any moment (one kick in the air at a time,
	    plus a short cooldown; CombatService enforces both), and everyone can
	    Block at any moment.
	  * Every kick that lands is a strike; the third strike explodes you. Parry
	    ping-pong compounds speed and pulls the pair closer, so long exchanges
	    become frantic close-range duels.
	  * Exploding, falling off the arena, dying or leaving is an elimination.
	  * Two left: Final Duel. One left: they win.

	Everything here goes through the GameMode contract (ServerTypes); there is
	no direct dependency on CombatService or RoundManager internals.
]]

local ServerTypes = require(script.Parent.Parent.ServerTypes)

type RoundContext = ServerTypes.RoundContext

local SurgeMode: ServerTypes.GameMode = {
	name = "Surge",
	minPlayers = 2,

	onRoundStart = function(_self: ServerTypes.GameMode, _ctx: RoundContext) end,

	onTick = function(_self: ServerTypes.GameMode, _ctx: RoundContext, _dt: number) end,

	onRoundEnd = function(_self: ServerTypes.GameMode, _ctx: RoundContext) end,

	-- Free-for-all: every survivor may kick, and may be kicked by anyone.
	canLaunch = function(_self: ServerTypes.GameMode, ctx: RoundContext, player: Player): boolean
		return ctx.isAlive(player)
	end,

	canTarget = function(_self: ServerTypes.GameMode, ctx: RoundContext, attacker: Player, target: Player): boolean
		return attacker ~= target and ctx.isAlive(target)
	end,

	onDefeated = function(
		_self: ServerTypes.GameMode,
		ctx: RoundContext,
		victim: Player,
		attacker: Player?,
		cause: ServerTypes.DefeatCause
	)
		ctx.eliminate(victim, attacker, cause)
	end,

	onStruck = function(
		_self: ServerTypes.GameMode,
		_ctx: RoundContext,
		_victim: Player,
		_attacker: Player,
		_strikes: number
	)
		-- Nothing extra: strike bookkeeping is CombatService's, coins are the RoundManager's.
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
