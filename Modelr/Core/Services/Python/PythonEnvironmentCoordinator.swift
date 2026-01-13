import os.log
import Foundation
import AppKit

// Note: GeneratorModel is defined in GenerationModels.swift

/// Coordinates all Python-related services (dependencies, processes, communication)
///
/// Directory structure in ~/Library/Application Support/Modelr/:
/// ├── Lib/python/modelr_core/ # Shared Python module
/// ├── Environments/sam/       # Segmentation environment
/// ├── Environments/tools/     # Mesh processing environment
/// └── Environments/hunyuan/   # 3D generation environment
class PythonEnvironment: ObservableObject {
    @Published var isSetup = false
    @Published var status = "Initializing..."
    @Published var selectedModel = "base_plus"
    @Published var isProcessing = false
    @Published var hunyuanProgress: String = ""
    @Published var samModelReady = false
    @Published var isGenerationCancelled = false
    @Published var selectedGenerator: GeneratorModel = .hunyuan

    private let dependencyService: PythonDependencyService
    private let processManager: PythonProcessManager
    private var bridge: PythonBridge?

    private var currentImagePath: String?
    private var imagePixelSize: CGSize = .zero

    /// Track which project owns the currently encoded SAM image (CRITICAL for preventing cross-project segmentation)
    private(set) var currentImageProjectId: UUID?

    /// Used for dependency injection during unit tests
    var resourcePathOverride: String? {
        didSet {
            dependencyService.resourcePathOverride = resourcePathOverride
        }
    }

    init() {
        dependencyService = PythonDependencyService()
        processManager = PythonProcessManager()
    }
    
deinit {
        // CRITICAL: deinit must be fast and non-blocking
        // Fire-and-forget cleanup without blocking
        let process = processManager.persistentProcess
        let pid = process?.processIdentifier

        // Terminate process without waiting
        process?.terminate()

        // Forceful cleanup in background
        if let pid = pid {
            DispatchQueue.global().async {
                usleep(200_000)  // 200ms grace period
                kill(pid, SIGKILL)
            }
        }

        // Don't call stopPersistentWorker() - it blocks
    }
    
    // MARK: - Setup
    func setup(
        modelChoice: SetupModelChoice = .fast,
        onProgress: @escaping (SetupProgressUpdate) -> Void
    ) async -> Bool {
        let success = await dependencyService.setup(
            modelChoice: modelChoice, 
            onProgress: { [weak self] update in
                if update.stage == .completed {
                    Task { @MainActor in
                        self?.isSetup = true
                        self?.status = "Ready"
                    }
                } else if update.stage == .failed {
                    Task { @MainActor in
                        self?.isSetup = false
                        self?.status = "Setup failed"
                    }
                }
                onProgress(update)
            }
        )

        return success
    }

    /// Mark the Hunyuan environment as ready (called by new setup flow)
    func markHunyuanReady() {
        dependencyService.hunyuanVenvReady = true
        isSetup = true
        status = "Ready"
    }

    /// Refresh Python environments (venvs) without re-downloading models
    /// Called when app build changes to update dependencies
    func refreshEnvironments(onProgress: @escaping (SetupProgressUpdate) -> Void) async -> Bool {
        let success = await dependencyService.refreshEnvironments(onProgress: onProgress)
        if success {
            isSetup = true
            status = "Ready"
        }
        return success
    }

    /// Check if environments need refreshing
    var needsEnvironmentRefresh: Bool {
        dependencyService.needsEnvironmentRefresh
    }

    /// Copy resources to Application Support
    func copyResources() async {
        // Use the internal dependency service which has our improved recursive copy logic
        _ = await dependencyService.setup(onProgress: { _ in }) // This calls copyResourceFiles internally
    }

    /// Sync the Python environment using uv
    func syncEnvironment(pythonVersion: String = "3.13") async -> Bool {
        guard dependencyService.cachedUvPath != nil else { return false }
        
        // Use the dependency service setup
        let success = await dependencyService.setup(onProgress: { _ in })
        return success
    }
    
