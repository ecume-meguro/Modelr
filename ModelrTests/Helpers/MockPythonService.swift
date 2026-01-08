import Foundation
@testable import Modelr

class MockPythonService: PythonServiceProtocol {
    var isProcessing: Bool = false
    var status: String = "Mock ready"
    
    var shouldThrowError: Bool = false
    var errorToThrow: Error?
    var mockMaskURL: URL?
    var mock3DModelURL: URL?
    var delayMs: UInt64 = 0
    
    func setup() async {
        try? await Task.sleep(nanoseconds: delayMs * 1_000_000)
        status = "Mock setup complete"
    }
    
    private var currentImagePath: String?

    func setImage(path: String) async throws -> CGSize {
        try? await Task.sleep(nanoseconds: delayMs * 1_000_000)

        if shouldThrowError, let error = errorToThrow {
            throw error
        }

        currentImagePath = path
        return CGSize(width: 100, height: 100)
    }

    func setImageIfNeeded(path: String) async throws -> CGSize {
        if path == currentImagePath {
            return CGSize(width: 100, height: 100)
        }
        return try await setImage(path: path)
    }

    func predict(points: [SAMPoint], box: SAMBox?, imageSize: CGSize) async throws -> (masks: [URL], primaryMask: URL, scores: [Double], confidenceMap: URL?) {
        isProcessing = true
        status = "Mock predicting..."

        try? await Task.sleep(nanoseconds: delayMs * 1_000_000)

        if shouldThrowError, let error = errorToThrow {
            isProcessing = false
            status = "Mock error"
            throw error
        }

        isProcessing = false
        status = "Mock ready"

        let url = mockMaskURL ?? URL(fileURLWithPath: "/tmp/mock_mask.png")
        return (masks: [url], primaryMask: url, scores: [0.95], confidenceMap: nil)
    }

    func removeBackground() async throws -> URL {
        isProcessing = true
        status = "Mock removing background..."

        try? await Task.sleep(nanoseconds: delayMs * 1_000_000)

        if shouldThrowError, let error = errorToThrow {
            isProcessing = false
            status = "Mock error"
            throw error
        }

        isProcessing = false
        status = "Mock ready"

        return URL(fileURLWithPath: "/tmp/mock_no_bg.png")
    }
    
    func resetPredictor() async throws {
        try? await Task.sleep(nanoseconds: delayMs * 1_000_000)
        status = "Mock reset complete"
    }
    
    func generate3DModel(
        imagePath: String,
        maskPath: String,
        steps: Int,
        resolution: Int,
        modelVariant: String = "std",
        progress: @escaping (String) -> Void,
        preview: ((Data) -> Void)? = nil,
        completion: @escaping (Result<URL, Error>) -> Void
    ) async {
        isProcessing = true
        status = "Mock generating..."
        
        progress("Starting mock generation")
        try? await Task.sleep(nanoseconds: 100_000_000)
        
        progress("Mock step 1/10")
        try? await Task.sleep(nanoseconds: 100_000_000)
        
        progress("Mock step 5/10")
        try? await Task.sleep(nanoseconds: 100_000_000)
        
        progress("Mock step 10/10")
        try? await Task.sleep(nanoseconds: 100_000_000)
        
        if shouldThrowError, let error = errorToThrow {
            isProcessing = false
            status = "Mock generation failed"
            completion(.failure(error))
            return
        }
        
        isProcessing = false
        status = "Mock generation complete"
        completion(.success(mock3DModelURL ?? URL(fileURLWithPath: "/tmp/mock_model.obj")))
    }
}
