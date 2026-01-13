import XCTest
@testable import Modelr

// MARK: - Mock Types

struct MockRequest: Codable {
    let messageId: String
    let command: String
    let value: Int?

    init(command: String, value: Int? = nil) {
        self.messageId = UUID().uuidString
        self.command = command
        self.value = value
    }
}

struct MockResponse: Codable {
    let messageId: String?
    let success: Bool
    let result: Int?
    let type: String?
    let error: String?
}

// MARK: - UnifiedProcessBridge Tests

final class UnifiedProcessBridgeTests: XCTestCase {

    // MARK: - Basic Request-Response Tests

    func testSingleRequest() async throws {
        let bridge = UnifiedProcessBridge<MockRequest, MockResponse>()
        let request = MockRequest(command: "test", value: 42)

        // Simulate async write and response
        Task {
            try await Task.sleep(for: .milliseconds(10))

            // Simulate response from Python process
            let response = MockResponse(
                messageId: request.messageId,
                success: true,
                result: 42,
                type: nil,
                error: nil
            )

            let jsonData = try! JSONEncoder().encode(response)
            let jsonString = String(data: jsonData, encoding: .utf8)! + "\n"

            let responses = await bridge.handleStdout(Data(jsonString.utf8))
            for (messageId, response) in responses {
                await bridge.dispatchResponse(messageId: messageId, response: response)
            }
        }

        // Send request
        let response = try await bridge.sendRequest(
            request,
            messageId: request.messageId,
            timeout: .seconds(1),
            write: { _ in }
        )

        XCTAssertTrue(response.success)
        XCTAssertEqual(response.result, 42)
    }

    func testConcurrentRequests() async throws {
        let bridge = UnifiedProcessBridge<MockRequest, MockResponse>()

        // Create 10 concurrent requests
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<10 {
                group.addTask {
                    let request = MockRequest(command: "test", value: i)

                    // Simulate response
                    Task {
                        try await Task.sleep(for: .milliseconds(10))

                        let response = MockResponse(
                            messageId: request.messageId,
                            success: true,
                            result: i,
                            type: nil,
                            error: nil
                        )

                        let jsonData = try! JSONEncoder().encode(response)
                        let jsonString = String(data: jsonData, encoding: .utf8)! + "\n"

                        let responses = await bridge.handleStdout(Data(jsonString.utf8))
                        for (messageId, response) in responses {
                            await bridge.dispatchResponse(messageId: messageId, response: response)
                        }
                    }

                    // Send request
                    do {
                        let response = try await bridge.sendRequest(
                            request,
                            messageId: request.messageId,
                            timeout: .seconds(1),
                            write: { _ in }
                        )

                        XCTAssertTrue(response.success)
                        XCTAssertEqual(response.result, i)
                    } catch {
                        XCTFail("Request \(i) failed: \(error)")
                    }
                }
            }
        }
    }

    func testTimeout() async throws {
        let bridge = UnifiedProcessBridge<MockRequest, MockResponse>()
        let request = MockRequest(command: "test")

        // Don't send any response - should timeout
        do {
            _ = try await bridge.sendRequest(
                request,
                messageId: request.messageId,
                timeout: .milliseconds(100),
                write: { _ in }
            )
            XCTFail("Should have timed out")
        } catch {
            // Expected timeout
            XCTAssertTrue(error is PythonError)
        }
    }

    func testBufferOverflowHandling() async throws {
        let bridge = UnifiedProcessBridge<MockRequest, MockResponse>()

        // Create 11MB of data (exceeds 10MB limit)
        let largeData = Data(repeating: 0x41, count: 11 * 1024 * 1024)

        // Should not crash, should keep most recent data
        let responses = await bridge.handleStdout(largeData)

        // Verify bridge is still functional
        XCTAssertEqual(responses.count, 0) // No valid JSON in large data

        // Verify we can still process valid responses
        let request = MockRequest(command: "test")
        let response = MockResponse(
            messageId: request.messageId,
            success: true,
            result: nil,
            type: nil,
            error: nil
        )

        let jsonData = try! JSONEncoder().encode(response)
        let jsonString = String(data: jsonData, encoding: .utf8)! + "\n"

        let validResponses = await bridge.handleStdout(Data(jsonString.utf8))
        XCTAssertEqual(validResponses.count, 1)
    }

    func testCancellation() async throws {
        let bridge = UnifiedProcessBridge<MockRequest, MockResponse>()

        // Cancel all pending requests
        await bridge.cancelAll(error: PythonError.processTerminated)

        // Verify no pending requests
        let count = await bridge.pendingCount
        XCTAssertEqual(count, 0)
    }

    func testFIFOMode() async throws {
        let bridge = UnifiedProcessBridge<MockRequest, MockResponse>()
        let request = MockRequest(command: "test")

        // Simulate FIFO response (no messageId)
        Task {
            try await Task.sleep(for: .milliseconds(10))

            let response = MockResponse(
                messageId: nil,
                success: true,
                result: 99,
                type: nil,
                error: nil
            )

            await bridge.dispatchResponseFIFO(response)
        }

        // Send request in FIFO mode
        let response = try await bridge.sendRequestFIFO(
            request,
            timeout: .seconds(1),
            write: { _ in }
        )

        XCTAssertTrue(response.success)
        XCTAssertEqual(response.result, 99)
    }
}

