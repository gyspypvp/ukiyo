--!strict
--[[
	Signal (ModuleScript, ReplicatedStorage/Shared)
	===============================================
	Tiny typed event used for server-internal notifications (CombatService ->
	RoundManager -> GameMode).

	Handlers are DEFERRED (task.defer): they run after the code that fired the
	signal has finished. CombatService fires signals in the middle of
	updating its tables, so a handler that runs immediately and calls back into
	it (e.g. eliminate -> unregisterCombatant) could see half-updated state.
	Deferring removes that whole class of re-entrancy bugs. A handler that errors
	or yields also can't break the loop that fired it.
]]

export type Signal<T...> = {
	Connect: (self: Signal<T...>, handler: (T...) -> ()) -> () -> (),
	Fire: (self: Signal<T...>, T...) -> (),
}

local Signal = {}

function Signal.new<T...>(): Signal<T...>
	local handlers: { [{}]: (T...) -> () } = {}

	local signal: Signal<T...> = {
		-- Returns a disconnect function.
		Connect = function(_self: Signal<T...>, handler: (T...) -> ()): () -> ()
			local key = {}
			handlers[key] = handler
			return function()
				handlers[key] = nil
			end
		end,

		Fire = function(_self: Signal<T...>, ...: T...)
			-- Snapshot first: a handler may connect/disconnect while we iterate.
			local snapshot = {}
			for _, handler in handlers do
				table.insert(snapshot, handler)
			end
			for _, handler in snapshot do
				task.defer(handler, ...)
			end
		end,
	}

	return signal
end

return Signal
