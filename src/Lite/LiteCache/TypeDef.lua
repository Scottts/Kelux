-- Annotations ---------------------------------------------------------------------------------------------
export type FIFOState = { queue: {string} }
export type LRUState = { head: string?, tail: string?, nodes: {[string]: any} }
export type LFUState = { minFreq: number, freqMap: {[number]: {string}} }
export type RRState = { queue: {string} }
export type PolicyState = FIFOState | LRUState | LFUState | RRState
export type CacheEntry<T> = {
	value: T,
	expires: number?,
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
export type LiteCache<T> = {
	InsertSingle: typeof(
		--[[
			Inserts a single object into the array section of the cache.
			<code>cache:InsertSingle("Pen")
		]]
		function(self: LiteCache<T>, item: T): T end
	),
	InsertBatch: typeof(
		--[[
			Inserts multiple values into the array section of the cache.
			<code>cache:InsertBatch({ "Pen", "Pineapple", "Apple", "Pen" })
		]]
		function(self: LiteCache<T>, items: {T}): {T} end
	),
	Set: typeof(
		--[[
			Set a value under "key", without TTL.
			Later "Get(key)" will return the raw "value".
			<code>cache:Set("key", "value")
		]]
		function(self: LiteCache<T>, key: string|{any}, value: T): T end
	),
	Get: typeof(
		--[[
			Returns the value for a key, if it exists and hasn’t expired.
			Automatically removes expired TTL entries.
			
			<code>local username = cache:Get("username_123")
		]]
		function(self: LiteCache<T>, key: string|{any}): T? end
	),
	Has: typeof(
		--[[
			Checks whether a key exists and hasn’t expired.
			Cleans up expired TTL values in the process.
			
			<code>if cache:Has("username_123") then
				print("Key is still valid!")
			end
		]]
		function(self: LiteCache<T>, key: string|{any}): boolean end
	),
	Remove: typeof(
		--[[
			Deletes a key-value pair from the dictionary section, <em>regardless of its state.</em>
			<code>cache:Remove("username_123")
		]]
		function(self: LiteCache<T>, key: string|{any}): () end
	),
	Clear: typeof(
		--[[
			Completely resets the cache’s internal storage.
			Also resets the eviction policy to default state.
			
			<code>cache:Clear()
		]]
		function(self: LiteCache<T>): () end
	),
	Cleanup: typeof(
		--[[
			Removes all nil entries in the array section.
			This is a maintenance function mostly for the FIFO array.
			
			<code>cache:Cleanup()
		]]
		function(self: LiteCache<T>): () end
	),
	Peek: typeof(
		--[[
			Return a dict-entry value without bumping 
			its LRU/LFU state or affecting TTL.
			<code>local value = cache:Peek("key")
			if value then
				print(value)
			end
		]]
		function(self: LiteCache<T>, key: string|{any}): T? end
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
		function(self: LiteCache<T>): {string|{any}} end
	),
	Values: typeof(
		--[[
			Return a list of all values in array + dict
			<strong>(Excludes expired)</strong>
			
			<code>local values = cache:Values()
		]]
		function(self: LiteCache<T>): {T} end
	),
	SetWithTTL: typeof(
		--[[
			Stores a key-value pair that expires in "ttl" seconds.
			Useful for temporary data like sessions or cooldowns.
			
			<code>cache:SetWithTTL("session_abc", "SessionData", 30)
		]]
		function(self: LiteCache<T>, key: string|{any}, value: T, ttl: number): T end
	),
	TTLRemaining: typeof(
		--[[
			Return seconds until expiration, or nil if none.
			<code>local remaining = cache:TTLRemaining("key")
		]]
		function(self: LiteCache<T>, key: string|{any}): number? end
	)
}
export type Static = {
	Create: typeof(
		--[[
			Creates a new named cache or returns an existing one if already created.
			Supports optional max
			object count, TTL interval in seconds, and cache options (weak/strong mode and eviction policy).
			<code>local cache = LiteCache.Create("MyCache", 100, 5, { Mode = "strong", Policy = "LRU" })
		]]
		function(self: LiteCache<T>, CacheName: string, MaxObjects: number?, Opts: {Mode: string, Policy: string, MemoryBudget: number, MaxSerializedSize: number}?): LiteCache<T> end
	),
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
	SnapshotData: SnapshotData,
	LiteCache: LiteCache,
	Static: Static,
}
local TypeDef = {}
return TypeDef :: Master