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
/// - Start loading Hunyuan model asynchronously after SAM is ready (if downloaded)
/// - Both models remain loaded throughout the session
@MainActor
class ModelLoadingCoordinator: ObservableObject {
    static let shared = ModelLoadingCoordinator()

    /// Current loading strategy based on system RAM
    @Published private(set) var strategy: ModelLoadingStrategy

    /// Whether Hunyuan model is currently being preloaded in the background
    @Published private(set) var isPreloadingHunyuan: Bool = false

    /// Whether Hunyuan model has been preloaded and is ready
    @Published private(set) var isHunyuanPreloaded: Bool = false

    /// System RAM in bytes
    let systemRAM: UInt64

    /// Formatted system RAM for display
    var formattedSystemRAM: String {
        ByteCountFormatter.string(fromByteCount: Int64(systemRAM), countStyle: .memory)
    }

    private var preloadTask: Task<Void, Never>?

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

    /// Check which Hunyuan models are available for preloading
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

    /// Called when SAM model is ready - triggers async Hunyuan preload if using aggressive strategy
    func onSAMModelReady(env: PythonEnvironment) {
        guard strategy == .aggressive && !isHunyuanPreloaded && !isPreloadingHunyuan else {
            if strategy == .conservative {
                print("[ModelLoadingCoordinator] Conservative strategy - skipping Hunyuan preload")
            }
            return
        }

        // Check if we have a model to preload
        guard let variant = getAvailableHunyuanVariant() else {
            print("[ModelLoadingCoordinator] No Hunyuan model available to preload")
            return
        }

        print("[ModelLoadingCoordinator] SAM ready, starting async Hunyuan preload (variant: \(variant))...")
        isPreloadingHunyuan = true

        preloadTask = Task {
            await preloadHunyuanModel(env: env, variant: variant)
        }
    }

    /// Preload Hunyuan model in the background (aggressive strategy only)
    private func preloadHunyuanModel(env: PythonEnvironment, variant: String) async {
        guard let uvPath = env.findUVPath() else {
            print("[ModelLoadingCoordinator] UV path not found, cannot preload Hunyuan")
            isPreloadingHunyuan = false
            return
        }

        let hunyuanDir = PathManager.hunyuanProjectDirectory
        let hunyuanVenv = PathManager.hunyuanVenvDirectory
        let hunyuanScript = PathManager.hunyuanWrapperPath.path

        let process = Process()
        process.executableURL = URL(fileURLWithPath: uvPath)
        process.arguments = [
            "run", "--project", hunyuanDir.path, hunyuanScript,
            "--warmup",
            "--model", variant
        ]
        process.currentDirectoryURL = hunyuanDir

        var processEnv = ProcessInfo.processInfo.environment
        processEnv["UV_PROJECT_ENVIRONMENT"] = hunyuanVenv.path
        processEnv["UV_PYTHON_INSTALL_DIR"] = PathManager.pythonRuntimesDirectory.path
        processEnv["UV_CACHE_DIR"] = PathManager.uvCacheDirectory.path
        processEnv["UV_PYTHON_PREFERENCE"] = "only-managed"
        processEnv["UV_LINK_MODE"] = "copy"
        processEnv["PYTHONUNBUFFERED"] = "1"
        processEnv["HF_HOME"] = PathManager.modelsDirectory.path
        processEnv["HUGGINGFACE_HUB_CACHE"] = PathManager.modelsHubDirectory.path
        processEnv["TRANSFORMERS_CACHE"] = PathManager.modelsHubDirectory.path
        processEnv["MODELR_CONFIG_PATH"] = PathManager.projectConfigPath.path
        processEnv["MODELR_OUTPUTS_DIR"] = PathManager.outputsDirectory.path
        processEnv["MODELR_WORKING_DIR"] = PathManager.workingDirectory.path
        processEnv["MODELR_LOGS_DIR"] = PathManager.logsDirectory.path
        processEnv["MODELR_CHECKPOINTS_DIR"] = PathManager.checkpointsDirectory.path
        processEnv["PYTHONPATH"] = [
            PathManager.libPythonDirectory.path,
            PathManager.libPythonDirectory.appendingPathComponent("modelr_core", isDirectory: true).path
        ].joined(separator: ":")
        process.environment = processEnv

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if let output = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
               !output.isEmpty {
                print("[HunyuanPreload] \(output)")
            }
        }

        do {
            try process.run()

            // Wait for completion on a background thread
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                Task.detached {
                    process.waitUntilExit()
                    continuation.resume()
                }
            }

            pipe.fileHandleForReading.readabilityHandler = nil

            if process.terminationStatus == 0 {
                print("[ModelLoadingCoordinator] Hunyuan preload completed successfully (variant: \(variant))")
                isHunyuanPreloaded = true
            } else {
                print("[ModelLoadingCoordinator] Hunyuan preload failed with status \(process.terminationStatus) - this is OK, model will load on-demand")
            }
        } catch {
            print("[ModelLoadingCoordinator] Hunyuan preload error: \(error) - this is OK, model will load on-demand")
        }

        isPreloadingHunyuan = false
    }

    /// Called before generation step - handles model offloading for conservative strategy
    /// Returns true if ready to proceed, false if caller should wait
    func prepareForGeneration(env: PythonEnvironment) async -> Bool {
        if strategy == .conservative {
            print("[ModelLoadingCoordinator] Conservative strategy: Offloading SAM model before generation...")
            env.stopPersistentWorker()

            // Small delay to ensure resources are released
            try? await Task.sleep(nanoseconds: 500_000_000)  // 0.5 seconds

            print("[ModelLoadingCoordinator] SAM model offloaded, ready for Hunyuan generation")
        }

        return true
    }

    /// Called after generation completes - restarts SAM if needed
    func onGenerationComplete(env: PythonEnvironment) async {
        if strategy == .conservative {
            print("[ModelLoadingCoordinator] Generation complete, SAM will be reloaded when needed")
            // SAM will be loaded on-demand when user goes back to segmentation
        }
    }

    /// Cancel any ongoing preload operation
    func cancelPreload() {
        preloadTask?.cancel()
        preloadTask = nil
        isPreloadingHunyuan = false
    }
}
