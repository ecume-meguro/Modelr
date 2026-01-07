import Foundation

/// Manages Python dependency installation and environment setup
class PythonDependencyService {
    private let fileManager = FileManager.default

    var cachedUvPath: String?
    var samVenvReady = false
    var toolsVenvReady = false
    var hunyuanVenvReady = false
    var resourcePathOverride: String?

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

        // 1. Segmentation (Environment then Model)
        report(.syncingSAM, "Syncing SAM environment...", nil, false)
        await setupSAMEnvironment(uvPath: uvPath, onProgress: onProgress)
        guard samVenvReady else {
            report(.failed, "SAM environment sync failed", nil, false)
            return false
        }
        
        report(.downloadingSAM, "Downloading segmentation model...", nil, false)
        await warmupSAMModel(uvPath: uvPath, onProgress: onProgress)

        // 2. 3D Generation (Environment then Model)
        report(.syncingHunyuan, "Syncing 3D generation environment...", nil, false)
        await setupHunyuanEnvironment(uvPath: uvPath, onProgress: onProgress)
        guard hunyuanVenvReady else {
            report(.failed, "Hunyuan environment sync failed", nil, false)
            return false
        }
        
        report(.downloadingHunyuan, "Downloading 3D generation model (\(modelChoice.displayName))...", nil, false)
        await downloadHunyuanModel(uvPath: uvPath, variant: modelChoice.modelVariant, onProgress: onProgress)

        // 3. Post-Process (Mesh Tools)
        report(.syncingTools, "Syncing mesh tools...", nil, false)
        await setupToolsEnvironment(uvPath: uvPath, onProgress: onProgress)
        guard toolsVenvReady else {
            report(.failed, "Tools environment sync failed", nil, false)
            return false
        }

