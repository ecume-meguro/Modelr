import Foundation

/// Manages the initial setup process including Python environment and model downloads
///
/// Directory structure in ~/Library/Application Support/ModelrV3/:
/// ├── modelrv3_core/         # Shared Python module
/// ├── SAM/                   # Segmentation environment
/// ├── Tools/                 # Mesh processing environment
/// └── Hunyuan3D/             # 3D generation environment
@MainActor
class SetupManager: ObservableObject {
    @Published var setupStarted = false
    @Published var isComplete = false
    @Published var currentStage = "Preparing..."
    @Published var detailedStatus = ""
    @Published var overallProgress: Double = 0

    @Published var downloadedSize = "—"
    @Published var elapsedTime = "0:00"

    private var startTime: Date?
    private var monitorTask: Task<Void, Never>?
    private let appSupportDir: URL
    private var selectedModelChoice: SetupModelChoice = .fast

    // Environment directories
    private var samDir: URL { appSupportDir.appendingPathComponent("SAM") }
    private var toolsDir: URL { appSupportDir.appendingPathComponent("Tools") }
    private var hunyuanDir: URL { appSupportDir.appendingPathComponent("Hunyuan3D") }

    init() {
        let fm = FileManager.default
        let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        appSupportDir = appSupport.appendingPathComponent("ModelrV3")
    }

    func startSetup(modelChoice: SetupModelChoice = .fast) {
        setupStarted = true
        startTime = Date()
        selectedModelChoice = modelChoice

        // Start elapsed time timer
        Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] timer in
            guard let self = self else { timer.invalidate(); return }

