import Foundation

/// Manages Python dependency installation and environment setup
class PythonDependencyService {
    private let fileManager = FileManager.default

    var cachedUvPath: String?
    var inferenceVenvReady = false
    var hunyuanVenvReady = false
    var resourcePathOverride: String?
    var processTracker: ProcessTracker?  // Optional tracker for cleanup

    // Legacy flags (deprecated - use inferenceVenvReady)
    var samVenvReady: Bool { inferenceVenvReady }
    var toolsVenvReady: Bool { inferenceVenvReady }
    var vlmVenvReady: Bool { inferenceVenvReady }

    init() {
        cachedUvPath = findUVExecutable()
    }

    // MARK: - Main Setup Flow

    func setup(
        modelChoice: SetupModelChoice = .fast,
        onProgress: @escaping (SetupProgressUpdate) -> Void
    ) async -> Bool {
        let report = { (stage: SetupStage, status: String, log: String?, isDetailed: Bool) in
            if !status.isEmpty {
                print("[Setup][\(stage.rawValue)] \(status)")
            }
            if let l = log { print("[Setup][\(stage.rawValue)] \(l)") }
            onProgress(SetupProgressUpdate(stage: stage, status: status, logLine: log, isDetailedLog: isDetailed))
        }

        report(.preparing, "Preparing resources...", nil, false)
        do {
            try PathManager.ensureAppSupportDirectoryExists()
            try PathManager.migrateLegacyLayoutIfNeeded()
        } catch {
            report(.failed, "Failed to prepare Application Support directories", error.localizedDescription, false)
            return false
        }

        copyResourceFiles()

        guard checkResources() else {
            report(.failed, "Critical resource files missing", nil, false)
            return false
        }

        guard let uvPath = cachedUvPath else {
            report(.failed, "uv binary not found", nil, false)
            return false
        }

        // 1. Unified Inference Environment (SAM + VLM + Tools)
        report(.syncingSAM, "Syncing inference environment...", nil, false)
        await setupInferenceEnvironment(uvPath: uvPath, onProgress: onProgress)
        guard inferenceVenvReady else {
            report(.failed, "Inference environment sync failed", nil, false)
            return false
        }

        // 2. Download SAM model
        report(.downloadingSAM, "Downloading segmentation model...", nil, false)
        guard await downloadAndVerifySAM(uvPath: uvPath, onProgress: onProgress) else {
            report(.failed, "SAM model download or verification failed", nil, false)
            return false
        }

        // 3. Download VLM model
        report(.downloadingSAM, "Downloading VLM model...", nil, false)
        guard await downloadVLMModel(uvPath: uvPath, onProgress: onProgress) else {
            report(.failed, "VLM model download or verification failed", nil, false)
            return false
        }

        // 4. 3D Generation (separate environment - requires Python 3.10)
        report(.syncingHunyuan, "Syncing 3D generation environment...", nil, false)
        await setupHunyuanEnvironment(uvPath: uvPath, onProgress: onProgress)
        guard hunyuanVenvReady else {
            report(.failed, "Hunyuan environment sync failed", nil, false)
            return false
        }

        report(.downloadingHunyuan, "Downloading 3D generation model (\(modelChoice.displayName))...", nil, false)
        guard await downloadHunyuanModel(uvPath: uvPath, variant: modelChoice.modelVariant, onProgress: onProgress) else {
            report(.failed, "Hunyuan model download failed", nil, false)
            return false
        }

        report(.completed, "Ready", nil, false)
        return true
    }

    // MARK: - Stage Implementations

    /// Sets up the unified inference environment (SAM + VLM + Tools)
    private func setupInferenceEnvironment(uvPath: String, onProgress: @escaping (SetupProgressUpdate) -> Void) async {
        let inferenceProjectDir = PathManager.inferenceProjectDirectory
        let inferenceVenvDir = PathManager.inferenceVenvDirectory
        do {
            try PathManager.ensureDirectoryExists(at: inferenceProjectDir)
            try PathManager.ensureDirectoryExists(at: PathManager.inferenceEnvironmentDirectory)
        } catch {
            onProgress(SetupProgressUpdate(stage: .failed, status: "Inference environment preparation failed", logLine: error.localizedDescription))
            return
        }

        inferenceVenvReady = await syncEnvironment(
            uvPath: uvPath,
            pythonVersion: "3.13",
            venvPath: inferenceVenvDir,
            workingDir: inferenceProjectDir,
            stage: .syncingSAM,
            onProgress: onProgress
        )
    }

