import SwiftUI
import Foundation
import Combine
import SceneKit
import ModelIO
import SceneKit.ModelIO

/// ViewModel for ContentViewSimple - manages all state and business logic
@MainActor
class SimpleEditorViewModel: BaseEditorViewModel {
    // MARK: - Subscriptions
    var cancellables = Set<AnyCancellable>()

    // MARK: - Preload Manager
    let preloadManager = PreloadManager.shared

    // MARK: - Task Management (for proper cancellation)
    var imageLoadTask: Task<Void, Never>?
    var segmentationTask: Task<Void, Never>?
    var generationTask: Task<Void, Never>?
    var cleanupTask: Task<Void, Never>?

    // MARK: - Workflow State
    enum Step: Int, CaseIterable, Comparable {
        case setup = 0
        case input = 1
        case segment = 2
        case touchup = 3
        case generateSettings = 4
        case generate = 5
        case postProcess = 6

        static func < (lhs: Step, rhs: Step) -> Bool {
            lhs.rawValue < rhs.rawValue
        }

        /// Previous step in the workflow (nil for setup)
        var previous: Step? {
            guard rawValue > 0 else { return nil }
            return Step(rawValue: rawValue - 1)
        }

        /// Whether this step is optional (can be skipped)
        var isOptional: Bool {
            switch self {
            case .touchup, .generateSettings: return true
            default: return false
            }
        }

        /// Check if transitioning from this step loses important work
        var hasSignificantState: Bool {
            switch self {
            case .setup, .input: return false
            case .segment: return true  // Has segmentation masks
            case .touchup: return true  // Has edited mask
            case .generateSettings: return false // Just settings, no state
            case .generate: return true // Has 3D model
            case .postProcess: return true // Has post-process edits
            }
        }
    }
    @Published var currentStep: Step = .setup {
        didSet {
            // Track visited steps when moving forward
            if currentStep.rawValue > oldValue.rawValue {
                visitedSteps.insert(currentStep)
            }
        }
    }

    /// Tracks which steps the user has actually visited (for proper back navigation)
    @Published var visitedSteps: Set<Step> = [.setup]

    // MARK: - Error State
    @Published var lastError: AppError?
    @Published var showErrorAlert: Bool = false

    // MARK: - Setup State
    enum SetupSubStep: String, CaseIterable {
        case chooseModel = "Choose Model"
        case configuringSegmentation = "Configuring Segmentation Environment"
        case downloadingSegmentation = "Downloading Segmentation Model"
        case configuringGeneration = "Configuring 3D Generation Environment"
        case downloadingGeneration = "Downloading 3D Generation Model"
        case configuringPostProcess = "Configuring Post-Process Environment"
    }
    @Published var currentSetupSubStep: SetupSubStep = .chooseModel
    @Published var currentSetupStage: SetupStage = .preparing
    @Published var setupProgress: Double = 0
    @Published var setupStatus: String = ""
    @Published var setupConsoleOutput: [SetupSubStep: [String]] = [:]
    @Published var setupSubStepCompleted: Set<SetupSubStep> = []
    @Published var selectedModelChoice: SetupModelChoice = .fast
    @Published var isSetupComplete: Bool = false

    // Download progress tracking
    @Published var downloadedBytes: Int64 = 0
    @Published var downloadTotalBytes: Int64 = 0
    @Published var downloadSpeed: Double = 0  // bytes per second (smoothed)
    @Published var downloadTimeRemaining: TimeInterval = 0
    /// If set, we prefer this total over any parsed tqdm totals.
    var pinnedDownloadTotalBytes: Int64? = nil
    /// Avoid re-querying HF repeatedly while a stage is active.
    var didQueryCurrentDownloadTotal: Bool = false
    var downloadStartTime: Date?
    var lastDownloadBytes: Int64 = 0
    var lastSpeedUpdateTime: Date?
    var speedHistory: [Double] = []  // For moving average
    var lastValidSpeed: Double = 0   // Keep last valid speed when no change

    // Prefer HF/tqdm-reported byte totals when available.
    var isUsingHuggingFaceDownloadProgress: Bool = false

    let downloadMonitor = DownloadMonitor()

    var formattedDownloadProgress: String {
        let downloaded = ByteCountFormatter.string(fromByteCount: downloadedBytes, countStyle: .file)
        let total = ByteCountFormatter.string(fromByteCount: downloadTotalBytes, countStyle: .file)
        return "\(downloaded) / \(total)"
    }

