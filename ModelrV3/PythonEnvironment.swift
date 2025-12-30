import Foundation
import AppKit

class PythonEnvironment: ObservableObject {
    @Published var isSetup = false
    @Published var status = "Initializing..."
    @Published var selfTestImage: NSImage?
    @Published var selfTestMask: NSImage?
    @Published var canProceed = false
    
    private let appSupportDir: URL
    private let venvDir: URL
    private let pythonWorkingDir: URL
    
    init() {
        let fileManager = FileManager.default
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        appSupportDir = appSupport.appendingPathComponent("ModelrV3")
        venvDir = appSupportDir.appendingPathComponent(".venv")
        pythonWorkingDir = appSupportDir // The project root is now App Support
        
        try? fileManager.createDirectory(at: appSupportDir, withIntermediateDirectories: true)
    }
    
    func setup() async {
        await MainActor.run { status = "Bootstrapping..." }
        
        var uvPath = Bundle.main.path(forResource: "uv", ofType: nil)
        if uvPath == nil {
            uvPath = Bundle.main.path(forResource: "uv", ofType: nil, inDirectory: "Resources")
        }
        
        guard let finalUvPath = uvPath else {
            print("ERROR: uv binary not found in bundle")
            await MainActor.run { status = "Error: uv not found" }
            return
        }

        // 0. Copy script resources to App Support
        await MainActor.run { status = "Syncing assets..." }
        let fm = FileManager.default
        let resources = ["sam_wrapper.py", "pyproject.toml", "self_test.jpg"]
        for res in resources {
            let targetPath = appSupportDir.appendingPathComponent(res)
            var sourcePath = Bundle.main.path(forResource: res, ofType: nil)
            if sourcePath == nil {
                sourcePath = Bundle.main.path(forResource: res, ofType: nil, inDirectory: "Resources")
            }
            
            if let finalSource = sourcePath {
                print(">>> COPY: \(res) to \(targetPath.path)")
                try? fm.removeItem(at: targetPath)
                try? fm.copyItem(atPath: finalSource, toPath: targetPath.path)
            }
        }
        
        // Load original self-test image for UI
        let testImgURL = appSupportDir.appendingPathComponent("self_test.jpg")
        if let image = NSImage(contentsOf: testImgURL) {
            await MainActor.run { self.selfTestImage = image }
        }

        // 1. Sync Environment (this will also install python locally if needed)
        await MainActor.run { status = "Setting up Python environment..." }
        
        let syncSuccess = await execute(
            executable: finalUvPath,
            arguments: ["sync", "--python", "3.12"],
            environment: [
                "UV_PROJECT_ENVIRONMENT": venvDir.path,
                "UV_PYTHON_INSTALL_DIR": appSupportDir.appendingPathComponent("python_runtimes").path,
                "UV_CACHE_DIR": appSupportDir.appendingPathComponent("uv_cache").path,
                "UV_PYTHON_PREFERENCE": "only-managed",
                "PYTHONUNBUFFERED": "1"
            ]
        )
        
        if syncSuccess {
            await runSelfTest(finalUvPath: finalUvPath)
        } else {
            await MainActor.run { status = "Setup failed" }
        }
    }
    
    @discardableResult
    private func execute(executable: String, arguments: [String], environment: [String: String]? = nil) async -> Bool {
        print("\n>>> EXEC: \(executable) \(arguments.joined(separator: " "))")
        
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = appSupportDir // Set working directory to app support
        
        var currentEnv = ProcessInfo.processInfo.environment
        
        // Globally enforce UV isolation for all commands
        let cacheDir = appSupportDir.appendingPathComponent("uv_cache").path
        let runtimesDir = appSupportDir.appendingPathComponent("python_runtimes").path
        
        currentEnv["UV_PROJECT_ENVIRONMENT"] = venvDir.path
        currentEnv["UV_PYTHON_INSTALL_DIR"] = runtimesDir
        currentEnv["UV_CACHE_DIR"] = cacheDir
        currentEnv["UV_PYTHON_PREFERENCE"] = "only-managed"
        currentEnv["PYTHONUNBUFFERED"] = "1"
        
        if let env = environment {
            for (key, value) in env {
                currentEnv[key] = value
            }
        }
        process.environment = currentEnv
        
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
               pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if let line = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines), !line.isEmpty {
                print(">>> \(line)")
                // Dynamically update status if the line looks like a status message
                if line.contains("Testing segmentation model") {
                    DispatchQueue.main.async {
                        self.status = "Testing segmentation model..."
                    }
                }
            }
        }
        
        do {
            try process.run()
            process.waitUntilExit()
            pipe.fileHandleForReading.readabilityHandler = nil
            print(">>> EXIT CODE: \(process.terminationStatus)\n")
            return process.terminationStatus == 0
        } catch {
            print(">>> EXEC ERROR: \(error.localizedDescription)")
            return false
        }
    }
    
    private func runSelfTest(finalUvPath: String) async {
        await MainActor.run { status = "Loading segmentation model..." }
        
        let scriptPath = appSupportDir.appendingPathComponent("sam_wrapper.py").path
        let testImgPath = appSupportDir.appendingPathComponent("self_test.jpg").path
        let success = await execute(
            executable: finalUvPath,
            arguments: ["run", scriptPath, "--test", testImgPath],
            environment: [
                "PYTHONPATH": appSupportDir.path,
                "PYTHONUNBUFFERED": "1"
            ]
        )
        
        let maskURL = appSupportDir.appendingPathComponent("self_test_mask.png")
        let maskImage = NSImage(contentsOf: maskURL)
        
        await MainActor.run {
            if success {
                self.selfTestMask = maskImage
                self.canProceed = true
                status = "Ready"
            } else {
                status = "Error: Self-test failed"
            }
        }
    }
    
    private func parseProgress(_ line: String) {
        // Simple heuristic to show progress from uv output
        if line.contains("Installed") || line.contains("Prepared") || line.contains("Resolved") {
            status = line.trimmingCharacters(in: .whitespacesAndNewlines)
        } else if line.contains("Resolving") || line.contains("Downloading") {
            status = line.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }
    
    func runSAM2(imagePath: String, x: Int, y: Int) async -> URL? {
        guard isSetup else { return nil }
        
        var uvPath = Bundle.main.path(forResource: "uv", ofType: nil)
        if uvPath == nil {
            uvPath = Bundle.main.path(forResource: "uv", ofType: nil, inDirectory: "Resources")
        }
        guard let finalUvPath = uvPath else { return nil }

        await MainActor.run { status = "Segmenting..." }
        
        let scriptPath = appSupportDir.appendingPathComponent("sam_wrapper.py").path
        let maskPath = appSupportDir.appendingPathComponent("mask.png").path
        
        let success = await execute(
            executable: finalUvPath,
            arguments: ["run", scriptPath, imagePath, "\(x)", "\(y)", maskPath],
            environment: [
                "PYTHONPATH": appSupportDir.path,
                "PYTHONUNBUFFERED": "1"
            ]
        )
        
        if success {
            await MainActor.run { status = "Done" }
            return URL(fileURLWithPath: maskPath)
        }
        
        await MainActor.run { status = "Ready" }
        return nil
    }
}
