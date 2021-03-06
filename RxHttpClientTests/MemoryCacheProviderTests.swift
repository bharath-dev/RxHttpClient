import XCTest
import RxSwift
@testable import RxHttpClient

class MemoryCacheProviderTests: XCTestCase {
	var bag: DisposeBag!
	var request: URLRequest = URLRequest(url: URL(baseUrl: "https://test.com/json", parameters: nil)!)
	var session: FakeSession!
	var httpClient: HttpClient!
	let waitTimeout: Double = 2
	var fakeResponse: URLResponse!
	var resumeActions: ((FakeDataTask) -> ())!
	
	override func setUp() {
		super.setUp()
		// Put setup code here. This method is called before the invocation of each test method in the class.
		
		bag = DisposeBag()
		//session = FakeSession(fakeTask: FakeDataTask())
		session = FakeSession()
		httpClient = HttpClient(session: session)
		
		fakeResponse = URLResponse(url: request.url!, mimeType: "audio/mpeg", expectedContentLength: 26, textEncodingName: nil)
		// when fake task will resumed it will invoke this closure
		resumeActions = { _ in
			let fakeUrlEvents = [
				SessionDataEvents.didReceiveResponse(session: self.session,
					dataTask: self.session.task,
					response: self.fakeResponse,
					completion: { _ in }),
				SessionDataEvents.didReceiveData(session: self.session, dataTask: self.session.task, data: "First".data(using: String.Encoding.utf8)!),
				SessionDataEvents.didReceiveData(session: self.session, dataTask: self.session.task, data: "Second".data(using: String.Encoding.utf8)!),
				SessionDataEvents.didReceiveData(session: self.session, dataTask: self.session.task, data: "Third".data(using: String.Encoding.utf8)!),
				SessionDataEvents.didReceiveData(session: self.session, dataTask: self.session.task, data: "Fourth".data(using: String.Encoding.utf8)!),
				SessionDataEvents.didCompleteWithError(session: self.session, dataTask: self.session.task, error: nil)
			]
			
			DispatchQueue.global(qos: DispatchQoS.QoSClass.utility).async { [unowned self] in
				for event in fakeUrlEvents {
					// send events to session observer (simulates NSURLSession behavior)
					self.httpClient.sessionObserver.sessionEventsSubject.onNext(event)
					// simulate delay
					Thread.sleep(forTimeInterval: 0.005)
				}
			}
		}
	}
	
	override func tearDown() {
		// Put teardown code here. This method is called after the invocation of each test method in the class.
		super.tearDown()
		bag = nil
		session = nil
	}
	
	func testInitWithCorrectMimeType() {
		let provider = MemoryDataCacheProvider(contentMimeType: "audio/mpeg")
		XCTAssertEqual("audio/mpeg", provider.contentMimeType)
	}
	
	func testInitWithUidAndEmptyMimeType() {
		let provider = MemoryDataCacheProvider()
		XCTAssertNil(provider.contentMimeType)
		XCTAssertNotEqual("", provider.uid)
	}
	
	func testCacheCorrectData() {
		let taskCancelExpectation = expectation(description: "Should cancel task and not invalidate tession")
		session.task = FakeDataTask(resumeClosure: resumeActions, cancelClosure: { _ in taskCancelExpectation.fulfill() })

		var receiveChunkCounter = 0
		
		let successExpectation = expectation(description: "Should successfuly cache data")
		
		httpClient.request(request, dataCacheProvider: MemoryDataCacheProvider(uid: UUID().uuidString)).subscribe(onNext: { result in
			if case StreamTaskEvents.cacheData = result {
				receiveChunkCounter += 1
			} else if case .success(let cacheProvider) = result {
				XCTAssertNotNil(cacheProvider, "Cache provider should be specified")
				XCTAssertEqual(self.fakeResponse.expectedContentLength, cacheProvider?.expectedDataLength, "Should have expectedDataLength same as length in response")
				XCTAssertEqual(self.fakeResponse.mimeType, cacheProvider?.contentMimeType, "Should have mime type same as mime type of request")
				XCTAssertEqual(4, receiveChunkCounter, "Should cache correct data chunk amount")
				XCTAssertEqual(true, cacheProvider!.getData() == "FirstSecondThirdFourth".data(using: String.Encoding.utf8)!, "Sended data end cached data should be equal")
				successExpectation.fulfill()
			} else if case StreamTaskEvents.receiveData = result {
				XCTFail("Shouldn't rise this event because CacheProvider was specified")
			}
			}).disposed(by: bag)
		
		waitForExpectations(timeout: waitTimeout, handler: nil)
		XCTAssertFalse(self.session.isFinished, "Session should not be invalidated")
	}
	
	func testCacheCorrectDataIfDataTaskHasMoreThanOneObserver() {
		session.task = FakeDataTask(resumeClosure: resumeActions)

		var receiveChunkCounter = 0
		
		let successExpectation = expectation(description: "Should successfuly cache data")
		
		let dataTask = session.dataTaskWithRequest(request)
		let task = StreamDataTask(taskUid: UUID().uuidString,
		                          dataTask: dataTask,
		                          sessionEvents: httpClient.sessionObserver.sessionEvents,
		                          dataCacheProvider: MemoryDataCacheProvider(uid: UUID().uuidString))

		task.taskProgress.subscribe(onNext: { result in
			if case StreamTaskEvents.cacheData = result {
				receiveChunkCounter += 1
			} else if case .success(let cacheProvider) = result {
				XCTAssertNotNil(cacheProvider, "Cache provider should be specified")
				XCTAssertEqual(self.fakeResponse.expectedContentLength, cacheProvider?.expectedDataLength, "Should have expectedDataLength same as length in response")
				XCTAssertEqual(self.fakeResponse.mimeType, cacheProvider?.contentMimeType, "Should have mime type same as mime type of request")
				XCTAssertEqual(4, receiveChunkCounter, "Should cache correct data chunk amount")
				XCTAssertEqual(true, cacheProvider!.getData() == "FirstSecondThirdFourth".data(using: String.Encoding.utf8)!, "Sended data end cached data should be equal")
				successExpectation.fulfill()
			} else if case StreamTaskEvents.receiveData = result {
				XCTFail("Shouldn't rise this event because CacheProvider was specified")
			}
			}).disposed(by: bag)
		
		// bind to task events one more time
		task.taskProgress.subscribe(onNext: { _ in }).disposed(by: bag)
		
		task.resume()
		
		waitForExpectations(timeout: waitTimeout, handler: nil)
		XCTAssertFalse(self.session.isFinished, "Session should not be invalidated")
		//XCTAssertFalse(task.resumed, "Task should not be resumed")
		XCTAssertEqual(StreamTaskState.completed, task.state, "Task should be completed")
	}
	
