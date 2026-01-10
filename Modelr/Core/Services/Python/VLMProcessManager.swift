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

    /// Start the persistent VLM server
    func startServer(uvPath: String) throws {
        guard !isRunning else {
            print("[VLM] Server already running")
            return
        }

        let vlmDir = PathManager.vlmProjectDirectory
        let vlmVenv = PathManager.vlmVenvDirectory
        let vlmScript = PathManager.vlmWrapperPath.path

        process = Process()
        process?.executableURL = URL(fileURLWithPath: uvPath)
        process?.arguments = [
            "run", "--project", vlmDir.path, vlmScript,
            "--server"
        ]
        process?.currentDirectoryURL = vlmDir

        var env = ProcessInfo.processInfo.environment
        env["UV_PROJECT_ENVIRONMENT"] = vlmVenv.path
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

        try process?.run()

        // Register for cleanup on app termination
        if let pid = process?.processIdentifier {
            ProcessCleanup.shared.registerProcess(pid)
        }

        let vlmPid = process?.processIdentifier ?? -1
        print("[VLM] Server started with PID \(vlmPid)")
    }

    /// Stop the server synchronously
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
        responseBuffer.append(data)

        while let newlineRange = responseBuffer.range(of: Data("\n".utf8)) {
            let lineData = responseBuffer.subdata(in: responseBuffer.startIndex..<newlineRange.lowerBound)
            responseBuffer.removeSubrange(responseBuffer.startIndex...newlineRange.lowerBound)

            guard let lineString = String(data: lineData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !lineString.isEmpty else { continue }

            // Skip non-JSON lines
            if !lineString.hasPrefix("{") || !lineString.hasSuffix("}") {
                print("[VLM stdout] \(lineString)")
                continue
            }

            print("[VLM JSON] \(lineString)")

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
    func waitForReady(timeout: TimeInterval) async throws -> VLMResponse {
        return try await withCheckedThrowingContinuation { continuation in
            // Thread-safe tracker to prevent double-resume of continuation
            final class ResumeTracker: @unchecked Sendable {
                private let lock = NSLock()
                private var _resumed = false

                var resumed: Bool {
                    get { lock.lock(); defer { lock.unlock() }; return _resumed }
                    set { lock.lock(); defer { lock.unlock() }; _resumed = newValue }
                }
            }
            let tracker = ResumeTracker()

            continuationLock.lock()
            pendingContinuations.append { [tracker] data in
                guard !tracker.resumed else { return }
                tracker.resumed = true
                do {
                    let response = try JSONDecoder().decode(VLMResponse.self, from: data)
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
                // Remove pending continuation that hasn't been consumed yet
                if let strongSelf = self, !strongSelf.pendingContinuations.isEmpty {
                    strongSelf.pendingContinuations.removeFirst()
                }
                self?.continuationLock.unlock()
                continuation.resume(throwing: PythonError.timeout)
            }
        }
    }

    /// Send a request and wait for the response
    func sendRequest(_ request: VLMRequest, timeout: TimeInterval = 60) async throws -> VLMResponse {
        requestSemaphore.wait()
        defer { requestSemaphore.signal() }

        guard let stdin = stdinPipe?.fileHandleForWriting else {
            throw PythonError.workerNotRunning
        }

        let jsonData = try JSONEncoder().encode(request)
        guard var jsonString = String(data: jsonData, encoding: .utf8) else {
            throw PythonError.encodingError
        }
        print("[VLM Request] \(jsonString)")
        jsonString += "\n"

        try stdin.write(contentsOf: Data(jsonString.utf8))

        return try await withCheckedThrowingContinuation { continuation in
            // Thread-safe tracker to prevent double-resume of continuation
            final class CompletionTracker: @unchecked Sendable {
                private var _completed = false
                private let lock = NSLock()

                func tryComplete() -> Bool {
                    lock.lock()
                    defer { lock.unlock() }
                    if _completed { return false }
                    _completed = true
                    return true
                }

                var isCompleted: Bool {
                    lock.lock()
                    defer { lock.unlock() }
                    return _completed
                }
            }
            let tracker = CompletionTracker()

            continuationLock.lock()
            pendingContinuations.append { [tracker] data in
                guard tracker.tryComplete() else { return }
                do {
                    let response = try JSONDecoder().decode(VLMResponse.self, from: data)
                    continuation.resume(returning: response)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
            continuationLock.unlock()

            // Timeout handling
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [tracker] in
                if tracker.tryComplete() {
                    continuation.resume(throwing: PythonError.timeout)
                }
            }
        }
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

    /// Send a ping to check if the server is responsive
    func ping() async throws -> Bool {
        let request = VLMRequest(command: "ping")
        let response = try await sendRequest(request)
        return response.success && response.status == "pong"
    }

    deinit {
        stopServer()
    }
}
