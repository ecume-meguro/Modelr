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

    // MARK: - Preload State
    @Published private(set) var isMaskMergePreloading = false
    @Published private(set) var isCompositePreloading = false
    @Published private(set) var preloadedMergedMask: NSImage?
    @Published private(set) var preloadedComposite: NSImage?

    // MARK: - Task Management
    private var maskMergeTask: Task<Void, Never>?
    private var compositeTask: Task<Void, Never>?
    private var modelCheckTask: Task<Void, Never>?

    // MARK: - Debounce
    private var maskMergeDebounceWorkItem: DispatchWorkItem?
    private let debounceDelay: TimeInterval = 0.3

    private init() {}

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
    func preloadModelAvailability(completion: @escaping (Bool, Bool) -> Void) {
        modelCheckTask?.cancel()

        modelCheckTask = Task {
            // Run file checks on background thread
            let (mini, std) = await Task.detached(priority: .utility) {
                let miniDownloaded = PathManager.isHunyuanModelDownloaded(variant: "mini")
                let stdDownloaded = PathManager.isHunyuanModelDownloaded(variant: "std")
                return (miniDownloaded, stdDownloaded)
            }.value

            guard !Task.isCancelled else { return }

            await MainActor.run {
                completion(mini, std)
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
