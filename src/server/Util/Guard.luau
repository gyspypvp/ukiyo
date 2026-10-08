--!strict
--[[
	Guard (ModuleScript, server)
	============================
	Validators for UNTRUSTED values arriving over remotes. An exploiter can send
	any Luau value (wrong types, NaN, inf, huge tables, instances), so every
	remote handler narrows its arguments through these before touching them.

	Every function returns the narrowed value, or nil if it is invalid.
]]

local Players = game:GetService("Players")

local Guard = {}

local function finite(value: number): boolean
	-- NaN ~= NaN, and +/-inf would poison any physics or timing math.
	return value == value and value ~= math.huge and value ~= -math.huge
end

function Guard.number(value: unknown): number?
	if typeof(value) == "number" and finite(value) then
		return value
	end
	return nil
end

function Guard.integer(value: unknown, minValue: number, maxValue: number): number?
	if typeof(value) == "number" and finite(value) and value % 1 == 0 and value >= minValue and value <= maxValue then
		return value
	end
	return nil
end

function Guard.cframe(value: unknown): CFrame?
	if typeof(value) ~= "CFrame" then
		return nil
	end
	for _, component in { value:GetComponents() } do
		if not finite(component) then
			return nil
		end
	end
	return value
end

function Guard.vector3(value: unknown): Vector3?
	if typeof(value) == "Vector3" and finite(value.X) and finite(value.Y) and finite(value.Z) then
		return value
	end
	return nil
end

-- Resolves a UserId to an in-game Player (nil if invalid or not in this server).
function Guard.player(value: unknown): Player?
	local userId = Guard.integer(value, -(2 ^ 53), 2 ^ 53)
	if userId == nil then
		return nil
	end
	return Players:GetPlayerByUserId(userId)
end

function Guard.shortString(value: unknown, maxLength: number): string?
	if typeof(value) == "string" and #value > 0 and #value <= maxLength then
		return value
	end
	return nil
end

return table.freeze(Guard)
