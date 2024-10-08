import Foundation

/// Performs a predefined asynchronous operation using dynamically created child tasks, sharing the same task between identical requests.
///
/// ## Examples
/// ### Loading data from the internet
/// The following code shows how to load data using URLSession without making multiple simultaneous requests for the same URL.
///
/// ```swift
/// let loader = SharedTaskExecutor { (url: URL) in
///		return try await URLSession.shared.data(from: url)
/// }
///
/// // make multiple simultaneous requests, some to the same URL
/// async let result1 = loader.performWithSharedTask(request: URL("https://example.com/some/resource")!)
/// async let result2 = loader.performWithSharedTask(request: URL("https://example.com/some/resource")!)
/// async let result3 = loader.performWithSharedTask(request: URL("https://example.com/a/different/thing")!)
///
/// // Even though we called it three times, the first two were for identical URLs, so only one request will be made to `/some/resource` and one to `/a/different/thing`. Both calls to `/some/resource` will return at the same time.
/// ```
///
/// ### Image loader with caching
/// The following code implements a basic image loader that batches requests to load the same image, and caches the decoded images so only one request is ever made per URL.
///
/// A 500 millisecond grace period means that if a request for a particular URL is cancelled and another request for the same image is made within 500 milliseconds, the load task will not be cancelled and the second request will pick up where the first left off. This is useful e.g. for loading images in a lazy stack where the user might scroll back and forth rapidly.
///
/// ```swift
/// let cache = NSCache<NSURL, UIImage>()
/// let loader = SharedTaskExecutor<URL, UIImage?>(gracePeriod: .milliseconds(500)) { url in
/// 	if let cachedImage = cache.object(forKey: url as NSURL) {
///			return cachedImage
/// 	} else {
/// 		let (data, httpResponse) = try await URLSession.shared.data(from: url)
/// 		guard let image = UIImage(data: data) else { return nil }
/// 		cache.setObject(image, forKey: url as NSURL)
/// 		return image
///		}
/// }
/// ```
///
///	- Tip: Alone, the executor does not hold the result of an operation after it has completed, which means that subsequent identical requests after the first ones finish will repeat the operation. It is recommended to do any caching you need within the operation body.
public actor SharedTaskExecutor<RequestParameters: Hashable & Sendable, ChildTaskResult: Sendable> {
	
	/// Holds the continuation for a task that is waiting for a result from the operation.
	private class Subscriber: Identifiable {
		let subscriptionID: UUID
		private var continuation: CheckedContinuation<ChildTaskResult, Error>?
		
		init(subscriptionID: UUID, continuation: CheckedContinuation<ChildTaskResult, Error>) {
			self.subscriptionID = subscriptionID
			self.continuation = continuation
		}
		
		func resume(returning value: ChildTaskResult) {
			continuation?.resume(returning: value)
			continuation = nil
		}
		
		func resume(throwing error: Error) {
			continuation?.resume(throwing: error)
			continuation = nil
		}
		
		deinit {
			continuation?.resume(throwing: CancellationError())
		}
	}
	
	/// The amount of time that the executor should wait before canceling an operation if all requesting tasks have been canceled.
	///
	/// If another identical request is made during this time, it will continue to use the same task rather than canceling it and starting a new one.
	///
	/// If `nil`, the operation will be immediately canceled if all requesting tasks are canceled.
	public var gracePeriod: Duration?
	
	private let operation: (RequestParameters) async throws -> ChildTaskResult
	private var inProgressTasks: [RequestParameters: Task<Void, Never>] = [:]
	private var subscribers: [RequestParameters: Array<Subscriber>] = [:]
	
	/// Creates an executor that runs the given operation using dynamically created child tasks when requested.
	/// - Parameters:
	///   - gracePeriod: Optional. The amount of time to wait before canceling an operation if all requesters cancel, allowing further requests to continue where it left off.
	///   - operation: An async throwing closure that takes a request, performs an asynchronous operation, and returns a result.
	public init(gracePeriod: Duration? = nil, operation: sending @escaping (RequestParameters) async throws -> ChildTaskResult) {
		self.operation = operation
		self.gracePeriod = gracePeriod
	}
	
	private func addSubscriberForRequest(_ request: RequestParameters, subscriber: Subscriber) {
		if subscribers[request] != nil {
			subscribers[request]!.append(subscriber)
		} else {
			subscribers[request] = [subscriber]
		}
	}
	
	/// Perform `operation` asynchronously using a Task. If multiple calls are made using the same request value, the executor will only use one Task and share the result with all callers that used the same request value.
	/// - Parameter request: The value to pass to the `operation` closure. Also used to avoid creating duplicate tasks for the same request value.
	/// - Returns: The result of `operation`
	/// - Throws: Any error thrown from `operation`
	public func performWithSharedTask(request: RequestParameters) async throws -> ChildTaskResult {
		let subscriptionID = UUID()
		return try await withTaskCancellationHandler {
			return try await withCheckedThrowingContinuation { continuation in
				let subscriber = Subscriber(subscriptionID: subscriptionID, continuation: continuation)
				addSubscriberForRequest(request, subscriber: consume subscriber)
				
				if let existingTask = inProgressTasks[request], !existingTask.isCancelled {
					// There is already a Task in progress for this request, so adding the susbscriber was all we needed to do.
					return
				} else {
					// Start a task to handle this request.
					let task = Task {
						defer {
							inProgressTasks.removeValue(forKey: request)
						}
						await performOperationForSubscribers(request: request)
					}
					inProgressTasks[request] = task
				}
			}
		} onCancel: {
			Task {
				await self.unsubscribe(subscriptionID, request: request)
			}
		}
	}
	
	/// Performs ``operation`` with the given argument and sends the result to all subscribers.
	private func performOperationForSubscribers(request: RequestParameters) async {
		do {
			let result = try await operation(request)
			// Broadcast result to subscribers
			guard let subscribersAwaitingResult = subscribers.removeValue(forKey: request) else { return }
			for subscriber in subscribersAwaitingResult {
				subscriber.resume(returning: result)
			}
		} catch {
			guard let subscribersAwaitingResult = subscribers.removeValue(forKey: request) else { return }
			for subscriber in subscribersAwaitingResult {
				subscriber.resume(throwing: error)
			}
		}
	}
	
	/// Remove the subscriber with the given subscription ID and cancel its task. If this was the last subscriber and ``gracePeriod`` is set, wait that long and only cancel the task if no more subscribers have subscribed during that time.
	private func unsubscribe(_ subscriptionID: UUID, request: RequestParameters) async {
		subscribers[request]?.removeAll(where: { $0.subscriptionID == subscriptionID })
		
		// If there are no more subscribers to this request, start the grace period
		if subscribers[request]?.isEmpty == true {
			do {
				// Wait to cancel the task being performed until the grace period is finished.
				if let gracePeriod {
					try await Task.sleep(for: gracePeriod)
				}
				
				// If there are still no more subscribers for this request, cancel the task
				if subscribers[request]?.isEmpty == true,
				   let ongoingTask = inProgressTasks.removeValue(forKey: request) {
					ongoingTask.cancel()
				}
			} catch {
				return
			}
		}
	}
}
