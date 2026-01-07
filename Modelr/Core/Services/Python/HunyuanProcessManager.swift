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

        try process?.run()
        print("[Hunyuan] Server started with PID \(process?.processIdentifier ?? -1)")
    }

    /// Stop the server
    func stopServer() {
        guard isRunning else { return }

        // Try graceful exit first
        if let stdin = stdinPipe?.fileHandleForWriting {
            let exitCommand = "{\"command\":\"exit\"}\n"
            try? stdin.write(contentsOf: Data(exitCommand.utf8))
        }

        // Give it a moment to exit gracefully
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) { [weak self] in
            if self?.isRunning == true {
                self?.process?.terminate()
            }
        }

        stdoutPipe?.fileHandleForReading.readabilityHandler = nil
        stderrPipe?.fileHandleForReading.readabilityHandler = nil

        process = nil
        stdinPipe = nil
        stdoutPipe = nil
        stderrPipe = nil

        print("[Hunyuan] Server stopped")
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
            continuationLock.lock()
            pendingContinuations.append { data in
                do {
                    let response = try JSONDecoder().decode(HunyuanResponse.self, from: data)
                    continuation.resume(returning: response)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
            continuationLock.unlock()

            // Timeout handling
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [weak self] in
                self?.continuationLock.lock()
                if !(self?.pendingContinuations.isEmpty ?? true) {
                    _ = self?.pendingContinuations.removeFirst()
                    self?.continuationLock.unlock()
                    continuation.resume(throwing: PythonError.timeout)
                } else {
                    self?.continuationLock.unlock()
                }
            }
        }
    }

    /// Send a request and wait for the final response (ignoring progress updates)
    func sendRequest(_ request: HunyuanRequest, onProgress: ((HunyuanResponse) -> Void)? = nil) async throws -> HunyuanResponse {
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
            var completed = false

            func handleResponse(_ data: Data) {
                guard !completed else { return }

                do {
                    let response = try JSONDecoder().decode(HunyuanResponse.self, from: data)

                    // Check if this response matches our request
                    if response.messageId != request.messageId && response.type != nil {
                        // Might be for a different request, re-queue
                        return
                    }

                    if response.type == "progress" {
                        // Progress update - notify callback but keep waiting
                        onProgress?(response)
                        // Re-register for next response
                        self.continuationLock.lock()
                        self.pendingContinuations.append(handleResponse)
                        self.continuationLock.unlock()
                    } else {
                        // Complete or error - we're done
                        completed = true
                        continuation.resume(returning: response)
                    }
                } catch {
                    completed = true
                    continuation.resume(throwing: error)
                }
            }

            continuationLock.lock()
            pendingContinuations.append(handleResponse)
            continuationLock.unlock()
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
