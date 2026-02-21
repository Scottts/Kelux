-- Annotations ---------------------------------------------------------------------------------------------
export type FIFOState = {queue: {string}}
export type LRUState = {head: string?, tail: string?, nodes: {[string]: any}}
export type LFUState = {minFreq: number, freqMap: {[number]: {string}}}
export type RRState = {queue: {string}}
export type PolicyState = FIFOState | LRUState | LFUState | RRState
export type CacheEntry<T> = {
	value: T,
	expires: number?,
	pinned: boolean?,
}
export type EvictionInfo<T> = {
	kind: "array" | "dict",
	key: string?,
	value: T,
	expired: boolean,
}
export type MemoryChangeInfo = {
	used: number,
	budget: number,
	percentUsed: number,
}
export type WatchEvent<T> = {
	event: "SET" | "REMOVE" | "EVICT" | "EXPIRE",
	key: string | {any},
	value: T?,
	timestamp: number,
}
export type SnapshotData<T> = {
	array: {T},
	dict: {[string]: CacheEntry<T>},
	maxobj: number,
	policyName: string,
	policyState: PolicyState,
	memoryBudget: number,
	memoryUsage: number,
	arrayMemoryUsage: number,
	dictMemoryUsage: number,
	maxEntrySizeBytes: number?,
	formatType: string?,
	timestamp: number,
}
export type CreateOpts = {
	Mode: string,
	Policy: string, 
	MemoryBudget: number, 
	MaxSerializedSize: number, 
	FormatType: string,
	ReadOnly: boolean?,
	EstimateSizeFunction: ((any) -> number)?, 
	UseCompression:string?,
	TTLCapacity: number,
	TTLFilter: string?,
	TTLMode: string?,
	TTLUseClock: boolean?,
}
export type FullCache<T> = {
	InsertSingle: typeof(
		--[[
			Inserts a single object into the array section of the cache. 
			
			<code>cache:InsertSingle("Pen")
		]]
		function(self: FullCache<T>, item: T): T end
	),
	InsertBatch: typeof(
		--[[
			Inserts multiple values into the array section of the cache. 
			
			<code>cache:InsertBatch({"Pen", "Pineapple", "Apple", "Pen"})
		]]
		function(self: FullCache<T>, items: {T}): {T} end
	),
	Set: typeof(
		--[[
			Set a value under "key", without TTL. 
			Later "Get(key)" will return the raw "value".
			
			<code>cache:Set("key", "value")
		]]
		function(self: FullCache<T>, key: string|{any}, value: T): T end
	),
	SetMetadata: typeof(
		--[[
			Sets or updates a metadata table for an existing key.
			The metadata must be a JSON-serializable table. Its size
			is calculated and added to the cache's memory budget.
			Returns true if the metadata was successfully set.

			<code>local success = cache:SetMetadata("key1", {contentType = "image/png", version = "v2"}) 
		]]
		function(self: FullCache<T>, key: string|{any}, data: any): boolean end
	),
	Get: typeof(
		--[[
			Returns the value for a key, if it exists and hasn’t expired. 
			Automatically removes expired TTL entries. 
			
			<code>local username = cache:Get("username_123")
		]]
		function(self: FullCache<T>, key: string|{any}): T? end
	),
	GetMetadata: typeof(
		--[[
			Retrieves a deep copy of the metadata for a given key.
			Returns nil if the key does not exist or has no metadata. 

			<code>local meta = cache:GetMetadata("key1")
			if meta then
				print("Version:", meta.version)
			end
		]]
		function(self: FullCache<T>, key: string|{any}): any? end
	),
	Update: typeof(
		--[[
			Atomically updates a value for a key by applying a function.
			The entire operation (get, modify, set) is performed within a single lock.
			The function receives the current value and should return the new value.
			If the function returns nil, the key is removed.

			<code>-- Atomically increment a counter without race conditions
			cache:Update("player_score", function(currentScore)
				return (currentScore or 0) + 1
			end)
		]]
		function(self: FullCache<T>, key: string|{any}, updaterFn: (currentValue: T) -> T): T? end
	),
	Pin: typeof(
		--[[
			Marks a key as non-evictable.  Pinned items are ignored by
			all eviction policies and will not be removed due to memory
			pressure or size limits.  Returns true if the key exists and was pinned.

			<code>cache:Pin("important_config")
		]]
		function(self: FullCache<T>, key: string|{any}): boolean end
	),
	Unpin: typeof(
		--[[
			Unmarks a key as non-evictable, making it eligible for
			eviction again according to the cache's policy.  Returns
			true if the key exists and was unpinned. 

			<code>cache:Unpin("important_config")
		]]
		function(self: FullCache<T>, key: string|{any}): boolean end
	),
	GetOrLoad: typeof(
		--[[ 
			Gets a value if present;  otherwise calls loader(), caches the result, and returns it.
			Optionally accepts ttl in seconds. 
			
			<code>local val = cache:GetOrLoad("user_42", function()
				return LoadUserFromDatabase(42)
			end, 30)  -- cached for 30s
		]]
		function(self: FullCache<T>, key: string|{any}, loader: () -> T, ttl: number?): T end
	),
	Has: typeof(
		--[[
			Checks whether a key exists and hasn’t expired.
			Cleans up expired TTL values in the process. 
			
			<code>if cache:Has("username_123") then
				print("Key is still valid!")
			end
		]]
		function(self: FullCache<T>, key: string|{any}): boolean end
	),
	Remove: typeof(
		--[[
			Deletes a key-value pair from the dictionary section, <em>regardless of its state.</em> 
			
			<code>cache:Remove("username_123")
		]]
		function(self: FullCache<T>, key: string|{any}) end
	),
	Size: typeof(
		--[[
			Returns the combined count of array and dictionary entries.
			TTL-expired entries are cleared before counting. 

			<code>print("Total cache size:", cache:Size())
		]]
		function(self: FullCache<T>): number end
	),
	Clear: typeof(
		--[[
			Completely resets the cache’s internal storage.
			Also resets the eviction policy to default state. 
			
			<code>cache:Clear()
		]]
		function(self: FullCache<T>) end
	),
	Cleanup: typeof(
		--[[
			Removes all nil entries in the array section.
			This is a maintenance function mostly for the FIFO array.
			
			<code>cache:Cleanup()
		]]
		function(self: FullCache<T>) end
	),
	GetAll: typeof(
		--[[
			Returns a shallow copy of all items  stored in both array and dictionary sections.
			TTL-expired items are removed first. 
			
			<code>for _, item in ipairs(cache:GetAll()) do
				print(item)
			end
		]]
		function(self: FullCache<T>): {T} end
	),
	ReadOnly: typeof(
		--[[
			Enables or disables read-only mode, freezing and restoring the cache.  All mutator methods
			<strong>(e.g. "Set", 'Remove', "Clear")</strong> will be disabled, and the TTL service
			will be paused or continued to prevent automatic expirations, and the TTL service is resumed. 

			<code>cache:ReadOnly(true) -- This will enable read-only mode
			task.wait(5)
			cache:ReadOnly(false) -- This will disable read-only mode
		]]
		function(self: FullCache<T>, state:boolean) end
	),
	Prefetch: typeof(
		--[[
			Asynchronously gets a value if present; otherwise calls loader()
			in the background, caches the result, and returns immediately.
			This is a non-blocking method for pre-warming the cache. 

			<code>cache:Prefetch("user_42", function()
				return LoadUserFromDatabase(42)
			end, 30)  -- fetched in background and cached for 30s
		]]
		function(self: FullCache<T>, key: string|{any}, loader: ()->T, ttl: number?) end
	),
	RemoveByPattern: typeof(
		--[[
			Removes all dictionary entries whose keys match a given pattern or satisfy a predicate function.
			This method supports several matching strategies with different performance characteristics. 

			<strong>By Glob Pattern (High-Performance)...</strong>
			Removes keys using a fast, Trie-based search when a string or table of strings with a glob ('*') is provided. 
			This is the recommended method for optimal performance. 
			
			<code>-- Remove all keys within the 'users:session' namespace
			cache:RemoveByPattern("users:session:*")
			-- Remove multiple glob patterns at once
			cache:RemoveByPattern({"users:*:tmp", "sessions:old:*"})
			</code>

			<strong>By Predicate Function...</strong>
			Removes keys for which the given function returns true.
			Supports both string and table keys. 
			
			<code>cache:RemoveByPattern(function(key)
				return type(key) == "table" and key.type == "A"
			end)
			</code>

			<strong>By Multiple Exact Strings (Aho-Corasick)...</strong>
			Uses the high-performance Aho-Corasick algorithm when a table of exact, non-glob strings is provided. 
			
			<code>cache:RemoveByPattern({"user_to_delete_1", "guest_session_abc"})
			</code>

			<strong>By Lua Pattern (Fallback)...</strong>
			When a single string *without* a glob ('*') is provided, the function falls 
			back to a slower iteration method using standard Lua pattern matching. 
			
			<code>-- Removes keys like "log_1", "log_2", etc. using Lua's pattern matching
			cache:RemoveByPattern("log_%d+")
			</code>
		]]
		function(self: FullCache<T>, patOrFn: string | {string} | ((key: string|{any}) -> boolean)) end
	),
	RemoveNamespace: typeof(
		--[[
			Removes all entries within a given namespace using a fast, trie-based prefix search. 
			A namespace is simply a key prefix. For example, calling this with "users:"
			will remove "users:1", "users:2", "users:config:a", etc.
			
			<code>local node = cache:RemoveNamespace("users:")
		]]
		function(self: FullCache<T>, prefix:string):number end
	),
	DefineVirtual: typeof(
		--[[
			Defines a "virtual" entry.  The value is not computed or stored
			until the first time it is accessed with Get().  On first access,
			the computeFn is executed, the result is cached, and the entry
			is "promoted" to a regular cache item. 

			<code>cache:DefineVirtual("complex_report", function()
				return GenerateComplexReport() -- This function only runs when needed
			end)
		]]
		function(self: FullCache<T>, key: string|{any}, computeFn: ()->T) end
	),
	ManualSweep: typeof(
		--[[
			Manually triggers the cache's cleanup mechanisms on demand,
			bypassing  the normal automated triggers. This is useful for
			deterministic testing or simulations. 

			No arguments: Performs a full sweep, clearing expired items AND enforcing memory/size limits. 
			{expireOnly = true}: Only removes items that have passed their TTL. 
			{enforceMemory = true}: Only evicts items to conform to memory budget and max object limits. 
			
			<code>-- Force a full cleanup
			cache:ManualSweep()
			-- Only run the TTL expiration check
			cache:ManualSweep({ expireOnly = true })
			</code>
		]]
		function(self: FullCache<T>, options: {expireOnly: boolean?, enforceMemory: boolean?}) end
	),
	Pause: typeof(
		--[[
			Pauses the TTL cleanup service, halting expiration checks.
			Useful if you want to batch operations without interference. 
			
			<code>cache:Pause()
		]]
		function(self: FullCache<T>) end
	),
	Resume: typeof(
		--[[
			Resumes the TTL cleanup service.
			Restarts expiration checks where they left off. 
			
			<code>cache:Resume()
		]]
		function(self: FullCache<T>) end
	),
	Destroy: typeof(
		--[[
			Completely removes and cleans up the cache instance.
			Stops all background processes and releases memory. 
			The cache cannot be used after being destroyed. 
		]]
		function(self: FullCache<T>) end
	),
	-- Introspection and Iteration
	Peek: typeof(
		--[[
			Return a dict-entry value without bumping 
			its LRU/LFU state or affecting TTL. 
			
			<code>local value = cache:Peek("key")
			if value then
				print(value)
			end
		]]
		function(self: FullCache<T>, key: string|{any}): T? end
	),
	Keys: typeof(
		--[[
			Return a list of all keys currently in the dict.
			<strong>(Excludes expired)</strong> 
			
			<code>local keys = cache:Keys()
			for _, key in ipairs(keys) do
				print(key)
			end
		]]
		function(self: FullCache<T>): {string|{any}} end
	),
	Values: typeof(
		--[[
			Return a list of all values in array + dict
			<strong>(Excludes expired)</strong>
			
			<code>local values = cache:Values()
		]]
		function(self: FullCache<T>): {T} end
	),
	ForEach: typeof(
		--[[
			Invoke fn(key, value) on every (key,value)
			pair without affecting eviction/TTL. 
			
			<code>cache:ForEach(function(key,value)
				print(key, value)
			end)
		]]
		function(self: FullCache<T>, fn: (key: string|{any}, value: T)->()) end
	),
	-- Bulk operations
	BulkSet: typeof(
		--[[
			Sets multiple key/value pairs in one shot.
			Supports parallel encoding on clients for improved performance. 
			
			entries: table where keys are string|table and values are T
			options?: {parallel:boolean}
			
			<code>cache:BulkSet({user1 = data1, user2 = data2, [complexKey] = data3})
		]]
		function(self: FullCache<T>, entries: {[string|{any}]: T}, options:{parallel:boolean?}) end
	),
	BulkGet: typeof(
		--[[
			Retrieves multiple values, returning nil for misses.
			Supports parallel execution on clients. 
			
			keys: array of string|table
			options?: {parallel:boolean}
			Returns an array of values in the same order. 
			
			<code>local results = cache:BulkGet({"a", "b", complexKey})
		]]
		function(self: FullCache<T>, keys: {string|{any}}, options:{parallel:boolean?}): {T?} end
	),
	BulkRemove: typeof(
		--[[
			Removes multiple keys at once.
			keys: array of string|table 
			
			<code>cache:BulkRemove({"user1", complexKey})
		]]
		function(self: FullCache<T>, keys: {string|{any}}) end
	),
	-- TTL
	SetWithTTL: typeof(
		--[[
			Stores a key-value pair that expires in "ttl" seconds.
			Useful for temporary data like sessions or cooldowns. 
			
			<code>cache:SetWithTTL("session_abc", "SessionData", 30)
		]]
		function(self: FullCache<T>, key: string|{any}, value: T, ttl: number): T end
	),
	Touch: typeof(
		--[[
			Resets a key's TTL to its original duration, as if it were just added.
			This is useful for keep-alive mechanisms.  An optional <strong>timeBoost</strong> in
			seconds can be added to the newly reset TTL.  Returns true if successful.

			<code>local updated = cache:Touch("session_key")
			if updated then
				print("Session extended!")
			end

			-- Extend session and add 5 extra minutes
			cache:Touch("session_key", 300)
		]]
		function(self: FullCache<T>, key: string|{any}, timeBoost: number?): boolean end
	),
	TTLRemaining: typeof(
		--[[
			Return seconds until expiration, or nil if none.
			
			<code>local remaining = cache:TTLRemaining("key")
		]]
		function(self: FullCache<T>, key: string|{any}): number? end
	),
	RefreshTTL: typeof(
		--[[
			Extends an existing key’s TTL by extra seconds.
			If the key doesn’t exist or has no TTL,
			does nothing (returns false). 
			
			<code>local success = cache:RefreshTTL("key", 300)
			if success then
				print("Refreshed TTL!")
			end
		]]
		function(self: FullCache<T>, key: string|{any}, extraSeconds: number): boolean end
	),
	ClearExpired: typeof(
		--[[
			Manually purge all expired entries; returns count removed. 
			
			<code>local count = cache:ClearExpired()
			print("Removed",count,"entries.")
		]]
		function(self: FullCache<T>): number end
	),
	-- Static Methods
	Create: typeof(
		--[[
			Creates a new named cache or returns an existing one if already created. 
			Supports optional max
			object count, TTL interval in seconds, and cache options (weak/strong mode and eviction policy). 
			
			<code>local cache = FullCache.Create("MyCache", 100, 5, {Mode = "strong", Policy = "LRU"})
		]]
		function(CacheName:string, MaxObjects:number?, Opts:CreateOpts?):FullCache<T> end
	),
	-- Memory introspection
	GetMemoryUsage: typeof(
		--[[
			Returns the memory used by both arrays and dictionaries. 
			
			<code>local usage = cache:GetMemoryUsage()
		]]
		function(self: FullCache<T>): number end
	),
	GetMemoryUsageByType: typeof(
		--[[
			Breaks down memory usage by array, dict, or both. 
			
			<code>local usage = cache:GetMemoryUsageByType()
		]]
		function(self: FullCache<T>): {array: number, dict: number} end
	),
	GetRemainingMemory: typeof(
		--[[
			Helps check how close you are to the limit. 
			
			<code>local MemoryRemaining = cache:GetRemainingMemory()
		]]
		function(self: FullCache<T>): number end
	),
	GetMemoryInfo: typeof(
		--[[
			Returns current usage, budget, and percent used. 
			
			<code>local MemoryInfo = cache:GetMemoryInfo()
		]]
		function(self: FullCache<T>): {used: number, budget: number, percentUsed: number} end
	),
	IsNearMemoryBudget: typeof(
		--[[
			Returns true if memory is near a threshold (default 90%). 
			
			<code>local IsNear = cache:IsNearMemoryBudget(0.8)
			if IsNear then
				print("Warning: memory usage exceeds 80%!")
			end
		]]
		function(self: FullCache<T>, threshold: number?): boolean end
	),
	-- Dynamic configuration
	Resize: typeof(
		--[[
			Adjusts the maximum number of entries the cache can hold. 
			If the current number of items exceeds newMax, evicts entries
			according to the active policy until the size constraint is satisfied. 
			
			<code>cache:Resize(newMax)
		]]
		function(self: FullCache<T>, newMax: number) end
	),
	SetPolicy: typeof(
		--[[  
			Switches the cache’s eviction policy to the given
			policyName <strong>(e.g. "LRU", "LFU", "FIFO", "RR")</strong>. 
			Attempts to preserve the existing policy state
			when switching to the same policy; otherwise,
			initializes the new policy fresh. 
			
			<code>cache:SetPolicy(policyName)
		]]
		function(self: FullCache<T>, policyName: string) end
	),
	SetMemoryBudget: typeof(
		--[[  
			Sets a new memory‐usage ceiling (in bytes) for this cache instance. 
			Immediately prunes entries until the total serialized size of stored
			items falls at or below the specified budget. 
			
			<code>cache:SetMemoryBudget(budget)
		]]
		function(self: FullCache<T>, budget: number) end
	),
	-- Events / signals
	Watch: typeof(
		--[[
			Returns a generator that yields a log of cache events (Set, Evict, Expire, Remove) 
			as they occur.  This provides a polling-based way to monitor all cache activity. 

			<code>
			local watchIterator, cleanupWatcher = cache:Watch()
			coroutine.wrap(function()
			-- Loop until the main thread tells us to stop
				while not stopWatching do
					local event = watchIterator() -- Manually get the next event
					if event then
						-- If we got an event, process it
						table.insert(watchEvents, event)
					else
						-- If there was no event, wait briefly before checking again.
						-- This prevents a busy-loop and resolves the race condition.
						task.wait()
					end
				end
			end)()
		]]
		function(self: FullCache<T>): (() -> WatchEvent<T>?, () -> ()) end
	),
	OnEvict: typeof(
		--[[
			Connects a callback that runs whenever an 
			object is evicted (from dictionary or array).
			Useful for cleanup or metrics. 
			
			<code>cache:OnEvict(function(info)
				print("Evicted:", info.kind, info.key or "", info.value)
			end)
		]]
		function(self: FullCache<T>, fn: (info: EvictionInfo<T>)->()): number end
	),
	OnMemoryChanged: typeof(
		--[[
			Connects a callback that runs whenever the cache's memory usage changes.
			The callback receives an info table with the current usage, budget, and percentage used. 
			
			<code>local conn = cache:OnMemoryChanged(function(info)
			print(string.format("Memory Usage: %.2f%% (%d / %d bytes)",
				info.percentUsed, info.used, info.budget))
		end)
		]]
		function(self: FullCache<T>, fn: (info: MemoryChangeInfo)->()): number end
	),
	OnHit: typeof(
		--[[ 
			Connect a callback that runs whenever a cache hit occurs. 
			
			<code>cache:OnHit(function(key, value)
				print("Hit:", key, value)
			end)
		]]
		function(self: FullCache<T>, fn: (key: string|{any}, value: T)->()): number end
	),
	OnMiss: typeof(
		--[[ 
			Connect a callback that runs whenever a cache miss occurs. 
			
			<code>cache:OnMiss(function(key)
				print("Miss:", key)
			end)
		]]
		function(self: FullCache<T>, fn: (key: string|{any})->()): number end
	),
	OnExpire: typeof(
		--[[
			Connect a callback that runs whenever a cache expiration occurs. 
			
			<code>cache:OnExpire(function(key, value)
				print("Expired:", key, value)
			end)
		]]
		function(self: FullCache<T>, fn: (key: string|{any}, value: T)->()): number end
	),
	-- Metrics
	ResetMetrics: typeof(
		--[[ 
			Zero out hit/miss/eviction counters. 
			
			<code>cache:ResetMetrics()
		]]
		function(self: FullCache<T>) end
	),
	GetStats: typeof(
		--[[ 
			Snapshot of current metrics. 
			
			<code>local Stats = cache:GetStats()
		]]
		function(self: FullCache<T>): {hits: number, misses: number, evictions: number, uptime: number, hitRate: number} end
	),
	GetMetrics: typeof(
		--[[
			Returns a table of performance metrics, including hits, misses, evictions,
			uptime, and the calculated hit-to-miss ratio. 
			
			<code>local metrics = cache:GetMetrics()
			print(string.format("Uptime: %.2fs, Hit/Miss Ratio: %.2f",
			metrics.uptime, metrics.hitMissRatio))
		]]
		function(self: FullCache<T>): {hits: number, misses: number, evictions: number, uptime: number, hitMissRatio: number} end
	),
	-- Snapshot / Persistence
	Snapshot: typeof(
		--[[
			Returns a serializable table representing the cache’s
			internal state (array, dict, TTL, policy, etc). 
			
			On the array/dict state, you can select the following
			options: <strong>"Auto", "Shallow", "Deep".</strong>
			<code>local snapshot = cache:Snapshot("Auto")</code>
			
			To snapshot a single key:
			<code>local partial_snapshot = cache:Snapshot("my_key")</code>
		]]
		function(self: FullCache<T>, Option: string?): SnapshotData<T> end
	),
	Restore: typeof(
		--[[
			Restores cache contents from a snapshot. 
			
			<code>cache:Restore(snapshot)
		]]
		function(self: FullCache<T>, snapshot: SnapshotData<T>) end
	),
	ToJSON: typeof(
		--[[
			Encodes a snapshot of the cache state into a JSON string.
			Can be used for persistence or debugging. 

			<code>local FormattedData = cache:ToJSON(format)
		]]
		function(self: FullCache<T>): string end
	),
	FromJSON: typeof(
		--[[
			Restores cache data from a previously serialized JSON snapshot string. 
			
			<code>cache:FromJSON(FormattedData)
		]]
		function(self: FullCache<T>, jsonString: string) end
	),
	-- Atomic Operations
	Transaction: typeof(
		--[[
			Executes a block of code within a single, atomic transaction.
			The cache is locked before the function begins and unlocked after it completes.
			This ensures that a sequence of operations is performed without interruption
			from other threads, preventing complex race conditions.

			<code>-- Atomically transfer a value from one account to another
			cache:Transaction(function(txCache)
				local valA = txCache:Get("accountA")
				local valB = txCache:Get("accountB")
				txCache:Set("accountA", valA - 100)
				txCache:Set("accountB", valB + 100)
			end)
		]]
		function(self: FullCache<T>, transactionFn: (cache: FullCache<T>) -> any): any? end
	),
}
export type Static = {
	Create: typeof(
		--[[
			Creates a new named cache or returns an existing one if already created. Supports optional max
			object count, TTL interval in seconds, and cache options (weak/strong mode and eviction policy).
			
			<code>local cache = FullCache.Create("MyCache", 100, 5, {Mode = "strong", Policy = "LRU"})
		]]
		function <T>(CacheName:string, MaxObjects:number?, Opts:CreateOpts?):FullCache<T> end
	)
}
------------------------------------------------------------------------------------------------------------
export type Master = {
	FIFOState: FIFOState,
	LRUState: LRUState,
	LFUState: LFUState,
	RRState: RRState,
	PolicyState: PolicyState,
	CacheEntry: CacheEntry,
	EvictionInfo: EvictionInfo,
	MemoryChangeInfo: MemoryChangeInfo,
	WatchEvent: WatchEvent,
	SnapshotData: SnapshotData,
	CreateOpts: CreateOpts,
	FullCache: FullCache,
	Static: Static,
}
local TypeDef = {}
return TypeDef :: Master