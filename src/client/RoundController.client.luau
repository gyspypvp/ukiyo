--!strict
--[[
	RoundController (LocalScript, StarterPlayer/StarterPlayerScripts/Client)
	========================================================================
	Round presentation, driven by the replicated ClashKickState attributes:

	  * phase pill + countdown ("INTERMISSION 0:12", "ALIVE 7", "FINAL DUEL")
	  * Final Duel: camera FOV widens and the music intensifies
	  * "<NAME> WINS!" banner and a small kill feed ("A exploded B")
	All of it in the shared UiTheme style.

	Music is optional: put a Folder named "ClashKickMusic" in SoundService with
	Sounds named "Lobby", "Battle" and "Duel". Missing sounds are skipped.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local SoundService = game:GetService("SoundService")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local Net = require(Shared:WaitForChild("Net"))
local Types = require(Shared:WaitForChild("Types"))
local UiTheme = require(script.Parent:WaitForChild("UiTheme"))

local localPlayer = Players.LocalPlayer
local playerGui = localPlayer:WaitForChild("PlayerGui") :: PlayerGui
local remotes = Net.client()
local state = Net.stateFolder()
local STATE = Net.StateAttributes
local COLORS = UiTheme.Colors

local PHASE_TITLES: { [string]: string } = {
	Waiting = "WAITING FOR PLAYERS",
	Intermission = "INTERMISSION",
	Spawning = "GET READY",
	Active = "ALIVE",
	FinalDuel = "FINAL DUEL",
	MatchEnd = "MATCH OVER",
}

-- UI -------------------------------------------------------------------------------------

local gui = Instance.new("ScreenGui")
gui.Name = "ClashKickRound"
gui.ResetOnSpawn = false
gui.IgnoreGuiInset = true
gui.Parent = playerGui

-- A glass pill that sizes itself to its text.
local function pill(name: string, y: number, textSize: number, color: Color3): (Frame, TextLabel)
	local frame = UiTheme.panel(gui, name, UDim.new(0.5, 0))
	frame.AnchorPoint = Vector2.new(0.5, 0)
	frame.Position = UDim2.new(0.5, 0, 0, y)
	frame.AutomaticSize = Enum.AutomaticSize.X
	frame.Size = UDim2.fromOffset(0, textSize + 14)
	local padding = Instance.new("UIPadding")
	padding.PaddingLeft = UDim.new(0, 16)
	padding.PaddingRight = UDim.new(0, 16)
	padding.Parent = frame
	local label = UiTheme.text(frame, UiTheme.Font, color, textSize)
	label.AutomaticSize = Enum.AutomaticSize.X
	label.Size = UDim2.fromScale(0, 1)
	return frame, label
end

local phasePill, phaseLabel = pill("Phase", 50, 16, COLORS.Text)
local feedPill, feed = pill("Feed", 90, 14, COLORS.Text)
feedPill.Visible = false

local banner = UiTheme.text(gui, UiTheme.FontHeavy, COLORS.Text)
banner.Name = "Banner"
banner.AnchorPoint = Vector2.new(0.5, 0)
banner.Position = UDim2.fromScale(0.5, 0.2)
banner.Size = UDim2.fromScale(0.6, 0.08)
UiTheme.stroke(banner, 1.5, Color3.new(0, 0, 0), 0.5).ApplyStrokeMode = Enum.ApplyStrokeMode.Contextual
local bannerRule = Instance.new("Frame") -- a thin accent line under the banner
bannerRule.Name = "Rule"
bannerRule.AnchorPoint = Vector2.new(0.5, 0)
bannerRule.Position = UDim2.new(0.5, 0, 1, 6)
bannerRule.Size = UDim2.new(0.4, 0, 0, 3)
bannerRule.BackgroundColor3 = COLORS.UltA
bannerRule.BorderSizePixel = 0
bannerRule.Visible = false
bannerRule.Parent = banner
UiTheme.corner(bannerRule, UDim.new(0, 2))

-- Final Duel: FOV + music ------------------------------------------------------------------

local currentTrack: Sound? = nil

local function playTrack(name: string)
	local folder = SoundService:FindFirstChild("ClashKickMusic")
	local nextTrack = folder and folder:FindFirstChild(name)
	if nextTrack == currentTrack then
		return
	end
	local previous = currentTrack
	if previous then
		TweenService:Create(previous, TweenInfo.new(1), { Volume = 0 }):Play()
		task.delay(1, function()
			if currentTrack ~= previous then
				previous:Stop()
			end
		end)
	end
	if nextTrack and nextTrack:IsA("Sound") then
		local targetVolume = nextTrack:GetAttribute("Volume")
		nextTrack.Looped = true
		nextTrack.Volume = 0
		nextTrack:Play()
		TweenService:Create(nextTrack, TweenInfo.new(1), {
			Volume = if typeof(targetVolume) == "number" then targetVolume else 0.5,
		}):Play()
		currentTrack = nextTrack
	else
		currentTrack = nil
	end
end

local function tweenFov(fov: number)
	local camera = Workspace.CurrentCamera
	if camera then
		TweenService:Create(camera, TweenInfo.new(Config.Camera.FovTweenTime, Enum.EasingStyle.Quad), {
			FieldOfView = fov,
		}):Play()
	end
end

local function onPhaseChanged()
	local phase = state:GetAttribute(STATE.Phase)
	if phase == "FinalDuel" then
		tweenFov(Config.Camera.FinalDuelFov)
		playTrack("Duel")
	elseif phase == "Active" or phase == "Spawning" then
		tweenFov(Config.Camera.DefaultFov)
		playTrack("Battle")
	else
		tweenFov(Config.Camera.DefaultFov)
		playTrack("Lobby")
	end
	if phase ~= "MatchEnd" then
		banner.Text = ""
		bannerRule.Visible = false
	end
end

state:GetAttributeChangedSignal(STATE.Phase):Connect(onPhaseChanged)
onPhaseChanged()

-- Phase label + countdown, refreshed every frame from the synced clock.
RunService.RenderStepped:Connect(function()
	local phase = state:GetAttribute(STATE.Phase)
	local title = if typeof(phase) == "string" then PHASE_TITLES[phase] or phase else ""
	local endsAt = state:GetAttribute(STATE.PhaseEndsAt)
	local alive = state:GetAttribute(STATE.AliveCount)

	phaseLabel.TextColor3 = if phase == "FinalDuel" then COLORS.UltA else COLORS.Text
	phasePill.Visible = title ~= ""
	if phase == "Active" and typeof(alive) == "number" then
		phaseLabel.Text = `{title} {alive}`
	elseif typeof(endsAt) == "number" and endsAt > 0 then
		local remaining = math.max(0, math.ceil(endsAt - Workspace:GetServerTimeNow()))
		phaseLabel.Text = string.format("%s %d:%02d", title, remaining // 60, remaining % 60)
	else
		phaseLabel.Text = title
	end
end)

-- Round announcements ----------------------------------------------------------------------

local function nameOf(userId: number?, fallback: string?): string
	local player = if userId then Players:GetPlayerByUserId(userId) else nil
	return if player then player.DisplayName else fallback or "Someone"
end

local feedToken = 0

local function showBanner(text: string)
	banner.Text = text
	bannerRule.Visible = true
	banner.Size = UDim2.fromScale(0.7, 0.1)
	TweenService:Create(banner, TweenInfo.new(0.35, Enum.EasingStyle.Back), { Size = UDim2.fromScale(0.6, 0.08) })
		:Play()
end

remotes.RoundEvent.OnClientEvent:Connect(function(payload: Types.RoundEventPayload)
	if payload.kind == "Winner" then
		showBanner(`{string.upper(nameOf(payload.userId, payload.displayName))} WINS`)
	elseif payload.kind == "Draw" then
		showBanner(`TIME · {string.upper(payload.displayName or "")} WIN`)
	elseif payload.kind == "NoContest" then
		showBanner("NO CONTEST")
	elseif payload.kind == "Eliminated" then
		local victim = nameOf(payload.userId, payload.displayName)
		local killer = if payload.killerId then nameOf(payload.killerId, nil) else nil
		if payload.cause == "Void" then
			feed.Text = if killer then `{killer} knocked {victim} off the arena` else `{victim} fell off the arena`
		elseif payload.cause == "Left" then
			feed.Text = if killer then `{killer} knocked out {victim} (they left)` else `{victim} left the match`
		elseif killer and payload.cause == "Kick" then
			feed.Text = `{killer} exploded {victim}`
		elseif killer then
			feed.Text = `{killer} knocked out {victim}`
		else
			feed.Text = `{victim} was knocked out`
		end
		feedPill.Visible = true
		feedToken += 1
		local token = feedToken
		task.delay(3, function()
			if token == feedToken then
				feedPill.Visible = false
			end
		end)
	end
end)
