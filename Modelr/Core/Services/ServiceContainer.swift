import Foundation
import AppKit
import Combine

/// Centralized container for application services to ensure single instances
@MainActor
class ServiceContainer {
    static let shared = ServiceContainer()

    /// Shared Python environment instance
    let pythonEnvironment: PythonEnvironment

    /// Shared generation service instance
    let generationService: GenerationService

    private init() {
        let env = PythonEnvironment()
        self.pythonEnvironment = env
        self.generationService = GenerationService(env: env)
    }
}

// MARK: - PreloadManager

/// Manages async preloading of resources for improved UX
/// Preloads data in the background before the user needs it
@MainActor
class PreloadManager: ObservableObject {
    static let shared = PreloadManager()

    // MARK: - ML Preload State
    @Published private(set) var mlPreloadStatus: MLPreloadStatus = .idle
    @Published private(set) var isMLReady: Bool = false
    @Published private(set) var areThumbnailsReady: Bool = false

    enum MLPreloadStatus: Equatable {
        case idle
        case preloadingVLM
        case preloadingSAM
        case preloadingThumbnails
        case ready
        case failed(String)

        var description: String {
            switch self {
            case .idle: return "Idle"
            case .preloadingVLM: return "Loading VLM..."
            case .preloadingSAM: return "Loading SAM..."
            case .preloadingThumbnails: return "Loading thumbnails..."
            case .ready: return "Ready"
            case .failed(let error): return "Failed: \(error)"
            }
        }
    }

    var isPreloading: Bool {
        switch mlPreloadStatus {
        case .preloadingVLM, .preloadingSAM, .preloadingThumbnails:
            return true
        default:
            return false
        }
    }

    var statusDescription: String {
        mlPreloadStatus.description
    }

    // MARK: - Preload State
    @Published private(set) var isMaskMergePreloading = false
    @Published private(set) var isCompositePreloading = false
    @Published private(set) var preloadedMergedMask: NSImage?
    @Published private(set) var preloadedComposite: NSImage?

    // MARK: - Task Management
    private var maskMergeTask: Task<Void, Never>?
    private var compositeTask: Task<Void, Never>?
    private var modelCheckTask: Task<Void, Never>?
    private var mlPreloadTask: Task<Void, Never>?
    private var hasStartedMLPreload = false

    // MARK: - Debounce
    private var maskMergeDebounceWorkItem: DispatchWorkItem?
    private let debounceDelay: TimeInterval = 0.3

    private init() {}

    // MARK: - ML Model Preloading

    /// Start preloading ML models (call once from app startup)
    func startPreloading() {
        guard !hasStartedMLPreload else { return }
        hasStartedMLPreload = true

        // Only preload if setup is complete
        guard PathManager.isSetupComplete else {
            print("[PreloadManager] Setup not complete, skipping ML preload")
            return
        }

        mlPreloadTask = Task { [weak self] in
            await self?.performMLPreload()
        }
    }

    private func performMLPreload() async {
        let startTime = CFAbsoluteTimeGetCurrent()
        print("[PreloadManager] Starting background ML preload...")

        // Phase 1: Start VLM server (highest priority - used for auto-naming)
        mlPreloadStatus = .preloadingVLM
        await preloadVLM()

        // Phase 2: Start SAM server (needed for segmentation)
        mlPreloadStatus = .preloadingSAM
        await preloadSAM()

        // Phase 3: Start Hunyuan in background (fire and forget - doesn't block)
        // This runs with low priority and won't interfere with SAM/VLM
        startHunyuanInBackground()

        // Phase 4: Preload thumbnails (lower priority)
        mlPreloadStatus = .preloadingThumbnails
        await preloadThumbnails()

        let elapsed = CFAbsoluteTimeGetCurrent() - startTime
        print("[PreloadManager] ML preload complete in \(String(format: "%.2f", elapsed))s")

        mlPreloadStatus = .ready
        isMLReady = true
    }

    /// Start Hunyuan loading in background (fire and forget)
    /// This ensures SAM/VLM remain responsive while Hunyuan loads
    private func startHunyuanInBackground() {
        let coordinator = ModelLoadingCoordinator.shared
        let env = ServiceContainer.shared.pythonEnvironment

        // Only start if model is downloaded and not already loading
        guard PathManager.isHunyuanModelDownloaded(variant: "mini") else {
            print("[PreloadManager] Hunyuan model not downloaded, skipping preload")
            return
        }

        print("[PreloadManager] Starting Hunyuan preload in background (low priority)...")
        coordinator.startHunyuanInBackground(env: env)
    }

    private func preloadVLM() async {
        let coordinator = ModelLoadingCoordinator.shared

        // Skip if already ready
        if coordinator.isVLMReady {
            print("[PreloadManager] VLM already ready")
            return
        }

        let env = ServiceContainer.shared.pythonEnvironment
        let startTime = CFAbsoluteTimeGetCurrent()
        print("[PreloadManager] Preloading VLM server...")

        let ready = await coordinator.ensureVLMReady(env: env)

        let elapsed = CFAbsoluteTimeGetCurrent() - startTime
        if ready {
            print("[PreloadManager] VLM ready in \(String(format: "%.2f", elapsed))s")
        } else {
            print("[PreloadManager] VLM failed to start after \(String(format: "%.2f", elapsed))s")
        }
    }