	func testNotOverrideMimeType() {
		let taskCancelExpectation = expectation(description: "Should cancel task and not invalidate session")
		session.task = FakeDataTask(resumeClosure: resumeActions, cancelClosure: { _ in taskCancelExpectation.fulfill() })
		
		let successExpectation = expectation(description: "Should successfuly cache data")
		
		// create memory cache provider with explicitly specified mime type
		httpClient.request(request, dataCacheProvider: MemoryDataCacheProvider(uid: UUID().uuidString, contentMimeType: "application/octet-stream")).subscribe(onNext: { result in
			if case .success(let cacheProvider) = result {
				XCTAssertNotNil(cacheProvider, "Cache provider should be specified")
				XCTAssertEqual(cacheProvider?.contentMimeType, "application/octet-stream", "Mime type should be preserved")
				successExpectation.fulfill()
			} else if case StreamTaskEvents.receiveData = result {
				XCTFail("Shouldn't rise this event because CacheProvider was specified")
			}
			}).disposed(by: bag)
		
		waitForExpectations(timeout: waitTimeout, handler: nil)
		XCTAssertFalse(self.session.isFinished, "Session should not be invalidated")
	}
	
	func testSaveDataOnDisk() {
		let provider = MemoryDataCacheProvider(uid: UUID().uuidString)
		let testData = "Some test data string".data(using: String.Encoding.utf8)!
		provider.append(data: testData)
		XCTAssertTrue(testData == provider.getData(), "Cached data should be equal to data sended in cache")
		let savedDataUrl = provider.saveData()
		XCTAssertNotNil(savedDataUrl, "Should save data end return url")
		XCTAssertEqual(savedDataUrl?.pathExtension, "dat", "Should set default file extension (dat)")
		if let savedDataUrl = savedDataUrl, let data = try? Data(contentsOf: savedDataUrl) {
			XCTAssertTrue(testData == data, "Saved on disk data should be same as cached data")
			try! FileManager.default.removeItem(at: savedDataUrl)
		} else {
			XCTFail("Cached data should be equal to sended data")
		}
	}
	
	func testSaveDataOnDiskWithCustomExtension() {
		let provider = MemoryDataCacheProvider(uid: UUID().uuidString)
		let testData = "Some test data string".data(using: String.Encoding.utf8)!
		provider.append(data: testData)
		let savedDataUrl = provider.saveData(fileExtension: "mp3")
		XCTAssertEqual(savedDataUrl?.pathExtension, "mp3", "Should set specified file extension")
		if let savedDataUrl = savedDataUrl {
			try! FileManager.default.removeItem(at: savedDataUrl)
		}
	}
	
	func testClearData() {
		let provider = MemoryDataCacheProvider(uid: UUID().uuidString)
		let testData = "Some test data string".data(using: String.Encoding.utf8)!
		provider.append(data: testData)
		XCTAssertTrue(provider.currentDataLength > 0, "Should have cached data")
		provider.clearData()
		XCTAssertEqual(0, provider.currentDataLength, "Should have clean cache data")
	}
	
	func testReturnCurrentData() {
		let provider = MemoryDataCacheProvider(uid: UUID().uuidString)
		let testData = "Some test data string".data(using: String.Encoding.utf8)!
		provider.append(data: testData)
		XCTAssertTrue(testData == provider.getData())
	}
	
	func testReturnCurrentDataOffset() {
		let provider = MemoryDataCacheProvider(uid: UUID().uuidString)
		let testData = "Some test data string".data(using: String.Encoding.utf8)!
		provider.append(data: testData)
		//XCTAssertTrue(testData.isEqualToData(provider.getCurrentData()))
		let chunkLen = provider.currentDataLength - 2
		let chunk = provider.getSubdata(location: 1, length: chunkLen)
		XCTAssertTrue(chunk == testData.subdata(in: Range(uncheckedBounds: (lower: 1, upper: chunkLen + 1))))
	}
	
	func testSaveDataToSpecificDir() {
		let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
		try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false, attributes: nil)
		let provider = MemoryDataCacheProvider(uid: "test")
		let testData = "Some test data string".data(using: String.Encoding.utf8)!
		provider.append(data: testData)
		let savedDataUrl = provider.saveData(destinationDirectory: dir)
		XCTAssertNotNil(savedDataUrl, "Should save data end return url")
		XCTAssertEqual(savedDataUrl?.pathExtension, "dat", "Should set default file extension (dat)")
		if let savedDataUrl = savedDataUrl, let data = try? Data(contentsOf: savedDataUrl) {
			XCTAssertTrue(testData == data, "Saved on disk data should be same as cached data")
			try! FileManager.default.removeItem(at: dir)
		} else {
			XCTFail("Cached data should be equal to sended data")
		}
	}
}
