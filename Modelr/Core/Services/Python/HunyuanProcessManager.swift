import os.log
import Foundation

/// Manages the persistent Hunyuan Python server process
class HunyuanProcessManager {
    private var process: Process?
    private(set) var stdinPipe: Pipe?
    private var stdoutPipe: Pipe?
    private var stderrPipe: Pipe?

    var onStdoutData: ((Data) -> Void)?
    var onStderrLine: ((String) -> Void)?

    // Unified actor-based communication - eliminates all locks and race conditions
    private let bridge = ProgressAwareBridge<HunyuanRequest, HunyuanResponse>()
    private let rateLimiter = ProgressRateLimiter(minInterval: 0.1) // 10 updates/sec max

    var isRunning: Bool {
        process?.isRunning ?? false
    }

    var processID: Int32? {
        process?.processIdentifier
    }

    /// Start the persistent Hunyuan server
    func startServer(uvPath: String, modelVariant: String) throws {
        guard !isRunning else {
            ErrorReporter.debug("Hunyuan server already running", subsystem: .python)
            return
        }

        let hunyuanDir = PathManager.hunyuanProjectDirectory
        let hunyuanVenv = PathManager.hunyuanVenvDirectory
        let hunyuanScript = PathManager.hunyuanWrapperPath.path

        process = Process()
        process?.executableURL = URL(fileURLWithPath: uvPath)
        process?.arguments = [
            "run", "--project", hunyuanDir.path, hunyuanScript,
            "--server",
            "--model", modelVariant
        ]
        process?.currentDirectoryURL = hunyuanDir

        process?.environment = PythonEnvConfig.hunyuanEnvironment(venvPath: hunyuanVenv)

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
        // Note: tqdm uses \r for in-place updates, so we split by both \n and \r
        stderrPipe?.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty,
                  let output = String(data: data, encoding: .utf8) else { return }

            // Split by both newlines and carriage returns to catch tqdm updates
            let separators = CharacterSet(charactersIn: "\n\r")
            for line in output.components(separatedBy: separators) {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty else { continue }
                self?.onStderrLine?(trimmed)
            }
        }

        // Set up termination handler to cancel all pending requests
        process?.terminationHandler = { [weak self] terminatedProcess in
            ErrorReporter.warning("Hunyuan process terminated unexpectedly (exit code: \(terminatedProcess.terminationStatus))", subsystem: .python)
            Task {
                await self?.bridge.cancelAll(error: PythonError.processTerminated)
            }
        }

        try process?.run()

