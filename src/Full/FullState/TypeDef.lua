-- Annotations ---------------------------------------------------------------------------------------------
export type Action = {
	type: string,
	payload: any?
}
export type Middleware<S> = (store: FullState<S>, action: Action, next: () -> ()) -> ()
export type Reducer<S> = (state: S, action: Action) -> S
export type Selector<S, R> = (state: S) -> R
export type CreateOptions = {
	deduplication: {
		enabled: boolean,
		maxSize: number?,
		maxAge: number?,
	}?
}
export type Listener<S> = (newState: S, oldState: S, action: Action, stateHash: string) -> ()
export type ErrorCallback = (method: string, err: string, ...any) -> ()
export type StateSnapshot<S> = {
	state: S,
	history: {{key: number, value: string}},
	historyIndex: number,
	actionAuditLog: {string},
	lastAuditRoot: string?,
}
export type FullState<S> = {
	-- Lifecycle
	Destroy: typeof(
		--[[
			Completely removes and cleans up the state instance.
			Stops all background processes and releases memory.
			The state manager cannot be used after being destroyed.

			<code>state:Destroy()
			</code>
		]]
		function(self: FullState<S>) end
	),
	ReadOnly: typeof(
		--[[
			Enables or disables read-only mode.
			When read-only, all dispatches (Dispatch, Batch, Transaction) will be ignored.

			<code>state:ReadOnly(true) -- Blocks all dispatches
			state:Dispatch({ type = "INCREMENT" }) -- This will be ignored
			state:ReadOnly(false) -- Re-enables dispatches
			</code>
		]]
		function(self: FullState<S>, state: boolean) end
	),
	CreateSlice: typeof(
		--[[
			Creates a "slice" view into a part of the state.
			Dispatches from the slice will have their action types
			automatically prefixed (e.g., "user/SET_NAME").
			GetState() on a slice returns only its sub-state.

			<code>-- Assuming state is { user: { name: "A" } }
			local userSlice = state:CreateSlice("user")
			local userName = userSlice:GetState().name -- "A"
			userSlice:Dispatch({ type = "SET_NAME", payload = "B" }) -- Dispatches "user/SET_NAME"
			</code>
		]]
		function(self: FullState<S>, slicePath: string): FullState<any> end
	),
	-- State Access
	GetState: typeof(
		--[[
			Returns a deep, frozen (read-only) copy of the current state.

			<code>local currentState = state:GetState()
			print(currentState.counter)
			</code>
		]]
		function(self: FullState<S>): S end
	),
	GetStateHash: typeof(
		--[[
			Returns a fast 32-bit hash (xxHash) of the current state.
			This is useful for quick memoization checks.

			<code>local hash = state:GetStateHash()
			if hash ~= lastHash then
				-- state has changed
			end
			</code>
		]]
		function(self: FullState<S>): string end
	),
	-- Actions
	Dispatch: typeof(
		--[[
			Dispatches an action. This is the primary way to update the state.
			The action flows through middleware, then the reducer,
			and finally notifies all listeners.
			Also accepts a function (thunk) for async logic.

			<code>-- Simple action
			state:Dispatch({ type = "INCREMENT", payload = 1 })

			-- Thunk action
			state:Dispatch(function(dispatch, getState)
				if getState().counter < 10 then
					dispatch({ type = "INCREMENT" })
				end
			end)
			</code>
		]]
		function(self: FullState<S>, action: Action | (dispatch: (Action) -> (), getState: () -> S) -> ()) end
	),
	Batch: typeof(
		--[[
			Batches multiple dispatches into a single "OnChanged" notification.
			Listeners will only be notified once after the callback function completes.

			<code>state:Batch(function()
				state:Dispatch({ type = "INCREMENT" })
				state:Dispatch({ type = "INCREMENT" })
			end)
			-- OnChanged fires only once here
			</code>
		]]
		function(self: FullState<S>, callback: () -> ()) end
	),
	-- Subscriptions
	OnDispatch: typeof(
		--[[
			Connects a listener that fires <strong>before</strong> an action is processed by middleware.
			Returns a disconnect function.

			<code>local disconnect = state:OnDispatch(function(action)
				print("Action Dispatched:", action.type)
			end)
			
			disconnect() -- Stop listening
			</code>
		]]
		function(self: FullState<S>, listener: (action: Action) -> ()): number end
	),
	OnCommit: typeof(
		--[[
			Connects a listener that fires <strong>after</strong> the reducer has run,
			but <strong>before</strong> the state is frozen and OnChanged listeners are notified.
			Returns a disconnect function.

			<code>local disconnect = state:OnCommit(function(newState, oldState, action)
				print("State is about to change from", oldState.counter, "to", newState.counter)
			end)
			</code>
		]]
		function(self: FullState<S>, listener: (newState: S, oldState: S, action: Action) -> ()): number end
	),
	OnChanged: typeof(
		--[[
			Connects a listener that fires <strong>after</strong> a dispatch has successfully
			completed and the state has changed.
			Returns a disconnect function.

			<code>local disconnect = state:OnChanged(function(newState, oldState, action)
				print("State changed due to:", action.type)
			end)

			-- To stop listening:
			disconnect()
			</code>
		]]
		function(self: FullState<S>, listener: Listener<S>): number end
	),
	OnError: typeof(
		--[[
			Connects a listener that fires when an error occurs
			inside a dispatch, transaction, or other method.
			Returns a disconnect function.

			<code>local disconnect = state:OnError(function(methodName, errorMessage)
				warn("FullState Error in", methodName, ":", errorMessage)
			end)
			</code>
		]]
		function(self: FullState<S>, listener: ErrorCallback): number end
	),
	SubscribeToPath: typeof(
		--[[
			Subscribes to changes on a specific, deep path within the state.
			The listener will <strong>only</strong> fire if the value at that exact path
			(e.g., "user.settings.theme") changes.

			<code>-- Assuming state is { user: { settings: { theme: "light" } } }
			local disconnect = state:SubscribeToPath("user.settings.theme", function(newTheme, oldTheme)
				print("Theme changed from", oldTheme, "to", newTheme)
			end)

			state:Dispatch({ type = "SET_THEME" }) -- (Assuming reducer changes the theme)
			-- Listener fires: "Theme changed from light to dark"
			</code>
		]]
		function(self: FullState<S>, path: string, listener: (newValue: any, oldValue: any) -> (), options: {equalityFn: ((any, any) -> boolean)?}?): (() -> ()) end
	),
	Disconnect: typeof(
		--[[
			Disconnects a listener using the connection ID number
			returned from an 'On...' or 'SubscribeToPath' method.

			<code>local id = state:OnChanged(myListener)
			-- Some stuff happens...
			state:Disconnect(id)
			</code>
		]]
		function(self: FullState<S>, connectionId: number) end
	),
	ClearListeners: typeof(
		--[[
			Removes all listeners connected to the 'OnChanged' signal.
			This is primarily useful for cleanup in test environments.

			<code>state:ClearListeners()
			</code>
		]]
		function(self: FullState<S>) end
	),
	WaitForChange: typeof(
		--[[
			Yields the current thread until the state changes, returning a (value, error) tuple.
			This function <strong>must</strong> be called from a coroutine (e.g., using task.spawn).

			An optional selector function can be provided. If it is,
			this function will only resume when the <strong>result</strong> of the
			selector is different from its value when the
			function was first called.

			An optional timeout (in seconds) will cause the
			function to resume with (nil, "timeout") if no
			change is detected.

			<code>task.spawn(function()
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
			</code>
		]]
		function<R>(self: FullState<S>, selectorFn: (state: S) -> R?, timeout: number?): (R?, string?) end
	),
	-- Selectors
	CreateSelector: typeof(
		--[[
			Creates a memoized selector function. The selector
			will only re-compute its value if the state hash has changed <strong>and</strong>
			the selected value is different from the last computed value.

			<code>-- Create a selector that only returns the user's name
			local selectName = state:CreateSelector(function(s) return s.user.name end)

			-- Use it like a function
			print(selectName()) -- "Initial"
			</code>
		]]
		function<R>(self: FullState<S>, selectorFn: (state: S) -> R, equalityFn: ((a: R, b: R) -> boolean)?): (() -> R) end
	),
	-- Time Travel
	Undo: typeof(
		--[[
			Reverts the state to the previous point in history (time travel).
			Fires OnChanged with an "@@UNDO" action.

			<code>state:Dispatch({ type = "INCREMENT" }) -- State is 1
			state:Undo()
			print(state:GetState().counter) -- 0
			</code>
		]]
		function(self: FullState<S>) end
	),
	Redo: typeof(
		--[[
			Re-applies a previously undone action (time travel).
			Fires OnChanged with an "@@REDO" action.

			<code>state:Dispatch({ type = "INCREMENT" }) -- State is 1
			state:Undo() -- State is 0
			state:Redo()
			print(state:GetState().counter) -- 1
			</code>
		]]
		function(self: FullState<S>) end
	),
	-- Persistence & Auditing
	GetStateHistoryRange: typeof(
		--[[
			Retrieves a range of state snapshots from the B+ Tree history.
			The states are decompressed and returned.

			<code>-- Get history entries 2, 3, and 4
			local history = state:GetStateHistoryRange(2, 4)
			for _, entry in ipairs(history) do
				print("History", entry.key, entry.state.counter)
			end
			</code>
		]]
		function(self: FullState<S>, startIndex: number, endIndex: number): {{key: number, state: S}} end
	),
	Snapshot: typeof(
		--[[
			Creates a serializable snapshot of the entire state manager,
			including the current state, history, and audit logs.

			<code>local snap = state:Snapshot()
			-- 'snap' can now be saved to a DataStore
			</code>
		]]
		function(self: FullState<S>): StateSnapshot<S> end
	),
	Restore: typeof(
		--[[
			Restores the state manager from a previously created snapshot.
			This will overwrite the current state and history.

			<code>-- 'snap' is loaded from a DataStore
			state:Restore(snap)
			</code>
		]]
		function(self: FullState<S>, snapshot: StateSnapshot<S>) end
	),
	ToJSON: typeof(
		--[[
			Serializes the result of Snapshot() into a JSON string.

			<code>local jsonState = state:ToJSON()
			-- 'jsonState' can be saved or sent over the network
			</code>
		]]
		function(self: FullState<S>): string end
	),
	FromJSON: typeof(
		--[[
			Restores the state manager from a JSON string.
			This is a convenience wrapper for Restore(JSONDecode(jsonString)).

			<code>state:FromJSON(jsonState)
			</code>
		]]
		function(self: FullState<S>, jsonString: string) end
	),
	BuildAuditTree: typeof(
		--[[
			Builds a Merkle Tree from the internal action audit log
			and clears the log. Returns the root hash of the tree.
			This is for high-security auditing.

			<code>local rootHash = state:BuildAuditTree()
			</code>
		]]
		function(self: FullState<S>): string? end
	),
	GetAuditRoot: typeof(
		--[[
			Gets the root hash of the <strong>last</strong> built Merkle Tree,
			without building a new one.

			<code>local lastRoot = state:GetAuditRoot()
			</code>
		]]
		function(self: FullState<S>): string? end
	),
	-- Introspection
	GetActionHistory: typeof(
		--[[
			Returns a deep copy of the recent action history,
			including timestamps and execution time.

			<code>local actions = state:GetActionHistory()
			for _, record in ipairs(actions) do
				print(record.action.type, record.timestamp)
			end
			</code>
		]]
		function(self: FullState<S>): {Action} end
	),
	GetMetrics: typeof(
		--[[
			Returns a table of performance and usage metrics,
			such as dispatch count, history size, etc.

			<code>local metrics = state:GetMetrics()
			print("Total Dispatches:", metrics.dispatchCount)
			</code>
		]]
		function(self: FullState<S>): {[string]: any} end
	),
	-- Management
	Transaction: typeof(
		--[[
			Executes multiple dispatches in an atomic block.
			If the function errors, all changes are rolled back.
			If it succeeds, all changes are applied as a single
			"@@TRANSACTION" action, firing OnChanged only once.

			<code>local ok, err = state:Transaction(function(txStore)
				txStore:Dispatch({ type = "DECREMENT_A" })
				txStore:Dispatch({ type = "INCREMENT_B" })
				if txStore:GetState().a < 0 then
					error("Insufficient funds") -- This will roll back
				end
			end)
			</code>
		]]
		function(self: FullState<S>, transactionFn: (txStore: FullState<S>) -> any): (boolean, any?) end
	),
	Reset: typeof(
		--[[
			Resets the state manager to an initial state.
			If no argument is given, resets to the <strong>original</strong> initial state.
			If 'nil' is passed, the state will be reset to nil.
			This clears all history and audit logs.

			<code>-- Reset to the state it was created with
			state:Reset()

			-- Reset to a brand new state
			state:Reset({ counter = 100 })
			
			-- Reset state to nil
			state:Reset(nil)
			</code>
		]]
		function(self: FullState<S>, ...:any) end
	),
	-- Middleware
	use: typeof(
		--[[
			Applies a middleware to the state's dispatch chain.
			Middleware wraps the dispatch function, allowing you
			to intercept, modify, or delay actions.

			<code>-- A simple logger middleware
			local logger = function(store, action, next)
				print("Action:", action.type)
				next() -- Call the next middleware or the reducer
				print("State updated")
			end
			state:use(logger)
			</code>
		]]
		function(self: FullState<S>, middleware: Middleware<S>): FullState<S> end
	),
}
export type Static = {
	Create: typeof(
		--[[
			Creates a new named state manager or returns an existing one
			if the name is already in use.

			<code>local initialState = { counter = 0 }
			local function reducer(state, action)
				if action.type == "INCREMENT" then state.counter += 1 end
				return state
			end
			
			local state = FullState.Create("MyState", initialState, reducer)
			</code>
		]]
		function <S>(StateName: string, initialState: S, reducer: Reducer<S>?, options: CreateOptions?): FullState<S> end
	),
	combineReducers: typeof(
		--[[
			Combines a table of reducer functions into a single root reducer.
			Each key in the table corresponds to a key in the state.
			This combined reducer will call each child reducer, passing it
			its own slice of the state.

			<code>-- userReducer handles state.user, inventoryReducer handles state.inventory
			local rootReducer = FullState.combineReducers({
				user = userReducer,
				inventory = inventoryReducer
			})
			-- The resulting state will be: { user = ..., inventory = ... }
			</code>
		]]
		function(reducers: {[string]: Reducer<any>}): Reducer<any> end
	),
	middleware: {
		logger: typeof(
			--[[
				Returns a simple logger middleware that prints action types
				before and after they are processed.

				<code>state:use(FullState.middleware.logger())
				</code>
			]]
			function(): Middleware<any> end
		),
		thunk: typeof(
			--[[
				Returns a thunk middleware that allows dispatching functions
				for asynchronous logic.

				<code>state:use(FullState.middleware.thunk())
				state:Dispatch(function(dispatch, getState)
					-- async logic...
				end)
				</code>
			]]
			function(): Middleware<any> end
		),
		performance: typeof(
			--[[
				Returns a performance middleware that warns if a dispatch
				takes longer than a given threshold (default 16ms).

				<code>-- Warn for actions taking longer than 30ms
				state:use(FullState.middleware.performance(0.03))
				</code>
			]]
			function(threshold: number?): Middleware<any> end
		),
		validator: typeof(
			--[[
				Returns a middleware that validates action payloads against
				a simple schema table. If validation fails, the action is
				blocked and an error is thrown.

				<code>local schema = { SET_NAME = "string", SET_AGE = "number" }
				state:use(FullState.middleware.validator(schema))
				</code>
			]]
			function(schema: {[string]: string}): Middleware<any> end
		)
	}
}
------------------------------------------------------------------------------------------------------------
export type Master = {
	Action: Action,
	Middleware: Middleware,
	Reducer: Reducer,
	Selector: Selector,
	CreateOptions: CreateOptions,
	Listener: Listener,
	ErrorCallback: ErrorCallback,
	StateSnapshot: StateSnapshot,
	FullState: FullState,
	Static: Static,
}
local TypeDef = {}
return TypeDef :: Master
