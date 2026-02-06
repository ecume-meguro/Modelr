import Foundation
import os.log

/// Strategy for loading ML models based on available system memory
enum ModelLoadingStrategy: String {
    /// Load models one at a time, offloading SAM before loading Hunyuan
    /// Used for systems with < 16GB RAM
    case conservative

    /// Load both models simultaneously, with SAM prioritized and Hunyuan loaded async
    /// Used for systems with >= 16GB RAM
    case aggressive

    var description: String {
        switch self {
        case .conservative:
            return "Sequential (< 16GB RAM)"
        case .aggressive:
            return "Parallel (≥ 16GB RAM)"
        }
    }
}

/// Coordinates model loading based on system memory constraints
///
/// For systems with < 16GB RAM (conservative):
/// - Load SAM model during setup/input phase
/// - Offload SAM model before generation step
/// - Load Hunyuan model only when generation starts
///
/// For systems with >= 16GB RAM (aggressive):
/// - Load SAM model with priority during setup
/// - Start persistent Hunyuan server asynchronously after SAM is ready (if model downloaded)
/// - Both models remain loaded throughout the session
@MainActor
class ModelLoadingCoordinator: ObservableObject {
    static let shared = ModelLoadingCoordinator()

    /// Current loading strategy based on system RAM
    @Published private(set) var strategy: ModelLoadingStrategy

    /// Whether Hunyuan server is currently starting
    @Published private(set) var isStartingHunyuan: Bool = false

    /// Whether Hunyuan server is running and ready
    @Published private(set) var isHunyuanReady: Bool = false

    /// Current Hunyuan model variant loaded
    @Published private(set) var hunyuanVariant: String?

    /// Whether VLM server is currently starting
    @Published private(set) var isStartingVLM: Bool = false

    /// Whether VLM server is running and ready
    @Published private(set) var isVLMReady: Bool = false

    /// Whether a variant switch is in progress
    @Published private(set) var isSwitchingVariant: Bool = false

    /// Status message for variant switch (for UI feedback)
    @Published private(set) var variantSwitchStatus: String?

    /// System RAM in bytes
    let systemRAM: UInt64

    /// Formatted system RAM for display
    var formattedSystemRAM: String {
        ByteCountFormatter.string(fromByteCount: Int64(systemRAM), countStyle: .memory)
    }

    /// The persistent Hunyuan process manager
    private(set) var hunyuanProcessManager: HunyuanProcessManager?

    /// The persistent VLM process manager
    private(set) var vlmProcessManager: VLMProcessManager?

    private var startupTask: Task<Void, Never>?
    private var vlmStartupTask: Task<Void, Never>?
    private var vlmIdleTask: Task<Void, Never>?

    /// Pending VLM startup continuations (for queuing concurrent requests)
    private var vlmStartupContinuations: [CheckedContinuation<Bool, Never>] = []

    /// Last time VLM was used (for idle timeout)
    private var lastVLMUseTime: Date?

    /// Maximum time to wait for a server to start (in seconds)
    private static let startupTimeoutSeconds: TimeInterval = 120

    /// Effective VLM idle timeout based on system memory and user preference
    var effectiveVLMIdleTimeout: TimeInterval {
        // Check user preference first
        let override = UserDefaults.standard.string(forKey: "vlmIdleTimeoutOverride") ?? "auto"
        switch override {
        case "always_warm":
            return .infinity
        case "5min":
            return 300
        case "10min":
            return 600
        default: // "auto"
            // Memory-aware timeout: 24GB+ = indefinite, else 5min
            let ramGB = systemRAM / (1024 * 1024 * 1024)
            if ramGB >= 24 {
                return .infinity
            }
            return 300
        }
    }