    private func downloadAndVerifySAM(uvPath: String, onProgress: @escaping (SetupProgressUpdate) -> Void) async -> Bool {
        // Download SAM model using the unified downloader
        // SHA256 verification happens during download, so no need for separate model load test
        let downloaderPath = PathManager.sharedDirectory.appendingPathComponent(AppConstants.modelDownloaderFileName)
        let inferenceVenvDir = PathManager.inferenceVenvDirectory

        let downloadProcess = Process()
        downloadProcess.executableURL = URL(fileURLWithPath: uvPath)
        downloadProcess.arguments = ["run", "--python", "3.13", "--with", "requests", downloaderPath.path, "download", "--model", "sam3"]
        downloadProcess.currentDirectoryURL = PathManager.sharedDirectory
        downloadProcess.environment = createPythonEnvironment(venvPath: inferenceVenvDir, modelsHubDir: PathManager.modelsHubDirectory)

        return await runProcessSimple(downloadProcess, stage: .downloadingSAM, onProgress: onProgress)
    }

    private func downloadVLMModel(uvPath: String, onProgress: @escaping (SetupProgressUpdate) -> Void) async -> Bool {
        // Download VLM model using the unified downloader
        // SHA256 verification happens during download for large files
        let downloaderPath = PathManager.sharedDirectory.appendingPathComponent(AppConstants.modelDownloaderFileName)
        let inferenceVenvDir = PathManager.inferenceVenvDirectory

        let downloadProcess = Process()
        downloadProcess.executableURL = URL(fileURLWithPath: uvPath)
        downloadProcess.arguments = ["run", "--python", "3.13", "--with", "requests", downloaderPath.path, "download", "--model", "vlm"]
        downloadProcess.currentDirectoryURL = PathManager.sharedDirectory
        downloadProcess.environment = createPythonEnvironment(venvPath: inferenceVenvDir, modelsHubDir: PathManager.modelsHubDirectory)

        return await runProcessSimple(downloadProcess, stage: .downloadingSAM, onProgress: onProgress)
    }

    private func setupHunyuanEnvironment(uvPath: String, onProgress: @escaping (SetupProgressUpdate) -> Void) async {
        let hunyuanProjectDir = PathManager.hunyuanProjectDirectory
        do {
            try PathManager.ensureDirectoryExists(at: hunyuanProjectDir)
            try PathManager.ensureDirectoryExists(at: PathManager.hunyuanEnvironmentDirectory)
        } catch {
            onProgress(SetupProgressUpdate(stage: .failed, status: "Hunyuan preparation failed", logLine: error.localizedDescription))
            return
        }

        hunyuanVenvReady = await syncEnvironment(
            uvPath: uvPath,
            pythonVersion: "3.10",
            venvPath: PathManager.hunyuanVenvDirectory,
            workingDir: hunyuanProjectDir,
            stage: .syncingHunyuan,
            onProgress: onProgress
        )
    }

    private func downloadHunyuanModel(uvPath: String, variant: String, onProgress: @escaping (SetupProgressUpdate) -> Void) async -> Bool {
        // Map variant to model key for downloader
        let modelKey = "hunyuan-2mini"  // Only mini model supported

        let downloaderPath = PathManager.sharedDirectory.appendingPathComponent(AppConstants.modelDownloaderFileName)
        let inferenceVenvDir = PathManager.inferenceVenvDirectory

        let process = Process()
        process.executableURL = URL(fileURLWithPath: uvPath)
        process.arguments = ["run", "--python", "3.13", "--with", "requests", downloaderPath.path, "download", "--model", modelKey]
        process.currentDirectoryURL = PathManager.sharedDirectory
        process.environment = createPythonEnvironment(venvPath: inferenceVenvDir, modelsHubDir: PathManager.modelsHubDirectory)

        let success = await runProcessSimple(process, stage: .downloadingHunyuan, onProgress: onProgress)
        if success {
            UserDefaults.standard.set(variant, forKey: "SelectedHunyuanModel")
        }
        return success
    }

