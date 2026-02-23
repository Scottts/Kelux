--[[
	[ FULLTASK DOCUMENTATION ]
	Version: 1.38.5 (STABLE)

	Author: Kel (@GudEveningBois)

	1. Introduction
		FullTask is a task management and scheduling module designed for efficient execution of tasks within Roblox games. 
		It provides advanced features for task dependencies, priority scheduling, concurrency control, and resource management.
		With FullTask, developers can manage complex task flows, handle retries, manage timeouts, and schedule recurring tasks.

		Key Features:

			Concurrency Control: 
				FullTask allows you to manage a defined level of concurrent task execution, ensuring optimal resource usage.
			Advanced Scheduling: 
				Supports scheduled tasks, cron expressions for recurring tasks, and resource-based task execution.
			Dependency Management: 
				Define dependencies between tasks to ensure proper task execution order.
			Task State Management: 
				Track task states like PENDING, RUNNING, COMPLETED, FAILED, CANCELLED, and WAITING.
			Retry Mechanism: 
				Tasks can be retried up to a maximum number of attempts if they fail.
			Timeouts: 
				Set timeouts for tasks. If a task runs longer than the defined timeout, it will be automatically cancelled.
			Resource Management: 
				Tasks can request specific resources, which will be managed to avoid conflicts and ensure task completion.
			Event-Driven Signals: 
				Subscribe to task events like taskQueued, taskStarted, taskCompleted, taskFailed, etc.
			Task Metrics: 
				Track task execution performance with detailed metrics like tasks completed, failed, retried, and more.

	2. Getting Started
		To begin using FullTask, you first need to create a task manager instance.

			FullTask.Create(config)
				This function creates a new task manager instance with the provided configuration.

				Parameters:
					NameOrConfig (string | table) [Optional]
						Can be a string representing the name of the task manager, or the config table. Defaults to a generated GUID.
					Options (table) [Optional]
						Configuration options for the task manager.

						Scheduling Options:
							scheduledFor (number) [Optional]
								A Unix timestamp (os.time()) specifying exactly when the task should first run.
							cronExpression (string) [Optional]
								A standard cron string (e.g., "* * * * *") to schedule recurring tasks automatically.
							recurringCount (number) [Optional]
								The maximum number of times a cron-scheduled task should run before discontinuing.

				Options Table:
					maxConcurrency (number) [Optional]
						The maximum number of concurrent tasks. Defaults to 10.
					taskRateLimit (number) [Optional]
						Maximum tasks to process from the queue per heartbeat. Defaults to 50.
					maxLoadPerHeartbeat (number) [Optional]
						Maximum execution time (in seconds) allowed per frame before yielding. Defaults to 0.005.
					autoProcessInterval (number) [Optional]
						Interval in seconds to automatically process the task queue. Defaults to 0.1.
					heapType (string) [Optional]
						Priority heap type: "PairingHeap" or "FibonacciHeap". Defaults to "PairingHeap".
					resourceLimits (table) [Optional]
						Table specifying resource limits. Example: {["HTTP"] = 5}.

				Example:
					----------------------------------------------------------------------------
					local FullTask = require(the.path.to.FullTask)
					-- Create a task manager with a max of 20 concurrent tasks
					local taskManager = FullTask.Create({
						name = "MyTaskManager",
						maxConcurrency = 20,
						resourceLimits = {["HTTP"] = 5}
					})
					----------------------------------------------------------------------------

	3. Core Concepts

		Task Lifecycle:
			Tasks can have the following states:
			- PENDING: The task is waiting to be executed.
			- RUNNING: The task is currently being executed.
			- COMPLETED: The task has successfully completed.
			- FAILED: The task failed during execution.
			- CANCELLED: The task was cancelled manually.
			- WAITING: The task is waiting for its dependencies to complete before execution.

		Dependencies:
			Tasks can depend on other tasks.
			A task will only run if all of its dependencies are completed.
			Concurrency:
			FullTask allows you to manage the number of tasks running concurrently.
			If the number of running tasks exceeds the maximum concurrency, tasks will be queued.
			Resources:
			Tasks may require resources (e.g., HTTP requests). FullTask manages resource allocation to prevent conflicts and ensure task completion.

	4. API Reference

		Creation:

			FullTask.Create(config)
				Creates a new task manager instance. See Getting Started for configuration options.
			
			Task Management:

				Submit(taskFn, options)
					Submits a new task to the task manager. The task function will be executed asynchronously.
					Options include task name, priority, max retries, timeout, etc.

				CancelTask(taskId, force)
					Cancels a running or pending task.
					If the task is running and 'force' is true, it will attempt to terminate the task.
					UpdateTaskPriority(taskId, newPriority)
					Updates the priority of a pending task.

				Destroy()
					Stops the task manager, cancels all running tasks, and releases resources.
					Task State Management:
					GetTask(id)
					Retrieves a task by its ID.

				GetTasks(status)
					Returns a table of tasks in a specific state (e.g., "PENDING", "RUNNING").
					AbortTask(id)
					Aborts a task, regardless of its state (PENDING, RUNNING, etc.).

			Task Execution Context (ctx):
				When a task function runs, it is passed a context table ('ctx'). 
				You should use the context's threading functions instead of the global 'task' 
				library to ensure the scheduler accurately tracks execution state:
					- ctx.wait(duration)
					- ctx.spawn(fn, ...)
					- ctx.defer(fn, ...)

		Resource Management:

			Signals:
				taskQueued: Fired when a task is added to the queue.
				taskStarted: Fired when a task starts executing.
				taskCompleted: Fired when a task completes.
				taskFailed: Fired when a task fails.
				taskCancelled: Fired when a task is cancelled.
				resourceAcquired: Fired when a resource is acquired for a task.
				resourceReleased: Fired when a resource is released after task completion.

			Metrics:
				totalTasksSubmitted: The total number of tasks submitted.
				tasksCompleted: The total number of completed tasks.
				tasksFailed: The total number of failed tasks.
				tasksCancelled: The total number of cancelled tasks.
				tasksRetried: The total number of tasks that were retried.
				tasksInQueue: The number of tasks in the queue waiting to run.
				currentConcurrency: The number of tasks currently running concurrently.
				totalExecutionTime: The total time spent executing tasks.
				averageExecutionTime: The average time spent executing tasks.
				uptime: The uptime of the task manager.

		Advanced Task Management:

			SetPriority(taskId, newPriority)
				Updates the priority of a task that is PENDING or WAITING.
			AddDependency(taskId, prerequisiteTaskId)
				Dynamically makes `taskId` wait for `prerequisiteTaskId` to complete before running.
			BulkCancel(taskIds, force)
				Accepts an array of task IDs and cancels all of them. Returns the number of successfully cancelled tasks.
			CancelByPattern(patOrFn, force)
				Cancels tasks matching a string pattern (supports globbing like "Task*") or a filter function.

		State & Flow Control:
		
			Pause() / Resume()
				Pauses or resumes the entire task scheduler's processing loop.
			Snapshot()
				Returns a serialized JSON-friendly table containing the state of all non-completed tasks and configs.
			Restore(snapshotData, functionMap)
				Restores the task manager's state from a snapshot. Requires a `functionMap` table to re-link task IDs/names to their Luau functions.
			ToJSON() / FromJSON(jsonString, functionMap)
				Helper methods to stringify or decode snapshots directly to/from JSON.
			Transaction(transactionFn)
				Executes multiple submissions, cancellations, or dependency additions in an all-or-nothing block. If one fails, the entire transaction is rolled back.
					
	5. Practical Examples

		Example 1: Simple Task Submission
			----------------------------------------------------------------------------
			local taskManager = FullTask.Create({
				name = "MyTaskManager",
				maxConcurrency = 5
			})

			local function myTaskFn(ctx)
				print("Task started:", ctx.id)
				ctx.wait(2)
				return "Task completed"
			end

			local task = taskManager:Submit(myTaskFn, { name = "Task 1", priority = FullTask.Priority.HIGH })
			----------------------------------------------------------------------------

		Example 2: Task Dependencies
			---------------------------------------------------------------------------- 
			local function taskFnA(ctx)
				print("Executing Task A")
				ctx.wait(1)
				return "A completed"
			end

			local function taskFnB(ctx)
				print("Executing Task B")
				ctx.wait(1)
				return "B completed"
			end

			local taskManager = FullTask.Create({ name = "TaskManager" })

			local taskA = taskManager:Submit(taskFnA, { name = "Task A" })
			local taskB = taskManager:Submit(taskFnB, { name = "Task B", dependencies = {taskA.id} })
			----------------------------------------------------------------------------

		Example 3: Cancelling a Task
			---------------------------------------------------------------------------- 
			local taskManager = FullTask.Create({ name = "TaskManager" })
			local function longTask(ctx)
				print("Long task started")
				ctx.wait(10)
				return "Long task completed"
			end

			local task = taskManager:Submit(longTask, { name = "LongTask" })
			taskManager:CancelTask(task.id)
			----------------------------------------------------------------------------
]]
