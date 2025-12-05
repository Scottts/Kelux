--[[
	[ FULLTASK DOCUMENTATION ]
	Version: 0.1.383 (STABLE)

	Author: Kel (@GudEveningBois)

	1. Introduction
		FullTask is a task management and scheduling module designed for efficient execution of tasks within Roblox games. 
		It provides advanced features for task dependencies, priority scheduling, concurrency control, and resource management.
		With FullTask, developers can manage complex task flows, handle retries, manage timeouts, and schedule recurring tasks.
		If you discover bugs, don't ask me--ask God, for I do not know what happens.
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
			config (table) [Required]
			A table of configuration options for the task manager.
			Options Table (config):
			name (string) [Optional]
				The name for your task manager instance. Defaults to a GUID.
			maxConcurrency (number) [Optional]
				The maximum number of concurrent tasks to run.
			Defaults to 10.
			autoProcessInterval (number) [Optional]
				The interval in seconds to automatically process the task queue. Defaults to 0.1 seconds.
			heapType (string) [Optional]
				Specify the type of heap for task priority. Options: "PairingHeap", "FibonacciHeap". Defaults to "PairingHeap".
			resourceLimits (table) [Optional]
				A table specifying the resource limits for tasks.
			Example: {["HTTP"] = 5} will limit tasks to 5 HTTP requests.
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

		Resource Management:
			AcquireResources(task)
			Attempts to acquire the resources required by the task.
			Returns true if successful.

			ReleaseResources(task)
			Releases the resources held by the task after it completes.
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
			
	5. Practical Examples

		Example 1: Simple Task Submission
			----------------------------------------------------------------------------
			local taskManager = FullTask.Create({
				name = "MyTaskManager",
				maxConcurrency = 5
			})

			local function myTaskFn(ctx)
				print("Task started:", ctx.id)
				task.wait(2)
				return "Task completed"
			end

			local task = taskManager:Submit(myTaskFn, { name = "Task 1", priority = FullTask.Priority.HIGH })
			----------------------------------------------------------------------------

		Example 2: Task Dependencies
			---------------------------------------------------------------------------- 
			local function taskA(ctx)
				print("Executing Task A")
				task.wait(1)
				return "A completed"
			end

			local function taskB(ctx)
				print("Executing Task B")
				task.wait(1)
				return "B completed"
			end

			local taskManager = FullTask.Create({ name = "TaskManager" })

			local taskA = taskManager:Submit(taskA, { name = "Task A" })
			local taskB = taskManager:Submit(taskB, { name = "Task B", dependencies = {taskA.id} })
			----------------------------------------------------------------------------

		Example 3: Cancelling a Task
			---------------------------------------------------------------------------- 
			local taskManager = FullTask.Create({ name = "TaskManager" })
			local function longTask(ctx)
				print("Long task started")
				task.wait(10)
				return "Long task completed"
			end

			local task = taskManager:Submit(longTask, { name = "LongTask" })
			taskManager:CancelTask(task.id)
			----------------------------------------------------------------------------
]]
