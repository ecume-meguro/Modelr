import SwiftUI
import SceneKit

// MARK: - Cache Types and Management
extension SimpleEditorViewModel {

    // MARK: - Cache Restore Methods

    /// Restore cached generation state (after navigating back from post-process)
    func restoreCachedGeneration() {
        guard let cache = cachedGeneration else { return }

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
    }

    /// Restore cached segmentation state
    func restoreCachedSegmentation() {
        guard let cache = cachedSegmentation else { return }

        segmentations = cache.segmentations
        activeSegmentationIndex = cache.activeIndex
        inputImage = cache.inputImage
        inputImagePath = cache.inputImagePath
        imagePixelSize = cache.imagePixelSize

        // Clear the cache after restoring
        cachedSegmentation = nil

        // Navigate to segment step
        currentStep = .segment
    }

    /// Clear all caches (called on explicit "Start Over")
    func clearAllCaches() {
        cachedGeneration = nil
        cachedSegmentation = nil
    }
}
