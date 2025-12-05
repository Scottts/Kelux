-- Annotations ---------------------------------------------------------------------------------------------
export type PoolConfig = {
	name: string?,
	maxSize: number?,
	initialSize: number?,
	templateInstance: Instance?,
	cleanupCallback: ((Instance) -> ())?,
}
export type LitePool<T> = {
	Name: string,
	InstanceType: string,
	Get: typeof(
		--[[
			Retrieves an instance from the pool. If the pool is empty, a new instance is created and returned.
			<code>local part = myPool:Get()
		]]
		function(self: LitePool<T>): Instance end
	),
	Return: typeof(
		--[[
			Returns an instance to the pool, making it available for reuse.
			
			<code>myPool:Return(part)
		]]
		function(self: LitePool<T>, instance: Instance): () end
	),
	Destroy: typeof(
		--[[
			Destroys all instances and cleans up the pool entirely.
			The pool cannot be used after this is called.
			
			<code>myPool:Destroy()
		]]
		function(self: LitePool<T>): () end
	),
}
export type Static = {
	Create: <T>(poolName: string, config: PoolConfig?) -> LitePool<T>
}
------------------------------------------------------------------------------------------------------------
export type Master = {
	PoolConfig: PoolConfig,
	LitePool: LitePool,
	Static: Static,
}
local TypeDef = {}
return TypeDef :: Master