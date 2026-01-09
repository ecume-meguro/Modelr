import Foundation

/// Manages the persistent Hunyuan Python server process
class HunyuanProcessManager {
    private var process: Process?
    private(set) var stdinPipe: Pipe?
    private var stdoutPipe: Pipe?
    private var stderrPipe: Pipe?

    var onStdoutData: ((Data) -> Void)?
    var onStderrLine: ((String) -> Void)?

    private var responseBuffer = Data()
    private var pendingContinuations: [(Data) -> Void] = []
    private let continuationLock = NSLock()
    private let requestSemaphore = DispatchSemaphore(value: 1)

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

        try process?.run()

        // Register for cleanup on app termination
        if let pid = process?.processIdentifier {
            ProcessCleanup.shared.registerProcess(pid)
        }

        print("[Hunyuan] Server started with PID \(process?.processIdentifier ?? -1)")
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

    /// Stop the server synchronously, ensuring all child processes are killed
    func stopServer() {
        guard let proc = process else { return }
        let pid = proc.processIdentifier

        // Unregister from cleanup
        ProcessCleanup.shared.unregisterProcess(pid)

        // Try graceful exit first
        if let stdin = stdinPipe?.fileHandleForWriting {
            let exitCommand = "{\"command\":\"exit\"}\n"
            try? stdin.write(contentsOf: Data(exitCommand.utf8))
        }

        // Clear handlers before waiting
        stdoutPipe?.fileHandleForReading.readabilityHandler = nil
        stderrPipe?.fileHandleForReading.readabilityHandler = nil

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
        responseBuffer.append(data)

        while let newlineRange = responseBuffer.range(of: Data("\n".utf8)) {
            let lineData = responseBuffer.subdata(in: responseBuffer.startIndex..<newlineRange.lowerBound)
            responseBuffer.removeSubrange(responseBuffer.startIndex...newlineRange.lowerBound)

            guard let lineString = String(data: lineData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !lineString.isEmpty else { continue }

            // Skip non-JSON lines
            if !lineString.hasPrefix("{") || !lineString.hasSuffix("}") {
                print("[Hunyuan stdout] \(lineString)")
                continue
            }

            // Debug: Log received JSON (truncate if too long)
            let debugStr = lineString.count > 200 ? String(lineString.prefix(200)) + "..." : lineString
            print("[Hunyuan JSON] \(debugStr)")

            // Dispatch to all pending continuations (they'll filter by messageId)
            onStdoutData?(Data(lineString.utf8))

            continuationLock.lock()
            if !pendingContinuations.isEmpty {
                let continuation = pendingContinuations.removeFirst()
                continuationLock.unlock()
                continuation(Data(lineString.utf8))
            } else {
                continuationLock.unlock()
            }
        }
    }

    /// Wait for the ready signal from the server
    func waitForReady(timeout: TimeInterval) async throws -> HunyuanResponse {
        return try await withCheckedThrowingContinuation { continuation in
            // Use a class to track whether continuation has been resumed
            final class ResumeTracker { var resumed = false }
            let tracker = ResumeTracker()

            continuationLock.lock()
            pendingContinuations.append { [tracker] data in
                guard !tracker.resumed else { return }
                tracker.resumed = true
                do {
                    let response = try JSONDecoder().decode(HunyuanResponse.self, from: data)
                    continuation.resume(returning: response)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
            continuationLock.unlock()

            // Timeout handling
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [weak self, tracker] in
                self?.continuationLock.lock()
                guard !tracker.resumed else {
                    self?.continuationLock.unlock()
                    return
                }
                tracker.resumed = true
                // Remove our handler if still present
                self?.pendingContinuations.removeAll { _ in false } // Just unlock, handler was already consumed or will be ignored
                self?.continuationLock.unlock()
                continuation.resume(throwing: PythonError.timeout)
            }
        }
    }

    /// Send a request and wait for the final response (ignoring progress updates)
    /// Timeout is 10 minutes for long generation tasks
    func sendRequest(_ request: HunyuanRequest, onProgress: ((HunyuanResponse) -> Void)? = nil, timeout: TimeInterval = 600) async throws -> HunyuanResponse {
        requestSemaphore.wait()
        defer { requestSemaphore.signal() }

        guard let stdin = stdinPipe?.fileHandleForWriting else {
            throw PythonError.workerNotRunning
        }

        let jsonData = try JSONEncoder().encode(request)
        guard var jsonString = String(data: jsonData, encoding: .utf8) else {
            throw PythonError.encodingError
        }
        print("[Hunyuan Request] \(jsonString)")
        jsonString += "\n"

        try stdin.write(contentsOf: Data(jsonString.utf8))

        // For generate commands, we need to handle multiple progress responses
        // before getting the final complete/error response
        return try await withCheckedThrowingContinuation { continuation in
            // Use a class to track completion state safely across closures
            final class CompletionTracker {
                var completed = false
                let lock = NSLock()

                func tryComplete() -> Bool {
                    lock.lock()
                    defer { lock.unlock() }
                    if completed { return false }
                    completed = true
                    return true
                }

                var isCompleted: Bool {
                    lock.lock()
                    defer { lock.unlock() }
                    return completed
                }
            }
            let tracker = CompletionTracker()

            func handleResponse(_ data: Data) {
                guard !tracker.isCompleted else { return }

                do {
                    let response = try JSONDecoder().decode(HunyuanResponse.self, from: data)

                    // Check if this response matches our request
                    if response.messageId != request.messageId && response.type != nil {
                        // Might be for a different request, re-queue
                        return
                    }

                    if response.type == "progress" {
                        // Progress update - notify callback but keep waiting
                        print("[Hunyuan Progress] stage=\(response.stage ?? "nil") progress=\(response.progress ?? 0) detail=\(response.detail ?? "nil")")
                        onProgress?(response)
                        // Re-register for next response
                        self.continuationLock.lock()
                        self.pendingContinuations.append(handleResponse)
                        self.continuationLock.unlock()
                    } else {
                        // Complete or error - we're done
                        if tracker.tryComplete() {
                            continuation.resume(returning: response)
                        }
                    }
                } catch {
                    if tracker.tryComplete() {
                        continuation.resume(throwing: error)
                    }
                }
            }

            continuationLock.lock()
            pendingContinuations.append(handleResponse)
            continuationLock.unlock()

            // Timeout handling
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [tracker] in
                if tracker.tryComplete() {
                    continuation.resume(throwing: PythonError.timeout)
                }
            }
        }
    }

    /// Send a ping to check if the server is responsive
    func ping() async throws -> Bool {
        let request = HunyuanRequest(command: "ping")
        let response = try await sendRequest(request)
        return response.success && response.status == "pong"
    }

    deinit {
        stopServer()
    }
}
