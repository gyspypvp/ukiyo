--!strict
--[[
	Main (Script, ServerScriptService/Server)
	=========================================
	Server entry point. The only Script on the server; everything else is a
	ModuleScript initialised here in dependency order.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Net = require(ReplicatedStorage.Shared.Net)

local Server = script.Parent
local Services = Server.Services
local GameModes = Server.GameModes

-- Create every remote BEFORE anything else, so no client WaitForChild can stall.
local remotes = Net.server()
Net.stateFolder()

local LatencyService = require(Services.LatencyService)
local PlayerDataService = require(Services.PlayerDataService)
local CombatService = require(Services.CombatService)
local BettingService = require(Services.BettingService)
local RoundManager = require(Services.RoundManager)

LatencyService.init(remotes)
PlayerDataService.init(remotes)
CombatService.init(remotes)
BettingService.init(remotes)
RoundManager.init(remotes)

-- Modes are registered by name; Config.Round.ModeRotation decides which ones run.
RoundManager.registerMode(require(GameModes.SurgeMode))
RoundManager.registerMode(require(GameModes.JuggernautMode)) -- draft, not in rotation yet

RoundManager.start()