    /// Event-driven condition waiter - replaces busy-wait polling
    /// - Parameters:
    ///   - condition: Closure that returns true while we should keep waiting
    ///   - timeout: Maximum time to wait in seconds (defaults to 120s)
    /// - Returns: true if condition became false (success), false if timed out
    private func waitForCondition(_ condition: () -> Bool, timeout: TimeInterval? = nil) async -> Bool {
        let effectiveTimeout = timeout ?? ModelLoadingCoordinator.startupTimeoutSeconds

        // Check immediately - if already satisfied, return
        guard condition() else {
            return true
        }

        // Use exponential backoff instead of fixed 100ms polling
        var backoff: UInt64 = 10_000_000  // Start at 10ms
        let maxBackoff: UInt64 = 500_000_000  // Max 500ms
        let deadline = Date().addingTimeInterval(effectiveTimeout)

        while condition() && Date() < deadline {
            try? await Task.sleep(nanoseconds: backoff)

            // Exponential backoff to reduce CPU usage
            backoff = min(backoff * 2, maxBackoff)

            // Check for task cancellation
            if Task.isCancelled {
                return false
            }
        }

        return !condition()
    }

    private init() {
        self.systemRAM = ProcessInfo.processInfo.physicalMemory
        self.strategy = systemRAM >= AppConstants.aggressiveLoadingRAMThreshold ? .aggressive : .conservative

        print("[ModelLoadingCoordinator] System RAM: \(formattedSystemRAM)")
        print("[ModelLoadingCoordinator] Strategy: \(strategy.description)")
    }

    // MARK: - Disk Space Validation

    /// Error type for model loading failures
    enum ModelLoadingError: LocalizedError {
        case insufficientDiskSpace(required: Int64, available: Int64)
        case modelCorrupted(variant: String, reason: String)
        case modelNotFound(variant: String)

        var errorDescription: String? {
            switch self {
            case .insufficientDiskSpace(let required, let available):
                let requiredStr = ByteCountFormatter.string(fromByteCount: required, countStyle: .file)
                let availableStr = ByteCountFormatter.string(fromByteCount: available, countStyle: .file)
                return "Insufficient disk space. Required: \(requiredStr), Available: \(availableStr)"
            case .modelCorrupted(let variant, let reason):
                return "Model '\(variant)' appears corrupted: \(reason). Consider re-downloading."
            case .modelNotFound(let variant):
                return "Model '\(variant)' not found. Please download it first."
            }
        }
    }

    /// Check if there's enough disk space for a model download
    /// - Parameters:
    ///   - variant: The model variant ("mini" or "std")
    ///   - bufferGB: Additional buffer space in GB (default 2GB)
    /// - Returns: nil if sufficient space, or a ModelLoadingError if not
    func checkDiskSpaceForModel(variant: String, bufferGB: Double = 2.0) -> ModelLoadingError? {
        let requiredBytes: Int64
        switch variant {
        case "std":
            requiredBytes = AppConstants.hunyuanStdModelBytes
        default:
            requiredBytes = AppConstants.hunyuanMiniModelBytes
        }

        // Add buffer space
        let bufferBytes = Int64(bufferGB * 1_000_000_000)
        let totalRequired = requiredBytes + bufferBytes

        // Get available disk space
        let fileManager = FileManager.default
        let modelsDir = PathManager.modelsDirectory

        do {
            let values = try modelsDir.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            if let availableBytes = values.volumeAvailableCapacityForImportantUsage {
                if availableBytes < totalRequired {
                    return .insufficientDiskSpace(required: totalRequired, available: availableBytes)
                }
            }
        } catch {
            // If we can't determine disk space, try the old method
            if let attributes = try? fileManager.attributesOfFileSystem(forPath: modelsDir.path),
               let freeSpace = attributes[.systemFreeSize] as? Int64 {
                if freeSpace < totalRequired {
                    return .insufficientDiskSpace(required: totalRequired, available: freeSpace)
                }
            }
        }

        return nil
    }

    // MARK: - Model Integrity Check

