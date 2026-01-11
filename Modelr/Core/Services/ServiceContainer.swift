import os.log
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
/// Uses RAM-based strategy to determine which models to preload
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

    /// RAM-based preload strategy
    enum PreloadStrategy: CustomStringConvertible {
        case minimal      // < 8GB: Only load models on-demand
        case balanced     // 8-16GB: Preload SAM + VLM, lazy load others
        case aggressive   // > 16GB: Preload all models including T2I

        var description: String {
            switch self {
            case .minimal: return "Minimal (on-demand)"
            case .balanced: return "Balanced (SAM + VLM)"
            case .aggressive: return "Aggressive (all models)"
            }
        }
    }

    /// Current preload strategy based on available RAM
    var preloadStrategy: PreloadStrategy {
        let totalRAM = ProcessInfo.processInfo.physicalMemory
        let gbRAM = totalRAM / (1024 * 1024 * 1024)

        switch gbRAM {
        case ..<8: return .minimal
        case 8..<16: return .balanced
        default: return .aggressive
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

    // CRITICAL: Track project ownership to prevent cross-project data leakage
    private var preloadedMergedMask: NSImage?
    private var preloadedMaskProjectId: UUID?
    private var preloadedComposite: NSImage?
    private var preloadedCompositeProjectId: UUID?

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
        let strategy = preloadStrategy
        print("[PreloadManager] Starting background ML preload with strategy: \(strategy.description)")
        print("[PreloadManager] System RAM: \(ProcessInfo.processInfo.physicalMemory / (1024 * 1024 * 1024))GB")

        switch strategy {
        case .minimal:
            // < 8GB: Only preload thumbnails, load models on-demand
            mlPreloadStatus = .preloadingThumbnails
            await preloadThumbnails()

        case .balanced:
            // 8-16GB: Preload VLM + SAM, lazy load Hunyuan/T2I
            mlPreloadStatus = .preloadingVLM
            await preloadVLM()

            mlPreloadStatus = .preloadingSAM
            await preloadSAM()

            // Start Hunyuan in background (fire and forget - doesn't block)
            startHunyuanInBackground()

            mlPreloadStatus = .preloadingThumbnails
            await preloadThumbnails()

        case .aggressive:
            // > 16GB: Preload everything
            mlPreloadStatus = .preloadingVLM
            await preloadVLM()

            mlPreloadStatus = .preloadingSAM
            await preloadSAM()

            // Start Hunyuan in background (fire and forget)
            startHunyuanInBackground()

            mlPreloadStatus = .preloadingThumbnails
            await preloadThumbnails()
        }

        let elapsed = CFAbsoluteTimeGetCurrent() - startTime
        print("[PreloadManager] ML preload complete in \(String(format: "%.2f", elapsed))s")

        mlPreloadStatus = .ready
        isMLReady = true
    }


    /// Preload models for a specific project mode
    func preloadForMode(_ mode: ProjectMode) async {
        print("[PreloadManager] Preloading for mode: \(mode.displayName)")

        switch mode {
        case .imageToModel:
            // Ensure SAM + VLM are ready for image-to-model workflow
            if !ServiceContainer.shared.pythonEnvironment.samModelReady {
                mlPreloadStatus = .preloadingSAM
                await preloadSAM()
            }
            if !ModelLoadingCoordinator.shared.isVLMReady {
                mlPreloadStatus = .preloadingVLM
                await preloadVLM()
            }
        }

        mlPreloadStatus = .ready
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
    /// CRITICAL: Now tracks projectId to prevent cross-project data leakage
    func preloadMergedMask(from segmentations: [SegmentationEntry], projectId: UUID) {
        // Cancel previous debounce
        maskMergeDebounceWorkItem?.cancel()

        // Create new debounced work
        maskMergeDebounceWorkItem = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                await self?.performMaskMerge(from: segmentations, projectId: projectId)
            }
        }

        // Schedule with delay
        DispatchQueue.main.asyncAfter(
            deadline: .now() + debounceDelay,
            execute: maskMergeDebounceWorkItem!
        )
    }

    private func performMaskMerge(from segmentations: [SegmentationEntry], projectId: UUID) async {
        // Get all valid selected masks
        let masks = segmentations.flatMap { $0.selectedMasks }
        guard !masks.isEmpty else {
            preloadedMergedMask = nil
            preloadedMaskProjectId = nil
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
                self?.preloadedMaskProjectId = projectId  // Track ownership
                self?.isMaskMergePreloading = false
                print("[PreloadManager] Cached mask for project \(projectId.uuidString.prefix(8))")
            }
        }
    }

    /// Clear preloaded mask (called when going back or starting new)
    func clearPreloadedMask() {
        maskMergeTask?.cancel()
        maskMergeTask = nil
        maskMergeDebounceWorkItem?.cancel()
        preloadedMergedMask = nil
        preloadedMaskProjectId = nil
        isMaskMergePreloading = false
    }

    /// Get the cached merged mask ONLY if it belongs to the specified project
    /// CRITICAL: Validates project ownership to prevent cross-project data leakage
    func getCachedMergedMask(for projectId: UUID) -> NSImage? {
        guard preloadedMaskProjectId == projectId else {
            print("[PreloadManager] Mask cache miss - cached for \(preloadedMaskProjectId?.uuidString.prefix(8) ?? "nil"), requested for \(projectId.uuidString.prefix(8))")
            return nil
        }
        return preloadedMergedMask
    }

    // MARK: - Composite Image Preloading

    /// Preload composite image when mask is ready
    /// CRITICAL: Now tracks projectId to prevent cross-project data leakage
    func preloadComposite(source: NSImage, mask: NSImage, projectId: UUID) {
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
                self?.preloadedCompositeProjectId = projectId  // Track ownership
                self?.isCompositePreloading = false
                print("[PreloadManager] Cached composite for project \(projectId.uuidString.prefix(8))")
            }
        }
    }

    /// Clear preloaded composite (called when going back or starting new)
    func clearPreloadedComposite() {
        compositeTask?.cancel()
        compositeTask = nil
        preloadedComposite = nil
        preloadedCompositeProjectId = nil
        isCompositePreloading = false
    }

    /// Get the preloaded composite ONLY if it belongs to the specified project
    /// CRITICAL: Validates project ownership to prevent cross-project data leakage
    func getPreloadedComposite(for projectId: UUID) -> NSImage? {
        guard preloadedCompositeProjectId == projectId else {
            print("[PreloadManager] Composite cache miss - cached for \(preloadedCompositeProjectId?.uuidString.prefix(8) ?? "nil"), requested for \(projectId.uuidString.prefix(8))")
            return nil
        }
        return preloadedComposite
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
        maskMergeDebounceWorkItem = nil

        preloadedMergedMask = nil
        preloadedMaskProjectId = nil
        preloadedComposite = nil
        preloadedCompositeProjectId = nil
        isMaskMergePreloading = false
        isCompositePreloading = false
    }

    /// Get preloaded mask if available for this project, otherwise merge synchronously
    /// CRITICAL: Validates project ownership before returning cached data
    func getMergedMask(from segmentations: [SegmentationEntry], projectId: UUID) -> NSImage? {
        // If we have a preloaded mask FOR THIS PROJECT, use it
        if let preloaded = getCachedMergedMask(for: projectId) {
            return preloaded
        }

        // Otherwise merge now (synchronous fallback)
        let masks = segmentations.flatMap { $0.selectedMasks }
        return ImageService.shared.mergeMasks(masks)
    }

}
