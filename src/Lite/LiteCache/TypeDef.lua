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
	kind: "dict",
	key: string?,
	value: T,
	expired: boolean,
}
export type SnapshotData<T> = {
	dict: {[string]: CacheEntry<T>},
	maxobj: number,
	policyName: string,
	policyState: PolicyState,
	timestamp: number,
}
export type LiteCache<T> = {
	Name: string,
	Set: typeof(
		--[[
			Set a value under "key". Optional TTL can be provided.
			<code>cache:Set("key", "value")
			cache:Set("key", "value", 60) -- Expires in 60s
		]]
		function(self: LiteCache<T>, key: string|{any}, value: T, ttl: number?): () end
	),
	Get: typeof(
		--[[
			Returns the value for a key, if it exists and hasn’t expired.
			Automatically removes expired TTL entries on access.
			
			<code>local val = cache:Get("key")
		]]
		function(self: LiteCache<T>, key: string|{any}): T? end
	),
	GetOrSet: typeof(
		--[[
			Atomic operation. Tries to Get a key. If missing/expired, it runs the callback,
			stores the result, and returns it.
			
			<code>
			local val = cache:GetOrSet("key", function()
				return Instance.new("Part") -- Only runs if "key" is missing
			end, 60)
			</code>
		]]
		function(self: LiteCache<T>, key: string|{any}, callback: () -> T, ttl: number?): T end
	),
	SetWithTTL: typeof(
		--[[
			Explicit method to set a value with a lifespan. 
			Alias for Set(k, v, ttl).
		]]
		function(self: LiteCache<T>, key: string|{any}, value: T, ttl: number): T end
	),
	Has: typeof(
		--[[
			Checks whether a key exists and hasn’t expired.
		]]
		function(self: LiteCache<T>, key: string|{any}): boolean end
	),
	Remove: typeof(
		--[[
			Deletes a key-value pair from the cache.
		]]
		function(self: LiteCache<T>, key: string|{any}): () end
	),
	Clear: typeof(
		--[[
			Completely resets the cache’s internal storage and policy.
		]]
		function(self: LiteCache<T>): () end
	),
	Pause: typeof(
		--[[
			Pauses the TTL background loop. 
		]]
		function(self: LiteCache<T>): () end
	),
	Resume: typeof(
		--[[
			Resumes the TTL background loop.
		]]
		function(self: LiteCache<T>): () end
	),
	Peek: typeof(
		--[[
			Return a value without bumping its LRU/LFU state or affecting TTL.
		]]
		function(self: LiteCache<T>, key: string|{any}): T? end
	),
	Keys: typeof(
		--[[
			Return a list of all valid keys.
		]]
		function(self: LiteCache<T>): {string|{any}} end
	),
	Values: typeof(
		--[[
			Return a list of all valid values.
		]]
		function(self: LiteCache<T>): {T} end
	),
	TTLRemaining: typeof(
		--[[
			Return seconds until expiration, or nil if none.
		]]
		function(self: LiteCache<T>, key: string|{any}): number? end
	),
	Destroy: typeof(
		--[[
			Destroys the cache and cleans up memory.
		]]
		function(self: LiteCache<T>): () end
	),
}
export type Static = {
	Create: <T>(CacheName: string, MaxObjects: number?, Opts: {Mode: string?, Policy: string?}?) -> LiteCache<T>
}
------------------------------------------------------------------------------------------------------------
export type Master = {
	FIFOState: FIFOState,
	LRUState: LRUState,
	LFUState: LFUState,
	RRState: RRState,
	PolicyState: PolicyState,
	CacheEntry: CacheEntry<any>,
	EvictionInfo: EvictionInfo<any>,
	SnapshotData: SnapshotData<any>,
	LiteCache: LiteCache<any>,
	Static: Static,
}
local TypeDef = {}
return TypeDef :: Master