        report(.completed, "Ready", nil, false)
        return true
    }

    // MARK: - Stage Implementations

    private func setupSAMEnvironment(uvPath: String, onProgress: @escaping (SetupProgressUpdate) -> Void) async {
        let samProjectDir = PathManager.samProjectDirectory
        let samVenvDir = PathManager.samEnvironmentDirectory.appendingPathComponent(AppConstants.venvDirectoryName, isDirectory: true)
        do {
            try PathManager.ensureDirectoryExists(at: samProjectDir)
            try PathManager.ensureDirectoryExists(at: PathManager.samEnvironmentDirectory)
        } catch {
            onProgress(SetupProgressUpdate(stage: .failed, status: "SAM preparation failed", logLine: error.localizedDescription))
            return
        }

        samVenvReady = await syncEnvironment(
            uvPath: uvPath,
            pythonVersion: "3.13",
            venvPath: samVenvDir,
            workingDir: samProjectDir,
            stage: .syncingSAM,
            onProgress: onProgress
        )
    }

    private func warmupSAMModel(uvPath: String, onProgress: @escaping (SetupProgressUpdate) -> Void) async {
        let samProjectDir = PathManager.samProjectDirectory
        let samVenvDir = PathManager.samEnvironmentDirectory.appendingPathComponent(AppConstants.venvDirectoryName, isDirectory: true)
        let modelsHubDir = PathManager.modelsHubDirectory
        try? PathManager.ensureDirectoryExists(at: modelsHubDir)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: uvPath)
        process.arguments = ["run", "--project", samProjectDir.path, AppConstants.samWrapperFileName, "--test"]
        process.currentDirectoryURL = samProjectDir
        process.environment = createPythonEnvironment(venvPath: samVenvDir, modelsHubDir: modelsHubDir)

        await runProcessAsync(process, stage: .downloadingSAM, onProgress: onProgress)
    }

    private func setupToolsEnvironment(uvPath: String, onProgress: @escaping (SetupProgressUpdate) -> Void) async {
        let toolsProjectDir = PathManager.toolsProjectDirectory
        let toolsVenvDir = PathManager.toolsEnvironmentDirectory.appendingPathComponent(AppConstants.venvDirectoryName, isDirectory: true)
        do {
            try PathManager.ensureDirectoryExists(at: toolsProjectDir)
            try PathManager.ensureDirectoryExists(at: PathManager.toolsEnvironmentDirectory)
        } catch {
            onProgress(SetupProgressUpdate(stage: .failed, status: "Tools preparation failed", logLine: error.localizedDescription))
            return
        }

        toolsVenvReady = await syncEnvironment(
            uvPath: uvPath,
            pythonVersion: "3.13",
            venvPath: toolsVenvDir,
            workingDir: toolsProjectDir,
            stage: .syncingTools,
            onProgress: onProgress
        )
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

    private func downloadHunyuanModel(uvPath: String, variant: String, onProgress: @escaping (SetupProgressUpdate) -> Void) async {
        let hunyuanProjectDir = PathManager.hunyuanProjectDirectory
        let modelsHubDir = PathManager.modelsHubDirectory
        try? PathManager.ensureDirectoryExists(at: modelsHubDir)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: uvPath)
        process.arguments = ["run", "--project", hunyuanProjectDir.path, AppConstants.hunyuanWrapperFileName, "--warmup", "--model", variant]
        process.currentDirectoryURL = hunyuanProjectDir
        process.environment = createPythonEnvironment(venvPath: PathManager.hunyuanVenvDirectory, modelsHubDir: modelsHubDir)

        await runProcessAsync(process, stage: .downloadingHunyuan, onProgress: onProgress)
        UserDefaults.standard.set(variant, forKey: "SelectedHunyuanModel")
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

        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if let line = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines), !line.isEmpty {
                print("[Setup][\(stage.rawValue)] \(line)")
                let isDetailed = line.contains("Resolving") || line.contains("Installing") || line.contains("Built")
                onProgress(SetupProgressUpdate(stage: stage, status: isDetailed ? "Syncing dependencies..." : line, logLine: line, isDetailedLog: isDetailed))
            }
        }

        return await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    try process.run()
                    process.waitUntilExit()
                    pipe.fileHandleForReading.readabilityHandler = nil
                    continuation.resume(returning: process.terminationStatus == 0)
                } catch {
                    onProgress(SetupProgressUpdate(stage: .failed, status: "Sync failed", logLine: error.localizedDescription))
                    continuation.resume(returning: false)
                }
            }
        }
    }

    private func runProcessAsync(_ process: Process, stage: SetupStage, onProgress: @escaping (SetupProgressUpdate) -> Void) async {
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if let line = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines), !line.isEmpty {
                print("[Setup][\(stage.rawValue)] \(line)")
                let isDetailed = line.contains("|") || line.contains("%") || line.contains("Fetching")
                onProgress(SetupProgressUpdate(stage: stage, status: isDetailed ? "" : line, logLine: line, isDetailedLog: isDetailed))
            }
        }

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    try process.run()
                    process.waitUntilExit()
                } catch {
                    onProgress(SetupProgressUpdate(stage: .failed, status: "Process execution failed", logLine: error.localizedDescription))
                }
                pipe.fileHandleForReading.readabilityHandler = nil
                continuation.resume()
            }
        }
    }

    private func createPythonEnvironment(venvPath: URL, modelsHubDir: URL) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["UV_PROJECT_ENVIRONMENT"] = venvPath.path
        env["UV_PYTHON_INSTALL_DIR"] = PathManager.pythonRuntimesDirectory.path
        env["UV_CACHE_DIR"] = PathManager.uvCacheDirectory.path
        env["UV_PYTHON_PREFERENCE"] = "only-managed"
        env["PYTHONUNBUFFERED"] = "1"
        env["HF_HOME"] = PathManager.modelsDirectory.path
        env["HUGGINGFACE_HUB_CACHE"] = modelsHubDir.path
        env["TRANSFORMERS_CACHE"] = modelsHubDir.path
        env["MODELR_CONFIG_PATH"] = PathManager.projectConfigPath.path
        env["MODELR_APP_SUPPORT_DIR"] = PathManager.appSupportDirectory.path
        env["MODELR_CHECKPOINTS_DIR"] = PathManager.checkpointsDirectory.path
        env["MODELR_OUTPUTS_DIR"] = PathManager.outputsDirectory.path
        env["MODELR_WORKING_DIR"] = PathManager.workingDirectory.path
        env["MODELR_LOGS_DIR"] = PathManager.logsDirectory.path

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
        try? PathManager.updateSetupMarkerVersion()
        print("[Resources] Resources refreshed successfully")
    }

    /// Check if resources need refreshing and do it automatically
    func refreshResourcesIfNeeded() {
        if PathManager.needsResourceRefresh {
            print("[Resources] App version changed, refreshing resources...")
            refreshResources()
        }
    }

    func checkResources() -> Bool {
        // These must exist after copyResourceFiles() runs.
        let requiredPaths: [URL] = [
            PathManager.projectConfigPath,
            PathManager.sharedDirectory.appendingPathComponent("modelr_core"),
            PathManager.sharedDirectory.appendingPathComponent("mlx-sam3"),
            PathManager.samProjectDirectory.appendingPathComponent("pyproject.toml"),
            PathManager.samProjectDirectory.appendingPathComponent(AppConstants.samWrapperFileName),
            PathManager.toolsProjectDirectory.appendingPathComponent("pyproject.toml"),
            PathManager.toolsProjectDirectory.appendingPathComponent("mesh_processor.py"),
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

            // Lib/scripts (stage scripts + pyproject into their final project directories)
            try PathManager.ensureDirectoryExists(at: PathManager.samProjectDirectory)
            let samPyprojectDst = PathManager.samProjectDirectory.appendingPathComponent("pyproject.toml")
            try copyFile(from: source.appendingPathComponent("pyproject_sam.toml"), to: samPyprojectDst)
            try copyFile(from: source.appendingPathComponent(AppConstants.samWrapperFileName), to: PathManager.samProjectDirectory.appendingPathComponent(AppConstants.samWrapperFileName))
            normalizeUvLocalSourcePaths(inPyprojectAt: samPyprojectDst)

            try PathManager.ensureDirectoryExists(at: PathManager.toolsProjectDirectory)
            let toolsPyprojectDst = PathManager.toolsProjectDirectory.appendingPathComponent("pyproject.toml")
            try copyFile(from: source.appendingPathComponent("pyproject_tools.toml"), to: toolsPyprojectDst)
            try copyFile(from: source.appendingPathComponent("mesh_processor.py"), to: PathManager.toolsProjectDirectory.appendingPathComponent("mesh_processor.py"))
            normalizeUvLocalSourcePaths(inPyprojectAt: toolsPyprojectDst)

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
