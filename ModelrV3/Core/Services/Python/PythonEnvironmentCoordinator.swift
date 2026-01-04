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
class PythonEnvironment: ObservableObject {
    @Published var isSetup = false
    @Published var status = "Initializing..."
    @Published var selectedModel = "base_plus"
    @Published var isProcessing = false
    @Published var hunyuanProgress: String = ""
    @Published var samModelReady = false
    @Published var isGenerationCancelled = false
    @Published var selectedGenerator: GeneratorModel = .hunyuan
    
    private let appSupportDir: URL
    private let venvDir: URL
    private let hunyuanVenvDir: URL
    
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
        venvDir = appSupportDir.appendingPathComponent(".venv")
        hunyuanVenvDir = appSupportDir.appendingPathComponent(".venv_hunyuan")
        
        do {
            try fileManager.createDirectory(at: appSupportDir, withIntermediateDirectories: true)
        } catch {
            print("ERROR: Failed to create directory: \(error.localizedDescription)")
        }
        
        dependencyService = PythonDependencyService(appSupportDir: appSupportDir)
        processManager = PythonProcessManager(
            appSupportDir: appSupportDir,
            venvDir: venvDir,
            hunyuanVenvDir: hunyuanVenvDir
        )
        processManager.selectedModel = selectedModel
        
        Task {
            await setup()
        }
    }
    
    deinit {
        processManager.stopPersistentWorker()
    }
    
    // MARK: - Setup
    
    func setup() async {
        let success = await dependencyService.setup { [weak self] statusText in
            Task { @MainActor in
                self?.status = statusText
            }
        }
        
        await MainActor.run {
            isSetup = success
            status = success ? "Ready" : "Setup failed"
        }
    }
    
    // MARK: - Worker Management
    
    func startPersistentWorker() async throws {
        guard let uvPath = dependencyService.cachedUvPath else {
            throw PythonError.uvNotFound
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

    // MARK: - Legacy API

    @available(*, deprecated, message: "Use setImage() and predict() for faster iterative refinement")
    func runSAM2(imagePath: String, x: Int, y: Int) async -> URL? {
        guard isSetup else { return nil }
        
        guard let uvPath = dependencyService.cachedUvPath else { return nil }
        
        await MainActor.run { status = "Segmenting..." }
        
        let scriptPath = appSupportDir.appendingPathComponent("sam_wrapper.py").path
        let maskPath = appSupportDir.appendingPathComponent("mask.png").path
        
        let process = Process()
        process.executableURL = URL(fileURLWithPath: uvPath)
        process.arguments = ["run", scriptPath, "--model", selectedModel, imagePath, "\(x)", "\(y)", maskPath]
        process.currentDirectoryURL = appSupportDir
        
        var env = ProcessInfo.processInfo.environment
        env["UV_PROJECT_ENVIRONMENT"] = venvDir.path
        env["UV_PYTHON_INSTALL_DIR"] = appSupportDir.appendingPathComponent("python_runtimes").path
        env["UV_CACHE_DIR"] = appSupportDir.appendingPathComponent("uv_cache").path
        env["UV_PYTHON_PREFERENCE"] = "only-managed"
        env["PYTHONUNBUFFERED"] = "1"
        env["PYTHONPATH"] = appSupportDir.path
        process.environment = env
        
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        
        do {
            try process.run()
            process.waitUntilExit()
            
            if process.terminationStatus == 0 {
                await MainActor.run { status = "Done" }
                return URL(fileURLWithPath: maskPath)
            }
        } catch {
            print("Error running SAM2: \(error)")
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
