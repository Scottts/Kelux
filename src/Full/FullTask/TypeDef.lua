-- Annotations ---------------------------------------------------------------------------------------------
type Signal = {
	new: () -> Signal,
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
export type TaskOptions = {
	id: string?, -- A custom unique identifier for the task
	name: string?, -- A human-readable name for the task
	priority: number?, -- The priority level of the task (e.g., FullTask.Priority.NORMAL)
	maxRetries: number?, -- The maximum number of times to retry the task if it fails[Default: 0]
	timeout: number?, -- A timeout in seconds. If the task runs longer, it will be cancelled
	resources: {[string]: number}?, -- A table specifying the resources and amounts this task requires (e.g., { "HTTP_REQUESTS": 1 })
	dependencies: {string}?, -- A list of task IDs that must be completed before this task can run
	scheduledFor: number?, -- A future timestamp (from tick()) when the task should be scheduled to run
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
	state: string,-- The current state of the task (e.g., "PENDING", "RUNNING")
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

			<code>taskManager:UpdateTaskPriority(myTask.id, FullTask.Priority.CRITICAL)
		]]
		function(self: FullTask<T>, taskId: string, newPriority: number) end
	),
	CancelTask: typeof(
		--[[
			Cancels a task. [cite: 14, 15]
			If the task is "RUNNING", the 'force' parameter must be true
			to attempt to terminate its coroutine. 

			<code>taskManager:CancelTask(myTask.id)
			taskManager:CancelTask(runningTaskId, true) -- Force cancel
		]]
		function(self: FullTask<T>, taskId: string, force: boolean?) end
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
		function(self: FullTask<T>, taskIds: {string}, force: boolean?) end
	),
	CancelByPattern: typeof(
		--[[
			Cancels all tasks that match a predicate function or a glob pattern.
			Using a function cancels if the function returns true for a task object.
			For the string, it ancels if the task 'name' matches the glob pattern (e.g., "http:*").

			<code>-- Cancel by predicate
			taskManager:CancelByPattern(function(task)
				return task.priority == FullTask.Priority.LOW
			end)
			-- Cancel by glob pattern
			taskManager:CancelByPattern("user_data:*", true)
		]]
		function(self: FullTask<T>, patOrFn: string | ((task: Task) -> boolean), force: boolean?) end
	),
}
export type Static = {
	TaskState: TaskState,
	Priority: Priority,
	Create: typeof(
		--[[
			Creates a new task manager instance. 

			<code>local taskManager = FullTask.Create({
				name = "MyTaskManager",
				maxConcurrency = 20,
				resourceLimits = {
					["HTTP"] = 5
				}
			})
		]]
		function <T>(name: string?, maxConcurrency: number?, autoProcessInterval: number?, heapType: ("PairingHeap" | "FibonacciHeap")?, resourceLimits: {[string]: number}?): FullTask<T> end
	),
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
