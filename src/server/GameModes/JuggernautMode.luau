--!strict
--[[
	JuggernautMode (ModuleScript, server): "Tagger vs. Lobby"
	==========================================================
	DRAFT, registered but NOT in Config.Round.ModeRotation.

	This exists to prove the architecture: an asymmetric mode is one file
	implementing the GameMode contract, with zero changes to CombatService
	or RoundManager. Balance and polish are future work.

	  * One random player is the Juggernaut and permanently owns the Surge.
	  * The Juggernaut may kick anyone; runners can only parry it BACK at the
	    Juggernaut (canTarget blocks redirects onto other runners).
	  * Whenever nobody holds the Surge, it returns to the Juggernaut.
	  * Runners win if the Juggernaut is KO'd; the Juggernaut wins if it's
	    the last one standing.

	To enable it, add "Juggernaut" to Config.Round.ModeRotation.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage.Shared.Config)
local ServerTypes = require(script.Parent.Parent.ServerTypes)

type RoundContext = ServerTypes.RoundContext

local rng = Random.new()
local juggernaut: Player? = nil
local surgeLostAt: number? = nil

local JuggernautMode: ServerTypes.GameMode = {
	name = "Juggernaut",
	minPlayers = 3,

	onRoundStart = function(_self: ServerTypes.GameMode, ctx: RoundContext)
		local alive = ctx.getAlive()
		local chosen = alive[rng:NextInteger(1, #alive)]
		juggernaut = chosen
		surgeLostAt = nil
		ctx.combat.grantSurge(chosen, 0)
	end,

	-- The Surge always comes home to the Juggernaut.
	onTick = function(_self: ServerTypes.GameMode, ctx: RoundContext, _dt: number)
		local current = juggernaut
		if current == nil or not ctx.isAlive(current) or #ctx.combat.getSurgeHolders() > 0 then
			surgeLostAt = nil
			return
		end
		local clock = os.clock()
		if surgeLostAt == nil then
			surgeLostAt = clock
		elseif clock - (surgeLostAt :: number) >= Config.Round.SurgeRespawnDelay then
			surgeLostAt = nil
			ctx.combat.grantSurge(current, 0)
		end
	end,

	onRoundEnd = function(_self: ServerTypes.GameMode, _ctx: RoundContext)
		juggernaut = nil
		surgeLostAt = nil
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
		_cause: ServerTypes.DefeatCause
	)
		-- Future: give the Juggernaut extra lives here instead of eliminating.
		ctx.eliminate(victim, attacker)
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