    /// Verify that a model file exists and has expected size
    /// - Parameter variant: The model variant to check ("mini" or "std")
    /// - Returns: nil if model is valid, or a ModelLoadingError if not
    func verifyModelIntegrity(variant: String) -> ModelLoadingError? {
        let modelDirName: String
        let expectedMinSizeBytes: Int64

        switch variant {
        case "std":
            modelDirName = "hunyuan-2.1"
            expectedMinSizeBytes = 8_000_000_000  // ~8 GB minimum for standard model
        default:
            modelDirName = "hunyuan-2mini"
            expectedMinSizeBytes = 3_500_000_000  // ~3.5 GB minimum for mini model
        }

        let modelsDir = PathManager.modelsDirectory
        let modelDir = modelsDir.appendingPathComponent(modelDirName)

        // Check for model directory
        guard FileManager.default.fileExists(atPath: modelDir.path) else {
            return .modelNotFound(variant: variant)
        }

        // Look for the main weights file in the subfolder
        let subfolderName = variant == "std" ? "hunyuan3d-dit-v2-1" : "hunyuan3d-dit-v2-mini"
        let weightsPath = modelDir.appendingPathComponent(subfolderName).appendingPathComponent("model.fp16.safetensors")

        guard FileManager.default.fileExists(atPath: weightsPath.path) else {
            // Check root directory as fallback
            let rootWeightsPath = modelDir.appendingPathComponent("model.fp16.safetensors")
            if FileManager.default.fileExists(atPath: rootWeightsPath.path) {
                // Verify size at root
                if let attributes = try? FileManager.default.attributesOfItem(atPath: rootWeightsPath.path),
                   let fileSize = attributes[.size] as? Int64 {
                    if fileSize < expectedMinSizeBytes {
                        return .modelCorrupted(variant: variant, reason: "File size \(fileSize) is smaller than expected \(expectedMinSizeBytes) bytes")
                    }
                    return nil  // Valid
                }
            }
            return .modelNotFound(variant: variant)
        }

        // Verify file size
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: weightsPath.path)
            if let fileSize = attributes[.size] as? Int64 {
                if fileSize < expectedMinSizeBytes {
                    return .modelCorrupted(variant: variant, reason: "File size \(fileSize) is smaller than expected \(expectedMinSizeBytes) bytes")
                }
            }
        } catch {
            return .modelCorrupted(variant: variant, reason: "Could not read file attributes: \(error.localizedDescription)")
        }

        return nil
    }

    /// Check model integrity before loading, with option to trigger re-download
    /// - Parameters:
    ///   - variant: The model variant to verify
    ///   - allowRedownload: Whether to offer re-download option (for UI)
    /// - Returns: Tuple of (isValid, errorMessage, canRedownload)
    func checkModelBeforeLoading(variant: String) -> (isValid: Bool, error: ModelLoadingError?) {
        // First check disk space
        if let spaceError = checkDiskSpaceForModel(variant: variant, bufferGB: 0.5) {
            return (false, spaceError)
        }

        // Then verify model integrity
        if let integrityError = verifyModelIntegrity(variant: variant) {
            return (false, integrityError)
        }

        return (true, nil)
    }

    /// Get the model variant that was selected during setup
    private func getSetupModelVariant() -> String? {
        let markerPath = PathManager.setupCompletionMarkerPath
        guard FileManager.default.fileExists(atPath: markerPath.path) else {
            return nil
        }

        do {
            let data = try Data(contentsOf: markerPath)
            if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
               let variant = json["model_variant"] as? String {
                return variant
            }
        } catch {
            print("[ModelLoadingCoordinator] Failed to read setup marker: \(error)")
        }

        return nil
    }

    /// Check which Hunyuan models are available for loading
    private func getAvailableHunyuanVariant() -> String? {
        // First, check what was selected during setup
        if let setupVariant = getSetupModelVariant() {
            print("[ModelLoadingCoordinator] Setup marker indicates variant: '\(setupVariant)'")
            let isDownloaded = PathManager.isHunyuanModelDownloaded(variant: setupVariant)
            print("[ModelLoadingCoordinator] Checking if '\(setupVariant)' has safetensors: \(isDownloaded)")
            if isDownloaded {
                return setupVariant
            }
            print("[ModelLoadingCoordinator] Setup variant '\(setupVariant)' weights not found, checking alternatives...")
        }

        // Fall back to checking what's actually downloaded
        let miniDownloaded = PathManager.isHunyuanModelDownloaded(variant: "mini")
        print("[ModelLoadingCoordinator] Mini model has safetensors: \(miniDownloaded)")
        if miniDownloaded {
            return "mini"
        }

        print("[ModelLoadingCoordinator] Hunyuan model not found - skipping preload")
        return nil
    }

    /// Called when SAM model is ready
    /// NOTE: VLM is now started lazily on-demand via ensureVLMReady() when auto-detect is triggered
    /// NOTE: Hunyuan is started separately via startHunyuanInBackground() to avoid blocking SAM
    func onSAMModelReady(env: PythonEnvironment) {
        // VLM is now loaded lazily on-demand to reduce memory pressure
        // Use ensureVLMReady() when auto-detect is needed
        print("[ModelLoadingCoordinator] SAM ready. VLM will start on first auto-detect request.")
    }

    /// Start Hunyuan server in background with low priority
    /// Should only be called AFTER SAM and VLM are ready
    func startHunyuanInBackground(env: PythonEnvironment) {
        // Only for aggressive strategy
        guard strategy == .aggressive else {
            print("[ModelLoadingCoordinator] Conservative strategy - Hunyuan will start on-demand")
            return
        }

        // Already running or starting
        guard !isHunyuanReady && !isStartingHunyuan else {
            return
        }

        // Check if we have a model to load
        guard let variant = getAvailableHunyuanVariant() else {
            print("[ModelLoadingCoordinator] No Hunyuan model available to preload")
            return
        }

        print("[ModelLoadingCoordinator] Starting Hunyuan server in background (low priority, variant: \(variant))...")
        isStartingHunyuan = true

        // Use detached task with background priority so it doesn't block main actor
        startupTask = Task.detached(priority: .background) { [weak self] in
            await self?.startHunyuanServer(env: env, variant: variant)
        }
    }

    /// Start the persistent Hunyuan server
    private func startHunyuanServer(env: PythonEnvironment, variant: String) async {
        guard let uvPath = env.findUVPath() else {
            print("[ModelLoadingCoordinator] UV path not found, cannot start Hunyuan server")
            isStartingHunyuan = false
            return
        }

        let manager = HunyuanProcessManager()
        hunyuanProcessManager = manager

        // Setup stderr logging
        manager.onStderrLine = { line in
            print("[HunyuanServer] \(line)")
        }

        do {
            try manager.startServer(uvPath: uvPath, modelVariant: variant)

            // Wait for ready signal
            let response = try await manager.waitForReady(timeout: 120)  // Model loading can take time

            if response.ready == true {
                print("[ModelLoadingCoordinator] Hunyuan server ready (variant: \(response.variant ?? variant), device: \(response.device ?? "unknown"))")
                hunyuanVariant = response.variant ?? variant
                isHunyuanReady = true
            } else {
                print("[ModelLoadingCoordinator] Hunyuan server failed to initialize: \(response.error ?? "unknown")")
                manager.stopServer()
                hunyuanProcessManager = nil
            }
        } catch {
            print("[ModelLoadingCoordinator] Hunyuan server startup error: \(error)")
            manager.stopServer()
            hunyuanProcessManager = nil
        }

        isStartingHunyuan = false
    }

    /// Start the persistent VLM server
    private func startVLMServer(env: PythonEnvironment) async {
        guard let uvPath = env.findUVPath() else {
            print("[ModelLoadingCoordinator] UV path not found, cannot start VLM server")
            isStartingVLM = false
            return
        }

        let manager = VLMProcessManager()
        vlmProcessManager = manager

        // Setup stderr logging
        manager.onStderrLine = { line in
            print("[VLMServer] \(line)")
        }

        do {
            try manager.startServer(uvPath: uvPath)

            // Wait for ready signal
            let response = try await manager.waitForReady(timeout: 120)  // Model loading can take time

            if response.ready == true {
                print("[ModelLoadingCoordinator] VLM server ready (device: \(response.device ?? "unknown"))")
                isVLMReady = true
            } else {
                print("[ModelLoadingCoordinator] VLM server failed to initialize: \(response.error ?? "unknown")")
                manager.stopServer()
                vlmProcessManager = nil
            }
        } catch {
            print("[ModelLoadingCoordinator] VLM server startup error: \(error)")
            manager.stopServer()
            vlmProcessManager = nil
        }

        isStartingVLM = false
    }

    /// Ensure VLM server is running (starts if needed)
    /// Uses continuation-based queuing to prevent multiple concurrent startup attempts
    func ensureVLMReady(env: PythonEnvironment) async -> Bool {
        // Already running
        if isVLMReady && vlmProcessManager?.isRunning == true {
            return true
        }

        // If already starting, queue this request and wait for result
        if isStartingVLM {
            print("[ModelLoadingCoordinator] VLM startup in progress, queuing request...")
            return await withCheckedContinuation { continuation in
                vlmStartupContinuations.append(continuation)
            }
        }

        // Start the server (we are first in line)
        isStartingVLM = true
        await startVLMServer(env: env)

        // Notify all queued requests of the result
        let result = isVLMReady
        for continuation in vlmStartupContinuations {
            continuation.resume(returning: result)
        }
        vlmStartupContinuations.removeAll()

        return result
    }

    /// Describe an image using the VLM server
    func describeImage(imagePath: String) async throws -> String {
        guard let manager = vlmProcessManager, manager.isRunning else {
            throw PythonError.workerNotRunning
        }

        // Track usage for idle timeout
        lastVLMUseTime = Date()
        startVLMIdleTimer()

        return try await manager.describeImage(imagePath: imagePath)
    }

    /// Generate a short descriptive project name for an image
    func generateProjectName(imagePath: String) async throws -> String {
        guard let manager = vlmProcessManager, manager.isRunning else {
            throw PythonError.workerNotRunning
        }

        // Track usage for idle timeout
        lastVLMUseTime = Date()
        startVLMIdleTimer()

        return try await manager.generateProjectName(imagePath: imagePath)
    }

    /// Start the VLM idle timer that will stop the server after inactivity
    private func startVLMIdleTimer() {
        // Cancel any existing timer
        vlmIdleTask?.cancel()

        vlmIdleTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 60_000_000_000)  // Check every 60 seconds

                guard let self = self else { return }
                guard self.isVLMReady, let lastUse = self.lastVLMUseTime else { continue }

                let idleTime = Date().timeIntervalSince(lastUse)
                let timeout = self.effectiveVLMIdleTimeout

                // Skip timeout check if set to infinity (always keep warm)
                guard timeout != .infinity else { continue }

                if idleTime >= timeout {
                    print("[ModelLoadingCoordinator] VLM idle for \(Int(idleTime))s (timeout=\(Int(timeout))s), stopping server to free memory")
                    self.stopVLMServer()
                    return
                }
            }
        }
    }

    // MARK: - Hunyuan Server Management

    /// Ensure Hunyuan server is running (starts if needed)
    /// For conservative strategy, this should be called before generation
    func ensureHunyuanReady(env: PythonEnvironment) async -> Bool {
        // Already running
        if isHunyuanReady && hunyuanProcessManager?.isRunning == true {
            return true
        }

        // Already starting, wait for it with timeout
        if isStartingHunyuan {
            let completed = await waitForCondition { self.isStartingHunyuan }
            if !completed {
                print("[ModelLoadingCoordinator] Hunyuan startup wait timed out")
            }
            return isHunyuanReady
        }

        // Need to start
        guard let variant = getAvailableHunyuanVariant() else {
            print("[ModelLoadingCoordinator] No Hunyuan model available")
            return false
        }

        isStartingHunyuan = true
        await startHunyuanServer(env: env, variant: variant)
        return isHunyuanReady
    }

    /// Ensure Hunyuan server is running with a specific model variant
    /// If a different variant is loaded, restarts the server with the requested variant
    /// - Parameters:
    ///   - env: Python environment
    ///   - variant: The model variant to load ("mini" or "std")
    ///   - onProgress: Optional callback for status updates during variant switch
    /// - Returns: Whether the server is ready with the requested variant
    func ensureHunyuanReady(
        env: PythonEnvironment,
        variant: String,
        onProgress: ((String) -> Void)? = nil
    ) async -> Bool {
        // Check if correct variant is already loaded
        if isHunyuanReady && hunyuanProcessManager?.isRunning == true && hunyuanVariant == variant {
            return true
        }

        // Already starting, wait for it with timeout
        if isStartingHunyuan {
            onProgress?("Waiting for model to load...")
            variantSwitchStatus = "Waiting for model to load..."
            let completed = await waitForCondition { self.isStartingHunyuan }
            variantSwitchStatus = nil
            if !completed {
                print("[ModelLoadingCoordinator] Hunyuan startup wait timed out")
            }
            // Check if the started variant matches what we need
            if hunyuanVariant == variant && isHunyuanReady {
                return true
            }
        }

        // Different variant needed - restart server with progress feedback
        if hunyuanProcessManager?.isRunning == true && hunyuanVariant != variant {
            isSwitchingVariant = true
            let variantName = variant == "std" ? "Standard" : "Mini"
            let status = "Switching to \(variantName) model..."
            variantSwitchStatus = status
            onProgress?(status)

            print("[ModelLoadingCoordinator] Switching Hunyuan variant from \(hunyuanVariant ?? "nil") to \(variant)")
            hunyuanProcessManager?.stopServer()
            hunyuanProcessManager = nil
            isHunyuanReady = false
            hunyuanVariant = nil

            // Small delay to ensure resources are released
            try? await Task.sleep(nanoseconds: 300_000_000)  // 0.3 seconds
        }

        // Check model integrity before loading
        let (isValid, loadError) = checkModelBeforeLoading(variant: variant)
        if !isValid {
            print("[ModelLoadingCoordinator] Model validation failed: \(loadError?.localizedDescription ?? "unknown")")
            isSwitchingVariant = false
            variantSwitchStatus = nil
            return false
        }

        // Start with requested variant
        let loadingStatus = "Loading \(variant == "std" ? "Standard" : "Mini") model..."
        variantSwitchStatus = loadingStatus
        onProgress?(loadingStatus)

        isStartingHunyuan = true
        await startHunyuanServer(env: env, variant: variant)

        isSwitchingVariant = false
        variantSwitchStatus = nil

        return isHunyuanReady && hunyuanVariant == variant
    }

    /// Generate 3D model using the persistent Hunyuan server
    /// - Parameters:
    ///   - onProgress: Callback with (stage, detail, progress) where stage is "loading"/"diffusion"/"volume_decoding"/"saving"
    func generate(
        imagePath: String,
        maskPath: String?,
        outputPath: String,
        steps: Int,
        resolution: Int,
        guidanceScale: Double = 5.0,
        boxV: Double = 1.01,
        mcLevel: Double = 0.0,
        onProgress: ((String, String, Double) -> Void)?
    ) async throws -> URL {
        guard let manager = hunyuanProcessManager, manager.isRunning else {
            throw PythonError.workerNotRunning
        }

        let request = HunyuanRequest(
            command: "generate",
            imagePath: imagePath,
            maskPath: maskPath,
            outputPath: outputPath,
            steps: steps,
            resolution: resolution,
            guidanceScale: guidanceScale,
            boxV: boxV,
            mcLevel: mcLevel
        )

        // Track progress from both JSON callbacks AND tqdm stderr parsing
        // Use a class to allow mutation from closure
        final class ProgressTracker {
            var lastReportedStep = 0
            var lastTotalSteps = 0
            var inVolumeDecoding = false
            var recordActivity: (() -> Void)?  // Called to reset idle timeout
        }
        let tracker = ProgressTracker()

        // Setup stderr handler to parse progress from Python
        // We look for explicit markers like "[DIFFUSION_PROGRESS] X/Y Z%" and "[STAGE] volume_decoding"
        // Also fall back to tqdm parsing if those aren't present
        let previousStderrHandler = manager.onStderrLine
        manager.onStderrLine = { [onProgress, tracker, steps] line in
            // Pass through to previous handler for logging
            previousStderrHandler?(line)

            // Parse explicit diffusion progress: "[DIFFUSION_PROGRESS] X/Y Z%"
            if line.contains("[DIFFUSION_PROGRESS]") {
                tracker.recordActivity?()  // Reset idle timeout
                // Format: "[DIFFUSION_PROGRESS] 5/25 41%"
                let parts = line.replacingOccurrences(of: "[DIFFUSION_PROGRESS]", with: "").trimmingCharacters(in: .whitespaces).split(separator: " ")
                if parts.count >= 2 {
                    let stepParts = parts[0].split(separator: "/")
                    if stepParts.count == 2,
                       let currentStep = Int(stepParts[0]),
                       let totalSteps = Int(stepParts[1]) {
                        let percentStr = parts[1].replacingOccurrences(of: "%", with: "")
                        let percent = Int(percentStr) ?? 0
                        let progress = Double(percent) / 100.0
                        let detail = "\(currentStep)/\(totalSteps)"
                        print("[Progress] Diffusion step \(detail) at \(percent)%")
                        tracker.lastReportedStep = currentStep
                        DispatchQueue.main.async {
                            onProgress?("diffusion", detail, progress)
                        }
                    }
                }
                return
            }

            // Parse explicit stage change: "[STAGE] volume_decoding"
            if line.contains("[STAGE] volume_decoding") {
                tracker.recordActivity?()  // Reset idle timeout
                if !tracker.inVolumeDecoding {
                    tracker.inVolumeDecoding = true
                    print("[Progress] Switching to volume decoding stage")
                    DispatchQueue.main.async {
                        onProgress?("volume_decoding", "Extracting mesh...", 0.82)
                    }
                }
                return
            }

            // Fallback: Parse tqdm progress: "X%|" pattern
            // tqdm format: " 45%|████▌     | 11/25 [00:05<00:06,  2.19it/s]"
            if let match = line.range(of: #"(\d+)%\|"#, options: .regularExpression) {
                tracker.recordActivity?()  // Reset idle timeout on any tqdm progress
                let percentStr = line[match].dropLast(2) // Remove "%|"
                if let percent = Int(percentStr) {
                    // Also try to extract step counts
                    var currentStep = 0
                    var totalSteps = steps
                    if let stepMatch = line.range(of: #"\|\s*(\d+)/(\d+)"#, options: .regularExpression) {
                        let stepPart = String(line[stepMatch]).replacingOccurrences(of: "|", with: "").trimmingCharacters(in: .whitespaces)
                        let parts = stepPart.split(separator: "/")
                        if parts.count == 2, let cur = Int(parts[0]), let tot = Int(parts[1]) {
                            currentStep = cur
                            totalSteps = tot
                        }
                    }

                    // Detect stage change: if total steps jumps significantly (e.g., 25 -> 899),
                    // it means we've moved from diffusion to volume decoding
                    if tracker.lastTotalSteps > 0 && totalSteps > tracker.lastTotalSteps * 3 {
                        // Total steps increased dramatically - this is volume decoding
                        if !tracker.inVolumeDecoding {
                            tracker.inVolumeDecoding = true
                            tracker.lastReportedStep = 0
                            print("[tqdm] Detected stage change to volume decoding (steps: \(tracker.lastTotalSteps) -> \(totalSteps))")
                        }
                    }
                    tracker.lastTotalSteps = totalSteps

                    // Only report if step changed to avoid flooding
                    if currentStep > tracker.lastReportedStep || (currentStep == 1 && tracker.lastReportedStep > currentStep) {
                        tracker.lastReportedStep = currentStep
                        let progress = Double(percent) / 100.0
                        let detail = currentStep > 0 ? "\(currentStep)/\(totalSteps)" : ""

                        if tracker.inVolumeDecoding {
                            print("[tqdm] Volume decoding step \(detail) at \(percent)%")
                            DispatchQueue.main.async {
                                onProgress?("volume_decoding", detail, 0.80 + progress * 0.15)
                            }
                        } else {
                            print("[tqdm] Diffusion step \(detail) at \(percent)%")
                            DispatchQueue.main.async {
                                onProgress?("diffusion", detail, 0.15 + progress * 0.65)
                            }
                        }
                    }
                }
                return
            }

            // Fallback: Detect volume decoding / mesh extraction from log messages
            let lower = line.lowercased()
            if !tracker.inVolumeDecoding && (lower.contains("decoding") || lower.contains("marching cube") || lower.contains("extracting mesh")) {
                tracker.inVolumeDecoding = true
                print("[Progress] Detected volume decoding from log")
                DispatchQueue.main.async {
                    onProgress?("volume_decoding", "Extracting mesh...", 0.82)
                }
            }
        }

        defer {
            // Restore previous handler
            manager.onStderrLine = previousStderrHandler
        }

        let response = try await manager.sendRequest(
            request,
            onProgress: { progress in
                // JSON progress from Python callback (if it works)
                if let stage = progress.stage, let value = progress.progress {
                    let detail = progress.detail ?? ""
                    print("[JSON Progress] stage=\(stage) detail=\(detail) value=\(value)")
                    DispatchQueue.main.async {
                        onProgress?(stage, detail, value)
                    }
                }
            },
            onActivity: { activityRecorder in
                // Store the activity recorder so stderr handler can use it
                tracker.recordActivity = activityRecorder
            }
        )

        guard response.success, let outputURL = response.outputPath else {
            throw PythonError.predictionFailed(response.error ?? "Generation failed")
        }

        return URL(fileURLWithPath: outputURL)
    }

    /// Called before generation step - handles model offloading for conservative strategy
    /// - Parameters:
    ///   - env: Python environment
    ///   - variant: The model variant to load ("mini" or "std")
    ///   - onProgress: Optional callback for status updates during model loading/switching
    func prepareForGeneration(
        env: PythonEnvironment,
        variant: String = "mini",
        onProgress: ((String) -> Void)? = nil
    ) async -> Bool {
        if strategy == .conservative {
            onProgress?("Preparing for generation...")
            print("[ModelLoadingCoordinator] Conservative strategy: Offloading SAM model before generation...")
            env.stopPersistentWorker()

            // Small delay to ensure resources are released
            try? await Task.sleep(nanoseconds: 500_000_000)  // 0.5 seconds

            print("[ModelLoadingCoordinator] SAM model offloaded, starting Hunyuan server (variant: \(variant))...")

            // Start Hunyuan server for generation with the requested variant
            return await ensureHunyuanReady(env: env, variant: variant, onProgress: onProgress)
        }

        // For aggressive strategy, ensure correct variant is running
        return await ensureHunyuanReady(env: env, variant: variant, onProgress: onProgress)
    }

    /// Called after generation completes
    func onGenerationComplete(env: PythonEnvironment) async {
        if strategy == .conservative {
            print("[ModelLoadingCoordinator] Generation complete")
            // For conservative strategy, we keep Hunyuan running until user goes back to segmentation
            // This avoids reloading if they want to generate again
        }
    }

    /// Stop the Hunyuan server (for conservative strategy when returning to segmentation)
    func stopHunyuanServer() {
        hunyuanProcessManager?.stopServer()
        hunyuanProcessManager = nil
        isHunyuanReady = false
        hunyuanVariant = nil
        print("[ModelLoadingCoordinator] Hunyuan server stopped")
    }

    /// Stop the VLM server
    func stopVLMServer() {
        vlmIdleTask?.cancel()
        vlmIdleTask = nil
        lastVLMUseTime = nil
        vlmProcessManager?.stopServer()
        vlmProcessManager = nil
        isVLMReady = false
        print("[ModelLoadingCoordinator] VLM server stopped")
    }

    /// Cancel current generation without stopping the server
    func cancelGeneration() {
        hunyuanProcessManager?.cancelGeneration()
    }

    /// Cancel any ongoing startup operation
    func cancelStartup() {
        startupTask?.cancel()
        startupTask = nil
        vlmStartupTask?.cancel()
        vlmStartupTask = nil

        // Resume any waiting VLM continuations with failure
        for continuation in vlmStartupContinuations {
            continuation.resume(returning: false)
        }
        vlmStartupContinuations.removeAll()

        isStartingHunyuan = false
        isStartingVLM = false
        isSwitchingVariant = false
        variantSwitchStatus = nil
        stopHunyuanServer()
        stopVLMServer()
    }

    deinit {
        // CRITICAL: deinit must be fast and non-blocking
        // The process managers have their own non-blocking deinit that handles
        // fire-and-forget termination with background SIGKILL fallback

        // Cancel all pending tasks
        startupTask?.cancel()
        vlmStartupTask?.cancel()
        vlmIdleTask?.cancel()

        // Resume any waiting continuations with failure
        for continuation in vlmStartupContinuations {
            continuation.resume(returning: false)
        }

        // Stop servers (non-blocking - process managers handle cleanup)
        hunyuanProcessManager?.stopServer()
        vlmProcessManager?.stopServer()
    }
}
