import Foundation
import AppKit

/// Available 3D model generators
enum GeneratorModel: String, CaseIterable, Identifiable {
    case hunyuan = "Hunyuan3D-2"
    case sf3d = "SF3D"
    case both = "Both"
    
    var id: String { rawValue }
    
    var description: String {
        switch self {
        case .hunyuan:
            return "Tencent's Hunyuan3D-2 (shape only, fast)"
        case .sf3d:
            return "Stability AI's SF3D (with textures)"
        case .both:
            return "Test both generators"
        }
    }
}

class PythonEnvironment: ObservableObject {
    @Published var isSetup = false
    @Published var status = "Welcome to Modelr V3"
    @Published var selfTestImage: NSImage?
    @Published var selfTestMask: NSImage?
    @Published var selfTest3DModelURL: URL?
    @Published var canProceed = false
    @Published var selectedModel = "base_plus"  // Default to recommended
    @Published var isProcessing = false
    @Published var hunyuanProgress: String = ""
    @Published var setupStarted = false  // Track if setup has begun
    @Published var canSkipSetup = false  // Track if we can skip the splash sequence

    // Interactive self-test state
    @Published var selfTestClickPoint: CGPoint? = nil  // Normalized 0-1
    @Published var selfTestPrompt: String = "Click on the center of the alpaca's body"
    @Published var selfTestAwaitingClick = false
    @Published var selfTestAttempts = 0
    @Published var referenceMaskCoverage: Double = 0  // Expected mask coverage %
    
    // Generator selection
    @Published var selectedGenerator: GeneratorModel = .hunyuan

    private let appSupportDir: URL
    private let venvDir: URL
    private let hunyuanVenvDir: URL
    private let sf3dVenvDir: URL
    private let pythonWorkingDir: URL

    private let fileManager = FileManager.default
    private let logger = SecureLogger.shared

    /// Used for dependency injection during unit tests
    var resourcePathOverride: String?

    // MARK: - Persistent Process State

    private var persistentProcess: Process?
    private var stdinPipe: Pipe?
    private var stdoutPipe: Pipe?
    private var responseBuffer = Data()
    private var currentImagePath: String?
    private var imagePixelSize: CGSize = .zero

    private let processQueue = DispatchQueue(label: "com.modelr.python.process")
    private var pendingContinuation: CheckedContinuation<SAMResponse, Error>?

    // Throughput monitoring
    private var throughputMonitorTask: Task<Void, Never>?
    private var lastDirectorySize: UInt64 = 0
    private var lastSizeCheckTime: Date = Date()

    init() {
        let fileManager = FileManager.default
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        appSupportDir = appSupport.appendingPathComponent("ModelrV3")
        venvDir = appSupportDir.appendingPathComponent(".venv")
        hunyuanVenvDir = appSupportDir.appendingPathComponent(".venv_hunyuan")
        sf3dVenvDir = appSupportDir.appendingPathComponent("SF3D/.venv")
        pythonWorkingDir = appSupportDir

        do {
            try fileManager.createDirectory(at: appSupportDir, withIntermediateDirectories: true)
        } catch {
            print("ERROR: Failed to create directory: \(error.localizedDescription)")
        }
        // Setup is started manually when user clicks "Begin Setup"
        checkExistingSetup()
    }

    deinit {
        stopPersistentWorker()
    }

    /// Check if the required environment and scripts already exist
    func checkExistingSetup() {
        let fm = FileManager.default
        let samWrapper = appSupportDir.appendingPathComponent("sam_wrapper.py").path
        let hunyuanWrapper = appSupportDir.appendingPathComponent("Hunyuan3D/hunyuan_wrapper.py").path
        let venv = venvDir.appendingPathComponent("bin/python").path
        let hunyuanVenv = appSupportDir.appendingPathComponent("Hunyuan3D/.venv/bin/python").path

        let filesExist = fm.fileExists(atPath: samWrapper) &&
                         fm.fileExists(atPath: hunyuanWrapper) &&
                         fm.fileExists(atPath: venv) &&
                         fm.fileExists(atPath: hunyuanVenv)

        DispatchQueue.main.async {
            self.canSkipSetup = filesExist
        }
    }

    /// Skip the setup and transition to the editor
    func skipSetup() {
        Task {
            // Find uv binary
            var uvPath = Bundle.main.path(forResource: "uv", ofType: nil)
            if uvPath == nil {
                uvPath = Bundle.main.path(forResource: "uv", ofType: nil, inDirectory: "Resources")
            }
            
            if let finalUvPath = uvPath {
                cachedUvPath = finalUvPath
                hunyuanVenvReady = true // Assume ready if we found the files
            }

            await MainActor.run {
                self.isSetup = true
                self.status = "Ready"
            }
        }
    }

    // MARK: - Setup