// MARK: - ProgressAwareBridge Tests

final class ProgressAwareBridgeTests: XCTestCase {

    func testProgressUpdates() async throws {
        let bridge = ProgressAwareBridge<MockRequest, MockResponse>()
        let request = MockRequest(command: "generate")

        var progressCount = 0
        let progressExpectation = expectation(description: "Progress updates")
        progressExpectation.expectedFulfillmentCount = 3

        // Simulate progress + final response
        Task {
            try await Task.sleep(for: .milliseconds(10))

            // Send 3 progress updates
            for i in 1...3 {
                let progress = MockResponse(
                    messageId: request.messageId,
                    success: true,
                    result: i * 33,
                    type: "progress",
                    error: nil
                )

                await bridge.dispatchResponse(
                    messageId: request.messageId,
                    response: progress,
                    isProgress: true,
                    isFinal: false
                )

                try await Task.sleep(for: .milliseconds(10))
            }

            // Send final response
            let final = MockResponse(
                messageId: request.messageId,
                success: true,
                result: 100,
                type: "complete",
                error: nil
            )

            await bridge.dispatchResponse(
                messageId: request.messageId,
                response: final,
                isProgress: false,
                isFinal: true
            )
        }

        // Send request with progress callback
        let response = try await bridge.sendRequest(
            request,
            messageId: request.messageId,
            idleTimeout: .seconds(1),
            write: { _ in },
            onProgress: { progress in
                progressCount += 1
                progressExpectation.fulfill()
            },
            onActivityDetected: { _ in }
        )

        await fulfillment(of: [progressExpectation], timeout: 1)

        XCTAssertTrue(response.success)
        XCTAssertEqual(response.result, 100)
        XCTAssertEqual(progressCount, 3)
    }

    func testIdleTimeout() async throws {
        let bridge = ProgressAwareBridge<MockRequest, MockResponse>()
        let request = MockRequest(command: "test")

        // Send initial activity, then stop
        Task {
            try await Task.sleep(for: .milliseconds(10))

            let progress = MockResponse(
                messageId: request.messageId,
                success: true,
                result: 50,
                type: "progress",
                error: nil
            )

            await bridge.dispatchResponse(
                messageId: request.messageId,
                response: progress,
                isProgress: true,
                isFinal: false
            )

            // Don't send final response - should idle timeout
        }

        do {
            _ = try await bridge.sendRequest(
                request,
                messageId: request.messageId,
                idleTimeout: .milliseconds(200),
                write: { _ in },
                onProgress: nil,
                onActivityDetected: { _ in }
            )
            XCTFail("Should have timed out")
        } catch {
            // Expected idle timeout
            XCTAssertTrue(error is PythonError)
        }
    }
}

// MARK: - ProgressRateLimiter Tests

final class ProgressRateLimiterTests: XCTestCase {

    func testRateLimiting() async throws {
        let limiter = ProgressRateLimiter(minInterval: 0.1)

        // First emission should succeed
        let first = await limiter.shouldEmit()
        XCTAssertTrue(first)

        // Immediate second emission should fail
        let second = await limiter.shouldEmit()
        XCTAssertFalse(second)

        // After 100ms, should succeed again
        try await Task.sleep(for: .milliseconds(110))
        let third = await limiter.shouldEmit()
        XCTAssertTrue(third)
    }

    func testReset() async throws {
        let limiter = ProgressRateLimiter(minInterval: 0.1)

        _ = await limiter.shouldEmit()

        // Should fail without reset
        let beforeReset = await limiter.shouldEmit()
        XCTAssertFalse(beforeReset)

        // Reset
        await limiter.reset()

        // Should succeed after reset
        let afterReset = await limiter.shouldEmit()
        XCTAssertTrue(afterReset)
    }
}
