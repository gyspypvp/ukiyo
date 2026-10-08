--!strict
--[[
	JuggernautMode (ModuleScript, server): "Tagger vs. Lobby"
	==========================================================
	DRAFT, registered but NOT in Config.Round.ModeRotation.

	This exists to prove the architecture: an asymmetric mode is one file
	implementing the GameMode contract, with zero changes to CombatService
	or RoundManager. Balance and polish are future work.

	  * One random player is the Juggernaut and is the ONLY one who may start
	    kicks (canLaunch).
	  * Runners can only Block. A parry ricochets back at the Juggernaut, and
	    canTarget stops runners redirecting onto each other.
	  * Runners win if the Juggernaut is KO'd; the Juggernaut wins if it's
	    the last one standing.

	To enable it, add "Juggernaut" to Config.Round.ModeRotation.
]]

local ServerTypes = require(script.Parent.Parent.ServerTypes)

type RoundContext = ServerTypes.RoundContext

local rng = Random.new()
local juggernaut: Player? = nil

local JuggernautMode: ServerTypes.GameMode = {
	name = "Juggernaut",
	minPlayers = 3,

	onRoundStart = function(_self: ServerTypes.GameMode, ctx: RoundContext)
		local alive = ctx.getAlive()
		juggernaut = alive[rng:NextInteger(1, #alive)]
	end,

	onTick = function(_self: ServerTypes.GameMode, _ctx: RoundContext, _dt: number) end,

	onRoundEnd = function(_self: ServerTypes.GameMode, _ctx: RoundContext)
		juggernaut = nil
	end,

	canLaunch = function(_self: ServerTypes.GameMode, ctx: RoundContext, player: Player): boolean
		return player == juggernaut and ctx.isAlive(player)
	end,

	canTarget = function(_self: ServerTypes.GameMode, ctx: RoundContext, attacker: Player, target: Player): boolean
		if attacker == juggernaut then
			return target ~= attacker and ctx.isAlive(target)
		end
		return target == juggernaut
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

	-- Future: give the Juggernaut more HP than the runners.
	onDamaged = function(
		_self: ServerTypes.GameMode,
		_ctx: RoundContext,
		_victim: Player,
		_attacker: Player,
		_damage: number,
		_health: number
	)
	end,

	onParried = function(
		_self: ServerTypes.GameMode,
		_ctx: RoundContext,
		_defender: Player,
		_attacker: Player,
		_perfect: boolean
	)
	end,

	getResult = function(_self: ServerTypes.GameMode, ctx: RoundContext): ServerTypes.RoundResult?
		local current = juggernaut
		local alive = ctx.getAlive()
		if current == nil or not ctx.isAlive(current) then
			return { winners = alive, reason = "JuggernautDown" }
		end
		if #alive == 1 then
			return { winners = alive, reason = "JuggernautWins" }
		end
		return nil
	end,

	isFinalPhase = function(_self: ServerTypes.GameMode, ctx: RoundContext): boolean
		return #ctx.getAlive() == 2
	end,
}

return JuggernautMode
