import Foundation

/// Manages Python dependency installation and environment setup
///
/// Directory structure in ~/Library/Application Support/ModelrV3/:
/// ├── modelrv3_core/         # Shared Python module (referenced by all envs)
/// ├── SAM/                   # Segmentation environment
/// │   ├── .venv/
/// │   ├── pyproject.toml
/// │   ├── sam_wrapper.py
/// │   └── mlx-sam3/
/// ├── Tools/                 # Mesh processing environment
/// │   ├── .venv/
/// │   ├── pyproject.toml
/// │   └── mesh_processor.py
/// └── Hunyuan3D/             # 3D generation environment
///     ├── .venv/
///     ├── pyproject.toml
///     └── hunyuan_wrapper.py
class PythonDependencyService {
    private let appSupportDir: URL
    private let fileManager = FileManager.default

    var cachedUvPath: String?
    var samVenvReady = false
    var toolsVenvReady = false
    var hunyuanVenvReady = false
    var resourcePathOverride: String?

    // Directory URLs for each environment
    var samDir: URL { appSupportDir.appendingPathComponent("SAM") }
    var toolsDir: URL { appSupportDir.appendingPathComponent("Tools") }
    var hunyuanDir: URL { appSupportDir.appendingPathComponent("Hunyuan3D") }

    init(appSupportDir: URL) {
        self.appSupportDir = appSupportDir
        cachedUvPath = findUVExecutable()
    }

    // MARK: - Setup

    func setup(modelChoice: SetupModelChoice = .fast, statusUpdate: @escaping (String) -> Void, logUpdate: @escaping (String) -> Void) async -> Bool {
        statusUpdate("Preparing resources...")
        logUpdate("[Setup] Initializing application resources")

        guard let uvPath = cachedUvPath else {
            statusUpdate("Error: uv not found")
            logUpdate("[Error] uv binary not found in application bundle")
            return false
        }

        // Copy resource files to Application Support
        copyResourceFiles()

        if !checkResources() {
            statusUpdate("Error: Critical resource files missing after copy")
            logUpdate("[Error] resource verification failed")
            return false
        }

        // Setup SAM environment
        statusUpdate("Syncing SAM environment...")
        logUpdate("[Setup] Configuring Segment Anything environment")
        await setupSAMEnvironment(uvPath: uvPath, statusUpdate: statusUpdate, logUpdate: logUpdate)

        guard samVenvReady else {
            statusUpdate("SAM environment sync failed")
            logUpdate("[Error] SAM environment synchronization failed")
            return false
        }
        
        // Warmup SAM model (downloads it if needed)
        statusUpdate("Downloading segmentation model...")
        logUpdate("[Setup] Checking segmentation model checkpoints")
        await warmupSAMModel(uvPath: uvPath, logUpdate: logUpdate)

        // Setup Tools environment (lightweight, for mesh processing)
        statusUpdate("Syncing Tools environment...")
        logUpdate("[Setup] Configuring mesh processing tools")
        await setupToolsEnvironment(uvPath: uvPath, statusUpdate: statusUpdate, logUpdate: logUpdate)

        // Setup Hunyuan environment
        statusUpdate("Syncing 3D generation environment...")
        logUpdate("[Setup] Configuring Hunyuan3D environment")
        await setupHunyuanEnvironment(uvPath: uvPath, statusUpdate: statusUpdate, logUpdate: logUpdate)
        
        guard hunyuanVenvReady else {
            statusUpdate("Hunyuan environment sync failed")
            logUpdate("[Error] Hunyuan3D environment synchronization failed")
            return false
        }
        
        // Download Hunyuan model based on choice
        statusUpdate("Downloading 3D generation model...")
        logUpdate("[Setup] Downloading \(modelChoice.displayName) model variant")
        await downloadHunyuanModel(uvPath: uvPath, variant: modelChoice.modelVariant, statusUpdate: statusUpdate, logUpdate: logUpdate)

        statusUpdate("Ready")
        logUpdate("[Setup] Environment configuration successful")
        return true
    }

    private func warmupSAMModel(uvPath: String, logUpdate: @escaping (String) -> Void) async {
        let samWrapper = samDir.appendingPathComponent("sam_wrapper.py")
        let samVenv = samDir.appendingPathComponent(".venv")
        let samCacheDir = appSupportDir.appendingPathComponent("sam_cache")
        
        try? fileManager.createDirectory(at: samCacheDir, withIntermediateDirectories: true)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: uvPath)
        process.arguments = ["run", "--project", samDir.path, samWrapper.path, "--test"]
        process.currentDirectoryURL = samDir
        process.environment = createPythonEnvironment(venvPath: samVenv, cacheDir: samCacheDir)