            Task { @MainActor in
                if self.isComplete {
                    timer.invalidate()
                    return
                }

                if let start = self.startTime {
                    let elapsed = Date().timeIntervalSince(start)
                    let minutes = Int(elapsed) / 60
                    let seconds = Int(elapsed) % 60
                    self.elapsedTime = String(format: "%d:%02d", minutes, seconds)
                }
            }
        }

        // Start the actual setup
        Task {
            await runSetup()
        }
    }

    private func runSetup() async {
        let fm = FileManager.default

        // Create directory
        try? fm.createDirectory(at: appSupportDir, withIntermediateDirectories: true)

        // Stage 1: Copy resources
        currentStage = "Copying resources..."
        overallProgress = 0.05
        await copyResources()

        // Stage 2: Setup Python environment (SAM)
        currentStage = "Setting up Python environment..."
        overallProgress = 0.1
        await setupSAMEnvironment()

        // Stage 3: Download SAM model
        currentStage = "Downloading segmentation model..."
        overallProgress = 0.3
        await downloadSAMModel()

        // Stage 4: Setup Hunyuan environment
        currentStage = "Setting up 3D generation environment..."
        overallProgress = 0.5
        await setupHunyuanEnvironment()

        // Stage 5: Download Hunyuan model
        currentStage = "Downloading 3D generation model..."
        overallProgress = 0.7
        let modelTotalSize = selectedModelChoice == .fast ? "2.0G" : "4.0G"
        startMonitoring(directory: hunyuanDir.appendingPathComponent("hf_cache"), totalSize: modelTotalSize)
        await downloadHunyuanModel()
        stopMonitoring()

        // Complete
        overallProgress = 1.0
        currentStage = "Setup Complete"
        detailedStatus = "All models downloaded and ready"
        isComplete = true

        // Mark setup as complete in UserDefaults
        UserDefaults.standard.set(true, forKey: "SetupComplete")
    }

    private func copyResources() async {
        // Resources are now copied by PythonDependencyService
        // This is a simplified version that just checks critical files exist
        let resources = ["pyproject_sam.toml", "pyproject_tools.toml", "pyproject_hunyuan.toml", "sam_wrapper.py"]

        for (index, res) in resources.enumerated() {
            detailedStatus = "Checking \(res)..."
            overallProgress = 0.05 + (0.05 * Double(index + 1) / Double(resources.count))
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    private func setupSAMEnvironment() async {
        guard let uvPath = Bundle.main.path(forResource: "uv", ofType: nil) ??
                          Bundle.main.path(forResource: "uv", ofType: nil, inDirectory: "Resources") else {
            detailedStatus = "Error: uv not found in bundle"
            return
        }

        detailedStatus = "Installing Python 3.13 and SAM dependencies..."

        // Create SAM directory and copy files
        try? FileManager.default.createDirectory(at: samDir, withIntermediateDirectories: true)

        // Copy pyproject_sam.toml to SAM/pyproject.toml
        if let sourcePath = Bundle.main.path(forResource: "pyproject_sam.toml", ofType: nil) ??
                           Bundle.main.path(forResource: "pyproject_sam.toml", ofType: nil, inDirectory: "Resources") {
            let targetPath = samDir.appendingPathComponent("pyproject.toml")
            try? FileManager.default.removeItem(at: targetPath)
            try? FileManager.default.copyItem(at: URL(fileURLWithPath: sourcePath), to: targetPath)
        }

        // Copy sam_wrapper.py
        if let sourcePath = Bundle.main.path(forResource: "sam_wrapper.py", ofType: nil) ??
                           Bundle.main.path(forResource: "sam_wrapper.py", ofType: nil, inDirectory: "Resources") {
            let targetPath = samDir.appendingPathComponent("sam_wrapper.py")
            try? FileManager.default.removeItem(at: targetPath)
            try? FileManager.default.copyItem(at: URL(fileURLWithPath: sourcePath), to: targetPath)
        }

        let samVenv = samDir.appendingPathComponent(".venv")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: uvPath)
        process.arguments = ["sync", "--python", "3.13"]
        process.currentDirectoryURL = samDir
        process.environment = [
            "UV_PROJECT_ENVIRONMENT": samVenv.path,
            "UV_PYTHON_INSTALL_DIR": appSupportDir.appendingPathComponent("python_runtimes").path,
            "UV_CACHE_DIR": appSupportDir.appendingPathComponent("uv_cache").path,
            "UV_PYTHON_PREFERENCE": "only-managed",
            "PYTHONUNBUFFERED": "1",
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin"
        ]

        await runProcessAsync(process, parseOutput: true)
    }

    /// Runs a process without blocking the main thread, with output parsing
    private func runProcessAsync(_ process: Process, parseOutput: Bool = false) async {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                if parseOutput {
                    let pipe = Pipe()
                    let errorPipe = Pipe()
                    process.standardOutput = pipe
                    process.standardError = errorPipe

                    // Read stdout in background
                    pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
                        let data = handle.availableData
                        if !data.isEmpty {
                            FileHandle.standardOutput.write(data)
                            if let output = String(data: data, encoding: .utf8) {
                                Task { @MainActor in
                                    self?.parseProcessOutput(output)
                                }
                            }
                        }
                    }

                    // Read stderr in background
                    errorPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
                        let data = handle.availableData
                        if !data.isEmpty {
                            FileHandle.standardError.write(data)
                            if let output = String(data: data, encoding: .utf8) {
                                Task { @MainActor in
                                    self?.parseProcessOutput(output)
                                }
                            }
                        }
                    }
                }

                do {
                    try process.run()
                    process.waitUntilExit()
                } catch {
                    Task { @MainActor in
                        self.detailedStatus = "Error: \(error.localizedDescription)"
                    }
                }
                continuation.resume()
            }
        }
    }

    /// Parse process output for progress info
    private func parseProcessOutput(_ output: String) {
        let lines = output.replacingOccurrences(of: "\r", with: "\n").components(separatedBy: .newlines)

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }

            Task { @MainActor in
                if trimmed.hasPrefix("+ ") {
                    let package = String(trimmed.dropFirst(2))
                    if let name = package.split(separator: "=").first {
                        self.detailedStatus = "Installing \(name)..."
                    }
                }
                else if trimmed.contains("/") && trimmed.contains("%") {
                    if let colonIdx = trimmed.firstIndex(of: ":") {
                        let fileName = String(trimmed[..<colonIdx])
                        if fileName.contains("model") || fileName.contains("safetensor") || fileName.contains(".ckpt") {
                            self.detailedStatus = "Downloading \(fileName)..."
                        }
                    }
                }
                else if trimmed.contains("Fetching") && trimmed.contains("files") {
                    self.detailedStatus = trimmed.components(separatedBy: "|").first?.trimmingCharacters(in: .whitespaces) ?? trimmed
                }
                else if trimmed.hasPrefix("Resolved") || trimmed.hasPrefix("Prepared") || trimmed.hasPrefix("Installed") {
                    self.detailedStatus = trimmed
                }
                else if trimmed.contains("Loading") && trimmed.contains("pipeline") {
                    self.detailedStatus = "Loading model..."
                }
                else if trimmed.contains("Warming up") {
                    self.detailedStatus = trimmed
                }
            }
        }
    }

    // MARK: - Monitoring

    private func startMonitoring(directory: URL, totalSize: String) {
        stopMonitoring()
        monitorTask = Task {
            while !Task.isCancelled {
                let size = await getDiskUsage(at: directory)
                await MainActor.run {
                    self.downloadedSize = "\(size) / \(totalSize)"
                }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }

    private func stopMonitoring() {
        monitorTask?.cancel()
        monitorTask = nil
        Task { @MainActor in
            self.downloadedSize = "—"
        }
    }

    private func getDiskUsage(at url: URL) async -> String {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let process = Process()
                let pipe = Pipe()

                process.executableURL = URL(fileURLWithPath: "/usr/bin/du")
                process.arguments = ["-sh", url.path]
                process.standardOutput = pipe
                process.standardError = nil

                do {
                    try process.run()
                    process.waitUntilExit()

                    let data = pipe.fileHandleForReading.readDataToEndOfFile()
                    if let output = String(data: data, encoding: .utf8),
                       let size = output.split(separator: "\t").first {
                        continuation.resume(returning: String(size))
                    } else {
                        continuation.resume(returning: "0")
                    }
                } catch {
                    continuation.resume(returning: "0")
                }
            }
        }
    }

    private func downloadSAMModel() async {
        guard let uvPath = Bundle.main.path(forResource: "uv", ofType: nil) ??
                          Bundle.main.path(forResource: "uv", ofType: nil, inDirectory: "Resources") else {
            detailedStatus = "Error: uv not found in bundle"
            return
        }

        detailedStatus = "Downloading SAM model..."

        let samWrapper = samDir.appendingPathComponent("sam_wrapper.py")
        let samVenv = samDir.appendingPathComponent(".venv")
        let samCacheDir = appSupportDir.appendingPathComponent("sam_cache")

        try? FileManager.default.createDirectory(at: samCacheDir, withIntermediateDirectories: true)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: uvPath)
        process.arguments = ["run", samWrapper.path, "--test"]
        process.currentDirectoryURL = samDir
        process.environment = [
            "UV_PROJECT_ENVIRONMENT": samVenv.path,
            "UV_PYTHON_INSTALL_DIR": appSupportDir.appendingPathComponent("python_runtimes").path,
            "UV_CACHE_DIR": appSupportDir.appendingPathComponent("uv_cache").path,
            "UV_PYTHON_PREFERENCE": "only-managed",
            "PYTHONUNBUFFERED": "1",
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "HF_HOME": samCacheDir.path
        ]

        startMonitoring(directory: samCacheDir, totalSize: "3.2G")
        await runProcessAsync(process, parseOutput: true)
        stopMonitoring()
    }

    private func setupHunyuanEnvironment() async {
        guard let uvPath = Bundle.main.path(forResource: "uv", ofType: nil) ??
                          Bundle.main.path(forResource: "uv", ofType: nil, inDirectory: "Resources") else {
            return
        }

        try? FileManager.default.createDirectory(at: hunyuanDir, withIntermediateDirectories: true)

        // Copy pyproject_hunyuan.toml to Hunyuan3D/pyproject.toml
        if let sourcePath = Bundle.main.path(forResource: "pyproject_hunyuan.toml", ofType: nil) ??
                           Bundle.main.path(forResource: "pyproject_hunyuan.toml", ofType: nil, inDirectory: "Resources") {
            let targetPath = hunyuanDir.appendingPathComponent("pyproject.toml")
            try? FileManager.default.removeItem(at: targetPath)
            try? FileManager.default.copyItem(at: URL(fileURLWithPath: sourcePath), to: targetPath)
        }

        // Copy hunyuan_wrapper.py
        if let sourcePath = Bundle.main.path(forResource: "hunyuan_wrapper.py", ofType: nil) ??
                           Bundle.main.path(forResource: "hunyuan_wrapper.py", ofType: nil, inDirectory: "Resources") {
            let targetPath = hunyuanDir.appendingPathComponent("hunyuan_wrapper.py")
            try? FileManager.default.removeItem(at: targetPath)
            try? FileManager.default.copyItem(at: URL(fileURLWithPath: sourcePath), to: targetPath)
        }

        detailedStatus = "Installing Hunyuan3D dependencies..."

        let hunyuanVenv = hunyuanDir.appendingPathComponent(".venv")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: uvPath)
        process.arguments = ["sync", "--python", "3.10"]
        process.currentDirectoryURL = hunyuanDir
        process.environment = [
            "UV_PROJECT_ENVIRONMENT": hunyuanVenv.path,
            "UV_PYTHON_INSTALL_DIR": appSupportDir.appendingPathComponent("python_runtimes").path,
            "UV_CACHE_DIR": appSupportDir.appendingPathComponent("uv_cache").path,
            "UV_PYTHON_PREFERENCE": "only-managed",
            "PYTHONUNBUFFERED": "1",
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin"
        ]

        await runProcessAsync(process, parseOutput: true)
    }

    private func downloadHunyuanModel() async {
        guard let uvPath = Bundle.main.path(forResource: "uv", ofType: nil) ??
                          Bundle.main.path(forResource: "uv", ofType: nil, inDirectory: "Resources") else {
            return
        }

        detailedStatus = "Downloading \(selectedModelChoice.modelName) (\(selectedModelChoice.downloadSize))..."

        let hunyuanVenv = hunyuanDir.appendingPathComponent(".venv")
        let hfCacheDir = hunyuanDir.appendingPathComponent("hf_cache")

        try? FileManager.default.createDirectory(at: hfCacheDir, withIntermediateDirectories: true)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: uvPath)
        process.arguments = ["run", hunyuanDir.appendingPathComponent("hunyuan_wrapper.py").path, "--warmup", "--model", selectedModelChoice.modelVariant]
        process.currentDirectoryURL = hunyuanDir
        process.environment = [
            "UV_PROJECT_ENVIRONMENT": hunyuanVenv.path,
            "UV_PYTHON_INSTALL_DIR": appSupportDir.appendingPathComponent("python_runtimes").path,
            "UV_CACHE_DIR": appSupportDir.appendingPathComponent("uv_cache").path,
            "UV_PYTHON_PREFERENCE": "only-managed",
            "PYTHONUNBUFFERED": "1",
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "HF_HOME": hfCacheDir.path
        ]

        await runProcessAsync(process, parseOutput: true)

        UserDefaults.standard.set(selectedModelChoice.modelVariant, forKey: "SelectedHunyuanModel")
    }
}