    var formattedDownloadSpeed: String {
        guard downloadSpeed > 1024 else { return "—" }
        return ByteCountFormatter.string(fromByteCount: Int64(downloadSpeed), countStyle: .file) + "/s"
    }

    var formattedTimeRemaining: String {
        guard downloadTimeRemaining > 0 && downloadTimeRemaining < 86400 else { return "" }
        let minutes = Int(downloadTimeRemaining) / 60
        let seconds = Int(downloadTimeRemaining) % 60
        let timeStr = minutes > 0 ? "\(minutes)m \(seconds)s" : "\(seconds)s"
        return "\(timeStr) remaining"
    }

    // MARK: - VLM Auto-Detection State
    @Published var isAutoDetecting: Bool = false
    @Published var autoDetectedLabel: String?
    var autoDetectionTask: Task<Void, Never>?

    // MARK: - Multi-Segmentation State
    @Published var segmentations: [SegmentationEntry] = []
    @Published var activeSegmentationIndex: Int = 0
    @Published var useExistingAlpha: Bool = false
    @Published var imageHasAlpha: Bool = false
    @Published var currentDrawingBox: SAMBox? = nil  // Box being drawn

    /// Currently active segmentation entry
    var activeSegmentation: SegmentationEntry? {
        guard activeSegmentationIndex < segmentations.count else { return nil }
        return segmentations[activeSegmentationIndex]
    }

    /// Check if any segmentation is currently processing
    var isAnySegmenting: Bool {
        segmentations.contains { $0.isProcessing }
    }

    /// Total number of valid masks across all segmentations
    var totalValidMasks: Int {
        segmentations.filter { $0.hasValidMask }.count
    }

    // MARK: - Touchup State
    enum BrushMode { case add, remove }
    @Published var brushMode: BrushMode = .add
    @Published var brushSize: CGFloat = 30
    @Published var editableMaskImage: NSImage?
    @Published var brushPreviewPosition: CGPoint? = nil
    @Published var maskHistory: [NSImage] = []
    @Published var isStrokeInProgress: Bool = false
    @Published var currentStroke: PaintStroke? = nil  // Live stroke for visual feedback
    @Published var hasMaskEdits: Bool = false  // True if user actually edited the mask
    var lastBrushPoint: CGPoint? = nil  // For stroke interpolation

    // MARK: - Generation State
    @Published var generationStatus = ""
    @Published var compositeImage: NSImage?
    @Published var generationDuration: TimeInterval?
    @Published var selectedPreset: QualityPreset = .normal
    @Published var showAdvancedSettings = false
    @Published var customSteps: CGFloat = 10   // matches turboNormal preset
    @Published var customResolution: CGFloat = 256
    @Published var generationStages: [GenerationStage: StageProgress] = [:]
    @Published var isLargeModelDownloaded: Bool = false
    @Published var isSmallModelDownloaded: Bool = false
    /// Tracks the step user was on before starting generation (for returning on cancel/stop)
    var stepBeforeGeneration: Step?

    // MARK: - Warning Dialogs
    @Published var showBackWarning: Bool = false
    @Published var showDiscardModelWarning: Bool = false
    @Published var showDiscardImageWarning: Bool = false
    @Published var showStartOverWarning: Bool = false

    // MARK: - Post-Process State
    @Published var meshComponents: [MeshComponent] = []
    @Published var keepIndices: Set<Int> = []        // Components to keep (solid clay)
    @Published var deleteIndices: Set<Int> = []      // Components to delete (ghost/translucent)
    @Published var highlightedComponentIndex: Int? = nil  // Currently highlighted (rim glow in viewer)
    @Published var hoveredComponentIndex: Int? = nil      // Currently hovered via viewport raycasting
    @Published var isolatedComponentIndex: Int? = nil     // Show only this component (nil = show all)
    @Published var isAnalyzingMesh: Bool = false
    @Published var isExtractingComponents: Bool = false
    @Published var isProcessingMesh: Bool = false
    @Published var processedModelURL: URL?
    @Published var selectedExportFormat: ExportFormat = .obj
    @Published var componentFiles: [ComponentFile] = []

    /// Pre-loaded SceneKit nodes for instant post-process rendering (keyed by component index)
    @Published var preloadedComponentNodes: [Int: SCNNode] = [:]
    @Published var isPreloadingScenes: Bool = false

