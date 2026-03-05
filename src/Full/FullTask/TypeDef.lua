-- Annotations ---------------------------------------------------------------------------------------------
type Signal = {
	new: () -> Signal,
	Connect: (self: Signal, handler: (...any) -> ()) -> number,
	Once: (self: Signal, handler: (...any) -> ()) -> number,
	Disconnect: (self: Signal, id: number) -> (),
	Wait: (self: Signal) -> ...any,
	Fire: (self: Signal, ...any) -> (),
	DisconnectAll: (self: Signal) -> ()
}
export type TaskState = {
	PENDING: "PENDING",
	RUNNING: "RUNNING",
	COMPLETED: "COMPLETED",
	FAILED: "FAILED",
	CANCELLED: "CANCELLED",
	WAITING: "WAITING"
}
export type Priority = {
	LOW: number,
	NORMAL:number,
	HIGH: number,
	CRITICAL: number
}
export type TransactionContext = {
	Submit: typeof(
		--[[
			Stages a task submission inside the transaction.
			This does NOT submit immediately, it’s committed after <strong>transactionFn</strong> returns.

			Returns true (staged successfully).
		]]
		function(self: TransactionContext, taskFn: (ctx: TaskExecutionContext) -> ...any, options: TaskOptions?): true end
	),
	CancelTask: typeof(
		--[[
			Stages a cancel request inside the transaction.
			This does NOT cancel immediately, it’s committed after <strong>transactionFn</strong> returns.

			Returns true (staged successfully).
		]]
		function(self: TransactionContext, taskId: string, force: boolean?): true end
	),
	SetPriority: typeof(
		--[[
			Stages a priority change inside the transaction.
			This does NOT apply immediately, it’s committed after <strong>transactionFn</strong> returns.

			Returns true (staged successfully).
		]]
		function(self: TransactionContext, id: string, newPriority: number): true end
	),
	AddDependency: typeof(
		--[[
			Stages a dependency edge inside the transaction:
			<strong>taskId</strong> will wait on <strong>prerequisiteTaskId</strong>.

			This does NOT apply immediately, it’s committed after <strong>transactionFn</strong> returns.
			Returns true (staged successfully).
		]]
		function(self: TransactionContext, taskId: string, prerequisiteTaskId: string): true end
	),
	GetTask: typeof(
		--[[
			Reads a task by ID from the manager while the transaction lock is held.
			Returns the Task object or nil if it doesn't exist.
		]]
		function(self: TransactionContext, id: string): Task? end
	),
	GetTasks: typeof(
		--[[
			Reads tasks from the manager while the transaction lock is held.
			If <strong>status</strong> is provided, returns only tasks with that exact state.
			Returns a dictionary keyed by taskId.
		]]
		function(self: TransactionContext, status: TaskStateValue?): {[string]: Task} end
	),
	GetTaskDependencies: typeof(
		--[[
			Returns an array of dependency task IDs for the given task.
			Returns an empty array if the task doesn't exist or has no dependencies.
		]]
		function(self: TransactionContext, id: string): {string} end
	),
}
export type TaskStateValue = "PENDING" | "RUNNING" | "COMPLETED" | "FAILED" | "CANCELLED" | "WAITING"
export type ManagerOptions = {
	name: string?,
	maxConcurrency: number?,
	taskRateLimit: number?,
	maxLoadPerHeartbeat: number?,
	autoProcessInterval: number?,
	heapType: ("PairingHeap" | "FibonacciHeap")?,
	resourceLimits: {[string]: number}?,
}
export type TaskOptions = {
	id: string?, -- A custom unique identifier for the task
	name: string?, -- A human-readable name for the task
	priority: number?, -- The priority level of the task (e.g., FullTask.Priority.NORMAL)
	maxRetries: number?, -- The maximum number of times to retry the task if it fails[Default: 0]
	timeout: number?, -- A timeout in seconds. If the task runs longer, it will be cancelled
	resources: {[string]: number}?, -- A table specifying the resources and amounts this task requires (e.g., { "HTTP_REQUESTS": 1 })
	dependencies: ({string} | {[string]: true} | {[any]: string})?, -- array or map form (normalized internally)
	scheduledFor: number?, -- A future Unix timestamp (from os.time()) when the task should be scheduled to run
	cronExpression: string?, -- A cron expression for scheduling recurring tasks
	recurringCount: number?, -- The number of times a recurring task should run (nil for indefinitely)
	data: {[any]: any}?, -- A table for arbitrary user data associated with the task
}
export type Task = {
	id: string,-- The unique identifier of the task
	name: string,-- The human-readable name of the task
	fn: (ctx: TaskExecutionContext) -> ...any,-- The function to be executed
	priority: number,-- The task's priority level
	retries: number,-- The current number of retry attempts
	maxRetries: number,-- The maximum allowed retry attempts
	timeout: number?,-- The timeout duration in seconds
	resources: {[string]: number},-- The resources required by the task
	dependencies: {string},-- A list of task IDs this task depends on
	dependents: {string},-- A list of task IDs that depend on this task
	scheduledFor: number?,-- The timestamp when this task is scheduled to run
	cronExpression: string?,-- The cron expression for recurrence
	recurringCount: number?,-- The remaining number of times this recurring task will run
	state: TaskStateValue,-- The current state of the task (e.g., "PENDING", "RUNNING")
	cancellationRequested: boolean,-- Flag indicating if cancellation has been requested
	data: {[any]: any},-- Arbitrary user data
	thread: thread?,-- The coroutine executing the task
	submitTime: number,-- The timestamp when the task was submitted
	startTime: number?,-- The timestamp when the task started running
	endTime: number?,-- The timestamp when the task finished
	result: any?,-- The return value(s) of the task function if completed
	error: any?,-- The error message if the task failed
	isRecurring: boolean,-- Whether the task is recurring
	contentHash: string,-- A hash of the task's content for deduplication
	parsedCron: any?,-- The parsed cron expression object
}
export type TaskExecutionContext = Task & {
	wait: typeof(task.wait),
	spawn: typeof(task.spawn),
	defer: typeof(task.defer),
}
export type FullTaskSignals = {
	taskQueued: Signal,
	taskStarted: Signal,
	taskCompleted: Signal,
	taskFailed: Signal,
	taskCancelled: Signal,
	taskRetried: Signal,
	resourceAcquired: Signal,
	resourceReleased: Signal,
	queueEmpty: Signal,
	systemOverload: Signal,
}
export type FullTaskMetrics = {
	totalTasksSubmitted: number,
	tasksCompleted: number,
	tasksFailed: number,
	tasksCancelled: number,
	tasksRetried: number,
	tasksInQueue: number,
	currentConcurrency: number,
	totalExecutionTime: number,
	averageExecutionTime: number,
	uptime: number,
}
export type FullTaskSnapshot = {
	version: string,
	name: string,
	timestamp: number,
	config: {
		maxConcurrency: number,
		resourceLimits: {[string]: number},
	},
	tasks: {[string]: {
		id: string,
		name: string,
		state: "PENDING" | "WAITING",
		priority: number,
		retries: number,
		maxRetries: number,
		timeout: number?,
		resources: {[string]: number},
		dependencies: {string},
		scheduledFor: number?,
		cronExpression: string?,
		recurringCount: number?,
		data: {[any]: any},
		submitTime: number,
		contentHash: string,
		isRecurring: boolean,
	}},
}
export type FullTask<T> = {
	-- Public properties
	name: string, 
	maxConcurrency: number, 
	currentConcurrency: number, 
	signals: FullTaskSignals, 
	metrics: FullTaskMetrics, 
	tasks: {[string]: Task}, 
	-- Public methods
	Submit: typeof(
		--[[
			Submits a new task to the manager. 

			<code>local myTask = taskManager:Submit(function(ctx)
				print("Hello from task:", ctx.id)
				task.wait(1)
				return "Done"
			end, {
				name = "MyFirstTask",
				priority = FullTask.Priority.HIGH,
				maxRetries = 2
			})
		]]
		function(self: FullTask<T>,taskFn: (ctx: TaskExecutionContext) -> ...any,options: TaskOptions?): Task? end
	),
	UpdateTaskPriority: typeof(
		--[[
			Updates the priority of a pending task.
			Returns false if task doesn't exist.
			May return true in some internal paths; otherwise returns nil.
		]]
		function(self: FullTask<T>, taskId: string, newPriority: number): boolean? end
	),
	CancelTask: typeof(
		--[[
			Cancels a task. [cite: 14, 15]
			If the task is "RUNNING", the 'force' parameter must be true
			to attempt to terminate its coroutine. 

			<code>taskManager:CancelTask(myTask.id)
			taskManager:CancelTask(runningTaskId, true) -- Force cancel
		]]
		function(self: FullTask<T>, taskId: string, force: boolean?): boolean? end
	),
	Destroy: typeof(
		--[[
			Destroys the task manager instance. 
			Stops the main loop, cancels all running tasks,
			and disconnects all signals. [cite: 19, 20]

			<code>taskManager:Destroy()
		]]
		function(self: FullTask<T>) end
	),
	BulkCancel: typeof(
		--[[
			Cancels a list of tasks by their IDs.
			This is much more performant than calling CancelTask in a loop.
			
			<code>taskManager:BulkCancel({task1.id, task2.id}, true) -- Force cancel
		]]
		function(self: FullTask<T>, taskIds: {string}, force: boolean?): number end
	),
	CancelByPattern: typeof(
		--[[
			Cancels all tasks that match a predicate function or a glob pattern.
			Using a function cancels if the function returns true for a task object.
			For the string, it cancels if the task 'name' matches the glob pattern (e.g., "http:*").

			<code>-- Cancel by predicate
			taskManager:CancelByPattern(function(task)
				return task.priority == FullTask.Priority.LOW
			end)
			-- Cancel by glob pattern
			taskManager:CancelByPattern("user_data:*", true)
		]]
		function(self: FullTask<T>, patOrFn: string | ((task: Task) -> boolean), force: boolean?): number end
	),
	GetTask: typeof(
		--[[
			Returns the live Task object for the given ID, or nil if it doesn't exist.
			Returns nil if the manager is destroyed.
		]]
		function(self: FullTask<T>, id: string): Task? end
	),

	GetTasks: typeof(
		--[[
			Returns a dictionary of Task objects keyed by taskId.
			If <strong>status</strong> is provided, only tasks with that exact state are returned.
			Returns nil if the manager is destroyed.
		]]
		function(self: FullTask<T>, status: TaskStateValue?): {[string]: Task}? end
	),

	SetPriority: typeof(
		--[[
			Updates a task's priority (only valid while the task is PENDING or WAITING).
			Returns (true) on success, or (false, reason) on failure.
		]]
		function(self: FullTask<T>, id: string, newPriority: number): (boolean, string?) end
	),

	AbortTask: typeof(
		--[[
			Force-aborts a task and marks it CANCELLED.
			If the task is RUNNING, this attempts to stop its thread and release its resources.
			Returns (true) on success, or (false, reason) on failure.
		]]
		function(self: FullTask<T>, id: string): (boolean, string?) end
	),

	AddDependency: typeof(
		--[[
			Adds a dependency edge: <strong>taskId</strong> will wait on <strong>prerequisiteTaskId</strong>.
			Prevents cycles and validates task state (must be PENDING/WAITING).
			Returns (true) on success, or (false, reason) on failure.
		]]
		function(self: FullTask<T>, taskId: string, prerequisiteTaskId: string): (boolean, string?) end
	),

	Pause: typeof(
		--[[
			Pauses the scheduler (stops the main loop). Tasks won't start while paused.
			Returns (true) on success, or (false, reason) on failure.
	]]
		function(self: FullTask<T>): (boolean, string?) end
	),

	Resume: typeof(
		--[[
			Resumes the scheduler (restarts the main loop).
			Returns (true) on success, or (false, reason) on failure.
		]]
		function(self: FullTask<T>): (boolean, string?) end
	),

	GetTaskDependencies: typeof(
		--[[
			Returns an array of dependency task IDs for the given task.
			Note: if the task doesn't exist, this returns an empty array (not nil).
			Returns nil only if the manager is destroyed or an internal error occurs.
		]]
		function(self: FullTask<T>, id: string): {string}? end
	),

	Snapshot: typeof(
		--[[
			Captures a serializable snapshot of all non-finished tasks.
			RUNNING tasks are saved as PENDING so they can be resumed safely.
			Returns nil if the manager is destroyed or snapshotting fails.
		]]
		function(self: FullTask<T>): FullTaskSnapshot? end
	),

	Restore: typeof(
		--[[
			Restores tasks from a snapshot produced by <strong>Snapshot()</strong>.
			<strong>functionMap</strong> must be a non-empty map of function IDs -> runnable functions.
			Returns (true) on success, or (false, reason) on failure.
		]]
		function(self: FullTask<T>, snapshotData: FullTaskSnapshot, functionMap: {[string]: () -> ...any}): (boolean, string?) end
	),

	ToJSON: typeof(
		--[[
			Encodes <strong>Snapshot()</strong> to a JSON string via HttpService:JSONEncode.
			Returns nil if the manager is destroyed or encoding fails.
		]]
		function(self: FullTask<T>): string? end
	),

	FromJSON: typeof(
		--[[
			Decodes a snapshot JSON string via HttpService:JSONDecode, then calls <strong>Restore</strong>.
			<strong>functionMap</strong> must be a non-empty map of function IDs -> runnable functions.
			Returns (true) on success, or (false, reason) on failure.
		]]
		function(self: FullTask<T>, jsonString: string, functionMap: {[string]: () -> ...any}): (boolean, string?) end
	),

	Transaction: typeof(
		--[[
			Runs a transactional batch against a lightweight tx context.
			If the transaction function errors or any committed action fails, the transaction errors.
			Returns all values returned by <strong>transactionFn</strong>.
		]]
		function(self: FullTask<T>, transactionFn: (tx: TransactionContext) -> ...any): ...any end
	),
}
export type Static = {
	TaskState: TaskState,
	Priority: Priority,
	Version: string,
	Registry: {[string]: FullTask<any>},
	Create: typeof(function <T>(
		NameOrConfig: string | ManagerOptions?,
		Options: ManagerOptions?
	): FullTask<T> end),
}
------------------------------------------------------------------------------------------------------------
export type Master = {
	TaskState: TaskState,
	Priority: Priority,
	TaskOptions: TaskOptions,
	Task: Task,
	TaskExecutionContext: TaskExecutionContext,
	FullTaskSignals: FullTaskSignals,
	FullTaskMetrics: FullTaskMetrics,
	FullTaskSnapshot: FullTaskSnapshot,
	FullTask: FullTask,
	Static: Static,
}
local TypeDef = {}
return TypeDef :: Master