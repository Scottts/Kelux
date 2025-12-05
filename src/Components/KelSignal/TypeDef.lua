-- Annotations ---------------------------------------------------------------------------------------------
export type Handler = (...any) -> ()
export type Signal = {
	-- Connection Management
	Connect: typeof(
		--[[
			Connects a handler function to the signal.
			Returns a <strong>Connection ID</strong> (number) which is used to disconnect.
			
			<code>local id = signal:Connect(function(name)
				print("Hello", name)
			end)
		]]
		function(self: Signal, handler: Handler): number end
	),
	Once: typeof(
		--[[
			Connects a handler function that will only run <strong>one time</strong>
			and then automatically disconnect.
			
			<code>signal:Once(function(...) print("Fired once") end)
		]]
		function(self: Signal, handler: Handler): number end
	),
	Disconnect: typeof(
		--[[
			Disconnects a specific handler using its <strong>Connection ID</strong>.
			If the signal is currently firing, the disconnect is deferred
			until the fire cycle is complete.
			
			<code>signal:Disconnect(connectionId)
		]]
		function(self: Signal, id: number) end
	),
	DisconnectAll: typeof(
		--[[
			Disconnects <strong>all</strong> handlers from the signal.
			Cleans up all internal lookups and lists.
			
			<code>signal:DisconnectAll()
		]]
		function(self: Signal) end
	),
	-- Yielding
	Wait: typeof(
		--[[
			Yields the current coroutine until the signal is fired.
			Returns the arguments passed to <code>Fire</code>.
			
			<code>local arg1, arg2 = signal:Wait()
		]]
		function(self: Signal): ...any end
	),
	-- Firing
	Fire: typeof(
		--[[
			Fires the signal, invoking all connected handlers with the provided arguments.
			
			<code>signal:Fire("Argument 1", 200)
		]]
		function(self: Signal, ...: any) end
	),
}
export type Static = {
	new: typeof(
		--[[
			Creates a new KelSignal instance.
			Designed for high throughput with optimized Connect/Fire speeds.
			
			<code>local signal = KelSignal.new()
		]]
		function(): Signal end
	)
}
------------------------------------------------------------------------------------------------------------
export type Master = {
	Handler: Handler,
	Signal: Signal,
	Static: Static,
}
local TypeDef = {}
return TypeDef :: Master