        await runProcessAsync(process, logUpdate: logUpdate)
    }
    
    private func downloadHunyuanModel(uvPath: String, variant: String, statusUpdate: @escaping (String) -> Void, logUpdate: @escaping (String) -> Void) async {
        let hunyuanVenv = hunyuanDir.appendingPathComponent(".venv")
        let hfCacheDir = hunyuanDir.appendingPathComponent("hf_cache")
        let wrapper = hunyuanDir.appendingPathComponent("hunyuan_wrapper.py")

        try? fileManager.createDirectory(at: hfCacheDir, withIntermediateDirectories: true)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: uvPath)
        process.arguments = ["run", "--project", hunyuanDir.path, wrapper.path, "--warmup", "--model", variant]
        process.currentDirectoryURL = hunyuanDir
        process.environment = createPythonEnvironment(venvPath: hunyuanVenv, cacheDir: hfCacheDir)

        await runProcessAsync(process, logUpdate: logUpdate)
        UserDefaults.standard.set(variant, forKey: "SelectedHunyuanModel")
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
    
    private func runProcessAsync(_ process: Process, logUpdate: @escaping (String) -> Void) async {
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if let line = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines), !line.isEmpty {
                logUpdate(line)
            }
        }

        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    try process.run()
                    process.waitUntilExit()
                } catch {
                    logUpdate("[Error] Process execution failed: \(error.localizedDescription)")
                }
                pipe.fileHandleForReading.readabilityHandler = nil
                continuation.resume()
            }
        }
    }

    private func syncEnvironment(uvPath: String, pythonVersion: String, venvPath: URL, workingDir: URL, statusUpdate: @escaping (String) -> Void, logUpdate: @escaping (String) -> Void) async -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: uvPath)
        process.arguments = ["sync", "--python", pythonVersion]
        process.currentDirectoryURL = workingDir

        var env = ProcessInfo.processInfo.environment
        env["UV_PROJECT_ENVIRONMENT"] = venvPath.path
        env["UV_PYTHON_INSTALL_DIR"] = appSupportDir.appendingPathComponent("python_runtimes").path
        env["UV_CACHE_DIR"] = appSupportDir.appendingPathComponent("uv_cache").path
        env["UV_PYTHON_PREFERENCE"] = "only-managed"
        env["UV_LINK_MODE"] = "copy"
        env["PYTHONUNBUFFERED"] = "1"
        process.environment = env

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if let line = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines), !line.isEmpty {
                logUpdate(line)
                
                // Update status if we see downloading
                if line.contains("Downloading") {
                    statusUpdate("Downloading dependencies...")
                } else if line.contains("Installing") || line.contains("Built") {
                    statusUpdate("Installing dependencies...")
                }
            }
        }

        do {
            try await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                DispatchQueue.global(qos: .userInitiated).async {
                    do {
                        try process.run()
                        process.waitUntilExit()
                    } catch {
                        logUpdate("[Error] sync failed: \(error.localizedDescription)")
                    }
                    continuation.resume()
                }
            }
            pipe.fileHandleForReading.readabilityHandler = nil
            return process.terminationStatus == 0
        } catch {
            logUpdate("[Error] sync exception: \(error.localizedDescription)")
            return false
        }
    }

    // MARK: - SAM Environment Setup

    private func setupSAMEnvironment(uvPath: String, statusUpdate: @escaping (String) -> Void, logUpdate: @escaping (String) -> Void) async {
        let samPyprojectSource = appSupportDir.appendingPathComponent("pyproject_sam.toml")
        let samPyprojectTarget = samDir.appendingPathComponent("pyproject.toml")

        do {
            try fileManager.createDirectory(at: samDir, withIntermediateDirectories: true)

            // Copy pyproject.toml
            if fileManager.fileExists(atPath: samPyprojectTarget.path) {
                try fileManager.removeItem(at: samPyprojectTarget)
            }
            if fileManager.fileExists(atPath: samPyprojectSource.path) {
                try fileManager.copyItem(at: samPyprojectSource, to: samPyprojectTarget)
            }

            // Copy sam_wrapper.py
            let wrapperSource = appSupportDir.appendingPathComponent("sam_wrapper.py")
            let wrapperTarget = samDir.appendingPathComponent("sam_wrapper.py")
            if fileManager.fileExists(atPath: wrapperTarget.path) {
                try fileManager.removeItem(at: wrapperTarget)
            }
            if fileManager.fileExists(atPath: wrapperSource.path) {
                try fileManager.copyItem(at: wrapperSource, to: wrapperTarget)
            }

            // Copy mlx-sam3 directory
            let mlxSam3Source = appSupportDir.appendingPathComponent("mlx-sam3")
            let mlxSam3Target = samDir.appendingPathComponent("mlx-sam3")
            if fileManager.fileExists(atPath: mlxSam3Target.path) {
                try fileManager.removeItem(at: mlxSam3Target)
            }
            if fileManager.fileExists(atPath: mlxSam3Source.path) {
                try fileManager.copyItem(at: mlxSam3Source, to: mlxSam3Target)
            }
            
            // Copy modelrv3_core directory
            let coreSource = appSupportDir.appendingPathComponent("modelrv3_core")
            let coreTarget = samDir.appendingPathComponent("modelrv3_core")
            if fileManager.fileExists(atPath: coreTarget.path) {
                try fileManager.removeItem(at: coreTarget)
            }
            if fileManager.fileExists(atPath: coreSource.path) {
                try fileManager.copyItem(at: coreSource, to: coreTarget)
            }

            SecureLogger.shared.info("SAM environment files prepared", category: "Python")
        } catch {
            SecureLogger.shared.error("Failed to prepare SAM environment files: \(error.localizedDescription)", category: "Python")
            return
        }

        let samVenv = samDir.appendingPathComponent(".venv")
        samVenvReady = await syncEnvironment(
            uvPath: uvPath,
            pythonVersion: "3.13",
            venvPath: samVenv,
            workingDir: samDir,
            statusUpdate: statusUpdate,
            logUpdate: logUpdate
        )
    }

    // MARK: - Tools Environment Setup

    private func setupToolsEnvironment(uvPath: String, statusUpdate: @escaping (String) -> Void, logUpdate: @escaping (String) -> Void) async {
        let toolsPyprojectSource = appSupportDir.appendingPathComponent("pyproject_tools.toml")
        let toolsPyprojectTarget = toolsDir.appendingPathComponent("pyproject.toml")

        do {
            try fileManager.createDirectory(at: toolsDir, withIntermediateDirectories: true)

            if fileManager.fileExists(atPath: toolsPyprojectTarget.path) {
                try fileManager.removeItem(at: toolsPyprojectTarget)
            }
            if fileManager.fileExists(atPath: toolsPyprojectSource.path) {
                try fileManager.copyItem(at: toolsPyprojectSource, to: toolsPyprojectTarget)
            }

            // Copy mesh_processor.py
            let processorSource = appSupportDir.appendingPathComponent("mesh_processor.py")
            let processorTarget = toolsDir.appendingPathComponent("mesh_processor.py")
            if fileManager.fileExists(atPath: processorTarget.path) {
                try fileManager.removeItem(at: processorTarget)
            }
            if fileManager.fileExists(atPath: processorSource.path) {
                try fileManager.copyItem(at: processorSource, to: processorTarget)
            }

            SecureLogger.shared.info("Tools environment files prepared", category: "Python")
        } catch {
            SecureLogger.shared.error("Failed to prepare Tools environment files: \(error.localizedDescription)", category: "Python")
            return
        }

        let toolsVenv = toolsDir.appendingPathComponent(".venv")
        toolsVenvReady = await syncEnvironment(
            uvPath: uvPath,
            pythonVersion: "3.13",
            venvPath: toolsVenv,
            workingDir: toolsDir,
            statusUpdate: statusUpdate,
            logUpdate: logUpdate
        )
    }

    // MARK: - Hunyuan Environment Setup

    private func setupHunyuanEnvironment(uvPath: String, statusUpdate: @escaping (String) -> Void, logUpdate: @escaping (String) -> Void) async {
        let hunyuanPyprojectSource = appSupportDir.appendingPathComponent("pyproject_hunyuan.toml")
        let hunyuanPyprojectTarget = hunyuanDir.appendingPathComponent("pyproject.toml")

        do {
            try fileManager.createDirectory(at: hunyuanDir, withIntermediateDirectories: true)

            if fileManager.fileExists(atPath: hunyuanPyprojectTarget.path) {
                try fileManager.removeItem(at: hunyuanPyprojectTarget)
            }
            if fileManager.fileExists(atPath: hunyuanPyprojectSource.path) {
                try fileManager.copyItem(at: hunyuanPyprojectSource, to: hunyuanPyprojectTarget)
            }

            // Copy hunyuan_wrapper.py
            let wrapperSource = appSupportDir.appendingPathComponent("hunyuan_wrapper.py")
            let wrapperTarget = hunyuanDir.appendingPathComponent("hunyuan_wrapper.py")
            if fileManager.fileExists(atPath: wrapperTarget.path) {
                try fileManager.removeItem(at: wrapperTarget)
            }
            if fileManager.fileExists(atPath: wrapperSource.path) {
                try fileManager.copyItem(at: wrapperSource, to: wrapperTarget)
            }

            SecureLogger.shared.info("Hunyuan environment files prepared", category: "Python")
        } catch {
            SecureLogger.shared.error("Failed to prepare Hunyuan environment files: \(error.localizedDescription)", category: "Python")
            return
        }

        let hunyuanVenv = hunyuanDir.appendingPathComponent(".venv")
        hunyuanVenvReady = await syncEnvironment(
            uvPath: uvPath,
            pythonVersion: "3.10",
            venvPath: hunyuanVenv,
            workingDir: hunyuanDir,
            statusUpdate: statusUpdate,
            logUpdate: logUpdate
        )
    }

    /// Verify that critical resources are present in the app support directory
            func checkResources() -> Bool {
                let criticalFiles = [
                    "sam_wrapper.py",
                    "pyproject_sam.toml",
                    "pyproject_tools.toml",
                    "pyproject_hunyuan.toml",
                    "project_config.json",
                    "mlx-sam3",
                    "modelrv3_core"
                ]
                for file in criticalFiles {
                    let path = appSupportDir.appendingPathComponent(file).path
                    if !fileManager.fileExists(atPath: path) {
                        SecureLogger.shared.error("Missing critical resource: \(file) at \(path)", category: "Python")
                        return false
                    }
                }
                return true
            }
        
            private func findUVExecutable() -> String? {
                if let override = resourcePathOverride {
                    return override
                }
        
                if let path = Bundle.main.path(forResource: "uv", ofType: nil) {
                    return path
                }
        
                return Bundle.main.path(forResource: "uv", ofType: nil, inDirectory: "Resources")
            }
        
            private func copyResourceFiles() {
                SecureLogger.shared.info("Starting copyResourceFiles", category: "Python")
                var sourceURL: URL?
        
                if let override = resourcePathOverride {
                    sourceURL = URL(fileURLWithPath: override).deletingLastPathComponent()
                } else {
                    let baseResourceURL = Bundle.main.resourceURL
                    let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        
                    let searchPaths = [
                        baseResourceURL,
                        baseResourceURL?.appendingPathComponent("Resources"),
                        baseResourceURL?.appendingPathComponent("Resources/Resources"),
                        Bundle.main.bundleURL.appendingPathComponent("Contents/Resources"),
                        Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/Resources"),
                        cwd.appendingPathComponent("Resources"),
                        cwd,
                        URL(fileURLWithPath: Bundle.main.resourcePath ?? ""),
                        URL(fileURLWithPath: Bundle.main.resourcePath ?? "").appendingPathComponent("Resources")
                    ]
        
                    for path in searchPaths {
                        if let p = path {
                            // Check for pyproject_sam.toml as the indicator file
                            let check = p.appendingPathComponent("pyproject_sam.toml")
                            let exists = fileManager.fileExists(atPath: check.path)
                            print("[Python] Checking resource path: \(p.path) -> \(exists)")
                            SecureLogger.shared.debug("Checking \(p.path) -> \(exists)", category: "Python")
                            if exists {
                                sourceURL = p
                                break
                            }
                        }
                    }
                }
        guard let source = sourceURL else {
            print("[Python] ERROR: Could not find resource folder containing pyproject_sam.toml")
            SecureLogger.shared.error("Could not find resource folder containing pyproject_sam.toml", category: "Python")
            return
        }

        print("[Python] Copying resources from \(source.path) to \(appSupportDir.path)")
        SecureLogger.shared.info("Copying resources from \(source.path) to \(appSupportDir.path)", category: "Python")
        copyFolderContents(from: source, to: appSupportDir)
    }

    private func copyFolderContents(from source: URL, to destination: URL) {
        do {
            if !fileManager.fileExists(atPath: destination.path) {
                try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
            }

            let contents = try fileManager.contentsOfDirectory(at: source, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])

            for item in contents {
                let targetURL = destination.appendingPathComponent(item.lastPathComponent)

                var isDirectory: ObjCBool = false
                if fileManager.fileExists(atPath: item.path, isDirectory: &isDirectory) {
                    if isDirectory.boolValue {
                        // Recursively copy subdirectory
                        copyFolderContents(from: item, to: targetURL)
                    } else {
                        // Copy file, replacing if exists
                        if fileManager.fileExists(atPath: targetURL.path) {
                            try fileManager.removeItem(at: targetURL)
                        }
                        try fileManager.copyItem(at: item, to: targetURL)
                        // Log only critical files or summary to avoid noise
                    }
                }
            }
        } catch {
            SecureLogger.shared.error("ERROR copying resources from \(source.path) to \(destination.path): \(error.localizedDescription)", category: "Python")
        }
    }

    private func syncEnvironment(uvPath: String, pythonVersion: String, venvPath: URL, workingDir: URL) async -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: uvPath)
        process.arguments = ["sync", "--python", pythonVersion]
        process.currentDirectoryURL = workingDir

        var env = ProcessInfo.processInfo.environment
        env["UV_PROJECT_ENVIRONMENT"] = venvPath.path
        env["UV_PYTHON_INSTALL_DIR"] = appSupportDir.appendingPathComponent("python_runtimes").path
        env["UV_CACHE_DIR"] = appSupportDir.appendingPathComponent("uv_cache").path
        env["UV_PYTHON_PREFERENCE"] = "only-managed"
        env["UV_LINK_MODE"] = "copy"
        env["PYTHONUNBUFFERED"] = "1"
        process.environment = env

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if let line = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines), !line.isEmpty {
                print(">>> \(line)")
            }
        }

        do {
            try process.run()
            process.waitUntilExit()
            pipe.fileHandleForReading.readabilityHandler = nil
            return process.terminationStatus == 0
        } catch {
            print(">>> EXEC ERROR: \(error.localizedDescription)")
            return false
        }
    }

    // MARK: - SAM Environment Setup

    private func setupSAMEnvironment(uvPath: String, statusUpdate: @escaping (String) -> Void) async {
        let samPyprojectSource = appSupportDir.appendingPathComponent("pyproject_sam.toml")
        let samPyprojectTarget = samDir.appendingPathComponent("pyproject.toml")

        do {
            try fileManager.createDirectory(at: samDir, withIntermediateDirectories: true)

            // Copy pyproject.toml
            if fileManager.fileExists(atPath: samPyprojectTarget.path) {
                try fileManager.removeItem(at: samPyprojectTarget)
            }
            if fileManager.fileExists(atPath: samPyprojectSource.path) {
                try fileManager.copyItem(at: samPyprojectSource, to: samPyprojectTarget)
            }

            // Copy sam_wrapper.py
            let wrapperSource = appSupportDir.appendingPathComponent("sam_wrapper.py")
            let wrapperTarget = samDir.appendingPathComponent("sam_wrapper.py")
            if fileManager.fileExists(atPath: wrapperTarget.path) {
                try fileManager.removeItem(at: wrapperTarget)
            }
            if fileManager.fileExists(atPath: wrapperSource.path) {
                try fileManager.copyItem(at: wrapperSource, to: wrapperTarget)
            }

            // Copy mlx-sam3 directory
            let mlxSam3Source = appSupportDir.appendingPathComponent("mlx-sam3")
            let mlxSam3Target = samDir.appendingPathComponent("mlx-sam3")
            if fileManager.fileExists(atPath: mlxSam3Target.path) {
                try fileManager.removeItem(at: mlxSam3Target)
            }
            if fileManager.fileExists(atPath: mlxSam3Source.path) {
                try fileManager.copyItem(at: mlxSam3Source, to: mlxSam3Target)
            }
            
            // Copy modelrv3_core directory
            let coreSource = appSupportDir.appendingPathComponent("modelrv3_core")
            let coreTarget = samDir.appendingPathComponent("modelrv3_core")
            if fileManager.fileExists(atPath: coreTarget.path) {
                try fileManager.removeItem(at: coreTarget)
            }
            if fileManager.fileExists(atPath: coreSource.path) {
                try fileManager.copyItem(at: coreSource, to: coreTarget)
            }

            SecureLogger.shared.info("SAM environment files prepared", category: "Python")
        } catch {
            SecureLogger.shared.error("Failed to prepare SAM environment files: \(error.localizedDescription)", category: "Python")
            return
        }

        let samVenv = samDir.appendingPathComponent(".venv")
        samVenvReady = await syncEnvironment(
            uvPath: uvPath,
            pythonVersion: "3.13",
            venvPath: samVenv,
            workingDir: samDir
        )
    }

    // MARK: - Tools Environment Setup

    private func setupToolsEnvironment(uvPath: String, statusUpdate: @escaping (String) -> Void) async {
        let toolsPyprojectSource = appSupportDir.appendingPathComponent("pyproject_tools.toml")
        let toolsPyprojectTarget = toolsDir.appendingPathComponent("pyproject.toml")

        do {
            try fileManager.createDirectory(at: toolsDir, withIntermediateDirectories: true)

            if fileManager.fileExists(atPath: toolsPyprojectTarget.path) {
                try fileManager.removeItem(at: toolsPyprojectTarget)
            }
            if fileManager.fileExists(atPath: toolsPyprojectSource.path) {
                try fileManager.copyItem(at: toolsPyprojectSource, to: toolsPyprojectTarget)
            }

            // Copy mesh_processor.py
            let processorSource = appSupportDir.appendingPathComponent("mesh_processor.py")
            let processorTarget = toolsDir.appendingPathComponent("mesh_processor.py")
            if fileManager.fileExists(atPath: processorTarget.path) {
                try fileManager.removeItem(at: processorTarget)
            }
            if fileManager.fileExists(atPath: processorSource.path) {
                try fileManager.copyItem(at: processorSource, to: processorTarget)
            }

            SecureLogger.shared.info("Tools environment files prepared", category: "Python")
        } catch {
            SecureLogger.shared.error("Failed to prepare Tools environment files: \(error.localizedDescription)", category: "Python")
            return
        }

        let toolsVenv = toolsDir.appendingPathComponent(".venv")
        toolsVenvReady = await syncEnvironment(
            uvPath: uvPath,
            pythonVersion: "3.13",
            venvPath: toolsVenv,
            workingDir: toolsDir
        )
    }

    // MARK: - Hunyuan Environment Setup

    private func setupHunyuanEnvironment(uvPath: String, statusUpdate: @escaping (String) -> Void) async {
        let hunyuanPyprojectSource = appSupportDir.appendingPathComponent("pyproject_hunyuan.toml")
        let hunyuanPyprojectTarget = hunyuanDir.appendingPathComponent("pyproject.toml")

        do {
            try fileManager.createDirectory(at: hunyuanDir, withIntermediateDirectories: true)

            if fileManager.fileExists(atPath: hunyuanPyprojectTarget.path) {
                try fileManager.removeItem(at: hunyuanPyprojectTarget)
            }
            if fileManager.fileExists(atPath: hunyuanPyprojectSource.path) {
                try fileManager.copyItem(at: hunyuanPyprojectSource, to: hunyuanPyprojectTarget)
            }

            // Copy hunyuan_wrapper.py
            let wrapperSource = appSupportDir.appendingPathComponent("hunyuan_wrapper.py")
            let wrapperTarget = hunyuanDir.appendingPathComponent("hunyuan_wrapper.py")
            if fileManager.fileExists(atPath: wrapperTarget.path) {
                try fileManager.removeItem(at: wrapperTarget)
            }
            if fileManager.fileExists(atPath: wrapperSource.path) {
                try fileManager.copyItem(at: wrapperSource, to: wrapperTarget)
            }

            SecureLogger.shared.info("Hunyuan environment files prepared", category: "Python")
        } catch {
            SecureLogger.shared.error("Failed to prepare Hunyuan environment files: \(error.localizedDescription)", category: "Python")
            return
        }

        let hunyuanVenv = hunyuanDir.appendingPathComponent(".venv")
        hunyuanVenvReady = await syncEnvironment(
            uvPath: uvPath,
            pythonVersion: "3.10",
            venvPath: hunyuanVenv,
            workingDir: hunyuanDir
        )
    }
}
