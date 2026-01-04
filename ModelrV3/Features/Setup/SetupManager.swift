import Foundation

/// Manages the initial setup process including Python environment and model downloads
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

        // Stage 2: Setup Python environment
        currentStage = "Setting up Python environment..."
        overallProgress = 0.1
        await setupPythonEnvironment()

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
        startMonitoring(directory: appSupportDir.appendingPathComponent("Hunyuan3D/hf_cache"), totalSize: modelTotalSize)
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
        let resources = ["sam_wrapper.py", "pyproject.toml"]

        for (index, res) in resources.enumerated() {
            detailedStatus = "Copying \(res)..."

            let targetPath = appSupportDir.appendingPathComponent(res)
            if let sourcePath = Bundle.main.path(forResource: res, ofType: nil) ??
                                Bundle.main.path(forResource: res, ofType: nil, inDirectory: "Resources") {
                do {
                    try? FileManager.default.removeItem(at: targetPath)
                    try FileManager.default.copyItem(at: URL(fileURLWithPath: sourcePath), to: targetPath)
                } catch {
                    print("[Setup] Failed to copy \(res): \(error)")
                }
            }

            overallProgress = 0.05 + (0.05 * Double(index + 1) / Double(resources.count))
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
    }

    private func setupPythonEnvironment() async {
        guard let uvPath = Bundle.main.path(forResource: "uv", ofType: nil) ??
                          Bundle.main.path(forResource: "uv", ofType: nil, inDirectory: "Resources") else {
            detailedStatus = "Error: uv not found in bundle"
            return
        }

        detailedStatus = "Installing Python 3.13 and dependencies..."

        let venvDir = appSupportDir.appendingPathComponent(".venv")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: uvPath)
        process.arguments = ["sync", "--python", "3.13"]
        process.currentDirectoryURL = appSupportDir
        process.environment = [
            "UV_PROJECT_ENVIRONMENT": venvDir.path,
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
                            // Pass through to terminal
                            FileHandle.standardOutput.write(data)
                            if let output = String(data: data, encoding: .utf8) {
                                Task { @MainActor in
                                    self?.parseProcessOutput(output)
                                }
                            }
                        }
                    }

                    // Read stderr in background (tqdm writes to stderr)
                    errorPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
                        let data = handle.availableData
                        if !data.isEmpty {
                            // Pass through to terminal
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
        // Handle carriage returns (tqdm uses \r for progress updates)
        let lines = output.replacingOccurrences(of: "\r", with: "\n").components(separatedBy: .newlines)

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }

            Task { @MainActor in
                // UV package installation: "+ package==version"
                if trimmed.hasPrefix("+ ") {
                    let package = String(trimmed.dropFirst(2))
                    if let name = package.split(separator: "=").first {
                        self.detailedStatus = "Installing \(name)..."
                    }
                }
                // HuggingFace download progress - show file being downloaded
                else if trimmed.contains("/") && trimmed.contains("%") {
                    if let colonIdx = trimmed.firstIndex(of: ":") {
                        let fileName = String(trimmed[..<colonIdx])
                        if fileName.contains("model") || fileName.contains("safetensor") || fileName.contains(".ckpt") {
                            self.detailedStatus = "Downloading \(fileName)..."
                        }
                    }
                }
                // Fetching files progress
                else if trimmed.contains("Fetching") && trimmed.contains("files") {
                    self.detailedStatus = trimmed.components(separatedBy: "|").first?.trimmingCharacters(in: .whitespaces) ?? trimmed
                }
                // Resolved/Prepared/Installed packages
                else if trimmed.hasPrefix("Resolved") || trimmed.hasPrefix("Prepared") || trimmed.hasPrefix("Installed") {
                    self.detailedStatus = trimmed
                }
                // Loading model
                else if trimmed.contains("Loading") && trimmed.contains("pipeline") {
                    self.detailedStatus = "Loading model..."
                }
                // Warming up
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
                try? await Task.sleep(nanoseconds: 1_000_000_000)  // 1 second
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

        let samWrapper = appSupportDir.appendingPathComponent("sam_wrapper.py")
        let venvDir = appSupportDir.appendingPathComponent(".venv")
        let samCacheDir = appSupportDir.appendingPathComponent("sam_cache")

        // Create cache directory
        try? FileManager.default.createDirectory(at: samCacheDir, withIntermediateDirectories: true)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: uvPath)
        process.arguments = ["run", samWrapper.path, "--test"]
        process.currentDirectoryURL = appSupportDir
        process.environment = [
            "UV_PROJECT_ENVIRONMENT": venvDir.path,
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

        // Copy Hunyuan resources
        let hunyuanDir = appSupportDir.appendingPathComponent("Hunyuan3D")
        try? FileManager.default.createDirectory(at: hunyuanDir, withIntermediateDirectories: true)

        // Copy pyproject_hunyuan.toml
        if let sourcePath = Bundle.main.path(forResource: "pyproject_hunyuan.toml", ofType: nil) ??
                           Bundle.main.path(forResource: "pyproject_hunyuan.toml", ofType: nil, inDirectory: "Resources") {
            let targetPath = hunyuanDir.appendingPathComponent("pyproject.toml")
            do {
                try? FileManager.default.removeItem(at: targetPath)
                try FileManager.default.copyItem(at: URL(fileURLWithPath: sourcePath), to: targetPath)
            } catch {
                print("[Setup] Failed to copy pyproject_hunyuan.toml: \(error)")
            }
        }

        // Copy hunyuan_wrapper.py
        if let sourcePath = Bundle.main.path(forResource: "hunyuan_wrapper.py", ofType: nil) ??
                           Bundle.main.path(forResource: "hunyuan_wrapper.py", ofType: nil, inDirectory: "Resources") {
            let targetPath = hunyuanDir.appendingPathComponent("hunyuan_wrapper.py")
            do {
                try? FileManager.default.removeItem(at: targetPath)
                try FileManager.default.copyItem(at: URL(fileURLWithPath: sourcePath), to: targetPath)
            } catch {
                print("[Setup] Failed to copy hunyuan_wrapper.py: \(error)")
            }
        }

        detailedStatus = "Installing Hunyuan3D dependencies..."

        let venvDir = appSupportDir.appendingPathComponent(".venv_hunyuan")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: uvPath)
        process.arguments = ["sync", "--python", "3.10"]
        process.currentDirectoryURL = hunyuanDir
        process.environment = [
            "UV_PROJECT_ENVIRONMENT": venvDir.path,
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

        let hunyuanDir = appSupportDir.appendingPathComponent("Hunyuan3D")
        let venvDir = appSupportDir.appendingPathComponent(".venv_hunyuan")
        let hfCacheDir = hunyuanDir.appendingPathComponent("hf_cache")

        // Create cache directory for monitoring
        try? FileManager.default.createDirectory(at: hfCacheDir, withIntermediateDirectories: true)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: uvPath)
        process.arguments = ["run", hunyuanDir.appendingPathComponent("hunyuan_wrapper.py").path, "--warmup", "--model", selectedModelChoice.modelVariant]
        process.currentDirectoryURL = hunyuanDir
        process.environment = [
            "UV_PROJECT_ENVIRONMENT": venvDir.path,
            "UV_PYTHON_INSTALL_DIR": appSupportDir.appendingPathComponent("python_runtimes").path,
            "UV_CACHE_DIR": appSupportDir.appendingPathComponent("uv_cache").path,
            "UV_PYTHON_PREFERENCE": "only-managed",
            "PYTHONUNBUFFERED": "1",
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "HF_HOME": hunyuanDir.appendingPathComponent("hf_cache").path
        ]

        await runProcessAsync(process, parseOutput: true)

        // Save the selected model choice for later use
        UserDefaults.standard.set(selectedModelChoice.modelVariant, forKey: "SelectedHunyuanModel")
    }
}
