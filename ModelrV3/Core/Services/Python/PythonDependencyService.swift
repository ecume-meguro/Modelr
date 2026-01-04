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
    }
    
    // MARK: - Setup
    
    func setup(statusUpdate: @escaping (String) -> Void) async -> Bool {
        statusUpdate("Bootstrapping...")
        
        guard let uvPath = findUVExecutable() else {
            statusUpdate("Error: uv not found")
            return false
        }
        
        cachedUvPath = uvPath
        
        // Copy resource files
        copyResourceFiles()
        
        // Setup SAM environment
        statusUpdate("Setting up Python environment...")
        let samSuccess = await syncEnvironment(
            uvPath: uvPath,
            pythonVersion: "3.13",
            venvPath: venvDir
        )
        
        guard samSuccess else {
            statusUpdate("Setup failed")
            return false
        }
        
        // Setup Hunyuan environment
        await setupHunyuanEnvironment(uvPath: uvPath, statusUpdate: statusUpdate)
        await downloadHunyuanModel(uvPath: uvPath, statusUpdate: statusUpdate)
        
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
        let resources = ["sam_wrapper.py", "pyproject.toml", "hunyuan_wrapper.py", "pyproject_hunyuan.toml"]
        
        for res in resources {
            let targetPath = appSupportDir.appendingPathComponent(res)
            var sourcePath: String?
            
            if let override = resourcePathOverride {
                sourcePath = URL(fileURLWithPath: override).deletingLastPathComponent().appendingPathComponent(res).path
            } else {
                sourcePath = Bundle.main.path(forResource: res, ofType: nil)
                if sourcePath == nil {
                    sourcePath = Bundle.main.path(forResource: res, ofType: nil, inDirectory: "Resources")
                }
            }
            
            if let source = sourcePath {
                if !fileManager.fileExists(atPath: targetPath.path) {
                    try? fileManager.copyItem(at: URL(fileURLWithPath: source), to: targetPath)
                }
            }
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
        
        try? fileManager.createDirectory(at: hunyuanDir, withIntermediateDirectories: true)
        try? fileManager.removeItem(at: hunyuanPyprojectTarget)
        try? fileManager.copyItem(at: hunyuanPyprojectSource, to: hunyuanPyprojectTarget)
        
        // Copy wrapper script
        let wrapperSource = appSupportDir.appendingPathComponent("hunyuan_wrapper.py")
        let wrapperTarget = hunyuanDir.appendingPathComponent("hunyuan_wrapper.py")
        try? fileManager.removeItem(at: wrapperTarget)
        try? fileManager.copyItem(at: wrapperSource, to: wrapperTarget)
        
        // Sync Hunyuan environment (must use hunyuanDir as working directory for pyproject.toml)
        let hunyuanVenv = hunyuanDir.appendingPathComponent(".venv")
        hunyuanVenvReady = await syncEnvironment(
            uvPath: uvPath,
            pythonVersion: "3.10",
            venvPath: hunyuanVenv,
            workingDir: hunyuanDir
        )
    }
    
    private func downloadHunyuanModel(uvPath: String, statusUpdate: @escaping (String) -> Void) async {
        guard hunyuanVenvReady else { return }
        
        let hunyuanDir = appSupportDir.appendingPathComponent("Hunyuan3D")
        let hunyuanVenv = hunyuanDir.appendingPathComponent(".venv")
        let hunyuanScript = hunyuanDir.appendingPathComponent("hunyuan_wrapper.py").path
        
        let process = Process()
        process.executableURL = URL(fileURLWithPath: uvPath)
        process.arguments = ["run", hunyuanScript, "--warmup"]
        process.currentDirectoryURL = hunyuanDir
        
        var env = ProcessInfo.processInfo.environment
        env["UV_PROJECT_ENVIRONMENT"] = hunyuanVenv.path
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
        } catch {
            print(">>> EXEC ERROR: \(error.localizedDescription)")
        }
    }
}
