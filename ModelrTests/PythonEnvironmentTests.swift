import XCTest
@testable import Modelr

final class PythonEnvironmentTests: XCTestCase {
    
    var mockService: MockPythonService!
    
    override func setUpWithError() throws {
        mockService = MockPythonService()
    }
    
    override func tearDownWithError() throws {
        mockService = nil
    }
    
    // MARK: - Setup Tests
    
    func testMockPythonServiceSetup() async throws {
        XCTAssertFalse(mockService.isProcessing, "Should not be processing initially")
        XCTAssertEqual(mockService.status, "Mock ready")
        
        await mockService.setup()
        
        XCTAssertEqual(mockService.status, "Mock setup complete")
    }
    
    func testMockPythonServiceDelay() async throws {
        mockService.delayMs = 100
        
        let start = Date()
        await mockService.setup()
        let elapsed = Date().timeIntervalSince(start)
        
        XCTAssertGreaterThanOrEqual(elapsed, 0.1, "Should respect delay")
    }
    
    // MARK: - setImage Tests
    
    func testSetImageSuccess() async throws {
        mockService.delayMs = 10
        
        let size = try await mockService.setImage(path: "/fake/path.jpg")
        
        XCTAssertEqual(size.width, 100)
        XCTAssertEqual(size.height, 100)
        XCTAssertEqual(mockService.status, "Mock ready")
    }
    
    func testSetImageError() async throws {
        mockService.shouldThrowError = true
        mockService.errorToThrow = PythonError.uvNotFound
        
        do {
            _ = try await mockService.setImage(path: "/fake/path.jpg")
            XCTFail("Should have thrown error")
        } catch {
            XCTAssertTrue(error is PythonError)
        }
    }
    
    // MARK: - predict Tests
    
    func testPredictSuccess() async throws {
        let imageSize = CGSize(width: 100, height: 100)
        let points = [SAMPoint(normalizedCoords: CGPoint(x: 0.5, y: 0.5))]

        let (_, primaryMask, _, _) = try await mockService.predict(points: points, box: nil, imageSize: imageSize)

        XCTAssertTrue(primaryMask.path.contains("mask.png"))
        XCTAssertEqual(mockService.status, "Mock ready")
    }
    
    func testPredictProcessingState() async throws {
        let imageSize = CGSize(width: 100, height: 100)
        let points = [SAMPoint(normalizedCoords: CGPoint(x: 0.5, y: 0.5))]
        
        mockService.delayMs = 100
        
        Task {
            _ = try await mockService.predict(points: points, box: nil, imageSize: imageSize)
        }
        
        try await Task.sleep(nanoseconds: 10_000_000)
        XCTAssertTrue(mockService.isProcessing, "Should be processing during prediction")
        
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertFalse(mockService.isProcessing, "Should finish processing")
    }
    
    func testPredictError() async throws {
        mockService.shouldThrowError = true
        mockService.errorToThrow = PythonError.predictionFailed("Test error")
        
        let imageSize = CGSize(width: 100, height: 100)
        let points = [SAMPoint(normalizedCoords: CGPoint(x: 0.5, y: 0.5))]
        
        do {
            _ = try await mockService.predict(points: points, box: nil, imageSize: imageSize)
            XCTFail("Should have thrown prediction error")
        } catch {
            XCTAssertTrue(error is PythonError)
        }
    }
    
    // MARK: - resetPredictor Tests
    
    func testResetPredictor() async throws {
        try await mockService.resetPredictor()
        
        XCTAssertEqual(mockService.status, "Mock reset complete")
    }
    
    // MARK: - generate3DModel Tests
    
    func testGenerate3DModelSuccess() async throws {
        var progressUpdates: [String] = []
        var finalResult: Result<URL, Error>?
        
        await mockService.generate3DModel(
            imagePath: "/fake/image.jpg",
            maskPath: "/fake/mask.png",
            steps: 10,
            resolution: 128,
            modelVariant: "mini"
        ) { progress in
            progressUpdates.append(progress)
        } completion: { result in
            finalResult = result
        }
        
        try await Task.sleep(nanoseconds: 500_000_000)
        
        XCTAssertNotNil(finalResult, "Should have completed")
        
        switch finalResult {
        case .success(let url):
            XCTAssertTrue(url.path.contains("model.obj"))
        case .failure:
            XCTFail("Should have succeeded")
        case .none:
            XCTFail("Should have a result")
        }
        
        XCTAssertFalse(progressUpdates.isEmpty, "Should have received progress updates")
        XCTAssertTrue(progressUpdates.contains("Starting mock generation"))
    }
    
