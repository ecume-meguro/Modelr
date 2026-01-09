import Foundation

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

    private init() {
        self.systemRAM = ProcessInfo.processInfo.physicalMemory
        self.strategy = systemRAM >= AppConstants.aggressiveLoadingRAMThreshold ? .aggressive : .conservative

        print("[ModelLoadingCoordinator] System RAM: \(formattedSystemRAM)")
        print("[ModelLoadingCoordinator] Strategy: \(strategy.description)")
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

    /// Called when SAM model is ready - starts VLM server only
    /// NOTE: Hunyuan is started separately via startHunyuanInBackground() to avoid blocking SAM/VLM
    func onSAMModelReady(env: PythonEnvironment) {
        // Start VLM server (lightweight MLX model, always start alongside SAM)
        if !isVLMReady && !isStartingVLM {
            print("[ModelLoadingCoordinator] SAM ready, starting VLM server...")
            isStartingVLM = true
            vlmStartupTask = Task {
                await startVLMServer(env: env)
            }
        }
        // NOTE: Hunyuan is NOT started here to ensure SAM/VLM have full priority
        // Use startHunyuanInBackground() after VLM is ready
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
    func ensureVLMReady(env: PythonEnvironment) async -> Bool {
        // Already running
        if isVLMReady && vlmProcessManager?.isRunning == true {
            return true
        }

        // Already starting, wait for it
        if isStartingVLM {
            while isStartingVLM {
                try? await Task.sleep(nanoseconds: 100_000_000)  // 100ms
            }
            return isVLMReady
        }

        // Need to start
        isStartingVLM = true
        await startVLMServer(env: env)
        return isVLMReady
    }

    /// Describe an image using the VLM server
    func describeImage(imagePath: String) async throws -> String {
        guard let manager = vlmProcessManager, manager.isRunning else {
            throw PythonError.workerNotRunning
        }

        return try await manager.describeImage(imagePath: imagePath)
    }

    /// Ensure Hunyuan server is running (starts if needed)
    /// For conservative strategy, this should be called before generation
    func ensureHunyuanReady(env: PythonEnvironment) async -> Bool {
        // Already running
        if isHunyuanReady && hunyuanProcessManager?.isRunning == true {
            return true
        }

        // Already starting, wait for it
        if isStartingHunyuan {
            // Wait for startup to complete
            while isStartingHunyuan {
                try? await Task.sleep(nanoseconds: 100_000_000)  // 100ms
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
    /// - Returns: Whether the server is ready with the requested variant
    func ensureHunyuanReady(env: PythonEnvironment, variant: String) async -> Bool {
        // Check if correct variant is already loaded
        if isHunyuanReady && hunyuanProcessManager?.isRunning == true && hunyuanVariant == variant {
            return true
        }

        // Already starting, wait for it
        if isStartingHunyuan {
            while isStartingHunyuan {
                try? await Task.sleep(nanoseconds: 100_000_000)  // 100ms
            }
            // Check if the started variant matches what we need
            if hunyuanVariant == variant && isHunyuanReady {
                return true
            }
        }

        // Different variant needed - restart server
        if hunyuanProcessManager?.isRunning == true && hunyuanVariant != variant {
            print("[ModelLoadingCoordinator] Switching Hunyuan variant from \(hunyuanVariant ?? "nil") to \(variant)")
            hunyuanProcessManager?.stopServer()
            hunyuanProcessManager = nil
            isHunyuanReady = false
            hunyuanVariant = nil
        }

        // Start with requested variant
        isStartingHunyuan = true
        await startHunyuanServer(env: env, variant: variant)
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
            resolution: resolution
        )

        // Track progress from both JSON callbacks AND tqdm stderr parsing
        // Use a class to allow mutation from closure
        final class ProgressTracker {
            var lastReportedStep = 0
            var lastTotalSteps = 0
            var inVolumeDecoding = false
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

        let response = try await manager.sendRequest(request) { progress in
            // JSON progress from Python callback (if it works)
            if let stage = progress.stage, let value = progress.progress {
                let detail = progress.detail ?? ""
                print("[JSON Progress] stage=\(stage) detail=\(detail) value=\(value)")
                DispatchQueue.main.async {
                    onProgress?(stage, detail, value)
                }
            }
        }

        guard response.success, let outputURL = response.outputPath else {
            throw PythonError.predictionFailed(response.error ?? "Generation failed")
        }

        return URL(fileURLWithPath: outputURL)
    }

    /// Called before generation step - handles model offloading for conservative strategy
    func prepareForGeneration(env: PythonEnvironment) async -> Bool {
        if strategy == .conservative {
            print("[ModelLoadingCoordinator] Conservative strategy: Offloading SAM model before generation...")
            env.stopPersistentWorker()

            // Small delay to ensure resources are released
            try? await Task.sleep(nanoseconds: 500_000_000)  // 0.5 seconds

            print("[ModelLoadingCoordinator] SAM model offloaded, starting Hunyuan server...")

            // Start Hunyuan server for generation
            return await ensureHunyuanReady(env: env)
        }

        // For aggressive strategy, Hunyuan should already be running
        return await ensureHunyuanReady(env: env)
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
        isStartingHunyuan = false
        isStartingVLM = false
        stopHunyuanServer()
        stopVLMServer()
    }

    deinit {
        hunyuanProcessManager?.stopServer()
        vlmProcessManager?.stopServer()
    }
}
