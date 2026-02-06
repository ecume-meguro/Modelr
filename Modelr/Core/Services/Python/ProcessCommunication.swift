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
            ErrorReporter.debug("Response for unknown messageId: \(messageId)", subsystem: .python)
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
            ErrorReporter.debug("Cancelling request \(messageId)", subsystem: .python)
            continuation.resume(throwing: error)
        }
        pendingRequests.removeAll()
        responseBuffer.removeAll()
    }

    /// Handle incoming stdout data, parse JSON lines, and dispatch to pending requests
    /// - Parameter data: Raw data from stdout
    /// - Returns: Array of (messageId, jsonData) tuples for successfully parsed responses
    /// - Note: On buffer overflow, all pending requests are notified with an error
    func handleStdoutChunk(_ data: Data) -> [(messageId: String, json: Data)] {
        // Check buffer size to prevent unbounded growth
        if responseBuffer.count + data.count > maxBufferSize {
            let overflowSize = responseBuffer.count + data.count
            ErrorReporter.error("Response buffer overflow (\(overflowSize) bytes), notifying pending requests and resetting", subsystem: .python)

            // Notify all pending requests about the overflow error before resetting
            let overflowError = PythonError.bufferOverflow(size: overflowSize)
            for (messageId, continuation) in pendingRequests {
                ErrorReporter.warning("Cancelling request \(messageId) due to buffer overflow", subsystem: .python)
                continuation.resume(throwing: overflowError)
            }
            pendingRequests.removeAll()
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
                ErrorReporter.debug(lineString, subsystem: .python)
                continue
            }

            // Try to extract messageId from JSON
            if let jsonData = lineString.data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
               let messageId = json["messageId"] as? String {
                results.append((messageId, lineData))
            } else {
                ErrorReporter.warning("JSON response missing messageId", subsystem: .python)
            }
        }

        return results
    }

    /// Get count of pending requests (for debugging)
    var pendingCount: Int {
        pendingRequests.count
    }
}
