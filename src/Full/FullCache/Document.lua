--[[
	[ FULLCACHE DOCUMENTATION ]
	Version: 0.3.56 (STABLE)

	Author: Kel (@GudEveningBois)

	1. Introduction
		FullCache is a simple cache module for Roblox developers. 
		It provides a robust, in-memory storage solution designed to manage temporary 
		data efficiently, helping to reduce latency and decrease the load on 
		persistent data stores.

		It features a unique dual-structure design, with both an array-based and a 
		dictionary-based cache, catering to a wide variety of use cases. FullCache 
		is highly configurable, offering multiple eviction policies, precise memory 
		management, event-driven signals, data persistence, and detailed performance
		metrics.

		Key Features:
		
			Dual Cache Structure: 
				Manages both ordered (array) and keyed (dictionary) data.

			Flexible Eviction Policies: 
				Includes FIFO, LRU, LFU, and Random Replacement (RR) policies.

			Comprehensive Memory Management: 
				Set memory budgets and monitor usage in bytes.

			Time-To-Live (TTL)
				Automatically expire data after a set duration.

			Lazy Loading: 
				Load data on-demand with GetOrLoad.

			Event-Driven Signals: 
				Subscribe to cache events like hits, misses, and evictions.

			Data Persistence: 
				Snapshot and restore the cache's state using JSON or the experimental KELP format.

			Bulk Operations: 
				Perform batch operations for improved performance.

			Advanced Metrics: 
				Track cache performance with detailed stats.
				
			Concurrency & Thread-Safety:
				All cache operations are thread-safe by default, protected by an internal 
				re-entrant mutex to prevent data corruption and race conditions. Includes atomic 
				operations like Update and Transaction for complex, multi-step modifications.

	2. Getting Started
		To begin using FullCache, you first need to create a cache instance.

		FullCache.Create(CacheName, MaxObjects, Opts)
		This function creates a new cache instance or 
		reconfigures an existing one with the same name.

		Parameters:
			CacheName (string) [Required]
			A unique name for your cache.

			MaxObjects (number?) [Optional]
			The maximum number of items the cache can hold. Defaults to 1000.

			Opts (table?) [Optional]
			A table of advanced options to configure the cache's behavior.

			Options Table (Opts)
				Policy (string)
				The eviction policy to use. Options: "FIFO", "LRU", "LFU", "RR", "ARC". Defaults to "FIFO".
				If you want to create your own cache replacement policy, please head to the Policies folder and read "Guide".

				MemoryBudget (number)
				The maximum memory the cache can use, in bytes. 
				Defaults to math.huge.

				Mode (string)
				Sets the 
				"weakness" of the internal tables. 
				Options: "strong", "weak", "k", "v", "kv". Defaults to "strong".

				MaxSerializedSize (number)
				The maximum size in bytes for a single serialized entry. 
				Defaults to math.huge.

				FormatType (string)
				The default serialization format. Options: "JSON", "KELP". Defaults to "JSON".

				EstimateSizeFunction (function)
				A custom function (value) -> number to estimate the memory size of a value. 
				Overrides default JSON/KELP sizing.
				
				UseCompression (string) [Optional]
				Enables automatic data compression on stored values to reduce their memory footprint.
				This creates a trade-off, saving significant memory at the cost of slightly higher CPU
				usage for Set (compression) and Get (decompression) operations.
				Options: "Zstd" & "LZ4"
				
				TTLCapacity (number) [Optional]
				The maximum number of keys the cache can track for TTL.
				Defaults to 10000.
				
				TTLFilter (string) [Optional]
				Selects the probabilistic data structure used 
				by the TTL service for faster key lookups.
				Options: "Cuckoo" & "Bloom"
				
		Example:
			----------------------------------------------------------------------------
			local FullCache = require(the.path.to.FullCache)
			-- Create a cache for player data with a max of 200 players, using the LRU policy
			local playerDataCache = FullCache.Create("PlayerDataCache", 200, {
				Policy = "LRU",
				MemoryBudget = 10 * 1024 * 1024 -- 10 MB
			})
			----------------------------------------------------------------------------

	3. Core Concepts
	
		Dual Structure: Array and Dictionary
			FullCache manages two separate internal data structures, 
			allowing you to store data in the way that best suits your needs.

		Dictionary (_dict)
			This is a standard key-value store, perfect for data that needs 
			to be accessed quickly by a unique identifier (e.g., a player's UserId). 
			Most features, including TTL and advanced eviction policies, 
			apply primarily to this structure.

		Array (_array)
			This is a list-like structure that stores items in the order they
			are added. It's suitable for collections where order is important
			and individual keys are not needed. It operates on a simple FIFO
			(First-In, First-Out) eviction basis.

		Eviction Policies:
			When a cache reaches its MaxObjects or MemoryBudget limit, it must remove 
			items to make space. An eviction policy determines which items get removed.

			FIFO (First-In, First-Out)
			The oldest items are evicted first. (Default)

			LRU (Least Recently Used)
			Items that haven't been accessed for the longest time are evicted.

			LFU (Least Frequently Used)
			Items that have been accessed the fewest times are evicted.

			RR (Random Replacement)
			A random item is chosen for eviction.
			
			ARC (Adaptive Replacement Cache)  
			Dynamically balances between recency and frequency.  
			It adapts to changing access patterns by combining the strengths of LRU and LFU,  
			without requiring manual tuning. Ideal when access patterns are unknown or inconsistent.
			
			If you want to make your own cache replacement policy,
			please check "Guide" in the Policies folder.

	4. API Reference (References are also seen in FullCache's source code)
	
		Creation:
			FullCache.Create(CacheName, MaxObjects, Opts)
			Creates or reconfigures a cache instance. See Getting Started.

		Array Operations:
			These methods interact with the array-based part of the cache.

				cache:InsertSingle(item)
				Inserts one item into the array.

				cache:InsertBatch(items)
				Inserts a table of items into the array.

				cache:Cleanup()
				Compacts the array by removing nil entries 
				that result from FIFO evictions.

		Dictionary (Key-Value) Operations:
			These methods interact with the dictionary-based part of the cache.

				cache:Set(key, value)
				Stores a value associated with a key.

				cache:Get(key)
				Retrieves a value by its key. Accessing an 
				item marks it as "used" for LRU/LFU policies.

				cache:GetOrLoad(key, loader, ttl?)
				Retrieves a value. If the key doesn't exist, it calls the 
				loader function, caches the result, and returns it. Optionally 
				sets a TTL on the newly loaded item.

				cache:Has(key)
				Returns true if a non-expired key exists.

				cache:Remove(key)
				Deletes a key-value pair.
				
				cache:Destroy()
				Completely removes and cleans up a cache instance, 
				stopping all background processes and releasing its memory.
				
				cache:SetMetadata(key, data)
				Attaches a table of custom, serializable metadata to an existing key-value pair.  
				This metadata's size is factored into the cache's total memory usage.  
				Returns true if the metadata was successfully set.
				
				cache:GetMetadata(key)
				Retrieves a deep copy of the custom metadata associated with a key.
				Returns nil if the key does not exist or has no metadata. 
				
				cache:Pin(key)
				Marks a key-value pair as non-evictable.
				Pinned items are ignored by all eviction policies and will not be
				removed due to memory or size constraints.
				Returns true if the key exists and was successfully pinned. 
				
				cache:Unpin(key)
				Removes the pinned status from a key, making it eligible for eviction again.
				Returns true if the key exists and was unpinned.
				
				cache:Prefetch(key, loader, ttl?)
				Asynchronously loads a value for a key if it's not already in the cache.
				It calls the loader function in a background thread and caches the result, 
				making it ideal for pre-warming the cache without blocking the main thread.
				
				cache:DefineVirtual(key, computeFn)
				Defines a "virtual" entry where the value is not computed or stored until 
				the first time it is accessed with Get().  On first access, the computeFn 
				is executed, its result is cached as a regular item,
				and the virtual entry is removed.

		General Cache Operations:
		
			cache:Size()
			Returns the total number of items in 
			both the array and dictionary.

			cache:Clear()
			Empties the entire cache.

			cache:GetAll()
			Returns a new table containing all values from 
			both the array and dictionary.

			cache:Pause()
			Stops the TTL expiration service.

			cache:Resume()
			Restarts the TTL expiration service.

		Introspection & Iteration:
		
			cache:Peek(key)
			Retrieves a value by key without affecting its status in LRU/LFU policies.

			cache:Keys()
			Returns a list of all keys in the dictionary.

			cache:Values()
			Returns a list of all values from both the array and dictionary.

			cache:ForEach(function(key, value)) 
			Executes a function for each item in the cache.

		Time-To-Live (TTL):
		
			cache:SetWithTTL(key, value, ttl)
			Stores a key-value pair that will automatically expire after ttl seconds.

			cache:TTLRemaining(key)
			Returns the remaining seconds until a key expires, or nil.

			cache:RefreshTTL(key, extraSeconds)
			Extends a key's expiration time.

			cache:ClearExpired()
			Manually purges all expired items and returns the count of items removed.
			
			cache:Touch(key, timeBoost?)
			Resets a key's TTL to its original duration, as if it were just added.
			An optional timeBoost in seconds can be added to the newly reset TTL.
			This is useful for keep-alive mechanisms where activity should extend 
			an item's lifetime.
			
		Bulk Operations:
		
			cache:BulkSet(entries, options?)
			Sets multiple key-value pairs from a dictionary.
			table with a 'parallel' boolean (e.g., {parallel = true}) can be provided 
			to perform encoding across multiple threads. This is only recommended for
			CPU-intensive workloads, such as when 'UseCompression' is enabled, as it
			may be slower than single-threaded execution for simple data.

			cache:BulkGet(keys, options?)
			Retrieves multiple values from a list of keys.
			An optional 'options' table with a 'parallel' boolean can be provided to perform lookups 
			and decompression in parallel. The performance gain is most significant
			when values are compressed or require heavy decoding 
			that can cause timouts in one thread.

			cache:BulkRemove(keys)
			Removes multiple key-value pairs from a list of keys.

		Memory Management:
		
			cache:GetMemoryUsage()
			Returns the total estimated memory usage in bytes.

			cache:GetMemoryUsageByType()
			Returns a table with memory usage for array and dict.

			cache:GetRemainingMemory()
			Returns the available memory in bytes before reaching the budget.


			cache:GetMemoryInfo()
			Returns a table with {used, budget, percentUsed}.

			cache:IsNearMemoryBudget(threshold?)
			Returns true if memory usage is above a certain percentage (default 90%).

		Dynamic Configuration:
		
			cache:Resize(newMax)
			Changes the MaxObjects limit of the cache, evicting items if necessary.

			cache:SetPolicy(policyName)
			Switches the eviction policy on the fly.

			cache:SetMemoryBudget(budget)
			Sets a new memory budget, evicting items if the new budget is exceeded.
			
			cache:ReadOnly(state)
			Enables or disables a read-only mode for the cache.
			When in read-only mode, methods that alter the cache's data 
			(like Set, Remove, and Clear) are disabled, and the TTL service is paused.
			state can be true or false.

		Persistence & Serialization:
		
			cache:Snapshot(mode?)
			Creates a serializable table representing the cache's full state. 
			mode can be "shallow", "deep", or "auto".

			cache:Restore(snapshot)
			Restores the cache's state from a snapshot table.

			cache:ToJSON(format?)
			Returns a JSON (or KELP) string of the cache's snapshot.

			cache:FromJSON(jsonString, format?)
			Restores the cache from a JSON (or KELP) string.

		Events / Signals:
			Connect to these signals to react to cache activity.

			cache:OnEvict(function(info))
			Fires when an item is evicted. 
			info is a table {kind, key, value, expired}.

			cache:OnHit(function(key, value))
			Fires on a successful Get.

			cache:OnMiss(function(key))
			Fires on a failed Get.

			cache:OnExpire(function(key, value))
			Fires when an item is removed specifically due to TTL expiration.

			cache:OnMemoryChanged(function(info))
			Fires when memory usage changes. 
			info is a table {used, budget, percentUsed}.
			
			cache:Watch()
			Returns a generator function that allows you to poll for a log 
			of all cache events (SET, REMOVE, EVICT, EXPIRE) as they occur.

		Metrics:
		
			cache:GetStats()
			Returns a table of performance metrics: 
			{hits, misses, evictions, uptime, hitRate}.
			
			cache:GetMetrics()
			Returns a table of performance metrics, including hits,
			misses, evictions, uptime, and the calculated hitMissRatio.
			
			cache:ResetMetrics()
			Resets all performance counters.

		Advanced Operations:
		
			cache:RemoveByPattern(patternOrPredicate)
			Removes all dictionary entries where the key matches
			a string pattern (e.g. "^user_%d+") or passes a predicate function (key → boolean).
			This uses a fast, prefix-aware trie when the pattern is a simple literal prefix,
			falling back to a full scan only when necessary. Returns the number of entries removed.
			
			cache:RemoveNamespace(prefix)
			Efficiently removes all dictionary entries whose keys start with the given prefix string.
			This method uses a fast, trie-based prefix search for optimal performance.
			
			cache:ManualSweep(options?)
			Manually triggers the cache's cleanup mechanisms on demand, bypassing automated triggers.
			>	No arguments: Performs a full sweep, clearing expired items and enforcing memory/size limits.
			>	{expireOnly = true}: Only removes items that have passed their TTL. 
			>	{enforceMemory = true}: Only evicts items to conform to memory and object limits.
			
		Atomic Operations:
		
			cache:Transaction(transactionFn) 
			Executes a block of code within a single, atomic transaction.
			The cache is locked before the function begins and unlocked after 
			it completes. This ensures that a sequence of operations is performed 
			without interruption from other threads, preventing complex race conditions.

	5. Practical Examples
	
		Example 1: Caching Player Profiles
			----------------------------------------------------------------------------
			local Players = game:GetService("Players")
			local DataStoreService = game:GetService("DataStoreService")
			local profileStore = DataStoreService:GetDataStore("PlayerProfiles")
			local profileCache = FullCache.Create("ProfileCache", 150, {Policy = "LRU"})
			local function getPlayerProfile(player)
			local userId = player.UserId
			-- Use GetOrLoad to fetch from cache or DataStore
			local profile = profileCache:GetOrLoad(userId, function()
				print("Cache miss for "..userId..". Loading from DataStore.")
				local success, data = pcall(function()
					return profileStore:GetAsync(userId)
				end)
				return success and data or {bux = 100, level = 1}
				end, 3600) -- Cache for 1 hour   
				return profile
			end
			Players.PlayerAdded:Connect(getPlayerProfile)
			----------------------------------------------------------------------------

		Example 2: Logging Evictions
			----------------------------------------------------------------------------
			local logCache = FullCache.Create("LogCache", 500)
			logCache:OnEvict(function(info)
				if info.expired then
					print(string.format("Item expired! Key: %s, Value: %s", tostring(info.key), 
					tostring(info.value)))
				else
					print(string.format("Item evicted to make space! Kind: %s", info.kind))
				end
			end)
			----------------------------------------------------------------------------
		Example 3: Temporary Cooldowns
			----------------------------------------------------------------------------
			local abilityCooldowns = FullCache.Create("Cooldowns")
			function useAbility(player)
				local userId = player.UserId
				if abilityCooldowns:Has(userId) then
					local remaining = abilityCooldowns:TTLRemaining(userId)
					player:Chat(string.format("Ability on cooldown for %.1f more seconds!", remaining))
					return
				end
				-- Use ability...
				print(player.Name .. " used their ability!")
				-- Set a 10-second cooldown
				abilityCooldowns:SetWithTTL(userId, true, 10)
			end
			----------------------------------------------------------------------------
]]

--[[
	[ BENCHMARK ]
		Benchmarks were conducted in Roblox's server 
		environment with an estimated 4 CPU cores.
		Multithreading is enabled where supported. 
		JSON is used as the default serialization 
		format unless otherwise specified.
		
		FullCache version: v0.3.42
		Mode: Server
		Estimated cores: 4
		Multithreading: Enabled where supported
		Compression codec: Zstd
		Serialization: JSON (default)
		
	[ Core Dictionary (Key-Value) Operations ]
		| Operation      | Performance           |
		| -------------- | --------------------- |
		| Set()          | 47,031 ops/sec        |
		| Get() (Hit)    | 1,138,692 ops/sec     |
		| Get() (Miss)   | 1,055,520 ops/sec     |
		| Has()          | 2,625,360 ops/sec     |
		| Remove()       | 71,557 ops/sec        |

		Set()/Remove() include eviction, TTL, and metadata bookkeeping
		
	[ Bulk Operations ]
		| Operation         | Single-threaded | Multi-threaded |
		| ----------------- | --------------- | -------------- |
		| BulkSet(1k)       | 113 ops/sec     | 149 ops/sec    |
		| BulkGet(1k)       | 971 ops/sec     | 796 ops/sec    |
		| BulkRemove(1k)    | 113 ops/sec     | N/A            |
		
		Larger batches (e.g. 10K+) incur significant LuaU threading  
		and GC overhead, and may trigger script timeouts
	
	[ Eviction Policy Overhead ]
		| Policy | Set() Performance (Evicting) |
		| ------ | ---------------------------- |
		| FIFO   | 48,620 ops/sec               |
		| LRU    | 57,783 ops/sec               |
		| LFU    | 49,489 ops/sec               |
		| ARC    | 59,884 ops/sec               |
		
		ARC (Adaptive Replacement Cache) adapts dynamically
		and shows top performance under forced eviction
		
	[ Advanced Loading & TTL Overhead ]
		| Operation                     | Performance        |
		| ----------------------------- | ------------------ |
		| SetWithTTL()                  | 44,631 ops/sec     |
		| GetOrLoad() (Cache Miss)      | 37,815 ops/sec     |
		| GetOrLoad() (Cache Hit)       | 85,404 ops/sec     |
		| DefineVirtual() + Get()       | 14,504 ops/sec     |
		| Prefetch() (Async fire)       | 12,756 ops/sec     |
		
		TTL and lazy-loading features add predictable overhead  
		optimized for non-blocking preloads
		
	[ Data Serialization & Compression ]
		| Format / Operation            | Ops/sec           |
		| ----------------------------- | ----------------- |
		| Set() (JSON default)          | 38,115 ops/sec    |
		| Set() (Zstd compression)      | 3,010 ops/sec     |
		| Get() (Zstd decompress)       | 27,043 ops/sec    |
		
		Compression trades CPU for memory savings 
		JSON remains the fastest serialization path
		
	[ Cleanup & Iteration ]
		| Operation                    | Performance       |
		| ---------------------------- | ----------------- |
		| ForEach() (1k items)         | 7,102 ops/sec     |
		| RemoveNamespace()            | 11,918 ops/sec    |
		| RemoveByPattern() (Trie)     | 1,313 ops/sec     |
		| RemoveByPattern() (Scan)     | 63 ops/sec        |
		
		Trie-backed removals offer fast prefix scans 
		Full-scan fallback is intentionally penalized
		
	[ Metadata & Pinning ]
		| Operation        | Performance        |
		| ---------------- | ------------------ |
		| SetMetadata()    | 212,779 ops/sec    |
		| Pin/Unpin()      | 24,471 ops/sec     |
		
		Pinning incurs validation overhead to prevent misuse
]]

--[[
	History:[
		[4/20/25 3:57 PM UTC+9]: 
		Replaced store with two subtables: "arrays" and "dictionaries"
		
		[4/20/25 7:56 PM UTC+9]: 
		I kind of forgot to list down the changes... Oh well.
		[4/20/25 11:54 PM UTC+9]: 
		
		Introduced policies, AKA: FIFO, LRU, and LFU, replacing and deprecating 
		the RecordAccess and AccessList function
		
		[4/21/25 11:36 PM UTC+9]: 
		The Insert method has been deprecated in favor of InsertSingle and InsertBatch.
		
		[4/23/25 6:26 PM UTC+9]: 
		Fixed an oversight where in Restore:(), "Policies[...].new(...)" 
		was set as "Policies[...]:new(...)". Notice the difference?
		
		[4/23/25 6:52 PM UTC+9]: 
		Introduced Lazy Loading via GetOrLoad
		
		[4/23/25 11:52 PM UTC+9]: 
		Each policies are now memory-aware, also added QoL methods to memory :)
		
		[4/25/25 11:45 PM UTC+9]: 
		Refactored cache insertion logic (Set, SetWithTTL, InsertSingle) to 
		route through a new unified method _encodeEntry, which handles serialization, 
		size estimation, and eviction checks.
		
		[4/26/25 5:19 PM UTC+9]: 
		Snapshot method now supports a mode for shallow, deep, or auto cloning.
		
		[4/26/25 7:05 PM UTC+9]: 
		TTL has been moved into its own sub-module for easier management. 
		TTLInterval and its parameter is also deprecated.
		
		[4/26/25 11:02 PM UTC+9]: 
		Introduced an experimental serialization format as an alternative to JSON. (KELP/kelPack)
		
		[4/27/25 12:35 PM UTC+9]: 
		Introduced two new methods: Resume and Pause
		
		[4/28/25 11:34 PM UTC+9]: 
		Introduced way too many methods (17 exact) at once.
		
		[4/29/25 11:30 PM UTC+9]: 
		Improved error and warn debugs.
		
		[4/30/25 8:10 PM UTC+9]: 
		Added missing descriptions to multiple methods.
		
		[6/11/25 6:33 PM UTC+9]: 
		I forgot to update History, but the previous changes were optimizations.
		
		[6/11/25 8:09 PM UTC+9]: 
		Introduced Trie primarily for the RemoveByPattern method. 
		
		[6/11/25 11:35 PM UTC+9]: 
		Introduced new algorithms, BloomFilter, Count-Min Sketch, Cuckoo Filter, and many more. 
		Murmurmash was quickly added but then immediately removed because of xxHash.
		
		[6/12/25 6:41 PM UTC+9]:
		Done a lot of edge-case testing and debugging,
		and fixed (I think) all of it (hopefully).
		
		[6/12/25 8:02 PM UTC+9]:
		Replaced GoodSignal with FastSignal because we aren't 
		yielding anywhere and we're lightweight anyway.
		
		See Stravant's official benchmark test:
		| FastSignal | GoodSignal | SimpleSignal | RobloxSignal | 
		--------------------------------------------------------------------------------
		CreateAndFire         |  0.6μs     |  1.2μs     |  2.4μs       |  18.5μs      | 
		ConnectAndDisconnect  |  0.3μs     |  0.3μs     |  0.4μs       |  1.8μs       | 
		FireWithNoConnections |  0.1μs     |  0.0μs     |  0.0μs       |  2.2μs       | 
		Fire                  |  0.2μs     |  0.8μs     |  3.8μs       |  3.2μs       | 
		FireManyArguments     |  0.2μs     |  0.8μs     |  2.0μs       |  3.5μs       | 
		FireManyHandlers      |  0.2μs     |  4.4μs     |  15.2μs      |  6.0μs       | 
		FireYieldingHandler   |  N/A       |  5.1μs     |  5.1μs       |  6.1μs       | 
		WaitOnEvent           |  3.1μs     |  3.5μs     |  5.1μs       |  5.6μs       |
		https://devforum.roblox.com/t/lua-signal-class-comparison-optimal-goodsignal-class/1387063
		
		[6/13/25 12:32 PM UTC+9]:
		A bit sudden, but, there's now 58 public APIs 
		compared to 46 in the previous version.
		Also, this is now a stable build (v0.3.39) because of edge-case testing.
		
		[6/14/25 9:54 PM UTC+9]:
		Multi-threading added, also new public API.
		The total of public APIs has increased to 59 APIs.
		
		[6/14/25 11:30 PM UTC+9]:
		Merged EnableReadOnly and DisableReadOnly 
		into ReadOnly(state) for ergonomitry.
		Also added Destroy API.
		
		[6/15/25 11:06 PM UTC+9]:
		Replaced FastSignal with KelSignal. 
		See KelSignal for benchmark results
		
		[6/15/25 12:52 PM UTC+9]:
		I FINALLY FIXED DUMB DOC COMMENTS 
		NOT BEING DISPLAYED BY INTELLISENSE
		
		[6/16/25 9:47 PM UTC+9]:
		EstimateClientCore was silently dropped
		
		[6/16/25 12:37 PM UTC+9]:
		Expiremented the hell out of Actors, they are furiating.
		Multi-threading will still use task.spawn
		unless someone smarter does it for me.
		
		[6/20/25 9:57 PM UTC+9]:
		Added mutex locking yay
		also added Update and Transaction
		60 APIs in total now wooo
		
		[6/21/25 4:59 PM UTC+9]:
		removed redundant calls and internal apis
	]
]]

--[[
	Terminology:
	.____________________________________________________________________________________________________________________________________
	| Term                          | Meaning                                                                                            |
	| ----------------------------- | -------------------------------------------------------------------------------------------------- |
	| TTL                       	| Time to Live – how long a cache entry stays before it expires.                                   	 |
	| LRU                       	| Least Recently Used – eviction policy that removes the least recently accessed item first.      	 |
	| LFU                       	| Least Frequently Used – removes the item accessed the fewest times.                             	 |
	| FIFO                      	| First-In, First-Out – removes the oldest inserted item.                                         	 |
	| RR                        	| Random Replacement – evicts a random entry when full.                                           	 |
	| ARC                       	| Adaptive Replacement Cache – automatically balances between LRU and LFU based on usage patterns.	 |
	| Eviction                  	| When an entry is removed from the cache (due to size, TTL, or policy).                             |
	| Compression (Zstd/LZ4)    	| Optional algorithms to reduce memory usage of large entries.                                       |
	| Serialization (JSON/KELP) 	| Converts a table/value into a storable string format.                                              |
	| Weak references           	| Lua feature allowing garbage collection of values/keys if not used elsewhere.                      |
	| Hit / Miss                	| Hit: data found in cache. Miss: data had to be loaded or computed.                            	 |
	| Memory Budget             	| Limit (in bytes) for how much data a cache can store before evicting items.                        |
	| GetOrLoad                 	| Function that retrieves a value if present, or generates + caches it if not.                       |
	| Snapshot                  	| A full export of current cache contents (can be restored later).                                   |
	^‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾
]]
