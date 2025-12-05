--!strict
-- AUTHOR: Kel (@GudEveningBois)
local FullFolder = script:WaitForChild("Full")
local LiteFolder = script:WaitForChild("Lite")
local Components = script:WaitForChild("Components") 

local FullBus = require(FullFolder:WaitForChild("FullBus"))
local FullCache = require(FullFolder:WaitForChild("FullCache"))
local FullPool = require(FullFolder:WaitForChild("FullPool"))
local FullState = require(FullFolder:WaitForChild("FullState"))
local FullTask = require(FullFolder:WaitForChild("FullTask"))
local KelSignal = require(Components:WaitForChild("KelSignal"))

local BusTypes = require(FullFolder.FullBus:WaitForChild("TypeDef"))
local CacheTypes = require(FullFolder.FullCache:WaitForChild("TypeDef"))
local PoolTypes = require(FullFolder.FullPool:WaitForChild("TypeDef"))
local StateTypes = require(FullFolder.FullState:WaitForChild("TypeDef"))
local TaskTypes = require(FullFolder.FullTask:WaitForChild("TypeDef"))

export type FullBus = BusTypes.Static
export type FullCache<T> = CacheTypes.Static
export type FullPool<T> = PoolTypes.Static
export type FullState = StateTypes.Static
export type FullTask = TaskTypes.Static

export type TaskPriority = TaskTypes.Priority
export type TaskState = TaskTypes.TaskState
export type StateAction = StateTypes.Action

local Kelux = {
	createBus = FullBus.Create,
	createCache = FullCache.Create,
	createPool = FullPool.Create,
	createState = FullState.Create,
	createTask = FullTask.Create,
	Bus = FullBus,
	Cache = FullCache,
	Pool = FullPool,
	State = FullState,
	Task = FullTask,
	Signal = KelSignal,
	TaskPriority = FullTask.Priority,
	TaskState = FullTask.TaskState,
	combineReducers = FullState.combineReducers,
	StateMiddleware = FullState.middleware,
	getPoolsByPattern = FullPool.GetPoolsByPattern,
	destroyPoolsByPattern = FullPool.DestroyByPattern,
	prefetchPools = FullPool.PrefetchByPattern,
	shrinkPoolsByPattern = FullPool.ShrinkByPattern,
	Versions = {
		Bus = FullBus.Version,
		Cache = FullCache.Version,
		Pool = FullPool.Version,
		State = FullState.Version,
		Task = FullTask.Version,
	}
}
return table.freeze(Kelux)
