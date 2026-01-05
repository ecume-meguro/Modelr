import SwiftUI
import Foundation

/// ViewModel for ContentViewSimple - manages all state and business logic
@MainActor
class SimpleEditorViewModel: ObservableObject {
    // MARK: - Dependencies
    let env: PythonEnvironment

    // MARK: - Core Image State
    @Published var inputImage: NSImage?
    @Published var inputImagePath: String?
    @Published var imagePixelSize: CGSize = .zero
    @Published var zoomScale: CGFloat = 1.0

    // MARK: - Workflow State
    enum Step { case setup, input, segment, touchup, generate, postProcess }
    @Published var currentStep: Step = .setup

    // MARK: - Setup State
    enum SetupSubStep: String, CaseIterable {
        case chooseModel = "Choose Model"
        case configuringEnvironment = "Configuring Environment"
        case downloadingSegmentation = "Downloading Segmentation Model"
        case downloadingGeneration = "Downloading 3D Generation Model"
    }
    @Published var currentSetupSubStep: SetupSubStep = .chooseModel
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
    var downloadStartTime: Date?
    var lastDownloadBytes: Int64 = 0
    var lastSpeedUpdateTime: Date?
    var speedHistory: [Double] = []  // For moving average
    var lastValidSpeed: Double = 0   // Keep last valid speed when no change

    // MARK: - Multi-Segmentation State
    @Published var segmentations: [SegmentationEntry] = []
    @Published var activeSegmentationIndex: Int = 0
    @Published var useExistingAlpha: Bool = false
    @Published var imageHasAlpha: Bool = false

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

    // MARK: - Generation State
    @Published var isGenerating = false
    @Published var generationStatus = ""
    @Published var generated3DModelURL: URL?
    @Published var compositeImage: NSImage?
    @Published var generationStartTime: Date?
    @Published var generationDuration: TimeInterval?
    @Published var selectedPreset: QualityPreset = .normal
    @Published var showAdvancedSettings = false
    @Published var customSteps: CGFloat = 35
    @Published var customResolution: CGFloat = 256
    @Published var generationStages: [GenerationStage: StageProgress] = [:]
    @Published var isLargeModelDownloaded: Bool = false
    @Published var isSmallModelDownloaded: Bool = false

    // MARK: - Warning Dialogs
    @Published var showBackWarning: Bool = false
    @Published var showDiscardModelWarning: Bool = false
    @Published var showDiscardImageWarning: Bool = false
    @Published var showStartOverWarning: Bool = false

    // MARK: - Post-Process State
    @Published var meshComponents: [MeshComponent] = []
    @Published var selectedComponentIndices: Set<Int> = []
    @Published var isAnalyzingMesh: Bool = false
    @Published var isProcessingMesh: Bool = false
    @Published var processedModelURL: URL?
    @Published var selectedExportFormat: ExportFormat = .obj
    @Published var componentFiles: [ComponentFile] = []

    // Post-process confirmations and editing state
    @Published var showDeleteSelectedConfirmation: Bool = false
    @Published var showKeepSelectedConfirmation: Bool = false
    @Published var showKeepLargestConfirmation: Bool = false
    @Published var isEditingKeepLargest: Bool = false
    @Published var keepLargestCount: Int = 1

    // Background environment setup tracking
    @Published var isConfiguringEnvironment: Bool = false

    // MARK: - UI State
    @Published var isDragging = false
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
    init(env: PythonEnvironment) {
        self.env = env

        // Check if setup was already completed
        let wasSetupComplete = UserDefaults.standard.bool(forKey: "SetupComplete")
        if wasSetupComplete {
            isSetupComplete = true
            currentStep = .input
            setupSubStepCompleted = Set(SetupSubStep.allCases)
            // Mark Python environment ready for generation
            env.markHunyuanReady()
        } else {
            currentStep = .setup
        }

        checkModelsDownloaded()
    }

    /// Check if models are downloaded
    func checkModelsDownloaded() {
        let fileManager = FileManager.default
        guard let appSupportDir = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return }

        let hunyuanDir = appSupportDir
            .appendingPathComponent("ModelrV3")
            .appendingPathComponent("Hunyuan3D")
        
        let hfCacheDir = hunyuanDir.appendingPathComponent("hf_cache")

        // Check large model (Hunyuan3D-2.1)
        let largeModelDirName = "models--tencent--Hunyuan3D-2.1"
        let isLargeDownloaded = checkModelExists(dirName: largeModelDirName, in: hfCacheDir) || 
                                checkModelExists(dirName: largeModelDirName, in: hunyuanDir)
        
        isLargeModelDownloaded = isLargeDownloaded

        // Check small model (Hunyuan3D-2mini)
        let smallModelDirName = "models--tencent--Hunyuan3D-2mini"
        let isSmallDownloaded = checkModelExists(dirName: smallModelDirName, in: hfCacheDir) || 
                                checkModelExists(dirName: smallModelDirName, in: hunyuanDir)
        
        isSmallModelDownloaded = isSmallDownloaded
        
