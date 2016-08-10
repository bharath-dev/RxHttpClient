import Foundation
import RxSwift
import RxCocoa

public protocol StreamTaskType {
	/// Identifier of a task.
	var uid: String { get }
	/// Resumes task.
	func resume()
	/// Cancels task.
	func cancel()
	/// Is task resumed.
	var resumed: Bool { get }
}

public protocol StreamDataTaskType : StreamTaskType {
	/// Observable sequence, that emits events associated with underlying data task.
	var taskProgress: Observable<StreamTaskEvents> { get }
	/// Instance of cache provider, associated with this task.
	var cacheProvider: CacheProviderType? { get }
}

/**
Represents the events that will be sended to observers of StreamDataTask
*/
public enum StreamTaskEvents {
	/// This event will be sended after receiving (and cacnhing) new chunk of data. 
	/// This event will be sended only if CacheProvider was specified.
	case CacheData(CacheProviderType)
	/// This event will be sended after receiving new chunk of data.
	/// This event will be sended only if CacheProvider was not specified.
	case ReceiveData(NSData)
	// This event will be sended after receiving response.
	case ReceiveResponse(NSURLResponse)
	/**
	This event will be sended if underlying task was completed with error.
	This event will be sended if unerlying NSURLSession invoked delegate method URLSession:task:didCompleteWithError: with specified error.
	*/
	case Error(ErrorType)
	/// This event will be sended after completion of underlying data task.
	case Success(cache: CacheProviderType?)
}

internal final class StreamDataTask {
	let uid: String
	var resumed = false
	var cacheProvider: CacheProviderType?

	let queue = dispatch_queue_create("com.RxHttpClient.StreamDataTask.Serial", DISPATCH_QUEUE_SERIAL)
	var response: NSURLResponse?
	let scheduler = SerialDispatchQueueScheduler(globalConcurrentQueueQOS: DispatchQueueSchedulerQOS.Utility)
	let dataTask: NSURLSessionDataTaskType
	let sessionEvents: Observable<SessionDataEvents>

	init(taskUid: String, dataTask: NSURLSessionDataTaskType, sessionEvents: Observable<SessionDataEvents>,
	            cacheProvider: CacheProviderType?) {
		self.dataTask = dataTask
		self.sessionEvents = sessionEvents
		self.cacheProvider = cacheProvider
		uid = taskUid
	}
	
	lazy var taskProgress: Observable<StreamTaskEvents> = {
		return Observable.create { [weak self] observer in
			guard let object = self else { observer.onCompleted(); return NopDisposable.instance }
			
			let disposable = object.sessionEvents.observeOn(object.scheduler).bindNext { e in
					switch e {
					case .didReceiveResponse(_, let task, let response, let completionHandler):
						guard task.isEqual(object.dataTask as? AnyObject) else { return }
						
						completionHandler(.Allow)
						
						object.response = response
						object.cacheProvider?.expectedDataLength = response.expectedContentLength
						object.cacheProvider?.setContentMimeTypeIfEmpty(response.MIMEType ?? "")
						observer.onNext(StreamTaskEvents.ReceiveResponse(response))
					case .didReceiveData(_, let task, let data):
						guard task.isEqual(object.dataTask as? AnyObject) else { return }
						
						if let cacheProvider = object.cacheProvider {
							cacheProvider.appendData(data)
							observer.onNext(StreamTaskEvents.CacheData(cacheProvider))
						} else {
							observer.onNext(StreamTaskEvents.ReceiveData(data))
						}
					case .didCompleteWithError(let session, let task, let error):
						guard task.isEqual(object.dataTask as? AnyObject) else { return }
						
						object.resumed = false
						
						if let error = error {
							observer.onNext(StreamTaskEvents.Error(error))
						} else {
							observer.onNext(StreamTaskEvents.Success(cache: object.cacheProvider))
						}

						observer.onCompleted()
					case .didBecomeInvalidWithError(_, let error):
						object.resumed = false
						// dealing with session invalidation
						guard let error = error else {
							// if error is nil, session was invalidated explicitly
							observer.onNext(StreamTaskEvents.Error(HttpClientError.SessionExplicitlyInvalidated))
							return
						}
						// otherwise sending error that caused invalidation
						observer.onNext(StreamTaskEvents.Error(HttpClientError.SessionInvalidatedWithError(error: error)))
					}
			}
			
			return AnonymousDisposable {
				disposable.dispose()
			}
		}.shareReplay(0)
	}()
}

extension StreamDataTask : StreamDataTaskType {
	func resume() {
		dispatch_sync(queue) {
			if !self.resumed { self.resumed = true; self.dataTask.resume(); }
		}
	}
		
	func cancel() {
		resumed = false
		dataTask.cancel()
	}
}