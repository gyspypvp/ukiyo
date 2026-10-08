--!strict
--[[
	LatencyService (ModuleScript, server)
	=====================================
	Measures each player's round-trip time so CombatService knows how far back it
	may believe a parry happened.

	HOW IT RESISTS SPOOFING
	-----------------------
	  * The server sends Ping(nonce) with a RANDOM nonce and times the reply with
	    its own monotonic clock. The client cannot answer before it has received
	    the nonce, so it can only make its latency look WORSE, never better.
	  * Making it look worse (a lag-switcher fishing for a bigger rewind) is
	    bounded three ways: the median ignores spikes, the engine's own
	    Player:GetNetworkPing() acts as an upper bound, and
	    Config.Latency.MaxCompensation is a hard cap.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage.Shared
local CombatMath = require(Shared.CombatMath)
local Config = require(Shared.Config)
local Net = require(Shared.Net)

local Guard = require(script.Parent.Parent.Util.Guard)
local RateLimiter = require(script.Parent.Parent.Util.RateLimiter)

type Record = {
	samples: { number }, -- most recent RTTs (seconds), ring buffer
	nextSlot: number,
	pending: { [number]: number }, -- nonce -> os.clock() when sent
	rtt: number,
	jitter: number,
}

local LatencyService = {}

local records: { [Player]: Record } = {}
local rng = Random.new()
local replyLimiter = RateLimiter.new(Config.RateLimits.PingReply.rate, Config.RateLimits.PingReply.burst)

local function newRecord(): Record
	return {
		samples = {},
		nextSlot = 1,
		pending = {},
		rtt = Config.Latency.DefaultRtt,
		jitter = 0,
	}
end

local function addSample(record: Record, rtt: number)
	record.samples[record.nextSlot] = rtt
	record.nextSlot = record.nextSlot % Config.Latency.SampleCount + 1
	record.rtt = CombatMath.median(record.samples)
	record.jitter = CombatMath.medianAbsoluteDeviation(record.samples)
end

local function onPingReply(player: Player, rawNonce: unknown)
	if not replyLimiter:check(player) then
		return
	end
	local record = records[player]
	local nonce = Guard.integer(rawNonce, 1, 2 ^ 30)
	if record == nil or nonce == nil then
		return
	end
	local sentAt = record.pending[nonce]
	if sentAt == nil then
		return -- unknown / replayed / forged nonce
	end
	record.pending[nonce] = nil
	addSample(record, os.clock() - sentAt)
end

local function pingAll(remotes: Net.Remotes)
	local clock = os.clock()
	for player, record in records do
		-- Drop pings that never came back so `pending` can't grow without bound.
		for nonce, sentAt in record.pending do
			if clock - sentAt > Config.Latency.PingTimeout then
				record.pending[nonce] = nil
			end
		end
		local nonce = rng:NextInteger(1, 2 ^ 30)
		record.pending[nonce] = clock
		remotes.Ping:FireClient(player, nonce)
	end
end

-- Median round-trip time in seconds, capped by the engine's own measurement.
function LatencyService.getRtt(player: Player): number
	local record = records[player]
	local measured = if record and #record.samples > 0 then record.rtt else Config.Latency.DefaultRtt

	-- Cross-check against the engine. Its value is treated only as a loose upper
	-- bound (x2, + slack) so the check is safe whether the engine reports one-way
	-- or round-trip time; it exists to stop a client that delays its ping replies
	-- from inflating its lag-compensation budget.
	local ok, engine = pcall(function(): number
		return player:GetNetworkPing()
	end)
	if ok and engine > 0 then
		measured = math.min(measured, math.max(engine * 2, engine + 0.05) + Config.Latency.JitterTolerance)
	end
	return measured
end

function LatencyService.getJitter(player: Player): number
	local record = records[player]
	return if record then record.jitter else 0
end

-- How far back (seconds) a parry stamp from this player may be believed.
function LatencyService.getMaxRewind(player: Player): number
	return CombatMath.maxRewind(
		LatencyService.getRtt(player),
		LatencyService.getJitter(player),
		Config.Latency.JitterTolerance,
		Config.Latency.MaxCompensation
	)
end

function LatencyService.init(remotes: Net.Remotes)
	local function track(player: Player)
		records[player] = newRecord()
	end
	Players.PlayerAdded:Connect(track)
	for _, player in Players:GetPlayers() do
		track(player)
	end
	Players.PlayerRemoving:Connect(function(player: Player)
		records[player] = nil
	end)

	remotes.PingReply.OnServerEvent:Connect(onPingReply)

	task.spawn(function()
		while true do
			pingAll(remotes)
			task.wait(Config.Latency.PingInterval)
		end
	end)
end

return LatencyService
