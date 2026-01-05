import Foundation

/// Manages Python dependency installation and environment setup
class PythonDependencyService {
    private let appSupportDir: URL
    private let venvDir: URL
    private let hunyuanVenvDir: URL
    private let fileManager = FileManager.default
    
    var cachedUvPath: String?
    var hunyuanVenvReady = false
    var resourcePathOverride: String?
    
    init(appSupportDir: URL) {
        self.appSupportDir = appSupportDir
        self.venvDir = appSupportDir.appendingPathComponent(".venv")
        self.hunyuanVenvDir = appSupportDir.appendingPathComponent(".venv_hunyuan")

        // Initialize uv path immediately so it's available for SAM worker
        cachedUvPath = findUVExecutable()
    }

    // MARK: - Setup

    func setup(statusUpdate: @escaping (String) -> Void) async -> Bool {
        statusUpdate("Preparing resources...")
        
        guard let uvPath = cachedUvPath else {
            statusUpdate("Error: uv not found")
            return false
        }
        
        // Copy resource files (recursively copies everything including mlx-sam3)
        copyResourceFiles()
        
        // Setup SAM environment (sync .venv)
        statusUpdate("Syncing SAM environment...")
        let samSuccess = await syncEnvironment(
            uvPath: uvPath,
            pythonVersion: "3.13",
            venvPath: venvDir
        )
        
        guard samSuccess else {
            statusUpdate("SAM environment sync failed")
            return false
        }
        
        // Setup Hunyuan environment (sync .venv_hunyuan)
        statusUpdate("Syncing Hunyuan environment...")
        await setupHunyuanEnvironment(uvPath: uvPath, statusUpdate: statusUpdate)
        
        // NOTE: Model downloading is handled by SimpleEditorViewModel after user choice
        
        statusUpdate("Ready")
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
            // Log everything to find the path
            SecureLogger.shared.debug("resourceURL: \(Bundle.main.resourceURL?.path ?? "nil")", category: "Python")
            SecureLogger.shared.debug("bundlePath: \(Bundle.main.bundlePath)", category: "Python")
            
            let baseResourceURL = Bundle.main.resourceURL
            let searchPaths = [
                baseResourceURL,
                baseResourceURL?.appendingPathComponent("Resources"),
                baseResourceURL?.appendingPathComponent("Resources/Resources"),
                Bundle.main.bundleURL.appendingPathComponent("Contents/Resources"),
                Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/Resources"),
                URL(fileURLWithPath: Bundle.main.resourcePath ?? "")
            ]
            
            for path in searchPaths {
                if let p = path {
                    let check = p.appendingPathComponent("pyproject.toml")
                    let exists = fileManager.fileExists(atPath: check.path)
                    SecureLogger.shared.debug("Checking \(p.path) -> \(exists)", category: "Python")
                    if exists {
                        sourceURL = p
                        break
                    }
                }
            }
        }

        guard let source = sourceURL else {
            SecureLogger.shared.error("Could not find resource folder containing pyproject.toml", category: "Python")
            return
        }

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
                        // Recursively copy subdirectories
                        copyFolderContents(from: item, to: targetURL)
                    } else {
                        // Copy file, overwrite if exists
                        if fileManager.fileExists(atPath: targetURL.path) {
                            try fileManager.removeItem(at: targetURL)
                        }
                        try fileManager.copyItem(at: item, to: targetURL)
                        SecureLogger.shared.debug("Copied \(item.lastPathComponent)", category: "Python")
                    }
                }
            }
        } catch {
            SecureLogger.shared.error("ERROR copying resources: \(error.localizedDescription)", category: "Python")
        }
    }
    
    private func syncEnvironment(uvPath: String, pythonVersion: String, venvPath: URL, workingDir: URL? = nil) async -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: uvPath)
        process.arguments = ["sync", "--python", pythonVersion]
        process.currentDirectoryURL = workingDir ?? appSupportDir
        
        var env = ProcessInfo.processInfo.environment
        env["UV_PROJECT_ENVIRONMENT"] = venvPath.path
        env["UV_PYTHON_INSTALL_DIR"] = appSupportDir.appendingPathComponent("python_runtimes").path
        env["UV_CACHE_DIR"] = appSupportDir.appendingPathComponent("uv_cache").path
        env["UV_PYTHON_PREFERENCE"] = "only-managed"
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
    
    private func setupHunyuanEnvironment(uvPath: String, statusUpdate: @escaping (String) -> Void) async {
        let hunyuanPyprojectSource = appSupportDir.appendingPathComponent("pyproject_hunyuan.toml")
        let hunyuanDir = appSupportDir.appendingPathComponent("Hunyuan3D")
        let hunyuanPyprojectTarget = hunyuanDir.appendingPathComponent("pyproject.toml")
        
        do {
            try fileManager.createDirectory(at: hunyuanDir, withIntermediateDirectories: true)
            
            if fileManager.fileExists(atPath: hunyuanPyprojectTarget.path) {
                try fileManager.removeItem(at: hunyuanPyprojectTarget)
            }
            // Use the file already copied to Application Support as source
            if fileManager.fileExists(atPath: hunyuanPyprojectSource.path) {
                try fileManager.copyItem(at: hunyuanPyprojectSource, to: hunyuanPyprojectTarget)
            }
            
            // Copy wrapper script
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
        
        // Sync Hunyuan environment (must use hunyuanDir as working directory for pyproject.toml)
        let hunyuanVenv = hunyuanDir.appendingPathComponent(".venv")
        hunyuanVenvReady = await syncEnvironment(
            uvPath: uvPath,
            pythonVersion: "3.10",
            venvPath: hunyuanVenv,
            workingDir: hunyuanDir
        )
    }
}