    private func preloadSAM() async {
        let env = ServiceContainer.shared.pythonEnvironment

        // Skip if already loaded
        if env.samModelReady {
            print("[PreloadManager] SAM already loaded")
            return
        }

        let startTime = CFAbsoluteTimeGetCurrent()
        print("[PreloadManager] Preloading SAM model...")

        await env.preloadSAMModel()

        let elapsed = CFAbsoluteTimeGetCurrent() - startTime
        print("[PreloadManager] SAM preload complete in \(String(format: "%.2f", elapsed))s")
    }

    private func preloadThumbnails() async {
        let projectManager = ProjectManager.shared

        // Ensure projects are loaded
        if projectManager.projects.isEmpty {
            await projectManager.loadProjects()
        }

        let examples = projectManager.getExampleImages()
        let projects = projectManager.projects

        print("[PreloadManager] Preloading \(projects.count) thumbnails and \(examples.count) examples...")

        // Use ThumbnailCache for preloading
        await ThumbnailCache.shared.preloadBrowserAssets(projects: projects, examples: examples)

        areThumbnailsReady = true
        print("[PreloadManager] Thumbnails preloaded")
    }

    // MARK: - Mask Merge Preloading

    /// Preload merged mask when segmentations change
    /// Called with debounce to avoid excessive computation during rapid changes
    func preloadMergedMask(from segmentations: [SegmentationEntry]) {
        // Cancel previous debounce
        maskMergeDebounceWorkItem?.cancel()

        // Create new debounced work
        maskMergeDebounceWorkItem = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                await self?.performMaskMerge(from: segmentations)
            }
        }

        // Schedule with delay
        DispatchQueue.main.asyncAfter(
            deadline: .now() + debounceDelay,
            execute: maskMergeDebounceWorkItem!
        )
    }

    private func performMaskMerge(from segmentations: [SegmentationEntry]) async {
        // Get all valid selected masks
        let masks = segmentations.flatMap { $0.selectedMasks }
        guard !masks.isEmpty else {
            preloadedMergedMask = nil
            return
        }

        // Cancel any existing task
        maskMergeTask?.cancel()

        isMaskMergePreloading = true

        maskMergeTask = Task { [weak self] in
            // Run merge on background thread
            let merged = await Task.detached(priority: .utility) {
                ImageService.shared.mergeMasks(masks)
            }.value

            // Check for cancellation
            guard !Task.isCancelled else { return }

            await MainActor.run {
                self?.preloadedMergedMask = merged
                self?.isMaskMergePreloading = false
            }
        }
    }

    /// Clear preloaded mask (called when going back or starting new)
    func clearPreloadedMask() {
        maskMergeTask?.cancel()
        maskMergeTask = nil
        maskMergeDebounceWorkItem?.cancel()
        preloadedMergedMask = nil
        isMaskMergePreloading = false
    }

    // MARK: - Composite Image Preloading

    /// Preload composite image when mask is ready
    func preloadComposite(source: NSImage, mask: NSImage) {
        // Cancel any existing task
        compositeTask?.cancel()

        isCompositePreloading = true

        compositeTask = Task { [weak self] in
            // Run composite creation on background thread
            let composite = await Task.detached(priority: .utility) {
                ImageService.shared.createCompositeImage(source: source, mask: mask)
            }.value

            // Check for cancellation
            guard !Task.isCancelled else { return }

            await MainActor.run {
                self?.preloadedComposite = composite
                self?.isCompositePreloading = false
            }
        }
    }

    /// Clear preloaded composite (called when going back or starting new)
    func clearPreloadedComposite() {
        compositeTask?.cancel()
        compositeTask = nil
        preloadedComposite = nil
        isCompositePreloading = false
    }

    // MARK: - Model Availability Preloading

    /// Preload model availability check during setup
    func preloadModelAvailability(completion: @escaping (Bool) -> Void) {
        modelCheckTask?.cancel()

        modelCheckTask = Task {
            // Run file checks on background thread
            let miniDownloaded = await Task.detached(priority: .utility) {
                PathManager.isHunyuanModelDownloaded(variant: "mini")
            }.value

            guard !Task.isCancelled else { return }

            await MainActor.run {
                completion(miniDownloaded)
            }
        }
    }

    // MARK: - Cleanup

    /// Cancel all preloading tasks
    func cancelAll() {
        maskMergeTask?.cancel()
        maskMergeTask = nil
        compositeTask?.cancel()
        compositeTask = nil
        modelCheckTask?.cancel()
        modelCheckTask = nil
        maskMergeDebounceWorkItem?.cancel()

        preloadedMergedMask = nil
        preloadedComposite = nil
        isMaskMergePreloading = false
        isCompositePreloading = false
    }

    /// Get preloaded mask if available, otherwise merge synchronously
    func getMergedMask(from segmentations: [SegmentationEntry]) -> NSImage? {
        // If we have a preloaded mask, use it
        if let preloaded = preloadedMergedMask {
            return preloaded
        }

        // Otherwise merge now (synchronous fallback)
        let masks = segmentations.flatMap { $0.selectedMasks }
        return ImageService.shared.mergeMasks(masks)
    }

    /// Get preloaded composite if available
    func getPreloadedComposite() -> NSImage? {
        return preloadedComposite
    }
}
