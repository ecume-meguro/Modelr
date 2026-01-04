import Foundation

/// Manages the lifecycle of Python worker processes
class PythonProcessManager {
    private let appSupportDir: URL
    private let venvDir: URL
    private let hunyuanVenvDir: URL
    
    private(set) var persistentProcess: Process?
    private(set) var stdinPipe: Pipe?
    private(set) var stdoutPipe: Pipe?
    private(set) var currentGenerationProcess: Process?
    
    var selectedModel = "base_plus"
    var isGenerationCancelled = false
    
    // Callbacks
    var onStdoutData: ((Data) -> Void)?
    var onProcessReady: (() -> Void)?
    
    init(appSupportDir: URL, venvDir: URL, hunyuanVenvDir: URL) {
        self.appSupportDir = appSupportDir
        self.venvDir = venvDir
        self.hunyuanVenvDir = hunyuanVenvDir
    }
    
    // MARK: - Persistent Worker
    
    func startPersistentWorker(uvPath: String) throws {
        guard persistentProcess == nil else {
            print("Persistent worker already running")
            return
        }
        
        let scriptPath = appSupportDir.appendingPathComponent("sam_wrapper.py").path
        
        let process = Process()
        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()
        
        process.executableURL = URL(fileURLWithPath: uvPath)
        process.arguments = [
            "run", scriptPath,
            "--server",
            "--model", selectedModel,
            "--output-dir", appSupportDir.path
        ]
        process.currentDirectoryURL = appSupportDir
        
        var env = ProcessInfo.processInfo.environment
        env["UV_PROJECT_ENVIRONMENT"] = venvDir.path
        env["UV_PYTHON_INSTALL_DIR"] = appSupportDir.appendingPathComponent("python_runtimes").path
        env["UV_CACHE_DIR"] = appSupportDir.appendingPathComponent("uv_cache").path
        env["UV_PYTHON_PREFERENCE"] = "only-managed"
        env["PYTHONUNBUFFERED"] = "1"
        env["PYTHONPATH"] = appSupportDir.path
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
        
        print("Persistent worker started with PID \(process.processIdentifier)")
    }
    
    func stopPersistentWorker() {
        stdinPipe?.fileHandleForWriting.closeFile()
        stdoutPipe?.fileHandleForReading.readabilityHandler = nil
        
        if let process = persistentProcess, process.isRunning {
            process.terminate()
            process.waitUntilExit()
        }
        
        persistentProcess = nil
        stdinPipe = nil
        stdoutPipe = nil
        
        print("Persistent worker stopped")
    }
    
    var isWorkerRunning: Bool {
        persistentProcess?.isRunning == true
    }
    
    // MARK: - 3D Generation Process
    
    func start3DGeneration(
        uvPath: String,
        imagePath: String,
        maskPath: String,
        outputPath: URL,
        steps: Int,
        resolution: Int,
        progressCallback: @escaping (String) -> Void,
        completion: @escaping (Result<URL, Error>) -> Void
    ) {
        let hunyuanDir = appSupportDir.appendingPathComponent("Hunyuan3D")
        let hunyuanVenv = hunyuanDir.appendingPathComponent(".venv")
        let hunyuanScript = hunyuanDir.appendingPathComponent("hunyuan_wrapper.py").path
        
        isGenerationCancelled = false
        
        let process = Process()
        currentGenerationProcess = process
        process.executableURL = URL(fileURLWithPath: uvPath)
        
        var args = [
            "run", hunyuanScript,
            "--image", imagePath,
            "--output", outputPath.path,
            "--output-dir", hunyuanDir.path,
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
                print("[Hunyuan] \(line)")
                
                if line.contains("Extracting foreground") {
                    progressCallback("Extracting foreground...")
                } else if line.contains("Loading Hunyuan3D pipeline") {
                    progressCallback("Loading model...")
                } else if line.contains("Generating 3D shape") {
                    progressCallback("Generating 3D shape...")
                } else if line.contains("Diffusion Sampling") {
                    let progressStr = self.parseDetailedProgress(line, stage: "Diffusion Sampling")
                    progressCallback(progressStr)
                } else if line.contains("Volume Decoding") {
                    let progressStr = self.parseDetailedProgress(line, stage: "Volume Decoding")
                    progressCallback(progressStr)
                } else if line.contains("Model saved to") {
                    progressCallback("Saving model...")
                }
            }
        }
        
        do {
            try process.run()
        } catch {
            pipe.fileHandleForReading.readabilityHandler = nil
            completion(.failure(error))
            return
        }
        
        Task.detached { [weak self] in
            process.waitUntilExit()
            pipe.fileHandleForReading.readabilityHandler = nil
            
            await MainActor.run {
                self?.currentGenerationProcess = nil
            }
            
            let fm = FileManager.default
            let wasCancelled = self?.isGenerationCancelled ?? false
            
            if wasCancelled {
                completion(.failure(PythonError.predictionFailed("Generation cancelled")))
                return
            }
            
            if process.terminationStatus == 0 && fm.fileExists(atPath: outputPath.path) {
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
        process.terminate()
        kill(process.processIdentifier, SIGINT)
        currentGenerationProcess = nil
    }
    
    private func parseDetailedProgress(_ line: String, stage: String) -> String {
        var result = stage
        
        let pattern = #"(\d+)%.*?\|\s*(\d+)/(\d+).*?(\d+\.?\d*)\s*(it/s|s/it)"#
        if let regex = try? NSRegularExpression(pattern: pattern, options: []),
           let match = regex.firstMatch(in: line, options: [], range: NSRange(line.startIndex..., in: line)) {
            
            if let pctRange = Range(match.range(at: 1), in: line) {
                result += ": \(String(line[pctRange]))"
            }
            
            if let currentRange = Range(match.range(at: 2), in: line),
               let totalRange = Range(match.range(at: 3), in: line) {
                result += " (\(String(line[currentRange]))/\(String(line[totalRange])))"
            }
            
            if let speedRange = Range(match.range(at: 4), in: line),
               let unitRange = Range(match.range(at: 5), in: line) {
                let speed = String(line[speedRange])
                let unit = String(line[unitRange])
                result += " [\(speed) \(unit)]"
            }
        }
        
        return result
    }
}
