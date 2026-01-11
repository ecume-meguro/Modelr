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
            print("Persistent worker already running")
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
        process.arguments = [
            "run", "--project", inferenceProjectDir.path, scriptPath,
            "--server",
            "--model", selectedModel,
            "--output-dir", outputDir.path
        ]
        process.currentDirectoryURL = inferenceProjectDir

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
                // Find and kill all child processes first (uv spawns Python in separate group)
                let children = Self.findChildProcesses(pid)
                for childPid in children.reversed() {
                    print("[SAM] Killing child PID \(childPid)")
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
                    usleep(50_000)
                    kill(-pgid, SIGKILL)
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

        // Find and kill all child processes first (uv spawns Python in separate group)
        let children = Self.findChildProcesses(pid)
        for childPid in children.reversed() {
            print("[Generation] Killing child PID \(childPid)")
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
            usleep(50_000)
            kill(-pgid, SIGKILL)
        }

        process.terminate()
        kill(pid, SIGKILL)

        ProcessCleanup.shared.unregisterProcess(pid)
        currentGenerationProcess = nil
    }
}
