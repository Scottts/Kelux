--[[ 
    [ FULLBUS DOCUMENTATION ]
    Version: 0.1.757 (STABLE)

    Author: Kel (@GudEveningBois)

    1. Introduction
        FullBus is a robust event bus system designed to manage event 
        subscriptions, publishing, and data flow between different parts
        of an application. It is highly configurable and provides advanced 
        features like wildcard/prefix subscription matching, various publish strategies (sync, async, sticky), 
        rate-limiting, event history tracking with cryptographic auditing, event deduplication, 
        request/reply patterns, transactions, and more.

        Key Features:
        
            Event Subscription:
                Supports subscribing with specific callbacks, priorities, and filters. Includes standard, once, prefix, time-range, debounced, batched, and throttled subscriptions.
            Wildcard & Prefix Matching:
                Allows subscribing to events with wildcard glob patterns (e.g., "Player.*") or prefix matching (e.g., "System.").
            Event Publishing:
                Publishes events synchronously or asynchronously. Supports sticky events that replay to new subscribers and publishing to prefix-based subscribers.
            Rate-Limiting:
                Applies rate limits to specific events using the Token Bucket algorithm.
            Event History & Auditing:
                Tracks a history of published events. Can build a Merkle Tree from the event log for cryptographic verification.
            Event Deduplication:
                Optionally deduplicates identical events published close together using a Bloom Filter and xxHash.
            Request/Reply Pattern:
                Implements a request/response pattern with timeouts.
            Transactions:
                Executes multiple bus operations atomically.
            Signals & Introspection:
                Provides signals for publish, subscribe, disconnect, and error events. Allows introspection of active keys and subscribers.
            Concurrency:
                Uses a mutex for thread-safe operations.

    2. Getting Started
        To begin using FullBus, create an event bus instance using 'FullBus.Create'.

        FullBus.Create(Opts)
                Creates a new event bus instance.
        Parameters:
                Opts (table?) [Optional] - Configuration options.
        Options Table (Opts):
            * 'EnableDebug' (boolean): Verbose logging. Default: 'false'.
            * 'MaxListenersPerEvent' (number): Max subscribers per specific event name. Default: '100'.
            * 'EnableWildcards' (boolean): Allow glob patterns ('*') in 'Subscribe'. Default: 'true'.
            * 'AsyncByDefault' (boolean): Publish events asynchronously ('task.spawn'). Default: 'true'.
            * 'StatsPrecision' (number): HyperLogLog precision for unique event count estimate. Default: '12'.
            * 'TimelineSize' (number): Size of the rolling event count timeline. Default: '1000'.
            * 'HistoryTreeOrder' (number): Order (branching factor) for the B+ Tree storing event history. Default: '5'.
            * 'EnableDeduplication' (boolean): Use Bloom Filter/xxHash to drop identical consecutive events. Default: 'false'.
            * 'DeduplicationCacheSize' (number): Size of the Bloom Filter. Default: '100'.
            * 'DeduplicationCmsEpsilon' (number): Bloom Filter error rate epsilon. Default: '0.01'.
            * 'DeduplicationCmsDelta' (number): Bloom Filter error rate delta. Default: '0.001'.

        Example: 
            ---------------------------------------------------------------------------- 
            local FullBus = require(script.Parent.FullBus) -- Adjust path
            local bus = FullBus.Create({
                EnableDebug = true,
                MaxListenersPerEvent = 200,
                AsyncByDefault = false -- Prefer synchronous execution
            })
            ----------------------------------------------------------------------------

    3. Core Concepts
    
        Subscriptions:
            Register functions (callbacks) to be executed when specific events occur. Subscriptions can be configured with priorities, filters, and different behaviors (once, debounced, etc.).
        Publishing:
            Triggering an event by name, causing all relevant subscribed callbacks to execute with the provided arguments.
        Middleware:
            Functions that intercept all published events *before* subscribers are called, allowing modification or inspection of arguments.
        Event History & Auditing:
            The bus logs published events (timestamp, name, args). This log can be periodically processed into a Merkle Tree, allowing cryptographic verification that specific events occurred.
        Event Deduplication:
            When enabled, uses a Bloom Filter and xxHash to detect and drop events that are identical (name + arguments) to the immediately preceding one. This is different from LFU caching.

    4. API Reference (Types defined in FullBus source code)
        
        Creation & Lifecycle:
        
            FullBus.Create(Opts?) -> FullBus
                Creates a new event bus instance. See Getting Started.
            bus:Destroy()
                Cleans up the bus, disconnects subscribers, stops processes.

        Subscription Operations:
        
            bus:Subscribe(eventName: string, callback: Callback, options?: SubscribeOptions) -> DisconnectHandle
                Subscribes a callback to an event name or glob pattern. Returns a handle with a '.Disconnect()' method.
            bus:SubscribeOnce(eventName: string, callback: Callback, options?: SubscribeOptions) -> DisconnectHandle
                Subscribes a callback that runs only once.
            bus:SubscribeByPrefix(prefix: string, callback: Callback, options?: SubscribeOptions) -> DisconnectHandle
                Subscribes to any event starting with the prefix.
            bus:SubscribeTimeRange(eventName: string, low: number, high: number, callback: Callback, options?: SubscribeOptions) -> DisconnectHandle
                Subscribes, but only fires if published within the time-of-day range (seconds since midnight). Handles midnight wrap-around.
            bus:SubscribeDebounced(eventName: string, waitTime: number, callback: Callback, options?: SubscribeOptions) -> DisconnectHandle
                Fires only after 'waitTime' seconds of inactivity on the event, using the last event's args.
            bus:SubscribeBatched(eventName: string, waitTime: number, callback: Callback, options?: SubscribeOptions) -> DisconnectHandle
                Collects all args from events over 'waitTime' seconds, then fires with a table of argument lists.
            bus:SubscribeThrottled(eventName: string, waitTime: number, callback: Callback, options?: SubscribeOptions) -> DisconnectHandle
                Fires immediately on the first event, then ignores events for 'waitTime' seconds.
            bus:SubscribeToAll(callback: Callback, options?: SubscribeOptions) -> DisconnectHandle
                Subscribes to *all* events published on the bus. Callback receives '(eventName, ...args)'.
            bus:Disconnect(connection: Connection)
                Manually disconnects a subscription using its internal connection object (less common). Prefer using the returned DisconnectHandle.
            bus:Unsubscribe(eventName: string, callback: Callback)
                Finds and disconnects all subscriptions matching the exact event name and callback function reference.
            bus:CreateSubscriptionGroup() -> SubscriptionGroup
                Creates a group object to manage multiple subscriptions. Add handles via 'options.Group'. Call 'group:Destroy()' to disconnect all handles in the group.

        Publishing Operations:
        
            bus:Publish(eventName: string, ...args)
                Publishes an event. Execution mode (sync/async) depends on 'AsyncByDefault'.
            bus:PublishAsync(eventName: string, ...args)
                Publishes asynchronously and *yields* until all subscribers complete.
            bus:PublishSticky(eventName: string, ...args)
                Publishes and caches the event args. New subscribers immediately receive the cached args.
            bus:RemoveSticky(eventName: string)
                Removes a cached sticky event.
            bus:PublishByPrefix(eventName: string, ...args)
                Fires subscribers listening to prefixes of the 'eventName' (e.g., "A", "A.B" for "A.B.C").

        Request/Reply & Waiting:

            bus:Request(eventName: string, timeout?: number, ...args) -> (boolean, ...any)
                Publishes, then waits for a 'Reply' or timeout. Returns '(success, ...results)' or '(false, errorMsg)'.
            bus:Reply(eventName: string, callback: Callback, options?: SubscribeOptions) -> DisconnectHandle
                Subscribes to handle a 'Request'. The callback's return values are sent back.
            bus:WaitFor(eventName: string, timeout?: number) -> (boolean, ...any)
                Yields until the event fires or timeout occurs. Returns '(true, ...args)' or '(false)'.

        Configuration & Middleware:
        
            bus:AddMiddleware(middlewareFunc: Middleware)
                Adds a middleware function '(eventName, ...args) -> ...newArgs'. Middleware functions chain their return values. 
                Returning nothing ('nil') effectively stops the chain for that event (subscribers won't be called). 
                Does not support returning 'false' to cancel.
            bus:RemoveMiddleware(middlewareFunc: Middleware)
                Removes a specific middleware function reference.
            bus:SetEventRateLimit(eventName: string, refillRate: number, capacity: number)
                Applies a Token Bucket rate limit to an event.
            bus:SetDebug(enabled: boolean)
                Toggles verbose debug logging at runtime.
            bus:ReadOnly(state: boolean)
                Enables/disables read-only mode, preventing state changes (Subscribe, Publish, etc.).

        Cleanup:
        
            bus:Clear(eventName: string)
                Removes all subscribers for a specific event name.
            bus:ClearAll()
                Removes *all* subscribers from the bus.

        Introspection & Auditing:
        
            bus:GetStats() -> BusStats
                Returns a table of various statistics.
            bus:GetEventHistoryRange(startTime: number, endTime: number) -> {{key: number, value: {Name: string, Args: {any}}}}
                Retrieves historical event logs between 'os.clock()' timestamps. Args are deserialized.
            bus:GetPendingAuditLog() -> {string}
                Returns the list of serialized event hashes waiting to be built into a Merkle Tree.
            bus:BuildAuditTree() -> string?
                Builds a Merkle Tree from the pending log, clears the log, stores the tree, and returns the root hash.
            bus:GetAuditRoot() -> string?
                Gets the root hash of the last built Merkle Tree.
            bus:GetEventProof(index: number) -> {any}?
                Gets the Merkle proof for an event at a specific index *from the last built tree*.
            bus:VerifyWithLastRoot(proof: {any}, leafData: string) -> boolean
                Verifies if a proof and leaf hash match the last tree root.
            bus:Keys() -> {string}
                Returns a list of all event names/patterns with active subscribers.
            bus:Subscribers(eventName: string) -> {SubscriberInfo}
                Returns detailed info about subscribers for an *exact* event name.
            bus:ForEach(fn: (eventName: string, connection: Connection) -> ())
                Calls 'fn' for each active, non-specialized subscription.

        Signals (for monitoring the bus itself):

            bus:OnPublish(fn: (eventName: string, args: {any}) -> ()) -> number
                Connects a callback fired just before subscribers are called. Returns connection ID.
            bus:OnSubscribe(fn: (eventName: string, connection: Connection) -> ()) -> number
                Connects a callback fired after a successful subscription. Returns connection ID.
            bus:OnDisconnect(fn: (eventName: string, connection: Connection) -> ()) -> number
                Connects a callback fired after a disconnection. Returns connection ID.
            bus:OnError(fn: (eventName: string, failingCallback: Callback, errorMsg: string, originalArgs: {any}) -> ()) -> number
                Connects a callback fired when a subscriber errors. Returns connection ID.
            bus:DisconnectSignal(signalInstance: any, connectionId: number)
                Disconnects a signal connection using its ID and the internal signal object (e.g., 'bus._publishSignal').

        Transactions:

            bus:Transaction(transactionFn: (txBus: FullBus) -> any) -> (boolean, ...any)
                Executes 'transactionFn' atomically. Operations called on 'txBus' inside the function are queued
                and applied only if the function succeeds without errors. Returns '(true, ...results)' or '(false, error)'.

    5. Practical Examples
        
        Example 1: Basic Pub/Sub
            ----------------------------------------------------------------------------
            local bus = FullBus.Create()
            local function onPlayerJoined(player) print(player.Name .. " has joined!") end
            local handle = bus:Subscribe("Player.Joined", onPlayerJoined)
            bus:Publish("Player.Joined", { Name = "Alice" }) -- Triggers onPlayerJoined
            handle:Disconnect() -- Clean up listener
            ----------------------------------------------------------------------------

        Example 2: Request/Reply
            ----------------------------------------------------------------------------
            local bus = FullBus.Create({ AsyncByDefault = false }) -- Easier for sync request/reply
            -- Service providing data
            local dataStore = { Player123 = { Score = 100 } }
            bus:Reply("GetScore", function(playerId)
                return dataStore[playerId] and dataStore[playerId].Score
            end)
            -- Requester
            task.spawn(function()
                local ok, score = bus:Request("GetScore", 2, "Player123") -- 2 sec timeout
                if ok then print("Player Score:", score) else print("Failed to get score:", score) end
            end)
            ----------------------------------------------------------------------------

        Example 3: Debounced Input
            ----------------------------------------------------------------------------
            local bus = FullBus.Create()
            local userInput = ""
            -- Only update search results 300ms after user stops typing
            bus:SubscribeDebounced("UserInput", 0.3, function(text)
                print("Searching for:", text)
                -- UpdateSearchResults(text) 
            end)
            -- Simulate typing
            bus:Publish("UserInput", "h")
            task.wait(0.1)
            bus:Publish("UserInput", "he")
            task.wait(0.1)
            bus:Publish("UserInput", "hel") -- This one should trigger the search after 0.3s
            ----------------------------------------------------------------------------
            
        Example 4: Transactional Update
            ----------------------------------------------------------------------------
            local bus = FullBus.Create()
            local counter = 0
            bus:Subscribe("CounterIncremented", function(newCount) counter = newCount end)
            
            local success, err = bus:Transaction(function(txBus)
                local currentVal = counter -- Read state *before* transaction modifies
                local newVal = currentVal + 1
                txBus:Publish("CounterIncremented", newVal) -- Queue the publish
                -- Other atomic ops could go here
                if newVal > 10 then error("Counter limit exceeded") end -- This would rollback the publish
            end)
            
            if success then print("Counter updated to:", counter) 
            else print("Transaction failed:", err) end
            ----------------------------------------------------------------------------

    6. Advanced Features
    
        Wildcard/Prefix Matching:
            'Subscribe' supports '*' as a wildcard for any sequence within an event name segment. 
            'SubscribeByPrefix' matches any event starting with the given string. Remember event 
            names are typically dot-separated ('System.Log.Info').
        
        Middleware Chain:
            Middleware functions execute sequentially in the order they were added. 
            The arguments returned by one middleware become the input for the next. 
            Returning nothing ('nil') breaks the chain and prevents subscribers 
            from being called for that specific publish event.
        
        Event History & Auditing:
            Events are logged with 'os.clock()' timestamps. 'BuildAuditTree' processes the pending 
            log into a Merkle Tree, useful for verifying event integrity or order externally. 
            'GetEventHistoryRange' queries the B+ Tree storage.
            
        Asynchronous Considerations:
            When 'AsyncByDefault' is 'true' (the default), 'Publish' uses 'task.spawn' for each 
            subscriber call. This improves responsiveness but means subscribers run in parallel 
            and potentially out of order. 'PublishAsync' provides a way to wait for all spawned 
            tasks to complete. Synchronous mode ('AsyncByDefault = false') executes subscribers 
            sequentially within the 'Publish' call.

        Concurrency & Thread-Safety:
            FullBus uses an internal mutex ('_lock') to protect its internal state during operations 
            like adding/removing subscribers or modifying middleware. This ensures safe usage in 
            environments where multiple threads might interact with the same bus instance.
]]

--[[
	[ BENCHMARK - FullBus ]
		Benchmarks were conducted in Roblox's server environment.
		Timings reflect typical performance under benchmark conditions.
		Results may vary based on system load and callback complexity.
		
		FullBus version: v0.1.757 (STABLE)
		Mode: Server
		NUM_OPERATIONS_PUB = 5000
		NUM_OPERATIONS_SUB = 1000
		NUM_SUBSCRIBERS_FEW = 10
		NUM_SUBSCRIBERS_MANY = 1000
		
	[ Subscription Speed ]
		| Operation          			 | Performance       | Notes                                    		|
		| ------------------------------ | ----------------- | ------------------------------------------------ |
		| Subscribe() (Many) 			 | ~7,407 ops/sec    | Adding 1000 subs to a single event 				|
		
	[ Publish Speed (Synchronous) ]
		| Operation                      | Performance       | Notes                        					|
		| ------------------------------ | ----------------- | ------------------------------------------------ |
		| Publish() (Few Subs, Sync)     | ~36,982 ops/sec   | 10 subscribers									|
		| Publish() (Many Subs, Sync)    | ~1,082 ops/sec    | 1000 subscribers 								|
		
		Performance scales down linearly as synchronous subscriber count increases.
		
	[ Publish Speed (Asynchronous Dispatch) ]
		| Operation                      | Performance       | Notes                     				   	    |
		| ------------------------------ | ----------------- | ------------------------------------------------ |
		| Publish() (Few Subs, Async)    | ~20,156 ops/sec   | 10 subscribers 									|
		| Publish() (Many Subs, Async)   | ~313 ops/sec      | 1000 subscribers 								|
		
		Measures dispatch speed (task creation), not completion.
		High subscriber counts incur significant task scheduling overhead.
		Yielding was added to the 'Many Subs' benchmark to prevent script timeouts.
		
	[ Sticky Replay Speed ]
		| Operation                      | Performance      | Notes             	          	   				|
		| ------------------------------ | ---------------- | ------------------------------------------------- |
		| Sticky Replay (Many Subs)      | ~4,961 ops/sec   | Replaying event during Subscribe() 				|
		
		Replaying sticky events to new subscribers is relatively efficient.
		
	[ Request/Reply & WaitFor ]
		| Operation        			     | Performance      | Notes                                      	   |
		| ------------------------------ | ---------------- | ------------------------------------------------ |
		| Request/Reply Cycle 			 | ~60 ops/sec      | Includes 2 publishes, yield, reply processing    |
		| WaitFor Latency    			 | ~59 ops/sec      | Includes yield, time for event publish/capture   |
		
		Operations involving yielding inherently have lower throughput.
		Benchmark includes necessary yields to prevent re-entrancy errors in tight loops.
]]
