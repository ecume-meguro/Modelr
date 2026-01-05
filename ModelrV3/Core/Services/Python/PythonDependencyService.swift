import Foundation

/// Manages Python dependency installation and environment setup
class PythonDependencyService {
    private let appSupportDir: URL
    private let fileManager = FileManager.default

    var cachedUvPath: String?
    var samVenvReady = false
    var toolsVenvReady = false
    var hunyuanVenvReady = false
    var resourcePathOverride: String?

    var samDir: URL { appSupportDir.appendingPathComponent("SAM") }
    var toolsDir: URL { appSupportDir.appendingPathComponent("Tools") }
    var hunyuanDir: URL { appSupportDir.appendingPathComponent("Hunyuan3D") }

    init(appSupportDir: URL) {
        self.appSupportDir = appSupportDir
        cachedUvPath = findUVExecutable()
    }

    // MARK: - Main Setup Flow

    func setup(
        modelChoice: SetupModelChoice = .fast, 
        onProgress: @escaping (SetupProgressUpdate) -> Void
    ) async -> Bool {
        let report = { (stage: SetupStage, status: String, log: String?, isDetailed: Bool) in
            if let l = log { print("[\(stage.rawValue)] \(l)") }
            onProgress(SetupProgressUpdate(stage: stage, status: status, logLine: log, isDetailedLog: isDetailed))
        }

        report(.preparing, "Preparing resources...", nil, false)
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
        do {
            try fileManager.createDirectory(at: samDir, withIntermediateDirectories: true)
            
            let filesToCopy = [
                ("pyproject_sam.toml", "pyproject.toml"),
                ("sam_wrapper.py", "sam_wrapper.py"),
                ("mlx-sam3", "mlx-sam3"),
                ("modelrv3_core", "modelrv3_core")
            ]
            
            for (src, dst) in filesToCopy {
                let srcURL = appSupportDir.appendingPathComponent(src)
                let dstURL = samDir.appendingPathComponent(dst)
                if fileManager.fileExists(atPath: dstURL.path) { try fileManager.removeItem(at: dstURL) }
                try fileManager.copyItem(at: srcURL, to: dstURL)
            }
        } catch {
            onProgress(SetupProgressUpdate(stage: .failed, status: "SAM preparation failed", logLine: error.localizedDescription))
            return
        }

        samVenvReady = await syncEnvironment(
            uvPath: uvPath,
            pythonVersion: "3.13",
            venvPath: samDir.appendingPathComponent(".venv"),
            workingDir: samDir,
            stage: .syncingSAM,
            onProgress: onProgress
        )
    }

    private func warmupSAMModel(uvPath: String, onProgress: @escaping (SetupProgressUpdate) -> Void) async {
        let samCacheDir = appSupportDir.appendingPathComponent("sam_cache")
        try? fileManager.createDirectory(at: samCacheDir, withIntermediateDirectories: true)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: uvPath)
        process.arguments = ["run", "--project", samDir.path, "sam_wrapper.py", "--test"]
        process.currentDirectoryURL = samDir
        process.environment = createPythonEnvironment(venvPath: samDir.appendingPathComponent(".venv"), cacheDir: samCacheDir)

