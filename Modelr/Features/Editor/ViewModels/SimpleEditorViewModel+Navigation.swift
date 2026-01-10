import os.log
import SwiftUI

// MARK: - Navigation
extension SimpleEditorViewModel {

    /// Find the previous step that was actually visited (respects user's actual navigation path)
    /// This ensures "back" goes to where the user was, not just the previous sequential step.
    /// For example, if user went Segment -> PostProcess via "Restore", back should go to Segment,
    /// not Generate (which was skipped).
    func previousVisitedStep(from step: Step) -> Step? {
        var candidate = step.previous
        while let c = candidate {
            // Skip the generate step when coming from postProcess - it's a transient processing step
            // Users should go back to settings to adjust and regenerate, not to the generate step
            if step == .postProcess && c == .generate {
                candidate = c.previous
                continue
            }

            // Only return steps that were actually visited
            if visitedSteps.contains(c) {
                return c
            }
            candidate = c.previous
        }
        return nil
    }

    /// Navigate back one step, cleaning up state appropriately
    /// - Parameter force: If true, skip confirmation dialogs
    func goBack(force: Bool = false) {
        guard let targetStep = previousVisitedStep(from: currentStep) else {
            return  // Can't go back from setup
        }

        // Cancel any pending tasks that would update the current step's state
        cancelPendingTasks(for: currentStep)

        // Clean up state for the current step BEFORE transitioning (synchronous)
        cleanupStateForStep(currentStep, targetStep: targetStep)

        // Remove current step from visited (going back means we left it)
        visitedSteps.remove(currentStep)

        // Animate step change
        withStandardSpring {
            currentStep = targetStep
        }
    }

    /// Cancel pending tasks for a specific step
    func cancelPendingTasks(for step: Step) {
        switch step {
        case .setup:
            // Cancel setup-related tasks if any
            break
        case .input:
            imageLoadTask?.cancel()
            imageLoadTask = nil
        case .segment:
            segmentationTask?.cancel()
            segmentationTask = nil
        case .touchup:
            // No long-running tasks in touchup
            break
        case .generateSettings:
            // No long-running tasks in settings
            break
        case .generate:
            generationTask?.cancel()
            generationTask = nil
            if isGenerating {
                stopGeneration()
            }
        case .postProcess:
            meshPreloadTask?.cancel()
            meshPreloadTask = nil
        }
    }

    /// Clean up state when leaving a step (called BEFORE transition)
    /// - Parameters:
    ///   - step: The current step being left
    ///   - targetStep: The step we're navigating to (for context-aware cleanup)
    func cleanupStateForStep(_ step: Step, targetStep: Step) {
        switch step {
        case .setup:
            break
        case .input:
            // Going back to setup - this shouldn't happen normally
            break
        case .segment:
            // Cache segmentation state before clearing
            if !segmentations.isEmpty {
                cachedSegmentation = SegmentationCache(
                    segmentations: segmentations,
                    activeIndex: activeSegmentationIndex,
                    inputImage: inputImage,
                    inputImagePath: inputImagePath,
                    imagePixelSize: imagePixelSize
                )
            }
            // Going back to input - clear segmentation state
            segmentations.removeAll()
            inputImage = nil
            inputImagePath = nil
            imagePixelSize = .zero
            imageHasAlpha = false
            useExistingAlpha = false
            isImageInitializedWithSAM = false
            // Clear preloaded mask
            preloadManager.clearPreloadedMask()
        case .touchup:
            // Going back to segment - clear touchup edits but keep segmentation
            editableMaskImage = nil
            maskHistory.removeAll()
            brushPreviewPosition = nil
            isStrokeInProgress = false
            hasMaskEdits = false
            // Clear preloaded composite
            preloadManager.clearPreloadedComposite()
        case .generateSettings:
            // Going back - clear composite since settings may change
            compositeImage = nil
        case .generate:
            // Clear generation state when going back
            // Keep compositeImage if going back to generateSettings (so user sees their preview)
            if targetStep != .generateSettings {
                compositeImage = nil
            }
            generated3DModelURL = nil
            generationStages = [:]
            generationStatus = ""
            generationStartTime = nil
            generationDuration = nil
            isGenerating = false
            // Reset download monitoring
            resetDownloadMonitoringState()
        case .postProcess:
            // Cache generation/post-process state before clearing
            if let modelURL = generated3DModelURL {
                cachedGeneration = GenerationCache(
                    modelURL: modelURL,
                    compositeImage: compositeImage,
                    meshComponents: meshComponents,
                    componentFiles: componentFiles,
                    preloadedNodes: preloadedComponentNodes,
                    keepIndices: keepIndices,
                    deleteIndices: deleteIndices
                )
            }
            // Clear post-process state
            meshComponents.removeAll()
            keepIndices.removeAll()
            deleteIndices.removeAll()
            highlightedComponentIndex = nil
            hoveredComponentIndex = nil
            isolatedComponentIndex = nil
            processedModelURL = nil
            componentFiles.removeAll()
            preloadedComponentNodes.removeAll()
            meshDisplayMode = .solid
            customModelColor = nil
            // Clean up temp mesh component files
            cleanupMeshComponentsTempDirectory()

            // Clear generation state (model is cached for restoration)
            // Keep compositeImage when going to generateSettings so user sees preview
            generated3DModelURL = nil
            generationStages = [:]
            generationStatus = ""
            generationStartTime = nil
            generationDuration = nil
        }
    }