    // MARK: - Worker Management
    
    func startPersistentWorker() async throws {
        guard let uvPath = dependencyService.cachedUvPath else {
            throw PythonError.uvNotFound
        }

        // Ensure resources are present before starting
        if !dependencyService.checkResources() {
            print("[Python] Resources missing in Application Support, copying...")
            _ = await setup(onProgress: { _ in })
        }

        try processManager.startPersistentWorker(uvPath: uvPath)

        // Initialize bridge
        bridge = PythonBridge(processManager: processManager)

        // Wait for ready signal
        let response = try await bridge!.waitForResponse(timeout: 30)
        guard response.ready == true else {
            throw PythonError.workerNotReady
        }

        print("Persistent worker ready")
        await MainActor.run {
            samModelReady = true
            // Notify coordinator that SAM is ready (triggers async Hunyuan preload if aggressive strategy)
            ModelLoadingCoordinator.shared.onSAMModelReady(env: self)
        }
    }
    
    func preloadSAMModel() async {
        guard isSetup && !samModelReady else { return }
        await MainActor.run { status = "Loading SAM model..." }
        do {
            try await startPersistentWorker()
        } catch {
            print("Failed to preload SAM model: \(error)")
        }
        await MainActor.run { status = "Ready" }
    }
    
    func stopPersistentWorker() {
        processManager.stopPersistentWorker()
        bridge = nil
        currentImagePath = nil
        imagePixelSize = .zero
        currentImageProjectId = nil  // Clear project ownership
        samModelReady = false
        print("[PythonEnvironment] Worker stopped, all state cleared")
    }
    
    // MARK: - Image & Prediction API

    /// Set image for SAM segmentation, tracking which project it belongs to
    /// CRITICAL: This prevents cross-project segmentation bugs
    func setImage(path: String, projectId: UUID) async throws -> CGSize {
        if !processManager.isWorkerRunning {
            try await startPersistentWorker()
        }

        guard let bridge = bridge else {
            throw PythonError.workerNotRunning
        }

        let size = try await bridge.setImage(path: path)
        currentImagePath = path
        imagePixelSize = size
        currentImageProjectId = projectId  // Track ownership

        print("[PythonEnvironment] SAM image set for project \(projectId.uuidString.prefix(8))")
        return size
    }

    /// Check if the correct image is loaded for a project
    func isImageLoadedFor(projectId: UUID) -> Bool {
        return currentImageProjectId == projectId && processManager.isWorkerRunning
    }
    
