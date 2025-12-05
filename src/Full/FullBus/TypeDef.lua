-- Annotations ---------------------------------------------------------------------------------------------
export type Callback = (...any) -> ()
export type Connection = {
	Callback:Callback,
	Priority:number,
	Once:boolean,
	Filter:((any) -> boolean)?,
	Connected:boolean,
	EventName:string,
	_bus:FullBus,
}
export type SubscriptionGroup = {
	Add:(self:SubscriptionGroup, handle:DisconnectHandle) -> DisconnectHandle,
	Destroy:(self:SubscriptionGroup) -> (),
	Count:(self:SubscriptionGroup) -> number,
	_handles: {DisconnectHandle},
}
export type SubscribeOptions = {
	Priority:number?,
	Once:boolean?,
	Filter:((any) -> boolean)?,
	Async:boolean?,
	Group:SubscriptionGroup?,
}
export type SubscriberInfo = {
	Callback: Callback,
	Priority: number,
	Once: boolean,
	Filter: ((any) -> boolean)?,
	HandlerType: "Debounce" | "Batch" | "Throttle" | nil,
	WaitTime: number?,
	LastCallTime: number?,
}
export type CreateOpts = {
	EnableDebug:boolean?,
	MaxListenersPerEvent:number?,
	EnableWildcards:boolean?,
	AsyncByDefault:boolean?,
	StatsPrecision:number?,
	TimelineSize:number?,
	HistoryTreeOrder:number?,
	EnableDeduplication:boolean?,
	DeduplicationCacheSize:number?,
	DeduplicationCmsEpsilon:number?,
	DeduplicationCmsDelta:number?,
}
export type Middleware = (eventName:string, ...any) -> (...any)
export type BusStats = {
	Destroyed:boolean?,
	TotalEvents:number,
	TotalSubscribers:number,
	NormalSubscriptions:number,
	PrefixSubscriptions:number,
	TimeRangeSubscriptions:number,
	WildcardSubscriptions:number,
	StickyEvents:number,
	EventCounts:{[string]:number},
	SubscriberCounts:{[string]:number},
	EventHistory:{[string]:number},
	UniqueEventNamesEstimate:number,
	TimelineEventCount:number,
	TimelineWindowSize:number,
	PendingAuditLogSize:number,
	LastAuditRoot:string?,
}
export type DisconnectHandle = {
	Disconnect:(self:DisconnectHandle) -> (),
}
export type FullBus = {
	-- Lifecycle
	Destroy:typeof(
		--[[
			Completely removes and cleans up the event bus instance.
			Stops all background processes and releases memory.
			The bus cannot be used after being destroyed.
		]]
		function(self:FullBus) end
	),
	-- Subscriptions
	Subscribe:typeof(
		--[[
			Subscribes a callback function to a specific event name.
			Supports <strong>glob patterns</strong> if EnableWildcards is true.
			
			<code>local handle = bus:Subscribe("Player.Joined", onPlayerJoined)
		]]
		function(self:FullBus, eventName:string, callback:Callback, options:SubscribeOptions?):DisconnectHandle end
	),
	SubscribeOnce:typeof(
		--[[
			Subscribes a callback function that will only run <strong>one time</strong>
			and then automatically disconnect.
			
			<code>bus:SubscribeOnce("Game.Start", startGameLogic)
		]]
		function(self:FullBus, eventName:string, callback:Callback, options:SubscribeOptions?):DisconnectHandle end
	),
	SubscribeByPrefix:typeof(
		--[[
			Subscribes a callback to any event name that <strong>starts with</strong>
			the given prefix string.
			e.g., <code>bus:SubscribeByPrefix("Player.")</code> matches "Player.Joined", "Player.Left".
			
			<code>bus:SubscribeByPrefix("Entity.", handleEntityEvent)
		]]
		function(self:FullBus, prefix:string, callback:Callback, options:SubscribeOptions?):DisconnectHandle end
	),
	SubscribeTimeRange:typeof(
		--[[
			Subscribes a callback to an event, but only fires if the
			event is published within a specific time-of-day range.
			Time is expressed in seconds since midnight (0 to 86399).
			
			<code>bus:SubscribeTimeRange("Tick", 3600, 7200, handleNightlyTick)
		]]
		function(self:FullBus, eventName:string, low:number, high:number, callback:Callback, options:SubscribeOptions?):DisconnectHandle end
	),
	SubscribeDebounced:typeof(
		--[[
			Subscribes a callback that only fires after 'waitTime' seconds have
			passed without another event being published. Uses arguments from the
			last event in the quiet period.
		]]
		function(self:FullBus, eventName:string, waitTime:number, callback:Callback, options:SubscribeOptions?):DisconnectHandle end
	),
	SubscribeBatched:typeof(
		--[[
			Subscribes a callback that collects all events published over 'waitTime'
			seconds and fires the callback with a table of all event argument sets.
		]]
		function(self:FullBus, eventName:string, waitTime:number, callback:Callback, options:SubscribeOptions?):DisconnectHandle end
	),
	SubscribeThrottled:typeof(
		--[[
			Subscribes a callback that fires immediately on the first event,
			but then ignores all subsequent events for 'waitTime' seconds.
			(Unlike debounce, which waits for a quiet period).
		]]
		function(self:FullBus, eventName:string, waitTime:number, callback:Callback, options:SubscribeOptions?):DisconnectHandle end
	),
	SubscribeToAll:typeof(
		--[[
			Subscribes a callback to <strong>all</strong> events published on the bus.
			This is a "catch-all" that fires for every event,
			ideal for global logging or debugging.
			
			<code>bus:SubscribeToAll(function(eventName, ...)
				print("Event fired:", eventName)
			end)
		]]
		function(self:FullBus, callback:Callback, options:SubscribeOptions?):DisconnectHandle end
	),
	CreateChildBus:typeof(
		--[[
			Creates a new, namespaced event bus.
			Events published on the child bus are automatically
			prefixed and published on the parent.
			
			<code>local playerBus = bus:CreateChildBus("Player.123")
			-- This publishes "Player.123.Joined" on the parent bus
			playerBus:Publish("Joined")
		]]
		function(self:FullBus, prefix:string):FullBus end
	),
	Request:typeof(
		--[[
			Publishes an event and yields until a 'Reply'
			is received or a timeout occurs. Implements a
			request/response pattern.
			
			<code>local ok, data = bus:Request("GetPlayerData", 5, 123) -- 5 sec timeout, player ID 123
		]]
		function(self:FullBus, eventName:string, timeout:number?, ...:any): (boolean, ...any) end
	),
	Reply:typeof(
		--[[
			Subscribes to a 'Request' event and provides a response.
			The callback's return values are sent back to the requester.
			
			<code>bus:Reply("GetPlayerData", function(playerId)
				return DB:Get(playerId)
			end)
		]]
		function(self:FullBus, eventName:string, callback:Callback, options:SubscribeOptions?):DisconnectHandle end
	),
	Disconnect:typeof(
		--[[
			Manually disconnects a subscription handle.
			
			<code>bus:Disconnect(handle)
		]]
		function(self:FullBus, connection:Connection) end
	),
	Unsubscribe:typeof(
		--[[
			Quality-of-life function to disconnect subscriptions by event name and 
			the exact callback function used for subscription. Disconnects all 
			matching connections.
		]]
		function(self:FullBus, eventName:string, callback:Callback) end
	),
	WaitFor:typeof(
		--[[
			Yields the current coroutine until the specified event fires
			or an optional timeout is reached.
			
			<code>local ok, player = bus:WaitFor("Player.Joined", 5)
		]]
		function(self:FullBus, eventName:string, timeout:number?): (boolean, ...any) end
	),
	-- Publishing
	Publish:typeof(
		--[[
			Publishes an event to all matching subscribers.
			Callbacks are executed based on 'AsyncByDefault' config.
			May be dropped if a <strong>rate limit</strong> is exceeded.
			
			<code>bus:Publish("Player.Joined", player)
		]]
		function(self:FullBus, eventName:string, ...:any) end
	),
	PublishAsync:typeof(
		--[[
			Publishes an event to all matching subscribers <strong>in parallel</strong>.
			This function will <strong>wait</strong> until all callbacks finish.
			May be dropped if a rate limit is exceeded.
			
			<code>bus:PublishAsync("Data.Save", player)
		]]
		function(self:FullBus, eventName:string, ...:any) end
	),
	PublishSticky:typeof(
		--[[
			Publishes an event and caches the arguments. New subscribers to this
			event will immediately receive the cached arguments (replayed).
			
			<code>bus:PublishSticky("Game.State", "RUNNING")
		]]
		function(self:FullBus, eventName:string, ...:any) end
	),
	RemoveSticky:typeof(
		--[[
			Removes a cached sticky event published with PublishSticky.
			New subscribers will no longer receive this event
			on connection.
			
			<code>bus:RemoveSticky("Game.State")
		]]
		function(self:FullBus, eventName:string) end
	),
	PublishByPrefix:typeof(
		--[[
			Publishes an event to all subscribers who are subscribed
			to a prefix of the given event name.
			e.g., <code>bus:PublishByPrefix("Player.Joined")</code> will fire subs for
			"P", "Player", "Player.", and "Player.Joined".
			
			<code>bus:PublishByPrefix("System.Shutdown")
		]]
		function(self:FullBus, eventName:string, ...:any) end
	),
	-- Configuration & Middleware
	AddMiddleware:typeof(
		--[[
			Adds a middleware function that intercepts all published
			events <strong>before</strong> they are sent to subscribers.
			
			<code>bus:AddMiddleware(loggerMiddleware)
		]]
		function(self:FullBus, middlewareFunc:Middleware) end
	),
	RemoveMiddleware:typeof(
		--[[
			Removes a specific middleware function that was
			previously added with AddMiddleware.
			
			<code>bus:RemoveMiddleware(loggerMiddleware)
		]]
		function(self:FullBus, middlewareFunc:Middleware) end
	),
	SetEventRateLimit:typeof(
		--[[
			Applies a rate limit to a specific event name using a <strong>Token Bucket</strong>.
			
			<strong>@param eventName</strong> Event to limit
			<strong>@param refillRate</strong> Tokens to add per second
			<strong>@param capacity</strong> Maximum tokens the bucket can hold
			
			<code>bus:SetEventRateLimit("Chat.Message", 5, 10) -- 5 messages/sec, burst up to 10
		]]
		function(self:FullBus, eventName:string, refillRate:number, capacity:number) end
	),
	SetDebug:typeof(
		--[[
			Enables or disables <strong>verbose debug warnings</strong>.
			
			<code>bus:SetDebug(true)
		]]
		function(self:FullBus, enabled:boolean) end
	),
	-- Cleanup
	Clear:typeof(
		--[[
			Removes all subscribers for a <strong>specific</strong> event name.
			
			<code>bus:Clear("Player.Joined")
		]]
		function(self:FullBus, eventName:string) end
	),
	ClearAll:typeof(
		--[[
			Removes <strong>all</strong> subscribers from the event bus.
			
			<code>bus:ClearAll()
		]]
		function(self:FullBus) end
	),
	-- Introspection & New Algorithm Features
	GetStats:typeof(
		--[[
			Returns a table of statistics about the event bus.
			
			<code>local stats = bus:GetStats()
		]]
		function(self:FullBus):BusStats end
	),
	GetEventHistoryRange:typeof(
		--[[
			Returns a log of all events published within a given
			<code>os.clock()</code> time range.
			
			<strong>@return</strong> <code>{{key:number, value:{Name:string, Args:{any}}}</code>
			
			<code>local history = bus:GetEventHistoryRange(startTime, endTime)
		]]
		function(self:FullBus, startTime:number, endTime:number):{any} end
	),
	GetEventProof:typeof(
		--[[
			Returns the Merkle Proof for an event at a given index
			(based on its position in the log when the tree was built).
			
			<code>local proof = bus:GetEventProof(5)
		]]
		function(self:FullBus, index:number):{any}? end
	),
	GetPendingAuditLog:typeof(
		--[[
			Returns a copy of the current event log, <strong>before</strong> it
			has been built into an audit tree.
			
			<code>local pending = bus:GetPendingAuditLog()
		]]
		function(self:FullBus):{string} end
	),
	BuildAuditTree:typeof(
		--[[
			Consumes the pending event log, builds a Merkle Tree,
			and returns the <strong>root hash</strong>. Clears the pending log.
			
			<code>local rootHash = bus:BuildAuditTree()
		]]
		function(self:FullBus):string? end
	),
	GetAuditRoot:typeof(
		--[[
			Gets the <strong>root hash</strong> of the <strong>last</strong> built audit tree.
			
			<code>local lastRoot = bus:GetAuditRoot()
		]]
		function(self:FullBus):string? end
	),
	VerifyWithLastRoot:typeof(
		--[[
			Verifies if a given leaf (event string) and proof
			match the last built Merkle Tree root.
			
			<code>local isValid = bus:VerifyWithLastRoot(proof, leafData)
		]]
		function(self:FullBus, proof:{any}, leafData:string):boolean end
	),
	ReadOnly: typeof(
		--[[
			Enables or disables read-only mode. When enabled,
			all methods that modify the bus state (Publish, Subscribe,
			Disconnect, Clear, etc.) will be disabled.

			<code>bus:ReadOnly(true) -- Enable read-only
			bus:ReadOnly(false) -- Disable read-only
		]]
		function(self: FullBus, state:boolean) end
	),
	-- Signals
	OnPublish: typeof(
		--[[
			Connects a callback that runs whenever an event is successfully
			published (after middleware, before subscribers are called).
			Callback receives: (eventName:string, args:{any})
			
			<code>bus:OnPublish(function(eventName, args)
				print("Event Published:", eventName)
			end)
		]]
		function(self: FullBus, fn: (eventName:string, args:{any})->()): number end
	),
	OnSubscribe: typeof(
		--[[
			Connects a callback that runs whenever a new subscription is successfully added.
			Callback receives: (eventName:string, connection:Connection)
			
			<code>bus:OnSubscribe(function(eventName, conn)
				print("New subscriber for:", eventName)
			end)
		]]
		function(self: FullBus, fn: (eventName:string, connection:Connection)->()): number end
	),
	OnDisconnect: typeof(
		--[[
			Connects a callback that runs whenever a subscription is disconnected.
			Callback receives: (eventName:string, connection:Connection)
			
			<code>bus:OnDisconnect(function(eventName, conn)
				print("Subscriber disconnected from:", eventName)
			end)
		]]
		function(self: FullBus, fn: (eventName:string, connection:Connection)->()): number end
	),
	OnError: typeof(
		--[[
			Connects a callback that runs whenever a subscriber callback throws an error.
			Callback receives: (eventName:string, failingCallback:Callback, errorMsg:string, originalArgs:{any})
			
			<code>bus:OnError(function(evName, cb, err, args)
				print("Error in", evName, err)
			end)
		]]
		function(self: FullBus, fn: ErrorCallback): number end
	),
	DisconnectSignal: typeof(
        --[[
            Disconnects a signal connection using the ID returned by OnPublish, OnSubscribe, etc.

            <code>local id = bus:OnError(...)
            bus:DisconnectSignal(bus._errorSignal, id) -- Requires knowing the internal signal object
        ]]
		-- OR provide specific methods like DisconnectOnError(id), DisconnectOnPublish(id) etc.
		function(self: FullBus, signalInstance: any, connectionId: number) end
	),
	-- Introspection
	Keys: typeof(
		--[[
			Returns a list of all unique event names/patterns that
			currently have active subscribers.

			<code>local activeKeys = bus:Keys()
		]]
		function(self: FullBus): {string} end
	),
	Subscribers: typeof(
		--[[
			Returns detailed information about all active subscribers
			for a specific, exact event name (does not handle wildcards
			or prefixes directly).

			<code>local subs = bus:Subscribers("Player.Joined")
			for _, subInfo in ipairs(subs) do
				print(" - Priority:", subInfo.Priority)
			end
		]]
		function(self: FullBus, eventName: string): {SubscriberInfo} end
	),
	ForEach: typeof(
		--[[
			Invokes a provided function once for each active,
			non-wildcard, non-prefix, non-timerange subscription.
			The function receives (eventName, connection).
			Iteration order is not guaranteed.

			<code>bus:ForEach(function(eventName, conn)
				print("Active sub:", eventName)
			end)
		]]
		function(self: FullBus, fn: (eventName: string, connection: Connection) -> ()) end
	),
	Transaction: typeof(
		--[[
			Executes a block of code within a single, atomic transaction.
			The bus is locked before the function begins and unlocked after it completes.
			Operations performed on the provided 'txBus' instance within the
			function are queued and applied atomically upon successful completion.
			If the function errors, none of the operations are applied.

			<code>local success, result = bus:Transaction(function(txBus)
				local handle = txBus:Subscribe("EventA", callback)
				txBus:Publish("EventB", 123)
				-- txBus:Disconnect(someHandle) -- Disconnect operations can be tricky to journal
				return "Completed"
			end)
		]]
		function(self: FullBus, transactionFn: (txBus: FullBus) -> any): (boolean, any?) end
	),
}
export type Static = {
	Create:typeof(
		--[[
			Creates a new event bus instance.
		]]
		function(Name:string, Opts:CreateOpts?):FullBus<T> end
	)
}
------------------------------------------------------------------------------------------------------------
export type Master = {
	Callback: Callback,
	Connection: Connection,
	SubscriptionGroup: SubscriptionGroup,
	SubscribeOptions: SubscribeOptions,
	SubscriberInfo: SubscriberInfo,
	CreateOpts: CreateOpts,
	Middleware: Middleware,
	BusStats: BusStats,
	DisconnectHandle: DisconnectHandle,
	FullBus: FullBus,
	Static: Static,
}
local TypeDef = {}
return TypeDef :: Master