    func setup() async {
        await MainActor.run {
            setupStarted = true
            status = "Bootstrapping..."
        }

        var uvPath: String?
        if let override = resourcePathOverride {
            uvPath = (override as NSString).appendingPathComponent("uv")
        } else {
            uvPath = Bundle.main.path(forResource: "uv", ofType: nil)
            if uvPath == nil {
                uvPath = Bundle.main.path(forResource: "uv", ofType: nil, inDirectory: "Resources")
            }
        }

        guard let finalUvPath = uvPath else {
            print("ERROR: uv binary not found")
            await MainActor.run { status = "Error: uv not found" }
            return
        }

        // 0. Copy script resources to App Support
        await MainActor.run { status = "Syncing assets..." }
        let fm = FileManager.default
        let resources = ["sam_wrapper.py", "pyproject.toml", "self_test.jpg", "hunyuan_wrapper.py", "pyproject_hunyuan.toml", "correct_self_test_mask.png", "sf3d_wrapper.py", "pyproject_sf3d.toml"]
        for res in resources {
            let targetPath = appSupportDir.appendingPathComponent(res)
            var sourcePath: String?

            if let override = resourcePathOverride {
                sourcePath = (override as NSString).appendingPathComponent(res)
            } else {
                sourcePath = Bundle.main.path(forResource: res, ofType: nil)
                if sourcePath == nil {
                    sourcePath = Bundle.main.path(forResource: res, ofType: nil, inDirectory: "Resources")
                }
            }

            if let finalSource = sourcePath {
                print(">>> COPY: \(res) to \(targetPath.path)")
                do {
                    try fm.removeItem(at: targetPath)
                } catch {
                    print("ERROR: Failed to remove file at \(targetPath.path): \(error.localizedDescription)")
                }
                do {
                    try fm.copyItem(atPath: finalSource, toPath: targetPath.path)
                } catch {
                    print("ERROR: Failed to copy file from \(finalSource) to \(targetPath.path): \(error.localizedDescription)")
                }
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

    // MARK: - Throughput Monitoring

    /// Calculate total size of a directory recursively
    private func directorySize(at url: URL) -> UInt64 {
        let fm = FileManager.default
        var totalSize: UInt64 = 0

        guard let enumerator = fm.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey], options: [.skipsHiddenFiles]) else {
            return 0
        }

        for case let fileURL as URL in enumerator {
            if let fileSize = try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                totalSize += UInt64(fileSize)
            }
        }

        return totalSize
    }

    /// Format bytes as human-readable string
    private func formatBytes(_ bytes: UInt64) -> String {
        let kb = Double(bytes) / 1024
        let mb = kb / 1024
        let gb = mb / 1024

        if gb >= 1 {
            return String(format: "%.2f GB", gb)
        } else if mb >= 1 {
            return String(format: "%.1f MB", mb)
        } else {
            return String(format: "%.0f KB", kb)
        }
    }

    /// Format throughput as human-readable string
    private func formatThroughput(_ bytesPerSecond: Double) -> String {
        let kbps = bytesPerSecond / 1024
        let mbps = kbps / 1024

        if mbps >= 1 {
            return String(format: "%.1f MB/s", mbps)
        } else if kbps >= 1 {
            return String(format: "%.0f KB/s", kbps)
        } else {
            return "Connecting..."
        }
    }

    /// Start monitoring throughput for a directory
    private func startThroughputMonitor(directory: URL, statusPrefix: String) {
        // Cancel any existing monitor
        throughputMonitorTask?.cancel()

        lastDirectorySize = directorySize(at: directory)
        lastSizeCheckTime = Date()

        throughputMonitorTask = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000) // 1 second

                let currentSize = directorySize(at: directory)
                let currentTime = Date()
                let elapsed = currentTime.timeIntervalSince(lastSizeCheckTime)

