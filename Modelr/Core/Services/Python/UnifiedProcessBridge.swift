import Foundation
import os.log

// MARK: - PythonError (if not already imported)
// PythonError is defined in AppError.swift

/// Unified actor-based process communication bridge
/// Eliminates all race conditions, NSLocks, and blocking primitives
actor UnifiedProcessBridge<Request: Codable, Response: Codable> {

    // MARK: - Types

    struct PendingRequest {
        let continuation: CheckedContinuation<Response, Error>
        let startTime: Date
        var timeoutTask: Task<Void, Never>?
    }

    // MARK: - State

    private var pendingRequests: [String: PendingRequest] = [:]
    private var responseBuffer = Data()
    private let maxBufferSize = 10 * 1024 * 1024 // 10MB

    // MARK: - Request Management

    /// Send a request and wait for response with automatic timeout
    func sendRequest(
        _ request: Request,
        messageId: String,
        timeout: Duration,
        write: @escaping (Data) async throws -> Void
    ) async throws -> Response {
        // Serialize and write request
        let jsonData = try JSONEncoder().encode(request)
        guard var jsonString = String(data: jsonData, encoding: .utf8) else {
            throw PythonError.encodingError
        }
        jsonString += "\n"

        // Register continuation BEFORE writing (prevents race with fast response)
        return try await withCheckedThrowingContinuation { continuation in
            // Create timeout task
            let timeoutTask = Task { [weak self] in
                do {
                    try await Task.sleep(for: timeout)
                    await self?.timeoutRequest(messageId: messageId)
                } catch {
                    // Task was cancelled, timeout won't fire
                }
            }

            // Store pending request
            pendingRequests[messageId] = PendingRequest(
                continuation: continuation,
                startTime: Date(),
                timeoutTask: timeoutTask
            )

            // Write request asynchronously
            Task {
                do {
                    try await write(Data(jsonString.utf8))
                } catch {
                    // Write failed - cancel the request
                    await self.cancelRequest(messageId: messageId, error: error)
                }
            }
        }
    }

    /// Send request for FIFO-based protocols (no messageId in response)
    func sendRequestFIFO(
        _ request: Request,
        timeout: Duration,
        write: @escaping (Data) async throws -> Void
    ) async throws -> Response {
        let messageId = UUID().uuidString
        return try await sendRequest(request, messageId: messageId, timeout: timeout, write: write)
    }

    // MARK: - Response Handling

    /// Process incoming stdout data
    /// Returns parsed responses ready for dispatch
    func handleStdout(_ data: Data) -> [(messageId: String, response: Response)] {
        // Check buffer overflow - keep most recent half if exceeded
        if responseBuffer.count + data.count > maxBufferSize {
            let keepSize = maxBufferSize / 2
            let dropCount = responseBuffer.count - keepSize
            responseBuffer.removeFirst(dropCount)
            print("[UnifiedBridge] Buffer overflow, dropped \(dropCount) bytes")
        }

        responseBuffer.append(data)

        var results: [(String, Response)] = []

        // Process all complete JSON lines atomically
        while let newlineRange = responseBuffer.range(of: Data("\n".utf8)) {
            let lineData = responseBuffer.subdata(in: responseBuffer.startIndex..<newlineRange.lowerBound)
            responseBuffer.removeSubrange(responseBuffer.startIndex...newlineRange.lowerBound)

            guard let lineString = String(data: lineData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !lineString.isEmpty else {
                continue
            }

            // Skip non-JSON lines (library output)
            guard lineString.hasPrefix("{"), lineString.hasSuffix("}") else {
                print("[UnifiedBridge] Skipping non-JSON: \(lineString)")
                continue
            }

            // Try to extract messageId
            if let jsonData = lineString.data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
               let messageId = json["messageId"] as? String {

                // Try to decode full response
                if let response = try? JSONDecoder().decode(Response.self, from: jsonData) {
                    results.append((messageId, response))
                } else {
                    print("[UnifiedBridge] Failed to decode response for messageId: \(messageId)")
                }
            } else {
                print("[UnifiedBridge] Response missing messageId: \(lineString.prefix(100))")
            }
        }

        return results
    }

    /// Dispatch a response to the waiting continuation
    func dispatchResponse(messageId: String, response: Response) {
        guard let pending = pendingRequests.removeValue(forKey: messageId) else {
            print("[UnifiedBridge] Received response for unknown messageId: \(messageId)")
            return
        }

        // Cancel timeout task
        pending.timeoutTask?.cancel()

        // Resume continuation
        pending.continuation.resume(returning: response)
    }

    /// Handle FIFO response (for protocols without messageId)
    func dispatchResponseFIFO(_ response: Response) {
        // Resume oldest pending request
        guard let (messageId, pending) = pendingRequests.min(by: { $0.value.startTime < $1.value.startTime }) else {
            print("[UnifiedBridge] Received FIFO response with no pending requests")
            return
        }

        pendingRequests.removeValue(forKey: messageId)
        pending.timeoutTask?.cancel()
        pending.continuation.resume(returning: response)
    }

    // MARK: - Cancellation & Timeout

    private func timeoutRequest(messageId: String) {
        guard let pending = pendingRequests.removeValue(forKey: messageId) else {
            return
        }

        let elapsed = Date().timeIntervalSince(pending.startTime)
        print("[UnifiedBridge] Request \(messageId) timed out after \(elapsed)s")
        pending.continuation.resume(throwing: PythonError.timeout)
    }

    private func cancelRequest(messageId: String, error: Error) {
        guard let pending = pendingRequests.removeValue(forKey: messageId) else {
            return
        }

        pending.timeoutTask?.cancel()
        pending.continuation.resume(throwing: error)
    }

    /// Cancel all pending requests (called on process termination)
    func cancelAll(error: Error) {
        for (messageId, pending) in pendingRequests {
            print("[UnifiedBridge] Cancelling request \(messageId): \(error)")
            pending.timeoutTask?.cancel()
            pending.continuation.resume(throwing: error)
        }
        pendingRequests.removeAll()
        responseBuffer.removeAll()
    }

    /// Get count of pending requests (for debugging)
    var pendingCount: Int {
        pendingRequests.count
    }
}

/// Progress-aware bridge that supports multi-response requests (e.g., Hunyuan generation)
actor ProgressAwareBridge<Request: Codable, Response: Codable> {

    // MARK: - Types

    struct PendingRequest {
        let onProgress: ((Response) -> Void)?
        let onComplete: (Response) -> Void
        let onError: (Error) -> Void
        let startTime: Date
        var lastActivityTime: Date
        var timeoutTask: Task<Void, Never>?
    }

    // MARK: - State

    private var pendingRequests: [String: PendingRequest] = [:]
    private var responseBuffer = Data()
    private let maxBufferSize = 10 * 1024 * 1024

    // MARK: - Request Management

    func sendRequest(
        _ request: Request,
        messageId: String,
        idleTimeout: Duration,
        write: @escaping (Data) async throws -> Void,
        onProgress: ((Response) -> Void)?,
        onActivityDetected: (@escaping () -> Void) -> Void
    ) async throws -> Response {
        let jsonData = try JSONEncoder().encode(request)
        guard var jsonString = String(data: jsonData, encoding: .utf8) else {
            throw PythonError.encodingError
        }
        jsonString += "\n"

        return try await withCheckedThrowingContinuation { continuation in
            // Activity recorder for external progress (e.g., stderr tqdm)
            let recordActivity = { [weak self, messageId] in
                Task {
                    await self?.recordActivity(messageId: messageId)
                }
            }
            onActivityDetected {
                _ = recordActivity()
            }

            // Store pending request
            pendingRequests[messageId] = PendingRequest(
                onProgress: onProgress,
                onComplete: { response in
                    continuation.resume(returning: response)
                },
                onError: { error in
                    continuation.resume(throwing: error)
                },
                startTime: Date(),
                lastActivityTime: Date(),
                timeoutTask: nil
            )

            // Start idle timeout checking
            let checkInterval = Duration.seconds(10)
            let timeoutTask = Task { [weak self, messageId, idleTimeout] in
                try? await Task.sleep(for: checkInterval)
                await self?.checkIdleTimeout(messageId: messageId, idleTimeout: idleTimeout)
            }
            Task {
                await self.updateTimeoutTask(messageId: messageId, task: timeoutTask)
            }

            // Write request
            Task {
                do {
                    try await write(Data(jsonString.utf8))
                } catch {
                    await self.cancelRequest(messageId: messageId, error: error)
                }
            }
        }
    }

    // MARK: - Response Handling

    func handleStdout(_ data: Data) -> [(messageId: String, response: Response)] {
        if responseBuffer.count + data.count > maxBufferSize {
            let keepSize = maxBufferSize / 2
            let dropCount = responseBuffer.count - keepSize
            responseBuffer.removeFirst(dropCount)
            print("[ProgressBridge] Buffer overflow, dropped \(dropCount) bytes")
        }

        responseBuffer.append(data)

        var results: [(String, Response)] = []

        while let newlineRange = responseBuffer.range(of: Data("\n".utf8)) {
            let lineData = responseBuffer.subdata(in: responseBuffer.startIndex..<newlineRange.lowerBound)
            responseBuffer.removeSubrange(responseBuffer.startIndex...newlineRange.lowerBound)

            guard let lineString = String(data: lineData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !lineString.isEmpty,
                  lineString.hasPrefix("{"),
                  lineString.hasSuffix("}") else {
                continue
            }

            if let jsonData = lineString.data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
               let messageId = json["messageId"] as? String,
               let response = try? JSONDecoder().decode(Response.self, from: jsonData) {
                results.append((messageId, response))
            }
        }

        return results
    }

    func dispatchResponse(messageId: String, response: Response, isProgress: Bool, isFinal: Bool) {
        guard var pending = pendingRequests[messageId] else {
            print("[ProgressBridge] Response for unknown messageId: \(messageId)")
            return
        }

        // Record activity
        pending.lastActivityTime = Date()
        pendingRequests[messageId] = pending

        if isProgress {
            // Progress update - call callback, keep pending
            pending.onProgress?(response)
        } else if isFinal {
            // Final response - complete and remove
            pendingRequests.removeValue(forKey: messageId)
            pending.timeoutTask?.cancel()
            pending.onComplete(response)
        }
    }

    // MARK: - Timeout Management

    private func recordActivity(messageId: String) {
        guard var pending = pendingRequests[messageId] else { return }
        pending.lastActivityTime = Date()
        pendingRequests[messageId] = pending
    }

    private func updateTimeoutTask(messageId: String, task: Task<Void, Never>) {
        guard var pending = pendingRequests[messageId] else {
            task.cancel()
            return
        }
        pending.timeoutTask?.cancel()
        pending.timeoutTask = task
        pendingRequests[messageId] = pending
    }

    private func checkIdleTimeout(messageId: String, idleTimeout: Duration) {
        guard let pending = pendingRequests[messageId] else { return }

        let idleTime = Date().timeIntervalSince(pending.lastActivityTime)
        let timeoutSeconds = Double(idleTimeout.components.seconds) + Double(idleTimeout.components.attoseconds) / 1e18

        if idleTime >= timeoutSeconds {
            // Timed out
            pendingRequests.removeValue(forKey: messageId)
            pending.timeoutTask?.cancel()
            print("[ProgressBridge] Request \(messageId) idle timeout after \(idleTime)s")
            pending.onError(PythonError.timeout)
        } else {
            // Still active, reschedule inline
            let checkInterval = Duration.seconds(10)
            let timeoutTask = Task { [weak self, messageId, idleTimeout] in
                try? await Task.sleep(for: checkInterval)
                await self?.checkIdleTimeout(messageId: messageId, idleTimeout: idleTimeout)
            }
            updateTimeoutTask(messageId: messageId, task: timeoutTask)
        }
    }

    private func cancelRequest(messageId: String, error: Error) {
        guard let pending = pendingRequests.removeValue(forKey: messageId) else { return }
        pending.timeoutTask?.cancel()
        pending.onError(error)
    }

    func cancelAll(error: Error) {
        for (messageId, pending) in pendingRequests {
            print("[ProgressBridge] Cancelling \(messageId): \(error)")
            pending.timeoutTask?.cancel()
            pending.onError(error)
        }
        pendingRequests.removeAll()
        responseBuffer.removeAll()
    }

    var pendingCount: Int {
        pendingRequests.count
    }
}

/// Rate limiter for progress callbacks to prevent UI flooding
actor ProgressRateLimiter {
    private var lastEmitTime: Date?
    private let minInterval: TimeInterval

    init(minInterval: TimeInterval = 0.1) { // Max 10 updates/sec
        self.minInterval = minInterval
    }

    func shouldEmit() -> Bool {
        let now = Date()
        if let last = lastEmitTime, now.timeIntervalSince(last) < minInterval {
            return false
        }
        lastEmitTime = now
        return true
    }

    func reset() {
        lastEmitTime = nil
    }
}
