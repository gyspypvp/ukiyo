--!strict
--[[
	RateLimiter (ModuleScript, server)
	==================================
	Per-player token bucket. Each remote gets its own limiter; a request that
	finds the bucket empty is dropped silently (no error reply, which would
	itself be a cheap amplification vector).

	    tokens = min(burst, tokens + elapsed * rate)
	    allowed if tokens >= 1, then tokens -= 1

	Buckets are weak-keyed by Player, so they disappear with the player.
]]

export type RateLimiter = {
	check: (self: RateLimiter, player: Player) -> boolean,
}

type Bucket = {
	tokens: number,
	updatedAt: number,
}

local RateLimiter = {}

function RateLimiter.new(rate: number, burst: number): RateLimiter
	local buckets: { [Player]: Bucket } = setmetatable({}, { __mode = "k" }) :: any

	local limiter: RateLimiter = {
		check = function(_self: RateLimiter, player: Player): boolean
			local now = os.clock()
			local bucket = buckets[player]
			if bucket == nil then
				bucket = { tokens = burst, updatedAt = now }
				buckets[player] = bucket
			end
			bucket.tokens = math.min(burst, bucket.tokens + (now - bucket.updatedAt) * rate)
			bucket.updatedAt = now
			if bucket.tokens < 1 then
				return false
			end
			bucket.tokens -= 1
			return true
		end,
	}
	return limiter
end

return RateLimiter
