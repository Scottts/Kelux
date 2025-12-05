--[[ 
    [ FULLPOOL DOCUMENTATION ]
    Version: 0.1.725 (STABLE)

    Author: Kel (@GudEveningBois)

    1. Introduction
    
        FullPool is a high-performance, robust object pooling system for Luau. 
        It is designed to manage the lifecycle of instances, reducing the 
        overhead of creating and destroying objects frequently. By recycling
        instances, FullPool improves performance, especially in scenarios 
        with high object churn (e.g., visual effects, projectiles, UI elements).

        It is highly configurable and provides advanced features like automated
        leasing, configurable sizing, template instances, validation callbacks,
        rate-limiting, and persistence.

        Key Features:
        
            Instance Pooling:
                Efficiently Get() and Return() instances, with support for different retrieval priorities.
            Configurable Sizing:
                Set initial and maximum pool sizes, and dynamically Resize() the pool at runtime.
            Template-Based Creation:
                Create new instances by cloning a provided templateInstance.
            Automated Leasing:
                Retrieve instances with GetWithLease() for a specific duration (TTL).
                Leases can be extended with Touch() or made permanent with Pin().
            Asynchronous Pre-warming:
                Use Prefetch() to populate the pool with instances in the background.
            Bulk Operations:
                Use BulkGet() and BulkReturn() for high-throughput scenarios.
            Static Pool Management:
                Create, retrieve, and manage multiple named pools using glob patterns 
                (e.g., GetPoolsByPattern(), DestroyByPattern()).
            Persistence:
                Save a pool's configuration and (optionally) its idle instances to a 
                JSON string with Snapshot(), and restore it with FromSnapshot().
            Introspection & Stats:
                Get a comprehensive snapshot of pool statistics with GetStats().
            Rate-Limiting:
                Configure a 'getsPerSecond' limit to throttle pool retrieval.

    2. Getting Started
    
        To begin, create or retrieve a pool instance using 'FullPool.Create'.
        Pools are identified by a unique name.

        FullPool.Create(poolName, config)
                Creates a new named pool or retrieves an existing one.
        Parameters:
                poolName (string) - The unique name for the pool.
                config (table?) [Optional] - Configuration options.
        
        Options Table (config):
            * 'instanceType' (string) [Required for new pools] - The ClassName of the instance to pool (e.t., "Part"). Required if 'templateInstance' is not set.
            * 'templateInstance' (Instance?) [Optional] - An instance to :Clone() for creating new pool items. If set, 'instanceType' is inferred.
            * 'maxSize' (number?): Max instances the pool can hold (active + idle). Default: 100.
            * 'initialSize' (number?): Number of instances to create immediately. Default: 10.
            * 'cleanupCallback' (function?): Called on an instance during Return(). Receives (instance).
            * 'validateCallback' (function?): Called on an instance during Get(). Receives (instance), returns (boolean). If false, instance is destroyed.
            * 'autoShrinkDelay' (number?): Seconds of inactivity after a Return() before shrinking idle instances to 'initialSize'. Default: nil (disabled).
            * 'getsPerSecond' (number?): Applies a Token Bucket rate limit to Get() and TryGet() calls. Default: nil (disabled).

        Example: 
            ---------------------------------------------------------------------------- 
            local FullPool = require(script.Parent.FullPool) -- Adjust path
            
            -- Create a new pool for basepart instances
            local partPool = FullPool.Create("PartPool", {
                instanceType = "Part",
                maxSize = 150,
                initialSize = 20,
                cleanupCallback = function(part)
                    part.Parent = nil
                    part.Anchored = false
                    part.Transparency = 0
                end
            })

            -- Retrieve the same pool later and resize it
            local samePool = FullPool.Create("PartPool", {
                maxSize = 200
            })
            ----------------------------------------------------------------------------

    3. Core Concepts
    
        Pooling (Get/Return):
            Instead of destroying instances, you 'Return()' them to the pool. Instead of
            creating new ones, you 'Get()' them from the pool. This recycles
            instances, avoiding the cost of creation and garbage collection.
            
        Leasing (GetWithLease):
            A powerful feature where you can 'GetWithLease(ttl)' an instance for a
            set time-to-live (in seconds). If you don't return it manually, the
            pool will automatically reclaim and 'Return()' it once the lease expires.
            This is excellent for temporary effects or objects you might forget to clean up.
            
        Pool Management:
            FullPool manages all pools statically. You 'Create' and access pools by name.
            This allows you to manage groups of pools at once, e.g.,
            'FullPool.DestroyByPattern("VFX:*")' to clean up all visual effect pools.
            
        Persistence (Snapshot/FromSnapshot):
            You can serialize a pool's configuration (and optionally, all its *idle*
            instances) into a JSON string using 'Snapshot()'. This string can be
            saved and later used with 'FromSnapshot()' to restore the pool's state,
            which is useful for scene transitions or saving/loading.

    4. API Reference
    
        The API is split into two parts:
        1. Static API: Functions called directly on the 'FullPool' module (e.g., FullPool.Create).
        2. Instance API: Methods called on a specific pool instance (e.g., partPool:Get).

        [ Static API ]
        
            FullPool.Create(poolName: string, config: PoolConfig?) -> FullPool
                Creates a new named pool or retrieves an existing one.
                If a pool with the specified "poolName" already exists, this function
                returns the existing pool and dynamically applies any new configurations
                provided. If the pool does not exist, it creates a new one.
                
                Example:
                ----------------------------------------------------------------------------
                local partPool = FullPool.Create("PartPool", {
                    instanceType = "Part",
                    maxSize = 150
                })
                ----------------------------------------------------------------------------

            FullPool.FromSnapshot(snapshotString: string) -> FullPool?
                Creates a new pool instance by deserializing its configuration and,
                optionally, its idle instances from a JSON string previously
                generated by the Snapshot() method.
                Returns the newly created FullPool instance, or nil if deserialization fails.

                Example:
                ----------------------------------------------------------------------------
                local restoredPool = FullPool.FromSnapshot(snapshotJsonString)
                if restoredPool then
                    local instance = restoredPool:Get()
                end
                ----------------------------------------------------------------------------
                
            FullPool.GetPoolsByPattern(pattern: string) -> {FullPool}
                Retrieves all pool instances whose names match a glob pattern.
                Uses a high-speed Trie search.

                Example:
                ----------------------------------------------------------------------------
                -- Get all visual effect pools
                local vfxPools = FullPool.GetPoolsByPattern("VFX:*")
                for _, pool in ipairs(vfxPools) do
                    print(pool.Name)
                end
                ----------------------------------------------------------------------------

            FullPool.DestroyByPattern(pattern: string) -> number
                Finds and destroys all pool instances matching a glob pattern.
                Returns the number of pools that were destroyed.

                Example:
                ----------------------------------------------------------------------------
                local destroyedCount = FullPool.DestroyByPattern("Temp:*")
                ----------------------------------------------------------------------------
                
            FullPool.PrefetchByPattern(pattern: string, countPerPool: number) -> number
                Triggers Prefetch() for all pools matching a glob pattern.
                Returns the number of pools affected.

                Example:
                ----------------------------------------------------------------------------
                FullPool.PrefetchByPattern("Enemies:*", 10) -- Prefetch 10 each
                ----------------------------------------------------------------------------
                
            FullPool.ShrinkByPattern(pattern: string, targetSize: number?) -> number
                Triggers Shrink() for all pools matching a glob pattern.
                Returns the number of pools affected.

                Example:
                ----------------------------------------------------------------------------
                FullPool.ShrinkByPattern("VFX:*", 5) -- Shrink to 5 idle each
                ----------------------------------------------------------------------------
                
        [ Instance API ]

	        [ Core Lifecycle & Retrieval ]

	            pool:Get(priority: PoolPriority?) -> Instance?
	                Retrieves an instance from the pool. If empty, a new one is created.
	                If pool is at max capacity:
	                * "low" priority returns nil.
	                * "normal" or higher will wait for an instance.
	                'priority' can be "low" | "normal" | "high" | "critical".
	                
	                Example:
	                ----------------------------------------------------------------------------
	                local part = myPool:Get("normal")
	                ----------------------------------------------------------------------------
	                
	            pool:Return(instance: Instance)
	                Returns an instance to the pool, making it available for reuse.
	                
	                Example:
	                ----------------------------------------------------------------------------
	                myPool:Return(part)
	                ----------------------------------------------------------------------------

	            pool:GetWithLease(ttl: number, priority: PoolPriority?) -> Instance?
	                Retrieves an instance with an automated lease (in seconds).
	                If not returned manually, the pool will reclaim it after 'ttl' seconds.
	                Returns nil if priority is "low" and pool is full.

	                Example:
	                ----------------------------------------------------------------------------
	                local part = myPool:GetWithLease(30, "normal") -- Auto-returns after 30s
	                ----------------------------------------------------------------------------
	                
	            pool:TryGet() -> Instance?
	                Retrieves an instance *only* if one is currently idle in the pool.
	                This function will never create a new instance and never wait.
	                
	                Example:
	                ----------------------------------------------------------------------------
	                local part = myPool:TryGet()
	                if part then
	                    -- Stuff...
	                end
	                ----------------------------------------------------------------------------
	                
	            pool:Prefetch(count: number, onComplete: function?)
	                Asynchronously creates new instances to populate the pool up to the desired count.
	                Ideal for loading screens or before anticipated high-demand events.
	                
	                Example:
	                ----------------------------------------------------------------------------
	                myPool:Prefetch(20, function()
	                    print("20 instances have been prefetched!")
	                end)
	                ----------------------------------------------------------------------------

	        [ Bulk Operations ]

	            pool:BulkGet(count: number, priority: PoolPriority?) -> {Instance}
	                Retrieves multiple instances from the pool in a single, synchronous call.
	                
	                Example:
	                ----------------------------------------------------------------------------
	                local fiveParts = myPool:BulkGet(5)
	                ----------------------------------------------------------------------------

	            pool:BulkReturn(instances: {Instance})
	                Returns multiple instances to the pool in a single call.
	                
	                Example:
	                ----------------------------------------------------------------------------
	                myPool:BulkReturn(fiveParts)
	                ----------------------------------------------------------------------------
	                
	        [ Dynamic Configuration & Control ]

	            pool:Resize(newMaxSize: number)
	                Adjusts the maximum number of instances the pool can hold.
	                If the new size is smaller, idle instances will be evicted and destroyed.
	                
	                Example:
	                ----------------------------------------------------------------------------
	                myPool:Resize(200)
	                ----------------------------------------------------------------------------
	                
	            pool:ReadOnly(state: boolean)
	                Enables or disables read-only mode. In read-only mode, new instances 
	                cannot be retrieved or created, but they can still be returned.
	                
	                Example:
	                ----------------------------------------------------------------------------
	                myPool:ReadOnly(true)
	                ----------------------------------------------------------------------------

	            pool:Pause()
	                Pauses the pool's background services, such as lease management.
	                
	            pool:Resume()
	                Resumes the pool's background services.

	        [ Instance Lifetime Management (Leasing) ]

	            pool:Touch(instance: Instance, timeBoost: number?) -> boolean
	                Extends the lease of a leased instance, resetting its TTL to its
	                original duration, plus an optional 'timeBoost' (in seconds).
	                Returns true if successful.
	                
	                Example:
	                ----------------------------------------------------------------------------
	                local success = myPool:Touch(leasedPart, 60) -- Add 60 seconds
	                ----------------------------------------------------------------------------
	                
	            pool:LeaseRemaining(instance: Instance) -> number?
	                Gets the remaining time in seconds on an instance's lease.
	                
	                Example:
	                ----------------------------------------------------------------------------
	                local remaining = myPool:LeaseRemaining(leasedPart)
	                ----------------------------------------------------------------------------
	                
	            pool:Pin(instance: Instance) -> boolean
	                Marks an active instance as non-evictable and exempt from lease expiration.
	                A pinned instance must be manually returned to the pool. Returns true if successful.
	                
	                Example:
	                ----------------------------------------------------------------------------
	                myPool:Pin(importantPart)
	                ----------------------------------------------------------------------------
	                
	            pool:Unpin(instance: Instance) -> boolean
	                Unpins an instance, making it eligible for lease expiration (if it has one)
	                and eviction again. Returns true if successful.
	                
	                Example:
	                ----------------------------------------------------------------------------
	                myPool:Unpin(importantPart)
	                ----------------------------------------------------------------------------

	        [ Advanced Introspection & Cleanup ]

	            pool:GetStats() -> PoolStats
	                Returns a comprehensive snapshot of the pool's current statistics.
	                The 'PoolStats' table includes: name, instanceType, pooledCount, 
	                activeCount, pinnedCount, totalCount, maxSize, gets, hits, misses, 
	                hitRate, creations, returns, evictions, leaseExpirations.
	                
	                Example:
	                ----------------------------------------------------------------------------
	                local stats = myPool:GetStats()
	                print("Hit Rate:", stats.hitRate)
	                ----------------------------------------------------------------------------
	                
	            pool:PeekAllActive() -> {Instance}
	                Returns a shallow copy of all currently active (in-use) instances
	                without affecting any policies or metadata.
	                
	            pool:PeekAllPooled() -> {Instance}
	                Returns a shallow copy of all currently idle (pooled) instances.
	                
	            pool:Shrink(targetSize: number?)
	                Forces the pool of idle instances to shrink to a specified size
	                by evicting the most recently returned instances. If 'targetSize'
	                is nil, it shrinks to the pool's 'initialSize'.
	                
	                Example:
	                ----------------------------------------------------------------------------
	                myPool:Shrink(10) -- Shrink idle pool to 10 instances
	                ----------------------------------------------------------------------------
	                
	            pool:ManualSweep(options: {expireLeasesOnly: boolean?})
	                Manually triggers the pool's cleanup mechanisms on demand.
	                * No options: Performs a full sweep (clears expired leases AND shrinks idle pool).
	                * {expireLeasesOnly = true}: Only reclaims instances whose leases have expired.
	                
	                Example:
	                ----------------------------------------------------------------------------
	                myPool:ManualSweep() -- Force a full cleanup
	                ----------------------------------------------------------------------------

	            pool:ReturnBy(predicate: (instance: Instance) -> boolean) -> number
	                Returns all active instances that satisfy the predicate function.
	                The predicate receives an instance and should return true if it should be returned.
	                Returns the number of instances returned.
	                
	                Example:
	                ----------------------------------------------------------------------------
	                -- Return all active instances named "Temp_FX"
	                local count = fxPool:ReturnBy(function(instance)
	                    return instance.Name == "Temp_FX"
	                end)
	                ----------------------------------------------------------------------------

	        [ Persistence & Destruction ]

	            pool:Snapshot(includeDescendants: boolean?) -> string?
	                Generates a JSON string representing the pool's configuration and,
	                optionally, the serialized state of its idle instances.
	                * If 'includeDescendants' is true, it serializes all idle instances and their children.
	                * If false or omitted, only the config and template (if any) are saved.
	                
	                Example:
	                ----------------------------------------------------------------------------
	                local fullStateJson = myPool:Snapshot(true)
	                ----------------------------------------------------------------------------

	            pool:Destroy()
	                Destroys all instances (active and idle) and cleans up the pool entirely.
	                The pool cannot be used after this is called.
	                
	                Example:
	                ----------------------------------------------------------------------------
	                myPool:Destroy()
	                ----------------------------------------------------------------------------
	                
    5. Practical Examples
        
        Example 1: Basic Get/Return
            ----------------------------------------------------------------------------
            local partPool = FullPool.Create("PartPool", { instanceType = "Part" })
            
            local part = partPool:Get()
            part.BrickColor = BrickColor.Red()
            part.Parent = workspace
            
            task.wait(3)
            
            -- Instead of part:Destroy(), return it
            partPool:Return(part)
            ----------------------------------------------------------------------------

        Example 2: Temporary Leased Effect
            ----------------------------------------------------------------------------
            local fxPool = FullPool.Create("FXPool", { templateInstance = game.ReplicatedStorage.ExplosionFX })

            -- This effect will be automatically returned after 5 seconds
            -- even if we don't manually return it.
            local explosion = fxPool:GetWithLease(5)
            explosion.Parent = workspace
            explosion:Play()
            ----------------------------------------------------------------------------

        Example 3: Pre-warming during Loading
            ----------------------------------------------------------------------------
            local bulletPool = FullPool.Create("BulletPool", {
                instanceType = "Part",
                maxSize = 200,
                initialSize = 0
            })
            
            print("Loading... pre-warming bullet pool.")
            -- Create 50 bullets in the background
            bulletPool:Prefetch(50, function()
                print("Bullet pool is ready. Game can start.")
            end)
            ----------------------------------------------------------------------------
            
        Example 4: Managing Groups of Pools
            ----------------------------------------------------------------------------
            -- Create pools for different enemy types
            local gruntPool = FullPool.Create("Enemy:Grunt", { templateInstance = game.ReplicatedStorage.Grunt })
            local bossPool = FullPool.Create("Enemy:Boss", { templateInstance = game.ReplicatedStorage.Boss })
            local minionPool = FullPool.Create("Enemy:Minion", { templateInstance = game.ReplicatedStorage.Minion })

            -- Game runs...

            -- At the end of the level, clean up all enemy pools
            local destroyedCount = FullPool.DestroyByPattern("Enemy:*")
            print("Cleaned up " .. destroyedCount .. " enemy pools.")
            ----------------------------------------------------------------------------

    6. Advanced Features
    
        Glob Pattern Matching:
            The static functions 'GetPoolsByPattern', 'DestroyByPattern', 'PrefetchByPattern',
            and 'ShrinkByPattern' use glob matching ('*') to manage multiple pools.
            This is extremely useful for grouping pools by name (e.g., "VFX:Sparks",
            "VFX:Fire") and managing them all with a single call like 'DestroyByPattern("VFX:*")'.
        
        Persistence (Snapshot/FromSnapshot):
            'Snapshot(true)' serializes all *idle* instances. This is powerful but
            can create very large JSON strings and may fail if instances contain
            un-serializable properties (like references to outside instances).
            'Snapshot(false)' is safer and only saves the configuration.
            'FromSnapshot' always creates a *new* pool with a unique internal name.
        
        Lease Management & Pinning:
            'Pin(instance)' is crucial for objects you 'Get' but decide you want to
            keep indefinitely, even if they were leased. A pinned instance is
            exempt from lease expiration and *must* be returned manually. 'Unpin()'
            re-enables lease expiration.
            
        Validation & Cleanup:
            The 'validateCallback' (runs on Get) and 'cleanupCallback' (runs on Return)
            are key for hygiene. Use 'validateCallback' to destroy instances that
            have broken or are in a bad state. Use 'cleanupCallback' to reset.
]]
