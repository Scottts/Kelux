-- Annotations ---------------------------------------------------------------------------------------------
export type Subscription = number | { Disconnect: (self: any) -> () }
export type LiteState<T> = {
	Get: typeof(
		--[[
			Returns the current state value.
			<code>local val = state:Get()
		]]
		function(self: LiteState<T>): T end
	),
	Set: typeof(
		--[[
			Sets a new state value.
			Fires subscribers if the value is different.
			
			<code>state:Set(5)
		]]
		function(self: LiteState<T>, newValue: T): () end
	),
	Update: typeof(
		--[[
			Updates the state using a transformation function.
			The callback receives the current state and must return the new state.
			
			<code>
			state:Update(function(current)
				return current + 1
			end)
			</code>
		]]
		function(self: LiteState<T>, callback: (currentState: T) -> T): () end
	),
	Subscribe: typeof(
		--[[
			Subscribes to state changes.
			The listener receives (newValue, oldValue).
			
			@returns A subscription ID or Connection object (depending on Signal implementation).
			<code>
			state:Subscribe(function(new, old)
				print("Changed from", old, "to", new)
			end)
			</code>
		]]
		function(self: LiteState<T>, listener: (newValue: T, oldValue: T?) -> ()): Subscription end
	),
	Batch: typeof(
		--[[
			Groups multiple Set/Update calls into a single signal fire.
			The 'Changed' signal will only fire once after the callback finishes.
			
			<code>
			state:Batch(function()
				state:Set(1)
				state:Set(2) -- Listeners only hear "2"
			end)
			</code>
		]]
		function(self: LiteState<T>, callback: () -> ()): () end
	),
	Destroy: typeof(
		--[[
			Cleans up the state container and disconnects all listeners.
		]]
		function(self: LiteState<T>): () end
	),
}
export type Static = {
	new: typeof(
		--[[
			Creates a new LiteState container with an initial value.
			<code>local state = LiteState.new(10)
		]]
		function<T>(initialState: T): LiteState<T> end
	),
}
------------------------------------------------------------------------------------------------------------
export type Master = {
	LiteState: LiteState<any>,
	Static: Static,
}
local TypeDef = {}
return TypeDef :: Master