        print("[Setup] Model status - Small: \(isSmallModelDownloaded), Large: \(isLargeModelDownloaded)")
    }

    private func checkModelExists(dirName: String, in parentDir: URL) -> Bool {
        let fileManager = FileManager.default
        let modelPath = parentDir.appendingPathComponent(dirName)
        
        if fileManager.fileExists(atPath: modelPath.path) {
            if let contents = try? fileManager.contentsOfDirectory(atPath: modelPath.path),
               contents.contains("snapshots") || contents.contains("blobs") {
                return true
            }
        }
        return false
    }

    /// Check if the large model (Hunyuan3D-2.1) is downloaded (legacy)
    func checkLargeModelDownloaded() {
        checkModelsDownloaded()
    }

    // MARK: - Image Loading
    func loadImage(from url: URL) {
        guard let image = NSImage(contentsOf: url) else { return }

        inputImage = image

        let ext = url.pathExtension.lowercased()
        if ext == "webp" || ext == "bmp" || ext == "gif" {
            if let pngPath = convertToPNG(image: image, originalName: url.deletingPathExtension().lastPathComponent) {
                inputImagePath = pngPath
            } else {
                inputImagePath = url.path
            }
        } else {
            inputImagePath = url.path
        }

        segmentations.removeAll()
        addSegmentation()
        editableMaskImage = nil
        maskHistory.removeAll()
        brushPreviewPosition = nil
        compositeImage = nil
        generated3DModelURL = nil
        generationStages = [:]
        generationStatus = ""
        zoomScale = 1.0
        useExistingAlpha = false

        if let rep = image.representations.first {
            imagePixelSize = CGSize(width: CGFloat(rep.pixelsWide), height: CGFloat(rep.pixelsHigh))
        }

        checkImageHasAlpha()

        withAnimation(.easeOut(duration: 0.25)) {
            currentStep = .segment
        }

        Task { await initializeImage() }
    }

    private func convertToPNG(image: NSImage, originalName: String) -> String? {
        guard let tiffData = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData),
              let pngData = bitmap.representation(using: .png, properties: [:]) else {
            return nil
        }

        let tempPath = NSTemporaryDirectory() + "\(originalName)_\(UUID().uuidString.prefix(8)).png"
        do {
            try pngData.write(to: URL(fileURLWithPath: tempPath))
            return tempPath
        } catch {
            print("Failed to write PNG: \(error)")
            return nil
        }
    }

    private func initializeImage() async {
        guard let path = inputImagePath else { return }
        do {
            let size = try await env.setImage(path: path)
            imagePixelSize = size
        } catch {
            print("[Init] Failed to set image: \(error)")
        }
    }

    func checkImageHasAlpha() {
        guard let image = inputImage,
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            imageHasAlpha = false
            return
        }

        let alphaInfo = cgImage.alphaInfo
        let hasAlphaChannel = alphaInfo == .first || alphaInfo == .last ||
                              alphaInfo == .premultipliedFirst || alphaInfo == .premultipliedLast

        guard hasAlphaChannel else {
            imageHasAlpha = false
            return
        }

        let width = cgImage.width
        let height = cgImage.height
        let colorSpace = CGColorSpaceCreateDeviceRGB()

        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ), let data = context.data else {
            imageHasAlpha = false
            return
        }

        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        let pixels = data.bindMemory(to: UInt8.self, capacity: width * height * 4)
        var hasTransparency = false

        let sampleStep = max(1, (width * height) / 10000)
        for i in stride(from: 0, to: width * height, by: sampleStep) {
            let alpha = pixels[i * 4 + 3]
            if alpha < 250 {
                hasTransparency = true
                break
            }
        }

        imageHasAlpha = hasTransparency
    }

    // MARK: - Navigation
    func handleBackAction() {
        switch currentStep {
        case .setup:
            break  // Can't go back from setup
        case .input:
            break
        case .segment:
            showDiscardImageWarning = true
        case .touchup:
            showBackWarning = true
        case .generate:
            if generated3DModelURL != nil {
                showDiscardModelWarning = true
            } else {
                goBack()
            }
        case .postProcess:
            goBack()
        }
    }

    func goBack() {
        withAnimation(.easeOut(duration: 0.2)) {
            switch currentStep {
            case .setup:
                break  // Can't go back from setup
            case .input:
                break
            case .segment:
                segmentations.removeAll()
                inputImage = nil
                inputImagePath = nil
                imagePixelSize = .zero
                imageHasAlpha = false
                currentStep = .input
            case .touchup:
                editableMaskImage = nil
                maskHistory.removeAll()
                brushPreviewPosition = nil
                currentStep = .segment
            case .generate:
                compositeImage = nil
                generated3DModelURL = nil
                generationStages = [:]
                generationStatus = ""
                generationStartTime = nil
                generationDuration = nil
                currentStep = .touchup
            case .postProcess:
                meshComponents.removeAll()
                selectedComponentIndices.removeAll()
                processedModelURL = nil
                currentStep = .generate
            }
        }
    }

    func clearAll() {
        withAnimation(.easeOut(duration: 0.2)) {
            inputImage = nil
            inputImagePath = nil
            segmentations.removeAll()
            activeSegmentationIndex = 0
            useExistingAlpha = false
            imageHasAlpha = false
            editableMaskImage = nil
            maskHistory.removeAll()
            compositeImage = nil
            generated3DModelURL = nil
            generationStages = [:]
            generationStartTime = nil
            generationDuration = nil
            meshComponents.removeAll()
            selectedComponentIndices.removeAll()
            processedModelURL = nil
            zoomScale = 1.0
            currentStep = .input
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
