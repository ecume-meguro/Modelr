import Foundation
import os.log

/// Actor-based process communication that eliminates blocking semaphores
/// and properly correlates requests with responses via messageId
actor ProcessCommunication {
    private var pendingRequests: [String: CheckedContinuation<Data, Error>] = [:]
    private var responseBuffer = Data()
    private let maxBufferSize = 10 * 1024 * 1024 // 10MB

    /// Register a request and wait for its response
    /// - Parameter messageId: Unique identifier for this request
    /// - Returns: Response data when it arrives
    /// - Throws: PythonError if timeout occurs or process terminates
    func registerRequest(messageId: String) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            pendingRequests[messageId] = continuation
        }
    }

    /// Handle a response from Python, resuming the appropriate continuation
    /// - Parameters:
    ///   - messageId: The request ID this response corresponds to
    ///   - data: The JSON response data
    func handleResponse(messageId: String, data: Data) {
        if let continuation = pendingRequests.removeValue(forKey: messageId) {
            continuation.resume(returning: data)
        } else {
            print("[ProcessCommunication] Warning: Received response for unknown messageId: \(messageId)")
        }
    }

    /// Cancel a specific pending request with a timeout error
    /// - Parameter messageId: The request ID to cancel
    func cancelRequest(messageId: String) {
        if let continuation = pendingRequests.removeValue(forKey: messageId) {
            continuation.resume(throwing: PythonError.timeout)
        }
    }

    /// Cancel all pending requests (called when process terminates)
    /// - Parameter error: The error to resume all continuations with
    func cancelAll(with error: Error) {
        for (messageId, continuation) in pendingRequests {
            print("[ProcessCommunication] Cancelling request \(messageId) due to: \(error)")
            continuation.resume(throwing: error)
        }
        pendingRequests.removeAll()
        responseBuffer.removeAll()
    }

    /// Handle incoming stdout data, parse JSON lines, and dispatch to pending requests
    /// - Parameter data: Raw data from stdout
    /// - Returns: Array of (messageId, jsonData) tuples for successfully parsed responses
    func handleStdoutChunk(_ data: Data) -> [(messageId: String, json: Data)] {
        // Check buffer size to prevent unbounded growth
        if responseBuffer.count + data.count > maxBufferSize {
            print("[ProcessCommunication] ERROR: Response buffer overflow (\(responseBuffer.count + data.count) bytes), resetting")
            responseBuffer.removeAll()
            return []
        }

        responseBuffer.append(data)

        var results: [(String, Data)] = []

        // Process complete JSON lines (delimited by newlines)
        while let newlineRange = responseBuffer.range(of: Data("\n".utf8)) {
            let lineData = responseBuffer.subdata(in: responseBuffer.startIndex..<newlineRange.lowerBound)
            responseBuffer.removeSubrange(responseBuffer.startIndex...newlineRange.lowerBound)

            guard let lineString = String(data: lineData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !lineString.isEmpty else { continue }

            // Skip non-JSON lines (library output, debug prints, etc.)
            guard lineString.hasPrefix("{"), lineString.hasSuffix("}") else {
                print("[ProcessCommunication stdout] \(lineString)")
                continue
            }

            // Try to extract messageId from JSON
            if let jsonData = lineString.data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
               let messageId = json["messageId"] as? String {
                results.append((messageId, lineData))
            } else {
                print("[ProcessCommunication] Warning: JSON response missing messageId: \(lineString.prefix(100))")
            }
        }

        return results
    }

    /// Get count of pending requests (for debugging)
    var pendingCount: Int {
        pendingRequests.count
    }
}
