import Foundation
import AppKit

/// Available 3D model generators
enum GeneratorModel: String, CaseIterable, Identifiable {
    case hunyuan = "Hunyuan3D-2"
    
    var id: String { rawValue }
    
    var description: String {
        switch self {
        case .hunyuan:
            return "Tencent's Hunyuan3D-2 (shape only, fast)"
        }
    }
}

class PythonEnvironment: ObservableObject {
    @Published var isSetup = false
    @Published var status = "Initializing..."
    @Published var selectedModel = "base_plus"  // Default to recommended
    @Published var isProcessing = false
    @Published var hunyuanProgress: String = ""
    @Published var samModelReady = false  // Tracks if SAM worker is loaded and ready

    // Generator selection
    @Published var selectedGenerator: GeneratorModel = .hunyuan

    private let appSupportDir: URL
    private let venvDir: URL
    private let hunyuanVenvDir: URL
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

    // Generation process tracking (for cancellation)
    private var currentGenerationProcess: Process?
    @Published var isGenerationCancelled = false

    init() {
        let fileManager = FileManager.default
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        appSupportDir = appSupport.appendingPathComponent("ModelrV3")
        venvDir = appSupportDir.appendingPathComponent(".venv")
        hunyuanVenvDir = appSupportDir.appendingPathComponent(".venv_hunyuan")
        pythonWorkingDir = appSupportDir

        do {
            try fileManager.createDirectory(at: appSupportDir, withIntermediateDirectories: true)
        } catch {
            print("ERROR: Failed to create directory: \(error.localizedDescription)")
        }
        
        // Start setup automatically in background
        Task {
            await setup()
        }
    }

    deinit {
        stopPersistentWorker()
    }

    // MARK: - Setup

    func setup() async {
        await MainActor.run {
            status = "Bootstrapping..."
        }

        var uvPath: String?
        if let override = resourcePathOverride {
            uvPath = override
        } else {
            uvPath = Bundle.main.path(forResource: "uv", ofType: nil)
            if uvPath == nil {
                uvPath = Bundle.main.path(forResource: "uv", ofType: nil, inDirectory: "Resources")
            }
        }

        guard let finalUvPath = uvPath else {
            await MainActor.run { status = "Error: uv not found" }
            return
        }
        
        cachedUvPath = finalUvPath

        // Create Application Support directory
        let fm = FileManager.default
        let resources = ["sam_wrapper.py", "pyproject.toml", "hunyuan_wrapper.py", "pyproject_hunyuan.toml"]

        for res in resources {
            let targetPath = appSupportDir.appendingPathComponent(res)
            var sourcePath: String?

            if let override = resourcePathOverride {
                // In tests, assume resources are in the same directory as override
                sourcePath = URL(fileURLWithPath: override).deletingLastPathComponent().appendingPathComponent(res).path
            } else {
                sourcePath = Bundle.main.path(forResource: res, ofType: nil)
                if sourcePath == nil {
                     sourcePath = Bundle.main.path(forResource: res, ofType: nil, inDirectory: "Resources")
                }
            }

            if let source = sourcePath {
                if !fm.fileExists(atPath: targetPath.path) {
                    try? fm.copyItem(at: URL(fileURLWithPath: source), to: targetPath)
                }
            }
        }

        // 1. Sync Environment (this will also install python locally if needed)
        await MainActor.run { status = "Setting up Python environment..." }

        let syncSuccess = await execute(
            executable: finalUvPath,
            arguments: ["sync", "--python", "3.13"],
            environment: [
                "UV_PROJECT_ENVIRONMENT": venvDir.path,
                "UV_PYTHON_INSTALL_DIR": appSupportDir.appendingPathComponent("python_runtimes").path,
                "UV_CACHE_DIR": appSupportDir.appendingPathComponent("uv_cache").path,
                "UV_PYTHON_PREFERENCE": "only-managed",
                "PYTHONUNBUFFERED": "1"
            ]
        )

        if syncSuccess {
            // Setup Hunyuan environment
            await setupHunyuanEnvironment(finalUvPath: finalUvPath)
            await downloadHunyuanModel(finalUvPath: finalUvPath)
            
            await MainActor.run {
                self.isSetup = true
                self.status = "Ready"
            }
        } else {
            await MainActor.run { status = "Setup failed" }
        }
    }
    
    // ... existing Hunyuan methods ...

