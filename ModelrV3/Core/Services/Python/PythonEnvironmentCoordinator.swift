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

/// Coordinates all Python-related services (dependencies, processes, communication)
///
/// Directory structure in ~/Library/Application Support/ModelrV3/:
/// ├── modelrv3_core/         # Shared Python module
/// ├── SAM/                   # Segmentation environment
/// ├── Tools/                 # Mesh processing environment
/// └── Hunyuan3D/             # 3D generation environment
class PythonEnvironment: ObservableObject {
    @Published var isSetup = false
    @Published var status = "Initializing..."
    @Published var selectedModel = "base_plus"
    @Published var isProcessing = false
    @Published var hunyuanProgress: String = ""
    @Published var samModelReady = false
    @Published var isGenerationCancelled = false
    @Published var selectedGenerator: GeneratorModel = .hunyuan

    let appSupportDir: URL

    private let dependencyService: PythonDependencyService
    private let processManager: PythonProcessManager
    private var bridge: PythonBridge?

    private var currentImagePath: String?
    private var imagePixelSize: CGSize = .zero

    /// Used for dependency injection during unit tests
    var resourcePathOverride: String? {
        didSet {
            dependencyService.resourcePathOverride = resourcePathOverride
        }
    }

    init() {
        let fileManager = FileManager.default
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        appSupportDir = appSupport.appendingPathComponent("ModelrV3")

        do {
            try fileManager.createDirectory(at: appSupportDir, withIntermediateDirectories: true)
        } catch {
            print("ERROR: Failed to create directory: \(error.localizedDescription)")
        }

        dependencyService = PythonDependencyService(appSupportDir: appSupportDir)
        processManager = PythonProcessManager(appSupportDir: appSupportDir)
        processManager.selectedModel = selectedModel
    }
    
    deinit {
        processManager.stopPersistentWorker()
    }
    
    // MARK: - Setup
    
    func setup(statusUpdate: ((String) -> Void)? = nil) async -> Bool {
        let success = await dependencyService.setup { [weak self] statusText in
            statusUpdate?(statusText)
            Task { @MainActor in
                self?.status = statusText
            }
        }

        await MainActor.run {
            isSetup = success
            status = success ? "Ready" : "Setup failed"
        }
        return success
    }

    /// Mark the Hunyuan environment as ready (called by new setup flow)
    func markHunyuanReady() {
        dependencyService.hunyuanVenvReady = true
        isSetup = true
        status = "Ready"
    }

    /// Copy resources to Application Support
    func copyResources() async {
        // Use the internal dependency service which has our improved recursive copy logic
        _ = await dependencyService.setup { _ in } // This calls copyResourceFiles internally
    }

    /// Sync the Python environment using uv
    func syncEnvironment(pythonVersion: String = "3.13") async -> Bool {
        guard dependencyService.cachedUvPath != nil else { return false }
        
        // Use the dependency service setup
        let success = await dependencyService.setup { _ in }
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
            _ = await setup()
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
        await MainActor.run { samModelReady = true }
    }
    
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
    
    func stopPersistentWorker() {
        processManager.stopPersistentWorker()
        bridge = nil
        currentImagePath = nil
        imagePixelSize = .zero
        samModelReady = false
    }
    
    // MARK: - Image & Prediction API
    
    func setImage(path: String) async throws -> CGSize {
        if !processManager.isWorkerRunning {
            try await startPersistentWorker()
        }
        
        guard let bridge = bridge else {
            throw PythonError.workerNotRunning
        }
        
        let size = try await bridge.setImage(path: path)
        currentImagePath = path
        imagePixelSize = size
        return size
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
    }
    
    // MARK: - 3D Model Generation
    
    func generate3DModel(
        imagePath: String,
        maskPath: String,
        steps: Int,
        resolution: Int,
        modelVariant: String = "std",
        progress: @escaping (String) -> Void,
        completion: @escaping (Result<URL, Error>) -> Void
    ) async {
        guard let uvPath = dependencyService.cachedUvPath else {
            completion(.failure(PythonError.uvNotFound))
            return
        }

        guard dependencyService.hunyuanVenvReady else {
            completion(.failure(PythonError.predictionFailed("Hunyuan3D environment not ready")))
            return
        }

        let hunyuanDir = appSupportDir.appendingPathComponent("Hunyuan3D")
        let timestamp = Int(Date().timeIntervalSince1970)
        let outputPath = hunyuanDir.appendingPathComponent("generated_model_\(timestamp).obj")

        await MainActor.run {
            isGenerationCancelled = false
        }

        processManager.start3DGeneration(
            uvPath: uvPath,
            imagePath: imagePath,
            maskPath: maskPath,
            outputPath: outputPath,
            steps: steps,
            resolution: resolution,
            modelVariant: modelVariant,
            progressCallback: progress,
            completion: completion
        )
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
