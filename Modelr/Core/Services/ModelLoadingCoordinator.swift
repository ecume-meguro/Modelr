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

    /// System RAM in bytes
    let systemRAM: UInt64

    /// Formatted system RAM for display
    var formattedSystemRAM: String {
        ByteCountFormatter.string(fromByteCount: Int64(systemRAM), countStyle: .memory)
    }

    /// The persistent Hunyuan process manager
    private(set) var hunyuanProcessManager: HunyuanProcessManager?

    private var startupTask: Task<Void, Never>?

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

        let stdDownloaded = PathManager.isHunyuanModelDownloaded(variant: "std")
        print("[ModelLoadingCoordinator] Standard model has safetensors: \(stdDownloaded)")
        if stdDownloaded {
            return "std"
        }

        print("[ModelLoadingCoordinator] No Hunyuan models with complete weights found - skipping preload")
        return nil
    }

    /// Called when SAM model is ready - triggers async Hunyuan server start if using aggressive strategy
    func onSAMModelReady(env: PythonEnvironment) {
        guard strategy == .aggressive && !isHunyuanReady && !isStartingHunyuan else {
            if strategy == .conservative {
                print("[ModelLoadingCoordinator] Conservative strategy - Hunyuan will start on-demand")
            }
            return
        }

        // Check if we have a model to load
        guard let variant = getAvailableHunyuanVariant() else {
            print("[ModelLoadingCoordinator] No Hunyuan model available to preload")
            return
        }

        print("[ModelLoadingCoordinator] SAM ready, starting persistent Hunyuan server (variant: \(variant))...")
        isStartingHunyuan = true

        startupTask = Task {
            await startHunyuanServer(env: env, variant: variant)
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

    /// Generate 3D model using the persistent Hunyuan server
    /// - Parameters:
    ///   - onProgress: Callback with (stage, detail, progress) where stage is "loading"/"diffusion"/"exporting"
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

        let response = try await manager.sendRequest(request) { progress in
            if let stage = progress.stage, let value = progress.progress {
                let detail = progress.detail ?? ""
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

    /// Cancel any ongoing startup operation
    func cancelStartup() {
        startupTask?.cancel()
        startupTask = nil
        isStartingHunyuan = false
        stopHunyuanServer()
    }

    deinit {
        hunyuanProcessManager?.stopServer()
    }
}
