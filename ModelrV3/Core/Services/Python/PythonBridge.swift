import Foundation
import AppKit

/// Handles JSON communication with Python worker processes
class PythonBridge {
    private var responseBuffer = Data()
    private let processQueue = DispatchQueue(label: "com.modelr.python.bridge")
    
    private weak var processManager: PythonProcessManager?
    
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
            self.pendingGenericContinuation = { data in
                do {
                    let response = try JSONDecoder().decode(R.self, from: data)
                    continuation.resume(returning: response)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
            
            do {
                try stdin.write(contentsOf: Data(jsonString.utf8))
            } catch {
                self.pendingGenericContinuation = nil
                continuation.resume(throwing: error)
            }
        }
    }
    
    private var pendingGenericContinuation: ((Data) -> Void)?
    
    // Legacy support
    private var pendingContinuation: CheckedContinuation<SAMResponse, Error>?
    
    func waitForResponse(timeout: TimeInterval) async throws -> SAMResponse {
        try await withCheckedThrowingContinuation { continuation in
            self.pendingContinuation = continuation
            
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [weak self] in
                if let cont = self?.pendingContinuation {
                    self?.pendingContinuation = nil
                    cont.resume(throwing: PythonError.timeout)
                }
            }
        }
    }
    
    private func handleStdoutData(_ data: Data) {
        responseBuffer.append(data)
        
        while let newlineRange = responseBuffer.range(of: Data("\n".utf8)) {
            let lineData = responseBuffer.subdata(in: responseBuffer.startIndex..<newlineRange.lowerBound)
            responseBuffer.removeSubrange(responseBuffer.startIndex...newlineRange.lowerBound)
            
            guard let line = String(data: lineData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !line.isEmpty else { continue }
            
            if let genericCont = pendingGenericContinuation {
                pendingGenericContinuation = nil
                genericCont(Data(line.utf8))
            } else {
                do {
                    let response = try JSONDecoder().decode(SAMResponse.self, from: Data(line.utf8))
                    if let continuation = pendingContinuation {
                        pendingContinuation = nil
                        continuation.resume(returning: response)
                    }
                } catch {
                    print("Failed to decode response: \(error), line: \(line)")
                    if let continuation = pendingContinuation {
                        pendingContinuation = nil
                        continuation.resume(throwing: PythonError.invalidResponse(line))
                    }
                }
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
