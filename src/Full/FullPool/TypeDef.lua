-- Annotations ---------------------------------------------------------------------------------------------
export type PoolConfig = {
	name: string?,
	maxSize: number?,
	initialSize: number?,
	templateInstance: Instance?,
	cleanupCallback: ((Instance) -> ())?,
	validateCallback: ((Instance) -> boolean)?,
	autoShrinkDelay: number?,
	getsPerSecond: number?,
}
export type PoolPriority = "low" | "normal" | "high" | "critical"
export type PoolStats = {
	name: string,
	instanceType: string,
	-- Counts
	pooledCount: number,
	activeCount: number,
	pinnedCount: number,
	totalCount: number,
	maxSize: number,
	-- Lifetime Metrics
	gets: number,
	hits: number,
	misses: number,
	hitRate: number,
	creations: number,
	returns: number,
	evictions: number,
	leaseExpirations: number,
}
export type FullPool<T> = {
	-- Properties
	Name: string,
	InstanceType: string,
	OnGet: any,
	OnReturn: any,
	OnCreate: any,
	OnDestroy: any,
	OnHit: any,
	OnMiss: any,
	-- Core Lifecycle & Retrieval
	Get: typeof(
		--[[
			Retrieves an instance from the pool.
			If the pool is empty, a new instance is created.
			
			If the pool is at max capacity:
			* "low" priority returns nil.
			* "normal" or higher will wait for an instance.
			
			<code>local part = myPool:Get("normal")
		]]
		function(self: FullPool<T>, priority: PoolPriority?): Instance? end
	),
	Return: typeof(
		--[[
			Returns an instance to the pool, making it available for reuse.
			
			<code>myPool:Return(part)
		]]
		function(self: FullPool<T>, instance: Instance): () end
	),
	GetWithLease: typeof(
		--[[
			Retrieves an instance with an automated lease.
			Returns nil if priority is "low" and pool is full.
			
			<code>local part = myPool:GetWithLease(30, "normal")
		]]
		function(self: FullPool<T>, ttl: number, priority: PoolPriority?): Instance? end
	),
	TryGet: typeof(
		--[[
			Retrieves an instance only if one is currently idle in the pool.
			This function will never create a new instance and never wait.
			
			<code>local part = myPool:TryGet()
		]]
		function(self: FullPool<T>): Instance? end
	),
	Prefetch: typeof(
		--[[
			Asynchronously creates new instances to populate the pool up to the desired count.
			Ideal for loading screens or before anticipated high-demand events.
			
			<code>myPool:Prefetch(20, function()
				print("20 instances have been prefetched!")
			end)
		]]
		function(self: FullPool<T>, count: number, onComplete: (() -> ())?): () end
	),

	-- Bulk Operations
	BulkGet: typeof(
		--[[
			Retrieves multiple instances from the pool in a single, synchronous call.
			
			<code>local fiveParts = myPool:BulkGet(5)
		]]
		function(self: FullPool<T>, count: number, priority: PoolPriority?): {Instance} end
	),
	BulkReturn: typeof(
		--[[
			Returns multiple instances to the pool in a single call.
			
			<code>myPool:BulkReturn(fiveParts)
		]]
		function(self: FullPool<T>, instances: {Instance}): () end
	),

	-- Dynamic Configuration & Control
	Resize: typeof(
		--[[
			Adjusts the maximum number of instances the pool can hold.
			If the new size is smaller, idle instances will be evicted and destroyed.
			
			<code>myPool:Resize(200)
		]]
		function(self: FullPool<T>, newMaxSize: number): () end
	),
	ReadOnly: typeof(
		--[[
			Enables or disables read-only mode. In read-only mode, new instances cannot be retrieved
            or created, but they can still be returned.
			
			<code>myPool:ReadOnly(true)
		]]
		function(self: FullPool<T>, state: boolean): () end
	),
	Pause: typeof(
		--[[
			Pauses the pool's background services, such as lease management.
			
			<code>myPool:Pause()
		]]
		function(self: FullPool<T>): () end
	),
	Resume: typeof(
		--[[
			Resumes the pool's background services.
			
			<code>myPool:Resume()
		]]
		function(self: FullPool<T>): () end
	),

	-- Instance Lifetime Management (Leasing)
	Touch: typeof(
		--[[
			Extends the lease of a leased instance, resetting its TTL to its
			original duration, plus an optional time boost.
			
			<code>local success = myPool:Touch(leasedPart, 60) -- Add 60 seconds
		]]
		function(self: FullPool<T>, instance: Instance, timeBoost: number?): boolean end
	),
	LeaseRemaining: typeof(
		--[[
			Gets the remaining time in seconds on an instance's lease.
			<code>local remaining = myPool:LeaseRemaining(leasedPart)
		]]
		function(self: FullPool<T>, instance: Instance): number? end
	),
	Pin: typeof(
		--[[
			Marks an active instance as non-evictable and exempt from lease expiration.
			A pinned instance must be manually returned to the pool.
			
			<code>myPool:Pin(importantPart)
		]]
		function(self: FullPool<T>, instance: Instance): boolean end
	),
	Unpin: typeof(
		--[[
			Unpins an instance, making it eligible for lease expiration and eviction again.
			
			<code>myPool:Unpin(importantPart)
		]]
		function(self: FullPool<T>, instance: Instance): boolean end
	),
	-- Advanced Introspection & Cleanup
	GetStats: typeof(
		--[[
			Returns a comprehensive snapshot of the pool's current statistics.
			
			<code>local stats = myPool:GetStats()
			print("Hit Rate:", stats.hitRate)
		]]
		function(self: FullPool<T>): PoolStats end
	),
	PeekAllActive: typeof(
		--[[
			Returns a shallow copy of all currently active (in-use) instances
			without affecting any policies or metadata.
			
			<code>local activeInstances = myPool:PeekAllActive()
		]]
		function(self: FullPool<T>): {Instance} end
	),
	PeekAllPooled: typeof(
		--[[
			Returns a shallow copy of all currently idle (pooled) instances.
			
			<code>local pooledInstances = myPool:PeekAllPooled()
		]]
		function(self: FullPool<T>): {Instance} end
	),
	Shrink: typeof(
		--[[
			Forces the pool of idle instances to shrink to a specified size
			by evicting the most recently returned instances.
			
			<code>myPool:Shrink(10) -- Shrink idle pool to 10 instances
		]]
		function(self: FullPool<T>, targetSize: number?): () end
	),
	ManualSweep: typeof(
		--[[
			Manually triggers the pool's cleanup mechanisms on demand.
            
			No options: Performs a full sweep, clearing expired leases AND 
			enforcing memory/size limits on the idle pool.
			
			{expireLeasesOnly = true}: Only reclaims instances whose leases have expired.
			
			<code>
			-- Force a full cleanup
			myPool:ManualSweep()

			-- Only check for expired leases
			myPool:ManualSweep({expireLeasesOnly = true})
			</code>
		]]
		function(self: FullPool<T>, options: {expireLeasesOnly: boolean?}) end
	),
	ReturnBy: typeof(
		--[[
			Returns all active instances that satisfy the condition specified by the predicate function.
			The predicate function receives an instance and should return true if it should be returned.
			
			<code>
			-- Return all active instances named "Temp_FX"
			local count = fxPool:ReturnBy(function(instance)
				return instance.Name == "Temp_FX"
			end)
			print("Returned " .. count .. " instances.")
			</code>
		]]
		function(self: FullPool<T>, predicate: (instance: Instance) -> boolean): number end
	),
	Destroy: typeof(
		--[[
			Destroys all instances and cleans up the pool entirely.
			The pool cannot be used after this is called.
			
			<code>myPool:Destroy()
		]]
		function(self: FullPool<T>): () end
	),
	-- Persistence (Configuration Only)
	Snapshot: typeof(
		--[[
			Generates a JSON string representing the pool's configuration and,
			optionally, the serialized state of its idle instances including descendants.

			If 'includeDescendants' is true, it attempts to serialize all idle
			instances and their children. This can produce large strings and may
			fail if instances contain properties that cannot be serialized (e.g.,
			references to instances outside the hierarchy being serialized).

			If 'includeDescendants' is false or omitted, only the pool's configuration
			and template (if any) are saved.

			<code>-- Snapshot only the configuration
			local configJson = myPool:Snapshot()

			-- Snapshot configuration AND all idle instances + descendants
			local fullStateJson = myPool:Snapshot(true)
			</code>
		]]
		function(self: FullPool<T>, includeDescendants: boolean?): string? end
	),
}
export type Static = {
	Create: typeof(
		--[[
			Creates a new named pool or retrieves an existing one.

			If a pool with the specified "poolName" already exists, this function
			returns the existing pool and dynamically applies any new configurations
			provided. If the pool does not exist, it creates a new one based on
			the provided configuration. The 'instanceType' is required in the
			config for new pools.

			<code>
			-- Create a new pool for basepart instances
			local partPool = FullPool.Create("PartPool", {
				instanceType = "Part",
				maxSize = 150,
				initialSize = 20
			})

			-- Retrieve the same pool later and resize it
			local samePool = FullPool.Create("PartPool", {
				maxSize = 200
			})
			</code>
		]]
		function <T>(poolName: string, config: PoolConfig?):FullPool<T> end
	),
	FromSnapshot: typeof(
		--[[
			Creates a new pool instance by deserializing its configuration and,
			optionally, its idle instances from a JSON string previously
			generated by the Snapshot() method.

			This function attempts to recreate the pool's state. If the snapshot
			included serialized instances ('isFullState' was true), it will try
			to deserialize and add them to the new pool's idle list, up to the
			pool's maxSize.

			Returns the newly created FullPool instance, or nil if deserialization
			or pool creation fails.

			<code>local restoredPool = FullPool.FromSnapshot(snapshotJsonString)
			if restoredPool then
				local instance = restoredPool:Get()
				-- ... use the restored pool
			end
			</code>
		]]
		function(snapshotString: string): FullPool<any>? end
	),
	GetPoolsByPattern: typeof(
		--[[
			Retrieves all pool instances whose names match a glob pattern.
			Uses a high-speed Trie search.
			
			<code>-- Get all visual effect pools
			local vfxPools = FullPool.GetPoolsByPattern("VFX:*")
			for _, pool in ipairs(vfxPools) do
				print(pool.Name)
			end
			</code>
		]]
		function(pattern: string): {FullPool<any>} end
	),
	DestroyByPattern: typeof(
		--[[
			Finds and destroys all pool instances matching a glob pattern.
			Returns the number of pools that were destroyed.
			
			<code>-- Clean up all temporary pools
			local destroyedCount = FullPool.DestroyByPattern("Temp:*")
			print("Cleaned up " .. destroyedCount .. " temporary pools.")
			</code>
		]]
		function(pattern: string): number end
	),
	PrefetchByPattern: typeof(
		--[[
			Triggers Prefetch() for all pools matching a glob pattern.
			Returns the number of pools affected.
			
			<code>-- Pre-warm all enemy pools before a boss fight
			FullPool.PrefetchByPattern("Enemies:*", 10) -- Prefetch 10 each
			</code>
		]]
		function(pattern: string, countPerPool: number): number end
	),
	ShrinkByPattern: typeof(
		--[[
			Triggers Shrink() for all pools matching a glob pattern.
			Returns the number of pools affected.
			
			<code>-- Reclaim memory from VFX pools during low-action
			FullPool.ShrinkByPattern("VFX:*", 5) -- Shrink to 5 idle each
			</code>
		]]
		function(pattern: string, targetSize: number?): number end
	)
}
------------------------------------------------------------------------------------------------------------
export type Master = {
	PoolConfig: PoolConfig,
	PoolPriority: PoolPriority,
	PoolStats: PoolStats,
	FullPool: FullPool,
	Static: Static,
}
local TypeDef = {}
return TypeDef :: Master