    /// Run a process, parsing JSON progress output and forwarding to onProgress.
    /// JSON lines (starting with {) are parsed for download progress.
    /// Non-JSON lines are logged and forwarded as log lines.
    /// Returns true if the process completed successfully (exit code 0).
    /// Includes timeout and stall detection for long-running downloads.
    @discardableResult
    private func runProcessSimple(
        _ process: Process,
        stage: SetupStage,
        timeoutMinutes: Int = 30,  // Default 30 minutes for downloads
        stallTimeoutMinutes: Int = 5,  // 5 minutes without output = stalled
        onProgress: @escaping (SetupProgressUpdate) -> Void
    ) async -> Bool {
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        let description = "\(process.executableURL?.lastPathComponent ?? "process") - \(stage.rawValue)"

        // Actor to safely track last activity time across threads
        actor ActivityTracker {
            private var lastActivityTime = Date()

            func recordActivity() {
                lastActivityTime = Date()
            }

            func timeSinceLastActivity() -> TimeInterval {
                return Date().timeIntervalSince(lastActivityTime)
            }
        }

        let activityTracker = ActivityTracker()

        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines), !output.isEmpty {
                // Record activity
                Task { await activityTracker.recordActivity() }

                // Process each line separately (output may contain multiple lines)
                for line in output.components(separatedBy: .newlines) where !line.isEmpty {
                    print("[Setup][\(stage.rawValue)] \(line)")

                    // Check if this is JSON progress output (from model_downloader.py)
                    if line.hasPrefix("{") && line.hasSuffix("}") {
                        // Pass the JSON line to the progress handler for parsing
                        onProgress(SetupProgressUpdate(stage: stage, status: "", logLine: line, isDetailedLog: true))
                    } else {
                        // Regular log line
                        onProgress(SetupProgressUpdate(stage: stage, status: line, logLine: line, isDetailedLog: false))
                    }
                }
            }
        }

        do {
            try process.run()
            processTracker?.track(process, description: description)

            let timeoutSeconds: UInt64 = UInt64(timeoutMinutes * 60)
            let stallTimeoutSeconds: TimeInterval = TimeInterval(stallTimeoutMinutes * 60)

            enum ProcessResult {
                case completed(Bool)
                case timeout
                case stalled
            }

            let result = await withTaskGroup(of: ProcessResult.self) { group -> ProcessResult in
                // Task 1: Wait for process to complete
                group.addTask {
                    await withCheckedContinuation { (cont: CheckedContinuation<ProcessResult, Never>) in
                        DispatchQueue.global(qos: .userInitiated).async {
                            process.waitUntilExit()
                            cont.resume(returning: .completed(process.terminationStatus == 0))
                        }
                    }
                }

                // Task 2: Absolute timeout
                group.addTask {
                    do {
                        try await Task.sleep(nanoseconds: timeoutSeconds * 1_000_000_000)
                        if process.isRunning {
                            process.terminate()
                        }
                        return .timeout
                    } catch {
                        return .completed(true)  // Task cancelled, process finished first
                    }
                }

                // Task 3: Stall detection (check every 30 seconds)
                group.addTask {
                    while !Task.isCancelled {
                        do {
                            try await Task.sleep(nanoseconds: 30 * 1_000_000_000)  // 30 seconds
                            let timeSinceActivity = await activityTracker.timeSinceLastActivity()
                            if timeSinceActivity > stallTimeoutSeconds && process.isRunning {
                                process.terminate()
                                return .stalled
                            }
                        } catch {
                            break  // Task cancelled
                        }
                    }
                    return .completed(true)  // Task cancelled, process finished first
                }

                // Wait for first result
                let firstResult = await group.next() ?? .completed(false)

                // Cancel remaining tasks
                group.cancelAll()

                return firstResult
            }

            pipe.fileHandleForReading.readabilityHandler = nil

            switch result {
            case .completed(let success):
                if !success {
                    print("[Setup][\(stage.rawValue)] Process exited with code \(process.terminationStatus)")
                    onProgress(SetupProgressUpdate(stage: .failed, status: "Process failed with exit code \(process.terminationStatus)", logLine: nil))
                }
                return success

            case .timeout:
                print("[Setup][\(stage.rawValue)] Process timed out after \(timeoutMinutes) minutes")
                onProgress(SetupProgressUpdate(
                    stage: .failed,
                    status: "Download timed out after \(timeoutMinutes) minutes",
                    logLine: "The operation took too long. Please check your network connection and try again."
                ))
                return false

            case .stalled:
                print("[Setup][\(stage.rawValue)] Process stalled - no activity for \(stallTimeoutMinutes) minutes")
                onProgress(SetupProgressUpdate(
                    stage: .failed,
                    status: "Download stalled - no activity for \(stallTimeoutMinutes) minutes",
                    logLine: "The download appears to have stopped. This may be due to network issues."
                ))
                return false
            }
        } catch {
            print("[Setup][\(stage.rawValue)] Process failed: \(error)")
            onProgress(SetupProgressUpdate(stage: .failed, status: "Process failed", logLine: error.localizedDescription))
            pipe.fileHandleForReading.readabilityHandler = nil
            return false
        }
    }

    // MARK: - Process Helpers

    private func syncEnvironment(uvPath: String, pythonVersion: String, venvPath: URL, workingDir: URL, stage: SetupStage, onProgress: @escaping (SetupProgressUpdate) -> Void) async -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: uvPath)
        process.arguments = ["sync", "--python", pythonVersion]
        process.currentDirectoryURL = workingDir

        var env = createPythonEnvironment(venvPath: venvPath, modelsHubDir: PathManager.modelsHubDirectory)
        env["UV_LINK_MODE"] = "copy"
        process.environment = env

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        // Track process for cleanup
        let description = "uv sync (Python \(pythonVersion)) - \(stage.rawValue)"

        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if let line = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines), !line.isEmpty {
                print("[Setup][\(stage.rawValue)] \(line)")
                let isDetailed = line.contains("Resolving") || line.contains("Installing") || line.contains("Built")
                onProgress(SetupProgressUpdate(stage: stage, status: isDetailed ? "Syncing dependencies..." : line, logLine: line, isDetailedLog: isDetailed))
            }
        }

        do {
            try process.run()
            processTracker?.track(process, description: description)

            // Wait for process with timeout using async/await pattern
            // This avoids race conditions from DispatchQueue.asyncAfter
            let timeoutSeconds: UInt64 = 600 // 10 minutes
            let result = await withTaskGroup(of: Bool.self) { group -> Bool in
                // Task 1: Wait for process to complete
                group.addTask {
                    await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
                        DispatchQueue.global(qos: .userInitiated).async {
                            process.waitUntilExit()
                            cont.resume(returning: process.terminationStatus == 0)
                        }
                    }
                }

                // Task 2: Timeout
                group.addTask {
                    do {
                        try await Task.sleep(nanoseconds: timeoutSeconds * 1_000_000_000)
                        // Timeout reached - terminate if still running
                        if process.isRunning {
                            process.terminate()
                        }
                        return false // Indicate timeout
                    } catch {
                        // Task was cancelled (process finished first)
                        return true
                    }
                }

                // Wait for first result
                let firstResult = await group.next() ?? false

                // Cancel remaining tasks
                group.cancelAll()

                // Check if it was a timeout (process was still running when terminated)
                if !firstResult && !process.isRunning && process.terminationStatus == 143 {
                    // SIGTERM exit code indicates timeout
                    return false
                }

                return firstResult
            }

            pipe.fileHandleForReading.readabilityHandler = nil

            if !result && process.terminationStatus == 143 {
                onProgress(SetupProgressUpdate(stage: .failed, status: "Sync timed out after 10 minutes", logLine: "Process timeout"))
                return false
            }

            return result
        } catch {
            onProgress(SetupProgressUpdate(stage: .failed, status: "Sync failed", logLine: error.localizedDescription))
            pipe.fileHandleForReading.readabilityHandler = nil
            return false
        }
    }

    private func createPythonEnvironment(venvPath: URL, modelsHubDir: URL) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["UV_PROJECT_ENVIRONMENT"] = venvPath.path
        env["UV_PYTHON_INSTALL_DIR"] = PathManager.pythonRuntimesDirectory.path
        env["UV_CACHE_DIR"] = PathManager.uvCacheDirectory.path
        env["UV_PYTHON_PREFERENCE"] = "only-managed"
        env["PYTHONUNBUFFERED"] = "1"
        env["HF_HUB_ENABLE_HF_TRANSFER"] = "1"  // Enable high-speed downloads
        env["HF_HOME"] = PathManager.modelsDirectory.path
        env["HUGGINGFACE_HUB_CACHE"] = modelsHubDir.path
        env["TRANSFORMERS_CACHE"] = modelsHubDir.path
        env["MODELR_CONFIG_PATH"] = PathManager.projectConfigPath.path
        env["MODELR_APP_SUPPORT_DIR"] = PathManager.appSupportDirectory.path
        env["MODELR_CHECKPOINTS_DIR"] = PathManager.checkpointsDirectory.path
        env["MODELR_OUTPUTS_DIR"] = PathManager.outputsDirectory.path
        env["MODELR_WORKING_DIR"] = PathManager.workingDirectory.path
        env["MODELR_LOGS_DIR"] = PathManager.logsDirectory.path
        env["MODELR_MODELS_DIR"] = PathManager.modelsDirectory.path

        let pythonPathEntries: [String] = [
            PathManager.libPythonDirectory.path,
            PathManager.libPythonDirectory.appendingPathComponent("modelr_core", isDirectory: true).path,
            PathManager.libPythonDirectory.appendingPathComponent("mlx-sam3", isDirectory: true).path
        ]
        env["PYTHONPATH"] = pythonPathEntries.joined(separator: ":")
        env["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin"
        return env
    }

    // MARK: - Resource Utilities

    /// Refresh resources (scripts, configs) without re-running full setup
    /// This preserves models and environments, only updating code files
    func refreshResources() {
        print("[Resources] Refreshing resources (version: \(PathManager.currentAppVersion) build: \(PathManager.currentBuildNumber))...")
        copyResourceFiles()
        try? PathManager.updateResourcesMarker()
        try? PathManager.updateSetupMarkerVersion()
        print("[Resources] Resources refreshed successfully")
    }

    /// Check if resources need refreshing and do it automatically
    func refreshResourcesIfNeeded() {
        if PathManager.needsBundledResourcesRefresh || PathManager.needsResourceRefresh {
            print("[Resources] Bundled resources out of date, refreshing...")
            refreshResources()
        }
    }

    /// Refresh Python environments (venvs) without re-downloading models
    /// Called when build number changes to update dependencies
    func refreshEnvironments(onProgress: @escaping (SetupProgressUpdate) -> Void) async -> Bool {
        let report = { (stage: SetupStage, status: String, log: String?, isDetailed: Bool) in
            if !status.isEmpty {
                print("[EnvRefresh][\(stage.rawValue)] \(status)")
            }
            if let l = log { print("[EnvRefresh][\(stage.rawValue)] \(l)") }
            onProgress(SetupProgressUpdate(stage: stage, status: status, logLine: log, isDetailedLog: isDetailed))
        }

        report(.preparing, "Updating Python environments...", nil, false)

        // First refresh resource files
        refreshResources()

        guard let uvPath = cachedUvPath else {
            report(.failed, "uv binary not found", nil, false)
            return false
        }

        // Sync unified inference environment (SAM + VLM + Tools)
        report(.syncingSAM, "Updating inference environment...", nil, false)
        await setupInferenceEnvironment(uvPath: uvPath, onProgress: onProgress)
        guard inferenceVenvReady else {
            report(.failed, "Inference environment sync failed", nil, false)
            return false
        }

        // Sync Hunyuan environment
        report(.syncingHunyuan, "Updating 3D generation environment...", nil, false)
        await setupHunyuanEnvironment(uvPath: uvPath, onProgress: onProgress)
        guard hunyuanVenvReady else {
            report(.failed, "Hunyuan environment sync failed", nil, false)
            return false
        }

        // Update markers
        try? PathManager.updateEnvironmentMarker()
        try? PathManager.updateSetupMarkerVersion()

        report(.completed, "Environments updated", nil, false)
        return true
    }

    /// Check if environments need refreshing and schedule it
    var needsEnvironmentRefresh: Bool {
        PathManager.needsEnvironmentRefresh
    }

    func checkResources() -> Bool {
        // These must exist after copyResourceFiles() runs.
        let requiredPaths: [URL] = [
            PathManager.projectConfigPath,
            PathManager.sharedDirectory.appendingPathComponent("modelr_core"),
            PathManager.sharedDirectory.appendingPathComponent("mlx-sam3"),
            // Unified inference environment
            PathManager.inferenceProjectDirectory.appendingPathComponent("pyproject.toml"),
            // Individual wrapper scripts
            PathManager.samProjectDirectory.appendingPathComponent(AppConstants.samWrapperFileName),
            PathManager.vlmProjectDirectory.appendingPathComponent(AppConstants.vlmWrapperFileName),
            PathManager.toolsProjectDirectory.appendingPathComponent("mesh_processor.py"),
            // Hunyuan (separate environment)
            PathManager.hunyuanProjectDirectory.appendingPathComponent("pyproject.toml"),
            PathManager.hunyuanProjectDirectory.appendingPathComponent(AppConstants.hunyuanWrapperFileName)
        ]

        return requiredPaths.allSatisfy { fileManager.fileExists(atPath: $0.path) }
    }

    private func findUVExecutable() -> String? {
        if let override = resourcePathOverride {
            return PathManager.uvBinaryPath(resourcePathOverride: override)
        }
        return PathManager.uvBinaryPath()
    }

    private func copyResourceFiles() {
        guard let source = locateResourcesDirectory() else {
            print("[Resources] Could not locate Resources directory")
            return
        }

        do {
            try PathManager.ensureAppSupportDirectoryExists()
        } catch {
            print("[Resources] Failed to create App Support subdirectories: \(error)")
            return
        }

        do {
            // Config
            try copyFile(from: source.appendingPathComponent("project_config.json"), to: PathManager.projectConfigPath)

            // Shared packages (filtered copy to avoid egg-info/__pycache__ pollution)
            let sharedCoreSrc = source.appendingPathComponent("modelr_core", isDirectory: true)
            let sharedCoreDst = PathManager.sharedDirectory.appendingPathComponent("modelr_core", isDirectory: true)
            try copyDirectoryFiltered(from: sharedCoreSrc, to: sharedCoreDst)

            let sharedMlxSrc = source.appendingPathComponent("mlx-sam3", isDirectory: true)
            let sharedMlxDst = PathManager.sharedDirectory.appendingPathComponent("mlx-sam3", isDirectory: true)
            try copyDirectoryFiltered(from: sharedMlxSrc, to: sharedMlxDst)

            // Model downloader script (used for all model downloads)
            try copyFile(from: source.appendingPathComponent(AppConstants.modelDownloaderFileName), to: PathManager.sharedDirectory.appendingPathComponent(AppConstants.modelDownloaderFileName))

            // Unified inference environment (SAM + VLM + Tools)
            try PathManager.ensureDirectoryExists(at: PathManager.inferenceProjectDirectory)
            let inferencePyprojectDst = PathManager.inferenceProjectDirectory.appendingPathComponent("pyproject.toml")
            try copyFile(from: source.appendingPathComponent("pyproject_inference.toml"), to: inferencePyprojectDst)
            normalizeUvLocalSourcePaths(inPyprojectAt: inferencePyprojectDst)

            // SAM wrapper script (uses inference venv)
            try PathManager.ensureDirectoryExists(at: PathManager.samProjectDirectory)
            try copyFile(from: source.appendingPathComponent(AppConstants.samWrapperFileName), to: PathManager.samProjectDirectory.appendingPathComponent(AppConstants.samWrapperFileName))

            // Tools wrapper script (uses inference venv)
            try PathManager.ensureDirectoryExists(at: PathManager.toolsProjectDirectory)
            try copyFile(from: source.appendingPathComponent("mesh_processor.py"), to: PathManager.toolsProjectDirectory.appendingPathComponent("mesh_processor.py"))

            // VLM wrapper script (uses inference venv)
            try PathManager.ensureDirectoryExists(at: PathManager.vlmProjectDirectory)
            try copyFile(from: source.appendingPathComponent(AppConstants.vlmWrapperFileName), to: PathManager.vlmProjectDirectory.appendingPathComponent(AppConstants.vlmWrapperFileName))

            // Hunyuan (separate environment - requires Python 3.10)
            try PathManager.ensureDirectoryExists(at: PathManager.hunyuanProjectDirectory)
            let hunyuanPyprojectDst = PathManager.hunyuanProjectDirectory.appendingPathComponent("pyproject.toml")
            try copyFile(from: source.appendingPathComponent(AppConstants.hunyuanPyprojectFileName), to: hunyuanPyprojectDst)
            try copyFile(from: source.appendingPathComponent(AppConstants.hunyuanWrapperFileName), to: PathManager.hunyuanProjectDirectory.appendingPathComponent(AppConstants.hunyuanWrapperFileName))
            normalizeUvLocalSourcePaths(inPyprojectAt: hunyuanPyprojectDst)
        } catch {
            print("[Resources] Failed to copy resources: \(error)")
        }
    }

    private func normalizeUvLocalSourcePaths(inPyprojectAt path: URL) {
        guard fileManager.fileExists(atPath: path.path) else { return }

        do {
            let original = try String(contentsOf: path, encoding: .utf8)
            let updated = original
                .replacingOccurrences(of: "../../Shared/", with: "../../python/")
                .replacingOccurrences(of: "..\\/..\\/Shared/", with: "../../python/")

            guard updated != original else { return }
            try updated.write(to: path, atomically: true, encoding: .utf8)
            print("[Resources] Normalized uv local path sources in \(path.lastPathComponent)")
        } catch {
            print("[Resources] Failed to normalize uv local path sources: \(error)")
        }
    }

    private func locateResourcesDirectory() -> URL? {
        if let override = resourcePathOverride {
            let overrideURL = URL(fileURLWithPath: override)
            var isDir: ObjCBool = false
            if fileManager.fileExists(atPath: overrideURL.path, isDirectory: &isDir), isDir.boolValue {
                return overrideURL
            }
            return overrideURL.deletingLastPathComponent()
        }

        let searchPaths: [URL?] = [
            Bundle.main.resourceURL,
            Bundle.main.resourceURL?.appendingPathComponent("Resources"),
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("Resources")
        ]

        for path in searchPaths {
            if let p = path, fileManager.fileExists(atPath: p.appendingPathComponent("project_config.json").path) {
                return p
            }
        }

        return nil
    }

    private func shouldSkipCopyItem(named name: String) -> Bool {
        if name == ".DS_Store" { return true }
        if name == "__pycache__" { return true }
        if name == ".pytest_cache" { return true }
        if name == ".venv" { return true }
        if name.hasSuffix(".egg-info") { return true }
        if name.hasSuffix(".pyc") { return true }
        return false
    }

    private func copyFile(from source: URL, to destination: URL) throws {
        try PathManager.ensureDirectoryExists(at: destination.deletingLastPathComponent())
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        try fileManager.copyItem(at: source, to: destination)
    }

    private func copyDirectoryFiltered(from source: URL, to destination: URL) throws {
        var isDir: ObjCBool = false
        guard fileManager.fileExists(atPath: source.path, isDirectory: &isDir), isDir.boolValue else {
            return
        }

        // Ensure destination exists
        try PathManager.ensureDirectoryExists(at: destination)

        let contents = try fileManager.contentsOfDirectory(at: source, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
        for item in contents {
            let name = item.lastPathComponent
            if shouldSkipCopyItem(named: name) { continue }

            let target = destination.appendingPathComponent(name)
            var isChildDir: ObjCBool = false
            _ = fileManager.fileExists(atPath: item.path, isDirectory: &isChildDir)

            if isChildDir.boolValue {
                try copyDirectoryFiltered(from: item, to: target)
            } else {
                if fileManager.fileExists(atPath: target.path) {
                    try? fileManager.removeItem(at: target)
                }
                try fileManager.copyItem(at: item, to: target)
            }
        }
    }
}