    /// Clear all state and return to input step
    func clearAll() {
        // Cancel ALL pending tasks first
        cancelAllTasks()

        // Clear all state synchronously BEFORE animation
        resetAllState()

        // Clear all caches (user is starting over)
        clearAllCaches()

        // Animate to input
        withStandardSpring {
            currentStep = .input
        }
    }

    /// Cancel all pending tasks across all steps
    func cancelAllTasks() {
        imageLoadTask?.cancel()
        imageLoadTask = nil
        segmentationTask?.cancel()
        segmentationTask = nil
        generationTask?.cancel()
        generationTask = nil
        cleanupTask?.cancel()
        cleanupTask = nil
        meshPreloadTask?.cancel()
        meshPreloadTask = nil
        autoDetectionTask?.cancel()
        autoDetectionTask = nil

        // Clear all preloaded data
        preloadManager.cancelAll()

        // Stop generation if in progress
        if isGenerating {
            stopGeneration()
        }
    }

    /// Reset all state to initial values
    func resetAllState() {
        // Input state
        inputImage = nil
        inputImagePath = nil
        imagePixelSize = .zero
        imageHasAlpha = false
        isImageInitializedWithSAM = false
        isInitializingProject = false
        initializationStatus = ""

        // VLM auto-detection state
        isAutoDetecting = false
        autoDetectedLabel = nil

        // Segmentation state
        segmentations.removeAll()
        activeSegmentationIndex = 0
        useExistingAlpha = false

        // Touchup state
        editableMaskImage = nil
        maskHistory.removeAll()
        brushPreviewPosition = nil
        isStrokeInProgress = false
        hasMaskEdits = false

        // Generation state
        compositeImage = nil
        generated3DModelURL = nil
        generationStages = [:]
        generationStatus = ""
        generationStartTime = nil
        generationDuration = nil
        isGenerating = false

        // Post-process state
        meshComponents.removeAll()
        keepIndices.removeAll()
        deleteIndices.removeAll()
        highlightedComponentIndex = nil
        isolatedComponentIndex = nil
        processedModelURL = nil
        componentFiles.removeAll()
        preloadedComponentNodes.removeAll()
        meshDisplayMode = .solid
        customModelColor = nil
        // Clean up temp mesh component files
        cleanupMeshComponentsTempDirectory()

        // UI state
        zoomScale = 1.0
        panOffset = .zero
        panBase = .zero
        showingOriginal = false

        // Download state
        resetDownloadMonitoringState()

        // Error state
        lastError = nil
        showErrorAlert = false

        // Navigation state
        visitedSteps = [.setup, .input]
    }

    /// Reset download monitoring state
    func resetDownloadMonitoringState() {
        downloadedBytes = 0
        downloadTotalBytes = 0
        downloadSpeed = 0
        downloadTimeRemaining = 0
        pinnedDownloadTotalBytes = nil
        didQueryCurrentDownloadTotal = false
        isUsingHuggingFaceDownloadProgress = false
        downloadMonitor.stopMonitoring()
    }

    /// Get the display name for the back button based on actual navigation target
    var backButtonLabel: String {
        guard let target = previousVisitedStep(from: currentStep) else {
            return "Back"
        }
        switch target {
        case .setup: return "Back to Setup"
        case .input: return "Back to Input"
        case .segment: return "Back to Segment"
        case .touchup: return "Back to Touchup"
        case .generateSettings: return "Back to Settings"
        case .generate: return "Back to Generate"
        case .postProcess: return "Back"
        }
    }
}