    // MARK: - Setup



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
        await MainActor.run { samModelReady = true }
    }

    /// Preload the SAM model for faster segmentation
    func preloadSAMModel() async {
        guard !samModelReady else { return }
        await MainActor.run { status = "Loading SAM model..." }
        do {
            try await startPersistentWorker()
        } catch {
            print("Failed to preload SAM model: \(error)")
        }
        await MainActor.run { status = "Ready" }
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
        samModelReady = false

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
        print("[SAM Request] \(jsonString)")  // Debug
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

    /// Set image only if it differs from current image (skip redundant SAM encoding)
    /// This is a major performance optimization - SAM image encoding is ~90% of inference time
    func setImageIfNeeded(path: String) async throws -> CGSize {
        // Skip if same image is already loaded
        if path == currentImagePath && imagePixelSize != .zero {
            return imagePixelSize
        }
        return try await setImage(path: path)
    }

    /// Run prediction with points, box, and/or text prompt
    /// Returns tuple of (all mask URLs, best mask URL, scores, confidence map URL)
    func predict(points: [SAMPoint] = [], box: SAMBox? = nil, text: String? = nil, imageSize: CGSize) async throws -> (masks: [URL], primaryMask: URL, scores: [Double], confidenceMap: URL?) {
        guard persistentProcess?.isRunning == true else {
            throw PythonError.workerNotRunning
        }

        await MainActor.run {
            isProcessing = true
            status = text != nil ? "Finding \"\(text!)\"..." : "Segmenting..."
        }

        defer {
            Task { @MainActor in
                isProcessing = false
                status = "Ready"
            }
        }

        // Convert points to pixel coordinates and extract labels
        let pixelPoints: [[Int]] = points.map { point in
            let coords = point.pixelCoords(for: imageSize)
            return [coords.x, coords.y]
        }
        let pointLabels: [Int] = points.map { $0.label }

        // Convert box to pixel coordinates
        let pixelBox: [Int]? = box?.pixelBox(for: imageSize)

        let request = SAMRequest(
            command: "predict",
            points: pixelPoints.isEmpty ? nil : pixelPoints,
            labels: pointLabels.isEmpty ? nil : pointLabels,
            box: pixelBox,
            text: text
        )

        let response = try await sendRequest(request)

        guard response.success else {
            throw PythonError.predictionFailed(response.error ?? "Unknown error")
        }

        guard let maskPaths = response.masks, !maskPaths.isEmpty else {
            throw PythonError.predictionFailed("No masks returned")
        }

        if let inferenceTime = response.inferenceTimeMs {
            print("Inference completed in \(inferenceTime)ms")
        }

        let urls = maskPaths.map { URL(fileURLWithPath: $0) }
        let primaryURL = response.primaryMaskPath.flatMap { URL(fileURLWithPath: $0) } ?? urls.first!
        let scores = response.scores ?? []
        let confidenceMapURL = response.confidenceMapPath.flatMap { URL(fileURLWithPath: $0) }

        return (urls, primaryURL, scores, confidenceMapURL)
    }

    /// Automatically remove background using SAM2
    func removeBackground() async throws -> URL {
        guard persistentProcess?.isRunning == true else {
            throw PythonError.workerNotRunning
        }

        await MainActor.run {
            isProcessing = true
            status = "Removing background..."
        }

        defer {
            Task { @MainActor in
                isProcessing = false
                status = "Ready"
            }
        }

        let request = SAMRequest(command: "remove_background")
        let response = try await sendRequest(request)

        guard response.success, let imagePath = response.imagePath else {
            throw PythonError.predictionFailed(response.error ?? "Unknown error")
        }

        return URL(fileURLWithPath: imagePath)
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

        // Reset cancellation state
        await MainActor.run {
            isGenerationCancelled = false
        }

        let process = Process()
        currentGenerationProcess = process
        process.executableURL = URL(fileURLWithPath: finalUvPath)

        // Build arguments - only include mask if provided
        var args = [
            "run", hunyuanScript,
            "--image", imagePath,
            "--output", outputPath.path,
            "--output-dir", hunyuanDir.path,
            "--steps", "\(steps)",
            "--resolution", "\(resolution)"
        ]

        // Only add mask argument if a mask path is provided
        if !maskPath.isEmpty {
            args.insert(contentsOf: ["--mask", maskPath], at: 4)
        }

        process.arguments = args
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
        Task.detached { [weak self] in
            process.waitUntilExit()
            pipe.fileHandleForReading.readabilityHandler = nil

            // Clear process reference
            await MainActor.run {
                self?.currentGenerationProcess = nil
            }

            let fm = FileManager.default

            // Check if cancelled
            let wasCancelled = await MainActor.run { self?.isGenerationCancelled ?? false }
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

    /// Cancel the current 3D generation process
    func cancelGeneration() {
        guard let process = currentGenerationProcess, process.isRunning else {
            return
        }

        isGenerationCancelled = true

        // Terminate the process
        process.terminate()

        // Also try to interrupt (SIGINT) for cleaner shutdown
        kill(process.processIdentifier, SIGINT)

        currentGenerationProcess = nil
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
