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
            print("Persistent worker already running")
            return
        }

        let samProjectDir = PathManager.samProjectDirectory
        let scriptPath = PathManager.samWrapperPath.path
        let samVenv = PathManager.samEnvironmentDirectory.appendingPathComponent(AppConstants.venvDirectoryName, isDirectory: true)
        let outputDir = PathManager.outputsImagesDirectory

        let process = Process()
        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()

        process.executableURL = URL(fileURLWithPath: uvPath)
        process.arguments = [
            "run", "--project", samProjectDir.path, scriptPath,
            "--server",
            "--model", selectedModel,
            "--output-dir", outputDir.path
        ]
        process.currentDirectoryURL = samProjectDir

        var env = ProcessInfo.processInfo.environment
        env["UV_PROJECT_ENVIRONMENT"] = samVenv.path
        env["UV_PYTHON_INSTALL_DIR"] = PathManager.pythonRuntimesDirectory.path
        env["UV_CACHE_DIR"] = PathManager.uvCacheDirectory.path
        env["UV_PYTHON_PREFERENCE"] = "only-managed"
        env["UV_LINK_MODE"] = "copy"
        env["PYTHONUNBUFFERED"] = "1"
        env["HF_HOME"] = PathManager.modelsDirectory.path
        env["HUGGINGFACE_HUB_CACHE"] = PathManager.modelsHubDirectory.path
        env["TRANSFORMERS_CACHE"] = PathManager.modelsHubDirectory.path
        env["MODELR_CONFIG_PATH"] = PathManager.projectConfigPath.path
        env["MODELR_CONFIG_PATH"] = PathManager.projectConfigPath.path
        env["MODELR_OUTPUTS_DIR"] = PathManager.outputsDirectory.path
        env["MODELR_WORKING_DIR"] = PathManager.workingDirectory.path
        env["MODELR_LOGS_DIR"] = PathManager.logsDirectory.path
        env["MODELR_CHECKPOINTS_DIR"] = PathManager.checkpointsDirectory.path
        env["PYTHONPATH"] = [
            PathManager.libPythonDirectory.path,
            PathManager.libPythonDirectory.appendingPathComponent("modelr_core", isDirectory: true).path,
            PathManager.libPythonDirectory.appendingPathComponent("mlx-sam3", isDirectory: true).path
        ].joined(separator: ":")
        process.environment = env

        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr

        // Handle stderr
        stderr.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if let line = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines), !line.isEmpty {
                print("[Python stderr] \(line)")
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

        print("Persistent worker started with PID \(process.processIdentifier)")
    }

    func stopPersistentWorker() {
        stdinPipe?.fileHandleForWriting.closeFile()
        stdoutPipe?.fileHandleForReading.readabilityHandler = nil

        if let process = persistentProcess {
            let pid = process.processIdentifier
            ProcessCleanup.shared.unregisterProcess(pid)

            if process.isRunning {
                // Kill the process group to ensure Python children are also killed
                let pgid = getpgid(pid)
                if pgid > 0 {
                    kill(-pgid, SIGTERM)
                }
                process.terminate()
                process.waitUntilExit()
            }
        }

        persistentProcess = nil
        stdinPipe = nil
        stdoutPipe = nil

        print("Persistent worker stopped")
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
        env["MODELR_CONFIG_PATH"] = PathManager.projectConfigPath.path
        env["MODELR_OUTPUTS_DIR"] = PathManager.outputsDirectory.path
        env["MODELR_WORKING_DIR"] = PathManager.workingDirectory.path
        env["MODELR_LOGS_DIR"] = PathManager.logsDirectory.path
        env["MODELR_CHECKPOINTS_DIR"] = PathManager.checkpointsDirectory.path
        env["PYTHONPATH"] = [
            PathManager.libPythonDirectory.path,
            PathManager.libPythonDirectory.appendingPathComponent("modelr_core", isDirectory: true).path,
            PathManager.libPythonDirectory.appendingPathComponent("mlx-sam3", isDirectory: true).path
        ].joined(separator: ":")
        process.environment = env

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
                
                print("[Hunyuan] \(trimmed)")
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

        // Kill the process group to ensure Python children are also killed
        let pgid = getpgid(pid)
        if pgid > 0 {
            kill(-pgid, SIGTERM)
        }

        process.terminate()
        kill(pid, SIGKILL)

        ProcessCleanup.shared.unregisterProcess(pid)
        currentGenerationProcess = nil
    }
}
