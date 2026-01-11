import os.log
import SwiftUI
import SceneKit

// MARK: - Cache Types and Management
extension SimpleEditorViewModel {

    // MARK: - Cache Restore Methods

    /// Restore cached generation state (after navigating back from post-process)
    /// CRITICAL: Now validates project ownership AND file existence before restoring
    func restoreCachedGeneration() {
        guard let cache = cachedGeneration else { return }

        // CRITICAL: Validate the cache belongs to the current project
        guard let currentProjectId = projectId, cache.projectId == currentProjectId else {
            print("[Cache] Generation cache belongs to different project (cached: \(cache.projectId.uuidString.prefix(8)), current: \(projectId?.uuidString.prefix(8) ?? "nil")), clearing")
            cachedGeneration = nil
            return
        }

        // CRITICAL: Validate the cached model file still exists
        guard FileManager.default.fileExists(atPath: cache.modelURL.path) else {
            print("[Cache] Cached model file no longer exists at: \(cache.modelURL.path), clearing cache")
            cachedGeneration = nil
            return
        }

        generated3DModelURL = cache.modelURL
        compositeImage = cache.compositeImage
        meshComponents = cache.meshComponents
        componentFiles = cache.componentFiles
        preloadedComponentNodes = cache.preloadedNodes
        keepIndices = cache.keepIndices
        deleteIndices = cache.deleteIndices

        // Clear the cache after restoring
        cachedGeneration = nil

        // Navigate to post-process step
        currentStep = .postProcess
        print("[Cache] Restored generation cache for project \(currentProjectId.uuidString.prefix(8))")
    }

    /// Restore cached segmentation state
    /// CRITICAL: Now validates project ownership before restoring and re-initializes SAM
    func restoreCachedSegmentation() {
        guard let cache = cachedSegmentation else { return }

        // CRITICAL: Validate the cache belongs to the current project
        guard let currentProjectId = projectId, cache.projectId == currentProjectId else {
            print("[Cache] Segmentation cache belongs to different project (cached: \(cache.projectId.uuidString.prefix(8)), current: \(projectId?.uuidString.prefix(8) ?? "nil")), clearing")
            cachedSegmentation = nil
            return
        }

        segmentations = cache.segmentations
        activeSegmentationIndex = cache.activeIndex
        inputImage = cache.inputImage
        inputImagePath = cache.inputImagePath
        imagePixelSize = cache.imagePixelSize

        // Clear the cache after restoring
        cachedSegmentation = nil

        // Navigate to segment step
        currentStep = .segment

        // CRITICAL: Re-initialize SAM with the restored image to prevent stale state
        Task {
            _ = await initializeImageWithoutVLM()
        }

        print("[Cache] Restored segmentation cache for project \(currentProjectId.uuidString.prefix(8))")
    }

    /// Clear all caches (called on explicit "Start Over")
    func clearAllCaches() {
        cachedGeneration = nil
        cachedSegmentation = nil
    }
}
