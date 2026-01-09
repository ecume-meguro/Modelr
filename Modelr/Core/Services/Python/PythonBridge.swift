import Foundation
import AppKit

/// Handles JSON communication with Python worker processes
class PythonBridge {
    private var responseBuffer = Data()
    private let processQueue = DispatchQueue(label: "com.modelr.python.bridge")
    private let requestSemaphore = DispatchSemaphore(value: 1)
    
    private weak var processManager: PythonProcessManager?
    
    private var pendingContinuations: [(Data) -> Void] = []
    private let continuationLock = NSLock()
    
    init(processManager: PythonProcessManager) {
        self.processManager = processManager
        processManager.onStdoutData = { [weak self] data in
            self?.handleStdoutData(data)
        }
    }
    
    // MARK: - Communication
    
    func sendRequest(_ request: SAMRequest) async throws -> SAMResponse {
        return try await sendGenericRequest(request)
    }

    private func sendGenericRequest<T: Codable, R: Codable>(_ request: T) async throws -> R {
        // Ensure serial execution of requests
        requestSemaphore.wait()
        defer { requestSemaphore.signal() }
        
        guard let stdin = processManager?.stdinPipe?.fileHandleForWriting else {
            throw PythonError.workerNotRunning
        }
        
        let jsonData = try JSONEncoder().encode(request)
        guard var jsonString = String(data: jsonData, encoding: .utf8) else {
            throw PythonError.encodingError
        }
        print("[Python Request] \(jsonString)")
        jsonString += "\n"
        
        return try await withCheckedThrowingContinuation { continuation in
            continuationLock.lock()
            pendingContinuations.append { data in
                do {
                    let response = try JSONDecoder().decode(R.self, from: data)
                    continuation.resume(returning: response)
                } catch {
                    print("[Bridge] JSON Decode Error: \(error). Raw data: \(String(data: data, encoding: .utf8) ?? "binary")")
                    continuation.resume(throwing: error)
                }
            }
            continuationLock.unlock()
            
            do {
                try stdin.write(contentsOf: Data(jsonString.utf8))
            } catch {
                continuationLock.lock()
                _ = self.pendingContinuations.popLast()
                continuationLock.unlock()
                continuation.resume(throwing: error)
            }
        }
    }
    
    func waitForResponse(timeout: TimeInterval) async throws -> SAMResponse {
        // Use actor-isolated state to track if continuation was already resumed
        final class ResumeTracker: @unchecked Sendable {
            private let lock = NSLock()
            private var _hasResumed = false

            var hasResumed: Bool {
                lock.lock()
                defer { lock.unlock() }
                return _hasResumed
            }

            func markResumed() -> Bool {
                lock.lock()
                defer { lock.unlock() }
                if _hasResumed { return false }
                _hasResumed = true
                return true
            }
        }

        let tracker = ResumeTracker()

        return try await withCheckedThrowingContinuation { continuation in
            continuationLock.lock()
            pendingContinuations.append { [tracker] data in
                guard tracker.markResumed() else { return }
                do {
                    let response = try JSONDecoder().decode(SAMResponse.self, from: data)
                    continuation.resume(returning: response)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
            continuationLock.unlock()

            // Schedule timeout handler
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [weak self, tracker] in
                guard tracker.markResumed() else { return }

                // Remove the pending continuation since we're timing out
                self?.continuationLock.lock()
                // Find and remove the continuation (it hasn't been called yet since we just marked resumed)
                if let self = self, !self.pendingContinuations.isEmpty {
                    self.pendingContinuations.removeFirst()
                }
                self?.continuationLock.unlock()

                continuation.resume(throwing: PythonError.timeout)
            }
        }
    }
    
    private func handleStdoutData(_ data: Data) {
        responseBuffer.append(data)
        
        while let newlineRange = responseBuffer.range(of: Data("\n".utf8)) {
            let lineData = responseBuffer.subdata(in: responseBuffer.startIndex..<newlineRange.lowerBound)
            responseBuffer.removeSubrange(responseBuffer.startIndex...newlineRange.lowerBound)
            
            guard let lineString = String(data: lineData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !lineString.isEmpty else { continue }
            
            // Skip non-JSON lines (pollution from libraries like tqdm or direct prints)
            if !lineString.hasPrefix("{") || !lineString.hasSuffix("}") {
                print("[Python stdout skip] \(lineString)")
                continue
            }
            
            continuationLock.lock()
            if !pendingContinuations.isEmpty {
                let continuation = pendingContinuations.removeFirst()
                continuationLock.unlock()
                continuation(Data(lineString.utf8))
            } else {
                continuationLock.unlock()
                print("[Python Bridge] Received unexpected JSON: \(lineString)")
            }
        }
    }
    
    // MARK: - High-level API
    
    func setImage(path: String) async throws -> CGSize {
        let request = SAMRequest(command: "set_image", imagePath: path)
        let response = try await sendRequest(request)
        
        guard response.success else {
            throw PythonError.predictionFailed(response.error ?? "Unknown error")
        }
        
        guard let width = response.width, let height = response.height else {
            throw PythonError.predictionFailed("No image dimensions returned")
        }
        
        return CGSize(width: CGFloat(width), height: CGFloat(height))
    }
    
    func predict(
        points: [SAMPoint] = [],
        box: SAMBox? = nil,
        text: String? = nil,
        imageSize: CGSize
    ) async throws -> (masks: [URL], primaryMask: URL, scores: [Double], confidenceMap: URL?) {
        let pixelPoints: [[Int]] = points.map { point in
            let coords = point.pixelCoords(for: imageSize)
            return [coords.x, coords.y]
        }
        let pointLabels: [Int] = points.map { $0.label }
        let pixelBox: [Int]? = box?.pixelBox(for: imageSize)
        
        let request = SAMRequest(
            command: "predict",
            points: pixelPoints.isEmpty ? nil : pixelPoints,
            labels: pointLabels.isEmpty ? nil : pointLabels,
            box: pixelBox,
            text: text
        )
        
        let response = try await sendRequest(request)
        
        guard response.success else {
            throw PythonError.predictionFailed(response.error ?? "Unknown error")
        }
        
        guard let maskPaths = response.masks, !maskPaths.isEmpty else {
            throw PythonError.predictionFailed("No masks returned")
        }
        
        if let inferenceTime = response.inferenceTimeMs {
            print("Inference completed in \(inferenceTime)ms")
        }
        
        let urls = maskPaths.map { URL(fileURLWithPath: $0) }
        let primaryURL = response.primaryMaskPath.flatMap { URL(fileURLWithPath: $0) } ?? urls.first!
        let scores = response.scores ?? []
        let confidenceMapURL = response.confidenceMapPath.flatMap { URL(fileURLWithPath: $0) }
        
        return (urls, primaryURL, scores, confidenceMapURL)
    }
    
    func removeBackground() async throws -> URL {
        let request = SAMRequest(command: "remove_background")
        let response = try await sendRequest(request)
        
        guard response.success, let imagePath = response.imagePath else {
            throw PythonError.predictionFailed(response.error ?? "Unknown error")
        }
        
        return URL(fileURLWithPath: imagePath)
    }
    
    func resetPredictor() async throws {
        let request = SAMRequest(command: "reset")
        let _ = try await sendRequest(request)
    }
}