    // Post-process display options
    enum MeshDisplayMode: String, CaseIterable {
        case solid = "Solid"
        case wireframe = "Wireframe"
    }
    @Published var meshDisplayMode: MeshDisplayMode = .solid
    /// Custom model color (user paint selection) - nil means use default coloring
    @Published var customModelColor: NSColor? = nil

    // Post-process confirmations
    @Published var showApplyChangesConfirmation: Bool = false

    // Pre-loading task for instant post-process transition
    var meshPreloadTask: Task<Void, Never>?

    // MARK: - Workflow State Cache (for non-destructive navigation)

    /// Cached generation state for restoring when navigating back
    struct GenerationCache {
        let modelURL: URL
        let compositeImage: NSImage?
        let meshComponents: [MeshComponent]
        let componentFiles: [ComponentFile]
        let preloadedNodes: [Int: SCNNode]
        let keepIndices: Set<Int>
        let deleteIndices: Set<Int>
    }

    /// Cached segmentation state for restoring when navigating back
    struct SegmentationCache {
        let segmentations: [SegmentationEntry]
        let activeIndex: Int
        let inputImage: NSImage?
        let inputImagePath: String?
        let imagePixelSize: CGSize
    }

    /// Cached generation results (preserved when navigating back from post-process)
    @Published var cachedGeneration: GenerationCache? = nil

    /// Cached segmentation results (preserved when navigating back from segment)
    @Published var cachedSegmentation: SegmentationCache? = nil

    /// Whether there's a cached generation that can be restored
    var hasCachedGeneration: Bool { cachedGeneration != nil }

    /// Whether there's a cached segmentation that can be restored
    var hasCachedSegmentation: Bool { cachedSegmentation != nil }

    /// Whether we're in the handoff phase (generation complete, preloading for post-process)
    var isInHandoff: Bool {
        generationStages[.handoff]?.status == .inProgress
    }

    // Background environment setup tracking
    @Published var isConfiguringEnvironment: Bool = false

    // Environment refresh tracking (for app updates)
    @Published var isRefreshingEnvironments: Bool = false
    @Published var environmentRefreshStatus: String = ""

    // MARK: - UI State
    @Published var zoomScale: CGFloat = 1.0
    @Published var panOffset: CGSize = .zero
    var panBase: CGSize = .zero  // Base offset for pan gesture
    @Published var showingOriginal: Bool = false

    // MARK: - 3D View Mode
    enum ViewMode: String, CaseIterable {
        case shaded = "Shaded"
        case wireframe = "Wireframe"
        case textured = "Textured"
    }
    @Published var viewMode: ViewMode = .shaded

    /// Overall generation progress (0.0 to 1.0) based on weighted stages
    var overallGenerationProgress: Double {
        guard isGenerating || generated3DModelURL != nil else { return 0 }

        // Define stage weights (total = 1.0)
        let weights: [GenerationStage: Double] = [
            .downloading: 0.1,  // Only counts if downloading large model
            .extracting: 0.05,
            .loading: 0.15,
            .diffusion: 0.5,
            .volumeDecoding: 0.15,
            .saving: 0.05
        ]

        var progress: Double = 0

        for stage in GenerationStage.allCases {
            guard let stageProgress = generationStages[stage] else { continue }
            let weight = weights[stage] ?? 0

            switch stageProgress.status {
            case .completed:
                progress += weight
            case .inProgress:
                progress += weight * stageProgress.progress
            default:
                break
            }
        }

        return min(progress, 1.0)
    }

    // MARK: - Initialization
    override init(env: PythonEnvironment) {
        super.init(env: env)

        // Log memory management strategy
        let coordinator = ModelLoadingCoordinator.shared
        print("[Memory] System RAM: \(coordinator.formattedSystemRAM)")
        print("[Memory] Loading strategy: \(coordinator.strategy.description)")

        // Check if setup was already completed using marker file ONLY
        // UserDefaults is no longer used - it persists even when app data is deleted
        let wasSetupComplete = PathManager.isSetupComplete

        // Debug logging for setup state
        print("[Setup] Checking setup completion:")
        print("[Setup]   Marker file path: \(PathManager.setupCompletionMarkerPath.path)")
        print("[Setup]   Marker file exists: \(FileManager.default.fileExists(atPath: PathManager.setupCompletionMarkerPath.path))")
        print("[Setup]   isSetupComplete: \(wasSetupComplete)")

        if wasSetupComplete {
            isSetupComplete = true
            setupSubStepCompleted = Set(SetupSubStep.allCases)

            // Check if environments need refreshing due to build update
            if PathManager.needsEnvironmentRefresh {
                print("[Setup] Build changed, need to refresh Python environments")
                currentStep = .setup
                currentSetupSubStep = .configuringSegmentation
                isRefreshingEnvironments = true
                Task {
                    await runEnvironmentRefresh()
                }
            } else {
                currentStep = .input
                // Mark Python environment ready for generation
                env.markHunyuanReady()
                print("[Setup] Setup already complete, skipping to input step")
            }
        } else {
            currentStep = .setup
            // Clear any stale UserDefaults value
            UserDefaults.standard.removeObject(forKey: "SetupComplete")
            print("[Setup] Setup required, starting setup flow")
        }

        checkModelsDownloaded()
        setupGenerationObservation()
    }