                if elapsed > 0 {
                    let bytesDownloaded = currentSize > lastDirectorySize ? currentSize - lastDirectorySize : 0
                    let throughput = Double(bytesDownloaded) / elapsed

                    let totalDownloaded = formatBytes(currentSize)
                    let speed = formatThroughput(throughput)

                    if bytesDownloaded > 0 {
                        status = "\(statusPrefix) (\(totalDownloaded) @ \(speed))"
                    }

                    lastDirectorySize = currentSize
                    lastSizeCheckTime = currentTime
                }
            }
        }
    }

    /// Stop the throughput monitor
    private func stopThroughputMonitor() {
        throughputMonitorTask?.cancel()
        throughputMonitorTask = nil
    }

    @discardableResult
    private func execute(executable: String, arguments: [String], environment: [String: String]? = nil, workingDirectory: URL? = nil) async -> Bool {
        print("\n>>> EXEC: \(executable) \(arguments.joined(separator: " "))")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = workingDirectory ?? appSupportDir

        var currentEnv = ProcessInfo.processInfo.environment

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
                DispatchQueue.main.async {
                    // Parse progress messages
                    if line.contains("Testing segmentation model") {
                        self.status = "Testing segmentation model..."
                    } else if line.contains("Diffusion Sampling") {
                        // Extract percentage and speed: "Diffusion Sampling::  50%|█████     | 15/30 [00:06<00:06,  2.26it/s]"
                        if let match = line.range(of: #"(\d+)%.*?(\d+\.?\d*it/s)"#, options: .regularExpression) {
                            let progressStr = String(line[match])
                            if let pctMatch = progressStr.range(of: #"\d+%"#, options: .regularExpression),
                               let speedMatch = progressStr.range(of: #"\d+\.?\d*it/s"#, options: .regularExpression) {
                                let pct = String(progressStr[pctMatch])
                                let speed = String(progressStr[speedMatch])
                                self.status = "Diffusion Sampling: \(pct) (\(speed))"
                            }
                        }
                    } else if line.contains("Volume Decoding") {
                        // Extract percentage and speed
                        if let match = line.range(of: #"(\d+)%.*?(\d+\.?\d*it/s)"#, options: .regularExpression) {
                            let progressStr = String(line[match])
                            if let pctMatch = progressStr.range(of: #"\d+%"#, options: .regularExpression),
                               let speedMatch = progressStr.range(of: #"\d+\.?\d*it/s"#, options: .regularExpression) {
                                let pct = String(progressStr[pctMatch])
                                let speed = String(progressStr[speedMatch])
                                self.status = "Volume Decoding: \(pct) (\(speed))"
                            }
                        }
                    } else if line.contains("Loading Hunyuan3D pipeline") {
                        self.status = "Loading Hunyuan3D model..."
                    } else if line.contains("Generating 3D shape") {
                        self.status = "Generating 3D shape..."
                    } else if line.contains("Extracting foreground") {
                        self.status = "Extracting foreground..."
                    } else if line.contains("Model saved to") {
                        self.status = "3D model generated!"
                    } else if line.contains("download from huggingface") {
                        self.status = "Downloading Hunyuan3D model..."
                    } else if line.contains("Fetching") && line.contains("files") {
                        // "Fetching 3 files:  67%|██████▋   | 2/3"
                        if let match = line.range(of: #"\d+%"#, options: .regularExpression) {
                            let pct = String(line[match])
                            self.status = "Downloading model files: \(pct)"
                        }
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

    private var cachedUvPath: String?
    private var hunyuanVenvReady = false
    private var sf3dVenvReady = false

    private func runSelfTest(finalUvPath: String) async {
        cachedUvPath = finalUvPath

        // Step 1: Start SAM2 worker and download model
        await MainActor.run { status = "Downloading SAM2 model..." }

        // Monitor SAM2 checkpoint downloads
        let checkpointsDir = appSupportDir.appendingPathComponent("checkpoints")
        try? FileManager.default.createDirectory(at: checkpointsDir, withIntermediateDirectories: true)
        startThroughputMonitor(directory: checkpointsDir, statusPrefix: "Downloading SAM2 model")

        let testImgPath = appSupportDir.appendingPathComponent("self_test.jpg").path

        // Start persistent worker (this downloads SAM2 model if needed)
        do {
            try await startPersistentWorker()
        } catch {
            stopThroughputMonitor()
            await MainActor.run { status = "Error: Failed to start SAM2 worker" }
            return
        }

        stopThroughputMonitor()

        // Set the test image
        do {
            _ = try await setImage(path: testImgPath)
        } catch {
            await MainActor.run { status = "Error: Failed to load test image" }
            return
        }

        // Step 2: Setup 3D generators based on selection
        let generator = await MainActor.run { selectedGenerator }
        
        if generator == .hunyuan || generator == .both {
            // Setup Hunyuan3D environment and download model
            await MainActor.run { status = "Setting up Hunyuan3D environment..." }
            await setupHunyuanEnvironment(finalUvPath: finalUvPath)

            await MainActor.run { status = "Downloading Hunyuan3D model..." }

            // Monitor Hunyuan model downloads
            let hunyuanCacheDir = appSupportDir.appendingPathComponent("Hunyuan3D/hf_cache")
            try? FileManager.default.createDirectory(at: hunyuanCacheDir, withIntermediateDirectories: true)
            startThroughputMonitor(directory: hunyuanCacheDir, statusPrefix: "Downloading Hunyuan3D model")

            await downloadHunyuanModel(finalUvPath: finalUvPath)

            stopThroughputMonitor()
        }
        
        if generator == .sf3d || generator == .both {
            // Setup SF3D environment and download model
            await MainActor.run { status = "Setting up SF3D environment..." }
            await setupSF3DEnvironment(finalUvPath: finalUvPath)

            await MainActor.run { status = "Downloading SF3D model..." }

            // Monitor SF3D model downloads
            let sf3dCacheDir = appSupportDir.appendingPathComponent("SF3D/hf_cache")
            try? FileManager.default.createDirectory(at: sf3dCacheDir, withIntermediateDirectories: true)
            startThroughputMonitor(directory: sf3dCacheDir, statusPrefix: "Downloading SF3D model")

            await downloadSF3DModel(finalUvPath: finalUvPath)

            stopThroughputMonitor()
        }

        // Step 3: Now ready for user interaction - show click screen
        await MainActor.run {
            selfTestAwaitingClick = true
            selfTestPrompt = "Click on the center of the alpaca's body"
            status = "Click on the alpaca to continue"
        }
    }

    /// Setup Hunyuan3D virtual environment (without generating a model)
    private func setupHunyuanEnvironment(finalUvPath: String) async {
        let hunyuanPyprojectSource = appSupportDir.appendingPathComponent("pyproject_hunyuan.toml")
        let hunyuanDir = appSupportDir.appendingPathComponent("Hunyuan3D")
        let hunyuanPyprojectTarget = hunyuanDir.appendingPathComponent("pyproject.toml")

        let fm = FileManager.default
        try? fm.createDirectory(at: hunyuanDir, withIntermediateDirectories: true)
        try? fm.removeItem(at: hunyuanPyprojectTarget)
        try? fm.copyItem(at: hunyuanPyprojectSource, to: hunyuanPyprojectTarget)

        // Copy wrapper script
        let wrapperSource = appSupportDir.appendingPathComponent("hunyuan_wrapper.py")
        let wrapperTarget = hunyuanDir.appendingPathComponent("hunyuan_wrapper.py")
        try? fm.removeItem(at: wrapperTarget)
        try? fm.copyItem(at: wrapperSource, to: wrapperTarget)

        // Sync Hunyuan3D environment
        let hunyuanVenv = hunyuanDir.appendingPathComponent(".venv")
        let syncSuccess = await execute(
            executable: finalUvPath,
            arguments: ["sync", "--python", "3.10"],
            environment: [
                "UV_PROJECT_ENVIRONMENT": hunyuanVenv.path,
                "UV_PYTHON_INSTALL_DIR": appSupportDir.appendingPathComponent("python_runtimes").path,
                "UV_CACHE_DIR": appSupportDir.appendingPathComponent("uv_cache").path,
                "UV_PYTHON_PREFERENCE": "only-managed",
                "PYTHONUNBUFFERED": "1"
            ],
            workingDirectory: hunyuanDir
        )

        hunyuanVenvReady = syncSuccess
    }

    /// Pre-download Hunyuan3D model by running a warmup command
    private func downloadHunyuanModel(finalUvPath: String) async {
        guard hunyuanVenvReady else { return }

        let hunyuanDir = appSupportDir.appendingPathComponent("Hunyuan3D")
        let hunyuanVenv = hunyuanDir.appendingPathComponent(".venv")
        let hunyuanScript = hunyuanDir.appendingPathComponent("hunyuan_wrapper.py").path

        // Run with --warmup flag to just download model without generating
        _ = await execute(
            executable: finalUvPath,
            arguments: ["run", hunyuanScript, "--warmup"],
            environment: [
                "UV_PROJECT_ENVIRONMENT": hunyuanVenv.path,
                "UV_PYTHON_INSTALL_DIR": appSupportDir.appendingPathComponent("python_runtimes").path,
                "UV_CACHE_DIR": appSupportDir.appendingPathComponent("uv_cache").path,
                "UV_PYTHON_PREFERENCE": "only-managed",
                "PYTHONUNBUFFERED": "1"
            ],
            workingDirectory: hunyuanDir
        )
    }

    /// Setup SF3D virtual environment (without generating a model)
    private func setupSF3DEnvironment(finalUvPath: String) async {
        let sf3dPyprojectSource = appSupportDir.appendingPathComponent("pyproject_sf3d.toml")
        let sf3dDir = appSupportDir.appendingPathComponent("SF3D")
        let sf3dPyprojectTarget = sf3dDir.appendingPathComponent("pyproject.toml")

        let fm = FileManager.default
        try? fm.createDirectory(at: sf3dDir, withIntermediateDirectories: true)
        try? fm.removeItem(at: sf3dPyprojectTarget)
        try? fm.copyItem(at: sf3dPyprojectSource, to: sf3dPyprojectTarget)

        // Copy wrapper script
        let wrapperSource = appSupportDir.appendingPathComponent("sf3d_wrapper.py")
        let wrapperTarget = sf3dDir.appendingPathComponent("sf3d_wrapper.py")
        try? fm.removeItem(at: wrapperTarget)
        try? fm.copyItem(at: wrapperSource, to: wrapperTarget)
        
        // Clone stable-fast-3d repository for sf3d module access
        let sf3dRepoTarget = sf3dDir.appendingPathComponent("stable-fast-3d")
        if !fm.fileExists(atPath: sf3dRepoTarget.path) {
            await MainActor.run { status = "Cloning SF3D repository..." }
            // Clone the SF3D repository
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            process.arguments = ["clone", "--depth", "1", "https://github.com/Stability-AI/stable-fast-3d.git", sf3dRepoTarget.path]
            process.currentDirectoryURL = sf3dDir
            try? process.run()
            process.waitUntilExit()
        }

        // Sync SF3D environment (Python 3.10 for compatibility)
        // texture_baker and uv_unwrapper are installed from git subdirectories via pyproject.toml
        let sf3dVenv = sf3dDir.appendingPathComponent(".venv")
        let syncSuccess = await execute(
            executable: finalUvPath,
            arguments: ["sync", "--python", AppConstants.sf3dPythonVersion],
            environment: [
                "UV_PROJECT_ENVIRONMENT": sf3dVenv.path,
                "UV_PYTHON_INSTALL_DIR": appSupportDir.appendingPathComponent("python_runtimes").path,
                "UV_CACHE_DIR": appSupportDir.appendingPathComponent("uv_cache").path,
                "UV_PYTHON_PREFERENCE": "only-managed",
                "PYTHONUNBUFFERED": "1",
                "PYTORCH_ENABLE_MPS_FALLBACK": "1"
            ],
            workingDirectory: sf3dDir
        )
        
        guard syncSuccess else {
            sf3dVenvReady = false
            return
        }
        
        // Install texture_baker and uv_unwrapper from cloned repo with --no-build-isolation
        // These need setuptools which is now in the venv from uv sync
        await MainActor.run { status = "Installing SF3D texture baker..." }
        let textureBakerPath = sf3dRepoTarget.appendingPathComponent("texture_baker").path
        _ = await execute(
            executable: finalUvPath,
            arguments: ["pip", "install", "--no-build-isolation", textureBakerPath],
            environment: [
                "UV_PROJECT_ENVIRONMENT": sf3dVenv.path,
                "UV_PYTHON_INSTALL_DIR": appSupportDir.appendingPathComponent("python_runtimes").path,
                "UV_CACHE_DIR": appSupportDir.appendingPathComponent("uv_cache").path,
                "UV_PYTHON_PREFERENCE": "only-managed",
                "PYTHONUNBUFFERED": "1",
                "PYTORCH_ENABLE_MPS_FALLBACK": "1"
            ],
            workingDirectory: sf3dDir
        )
        
        await MainActor.run { status = "Installing SF3D UV unwrapper..." }
        let uvUnwrapperPath = sf3dRepoTarget.appendingPathComponent("uv_unwrapper").path
        _ = await execute(
            executable: finalUvPath,
            arguments: ["pip", "install", "--no-build-isolation", uvUnwrapperPath],
            environment: [
                "UV_PROJECT_ENVIRONMENT": sf3dVenv.path,
                "UV_PYTHON_INSTALL_DIR": appSupportDir.appendingPathComponent("python_runtimes").path,
                "UV_CACHE_DIR": appSupportDir.appendingPathComponent("uv_cache").path,
                "UV_PYTHON_PREFERENCE": "only-managed",
                "PYTHONUNBUFFERED": "1",
                "PYTORCH_ENABLE_MPS_FALLBACK": "1"
            ],
            workingDirectory: sf3dDir
        )

        sf3dVenvReady = syncSuccess
    }

    /// Pre-download SF3D model by running a warmup command
    private func downloadSF3DModel(finalUvPath: String) async {
        guard sf3dVenvReady else { return }

        let sf3dDir = appSupportDir.appendingPathComponent("SF3D")
        let sf3dVenv = sf3dDir.appendingPathComponent(".venv")
        let sf3dScript = sf3dDir.appendingPathComponent("sf3d_wrapper.py").path
        let sf3dRepoPath = sf3dDir.appendingPathComponent("stable-fast-3d").path

        // Run with --warmup flag to just download model without generating
        // PYTHONPATH includes cloned repo for sf3d module access
        _ = await execute(
            executable: finalUvPath,
            arguments: ["run", sf3dScript, "--warmup"],
            environment: [
                "UV_PROJECT_ENVIRONMENT": sf3dVenv.path,
                "UV_PYTHON_INSTALL_DIR": appSupportDir.appendingPathComponent("python_runtimes").path,
                "UV_CACHE_DIR": appSupportDir.appendingPathComponent("uv_cache").path,
                "UV_PYTHON_PREFERENCE": "only-managed",
                "PYTHONUNBUFFERED": "1",
                "PYTORCH_ENABLE_MPS_FALLBACK": "1",
                "PYTHONPATH": sf3dRepoPath
            ],
            workingDirectory: sf3dDir
        )
    }

    /// Called from SplashScreenView when user clicks on the test image
    func runSelfTestWithClick(normalizedPoint: CGPoint) async {
        guard let uvPath = cachedUvPath else { return }

        await MainActor.run {
            selfTestClickPoint = normalizedPoint
            selfTestAwaitingClick = false
            status = "Segmenting..."
        }

        let testImgPath = appSupportDir.appendingPathComponent("self_test.jpg").path

        // Create a SAMPoint from normalized coords
        let point = SAMPoint(normalizedCoords: normalizedPoint)

        do {
            let maskURL = try await predict(points: [point], box: nil, imageSize: imagePixelSize)
            let maskImage = NSImage(contentsOf: maskURL)

            await MainActor.run {
                selfTestMask = maskImage
                selfTestAttempts += 1
            }

            // Compare with reference mask
            let referenceMaskURL = appSupportDir.appendingPathComponent("correct_self_test_mask.png")
            let similarity = compareMasks(maskURL: maskURL, referenceURL: referenceMaskURL)
            print("Mask similarity to reference: \(String(format: "%.1f", similarity * 100))%")

            // If less than 90% similar (i.e., more than 10% different), ask to retry
            if similarity < 0.90 {
                await MainActor.run {
                    selfTestClickPoint = nil
                    selfTestMask = nil
                    selfTestAwaitingClick = true
                    selfTestPrompt = "That doesn't look right (\(Int((1-similarity)*100))% off). Try clicking on the alpaca's body again."
                    status = "Click on the alpaca to continue"
                }
                return
            }

            await MainActor.run {
                referenceMaskCoverage = similarity
                status = "Segmentation successful!"
            }

            // Continue to 3D generation based on selected generator
            let generator = await MainActor.run { selectedGenerator }
            switch generator {
            case .hunyuan:
                await runHunyuanSelfTest(finalUvPath: uvPath, maskPath: maskURL.path, imagePath: testImgPath)
            case .sf3d:
                await runSF3DSelfTest(finalUvPath: uvPath, maskPath: maskURL.path, imagePath: testImgPath)
            case .both:
                // Run Hunyuan first, then SF3D
                await runHunyuanSelfTest(finalUvPath: uvPath, maskPath: maskURL.path, imagePath: testImgPath)
                await runSF3DSelfTest(finalUvPath: uvPath, maskPath: maskURL.path, imagePath: testImgPath)
            }

        } catch {
            await MainActor.run {
                selfTestClickPoint = nil
                selfTestAwaitingClick = true
                selfTestPrompt = "Error occurred. Try clicking again."
                status = "Click on the alpaca to continue"
            }
        }
    }

    /// Compare two masks using Jaccard similarity (Intersection over Union).
    ///
    /// Algorithm:
    /// - Loads both mask images as RGBA bitmaps
    /// - Iterates over all pixels in the overlapping area
    /// - For each pixel, determines if it has content (alpha > 0.1)
    /// - Calculates:
    ///   - Intersection: Pixels where both masks agree (both have content or both empty)
    ///   - Union: Pixels where at least one mask has content
    /// - Returns: Intersection / Union (0.0 to 1.0)
    ///
    /// Similarity Interpretation:
    /// - 1.0 (100%): Masks are identical
    /// - 0.9 (90%): Minor differences (threshold for self-test pass)
    /// - 0.5 (50%): Half of the pixels disagree
    /// - 0.0 (0%): Completely different masks
    ///
    /// Time Complexity: O(w * h) where w=width, h=height
    /// Space Complexity: O(1)
    ///
    /// - Parameters:
    ///   - maskURL: URL to generated mask
    ///   - referenceURL: URL to reference (expected) mask
    /// - Returns: Jaccard similarity (0.0 to 1.0)
    private func compareMasks(maskURL: URL, referenceURL: URL) -> Double {
        guard let maskImage = NSImage(contentsOf: maskURL),
              let refImage = NSImage(contentsOf: referenceURL),
              let maskTiff = maskImage.tiffRepresentation,
              let refTiff = refImage.tiffRepresentation,
              let maskBitmap = NSBitmapImageRep(data: maskTiff),
              let refBitmap = NSBitmapImageRep(data: refTiff) else {
            print("Failed to load mask images for comparison")
            return 0
        }

        let width = min(maskBitmap.pixelsWide, refBitmap.pixelsWide)
        let height = min(maskBitmap.pixelsHigh, refBitmap.pixelsHigh)

        var matchingPixels = 0
        var totalMaskPixels = 0  // Pixels where either mask has content

        for y in 0..<height {
            for x in 0..<width {
                let maskAlpha = maskBitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0
                let refAlpha = refBitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0

                // Pixel is considered to have content if alpha > 0.1
                // This threshold filters out near-transparent pixels
                let maskHasContent = maskAlpha > 0.1
                let refHasContent = refAlpha > 0.1

                // Count pixels where either mask has content (union)
                if maskHasContent || refHasContent {
                    totalMaskPixels += 1
                    // Count where both agree (intersection)
                    if maskHasContent == refHasContent {
                        matchingPixels += 1
                    }
                }
            }
        }

        guard totalMaskPixels > 0 else { return 0 }

        // Jaccard similarity = Intersection / Union
        let similarity = Double(matchingPixels) / Double(totalMaskPixels)
        print("Mask comparison: \(matchingPixels)/\(totalMaskPixels) pixels match (\(String(format: "%.1f", similarity * 100))%)")
        return similarity
    }

    private func runHunyuanSelfTest(finalUvPath: String, maskPath: String, imagePath: String) async {
        guard hunyuanVenvReady else {
            await MainActor.run {
                self.canProceed = true
                status = "Ready - Click 'Open Editor' to continue"
            }
            return
        }

        await MainActor.run { status = "Generating 3D model..." }

        let hunyuanDir = appSupportDir.appendingPathComponent("Hunyuan3D")
        let hunyuanVenv = hunyuanDir.appendingPathComponent(".venv")
        let hunyuanScript = hunyuanDir.appendingPathComponent("hunyuan_wrapper.py").path
        let fm = FileManager.default

        // Run Hunyuan3D self-test (model already downloaded during warmup)
        let modelSuccess = await execute(
            executable: finalUvPath,
            arguments: ["run", hunyuanScript, "--test", maskPath, imagePath, "--output-dir", hunyuanDir.path],
            environment: [
                "UV_PROJECT_ENVIRONMENT": hunyuanVenv.path,
                "UV_PYTHON_INSTALL_DIR": appSupportDir.appendingPathComponent("python_runtimes").path,
                "UV_CACHE_DIR": appSupportDir.appendingPathComponent("uv_cache").path,
                "UV_PYTHON_PREFERENCE": "only-managed",
                "PYTHONUNBUFFERED": "1"
            ],
            workingDirectory: hunyuanDir
        )

        let modelURL = hunyuanDir.appendingPathComponent("self_test_model.obj")

        await MainActor.run {
            if modelSuccess && fm.fileExists(atPath: modelURL.path) {
                self.selfTest3DModelURL = modelURL
                self.canProceed = true
                status = "Ready - Click 'Open Editor' to continue"
            } else {
                // Still allow proceeding if SAM2 worked but Hunyuan failed
                self.canProceed = true
                status = "Ready - Click 'Open Editor' to continue"
            }
        }
    }

    /// Run SF3D self-test to generate 3D model
    private func runSF3DSelfTest(finalUvPath: String, maskPath: String, imagePath: String) async {
        guard sf3dVenvReady else {
            await MainActor.run {
                self.canProceed = true
                status = "Ready - Click 'Open Editor' to continue"
            }
            return
        }

        await MainActor.run { status = "Generating 3D model with SF3D..." }

        let sf3dDir = appSupportDir.appendingPathComponent("SF3D")
        let sf3dVenv = sf3dDir.appendingPathComponent(".venv")
        let sf3dScript = sf3dDir.appendingPathComponent("sf3d_wrapper.py").path
        let sf3dRepoPath = sf3dDir.appendingPathComponent("stable-fast-3d").path
        let fm = FileManager.default

        // Run SF3D self-test (model already downloaded during warmup)
        let modelSuccess = await execute(
            executable: finalUvPath,
            arguments: ["run", sf3dScript, "--test", maskPath, imagePath, "--output-dir", sf3dDir.path],
            environment: [
                "UV_PROJECT_ENVIRONMENT": sf3dVenv.path,
                "UV_PYTHON_INSTALL_DIR": appSupportDir.appendingPathComponent("python_runtimes").path,
                "UV_CACHE_DIR": appSupportDir.appendingPathComponent("uv_cache").path,
                "UV_PYTHON_PREFERENCE": "only-managed",
                "PYTHONUNBUFFERED": "1",
                "PYTORCH_ENABLE_MPS_FALLBACK": "1",
                "PYTHONPATH": sf3dRepoPath
            ],
            workingDirectory: sf3dDir
        )

        // SF3D outputs OBJ format with MTL and texture files
        let modelURL = sf3dDir.appendingPathComponent("self_test_model_sf3d.obj")

        await MainActor.run {
            if modelSuccess && fm.fileExists(atPath: modelURL.path) {
                self.selfTest3DModelURL = modelURL
                self.canProceed = true
                status = "Ready - Click 'Open Editor' to continue"
            } else {
                // Still allow proceeding if SAM2 worked but SF3D failed
                self.canProceed = true
                status = "Ready - Click 'Open Editor' to continue"
            }
        }
    }

    // MARK: - Persistent Worker Management

    /// Start the persistent Python worker process
    func startPersistentWorker() async throws {
        guard persistentProcess == nil else {
            print("Persistent worker already running")
            return
        }

        var uvPath = Bundle.main.path(forResource: "uv", ofType: nil)
        if uvPath == nil {
            uvPath = Bundle.main.path(forResource: "uv", ofType: nil, inDirectory: "Resources")
        }
        guard let finalUvPath = uvPath else {
            throw PythonError.uvNotFound
        }

        let scriptPath = appSupportDir.appendingPathComponent("sam_wrapper.py").path

        let process = Process()
        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()

        process.executableURL = URL(fileURLWithPath: finalUvPath)
        process.arguments = [
            "run", scriptPath,
            "--server",
            "--model", selectedModel,
            "--output-dir", appSupportDir.path
        ]
        process.currentDirectoryURL = appSupportDir

        var currentEnv = ProcessInfo.processInfo.environment
        currentEnv["UV_PROJECT_ENVIRONMENT"] = venvDir.path
        currentEnv["UV_PYTHON_INSTALL_DIR"] = appSupportDir.appendingPathComponent("python_runtimes").path
        currentEnv["UV_CACHE_DIR"] = appSupportDir.appendingPathComponent("uv_cache").path
        currentEnv["UV_PYTHON_PREFERENCE"] = "only-managed"
        currentEnv["PYTHONUNBUFFERED"] = "1"
        currentEnv["PYTHONPATH"] = appSupportDir.path
        process.environment = currentEnv

        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr

        // Handle stderr (for logging)
        stderr.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if let line = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines), !line.isEmpty {
                print("[Python stderr] \(line)")
            }
        }

        // Handle stdout (JSON responses)
        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            self?.handleStdoutData(data)
        }

        try process.run()

        self.persistentProcess = process
        self.stdinPipe = stdin
        self.stdoutPipe = stdout

        print("Persistent worker started with PID \(process.processIdentifier)")

        // Wait for ready signal
        let response = try await waitForResponse(timeout: 30)
        guard response.ready == true else {
            throw PythonError.workerNotReady
        }

        print("Persistent worker ready")
    }

    /// Stop the persistent Python worker
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
        currentImagePath = nil
        imagePixelSize = .zero

        print("Persistent worker stopped")
    }

    private func handleStdoutData(_ data: Data) {
        responseBuffer.append(data)

        // Look for complete JSON lines
        while let newlineRange = responseBuffer.range(of: Data("\n".utf8)) {
            let lineData = responseBuffer.subdata(in: responseBuffer.startIndex..<newlineRange.lowerBound)
            responseBuffer.removeSubrange(responseBuffer.startIndex...newlineRange.lowerBound)

            guard let line = String(data: lineData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !line.isEmpty else { continue }

            do {
                let response = try JSONDecoder().decode(SAMResponse.self, from: Data(line.utf8))
                if let continuation = pendingContinuation {
                    pendingContinuation = nil
                    continuation.resume(returning: response)
                }
            } catch {
                print("Failed to decode response: \(error), line: \(line)")
                if let continuation = pendingContinuation {
                    pendingContinuation = nil
                    continuation.resume(throwing: PythonError.invalidResponse(line))
                }
            }
        }
    }

    private func sendRequest(_ request: SAMRequest) async throws -> SAMResponse {
        guard let stdin = stdinPipe?.fileHandleForWriting else {
            throw PythonError.workerNotRunning
        }

        let jsonData = try JSONEncoder().encode(request)
        guard var jsonString = String(data: jsonData, encoding: .utf8) else {
            throw PythonError.encodingError
        }
        jsonString += "\n"

        return try await withCheckedThrowingContinuation { continuation in
            self.pendingContinuation = continuation

            do {
                try stdin.write(contentsOf: Data(jsonString.utf8))
            } catch {
                self.pendingContinuation = nil
                continuation.resume(throwing: error)
            }
        }
    }

    private func waitForResponse(timeout: TimeInterval) async throws -> SAMResponse {
        try await withCheckedThrowingContinuation { continuation in
            self.pendingContinuation = continuation

            // Set timeout
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [weak self] in
                if let cont = self?.pendingContinuation {
                    self?.pendingContinuation = nil
                    cont.resume(throwing: PythonError.timeout)
                }
            }
        }
    }

    // MARK: - Image & Prediction API

    /// Set the current image for prediction
    func setImage(path: String) async throws -> CGSize {
        // Start worker if needed
        if persistentProcess == nil || !persistentProcess!.isRunning {
            try await startPersistentWorker()
        }

        let request = SAMRequest(command: "set_image", imagePath: path)
        let response = try await sendRequest(request)

        guard response.success else {
            throw PythonError.predictionFailed(response.error ?? "Unknown error")
        }

        currentImagePath = path

        // Parse dimensions from response (need to add width/height to SAMResponse)
        // For now, we'll get them from the image file
        if let image = NSImage(contentsOfFile: path),
           let rep = image.representations.first {
            imagePixelSize = CGSize(width: CGFloat(rep.pixelsWide), height: CGFloat(rep.pixelsHigh))
        }

        return imagePixelSize
    }

    /// Run prediction with points and/or box
    func predict(points: [SAMPoint], box: SAMBox?, imageSize: CGSize) async throws -> URL {
        guard persistentProcess?.isRunning == true else {
            throw PythonError.workerNotRunning
        }

        await MainActor.run {
            isProcessing = true
            status = "Segmenting..."
        }

        defer {
            Task { @MainActor in
                isProcessing = false
                status = "Ready"
            }
        }

        // Convert points to pixel coordinates
        let pixelPoints: [[Int]] = points.map { point in
            let coords = point.pixelCoords(for: imageSize)
            return [coords.x, coords.y]
        }

        // Convert box to pixel coordinates
        let pixelBox: [Int]? = box?.pixelBox(for: imageSize)

        let request = SAMRequest(
            command: "predict",
            points: pixelPoints.isEmpty ? nil : pixelPoints,
            box: pixelBox
        )

        let response = try await sendRequest(request)

        guard response.success, let maskPath = response.maskPath else {
            throw PythonError.predictionFailed(response.error ?? "Unknown error")
        }

        if let inferenceTime = response.inferenceTimeMs {
            print("Inference completed in \(inferenceTime)ms")
        }

        return URL(fileURLWithPath: maskPath)
    }

    /// Reset the predictor state
    func resetPredictor() async throws {
        guard persistentProcess?.isRunning == true else { return }

        let request = SAMRequest(command: "reset")
        let _ = try await sendRequest(request)

        currentImagePath = nil
        imagePixelSize = .zero
    }

    // MARK: - 3D Model Generation

    /// Generate a 3D model from an image and mask
    func generate3DModel(
        imagePath: String,
        maskPath: String,
        steps: Int,
        resolution: Int,
        progress: @escaping (String) -> Void,
        completion: @escaping (Result<URL, Error>) -> Void
    ) async {
        var uvPath = Bundle.main.path(forResource: "uv", ofType: nil)
        if uvPath == nil {
            uvPath = Bundle.main.path(forResource: "uv", ofType: nil, inDirectory: "Resources")
        }
        guard let finalUvPath = uvPath else {
            completion(.failure(PythonError.uvNotFound))
            return
        }

        guard hunyuanVenvReady else {
            completion(.failure(PythonError.predictionFailed("Hunyuan3D environment not ready")))
            return
        }

        let hunyuanDir = appSupportDir.appendingPathComponent("Hunyuan3D")
        let hunyuanVenv = hunyuanDir.appendingPathComponent(".venv")
        let hunyuanScript = hunyuanDir.appendingPathComponent("hunyuan_wrapper.py").path

        // Generate unique output path
        let timestamp = Int(Date().timeIntervalSince1970)
        let outputPath = hunyuanDir.appendingPathComponent("generated_model_\(timestamp).obj")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: finalUvPath)
        process.arguments = [
            "run", hunyuanScript,
            "--image", imagePath,
            "--mask", maskPath,
            "--output", outputPath.path,
            "--output-dir", hunyuanDir.path,
            "--steps", "\(steps)",
            "--resolution", "\(resolution)"
        ]
        process.currentDirectoryURL = hunyuanDir

        var currentEnv = ProcessInfo.processInfo.environment
        currentEnv["UV_PROJECT_ENVIRONMENT"] = hunyuanVenv.path
        currentEnv["UV_PYTHON_INSTALL_DIR"] = appSupportDir.appendingPathComponent("python_runtimes").path
        currentEnv["UV_CACHE_DIR"] = appSupportDir.appendingPathComponent("uv_cache").path
        currentEnv["UV_PYTHON_PREFERENCE"] = "only-managed"
        currentEnv["PYTHONUNBUFFERED"] = "1"
        process.environment = currentEnv

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if let line = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines), !line.isEmpty {
                print("[Hunyuan] \(line)")

                // Parse progress with detailed info
                // tqdm format: "Diffusion Sampling::  50%|█████     | 15/30 [00:06<00:06,  2.26it/s]"
                if line.contains("Extracting foreground") {
                    progress("Extracting foreground...")
                } else if line.contains("Loading Hunyuan3D pipeline") {
                    progress("Loading model...")
                } else if line.contains("Generating 3D shape") {
                    progress("Generating 3D shape...")
                } else if line.contains("Diffusion Sampling") {
                    let progressStr = self.parseDetailedProgress(line, stage: "Diffusion Sampling")
                    progress(progressStr)
                } else if line.contains("Volume Decoding") {
                    let progressStr = self.parseDetailedProgress(line, stage: "Volume Decoding")
                    progress(progressStr)
                } else if line.contains("Model saved to") {
                    progress("Saving model...")
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

        // Wait for process in background
        Task.detached {
            process.waitUntilExit()
            pipe.fileHandleForReading.readabilityHandler = nil

            let fm = FileManager.default
            if process.terminationStatus == 0 && fm.fileExists(atPath: outputPath.path) {
                completion(.success(outputPath))
            } else {
                completion(.failure(PythonError.predictionFailed("3D generation failed")))
            }
        }
    }

    /// Parse tqdm-style progress bar output into a structured string.
    ///
    /// Algorithm:
    /// - Uses a single regex with multiple capture groups to extract:
    ///   1. Percentage: \d+% (e.g., "50%")
    ///   2. Current step: \d+ (e.g., "15")
    ///   3. Total steps: \d+ (e.g., "30")
    ///   4. Speed value: \d+\.?\d* (e.g., "2.26")
    ///   5. Speed unit: it/s or s/it
    /// - Formats extracted data into human-readable string
    ///
    /// Input Example:
    /// "Diffusion Sampling::  50%|█████     | 15/30 [00:06<00:06,  2.26it/s]"
    ///
    /// Output Example:
    /// "Diffusion Sampling: 50% (15/30) [2.26 it/s]"
    ///
    /// Regex Breakdown:
    /// - #"(\d+)%                    # Capture group 1: Percentage (50%)
    /// - .*?\|                         # Skip to progress bar separator
    /// - \s*(\d+)/(\d+)            # Capture groups 2-3: Current/Total steps (15/30)
    /// - .*?(\d+\.?\d*)             # Capture group 4: Speed value (2.26)
    /// - \s*(it/s|s/it)"#           # Capture group 5: Speed unit (it/s or s/it)
    ///
    /// Time Complexity: O(n) where n = length of input string (regex matching)
    /// Space Complexity: O(m) where m = length of output string
    ///
    /// - Parameters:
    ///   - line: Progress output line from Python/Hunyuan
    ///   - stage: Human-readable stage name (e.g., "Diffusion Sampling")
    /// - Returns: Formatted progress string
    private func parseDetailedProgress(_ line: String, stage: String) -> String {
        var result = stage

        // Single regex with capture groups for percentage, step count, and speed
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

    // MARK: - Legacy API (for backwards compatibility)

    /// Legacy single-shot prediction (spawns new process each time)
    @available(*, deprecated, message: "Use setImage() and predict() for faster iterative refinement")
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
            arguments: ["run", scriptPath, "--model", selectedModel, imagePath, "\(x)", "\(y)", maskPath],
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

// MARK: - Error Types

enum PythonError: Error, LocalizedError {
    case uvNotFound
    case workerNotRunning
    case workerNotReady
    case encodingError
    case invalidResponse(String)
    case predictionFailed(String)
    case timeout

    var errorDescription: String? {
        switch self {
        case .uvNotFound:
            return "uv binary not found"
        case .workerNotRunning:
            return "Python worker is not running"
        case .workerNotReady:
            return "Python worker failed to start"
        case .encodingError:
            return "Failed to encode request"
        case .invalidResponse(let response):
            return "Invalid response from worker: \(response)"
        case .predictionFailed(let error):
            return "Prediction failed: \(error)"
        case .timeout:
            return "Request timed out"
        }
    }
}