    func predict(
        points: [SAMPoint] = [],
        box: SAMBox? = nil,
        text: String? = nil,
        imageSize: CGSize
    ) async throws -> (masks: [URL], primaryMask: URL, scores: [Double], confidenceMap: URL?) {
        guard processManager.isWorkerRunning else {
            throw PythonError.workerNotRunning
        }
        
        guard let bridge = bridge else {
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
        
        return try await bridge.predict(points: points, box: box, text: text, imageSize: imageSize)
    }
    
    func removeBackground() async throws -> URL {
        guard processManager.isWorkerRunning else {
            throw PythonError.workerNotRunning
        }
        
        guard let bridge = bridge else {
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
        
        return try await bridge.removeBackground()
    }
    
    func resetPredictor() async throws {
        guard processManager.isWorkerRunning else { return }
        guard let bridge = bridge else { return }

        try await bridge.resetPredictor()
        currentImagePath = nil
        imagePixelSize = .zero
        currentImageProjectId = nil  // Clear project ownership
        print("[PythonEnvironment] SAM predictor reset, project ownership cleared")
    }
    
    // MARK: - 3D Model Generation

    func generate3DModel(
        imagePath: String,
        maskPath: String,
        steps: Int,
        resolution: Int,
        modelVariant: String = "std",
        guidanceScale: Double = 5.0,
        boxV: Double = 1.01,
        mcLevel: Double = 0.0,
        progress: @escaping (String) -> Void,
        preview: ((Data) -> Void)? = nil,
        completion: @escaping (Result<URL, Error>) -> Void
    ) async {
        guard dependencyService.hunyuanVenvReady else {
            completion(.failure(PythonError.predictionFailed("Hunyuan3D environment not ready")))
            return
        }

        let outputURL = PathManager.generatedModelPath(
            variant: modelVariant,
            steps: steps,
            resolution: resolution,
            guidanceScale: guidanceScale != 5.0 ? guidanceScale : nil,
            boxV: boxV != 1.01 ? boxV : nil,
            mcLevel: mcLevel != 0.0 ? mcLevel : nil
        )
        let outputPath = outputURL.path

        await MainActor.run {
            isGenerationCancelled = false
        }

        // Use the persistent Hunyuan server via ModelLoadingCoordinator
        let coordinator = await MainActor.run { ModelLoadingCoordinator.shared }

        // Check if persistent server is available with the correct variant
        // If variant doesn't match, the server will be restarted
        let isReady = await coordinator.ensureHunyuanReady(env: self, variant: modelVariant)

        if isReady {
            // Use persistent server
            do {
                let resultURL = try await coordinator.generate(
                    imagePath: imagePath,
                    maskPath: maskPath,
                    outputPath: outputPath,
                    steps: steps,
                    resolution: resolution,
                    guidanceScale: guidanceScale,
                    boxV: boxV,
                    mcLevel: mcLevel,
                    onProgress: { stage, detail, value in
                        // Format progress string with stage info for the UI parser
                        // stage is "loading", "diffusion", "volume_decoding", "saving"
                        // detail is step count like "1/25" or status message
                        let percent = Int(value * 100)
                        print("[Coordinator] onProgress: stage=\(stage) detail=\(detail) value=\(value)")
                        if stage == "diffusion" {
                            // Include step count in parentheses for proper parsing
                            let stepInfo = detail.isEmpty ? "" : " (\(detail))"
                            let msg = "Diffusion Sampling\(stepInfo) - PROGRESS:\(percent)%"
                            print("[Coordinator] Sending: \(msg)")
                            progress(msg)
                        } else if stage == "volume_decoding" {
                            let stepInfo = detail.isEmpty ? "" : " (\(detail))"
                            let msg = "Volume Decoding\(stepInfo) - PROGRESS:\(percent)%"
                            print("[Coordinator] Sending: \(msg)")
                            progress(msg)
                        } else if stage == "saving" {
                            let stepInfo = detail.isEmpty ? "" : " (\(detail))"
                            let msg = "Saving\(stepInfo) - PROGRESS:\(percent)%"
                            print("[Coordinator] Sending: \(msg)")
                            progress(msg)
                        } else if stage == "loading" {
                            progress("Loading Model - PROGRESS:\(percent)%")
                        } else {
                            progress("PROGRESS:\(percent)% - \(detail)")
                        }
                    }
                )
                completion(.success(resultURL))
            } catch {
                completion(.failure(error))
            }
        } else {
            // Fall back to one-shot generation (for cases where persistent server isn't running)
            guard let uvPath = dependencyService.cachedUvPath else {
                completion(.failure(PythonError.uvNotFound))
                return
            }

            processManager.start3DGeneration(
                uvPath: uvPath,
                imagePath: imagePath,
                maskPath: maskPath,
                outputPath: outputURL,
                steps: steps,
                resolution: resolution,
                modelVariant: modelVariant,
                progressCallback: progress,
                completion: completion
            )
        }
    }
    
    func cancelGeneration() {
        processManager.cancelGeneration()
        isGenerationCancelled = true
    }
    
    // MARK: - Utility

    func findUVPath() -> String? {
        dependencyService.cachedUvPath
    }
}
