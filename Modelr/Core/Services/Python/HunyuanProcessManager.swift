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
            print("[Hunyuan] Server already running")
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

        var env = ProcessInfo.processInfo.environment
        env["UV_PROJECT_ENVIRONMENT"] = hunyuanVenv.path
        env["UV_PYTHON_INSTALL_DIR"] = PathManager.pythonRuntimesDirectory.path
        env["UV_CACHE_DIR"] = PathManager.uvCacheDirectory.path
        env["UV_PYTHON_PREFERENCE"] = "only-managed"
        env["UV_LINK_MODE"] = "copy"
        env["PYTHONUNBUFFERED"] = "1"
        env["HF_HOME"] = PathManager.modelsDirectory.path
        env["HUGGINGFACE_HUB_CACHE"] = PathManager.modelsHubDirectory.path
        env["TRANSFORMERS_CACHE"] = PathManager.modelsHubDirectory.path
        env["MODELR_CONFIG_PATH"] = PathManager.projectConfigPath.path
        env["MODELR_OUTPUTS_DIR"] = PathManager.outputsDirectory.path
        env["MODELR_WORKING_DIR"] = PathManager.workingDirectory.path
        env["MODELR_LOGS_DIR"] = PathManager.logsDirectory.path
        env["MODELR_CHECKPOINTS_DIR"] = PathManager.checkpointsDirectory.path
        env["PYTHONPATH"] = [
            PathManager.libPythonDirectory.path,
            PathManager.libPythonDirectory.appendingPathComponent("modelr_core", isDirectory: true).path
        ].joined(separator: ":")
        process?.environment = env

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
            print("[Hunyuan] Process terminated unexpectedly (exit code: \(terminatedProcess.terminationStatus))")
            Task {
                await self?.bridge.cancelAll(error: PythonError.processTerminated)
            }
        }

        try process?.run()

        // Register for cleanup on app termination
        let processId = process?.processIdentifier ?? -1
        if processId > 0 {
            ProcessCleanup.shared.registerProcess(processId)
        }

        print("[Hunyuan] Server started with PID \(processId)")
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
                print("[Hunyuan] Sent cancel command over stdin")
            } catch {
                print("[Hunyuan] Failed to send cancel command: \(error)")
            }
        }

        // Back-compat fallback: keep the cancel-file behavior as well.
        // This may not work when launched via uv (PID mismatch), but is harmless.
        if let pid = process?.processIdentifier {
            let cancelFile = "/tmp/modelr_cancel_\(pid)"
            FileManager.default.createFile(atPath: cancelFile, contents: nil)
            print("[Hunyuan] Created cancel file: \(cancelFile)")
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

        // Try graceful exit first
        if let stdin = stdinPipe?.fileHandleForWriting {
            let exitCommand = "{\"command\":\"exit\"}\n"
            try? stdin.write(contentsOf: Data(exitCommand.utf8))
        }

        // Clear handlers before waiting
        stdoutPipe?.fileHandleForReading.readabilityHandler = nil
        stderrPipe?.fileHandleForReading.readabilityHandler = nil
        // Clear termination handler to prevent double-resuming continuations
        proc.terminationHandler = nil

        // Give brief grace period for graceful exit
        if proc.isRunning {
            usleep(200_000) // 200ms grace period

            if proc.isRunning {
                // Find and kill all child processes first (uv spawns Python in separate group)
                let children = Self.findChildProcesses(pid)
                for childPid in children.reversed() {
                    print("[Hunyuan] Killing child PID \(childPid)")
                    kill(childPid, SIGTERM)
                }

                if !children.isEmpty {
                    usleep(100_000) // 100ms for SIGTERM
                    for childPid in children.reversed() {
                        kill(childPid, SIGKILL)
                    }
                }

                // Also try process group (may work for some processes)
                let pgid = getpgid(pid)
                if pgid > 0 {
                    kill(-pgid, SIGTERM)
                    usleep(50_000) // 50ms
                    kill(-pgid, SIGKILL)
                }

                proc.terminate()
            }

            // Wait for exit to ensure cleanup is complete before returning
            proc.waitUntilExit()
        }

        process = nil
        stdinPipe = nil
        stdoutPipe = nil
        stderrPipe = nil

        print("[Hunyuan] Server stopped")
    }

    /// Recursively find all child processes of a given PID
    private static func findChildProcesses(_ pid: pid_t) -> [pid_t] {
        var result: [pid_t] = []

        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        task.arguments = ["-P", "\(pid)"]

        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice

        do {
            try task.run()
            task.waitUntilExit()

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            if let output = String(data: data, encoding: .utf8) {
                let childPids = output.components(separatedBy: .newlines)
                    .compactMap { Int32($0.trimmingCharacters(in: .whitespaces)) }

                for childPid in childPids {
                    result.append(childPid)
                    result.append(contentsOf: findChildProcesses(childPid))
                }
            }
        } catch {
            // Ignore - process may have already exited
        }

        return result
    }

    // MARK: - Communication

    private func handleStdoutData(_ data: Data) {
        Task {
            // Parse responses using bridge
            let responses = await bridge.handleStdout(data)

            for (messageId, response) in responses {
                // Debug logging
                print("[Hunyuan] Received response for \(messageId): type=\(response.type ?? "nil")")

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

        print("[Hunyuan Request] \(request.command)")

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
        // Fire-and-forget termination without waiting
        let pid = process?.processIdentifier
        process?.terminate()

        // Forceful cleanup in background (don't block deinit)
        if let pid = pid {
            DispatchQueue.global().async {
                usleep(200_000)  // 200ms grace period
                kill(pid, SIGKILL)
            }
        }

        // Don't call stopServer() - it blocks with waitUntilExit()
    }
}