    /// Check if models are downloaded
    func checkModelsDownloaded() {
        isLargeModelDownloaded = PathManager.isHunyuanModelDownloaded(variant: "std")
        isSmallModelDownloaded = PathManager.isHunyuanModelDownloaded(variant: "mini")

        print("[Setup] Model status - Small: \(isSmallModelDownloaded), Large: \(isLargeModelDownloaded)")
    }

    // MARK: - Image Loading
    func loadImage(from url: URL) {
        // Cancel any previous load task
        imageLoadTask?.cancel()

        imageLoadTask = Task { [weak self] in
            guard let self = self else { return }

            do {
                // Check for cancellation before starting
                try Task.checkCancellation()

                let image = try await self.loadInputImage(from: url)

                // Check for cancellation after loading
                try Task.checkCancellation()

                // Reset state for new image (synchronous, no race condition)
                self.segmentations.removeAll()
                self.addSegmentation()
                self.editableMaskImage = nil
                self.maskHistory.removeAll()
                self.brushPreviewPosition = nil
                self.compositeImage = nil
                self.generated3DModelURL = nil
                self.generationStages = [:]
                self.generationStatus = ""
                self.zoomScale = 1.0
                self.panOffset = .zero
                self.panBase = .zero
                self.useExistingAlpha = false
                self.lastError = nil

                self.imageHasAlpha = ImageService.shared.checkImageHasAlpha(image)

                withAnimation(.easeOut(duration: 0.25)) {
                    self.currentStep = .segment
                }

                // Initialize with Python backend
                try Task.checkCancellation()
                await self.initializeImage()

            } catch is CancellationError {
                // Task was cancelled, silently ignore
                print("[Load] Image load cancelled")
            } catch {
                print("[Load] Failed to load image: \(error)")
                // Show error to user
                self.lastError = AppError.imageProcessing(error.localizedDescription)
                self.showErrorAlert = true
            }
        }
    }

    func checkImageHasAlpha() {
        guard let image = inputImage else { return }
        imageHasAlpha = ImageService.shared.checkImageHasAlpha(image)
    }

    private func initializeImage() async {
        guard let path = inputImagePath else { return }
        do {
            let size = try await env.setImage(path: path)
            imagePixelSize = size

            // Trigger VLM auto-detection in background
            await startVLMAutoDetection(imagePath: path)
        } catch {
            print("[Init] Failed to set image: \(error)")
        }
    }

    /// Start VLM auto-detection to identify the object in the image
    private func startVLMAutoDetection(imagePath: String) async {
        // Cancel any previous detection
        autoDetectionTask?.cancel()

        autoDetectionTask = Task { [weak self] in
            guard let self = self else { return }

            await MainActor.run {
                self.isAutoDetecting = true
                self.autoDetectedLabel = nil
            }

            let coordinator = ModelLoadingCoordinator.shared

            // Wait for VLM to be ready if it's still starting
            if coordinator.isStartingVLM {
                print("[VLM] Waiting for VLM server to start...")
                while coordinator.isStartingVLM {
                    try? await Task.sleep(nanoseconds: 100_000_000)  // 100ms
                    if Task.isCancelled { return }
                }
            }

            // Ensure VLM is ready
            guard coordinator.isVLMReady else {
                print("[VLM] VLM server not ready, skipping auto-detection")
                await MainActor.run {
                    self.isAutoDetecting = false
                }
                return
            }

            do {
                try Task.checkCancellation()

                print("[VLM] Starting auto-detection for: \(imagePath)")
                let description = try await coordinator.describeImage(imagePath: imagePath)

                try Task.checkCancellation()

                await MainActor.run {
                    self.autoDetectedLabel = description
                    self.isAutoDetecting = false

                    // Auto-fill the text prompt for the active segmentation
                    if self.activeSegmentationIndex < self.segmentations.count {
                        self.segmentations[self.activeSegmentationIndex].textPrompt = description
                        print("[VLM] Auto-detected object: '\(description)' - filled text prompt")

                        // Automatically run SAM text prediction
                        print("[VLM] Auto-triggering SAM text prediction...")
                        self.runTextPrediction()
                    }
                }
            } catch is CancellationError {
                print("[VLM] Auto-detection cancelled")
            } catch {
                print("[VLM] Auto-detection failed: \(error)")
                await MainActor.run {
                    self.isAutoDetecting = false
                }
            }
        }
    }

