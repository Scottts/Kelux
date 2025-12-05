--[[
	[ FULLSTATE DOCUMENTATION ]
	Version: 0.1.1 (STABLE) 

	Author: Kel (@GudEveningBois) 

	1. Introduction
		FullState is a predictable, centralized state container for Roblox,
		inspired by modern web state-management patterns. It provides a
		robust solution for managing complex, shared application state
		(like UI state, player data, and session info) in a way that is
		predictable, testable, and easy to debug.

		It ensures all state changes are explicit and unidirectional,
		eliminating race conditions and "spaghetti code" that can arise
		from many different scripts modifying the same data.

		Key Features:

			Single Source of Truth:
				A centralized store holds the entire state of your application.
			Predictable Updates:
				State is modified by dispatching actions to pure functions
				called reducers, making changes explicit and traceable.
			Read-Only State:
				The state cannot be modified directly. GetState() returns
				a deeply frozen, read-only copy, preventing mutations.
			Middleware Chain:
				A powerful middleware API allows you to intercept actions to
				add logging, validation, async thunks, and more.
			Time-Travel Debugging:
				Step backward and forward through state history
				with Undo() and Redo().
			State Slices:
				Create "slice" views that act like mini-state managers
				for a specific part of your state.
			Memoized Selectors:
				Create efficient, memoized functions to compute derived
				data from the state without unnecessary re-calculations. 
			Concurrency-Safe:
				All operations are thread-safe, protected by an internal
				mutex to prevent data corruption.
			Atomic Transactions:
				Atomically apply multiple state changes in a single,
				all-or-nothing operation. 
			Persistence:
				Snapshot() and Restore() the entire state, including history,
				for saving to DataStores or replication.

	2. Getting Started
		To begin using FullState, you first need to create a state instance.

		FullState.Create(StateName, initialState, reducer, options?)
		This function creates a new, named state manager.

		Parameters:
			StateName (string) [Required]
			A unique name for your state manager (e.g., "PlayerSession").

			initialState (any) [Required]
			The default state to initialize the manager with.

			reducer (function) [Required]
			A function that takes (state, action) and returns the new state.

			options (table?) [Optional]
			A table of advanced options to configure the state's behavior. 

		Options Table (options)
			deduplication (table) 
			Enables deterministic action deduplication.
				enabled (boolean): If true, identical actions dispatched
				in rapid succession will be ignored.
				maxSize (number?): Max actions to track in the dedupe log.
				maxAge (number?): Max time (in seconds) to track an action.

		Example:
			----------------------------------------------------------------------------
			local FullState = require(the.path.to.FullState)

			-- 1. Define the initial state
			local initialState = {
				counter = 0,
				name = "Guest"
			}

			-- 2. Define the reducer
			local function reducer(state, action)
				if action.type == "INCREMENT" then
					state.counter += (action.payload or 1)
				elseif action.type == "SET_NAME" then
					state.user.name = action.payload
				end
				return state
			end

			-- 3. Create the state manager
			local myState = FullState.Create("MyApplicationState", initialState, reducer)

			-- 4. Dispatch an action to change the state
			myState:Dispatch({ type = "INCREMENT", payload = 5 })
			----------------------------------------------------------------------------

	3. Core Concepts

		Unidirectional Data Flow
			FullState enforces a one-way data flow. This is the core
			principle that makes your state predictable.
				State: A read-only copy of the state is read by your UI/game.
				
				Action: To change something, you dispatch an action
				(e.g., { type = "PLAYER_JOINED" }). 
				
				Reducer: The state manager passes the current state and the
				action to your reducer.
				
				New State: Your reducer returns a new state object, which
				replaces the old one and notifies all listeners.

		Immutability
			You must never modify the state object given to your reducer.
			Your reducer must always return a new copy of the state
			(or the original state if no changes were made).

			While FullState's internal logic copies the state before passing
			it to a single root reducer, this is a bad practice
			that will break combineReducers and selector memoization.

			The correct, pure pattern is to return a new state table if a change occurs.

			-- [Bad]: Mutating the state
			function reducer(state, action)
				if action.type == "INCREMENT" then
					state.counter += 1 -- Mutation
				end
				return state
			end

			-- [Good]: Pure Reducer Pattern
			function reducer(state, action)
				if action.type == "INCREMENT" then
					-- Create a new state table with the change
					local newState = {
						counter = state.counter + 1,
						name = state.name -- Don't forget other keys
					}
					return newState
				end

				-- No change, return the original state
				return state
			end

		Middleware
			Middleware provides an extension point between dispatching an
			action and the moment it reaches the reducer. It's ideal for
			logging, crash reporting, validation, or handling async logic.
			The most common middleware is thunk, which lets you dispatch
			functions for async operations. 

		Selectors
			Selectors are memoized functions that compute derived data
			from the state.  Because GetState() returns a new copy
			every time, you can't use simple equality checks (old == new).
			Selectors solve this by only re-computing their value when
			the underlying state actually changes, making them very
			efficient for connecting your game logic to state.

	4. API Reference

		Creation:
			FullState.Create(StateName, initialState, reducer, options?)
			Creates or returns a state manager instance. See Getting Started.

		State Access & Actions:
			state:Dispatch(action)
			Dispatches an action (or thunk) to be processed by middleware
			and the reducer.  This is the only way to trigger a state change.

			state:GetState()
			Returns a deep, frozen (read-only) copy of the current state.

			state:GetStateHash()
			Returns a fast 32-bit hash of the current state for quick comparisons.

		Subscriptions & Selectors:
			state:OnChanged(listener)
			Connects a listener that fires after a dispatch has successfully
			completed and the state has changed. Returns a connection ID (number).
			
			----------------------------------------------------------------------------
			local id = state:OnChanged(function(newState, oldState, action)
				print("State changed due to:", action.type)
			end)

			-- To stop listening:
			state:Disconnect(id)
			----------------------------------------------------------------------------

			state:OnDispatch(listener)
			Connects a listener that fires before an action is processed by
			middleware. Returns a connection ID (number).

			state:OnCommit(listener)
			Connects a listener that fires after the reducer has run but
			before OnChanged listeners are notified. Returns a
			connection ID (number).

			state:OnError(listener)
			Connects a listener that fires when an error occurs inside a
			dispatch, transaction, or other method. Returns a
			connection ID (number).

			state:SubscribeToPath(path, listener, options?)
			Subscribes to changes on a specific, deep path within the state
			(e.g., "user.settings.theme"). The listener fires only if
			the value at that path changes. Returns a disconnect function.

			state:Disconnect(id)
			Disconnects a listener using the connection ID number
			returned from an On... method. Does not work for
			SubscribeToPath listeners.
			
			----------------------------------------------------------------------------
			local id = state:OnChanged(myListener)
			-- Some changes later...
			state:Disconnect(id)
			----------------------------------------------------------------------------

			state:WaitForChange(selectorFn?, timeout?)
			Yields the current thread until the state changes, returning a (value, error) tuple.
			This function must be called from a coroutine (e.g., using task.spawn).

			An optional selector function can be provided. If it is,
			this function will only resume when the result of the
			selector is different from its value when the
			function was first called.
			
			----------------------------------------------------------------------------
			task.spawn(function()
				-- Wait 10 seconds for the user's name to change
				local newName, err = state:WaitForChange(function(s)
					return s.user.name
				end, 10)
	
				if err then
					print("Wait failed:", err)
				else
					print("Name is now:", newName)
				end
			end)
			----------------------------------------------------------------------------

			state:CreateSelector(selectorFn, equalityFn?)
			Creates a memoized selector function to efficiently read
			derived state. The selector only re-computes when the
			data it depends on has changed.

			state:ClearListeners()
			Removes all listeners connected to the 'OnChanged' signal.
			
		Middleware & Slices:
			state:use(middleware)
			Applies a middleware to the state's dispatch chain.

			state:CreateSlice(slicePath)
			Creates a "slice" view into a part of the state.  This slice
			has its own Dispatch and GetState methods, making it
			easier to manage modular state.

		Time Travel & History:
			state:Undo()
			Reverts the state to the previous point in history.

			state:Redo()
			Re-applies a previously undone action. 

			state:GetStateHistoryRange(startIndex, endIndex)
			Retrieves a range of decompressed state snapshots
			from the history buffer. 

		Persistence & Auditing:
			state:Snapshot()
			Creates a serializable snapshot of the entire state manager,
			including history and audit logs.

			state:Restore(snapshot)
			Restores the state manager from a snapshot,
			overwriting the current state and history.

			state:ToJSON()
			Serializes the result of Snapshot() into a JSON string. 

			state:FromJSON(jsonString)
			Restores the state manager from a JSON string. 

			state:BuildAuditTree()
			Builds a Merkle Tree from the internal action audit log and
			clears the log.  Returns the root hash.

			state:GetAuditRoot()
			Gets the root hash of the last built Merkle Tree. 

		Management & Introspection:
			state:Batch(callback)
			Batches multiple dispatches into a single "OnChanged"
			notification, which fires after the callback completes.

			state:Transaction(transactionFn)
			Executes multiple dispatches in an atomic block.  If the
			function errors, all changes are rolled back.  If it
			succeeds, all changes are applied as a single action.

			state:ReadOnly(state)
			Enables or disables read-only mode, which blocks all dispatches.

			state:Reset(newInitialState?)
			Resets the state manager. If no argument is given, resets to
			the original initial state.  If 'nil' is passed, the
			state is reset to nil.  This clears all history.

			state:Destroy()
			Completely removes and cleans up the state instance.

			state:GetActionHistory()
			Returns a deep copy of the recent action history,
			including timestamps. 

			state:GetMetrics()
			Returns a table of performance and usage metrics.

		Static Methods:
			FullState.combineReducers(reducers)
			Combines a table of reducer functions into a single root reducer.
			Each key in the table corresponds to a key in the state.

			This combined reducer will call each child reducer, passing it
			its own slice of the state. For this to work efficiently, your
			child reducers must be pure and return a new table on
			a change, or the original state if no change occurred.
			
			----------------------------------------------------------------------------
			-- userReducer handles state.user
			local function userReducer(state, action)
				if state == nil then state = { name = "Initial" } end
				if action.type == "SET_NAME" then
					return { name = action.payload } -- Return new table
				end
				return state -- Return old table
			end
			-- inventoryReducer handles state.inventory
			local function inventoryReducer(state, action)
				if state == nil then state = { items = {} } end
				-- Dostuff
				return state
			end
			local rootReducer = FullState.combineReducers({
				user = userReducer,
				inventory = inventoryReducer
			})
			-- The resulting state will be: { user = ..., inventory = ... }
			----------------------------------------------------------------------------

			FullState.middleware.logger()
			Returns a simple logger middleware that prints action types.

			FullState.middleware.thunk()
			Returns a thunk middleware that allows dispatching functions
			for asynchronous logic.

			FullState.middleware.performance(threshold?)
			Returns a middleware that warns if a dispatch takes longer
			than a given threshold.

			FullState.middleware.validator(schema)
			Returns a middleware that validates action payloads against
			a schema.

	5. Practical Examples

		Example 1: Simple Counter
			----------------------------------------------------------------------------
			local FullState = require(script.FullState)

			local initialState = { counter = 0 }

			local function reducer(state, action)
				if action.type == "INCREMENT" then
					state.counter += 1
				elseif action.type == "DECREMENT" then
					state.counter -= 1
				end
				return state
			end

			local counterState = FullState.Create("Counter", initialState, reducer)

			counterState:OnChanged(function(newState)
				print("Counter is now:", newState.counter)
			end)

			counterState:Dispatch({ type = "INCREMENT" }) -- Prints: Counter is now: 1
			counterState:Dispatch({ type = "INCREMENT" }) -- Prints: Counter is now: 2
			----------------------------------------------------------------------------

		Example 2: Async Logic with Thunks
			----------------------------------------------------------------------------
			local FullState = require(script.FullState)

			local initialState = { status = "idle", data = nil }

			local function reducer(state, action)
				if action.type == "FETCH_START" then
					state.status = "loading"
				elseif action.type == "FETCH_SUCCESS" then
					state.status = "success"
					state.data = action.payload
				end
				return state
			end

			-- Create the state and apply thunk middleware
			local dataState = FullState.Create("Data", initialState, reducer)
			dataState:use(FullState.middleware.thunk())

			-- Create a thunk action
			local function fetchData()
				return function(dispatch, getState)
					-- Don't fetch if already loading
					if getState().status == "loading" then return end

					dispatch({ type = "FETCH_START" })

					-- Simulate an async API call
					task.wait(2)
					local fakeData = { id = 123, name = "Fake Data" }

					dispatch({ type = "FETCH_SUCCESS", payload = fakeData })
				end
			end

			-- Dispatch the thunk
			dataState:Dispatch(fetchData())
			----------------------------------------------------------------------------

		Example 3: Using Slices and Selectors
			----------------------------------------------------------------------------
			local FullState = require(script.FullState)

			local initialState = {
				user = { name = "Guest", id = 0 },
				inventory = { items = {"Apple", "Sword"} }
			}

			-- A reducer that can handle actions for both user and inventory
			local function rootReducer(state, action)
				if action.type == "user/SET_NAME" then
					state.user.name = action.payload
				elseif action.type == "inventory/ADD_ITEM" then
					table.insert(state.inventory.items, action.payload)
				end
				return state
			end

			local rootState = FullState.Create("Root", initialState, rootReducer)

			-- Create a slice for just the user state
			local userSlice = rootState:CreateSlice("user") 
			-- GetState() on the slice only returns the 'user' part 
			print("User:", userSlice:GetState().name) -- Prints: User: Guest

			-- Dispatching to the slice automatically prefixes the action type
			-- This will dispatch { type = "user/SET_NAME", payload = "Kel" }
			-- to the root reducer.
			userSlice:Dispatch({ type = "SET_NAME", payload = "Kel" })

			-- Create a memoized selector to get the item count
			local selectItemCount = rootState:CreateSelector(function(state)
				return #state.inventory.items
			end) 

			print("Item count:", selectItemCount()) -- Prints: Item count: 2
			----------------------------------------------------------------------------
]]
