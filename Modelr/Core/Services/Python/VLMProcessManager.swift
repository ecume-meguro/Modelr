import os.log
import Foundation

/// Manages the persistent VLM Python server process for object detection
class VLMProcessManager {
    private var process: Process?
    private(set) var stdinPipe: Pipe?
    private var stdoutPipe: Pipe?
    private var stderrPipe: Pipe?

    var onStdoutData: ((Data) -> Void)?
    var onStderrLine: ((String) -> Void)?

    // Unified actor-based communication - no NSLocks, no race conditions
    private let bridge = UnifiedProcessBridge<VLMRequest, VLMResponse>()

    var isRunning: Bool {
        process?.isRunning ?? false
    }

    var processID: Int32? {
        process?.processIdentifier
    }

    /// Start the persistent VLM server
    func startServer(uvPath: String) throws {
        guard !isRunning else {
            ErrorReporter.debug("Server already running", subsystem: .python)
            return
        }

        // Use unified inference project for all inference scripts (SAM, VLM, T2I)
        let inferenceProjectDir = PathManager.inferenceProjectDirectory
        let inferenceVenv = PathManager.inferenceVenvDirectory
        let vlmScript = PathManager.vlmWrapperPath.path

        process = Process()
        process?.executableURL = URL(fileURLWithPath: uvPath)
        process?.arguments = [
            "run", "--project", inferenceProjectDir.path, vlmScript,
            "--server"
        ]
        process?.currentDirectoryURL = inferenceProjectDir

        process?.environment = PythonEnvConfig.inferenceEnvironment(venvPath: inferenceVenv)

        stdinPipe = Pipe()
        stdoutPipe = Pipe()
        stderrPipe = Pipe()

        process?.standardInput = stdinPipe
        process?.standardOutput = stdoutPipe
        process?.standardError = stderrPipe

        // Handle stdout - JSON responses
        stdoutPipe?.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            self?.handleStdoutData(data)
        }

        // Handle stderr - logs
        stderrPipe?.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty,
                  let output = String(data: data, encoding: .utf8) else { return }

            for line in output.components(separatedBy: .newlines) {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty else { continue }
                self?.onStderrLine?(trimmed)
            }
        }

        // Set up termination handler to cancel all pending requests
        process?.terminationHandler = { [weak self] terminatedProcess in
            ErrorReporter.warning("Process terminated unexpectedly (exit code: \(terminatedProcess.terminationStatus))", subsystem: .python)
            Task {
                await self?.bridge.cancelAll(error: PythonError.processTerminated)
            }
        }

        try process?.run()

        // Register for cleanup on app termination
        if let pid = process?.processIdentifier {
            ProcessCleanup.shared.registerProcess(pid)
            ErrorReporter.info("VLM server started with PID \(pid)", subsystem: .python)
        }
    }

    /// Stop the server asynchronously (non-blocking)
    func stopServer() {
        guard let proc = process else { return }
        let pid = proc.processIdentifier

        // Unregister from cleanup
        ProcessCleanup.shared.unregisterProcess(pid)

        // Cancel all pending requests asynchronously
        Task {
            await bridge.cancelAll(error: PythonError.workerNotRunning)
        }

        // Clear handlers before stopping
        stdoutPipe?.fileHandleForReading.readabilityHandler = nil
        stderrPipe?.fileHandleForReading.readabilityHandler = nil
        proc.terminationHandler = nil

        // Use shared process utilities for clean shutdown
        ProcessUtilities.stopProcess(proc, stdinPipe: stdinPipe)

        process = nil
        stdinPipe = nil
        stdoutPipe = nil
        stderrPipe = nil

        ErrorReporter.info("VLM server stopped", subsystem: .python)
    }

    // MARK: - Communication

    private func handleStdoutData(_ data: Data) {
        Task {
            // Parse responses using bridge
            let responses = await bridge.handleStdout(data)

            // Dispatch all parsed responses
            for (messageId, response) in responses {
                ErrorReporter.debug("Received response for \(messageId)", subsystem: .python)
                await bridge.dispatchResponse(messageId: messageId, response: response)
            }
        }
    }

    /// Wait for the ready signal from the server
    func waitForReady(timeout: TimeInterval) async throws -> VLMResponse {
        // The Python server broadcasts ready with messageId "READY"
        let readyMessageId = "READY"
        let request = VLMRequest(command: "ready")
        guard stdinPipe?.fileHandleForWriting != nil else {
            throw PythonError.workerNotRunning
        }

        return try await bridge.sendRequest(
            request,
            messageId: readyMessageId,
            timeout: .seconds(Int64(timeout)),
            write: { data in
                // Don't actually send - just wait for server's ready broadcast
            }
        )
    }

    /// Send a request and wait for the response
    func sendRequest(_ request: VLMRequest, timeout: TimeInterval = 60) async throws -> VLMResponse {
        guard let stdin = stdinPipe?.fileHandleForWriting else {
            throw PythonError.workerNotRunning
        }

        ErrorReporter.debug("Request: \(request.command)", subsystem: .python)

        return try await bridge.sendRequest(
            request,
            messageId: request.messageId,
            timeout: .seconds(Int64(timeout)),
            write: { data in
                try stdin.write(contentsOf: data)
            }
        )
    }

    /// Describe an image - returns the detected object name
    func describeImage(imagePath: String) async throws -> String {
        let request = VLMRequest(command: "describe", imagePath: imagePath)
        let response = try await sendRequest(request)

        guard response.success, let description = response.description else {
            throw PythonError.predictionFailed(response.error ?? "Failed to describe image")
        }

        return description
    }

    /// Generate a short descriptive project name for an image
    func generateProjectName(imagePath: String) async throws -> String {
        let request = VLMRequest(command: "name", imagePath: imagePath)
        let response = try await sendRequest(request)

        guard response.success, let name = response.description else {
            throw PythonError.predictionFailed(response.error ?? "Failed to generate project name")
        }

        return name
    }

    /// Send a ping to check if the server is responsive
    func ping() async throws -> Bool {
        let request = VLMRequest(command: "ping")
        let response = try await sendRequest(request)
        return response.success && response.status == "pong"
    }

    deinit {
        // CRITICAL: deinit must be fast and non-blocking
        // Use ProcessCleanup for guaranteed cleanup with proper tracking
        guard let proc = process else { return }
        let pid = proc.processIdentifier

        // Clear handlers synchronously to prevent callbacks after deallocation
        stdoutPipe?.fileHandleForReading.readabilityHandler = nil
        stderrPipe?.fileHandleForReading.readabilityHandler = nil
        proc.terminationHandler = nil

        // Register with ProcessCleanup if not already registered (defensive)
        // ProcessCleanup.shared handles the actual termination
        ProcessCleanup.shared.registerProcess(pid)

        // Send terminate signal synchronously (fast, non-blocking)
        proc.terminate()

        // ProcessCleanup.shared.killAllPythonProcesses() will handle SIGKILL
        // during app termination if process doesn't exit cleanly
    }
}