    /// Manually trigger VLM auto-detection (for re-detection button)
    func triggerAutoDetection() {
        guard let path = inputImagePath else { return }
        Task {
            await startVLMAutoDetection(imagePath: path)
        }
    }

    /// Cancel ongoing VLM auto-detection
    func cancelAutoDetection() {
        autoDetectionTask?.cancel()
        autoDetectionTask = nil
        isAutoDetecting = false
        print("[VLM] Auto-detection cancelled by user")
    }

    // MARK: - Navigation

    /// Find the previous step that was actually visited (respects user's actual navigation path)
    /// This ensures "back" goes to where the user was, not just the previous sequential step.
    /// For example, if user went Segment → PostProcess via "Restore", back should go to Segment,
    /// not Generate (which was skipped).
    func previousVisitedStep(from step: Step) -> Step? {
        var candidate = step.previous
        while let c = candidate {
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
        withAnimation(.spring(response: 0.25, dampingFraction: 0.85)) {
            currentStep = targetStep
        }
    }

    /// Cancel pending tasks for a specific step
    private func cancelPendingTasks(for step: Step) {
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
    private func cleanupStateForStep(_ step: Step, targetStep: Step) {
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
            compositeImage = nil
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

            // If going back to generate step, keep the model so user can see it
            // Otherwise clear it (going further back means starting fresh)
            if targetStep != .generate {
                generated3DModelURL = nil
                generationStages = [:]
                generationStatus = ""
                generationStartTime = nil
                generationDuration = nil
            }
        }
    }

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

    /// Reset download monitoring state
    private func resetDownloadMonitoringState() {
        downloadedBytes = 0
        downloadTotalBytes = 0
        downloadSpeed = 0
        downloadTimeRemaining = 0
        pinnedDownloadTotalBytes = nil
        didQueryCurrentDownloadTotal = false
        isUsingHuggingFaceDownloadProgress = false
        downloadMonitor.stopMonitoring()
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
        withAnimation(.spring(response: 0.25, dampingFraction: 0.85)) {
            currentStep = .input
        }
    }

    /// Cancel all pending tasks across all steps
    private func cancelAllTasks() {
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
    private func resetAllState() {
        // Input state
        inputImage = nil
        inputImagePath = nil
        imagePixelSize = .zero
        imageHasAlpha = false

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

    // MARK: - Utilities
    func colorForMask(_ index: Int) -> Color {
        AppDesign.neonColors[index % AppDesign.neonColors.count]
    }

    func colorForSegmentation(_ index: Int) -> Color {
        AppDesign.neonColors[index % AppDesign.neonColors.count]
    }

    func stageTextColor(_ status: StageStatus) -> Color {
        switch status {
        case .completed: return AppDesign.success
        case .inProgress: return .primary
        case .pending: return .secondary
        case .cancelled: return AppDesign.warning
        case .failed: return AppDesign.destructive
        }
    }

    func formatDuration(_ duration: TimeInterval) -> String {
        TimeFormatter.formatDuration(duration)
    }

    func fitSize(_ imageSize: CGSize, in containerSize: CGSize) -> CGSize {
        guard imageSize.width > 0 && imageSize.height > 0 && containerSize.width > 0 && containerSize.height > 0 else {
            return .zero
        }

        let imageAspect = imageSize.width / imageSize.height
        let containerAspect = containerSize.width / containerSize.height
        let margin: CGFloat = containerSize.width < 600 ? 0.95 : 0.9

        if imageAspect > containerAspect {
            let width = containerSize.width * margin
            return CGSize(width: width, height: width / imageAspect)
        } else {
            let height = containerSize.height * margin
            return CGSize(width: height * imageAspect, height: height)
        }
    }
}