        // Register for cleanup on app termination
        let processId = process?.processIdentifier ?? -1
        if processId > 0 {
            ProcessCleanup.shared.registerProcess(processId)
            ErrorReporter.info("Hunyuan server started with PID \(processId)", subsystem: .python)
        }
    }

    /// Cancel current generation.
    ///
    /// IMPORTANT: The Hunyuan server is started via `uv run ...`, so the `Process.processIdentifier`
    /// we see here is `uv`'s PID, not necessarily the Python process PID. Relying on a PID-named
    /// cancel file can therefore fail to cancel the actual generation.
    ///
    /// The server supports an explicit `{ "command": "cancel" }` message over stdin, which is
    /// reliable regardless of intermediate launcher processes.
    func cancelGeneration() {
        guard isRunning else { return }

        if let stdin = stdinPipe?.fileHandleForWriting {
            let cancelCommand = "{\"command\":\"cancel\"}\n"
            do {
                try stdin.write(contentsOf: Data(cancelCommand.utf8))
                ErrorReporter.info("Sent cancel command", subsystem: .generation)
            } catch {
                ErrorReporter.logError(error, subsystem: .generation, context: "Failed to send cancel command")
            }
        }

        // Back-compat fallback: cancel-file behavior (may not work via uv)
        if let pid = process?.processIdentifier {
            let cancelFile = "/tmp/modelr_cancel_\(pid)"
            FileManager.default.createFile(atPath: cancelFile, contents: nil)
        }
    }

    /// Stop the server asynchronously (non-blocking)
    func stopServer() {
        guard let proc = process else { return }
        let pid = proc.processIdentifier

        // Unregister from cleanup
        ProcessCleanup.shared.unregisterProcess(pid)

        // IMPORTANT: Cancel all pending requests FIRST, before clearing handlers
        // This ensures pending requests receive proper error notifications before
        // the communication channels are torn down
        Task {
            await bridge.cancelAll(error: PythonError.workerNotRunning)
        }

        // Clear termination handler to prevent double-cancellation
        proc.terminationHandler = nil

        // Clear I/O handlers AFTER initiating request cancellation
        // This prevents new responses from being processed while we're shutting down
        stdoutPipe?.fileHandleForReading.readabilityHandler = nil
        stderrPipe?.fileHandleForReading.readabilityHandler = nil

        // Use shared process utilities for clean shutdown
        ProcessUtilities.stopProcess(proc, stdinPipe: stdinPipe)

        process = nil
        stdinPipe = nil
        stdoutPipe = nil
        stderrPipe = nil

        ErrorReporter.info("Hunyuan server stopped", subsystem: .python)
    }

    // MARK: - Communication

    private func handleStdoutData(_ data: Data) {
        Task {
            // Parse responses using bridge
            let responses = await bridge.handleStdout(data)

            for (messageId, response) in responses {
                // Debug logging
                ErrorReporter.debug("Received response for \(messageId): type=\(response.type ?? "nil")", subsystem: .python)

                // Determine if this is progress or final
                let isProgress = response.type == "progress"
                let isFinal = response.type != "progress"

                // Dispatch with rate limiting for progress
                if isProgress {
                    let shouldEmit = await rateLimiter.shouldEmit()
                    if shouldEmit {
                        await bridge.dispatchResponse(messageId: messageId, response: response, isProgress: true, isFinal: false)
                    }
                } else {
                    await bridge.dispatchResponse(messageId: messageId, response: response, isProgress: false, isFinal: isFinal)
                }
            }
        }
    }

    /// Wait for the ready signal from the server
    func waitForReady(timeout: TimeInterval) async throws -> HunyuanResponse {
        // The Python server broadcasts ready with messageId "READY"
        let readyMessageId = "READY"

        guard stdinPipe?.fileHandleForWriting != nil else {
            throw PythonError.workerNotRunning
        }

        return try await bridge.sendRequest(
            HunyuanRequest(command: "ready"),
            messageId: readyMessageId,
            idleTimeout: .seconds(Int64(timeout)),
            write: { data in
                // Don't actually send - just wait for server's ready broadcast
            },
            onProgress: nil,
            onActivityDetected: { _ in }
        )
    }

    /// Send a request and wait for the final response
    /// Uses idle timeout - only times out if no progress received for `idleTimeout` seconds
    /// - Parameters:
    ///   - request: The request to send
    ///   - onProgress: Called when JSON progress is received from Python
    ///   - onActivity: Called when any activity is detected (can be called externally for stderr progress)
    ///   - idleTimeout: Seconds of no activity before timing out (default 5 minutes)
    func sendRequest(
        _ request: HunyuanRequest,
        onProgress: ((HunyuanResponse) -> Void)? = nil,
        onActivity: ((@escaping () -> Void) -> Void)? = nil,
        idleTimeout: TimeInterval = 300
    ) async throws -> HunyuanResponse {
        guard let stdin = stdinPipe?.fileHandleForWriting else {
            throw PythonError.workerNotRunning
        }

        ErrorReporter.debug("Request: \(request.command)", subsystem: .python)

        // Use unified progress-aware bridge - eliminates all manual tracking
        return try await bridge.sendRequest(
            request,
            messageId: request.messageId,
            idleTimeout: .seconds(Int64(idleTimeout)),
            write: { data in
                try stdin.write(contentsOf: data)
            },
            onProgress: onProgress,
            onActivityDetected: onActivity ?? { _ in }
        )
    }

    /// Send a ping to check if the server is responsive
    func ping() async throws -> Bool {
        let request = HunyuanRequest(command: "ping")
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
        // Don't call stopServer() - it blocks with waitUntilExit()
    }
}
