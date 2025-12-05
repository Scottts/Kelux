--[[
	LiteCache Documentation
	Version: 0.3.04 (STABLE)

	Author: Kel (@GudEveningBois)

	1. Introduction
		LiteCache is the streamlined, lightweight version of FullCache. 
		It is designed for developers who need a simple, efficient, 
		and easy-to-use caching solution without the overhead of advanced features.

		It retains the core dual-structure design of FullCache, featuring both an 
		array-based and a dictionary-based cache. This makes it a versatile choice 
		for managing temporary data, reducing latency, and decreasing the load on 
		persistent data stores, all with a much smaller API footprint.

		Key Features:
		
			Dual Cache Structure: 
				Manages both ordered (array) and keyed (dictionary) data.

			Flexible Eviction Policies: 
				Includes FIFO, LRU, LFU, and Random Replacement (RR) policies.

			Comprehensive Memory Management: 
				Set memory budgets and monitor usage in bytes.

			Time-To-Live (TTL)
				Automatically expire data after a set duration.

	2. Getting Started
		To begin using LiteCache, you first need to create a cache instance.

		LiteCache.Create(CacheName, MaxObjects, Opts)
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
				The eviction policy to use. Options: "FIFO", "LRU", "LFU", "RR", "ARC. Defaults to "FIFO".
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

		Example:
			----------------------------------------------------------------------------
			local LiteCache = require(the.path.to.LiteCache)
			-- Create a cache for player data with a max of 200 players, using the LRU policy
			local playerDataCache = LiteCache.Create("PlayerDataCache", 200, {
				Policy = "LRU",
				MemoryBudget = 10 * 1024 * 1024 -- 10 MB
			})
			----------------------------------------------------------------------------

	3. Core Concepts
	
		Dual Structure: Array and Dictionary
			LiteCache manages two separate internal data structures, 
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

	4. API Reference (References are also seen in LiteCache's source code)
	
		Creation:
			LiteCache.Create(CacheName, MaxObjects, Opts)
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

				cache:Has(key)
				Returns true if a non-expired key exists.

				cache:Remove(key)
				Deletes a key-value pair.

		General Cache Operations:

			cache:Clear()
			Empties the entire cache.

		Introspection & Iteration:
		
			cache:Peek(key)
			Retrieves a value by key without affecting its status in LRU/LFU policies.

			cache:Keys()
			Returns a list of all keys in the dictionary.

			cache:Values()
			Returns a list of all values from both the array and dictionary.

		Time-To-Live (TTL):
		
			cache:SetWithTTL(key, value, ttl)
			Stores a key-value pair that will automatically expire after ttl seconds.

			cache:TTLRemaining(key)
			Returns the remaining seconds until a key expires, or nil.

		Bulk Operations:
		
			cache:BulkSet(entries)
			Sets multiple key-value pairs from a dictionary.

			cache:BulkGet(keys)
			Retrieves multiple values from a list of keys.

			cache:BulkRemove(keys)
			Removes multiple key-value pairs from a list of keys.

	5. Practical Examples
	
		Example 1: Caching Player Profiles
			----------------------------------------------------------------------------
			local Players = game:GetService("Players")
			local DataStoreService = game:GetService("DataStoreService")
			local profileStore = DataStoreService:GetDataStore("PlayerProfiles")
			local profileCache = LiteCache.Create("ProfileCache", 150, {Policy = "LRU"})
			local function getPlayerProfile(player)
			local userId = player.UserId
			-- Check the cache first
			local profile = profileCache:Get(userId)
				if not profile then
					print("Cache miss for "..userId..". Loading from DataStore.")
					local success, data = pcall(function()
						return profileStore:GetAsync(userId)
					end)
					profile = success and data or {bux = 100, level = 1}
					-- Store the newly loaded data in the cache for 1 hour
					profileCache:SetWithTTL(userId, profile, 3600)
				end
				return profile
			end
			Players.PlayerAdded:Connect(getPlayerProfile)
			----------------------------------------------------------------------------
			
		Example 2: Temporary Cooldowns
			----------------------------------------------------------------------------
			local abilityCooldowns = LiteCache.Create("Cooldowns")
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
	History:[
		[6/11/25 6:07 PM UTC+9]:
		Came back to finally fix the outdated system.
		
		[6/11/25 11:50 PM UTC+9]:
		Introduced the xxHash algorithm.
		
		[6/12/25 4:50 PM UTC+9]:
		Added Trie and optimized many other things to 
		keep it up-to-date with FullCache, also ARC policy is now here.
		
		[6/22/25 8:58 PM UTC+9]:
		Added mutex-locking and fixed some outdated stuff
		also school starts tomorrow :(
	]
]]
