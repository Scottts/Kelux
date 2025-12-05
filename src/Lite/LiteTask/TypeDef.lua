-- Annotations ---------------------------------------------------------------------------------------------
export type CleanupToken = {
	Cancel: (self: CleanupToken) -> ()
}
export type LiteTask = {
	Delay: typeof(
		--[[
			Schedules a callback to run after 'seconds'.
			Returns a token to cancel the delay if needed (e.g., UI closed).
			
			<code>
			local timer = LiteTask.Delay(5, function()
				print("5 seconds passed")
			end)
			timer:Cancel() -- Stops it
			</code>
		]]
		function(seconds: number, callback: () -> ()): CleanupToken end
	),
	Debounce: typeof(
		--[[
			(Trailing Edge) Ensures 'callback' only runs after 'seconds' have passed 
			since the LAST call with this 'key'.
			Useful for: Search bars, saving data after typing stops.
			
			<code>
			-- Only saves data 2 seconds after the user STOPS typing
			LiteTask.Debounce("Save", 2, SaveFunction, data)
			</code>
		]]
		function(key: any, seconds: number, callback: (...any) -> (), ...: any): () end
	),
	Throttle: typeof(
		--[[
			(Leading Edge) Runs 'callback' IMMEDIATELY, then prevents it from 
			running again for this 'key' until 'seconds' have passed.
			Useful for: Button clicks, firing weapons, jumping.
			
			<code>
			-- Fires immediately, then cooldown for 0.5s
			LiteTask.Throttle("Attack", 0.5, FireWeapon)
			</code>
		]]
		function(key: any, seconds: number, callback: (...any) -> (), ...: any): () end
	),
	Cancel: typeof(
		--[[
			Manually cancels a pending Debounce task for the given key.
			Does not affect Throttles (as they run immediately).
			
			<code>LiteTask.Cancel("Save")</code>
		]]
		function(key: any): () end
	),
	Cleanup: typeof(
		--[[
			Cancels ALL pending Debounce/Delay tasks and clears the registry.
			Useful when destroying a plugin, changing maps, or resetting game state.
		]]
		function(): () end
	),
	Version: string
}
------------------------------------------------------------------------------------------------------------
export type Master = {
	CleanupToken: CleanupToken,
	LiteTask: LiteTask,
}
local TypeDef = {}
return TypeDef :: Master