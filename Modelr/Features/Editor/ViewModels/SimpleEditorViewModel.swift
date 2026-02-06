import os.log
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
        case modify = 7

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
            case .touchup, .modify: return true  // Touchup and modify are optional
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
            case .modify: return true // Has modified mesh
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

    /// Standardized error handling method
    /// - Parameters:
    ///   - error: The error to handle (can be AppError or any Error)
    ///   - userFacing: If true, shows alert to user; if false, only logs
    func handleError(_ error: Error, userFacing: Bool = true) {
        // Convert to AppError if needed
        let appError: AppError
        if let err = error as? AppError {
            appError = err
        } else {
            appError = .system(error)
        }

        // Always log the technical error for debugging
        ErrorReporter.error(appError.localizedDescription, subsystem: .general)

        // Show user-friendly alert to user if requested
        if userFacing {
            Task { @MainActor in
                self.lastError = appError
                self.showErrorAlert = true
            }
        }
    }

    /// Get user-friendly error message for display
    var userFriendlyErrorMessage: String? {
        lastError?.userFriendlyDescription
    }

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

    // MARK: - Image Initialization State
    /// Whether the current image has been successfully initialized with SAM backend
    @Published var isImageInitializedWithSAM: Bool = false
    /// Whether project initialization is in progress (shows loading overlay)
    @Published var isInitializingProject: Bool = false
    /// Status message during project initialization
    @Published var initializationStatus: String = ""

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
    @Published var selectedPreset: GenerationPreset = SettingsManager.shared.defaultPreset
    @Published var showAdvancedSettings = false

    // Hunyuan custom settings
    @Published var customSteps: CGFloat = 35
    @Published var customResolution: CGFloat = 256
    @Published var customGuidanceScaleHunyuan: CGFloat = 5.0
    @Published var customBoxV: CGFloat = 1.01
    @Published var customMcLevel: CGFloat = 0.0
    @Published var customMeshReduction: CGFloat = 50.0  // QEM mesh reduction percentage (0-90)
    @Published var generationStages: [GenerationStage: StageProgress] = [:]
    @Published var generationSetupLogs: [String] = []
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
    /// Tracks the temp directory for mesh components (for cleanup)
    var meshComponentsTempDirectory: URL?

    // MARK: - Modify State (Step 7)
    @Published var modifyType: ModifyType = .none
    @Published var voxelResolution: CGFloat = 0  // 0 = no change, 0.5-10.0 = voxel pitch
    @Published var lowPolyReduction: CGFloat = 0  // 0 = no change, 1-99 = % reduction
    @Published var modifiedModelURL: URL?
    @Published var isModifyingMesh: Bool = false
    @Published var originalFaceCount: Int = 0  // Original mesh face count
    @Published var modifiedFaceCount: Int = 0  // Modified mesh face count

    enum ModifyType: String, CaseIterable {
        case none = "None"
        case voxelize = "Voxelize"
        case lowPoly = "Low Poly"
    }

    /// Pre-loaded SceneKit nodes for instant post-process rendering (keyed by component index)
    @Published var preloadedComponentNodes: [Int: SCNNode] = [:]
    @Published var isPreloadingScenes: Bool = false

    // Post-process display options
    enum MeshDisplayMode: String, CaseIterable {
        case solid = "Solid"
        case wireframe = "Wireframe"
    }
    @Published var meshDisplayMode: MeshDisplayMode = .solid

    /// Material type for 3D model rendering
    enum MaterialType: String, CaseIterable, Identifiable {
        case matte = "Matte"
        case glossy = "Glossy"
        case metallic = "Metallic"

        var id: String { rawValue }

        var icon: String {
            switch self {
            case .matte: return "circle.fill"
            case .glossy: return "sparkles"
            case .metallic: return "diamond.fill"
            }
        }

        var roughness: CGFloat {
            switch self {
            case .matte: return 0.8
            case .glossy: return 0.1
            case .metallic: return 0.2
            }
        }

        var metalness: CGFloat {
            switch self {
            case .matte: return 0.0
            case .glossy: return 0.0
            case .metallic: return 1.0
            }
        }

        var transparency: CGFloat {
            return 1.0  // All materials are opaque
        }
    }
    @Published var materialType: MaterialType = .matte

    /// Custom model color (user paint selection) - nil means use default coloring
    @Published var customModelColor: NSColor? = nil {
        didSet {
            // CRITICAL: Invalidate preloaded nodes - they have baked-in color
            preloadedComponentNodes.removeAll()

            // Save to metadata when user manually changes color
            if let color = customModelColor, let projectId = projectId {
                handleCustomModelColorChange(color: color, projectId: projectId)
            }
        }
    }

    /// Task for saving custom model color (tracked for proper cancellation)
    private var colorSaveTask: Task<Void, Never>?

    /// Handle custom model color change - saves to metadata asynchronously
    private func handleCustomModelColorChange(color: NSColor, projectId: UUID) {
        // Cancel any pending color save task
        colorSaveTask?.cancel()

        let hexColor = ColorExtractionService.shared.toHexString(color)
        colorSaveTask = Task { [weak self] in
            guard let self = self else { return }
            do {
                try Task.checkCancellation()
                await self.saveColorToMetadata(projectId: projectId, hexColor: hexColor)
            } catch is CancellationError {
                // Task cancelled, ignore
            } catch {
                self.handleError(error, userFacing: false)
            }
        }
    }

    // Post-process confirmations
    @Published var showApplyChangesConfirmation: Bool = false

    // Pre-loading task for instant post-process transition
    var meshPreloadTask: Task<Void, Never>?

    // MARK: - Workflow State Cache (for non-destructive navigation)

    /// Cached generation state for restoring when navigating back
    /// CRITICAL: Now includes projectId to prevent cross-project restoration
    struct GenerationCache {
        let projectId: UUID  // Track which project this cache belongs to
        let modelURL: URL
        let compositeImage: NSImage?
        let meshComponents: [MeshComponent]
        let componentFiles: [ComponentFile]
        let preloadedNodes: [Int: SCNNode]
        let keepIndices: Set<Int>
        let deleteIndices: Set<Int>
    }

    /// Cached segmentation state for restoring when navigating back
    /// CRITICAL: Now includes projectId to prevent cross-project restoration
    struct SegmentationCache {
        let projectId: UUID  // Track which project this cache belongs to
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

    /// Time estimate for current generation settings, shown in sidebar
    var currentGenerationTimeEstimate: String {
        return selectedPreset.estimatedTime
    }

    // MARK: - Singleton State Management

    /// Clear all global singleton state to prevent cross-project contamination
    /// Call this when explicitly switching projects or on critical transitions
    static func clearGlobalSingletonState() {
        PreloadManager.shared.cancelAll()
        ErrorReporter.debug("Cleared all global singleton state", subsystem: .general)
    }

    // MARK: - Initialization
    override init(env: PythonEnvironment, projectId: UUID? = nil) {
        super.init(env: env, projectId: projectId)

        // CRITICAL: Clear any cached data from previous project
        // PreloadManager is a singleton that retains masks/composites across projects
        preloadManager.clearPreloadedMask()
        preloadManager.clearPreloadedComposite()

        // Clear setup console output from previous projects
        setupConsoleOutput.removeAll()

        ErrorReporter.debug("Cleared singleton state for new project: \(projectId?.uuidString ?? "nil")", subsystem: .general)

        // Log memory management strategy
        let coordinator = ModelLoadingCoordinator.shared
        ErrorReporter.info("System RAM: \(coordinator.formattedSystemRAM)", subsystem: .general)
        ErrorReporter.info("Loading strategy: \(coordinator.strategy.description)", subsystem: .general)

        // Check if setup was already completed using marker file ONLY
        // UserDefaults is no longer used - it persists even when app data is deleted
        let wasSetupComplete = PathManager.isSetupComplete

        // Debug logging for setup state
        ErrorReporter.debug("Checking setup completion:", subsystem: .setup)
        ErrorReporter.debug("  Marker file path: \(PathManager.setupCompletionMarkerPath.path)", subsystem: .setup)
        ErrorReporter.debug("  Marker file exists: \(FileManager.default.fileExists(atPath: PathManager.setupCompletionMarkerPath.path))", subsystem: .setup)
        ErrorReporter.debug("  isSetupComplete: \(wasSetupComplete)", subsystem: .setup)

        if wasSetupComplete {
            isSetupComplete = true
            setupSubStepCompleted = Set(SetupSubStep.allCases)

            // Check if environments need refreshing due to build update
            if PathManager.needsEnvironmentRefresh {
                ErrorReporter.info("Build changed, need to refresh Python environments", subsystem: .setup)
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
                ErrorReporter.debug("Setup already complete, skipping to input step", subsystem: .setup)
            }
        } else {
            currentStep = .setup
            // Clear any stale UserDefaults value
            UserDefaults.standard.removeObject(forKey: "SetupComplete")
            ErrorReporter.debug("Setup required, starting setup flow", subsystem: .setup)
        }

        checkModelsDownloaded()
        setupGenerationObservation()
    }

    deinit {
        // Cancel all pending tasks
        imageLoadTask?.cancel()
        segmentationTask?.cancel()
        generationTask?.cancel()
        cleanupTask?.cancel()
        autoDetectionTask?.cancel()
        meshPreloadTask?.cancel()
        colorSaveTask?.cancel()

        // Cancel associated object tasks (handoffTask, meshProcessorTimeoutTask)
        // These are stored via objc_setAssociatedObject in extensions
        // Access them directly using nonisolated helper to avoid MainActor isolation issues in deinit
        cancelAssociatedTasks()

        // Clean up temp directories on background thread
        if let tempDir = meshComponentsTempDirectory {
            Task.detached(priority: .utility) {
                try? FileManager.default.removeItem(at: tempDir)
            }
        }

        print("[SimpleEditorViewModel] deinit - cleaned up for project: \(projectId?.uuidString ?? "nil")")
    }

    /// Cancel associated object tasks from deinit (nonisolated for deinit compatibility)
    /// Note: Task.cancel() is thread-safe so this is safe to call from any context
    private nonisolated func cancelAssociatedTasks() {
        // Cancel handoff task (stored in extension via objc_setAssociatedObject)
        if let handoffTask = objc_getAssociatedObject(self, &Self.handoffTaskKeyStorage) as? Task<Void, Never> {
            handoffTask.cancel()
        }
        // Cancel mesh processor timeout task (stored in extension via objc_setAssociatedObject)
        if let timeoutTask = objc_getAssociatedObject(self, &Self.meshProcessorTimeoutTaskKeyStorage) as? Task<Void, Never> {
            timeoutTask.cancel()
        }
    }

    // Storage keys for associated objects (accessible from nonisolated context and extensions)
    nonisolated(unsafe) static var handoffTaskKeyStorage = "handoffTask"
    nonisolated(unsafe) static var meshProcessorTimeoutTaskKeyStorage = "meshProcessorTimeoutTask"

    /// Check if models are downloaded
    func checkModelsDownloaded() {
        isSmallModelDownloaded = PathManager.isHunyuanModelDownloaded(variant: "mini")
        let downloaded = isSmallModelDownloaded
        ErrorReporter.debug("Model status - Mini: \(downloaded)", subsystem: .setup)
    }

    // MARK: - Image Loading
    func loadImage(from url: URL) {
        // Cancel any previous load task
        imageLoadTask?.cancel()

        // Set initialization state SYNCHRONOUSLY before the task starts
        // This prevents race condition where loadProject() checks before task runs
        isImageInitializedWithSAM = false
        isInitializingProject = true
        initializationStatus = "Loading image..."

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

                // Invalidate cached thumbnails when loading new image
                if let projectId = self.projectId {
                    ThumbnailCache.shared.invalidate(projectId: projectId)
                }
                self.generationStatus = ""
                self.zoomScale = 1.0
                self.panOffset = .zero
                self.panBase = .zero
                self.useExistingAlpha = false
                self.lastError = nil

                self.imageHasAlpha = ImageService.shared.checkImageHasAlpha(image)

                // Extract dominant color from image and set as default model color
                if let dominantColor = ColorExtractionService.shared.extractDominantColor(from: image) {
                    self.customModelColor = dominantColor
                    ErrorReporter.debug("Extracted dominant color from image: \(dominantColor)", subsystem: .general)

                    // Save to metadata for persistence
                    let hexColor = ColorExtractionService.shared.toHexString(dominantColor)
                    if let projectId = self.projectId {
                        Task { [weak self] in
                            guard let self = self else { return }
                            do {
                                try Task.checkCancellation()
                                await self.saveColorToMetadata(projectId: projectId, hexColor: hexColor)
                            } catch is CancellationError {
                                // Task cancelled, ignore
                            } catch {
                                self.handleError(error, userFacing: false)
                            }
                        }
                    }
                } else {
                    ErrorReporter.debug("Failed to extract dominant color from image", subsystem: .general)
                }

                // Transition to segment step (loading overlay will show in ProjectEditorView)
                withAnimation(.easeOut(duration: 0.25)) {
                    self.currentStep = .segment
                }

                // Phase 1: Initialize SAM
                try Task.checkCancellation()
                self.initializationStatus = "Preparing segmentation..."
                let samInitSuccess = await self.initializeImageWithoutVLM()

                guard samInitSuccess else {
                    throw AppError.imageProcessing("Failed to initialize segmentation")
                }

                // Phase 2: Run VLM auto-detection and WAIT for it
                try Task.checkCancellation()
                self.initializationStatus = "Analyzing image..."
                let detectedLabel = await self.runVLMDetectionSync()

                // Phase 3: If we got a label, run segmentation
                try Task.checkCancellation()
                if let label = detectedLabel, !label.isEmpty {
                    self.initializationStatus = "Creating mask for \"\(label)\"..."

                    // Set the prompt and run prediction
                    if self.activeSegmentationIndex < self.segmentations.count {
                        self.segmentations[self.activeSegmentationIndex].textPrompt = label
                    }

                    // Run segmentation and wait for it
                    await self.runTextPredictionSync()
                }

                try Task.checkCancellation()

                // Complete initialization
                self.initializationStatus = "Ready"

                // Small delay for smooth transition
                try await Task.sleep(nanoseconds: 300_000_000) // 300ms

                // Hide loading overlay
                withAnimation(.easeOut(duration: 0.3)) {
                    self.isInitializingProject = false
                    self.initializationStatus = ""
                }

            } catch is CancellationError {
                // Task was cancelled, silently ignore
                ErrorReporter.debug("Image load cancelled", subsystem: .general)
                self.isInitializingProject = false
                self.initializationStatus = ""
            } catch {
                ErrorReporter.logError(error, subsystem: .general, context: "Failed to load image")
                // Show error to user
                self.isInitializingProject = false
                self.initializationStatus = ""
                self.lastError = AppError.imageProcessing(error.localizedDescription)
                self.showErrorAlert = true
            }
        }
    }

    /// Load image with saved state from a previous session
    /// Skips VLM detection if prompt is already saved, skips segmentation if mask indices are saved
    func loadImageWithSavedState(from url: URL, savedPrompt: String?, savedMaskIndices: [Int]?) {
        // Cancel any previous load task
        imageLoadTask?.cancel()

        // Set initialization state SYNCHRONOUSLY before the task starts
        isImageInitializedWithSAM = false
        isInitializingProject = true
        initializationStatus = "Loading project..."

        imageLoadTask = Task { [weak self] in
            guard let self = self else { return }

            do {
                try Task.checkCancellation()

                let image = try await self.loadInputImage(from: url)

                try Task.checkCancellation()

                // Reset state for image
                self.segmentations.removeAll()
                self.addSegmentation()
                self.editableMaskImage = nil
                self.maskHistory.removeAll()
                self.brushPreviewPosition = nil
                self.compositeImage = nil
                // Don't reset generated3DModelURL - it will be restored by caller
                self.generationStages = [:]
                self.generationStatus = ""
                self.zoomScale = 1.0
                self.panOffset = .zero
                self.panBase = .zero
                self.useExistingAlpha = false
                self.lastError = nil

                self.imageHasAlpha = ImageService.shared.checkImageHasAlpha(image)

                // Extract dominant color from image and set as default model color
                if let dominantColor = ColorExtractionService.shared.extractDominantColor(from: image) {
                    self.customModelColor = dominantColor
                    ErrorReporter.debug("Extracted dominant color from restored image: \(dominantColor)", subsystem: .general)

                    // Save to metadata for persistence
                    let hexColor = ColorExtractionService.shared.toHexString(dominantColor)
                    if let projectId = self.projectId {
                        Task { [weak self] in
                            guard let self = self else { return }
                            do {
                                try Task.checkCancellation()
                                await self.saveColorToMetadata(projectId: projectId, hexColor: hexColor)
                            } catch is CancellationError {
                                // Task cancelled, ignore
                            } catch {
                                self.handleError(error, userFacing: false)
                            }
                        }
                    }
                } else {
                    ErrorReporter.debug("Failed to extract dominant color from restored image", subsystem: .general)
                    // Try to load from metadata if extraction fails
                    self.loadDominantColorFromMetadata()
                }

                // Transition to segment step
                withAnimation(.easeOut(duration: 0.25)) {
                    self.currentStep = .segment
                }

                // Phase 1: Initialize SAM
                try Task.checkCancellation()
                self.initializationStatus = "Preparing segmentation..."
                let samInitSuccess = await self.initializeImageWithoutVLM()

                guard samInitSuccess else {
                    throw AppError.imageProcessing("Failed to initialize segmentation")
                }

                // Phase 2: Use saved prompt or run VLM
                try Task.checkCancellation()
                let label: String?
                if let prompt = savedPrompt, !prompt.isEmpty {
                    // Use saved prompt - skip VLM
                    self.initializationStatus = "Restoring prompt..."
                    label = prompt
                    self.autoDetectedLabel = prompt
                    ErrorReporter.debug("Using saved prompt: \(prompt)", subsystem: .general)
                } else {
                    // No saved prompt - run VLM detection
                    self.initializationStatus = "Analyzing image..."
                    label = await self.runVLMDetectionSync()
                }

                // Phase 3: Run segmentation if we have a label and no saved mask indices
                try Task.checkCancellation()
                if let label = label, !label.isEmpty {
                    // Set the prompt
                    if self.activeSegmentationIndex < self.segmentations.count {
                        self.segmentations[self.activeSegmentationIndex].textPrompt = label
                    }

                    // Only run segmentation if we don't have saved mask indices
                    // (mask will be restored by caller from file)
                    if savedMaskIndices == nil || savedMaskIndices?.isEmpty == true {
                        self.initializationStatus = "Creating mask for \"\(label)\"..."
                        await self.runTextPredictionSync()
                    } else {
                        self.initializationStatus = "Restoring mask..."
                        // Just mark as searched so UI shows correctly
                        if self.activeSegmentationIndex < self.segmentations.count {
                            self.segmentations[self.activeSegmentationIndex].isSearchPerformed = true
                        }
                        ErrorReporter.debug("Skipping segmentation - mask will be restored from file", subsystem: .segmentation)
                    }
                }

                try Task.checkCancellation()

                // Complete initialization
                self.initializationStatus = "Ready"
                try await Task.sleep(nanoseconds: 300_000_000) // 300ms

                // Load saved dominant color from metadata
                self.loadDominantColorFromMetadata()

                withAnimation(.easeOut(duration: 0.3)) {
                    self.isInitializingProject = false
                    self.initializationStatus = ""
                }

            } catch is CancellationError {
                ErrorReporter.debug("Project load cancelled", subsystem: .general)
                self.isInitializingProject = false
                self.initializationStatus = ""
            } catch {
                ErrorReporter.logError(error, subsystem: .general, context: "Failed to load project")
                self.isInitializingProject = false
                self.initializationStatus = ""
                self.lastError = AppError.imageProcessing(error.localizedDescription)
                self.showErrorAlert = true
            }
        }
    }

    /// Load image with fully saved segmentation data (skip SAM/VLM entirely)
    /// Use this when opening a project that has complete saved mask data
    func loadImageWithSavedSegmentations(
        from url: URL,
        savedSegmentations: [(id: UUID, name: String, textPrompt: String, selectedIndices: Set<Int>, masks: [(image: NSImage, score: Double, url: URL)])],
        autoDetectedLabel: String?
    ) {
        // Cancel any previous load task
        imageLoadTask?.cancel()

        isImageInitializedWithSAM = false
        isInitializingProject = true
        initializationStatus = "Loading project..."

        imageLoadTask = Task { [weak self] in
            guard let self = self else { return }

            // Ensure isInitializingProject is always reset, even on unexpected failures
            defer {
                Task { @MainActor [weak self] in
                    guard let self = self else { return }
                    // Only reset if still initializing (success path sets this explicitly)
                    if self.isInitializingProject {
                        self.isInitializingProject = false
                        self.initializationStatus = ""
                    }
                }
            }

            do {
                try Task.checkCancellation()

                let image = try await self.loadInputImage(from: url)

                try Task.checkCancellation()

                // Reset state
                self.editableMaskImage = nil
                self.maskHistory.removeAll()
                self.brushPreviewPosition = nil
                self.compositeImage = nil
                self.generationStages = [:]
                self.generationStatus = ""
                self.zoomScale = 1.0
                self.panOffset = .zero
                self.panBase = .zero
                self.useExistingAlpha = false
                self.lastError = nil

                self.imageHasAlpha = ImageService.shared.checkImageHasAlpha(image)

                // Restore auto-detected label
                self.autoDetectedLabel = autoDetectedLabel

                // Restore segmentation entries from saved data
                self.segmentations.removeAll()
                for saved in savedSegmentations {
                    var entry = SegmentationEntry(name: saved.name)
                    entry.textPrompt = saved.textPrompt
                    entry.allMasks = saved.masks
                    entry.selectedMaskIndices = saved.selectedIndices
                    entry.isSearchPerformed = true
                    entry.isExpanded = false
                    self.segmentations.append(entry)
                }

                // Expand first segmentation
                if !self.segmentations.isEmpty {
                    self.segmentations[0].isExpanded = true
                    self.activeSegmentationIndex = 0
                }

                ErrorReporter.debug("Restored \(savedSegmentations.count) segmentations from saved data", subsystem: .segmentation)

                // Transition to segment step
                withAnimation(.easeOut(duration: 0.25)) {
                    self.currentStep = .segment
                }

                // Initialize SAM in background (for potential new segmentations)
                // But don't wait for it - user can see their saved masks immediately
                try Task.checkCancellation()
                self.initializationStatus = "Preparing segmentation engine..."

                Task.detached { [weak self] in
                    _ = await self?.initializeImageWithoutVLM()
                }

                // Small delay then complete
                try await Task.sleep(nanoseconds: 200_000_000) // 200ms

                // Load saved dominant color from metadata
                self.loadDominantColorFromMetadata()

                withAnimation(.easeOut(duration: 0.3)) {
                    self.isInitializingProject = false
                    self.initializationStatus = ""
                }

                // Trigger preloading of merged mask
                self.triggerMaskPreload()

            } catch is CancellationError {
                ErrorReporter.debug("Project load cancelled", subsystem: .general)
                self.isInitializingProject = false
                self.initializationStatus = ""
            } catch {
                ErrorReporter.logError(error, subsystem: .general, context: "Failed to load project")
                self.isInitializingProject = false
                self.initializationStatus = ""
                self.lastError = AppError.imageProcessing(error.localizedDescription)
                self.showErrorAlert = true
            }
        }
    }

    /// Save current segmentation data to project folder
    func saveSegmentationDataToProject() {
        guard let projectId = projectId else { return }
        guard !segmentations.isEmpty else { return }

        // Convert SegmentationEntry to the format expected by ProjectManager
        let dataToSave: [(id: UUID, name: String, textPrompt: String, selectedIndices: [Int], masks: [(image: NSImage, url: URL)])] = segmentations.compactMap { entry in
            guard !entry.allMasks.isEmpty else { return nil }
            return (
                id: entry.id,
                name: entry.name,
                textPrompt: entry.textPrompt,
                selectedIndices: Array(entry.selectedMaskIndices),
                masks: entry.allMasks.map { (image: $0.image, url: $0.url) }
            )
        }

        guard !dataToSave.isEmpty else { return }

        // Get merged mask from preload manager
        let mergedMask = preloadManager.getCachedMergedMask(for: projectId)

        Task {
            do {
                try await ProjectManager.shared.saveSegmentationData(
                    for: projectId,
                    segmentations: dataToSave,
                    autoDetectedLabel: autoDetectedLabel,
                    mergedMask: mergedMask
                )
            } catch {
                ErrorReporter.logError(error, subsystem: .general, context: "Failed to save segmentation data")
            }
        }
    }

    /// Run VLM detection synchronously and return the result
    private func runVLMDetectionSync() async -> String? {
        guard let path = inputImagePath else { return nil }

        let coordinator = ModelLoadingCoordinator.shared

        // Wait for VLM to be ready if it's still starting
        if coordinator.isStartingVLM {
            ErrorReporter.debug("Waiting for VLM server to start...", subsystem: .python)
            while coordinator.isStartingVLM {
                try? await Task.sleep(nanoseconds: 100_000_000)  // 100ms
                if Task.isCancelled { return nil }
            }
        }

        // Ensure VLM is ready
        guard coordinator.isVLMReady else {
            ErrorReporter.debug("VLM server not ready, skipping auto-detection", subsystem: .python)
            return nil
        }

        do {
            ErrorReporter.debug("Starting auto-detection for: \(path)", subsystem: .python)
            let description = try await coordinator.describeImage(imagePath: path)

            // Update the label for display
            await MainActor.run {
                self.autoDetectedLabel = description
                self.isAutoDetecting = false
            }

            print("[VLM] Auto-detected: \(description)")
            return description
        } catch {
            print("[VLM] Auto-detection failed: \(error)")
            return nil
        }
    }

    /// Run text prediction synchronously (for initialization)
    private func runTextPredictionSync() async {
        guard activeSegmentationIndex < segmentations.count else { return }
        guard !segmentations[activeSegmentationIndex].textPrompt.isEmpty else { return }
        guard isImageInitializedWithSAM else {
            print("[Segmentation] Cannot run text prediction - image not initialized with SAM")
            return
        }

        segmentations[activeSegmentationIndex].isSearchPerformed = true
        segmentations[activeSegmentationIndex].isProcessing = true

        let index = activeSegmentationIndex
        let text = segmentations[index].textPrompt

        await performPrediction(for: index, text: text, points: [], box: nil)

        if index < segmentations.count {
            segmentations[index].isProcessing = false
            segmentations[index].name = text.capitalized
        }
    }

    func checkImageHasAlpha() {
        guard let image = inputImage else { return }
        imageHasAlpha = ImageService.shared.checkImageHasAlpha(image)
    }

    /// Initialize the image with SAM backend (also triggers VLM in background)
    /// - Returns: true if initialization succeeded, false otherwise
    func initializeImage() async -> Bool {
        guard let path = inputImagePath else {
            print("[Init] No input image path")
            return false
        }
        guard let projectId = projectId else {
            print("[Init] No project ID")
            return false
        }
        do {
            // CRITICAL: Pass projectId to track SAM image ownership
            let size = try await env.setImage(path: path, projectId: projectId)
            imagePixelSize = size
            isImageInitializedWithSAM = true
            print("[Init] Image initialized with SAM for project \(projectId.uuidString.prefix(8)), size: \(size)")

            // Trigger VLM auto-detection in background (don't await - let it run async)
            Task {
                await startVLMAutoDetection(imagePath: path)
            }
            return true
        } catch {
            print("[Init] Failed to set image: \(error)")
            isImageInitializedWithSAM = false
            return false
        }
    }

    /// Initialize the image with SAM backend only (no VLM trigger)
    /// Used during full initialization flow where VLM is called separately
    /// - Returns: true if initialization succeeded, false otherwise
    func initializeImageWithoutVLM() async -> Bool {
        guard let path = inputImagePath else {
            print("[Init] No input image path")
            return false
        }
        guard let projectId = projectId else {
            print("[Init] No project ID")
            return false
        }
        do {
            // CRITICAL: Pass projectId to track SAM image ownership
            let size = try await env.setImage(path: path, projectId: projectId)
            imagePixelSize = size
            isImageInitializedWithSAM = true
            print("[Init] Image initialized with SAM (no VLM) for project \(projectId.uuidString.prefix(8)), size: \(size)")
            return true
        } catch {
            print("[Init] Failed to set image: \(error)")
            isImageInitializedWithSAM = false
            return false
        }
    }

    /// Start VLM auto-detection to identify the object in the image
    private func startVLMAutoDetection(imagePath: String) async {
        // Cancel any previous detection
        autoDetectionTask?.cancel()

        // CRITICAL: Capture projectId to prevent race conditions on project switch
        guard let capturedProjectId = projectId else { return }

        autoDetectionTask = Task { [weak self, capturedProjectId] in
            guard let self = self else { return }

            await MainActor.run {
                self.isAutoDetecting = true
                self.autoDetectedLabel = nil
            }

            let coordinator = ModelLoadingCoordinator.shared

            // Wait for VLM to be ready if it's still starting
            if coordinator.isStartingVLM {
                ErrorReporter.debug("Waiting for VLM server to start...", subsystem: .python)
                while coordinator.isStartingVLM {
                    try? await Task.sleep(nanoseconds: 100_000_000)  // 100ms
                    if Task.isCancelled { return }
                }
            }

            // Ensure VLM is ready
            guard coordinator.isVLMReady else {
                ErrorReporter.debug("VLM server not ready, skipping auto-detection", subsystem: .python)
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
                    // CRITICAL: Validate project hasn't changed during async VLM call
                    guard self.projectId == capturedProjectId else {
                        print("[VLM] Project changed during detection - discarding result")
                        self.isAutoDetecting = false
                        return
                    }

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

    // MARK: - Utilities
    // NOTE: Navigation methods are in SimpleEditorViewModel+Navigation.swift
    // NOTE: Cache restore methods are in SimpleEditorViewModel+Cache.swift
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

    // MARK: - Color Persistence

    /// Save the dominant color to project metadata
    private func saveColorToMetadata(projectId: UUID, hexColor: String) async {
        // Access ProjectManager on MainActor since it's a shared singleton
        let metadata = await MainActor.run {
            ProjectManager.shared.loadMetadata(for: projectId) ?? ProjectMetadata(projectId: projectId)
        }
        var mutableMetadata = metadata
        mutableMetadata.dominantColor = hexColor
        do {
            try await MainActor.run {
                try ProjectManager.shared.saveMetadata(mutableMetadata)
            }
        } catch {
            handleError(error, userFacing: false)
        }
    }

    /// Load dominant color from metadata and set customModelColor
    func loadDominantColorFromMetadata() {
        guard let projectId = projectId else { return }
        if let metadata = ProjectManager.shared.loadMetadata(for: projectId),
           let hexColor = metadata.dominantColor,
           let color = ColorExtractionService.shared.fromHexString(hexColor) {
            customModelColor = color
        }
    }
}