        await runProcessAsync(process, stage: .downloadingSAM, onProgress: onProgress)
    }

    private func setupToolsEnvironment(uvPath: String, onProgress: @escaping (SetupProgressUpdate) -> Void) async {
        do {
            try fileManager.createDirectory(at: toolsDir, withIntermediateDirectories: true)
            let filesToCopy = [
                ("pyproject_tools.toml", "pyproject.toml"),
                ("mesh_processor.py", "mesh_processor.py")
            ]
            for (src, dst) in filesToCopy {
                let srcURL = appSupportDir.appendingPathComponent(src)
                let dstURL = toolsDir.appendingPathComponent(dst)
                if fileManager.fileExists(atPath: dstURL.path) { try fileManager.removeItem(at: dstURL) }
                try fileManager.copyItem(at: srcURL, to: dstURL)
            }
        } catch {
            onProgress(SetupProgressUpdate(stage: .failed, status: "Tools preparation failed", logLine: error.localizedDescription))
            return
        }

        toolsVenvReady = await syncEnvironment(
            uvPath: uvPath,
            pythonVersion: "3.13",
            venvPath: toolsDir.appendingPathComponent(".venv"),
            workingDir: toolsDir,
            stage: .syncingTools,
            onProgress: onProgress
        )
    }

    private func setupHunyuanEnvironment(uvPath: String, onProgress: @escaping (SetupProgressUpdate) -> Void) async {
        do {
            try fileManager.createDirectory(at: hunyuanDir, withIntermediateDirectories: true)
            let filesToCopy = [
                ("pyproject_hunyuan.toml", "pyproject.toml"),
                ("hunyuan_wrapper.py", "hunyuan_wrapper.py")
            ]
            for (src, dst) in filesToCopy {
                let srcURL = appSupportDir.appendingPathComponent(src)
                let dstURL = hunyuanDir.appendingPathComponent(dst)
                if fileManager.fileExists(atPath: dstURL.path) { try fileManager.removeItem(at: dstURL) }
                try fileManager.copyItem(at: srcURL, to: dstURL)
            }
        } catch {
            onProgress(SetupProgressUpdate(stage: .failed, status: "Hunyuan preparation failed", logLine: error.localizedDescription))
            return
        }

        hunyuanVenvReady = await syncEnvironment(
            uvPath: uvPath,
            pythonVersion: "3.10",
            venvPath: hunyuanDir.appendingPathComponent(".venv"),
            workingDir: hunyuanDir,
            stage: .syncingHunyuan,
            onProgress: onProgress
        )
    }

    private func downloadHunyuanModel(uvPath: String, variant: String, onProgress: @escaping (SetupProgressUpdate) -> Void) async {
        let hfCacheDir = hunyuanDir.appendingPathComponent("hf_cache")
        try? fileManager.createDirectory(at: hfCacheDir, withIntermediateDirectories: true)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: uvPath)
        process.arguments = ["run", "--project", hunyuanDir.path, "hunyuan_wrapper.py", "--warmup", "--model", variant]
        process.currentDirectoryURL = hunyuanDir
        process.environment = createPythonEnvironment(venvPath: hunyuanDir.appendingPathComponent(".venv"), cacheDir: hfCacheDir)

        await runProcessAsync(process, stage: .downloadingHunyuan, onProgress: onProgress)
        UserDefaults.standard.set(variant, forKey: "SelectedHunyuanModel")
    }

    // MARK: - Process Helpers

    private func syncEnvironment(uvPath: String, pythonVersion: String, venvPath: URL, workingDir: URL, stage: SetupStage, onProgress: @escaping (SetupProgressUpdate) -> Void) async -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: uvPath)
        process.arguments = ["sync", "--python", pythonVersion]
        process.currentDirectoryURL = workingDir
        
        var env = createPythonEnvironment(venvPath: venvPath, cacheDir: appSupportDir.appendingPathComponent("uv_cache"))
        env["UV_LINK_MODE"] = "copy"
        process.environment = env

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if let line = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines), !line.isEmpty {
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

    private func createPythonEnvironment(venvPath: URL, cacheDir: URL) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["UV_PROJECT_ENVIRONMENT"] = venvPath.path
        env["UV_PYTHON_INSTALL_DIR"] = appSupportDir.appendingPathComponent("python_runtimes").path
        env["UV_CACHE_DIR"] = appSupportDir.appendingPathComponent("uv_cache").path
        env["UV_PYTHON_PREFERENCE"] = "only-managed"
        env["PYTHONUNBUFFERED"] = "1"
        env["HF_HOME"] = cacheDir.path
        env["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin"
        return env
    }

    // MARK: - Resource Utilities

    func checkResources() -> Bool {
        let criticalFiles = ["pyproject_sam.toml", "pyproject_tools.toml", "pyproject_hunyuan.toml", "project_config.json", "mlx-sam3", "modelrv3_core"]
        return criticalFiles.allSatisfy { fileManager.fileExists(atPath: appSupportDir.appendingPathComponent($0).path) }
    }

    private func findUVExecutable() -> String? {
        if let override = resourcePathOverride { return override }
        return Bundle.main.path(forResource: "uv", ofType: nil) ?? 
               Bundle.main.path(forResource: "uv", ofType: nil, inDirectory: "Resources")
    }

    private func copyResourceFiles() {
        var sourceURL: URL?
        if let override = resourcePathOverride {
            sourceURL = URL(fileURLWithPath: override).deletingLastPathComponent()
        } else {
            let searchPaths = [Bundle.main.resourceURL, Bundle.main.resourceURL?.appendingPathComponent("Resources"), URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("Resources")]
            for path in searchPaths {
                if let p = path, fileManager.fileExists(atPath: p.appendingPathComponent("pyproject_sam.toml").path) {
                    sourceURL = p; break
                }
            }
        }
        if let source = sourceURL { copyFolderContents(from: source, to: appSupportDir) }
    }

    private func copyFolderContents(from source: URL, to destination: URL) {
        try? fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
        let contents = (try? fileManager.contentsOfDirectory(at: source, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        for item in contents {
            let target = destination.appendingPathComponent(item.lastPathComponent)
            var isDir: ObjCBool = false
            if fileManager.fileExists(atPath: item.path, isDirectory: &isDir) {
                if isDir.boolValue { copyFolderContents(from: item, to: target) }
                else {
                    if fileManager.fileExists(atPath: target.path) { try? fileManager.removeItem(at: target) }
                    try? fileManager.copyItem(at: item, to: target)
                }
            }
        }
    }
}