    func testGenerate3DModelError() async throws {
        mockService.shouldThrowError = true
        mockService.errorToThrow = PythonError.predictionFailed("Generation failed")
        
        var finalResult: Result<URL, Error>?
        
        await mockService.generate3DModel(
            imagePath: "/fake/image.jpg",
            maskPath: "/fake/mask.png",
            steps: 10,
            resolution: 128,
            modelVariant: "mini"
        ) { _ in } completion: { result in
            finalResult = result
        }
        
        try await Task.sleep(nanoseconds: 500_000_000)
        
        switch finalResult {
        case .success:
            XCTFail("Should have failed")
        case .failure(let error):
            XCTAssertTrue(error is PythonError)
        case .none:
            XCTFail("Should have a result")
        }
    }
    
    func testGenerate3DModelProgress() async throws {
        var progressUpdates: [String] = []
        
        await mockService.generate3DModel(
            imagePath: "/fake/image.jpg",
            maskPath: "/fake/mask.png",
            steps: 10,
            resolution: 128,
            modelVariant: "mini"
        ) { progress in
            progressUpdates.append(progress)
        } completion: { _ in }
        
        try await Task.sleep(nanoseconds: 500_000_000)
        
        XCTAssertGreaterThanOrEqual(progressUpdates.count, 3, "Should have multiple progress updates")
    }
    
    // MARK: - PythonError Tests
    
    func testPythonErrorDescriptions() throws {
        let errors: [PythonError] = [
            .uvNotFound,
            .workerNotRunning,
            .workerNotReady,
            .encodingError,
            .invalidResponse("test"),
            .predictionFailed("failed"),
            .timeout
        ]
        
        for error in errors {
            XCTAssertNotNil(error.errorDescription, "Error should have description")
        }
    }
    
    func testPythonErrorRecoverable() throws {
        let recoverableErrors: [PythonError] = [
            .timeout,
            .workerNotRunning
        ]
        
        for error in recoverableErrors {
            XCTAssertTrue(error.isRecoverable, "\(error) should be recoverable")
        }
        
        let nonRecoverableErrors: [PythonError] = [
            .uvNotFound,
            .invalidResponse("test")
        ]
        
        for error in nonRecoverableErrors {
            XCTAssertFalse(error.isRecoverable, "\(error) should not be recoverable")
        }
    }
    
    func testPythonErrorSuggestedAction() throws {
        let timeoutAction = PythonError.timeout.suggestedAction
        XCTAssertFalse(timeoutAction.isEmpty, "Timeout should have suggested action")
        
        let uvNotFoundAction = PythonError.uvNotFound.suggestedAction
        XCTAssertFalse(uvNotFoundAction.isEmpty, "uvNotFound should have suggested action")
    }
    
    // MARK: - Edge Cases
    
    func testEmptyPointsPredict() async throws {
        let imageSize = CGSize(width: 100, height: 100)

        let (_, primaryMask, _, _) = try await mockService.predict(points: [], box: nil, imageSize: imageSize)

        XCTAssertTrue(primaryMask.path.contains("mask.png"))
    }

    func testMultiplePointsPredict() async throws {
        let imageSize = CGSize(width: 100, height: 100)
        let points = [
            SAMPoint(normalizedCoords: CGPoint(x: 0.2, y: 0.2)),
            SAMPoint(normalizedCoords: CGPoint(x: 0.5, y: 0.5)),
            SAMPoint(normalizedCoords: CGPoint(x: 0.8, y: 0.8))
        ]

        let (_, primaryMask, _, _) = try await mockService.predict(points: points, box: nil, imageSize: imageSize)

        XCTAssertTrue(primaryMask.path.contains("mask.png"))
    }

    func testPredictWithBox() async throws {
        let imageSize = CGSize(width: 100, height: 100)
        let box = SAMBox(startPoint: CGPoint(x: 0.1, y: 0.1), endPoint: CGPoint(x: 0.9, y: 0.9))

        let (_, primaryMask, _, _) = try await mockService.predict(points: [], box: box, imageSize: imageSize)

        XCTAssertTrue(primaryMask.path.contains("mask.png"))
    }

    func testConcurrentPredictions() async throws {
        let imageSize = CGSize(width: 100, height: 100)
        let points1 = [SAMPoint(normalizedCoords: CGPoint(x: 0.3, y: 0.3))]
        let points2 = [SAMPoint(normalizedCoords: CGPoint(x: 0.7, y: 0.7))]

        mockService.delayMs = 100

        async let result1 = mockService.predict(points: points1, box: nil, imageSize: imageSize)
        async let result2 = mockService.predict(points: points2, box: nil, imageSize: imageSize)

        let ((_, primaryMask1, _, _), (_, primaryMask2, _, _)) = try await (result1, result2)

        XCTAssertTrue(primaryMask1.path.contains("mask.png"))
        XCTAssertTrue(primaryMask2.path.contains("mask.png"))
    }
}
