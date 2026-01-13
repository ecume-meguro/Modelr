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
            print("[VLM] Server already running")
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

        var env = ProcessInfo.processInfo.environment
        env["UV_PROJECT_ENVIRONMENT"] = inferenceVenv.path
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
            print("[VLM] Process terminated unexpectedly (exit code: \(terminatedProcess.terminationStatus))")
            Task {
                await self?.bridge.cancelAll(error: PythonError.processTerminated)
            }
        }

        try process?.run()

        // Register for cleanup on app termination
        if let pid = process?.processIdentifier {
            ProcessCleanup.shared.registerProcess(pid)
        }

        let vlmPid = process?.processIdentifier ?? -1
        print("[VLM] Server started with PID \(vlmPid)")
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
                // Find and kill all child processes first
                let children = Self.findChildProcesses(pid)
                for childPid in children.reversed() {
                    print("[VLM] Killing child PID \(childPid)")
                    kill(childPid, SIGTERM)
                }

                if !children.isEmpty {
                    usleep(100_000) // 100ms for SIGTERM
                    for childPid in children.reversed() {
                        kill(childPid, SIGKILL)
                    }
                }

                // Also try process group
                let pgid = getpgid(pid)
                if pgid > 0 {
                    kill(-pgid, SIGTERM)
                    usleep(50_000) // 50ms
                    kill(-pgid, SIGKILL)
                }

                proc.terminate()
            }

            proc.waitUntilExit()
        }

        process = nil
        stdinPipe = nil
        stdoutPipe = nil
        stderrPipe = nil

        print("[VLM] Server stopped")
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

            // Dispatch all parsed responses
            for (messageId, response) in responses {
                print("[VLM] Received response for \(messageId)")
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

        print("[VLM Request] \(request.command)")

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
