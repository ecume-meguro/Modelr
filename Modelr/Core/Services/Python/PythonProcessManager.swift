import os.log
import Foundation

/// Manages the lifecycle of Python worker processes
class PythonProcessManager {
    private(set) var persistentProcess: Process?
    private(set) var stdinPipe: Pipe?
    private(set) var stdoutPipe: Pipe?
    private(set) var currentGenerationProcess: Process?

    var selectedModel = "base_plus"
    var isGenerationCancelled = false

    // Callbacks
    var onStdoutData: ((Data) -> Void)?
    var onProcessReady: (() -> Void)?

    init() {
    }

    // MARK: - Persistent Worker (SAM)

    func startPersistentWorker(uvPath: String) throws {
        guard persistentProcess == nil else {
            ErrorReporter.debug("Persistent worker already running", subsystem: .python)
            return
        }

        // Use unified inference project for all inference scripts (SAM, VLM, T2I)
        let inferenceProjectDir = PathManager.inferenceProjectDirectory
        let scriptPath = PathManager.samWrapperPath.path
        let inferenceVenv = PathManager.inferenceVenvDirectory
        let outputDir = PathManager.outputsImagesDirectory

        let process = Process()
        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()

        process.executableURL = URL(fileURLWithPath: uvPath)
        let checkpointPath = PathManager.modelsDirectory.appendingPathComponent("sam3/model.safetensors")
        process.arguments = [
            "run", "--project", inferenceProjectDir.path, scriptPath,
            "--server",
            "--model", selectedModel,
            "--output-dir", outputDir.path,
            "--checkpoint", checkpointPath.path
        ]
        process.currentDirectoryURL = inferenceProjectDir

        process.environment = PythonEnvConfig.inferenceEnvironment(venvPath: inferenceVenv)

        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr

        // Handle stderr - use [weak self] to match stdout handler pattern and prevent retain cycles
        stderr.fileHandleForReading.readabilityHandler = { [weak self] handle in
            guard self != nil else { return }  // Early exit if self is deallocated
            let data = handle.availableData
            if let line = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines), !line.isEmpty {
                ErrorReporter.debug(line, subsystem: .python)
            }
        }

        // Handle stdout
        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            self?.onStdoutData?(data)
        }

        try process.run()

        self.persistentProcess = process
        self.stdinPipe = stdin
        self.stdoutPipe = stdout

        // Register for cleanup on app termination
        ProcessCleanup.shared.registerProcess(process.processIdentifier)

        ErrorReporter.info("Persistent worker started with PID \(process.processIdentifier)", subsystem: .python)
    }

    func stopPersistentWorker() {
        // Clear ALL readability handlers FIRST before closing pipes
        // This prevents handlers from being called during/after pipe closure
        stdoutPipe?.fileHandleForReading.readabilityHandler = nil

        // Also need to clear the stderr handler that was set during startPersistentWorker
        // The stderr pipe is local to startPersistentWorker, but we need to track it
        // For now, get the stderr from the process if available
        if let process = persistentProcess,
           let stderrPipe = process.standardError as? Pipe {
            stderrPipe.fileHandleForReading.readabilityHandler = nil
        }

        // Now safe to close stdin
        stdinPipe?.fileHandleForWriting.closeFile()

        if let process = persistentProcess {
            let pid = process.processIdentifier
            ProcessCleanup.shared.unregisterProcess(pid)

            if process.isRunning {
                ProcessUtilities.terminateProcessTree(pid)
            }
        }

        persistentProcess = nil
        stdinPipe = nil
        stdoutPipe = nil

        ErrorReporter.info("Persistent worker stopped", subsystem: .python)
    }

    var isWorkerRunning: Bool {
        persistentProcess?.isRunning == true
    }

    // MARK: - 3D Generation Process (Hunyuan)

    func start3DGeneration(
        uvPath: String,
        imagePath: String,
        maskPath: String,
        outputPath: URL,
        steps: Int,
        resolution: Int,
        modelVariant: String = "std",
        progressCallback: @escaping (String) -> Void,
        completion: @escaping (Result<URL, Error>) -> Void
    ) {
        let hunyuanDir = PathManager.hunyuanProjectDirectory
        let hunyuanVenv = PathManager.hunyuanVenvDirectory
        let hunyuanScript = PathManager.hunyuanWrapperPath.path

        isGenerationCancelled = false

        let process = Process()
        currentGenerationProcess = process
        process.executableURL = URL(fileURLWithPath: uvPath)

        var args = [
            "run", "--project", hunyuanDir.path, hunyuanScript,
            "--image", imagePath,
            "--output", outputPath.path,
            "--model", modelVariant,
            "--steps", "\(steps)",
            "--resolution", "\(resolution)"
        ]

        if !maskPath.isEmpty {
            args.insert(contentsOf: ["--mask", maskPath], at: 4)
        }

        process.arguments = args
        process.currentDirectoryURL = hunyuanDir

        process.environment = PythonEnvConfig.hunyuanEnvironment(venvPath: hunyuanVenv)

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard let output = String(data: data, encoding: .utf8) else { return }
            
            let lines = output.components(separatedBy: .newlines)
            for line in lines {
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { continue }
                
                ErrorReporter.debug(trimmed, subsystem: .generation)
                progressCallback(trimmed)
            }
        }

        do {
            try process.run()
            // Register for cleanup on app termination
            ProcessCleanup.shared.registerProcess(process.processIdentifier)
        } catch {
            pipe.fileHandleForReading.readabilityHandler = nil
            completion(.failure(error))
            return
        }

        Task.detached { [weak self] in
            process.waitUntilExit()
            pipe.fileHandleForReading.readabilityHandler = nil

            // Unregister since process has exited
            ProcessCleanup.shared.unregisterProcess(process.processIdentifier)

            await MainActor.run {
                self?.currentGenerationProcess = nil
            }

            let wasCancelled = self?.isGenerationCancelled ?? false

            if wasCancelled {
                completion(.failure(PythonError.predictionFailed("Generation cancelled")))
                return
            }

            if process.terminationStatus == 0 && PathManager.fileExists(at: outputPath) {
                completion(.success(outputPath))
            } else {
                completion(.failure(PythonError.predictionFailed("3D generation failed")))
            }
        }
    }

    func cancelGeneration() {
        guard let process = currentGenerationProcess, process.isRunning else {
            return
        }

        isGenerationCancelled = true
        let pid = process.processIdentifier

        // Use shared utilities for clean process tree termination
        ProcessUtilities.terminateProcessTree(pid)

        ProcessCleanup.shared.unregisterProcess(pid)
        currentGenerationProcess = nil
    }
}
