import os.log
import Foundation
import AppKit

/// Handles JSON communication with Python SAM worker process
/// Refactored to use UnifiedProcessBridge for safety
class PythonBridge {
    private let bridge = UnifiedProcessBridge<SAMRequest, SAMResponse>()
    private weak var processManager: PythonProcessManager?
    
    init(processManager: PythonProcessManager) {
        self.processManager = processManager
        processManager.onStdoutData = { [weak self] data in
            Task {
                await self?.handleStdoutData(data)
            }
        }
    }

    // MARK: - Communication

    func sendRequest(_ request: SAMRequest) async throws -> SAMResponse {
        guard let stdin = processManager?.stdinPipe?.fileHandleForWriting else {
            throw PythonError.workerNotRunning
        }

        print("[Python Request] \(request.command)")

        // Use unified bridge - FIFO mode (SAM responses don't have messageId)
        return try await bridge.sendRequestFIFO(
            request,
            timeout: .seconds(30),
            write: { data in
                try stdin.write(contentsOf: data)
            }
        )
    }
    
    func waitForResponse(timeout: TimeInterval) async throws -> SAMResponse {
        // Use unified bridge with timeout
        let request = SAMRequest(command: "ready")  // Dummy request for waiting
        guard processManager?.stdinPipe?.fileHandleForWriting != nil else {
            throw PythonError.workerNotRunning
        }

        return try await bridge.sendRequestFIFO(
            request,
            timeout: .seconds(Int64(timeout)),
            write: { data in
                // Don't actually write for waiting - just wait for next response
            }
        )
    }

    private func handleStdoutData(_ data: Data) async {
        // Parse responses using bridge
        let responses = await bridge.handleStdout(data)

        // Dispatch all parsed responses
        for (_, response) in responses {
            await bridge.dispatchResponseFIFO(response)
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
