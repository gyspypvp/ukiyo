--!strict
--[[
	RoundController (LocalScript, StarterPlayer/StarterPlayerScripts/Client)
	========================================================================
	Round presentation, driven by the replicated ClashKickState attributes:

	  * phase banner + countdown ("INTERMISSION 0:12", "ALIVE 7", "FINAL DUEL")
	  * Final Duel: camera FOV widens and the music intensifies
	  * "<NAME> WINS!" banner and a small KO feed

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

local localPlayer = Players.LocalPlayer
local playerGui = localPlayer:WaitForChild("PlayerGui") :: PlayerGui
local remotes = Net.client()
local state = Net.stateFolder()
local STATE = Net.StateAttributes

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

local function outlinedLabel(name: string, position: UDim2, size: UDim2, color: Color3): TextLabel
	local label = Instance.new("TextLabel")
	label.Name = name
	label.AnchorPoint = Vector2.new(0.5, 0)
	label.Position = position
	label.Size = size
	label.BackgroundTransparency = 1
	label.Font = Enum.Font.LuckiestGuy
	label.TextScaled = true
	label.TextColor3 = color
	label.Text = ""
	label.Parent = gui
	local uiStroke = Instance.new("UIStroke")
	uiStroke.Thickness = 3
	uiStroke.Color = Color3.fromRGB(60, 20, 0)
	uiStroke.Parent = label
	return label
end

local phaseLabel = outlinedLabel("Phase", UDim2.new(0.5, 0, 0, 52), UDim2.fromOffset(420, 36), Color3.new(1, 1, 1))
local banner =
	outlinedLabel("Banner", UDim2.fromScale(0.5, 0.2), UDim2.fromScale(0.6, 0.1), Color3.fromRGB(255, 170, 30))
local feed = outlinedLabel("Feed", UDim2.new(0.5, 0, 0, 92), UDim2.fromOffset(420, 22), Color3.fromRGB(255, 120, 120))

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

remotes.RoundEvent.OnClientEvent:Connect(function(payload: Types.RoundEventPayload)
	if payload.kind == "Winner" then
		banner.Text = `{string.upper(nameOf(payload.userId, payload.displayName))} WINS!`
		banner.Size = UDim2.fromScale(0.75, 0.13)
		TweenService:Create(banner, TweenInfo.new(0.35, Enum.EasingStyle.Back), { Size = UDim2.fromScale(0.6, 0.1) })
			:Play()
	elseif payload.kind == "Draw" then
		banner.Text = `TIME! {string.upper(payload.displayName or "")} WIN`
	elseif payload.kind == "NoContest" then
		banner.Text = "NO CONTEST"
	elseif payload.kind == "Eliminated" then
		local victim = nameOf(payload.userId, payload.displayName)
		local killer = if payload.killerId then nameOf(payload.killerId, nil) else nil
		if payload.cause == "Void" then
			feed.Text = if killer then `{killer} knocked {victim} off the arena` else `{victim} fell off the arena`
		elseif payload.cause == "Left" then
			feed.Text = if killer then `{killer} knocked out {victim} (they left)` else `{victim} left the match`
		elseif killer then
			feed.Text = `{killer} kicked out {victim}`
		else
			feed.Text = `{victim} was knocked out`
		end
		feed.TextTransparency = 0
		TweenService:Create(feed, TweenInfo.new(1, Enum.EasingStyle.Linear, Enum.EasingDirection.In, 0, false, 2), {
			TextTransparency = 1,
		}):Play()
	end
end)
