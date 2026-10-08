--!strict
--[[
	Net (ModuleScript, ReplicatedStorage/Shared): the network bridge
	===============================================================
	The single place where every remote is declared. The server CREATES them
	(Net.server()), clients WAIT for them (Net.client()). Both get the same typed
	`Remotes` table, so a typo in a remote name is a type error, not a silent
	runtime bug.

	Design rules (full rationale in docs/NETWORK_BRIDGE.md):

	  1. Clients send INTENT ("I pressed Block at t"), never RESULTS ("I parried").
	  2. The combat hot path uses fire-and-forget RemoteEvents only. Nothing in
	     a rally ever yields on a RemoteFunction, and the server never calls
	     InvokeClient (a client could hang the server thread forever).
	  3. State that supersedes itself (the live impact ETA) goes over an
	     UnreliableRemoteEvent: a dropped packet is replaced 50 ms later anyway.
	  4. Persistent state (phase, strikes, who is stunned or flying) lives in
	     Attributes, which replicate automatically and are correct for late joiners.
	  5. Every timestamp is server time (workspace:GetServerTimeNow()).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local REMOTES_FOLDER = "ClashKickRemotes"
local STATE_FOLDER = "ClashKickState"

export type Remotes = {
	-- Client -> Server: combat intent (RemoteEvent, reliable, rate-limited, validated)
	RequestLaunch: RemoteEvent, -- (targetUserId: number, cameraCFrame: CFrame)
	RequestParry: RemoteEvent, -- (kickId: number, pressServerTime: number, lockUserId: number?)
	RequestAbility: RemoteEvent, -- ()  (SKILL button: equipped Leg Style, mid-flight)
	RequestDash: RemoteEvent, -- (direction: Vector3)
	RequestUltimate: RemoteEvent, -- (targetUserId: number, cameraCFrame: CFrame)
	PingReply: RemoteEvent, -- (nonce: number)

	-- Server -> Client
	Ping: RemoteEvent, -- (nonce: number); latency probe, answered instantly
	KickStarted: RemoteEvent, -- (Types.KickStartedPayload), all clients
	KickUpdated: UnreliableRemoteEvent, -- (kickId: number, eta: number, sentAt: number), all clients, ~20 Hz
	KickResolved: RemoteEvent, -- (Types.KickResolvedPayload), all clients
	ParryFeedback: RemoteEvent, -- (Types.ParryFeedbackPayload), presser only
	Effect: RemoteEvent, -- (Types.EffectPayload), all clients
	Ultimate: RemoteEvent, -- (Types.UltimatePayload), all clients: leap / dive / miss / cancel
	RoundEvent: RemoteEvent, -- (Types.RoundEventPayload), all clients
	ProfileUpdated: RemoteEvent, -- (Types.ProfileSnapshot, notice: string?), owner only, on every profile change

	-- Lobby request/response (RemoteFunction, Client -> Server ONLY)
	GetProfile: RemoteFunction, -- () -> Types.ProfileSnapshot?
	PurchaseUpgrade: RemoteFunction, -- (statId: string) -> (ok: boolean, message: string)
	SpinCrate: RemoteFunction, -- () -> (ok: boolean, styleIdOrError: string, duplicate: boolean)
	BuyCrateKey: RemoteFunction, -- () -> (ok: boolean, message: string)  (Coins, Config.Monetization.KeyCoinPrice)
	EquipLegStyle: RemoteFunction, -- (styleId: string) -> (ok: boolean, message: string)
	PlaceBet: RemoteFunction, -- (targetUserId: number, amount: number) -> (ok: boolean, message: string, multiplier: number?)
}

local Net = {}

-- Attribute names set by the server on Player objects (persistent, late-join safe).
Net.Attributes = table.freeze({
	InArena = "CK_InArena", -- boolean: a live combatant in the current round
	KickReadyAt = "CK_KickReadyAt", -- number: server time when this player may kick again (cooldown UI)
	DashReadyAt = "CK_DashReadyAt", -- number: server time when this player may dash again
	UltCharge = "CK_UltCharge", -- number 0..1: ULTIMATE meter (full = ready)
	Ultimate = "CK_Ultimate", -- boolean: performing an ULTIMATE right now
	Flying = "CK_Flying", -- boolean: currently a human missile
	Stunned = "CK_Stunned", -- boolean: frozen mid-air after being parried, or tumbling after a hit
	Strikes = "CK_Strikes", -- number: kicks this player has taken this round (in the arena only)
	StrikesToExplode = "CK_StrikesToExplode", -- number: strikes that explode them (drives the strike pips)
	LegStyle = "CK_LegStyle", -- string: equipped Leg Style id (the SKILL button shows it)
	SkillUsed = "CK_SkillUsed", -- number: Leg Style activations used this round (nil = none)
	Flagged = "CK_Flagged", -- string: integrity flag reason (moderation tooling)
})

-- Attribute names set on the ReplicatedStorage.ClashKickState folder.
Net.StateAttributes = table.freeze({
	Phase = "Phase", -- Types.Phase
	PhaseEndsAt = "PhaseEndsAt", -- server time, 0 = open-ended
	Mode = "Mode", -- active GameMode name
	AliveCount = "AliveCount",
	RoundId = "RoundId",
})

local cachedRemotes: Remotes? = nil
local cachedState: Folder? = nil

local function getFolder(name: string, isServer: boolean): Folder
	if isServer then
		local existing = ReplicatedStorage:FindFirstChild(name)
		if existing and existing:IsA("Folder") then
			return existing
		end
		local folder = Instance.new("Folder")
		folder.Name = name
		folder.Parent = ReplicatedStorage
		return folder
	end
	return ReplicatedStorage:WaitForChild(name) :: Folder
end

local function build(isServer: boolean): Remotes
	local folder = getFolder(REMOTES_FOLDER, isServer)

	-- One typed constructor per remote class keeps Instance.new() calls literal,
	-- so the type checker knows exactly what each field holds.
	local function event(name: string): RemoteEvent
		if not isServer then
			return folder:WaitForChild(name) :: RemoteEvent
		end
		local existing = folder:FindFirstChild(name)
		if existing and existing:IsA("RemoteEvent") then
			return existing
		end
		local remote = Instance.new("RemoteEvent")
		remote.Name = name
		remote.Parent = folder
		return remote
	end

	local function unreliable(name: string): UnreliableRemoteEvent
		if not isServer then
			return folder:WaitForChild(name) :: UnreliableRemoteEvent
		end
		local existing = folder:FindFirstChild(name)
		if existing and existing:IsA("UnreliableRemoteEvent") then
			return existing
		end
		local remote = Instance.new("UnreliableRemoteEvent")
		remote.Name = name
		remote.Parent = folder
		return remote
	end

	local function func(name: string): RemoteFunction
		if not isServer then
			return folder:WaitForChild(name) :: RemoteFunction
		end
		local existing = folder:FindFirstChild(name)
		if existing and existing:IsA("RemoteFunction") then
			return existing
		end
		local remote = Instance.new("RemoteFunction")
		remote.Name = name
		remote.Parent = folder
		return remote
	end

	return {
		RequestLaunch = event("RequestLaunch"),
		RequestParry = event("RequestParry"),
		RequestAbility = event("RequestAbility"),
		RequestDash = event("RequestDash"),
		RequestUltimate = event("RequestUltimate"),
		PingReply = event("PingReply"),

		Ping = event("Ping"),
		KickStarted = event("KickStarted"),
		KickUpdated = unreliable("KickUpdated"),
		KickResolved = event("KickResolved"),
		ParryFeedback = event("ParryFeedback"),
		Effect = event("Effect"),
		Ultimate = event("Ultimate"),
		RoundEvent = event("RoundEvent"),
		ProfileUpdated = event("ProfileUpdated"),

		GetProfile = func("GetProfile"),
		PurchaseUpgrade = func("PurchaseUpgrade"),
		SpinCrate = func("SpinCrate"),
		BuyCrateKey = func("BuyCrateKey"),
		EquipLegStyle = func("EquipLegStyle"),
		PlaceBet = func("PlaceBet"),
	}
end

-- Server: create (or adopt) every remote. Call once, before any player can act.
function Net.server(): Remotes
	assert(RunService:IsServer(), "Net.server() is server-only")
	if not cachedRemotes then
		cachedRemotes = build(true)
	end
	return cachedRemotes :: Remotes
end

-- Client: wait for the server-created remotes.
function Net.client(): Remotes
	assert(RunService:IsClient(), "Net.client() is client-only")
	if not cachedRemotes then
		cachedRemotes = build(false)
	end
	return cachedRemotes :: Remotes
end

-- Folder whose attributes mirror the round state (phase, timers, alive count).
function Net.stateFolder(): Folder
	if not cachedState then
		cachedState = getFolder(STATE_FOLDER, RunService:IsServer())
	end
	return cachedState :: Folder
end

return Net
