import Foundation
import os.log

/// Manages the Text-to-Image Python server process for Stable Diffusion generation
actor T2IProcessManager {
    // MARK: - Types

    enum T2IError: LocalizedError {
        case notReady
        case serverNotRunning
        case generationFailed(String)
        case invalidResponse
        case timeout

        var errorDescription: String? {
            switch self {
            case .notReady: return "T2I server is not ready"
            case .serverNotRunning: return "T2I server is not running"
            case .generationFailed(let msg): return "T2I generation failed: \(msg)"
            case .invalidResponse: return "Invalid response from T2I server"
            case .timeout: return "T2I operation timed out"
            }
        }
    }

    struct GenerationResult {
        let imagePath: String
        let seed: Int
    }

    // MARK: - Properties

    private let logger = Logger(subsystem: "com.modelr.t2i", category: "T2IProcessManager")
    private var process: Process?
    private var stdin: FileHandle?
    private var stdout: FileHandle?
    private var stdoutBuffer = Data()
    private var isReady = false
    private var currentMessageId: String?
    private var responseHandler: ((Result<T2IResponse, Error>) -> Void)?
    private var progressHandler: ((String, Float, String) -> Void)?
    private var readSource: DispatchSourceRead?

    // MARK: - Lifecycle

    /// Start the T2I server
    func start(pythonPath: URL, wrapperPath: URL) async throws {
        guard process == nil else {
            logger.info("T2I server already running")
            return
        }

        logger.info("Starting T2I server...")

        let proc = Process()
        proc.executableURL = pythonPath
        proc.arguments = [wrapperPath.path, "--server"]
        proc.currentDirectoryURL = wrapperPath.deletingLastPathComponent()

        // Set environment
        var env = ProcessInfo.processInfo.environment
        env["PYTHONUNBUFFERED"] = "1"
        proc.environment = env

        // Setup pipes
        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()

        proc.standardInput = stdinPipe
        proc.standardOutput = stdoutPipe
        proc.standardError = stderrPipe

        self.stdin = stdinPipe.fileHandleForWriting
        self.stdout = stdoutPipe.fileHandleForReading
        self.process = proc

        // Handle stderr for logging
        stderrPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if !data.isEmpty, let text = String(data: data, encoding: .utf8) {
                Task { @MainActor in
                    print("[T2I stderr] \(text.trimmingCharacters(in: .whitespacesAndNewlines))")
                }
            }
        }

        // Setup async stdout reading
        setupStdoutReading(stdoutPipe.fileHandleForReading)

        // Handle termination
        proc.terminationHandler = { [weak self] process in
            Task { [weak self] in
                await self?.handleTermination(exitCode: process.terminationStatus)
            }
        }

        do {
            try proc.run()
            logger.info("T2I process started with PID \(proc.processIdentifier)")

            // Wait for ready signal - long timeout for initial model download (~6GB)
            try await waitForReady(timeout: 600.0)
            logger.info("T2I server is ready")

        } catch {
            logger.error("Failed to start T2I server: \(error.localizedDescription)")
            await cleanup()
            throw error
        }
    }

    /// Stop the server
    func stop() async {
        guard let proc = process, proc.isRunning else { return }

        logger.info("Stopping T2I server...")

        // Send exit command
        let exitCommand: [String: Any] = ["command": "exit"]
        if let data = try? JSONSerialization.data(withJSONObject: exitCommand) {
            try? stdin?.write(contentsOf: data + Data("\n".utf8))
        }

        // Wait briefly then terminate
        try? await Task.sleep(nanoseconds: 500_000_000)

        if proc.isRunning {
            proc.terminate()
        }

        await cleanup()
    }

    // MARK: - Generation

    /// Generate an image from a text prompt
    func generate(
        prompt: String,
        outputPath: String,
        negativePrompt: String = "",
        width: Int = 512,
        height: Int = 512,
        steps: Int = 20,
        guidanceScale: Float = 7.5,
        seed: Int? = nil,
        progressCallback: @escaping (String, Float, String) -> Void
    ) async throws -> GenerationResult {
        guard isReady else { throw T2IError.notReady }
        guard process?.isRunning == true else { throw T2IError.serverNotRunning }

        let messageId = UUID().uuidString
        currentMessageId = messageId
        progressHandler = progressCallback

        var request: [String: Any] = [
            "command": "generate",
            "messageId": messageId,
            "prompt": prompt,
            "outputPath": outputPath,
            "negativePrompt": negativePrompt,
            "width": width,
            "height": height,
            "steps": steps,
            "guidanceScale": guidanceScale
        ]

        if let seed = seed {
            request["seed"] = seed
        }

        return try await withCheckedThrowingContinuation { continuation in
            responseHandler = { result in
                switch result {
                case .success(let response):
                    if response.success, response.type == "complete",
                       let imagePath = response.imagePath {
                        continuation.resume(returning: GenerationResult(
                            imagePath: imagePath,
                            seed: response.seed ?? 0
                        ))
                    } else if response.type == "cancelled" {
                        continuation.resume(throwing: T2IError.generationFailed("Cancelled"))
                    } else {
                        continuation.resume(throwing: T2IError.generationFailed(response.error ?? "Unknown error"))
                    }
                case .failure(let error):
                    continuation.resume(throwing: error)
                }
            }

            sendCommand(request)
        }
    }

    /// Send a ping to check server health
    func ping() async throws -> Bool {
        guard process?.isRunning == true else { return false }

        let messageId = UUID().uuidString

        return try await withCheckedThrowingContinuation { continuation in
            responseHandler = { result in
                switch result {
                case .success(let response):
                    continuation.resume(returning: response.status == "pong")
                case .failure:
                    continuation.resume(returning: false)
                }
            }

            sendCommand(["command": "ping", "messageId": messageId])

            // Timeout after 5 seconds
            Task {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                self.responseHandler = nil
                continuation.resume(returning: false)
            }
        }
    }

    /// Cancel current generation
    func cancel() {
        sendCommand(["command": "cancel"])
    }

    // MARK: - Private

    private func setupStdoutReading(_ handle: FileHandle) {
        let fd = handle.fileDescriptor
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .global(qos: .userInitiated))

        source.setEventHandler { [weak self] in
            let data = handle.availableData
            guard !data.isEmpty else { return }

            Task { [weak self] in
                await self?.handleStdoutData(data)
            }
        }

        source.setCancelHandler {
            try? handle.close()
        }

        source.resume()
        readSource = source
    }

    private func handleStdoutData(_ data: Data) {
        stdoutBuffer.append(data)

        // Process complete lines
        while let newlineIndex = stdoutBuffer.firstIndex(of: UInt8(ascii: "\n")) {
            let lineData = stdoutBuffer.prefix(upTo: newlineIndex)
            stdoutBuffer.removeFirst(newlineIndex - stdoutBuffer.startIndex + 1)

            if let line = String(data: lineData, encoding: .utf8)?.trimmingCharacters(in: .whitespaces),
               !line.isEmpty {
                processJsonLine(line)
            }
        }
    }

    private func processJsonLine(_ line: String) {
        guard let data = line.data(using: .utf8),
              let response = try? JSONDecoder().decode(T2IResponse.self, from: data) else {
            logger.warning("Failed to parse T2I response: \(line)")
            return
        }

        // Handle ready signal
        if response.ready == true {
            isReady = true
            return
        }

        // Handle progress updates
        if response.type == "progress" {
            if let stage = response.stage, let progress = response.progress {
                progressHandler?(stage, progress, response.detail ?? "")
            }
            return
        }

        // Handle completion/error responses
        if response.type == "complete" || response.type == "error" || response.type == "cancelled" {
            responseHandler?(.success(response))
            responseHandler = nil
            progressHandler = nil
            currentMessageId = nil
        }
    }

    private func sendCommand(_ command: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: command) else {
            logger.error("Failed to serialize command")
            return
        }

        var payload = data
        payload.append(Data("\n".utf8))

        do {
            try stdin?.write(contentsOf: payload)
        } catch {
            logger.error("Failed to send command: \(error.localizedDescription)")
        }
    }

    private func waitForReady(timeout: TimeInterval) async throws {
        let startTime = Date()

        while !isReady {
            if Date().timeIntervalSince(startTime) > timeout {
                throw T2IError.timeout
            }

            if process?.isRunning != true {
                throw T2IError.serverNotRunning
            }

            try await Task.sleep(nanoseconds: 100_000_000)
        }
    }

    private func handleTermination(exitCode: Int32) {
        logger.info("T2I server terminated with exit code \(exitCode)")
        isReady = false

        if exitCode != 0 {
            responseHandler?(.failure(T2IError.generationFailed("Server exited with code \(exitCode)")))
        }

        responseHandler = nil
        progressHandler = nil
    }

    private func cleanup() async {
        readSource?.cancel()
        readSource = nil

        try? stdin?.close()
        stdin = nil
        stdout = nil
        process = nil
        isReady = false
        stdoutBuffer = Data()
        responseHandler = nil
        progressHandler = nil
        currentMessageId = nil
    }
}
