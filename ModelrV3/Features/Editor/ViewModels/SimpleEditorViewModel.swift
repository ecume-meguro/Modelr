import SwiftUI
import Foundation

// MARK: - Segmentation Entry Model
/// Represents a single segmentation with its own prompt and mask selection
struct SegmentationEntry: Identifiable {
    let id: UUID
    var name: String
    var textPrompt: String = ""
    var points: [SAMPoint] = []
    var allMasks: [(image: NSImage, score: Double, url: URL)] = []
    var selectedMaskIndices: Set<Int> = [0]  // Support multiple selections
    var isExpanded: Bool = true
    var isSearchPerformed: Bool = false
    var isProcessing: Bool = false

    init(name: String) {
        self.id = UUID()
        self.name = name
    }

    /// Returns the first selected mask (for single selection compatibility)
    var selectedMask: NSImage? {
        guard let firstIndex = selectedMaskIndices.sorted().first,
              firstIndex < allMasks.count else { return nil }
        return allMasks[firstIndex].image
    }

    /// Returns all selected masks
    var selectedMasks: [NSImage] {
        selectedMaskIndices.sorted().compactMap { index in
            guard index < allMasks.count else { return nil }
            return allMasks[index].image
        }
    }

    var hasValidMask: Bool {
        !allMasks.isEmpty && selectedMaskIndices.contains(where: { $0 < allMasks.count })
    }

    /// For backwards compatibility - returns first selected index
    var selectedMaskIndex: Int {
        selectedMaskIndices.sorted().first ?? 0
    }

    var promptDescription: String {
        if !textPrompt.isEmpty {
            return "\"\(textPrompt)\""
        } else if !points.isEmpty {
            return "\(points.count) point(s)"
        }
        return "Empty"
    }
}

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
    enum Step { case input, segment, touchup, generate, postProcess }
    @Published var currentStep: Step = .input

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
    @Published var selectedHunyuanModel: Hunyuan3DModel = .quality
    @Published var downloadedModels: Set<Hunyuan3DModel> = []
    
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

    struct ComponentFile: Identifiable {
        let id = UUID()
        let index: Int
        let path: String
    }

    struct MeshComponent: Identifiable {
        let id = UUID()
        let index: Int
        let vertexCount: Int
        let faceCount: Int
        let boundsMin: [Double]
        let boundsMax: [Double]
        let center: [Double]
        let size: Double
        let isWatertight: Bool

        var sizeDescription: String {
            if size < 0.01 { return "Tiny" }
            if size < 0.1 { return "Small" }
            if size < 0.5 { return "Medium" }
            return "Large"
        }
    }

    enum ExportFormat: String, CaseIterable, Identifiable {
        case obj = "OBJ"
        case glb = "GLB"
        case stl = "STL"
        case ply = "PLY"

        var id: String { rawValue }
        var fileExtension: String { rawValue.lowercased() }
    }

    // MARK: - UI State
    @Published var isDragging = false
    
    // MARK: - Generation Types
    enum Hunyuan3DModel: String, CaseIterable, Identifiable {
        case fast = "Fast"
        case quality = "Quality"

        var id: String { rawValue }

        var modelVariant: String {
            switch self {
            case .fast: return "mini"
            case .quality: return "std"
            }
        }

        var description: String {
            switch self {
            case .fast: return "Hunyuan3D-2 Mini — Faster generation"
            case .quality: return "Hunyuan3D-2.1 — Higher quality results"
            }
        }

        var modelSize: String {
            switch self {
            case .fast: return "~2 GB"
            case .quality: return "~4 GB"
            }
        }
    }

    enum GenerationStage: String, CaseIterable {
        case downloading = "Downloading Model"
        case extracting = "Extracting"
        case loading = "Loading Model"
        case diffusion = "Diffusion Sampling"
        case volumeDecoding = "Volume Decoding"
        case saving = "Saving"
    }
    
    struct StageProgress {
        var status: StageStatus = .pending
        var progress: Double = 0
        var detail: String = ""
    }
    
    enum StageStatus {
        case pending
        case inProgress
        case completed
        case cancelled
        case failed
    }
    
    // MARK: - Initialization
    init(env: PythonEnvironment) {
        self.env = env
        checkDownloadedModels()
        loadSavedModelPreference()
    }

    /// Load the model preference saved during setup
    private func loadSavedModelPreference() {
        if let savedVariant = UserDefaults.standard.string(forKey: "SelectedHunyuanModel") {
            if savedVariant == "mini" {
                selectedHunyuanModel = .fast
            } else if savedVariant == "std" {
                selectedHunyuanModel = .quality
            }
        }
    }

    /// Check which Hunyuan models are already downloaded
    func checkDownloadedModels() {
        let fileManager = FileManager.default
        guard let appSupportDir = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return }

        let hunyuanCacheDir = appSupportDir
            .appendingPathComponent("ModelrV3")
            .appendingPathComponent("Hunyuan3D")
            .appendingPathComponent("hf_cache")

        var downloaded: Set<Hunyuan3DModel> = []

        // Check for quality model (Hunyuan3D-2.1)
        let qualityModelPath = hunyuanCacheDir.appendingPathComponent("models--tencent--Hunyuan3D-2.1")
        if fileManager.fileExists(atPath: qualityModelPath.path) {
            // Check if there are actual model files (not just empty dir)
            if let contents = try? fileManager.contentsOfDirectory(atPath: qualityModelPath.path),
               contents.contains("snapshots") || contents.contains("blobs") {
                downloaded.insert(.quality)
            }
        }

        // Check for fast model (Hunyuan3D-2mini)
        let fastModelPath = hunyuanCacheDir.appendingPathComponent("models--tencent--Hunyuan3D-2mini")
        if fileManager.fileExists(atPath: fastModelPath.path) {
            if let contents = try? fileManager.contentsOfDirectory(atPath: fastModelPath.path),
               contents.contains("snapshots") || contents.contains("blobs") {
                downloaded.insert(.fast)
            }
        }

        downloadedModels = downloaded
    }

    func isModelDownloaded(_ model: Hunyuan3DModel) -> Bool {
        downloadedModels.contains(model)
    }
    
    // MARK: - Image Loading
    func loadImage(from url: URL) {
        guard let image = NSImage(contentsOf: url) else { return }

        inputImage = image

        // Convert non-standard formats (webp, etc.) to PNG for Python backend
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

        // Clear all previous data and initialize first segmentation
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

        // Get pixel dimensions
        if let rep = image.representations.first {
            imagePixelSize = CGSize(width: CGFloat(rep.pixelsWide), height: CGFloat(rep.pixelsHigh))
        }

        checkImageHasAlpha()

        withAnimation(.easeOut(duration: 0.25)) {
            currentStep = .segment
        }

        Task { await initializeImage() }
    }

    /// Converts an image to PNG format using Apple's native APIs (offline, no dependencies)
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
        
        // Check for actual transparency
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
    
    // MARK: - Multi-Segmentation Management

    /// Add a new segmentation entry and make it active
    func addSegmentation() {
        // Collapse all existing segmentations
        for i in segmentations.indices {
            segmentations[i].isExpanded = false
        }

        let newEntry = SegmentationEntry(name: "Object \(segmentations.count + 1)")
        segmentations.append(newEntry)
        activeSegmentationIndex = segmentations.count - 1
    }

    /// Remove a segmentation entry by index
    func removeSegmentation(at index: Int) {
        guard index < segmentations.count else { return }
        segmentations.remove(at: index)

        // Adjust active index
        if segmentations.isEmpty {
            addSegmentation()
        } else if activeSegmentationIndex >= segmentations.count {
            activeSegmentationIndex = segmentations.count - 1
        }
        // Keep original names - don't rename
    }

    /// Expand a segmentation and collapse others
    func expandSegmentation(at index: Int) {
        guard index < segmentations.count else { return }

        for i in segmentations.indices {
            segmentations[i].isExpanded = (i == index)
        }
        activeSegmentationIndex = index
    }

    /// Run text prediction for active segmentation
    func runTextPrediction() {
        guard activeSegmentationIndex < segmentations.count else { return }
        guard !segmentations[activeSegmentationIndex].textPrompt.isEmpty else { return }

        segmentations[activeSegmentationIndex].isSearchPerformed = true
        segmentations[activeSegmentationIndex].isProcessing = true

        let index = activeSegmentationIndex
        let text = segmentations[index].textPrompt

        Task {
            await performTextSearch(for: index, text: text)
            await MainActor.run {
                if index < segmentations.count {
                    segmentations[index].isProcessing = false
                }
            }
        }
    }

    private func performTextSearch(for index: Int, text: String) async {
        do {
            let (maskURLs, _, scores, _) = try await env.predict(
                points: [],
                box: nil,
                text: text,
                imageSize: imagePixelSize
            )

            var masks: [(image: NSImage, score: Double, url: URL)] = []
            for (url, score) in zip(maskURLs, scores) {
                if let image = NSImage(contentsOf: url) {
                    masks.append((image: image, score: score, url: url))
                }
            }

            await MainActor.run {
                if index < segmentations.count {
                    segmentations[index].allMasks = masks
                    segmentations[index].selectedMaskIndices = [0]
                    // Update name to use the text prompt
                    segmentations[index].name = text.capitalized
                }
            }
        } catch {
            print("[Text] Error: \(error)")
        }
    }

    /// Add a point to active segmentation and run prediction
    func addPoint(at normalized: CGPoint) {
        guard activeSegmentationIndex < segmentations.count else { return }

        let point = SAMPoint(normalizedCoords: normalized.clamped, label: 1)
        segmentations[activeSegmentationIndex].points.append(point)
        segmentations[activeSegmentationIndex].isProcessing = true

        let index = activeSegmentationIndex
        let points = segmentations[index].points

        Task {
            await runPointPrediction(for: index, points: points)
            await MainActor.run {
                if index < segmentations.count {
                    segmentations[index].isProcessing = false
                }
            }
        }
    }

    private func runPointPrediction(for index: Int, points: [SAMPoint]) async {
        guard !points.isEmpty else { return }
        do {
            let (maskURLs, _, scores, _) = try await env.predict(
                points: points,
                box: nil,
                text: nil,
                imageSize: imagePixelSize
            )

            var masks: [(image: NSImage, score: Double, url: URL)] = []
            for (url, score) in zip(maskURLs, scores) {
                if let image = NSImage(contentsOf: url) {
                    masks.append((image: image, score: score, url: url))
                }
            }

            await MainActor.run {
                if index < segmentations.count {
                    segmentations[index].allMasks = masks
                    segmentations[index].selectedMaskIndices = [0]
                }
            }
        } catch {
            print("[Point] Error: \(error)")
        }
    }

    /// Select mask for a specific segmentation (shift to add/remove from selection)
    func selectMask(at maskIndex: Int, for segmentationIndex: Int, addToSelection: Bool = false) {
        guard segmentationIndex < segmentations.count else { return }
        guard maskIndex < segmentations[segmentationIndex].allMasks.count else { return }

        if addToSelection {
            // Toggle selection for shift-click
            if segmentations[segmentationIndex].selectedMaskIndices.contains(maskIndex) {
                // Don't remove if it's the only selected item
                if segmentations[segmentationIndex].selectedMaskIndices.count > 1 {
                    segmentations[segmentationIndex].selectedMaskIndices.remove(maskIndex)
                }
            } else {
                segmentations[segmentationIndex].selectedMaskIndices.insert(maskIndex)
            }
        } else {
            // Single selection - replace all
            segmentations[segmentationIndex].selectedMaskIndices = [maskIndex]
        }
    }
    
    func createMaskFromAlpha() {
        guard let image = inputImage,
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }

        let width = cgImage.width
        let height = cgImage.height
        let colorSpace = CGColorSpaceCreateDeviceRGB()

        guard let sourceContext = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ), let sourceData = sourceContext.data else { return }

        sourceContext.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        guard let maskContext = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ), let maskData = maskContext.data else { return }

        let sourcePixels = sourceData.bindMemory(to: UInt8.self, capacity: width * height * 4)
        let maskPixels = maskData.bindMemory(to: UInt8.self, capacity: width * height * 4)

        for i in 0..<(width * height) {
            let offset = i * 4
            let alpha = sourcePixels[offset + 3]
            let white: UInt8 = alpha > 128 ? 255 : 0
            maskPixels[offset + 0] = white
            maskPixels[offset + 1] = white
            maskPixels[offset + 2] = white
            maskPixels[offset + 3] = white
        }

        guard let maskCGImage = maskContext.makeImage() else { return }
        let maskNSImage = NSImage(cgImage: maskCGImage, size: NSSize(width: width, height: height))

        let tempURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("alpha_mask_\(UUID().uuidString).png")

        if let tiff = maskNSImage.tiffRepresentation,
           let bitmap = NSBitmapImageRep(data: tiff),
           let png = bitmap.representation(using: .png, properties: [:]) {
            try? png.write(to: tempURL)
        }

        // Create a single segmentation entry from alpha
        segmentations.removeAll()
        var entry = SegmentationEntry(name: "From Alpha")
        entry.allMasks = [(image: maskNSImage, score: 1.0, url: tempURL)]
        entry.selectedMaskIndices = [0]
        entry.isSearchPerformed = true
        segmentations.append(entry)
        activeSegmentationIndex = 0
    }

    /// Clear all segmentations and start fresh
    func clearAllSegmentations() {
        segmentations.removeAll()
        editableMaskImage = nil
        addSegmentation()  // Add initial empty segmentation
    }

    /// Clear active segmentation only
    func clearActiveSegmentation() {
        guard activeSegmentationIndex < segmentations.count else { return }
        segmentations[activeSegmentationIndex].textPrompt = ""
        segmentations[activeSegmentationIndex].points.removeAll()
        segmentations[activeSegmentationIndex].allMasks.removeAll()
        segmentations[activeSegmentationIndex].selectedMaskIndices = [0]
        segmentations[activeSegmentationIndex].isSearchPerformed = false
    }

    /// Find which mask was clicked in active segmentation
    func findMaskAtPoint(_ normalized: CGPoint, displaySize: CGSize) -> Int? {
        guard activeSegmentationIndex < segmentations.count else { return nil }
        let masks = segmentations[activeSegmentationIndex].allMasks

        for (index, maskData) in masks.enumerated().reversed() {
            let image = maskData.image
            guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { continue }

            let pixelX = Int(normalized.x * CGFloat(cgImage.width))
            let pixelY = Int(normalized.y * CGFloat(cgImage.height))

            guard pixelX >= 0, pixelX < cgImage.width, pixelY >= 0, pixelY < cgImage.height else { continue }

            guard let dataProvider = cgImage.dataProvider,
                  let data = dataProvider.data,
                  let bytes = CFDataGetBytePtr(data) else { continue }

            let bytesPerPixel = cgImage.bitsPerPixel / 8
            let bytesPerRow = cgImage.bytesPerRow
            let pixelOffset = pixelY * bytesPerRow + pixelX * bytesPerPixel

            let alpha: UInt8
            if bytesPerPixel >= 4 {
                alpha = bytes[pixelOffset + 3]
            } else if bytesPerPixel >= 1 {
                alpha = bytes[pixelOffset]
            } else {
                continue
            }

            if alpha > 128 {
                return index
            }
        }
        return nil
    }
    
    // MARK: - Touchup
    func startTouchup() {
        // Merge all selected masks from all segmentations
        let mergedMask = mergeAllSelectedMasks()
        guard mergedMask != nil else { return }

        editableMaskImage = mergedMask
        maskHistory.removeAll()

        withAnimation(.easeOut(duration: 0.25)) {
            currentStep = .touchup
        }
    }

    /// Merge all selected masks from all segmentations using OR operation
    func mergeAllSelectedMasks() -> NSImage? {
        let validSegmentations = segmentations.filter { $0.hasValidMask }
        guard !validSegmentations.isEmpty else { return nil }

        // Get reference size from first mask
        guard let firstMask = validSegmentations.first?.selectedMask,
              let firstCG = firstMask.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }

        let width = firstCG.width
        let height = firstCG.height
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let totalPixels = width * height

        // Create output context
        guard let outputContext = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ), let outputData = outputContext.data else { return nil }

        let outputPixels = outputData.bindMemory(to: UInt8.self, capacity: totalPixels * 4)

        // Initialize to fully transparent
        memset(outputPixels, 0, totalPixels * 4)

        // OR all masks together (including multiple selections per segmentation)
        for segmentation in validSegmentations {
            // Iterate through ALL selected masks in this segmentation
            for mask in segmentation.selectedMasks {
                guard let cgMask = mask.cgImage(forProposedRect: nil, context: nil, hints: nil) else { continue }

                // Draw mask to temp context
                guard let maskContext = CGContext(
                    data: nil, width: width, height: height,
                    bitsPerComponent: 8, bytesPerRow: width * 4,
                    space: colorSpace,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                ), let maskData = maskContext.data else { continue }

                maskContext.draw(cgMask, in: CGRect(x: 0, y: 0, width: width, height: height))
                let maskPixels = maskData.bindMemory(to: UInt8.self, capacity: totalPixels * 4)

                // OR operation: check BOTH RGB luminance AND alpha channel
                // SAM masks may use either format
                for i in 0..<totalPixels {
                    let offset = i * 4
                    let r = maskPixels[offset]
                    let g = maskPixels[offset + 1]
                    let b = maskPixels[offset + 2]
                    let a = maskPixels[offset + 3]

                // Pixel is part of mask if:
                // - Alpha is high (alpha-based mask), OR
                // - RGB luminance is high (grayscale/RGB-based mask)
                let luminance = (UInt16(r) + UInt16(g) + UInt16(b)) / 3
                let isMaskPixel = a > 128 || luminance > 128

                if isMaskPixel {
                    outputPixels[offset + 0] = 255
                    outputPixels[offset + 1] = 255
                    outputPixels[offset + 2] = 255
                    outputPixels[offset + 3] = 255
                }
                }
            }
        }

        guard let mergedCG = outputContext.makeImage() else { return nil }
        return NSImage(cgImage: mergedCG, size: NSSize(width: width, height: height))
    }
    
    func saveUndoState() {
        guard let currentMask = editableMaskImage else { return }
        maskHistory.append(currentMask)
        if maskHistory.count > 20 {
            maskHistory.removeFirst()
        }
    }
    
    func undo() {
        guard !maskHistory.isEmpty else { return }
        editableMaskImage = maskHistory.removeLast()
    }
    
    func paintOnMask(at normalized: CGPoint) {
        guard let maskImage = editableMaskImage,
              let cgImage = maskImage.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }

        let width = cgImage.width
        let height = cgImage.height
        let pixelX = Int(normalized.x * CGFloat(width))
        let pixelY = Int(normalized.y * CGFloat(height))

        guard pixelX >= 0, pixelX < width, pixelY >= 0, pixelY < height else { return }

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ), let data = context.data else { return }

        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        let pixels = data.bindMemory(to: UInt8.self, capacity: width * height * 4)

        let brushRadius = max(1, Int(brushSize * CGFloat(width) / 1000.0))
        let radiusSquared = brushRadius * brushRadius
        let value: UInt8 = brushMode == .add ? 255 : 0
        let pixelValue = UInt32(value) | (UInt32(value) << 8) | (UInt32(value) << 16) | (UInt32(value) << 24)

        // Clamp bounds for faster iteration
        let minY = max(0, pixelY - brushRadius)
        let maxY = min(height - 1, pixelY + brushRadius)
        let minX = max(0, pixelX - brushRadius)
        let maxX = min(width - 1, pixelX + brushRadius)

        // Use squared distance to avoid sqrt in inner loop
        for py in minY...maxY {
            let dySquared = (py - pixelY) * (py - pixelY)
            let rowOffset = py * width
            for px in minX...maxX {
                let dxSquared = (px - pixelX) * (px - pixelX)
                if dxSquared + dySquared <= radiusSquared {
                    let offset = (rowOffset + px) * 4
                    // Write all 4 bytes at once
                    pixels.advanced(by: offset).withMemoryRebound(to: UInt32.self, capacity: 1) { ptr in
                        ptr.pointee = pixelValue
                    }
                }
            }
        }

        guard let newCGImage = context.makeImage() else { return }
        editableMaskImage = NSImage(cgImage: newCGImage, size: NSSize(width: width, height: height))
    }
    
    // MARK: - Generation
    func transitionToGenerate() {
        createCompositeImage()
        withAnimation(.easeOut(duration: 0.25)) {
            currentStep = .generate
        }
    }
    
    func createCompositeImage() {
        guard let sourceImage = inputImage,
              let sourceCGImage = sourceImage.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let maskImage = editableMaskImage,
              let maskCGImage = maskImage.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }

        let width = sourceCGImage.width
        let height = sourceCGImage.height
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let totalPixels = width * height

        guard let sourceContext = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ), let sourceData = sourceContext.data else { return }

        sourceContext.draw(sourceCGImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        guard let maskContext = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ), let maskData = maskContext.data else { return }

        maskContext.draw(maskCGImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        guard let outputContext = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ), let outputData = outputContext.data else { return }

        // Use UInt32 for faster 4-byte operations
        let sourcePixels = sourceData.bindMemory(to: UInt32.self, capacity: totalPixels)
        let maskPixels = maskData.bindMemory(to: UInt8.self, capacity: totalPixels * 4)
        let outputPixels = outputData.bindMemory(to: UInt32.self, capacity: totalPixels)

        // Process in parallel chunks for large images
        let chunkSize = 65536
        let chunks = (totalPixels + chunkSize - 1) / chunkSize

        DispatchQueue.concurrentPerform(iterations: chunks) { chunk in
            let start = chunk * chunkSize
            let end = min(start + chunkSize, totalPixels)

            for i in start..<end {
                let maskValue = maskPixels[i * 4]  // R channel
                if maskValue > 0 {
                    // Copy RGB from source, set alpha to 255
                    let sourceVal = sourcePixels[i]
                    outputPixels[i] = (sourceVal & 0x00FFFFFF) | 0xFF000000
                } else {
                    outputPixels[i] = 0  // Fully transparent
                }
            }
        }

        guard let finalImage = outputContext.makeImage() else { return }
        compositeImage = NSImage(cgImage: finalImage, size: NSSize(width: width, height: height))
    }
    
    func generate3D() {
        guard let composite = compositeImage else { return }
        
        // Save composite to temp file
        let tempImagePath = NSTemporaryDirectory() + "composite_\(UUID().uuidString).png"
        if let tiff = composite.tiffRepresentation,
           let bitmap = NSBitmapImageRep(data: tiff),
           let png = bitmap.representation(using: .png, properties: [:]) {
            try? png.write(to: URL(fileURLWithPath: tempImagePath))
        }
        
        // Save mask to temp file if we have one
        let tempMaskPath: String
        if let maskImage = editableMaskImage {
            tempMaskPath = NSTemporaryDirectory() + "mask_\(UUID().uuidString).png"
            if let tiff = maskImage.tiffRepresentation,
               let bitmap = NSBitmapImageRep(data: tiff),
               let png = bitmap.representation(using: .png, properties: [:]) {
                try? png.write(to: URL(fileURLWithPath: tempMaskPath))
            }
        } else {
            tempMaskPath = ""
        }
        
        isGenerating = true
        generationStartTime = Date()
        generationStages = [:]
        
        Task {
            await env.generate3DModel(
                imagePath: tempImagePath,
                maskPath: tempMaskPath,
                steps: Int(customSteps),
                resolution: Int(customResolution),
                modelVariant: selectedHunyuanModel.modelVariant,
                progress: { [weak self] status in
                    Task { @MainActor in
                        self?.generationStatus = status
                        self?.updateGenerationStages(status: status)
                    }
                },
                completion: { [weak self] result in
                    Task { @MainActor in
                        self?.isGenerating = false
                        switch result {
                        case .success(let modelURL):
                            self?.generated3DModelURL = modelURL
                            if let startTime = self?.generationStartTime {
                                self?.generationDuration = Date().timeIntervalSince(startTime)
                            }
                            self?.markAllStagesCompleted()
                            // Update downloaded models list after successful generation
                            self?.checkDownloadedModels()
                        case .failure(let error):
                            print("[Gen] Error: \(error)")
                        }
                    }
                }
            )
        }
    }
    
    func stopGeneration() {
        env.cancelGeneration()
        isGenerating = false
        markRemainingStagesCancelled()
    }
    
    private func updateGenerationStages(status: String) {
        if status.contains("Downloading") || status.contains("Fetching") {
            // Show downloading stage only if model wasn't already downloaded
            if !isModelDownloaded(selectedHunyuanModel) {
                let (progress, detail) = parseDownloadProgress(status)
                generationStages[.downloading] = StageProgress(status: .inProgress, progress: progress, detail: detail)
            }
        } else if status.contains("Extracting") {
            // Mark downloading complete if it was shown
            if generationStages[.downloading] != nil {
                generationStages[.downloading] = StageProgress(status: .completed, progress: 1.0, detail: "")
            }
            generationStages[.extracting] = StageProgress(status: .inProgress, progress: 0, detail: "")
        } else if status.contains("Loading") {
            markPreviousStagesCompleted(before: .loading)
            generationStages[.extracting] = StageProgress(status: .completed, progress: 1.0, detail: "")
            generationStages[.loading] = StageProgress(status: .inProgress, progress: 0, detail: "")
        } else if status.contains("Diffusion Sampling") {
            markPreviousStagesCompleted(before: .diffusion)
            let (progress, detail) = parseProgressString(status)
            generationStages[.diffusion] = StageProgress(status: .inProgress, progress: progress, detail: detail)
        } else if status.contains("Volume Decoding") {
            markPreviousStagesCompleted(before: .volumeDecoding)
            generationStages[.diffusion] = StageProgress(status: .completed, progress: 1.0, detail: "")
            let (progress, detail) = parseProgressString(status)
            generationStages[.volumeDecoding] = StageProgress(status: .inProgress, progress: progress, detail: detail)
        } else if status.contains("Saving") {
            markPreviousStagesCompleted(before: .saving)
            generationStages[.volumeDecoding] = StageProgress(status: .completed, progress: 1.0, detail: "")
            generationStages[.saving] = StageProgress(status: .inProgress, progress: 0, detail: "")
        }
    }

    private func parseDownloadProgress(_ status: String) -> (Double, String) {
        var progress: Double = 0
        var detail = ""

        // Parse HuggingFace download progress: "Fetching 10 files: 50%|..." or percentage
        if let percentRange = status.range(of: #"(\d+)%"#, options: .regularExpression) {
            let percentStr = status[percentRange].dropLast()
            if let percent = Double(percentStr) {
                progress = percent / 100.0
            }
        }

        // Parse file count if available
        if let filesRange = status.range(of: #"(\d+)/(\d+)"#, options: .regularExpression) {
            detail = String(status[filesRange])
        } else if status.contains("files") {
            detail = "Downloading..."
        }

        return (progress, detail)
    }
    
    private func markPreviousStagesCompleted(before stage: GenerationStage) {
        let allStages = GenerationStage.allCases
        guard let targetIndex = allStages.firstIndex(of: stage) else { return }
        
        for i in 0..<targetIndex {
            let prevStage = allStages[i]
            if generationStages[prevStage]?.status != .completed {
                generationStages[prevStage] = StageProgress(status: .completed, progress: 1.0, detail: "")
            }
        }
    }
    
    private func markAllStagesCompleted() {
        for stage in GenerationStage.allCases {
            generationStages[stage] = StageProgress(status: .completed, progress: 1.0, detail: "")
        }
    }
    
    private func markRemainingStagesCancelled() {
        for stage in GenerationStage.allCases {
            if generationStages[stage]?.status != .completed {
                generationStages[stage] = StageProgress(status: .cancelled, progress: 0, detail: "")
            }
        }
    }
    
    private func parseProgressString(_ status: String) -> (Double, String) {
        var progress: Double = 0
        var detail = ""
        
        if let percentRange = status.range(of: #"(\d+)%"#, options: .regularExpression) {
            let percentStr = status[percentRange].dropLast()
            if let percent = Double(percentStr) {
                progress = percent / 100.0
            }
        }
        
        if let stepRange = status.range(of: #"\d+/\d+"#, options: .regularExpression) {
            detail = String(status[stepRange])
        }
        
        return (progress, detail)
    }
    
    // MARK: - Navigation
    func handleBackAction() {
        switch currentStep {
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
        let minutes = Int(duration) / 60
        let seconds = Int(duration) % 60
        if minutes > 0 {
            return String(format: "%dm %ds", minutes, seconds)
        } else {
            return String(format: "%ds", seconds)
        }
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

    // MARK: - Post-Processing

    /// URL of the mesh to process (either generated or processed)
    var currentMeshURL: URL? {
        processedModelURL ?? generated3DModelURL
    }

    func transitionToPostProcess() {
        withAnimation(.easeOut(duration: 0.25)) {
            currentStep = .postProcess
        }
        Task {
            await analyzeMesh()
        }
    }

    func analyzeMesh() async {
        guard let modelURL = currentMeshURL else { return }

        await MainActor.run {
            isAnalyzingMesh = true
            meshComponents.removeAll()
            selectedComponentIndices.removeAll()
            componentFiles.removeAll()
        }

        let result = await runMeshProcessor(command: "analyze", inputPath: modelURL.path)

        await MainActor.run {
            isAnalyzingMesh = false
            if let result = result,
               result["success"] as? Bool == true,
               let components = result["components"] as? [[String: Any]] {

                meshComponents = components.compactMap { comp -> MeshComponent? in
                    guard let index = comp["index"] as? Int,
                          let vertexCount = comp["vertex_count"] as? Int,
                          let faceCount = comp["face_count"] as? Int else { return nil }

                    return MeshComponent(
                        index: index,
                        vertexCount: vertexCount,
                        faceCount: faceCount,
                        boundsMin: comp["bounds_min"] as? [Double] ?? [0, 0, 0],
                        boundsMax: comp["bounds_max"] as? [Double] ?? [0, 0, 0],
                        center: comp["center"] as? [Double] ?? [0, 0, 0],
                        size: comp["size"] as? Double ?? 0,
                        isWatertight: comp["is_watertight"] as? Bool ?? false
                    )
                }
            }
        }

        // Extract components for 3D visualization if there are multiple
        if meshComponents.count > 1 {
            await extractComponentsForVisualization()
        }
    }

    private func extractComponentsForVisualization() async {
        guard let modelURL = currentMeshURL else { return }

        let tempDir = NSTemporaryDirectory() + "mesh_components_\(UUID().uuidString)"

        let result = await runMeshProcessor(
            command: "extract_all",
            inputPath: modelURL.path,
            outputPath: tempDir
        )

        await MainActor.run {
            if let result = result,
               result["success"] as? Bool == true,
               let components = result["components"] as? [[String: Any]] {

                componentFiles = components.compactMap { comp -> ComponentFile? in
                    guard let index = comp["index"] as? Int,
                          let path = comp["path"] as? String else { return nil }
                    return ComponentFile(index: index, path: path)
                }
            }
        }
    }

    func deleteSelectedComponents() async {
        guard !selectedComponentIndices.isEmpty,
              let modelURL = currentMeshURL else { return }

        let indicesToDelete = selectedComponentIndices.sorted()
        let outputPath = NSTemporaryDirectory() + "processed_mesh_\(UUID().uuidString).obj"

        await MainActor.run {
            isProcessingMesh = true
        }

        let result = await runMeshProcessor(
            command: "delete",
            inputPath: modelURL.path,
            outputPath: outputPath,
            indices: indicesToDelete
        )

        await MainActor.run {
            isProcessingMesh = false
            if let result = result,
               result["success"] as? Bool == true,
               let outputPathStr = result["output_path"] as? String {
                processedModelURL = URL(fileURLWithPath: outputPathStr)
                selectedComponentIndices.removeAll()
            }
        }

        // Re-analyze
        await analyzeMesh()
    }

    func keepLargestComponent() async {
        guard let modelURL = currentMeshURL else { return }

        let outputPath = NSTemporaryDirectory() + "processed_mesh_\(UUID().uuidString).obj"

        await MainActor.run {
            isProcessingMesh = true
        }

        let result = await runMeshProcessor(
            command: "keep_largest",
            inputPath: modelURL.path,
            outputPath: outputPath
        )

        await MainActor.run {
            isProcessingMesh = false
            if let result = result,
               result["success"] as? Bool == true,
               let outputPathStr = result["output_path"] as? String {
                processedModelURL = URL(fileURLWithPath: outputPathStr)
                selectedComponentIndices.removeAll()
            }
        }

        // Re-analyze
        await analyzeMesh()
    }

    func exportMesh(to url: URL) async -> Bool {
        guard let modelURL = currentMeshURL else { return false }

        await MainActor.run {
            isProcessingMesh = true
        }

        let result = await runMeshProcessor(
            command: "export",
            inputPath: modelURL.path,
            outputPath: url.path,
            format: selectedExportFormat.fileExtension
        )

        await MainActor.run {
            isProcessingMesh = false
        }

        return result?["success"] as? Bool == true
    }

    func toggleComponentSelection(_ index: Int) {
        if selectedComponentIndices.contains(index) {
            selectedComponentIndices.remove(index)
        } else {
            selectedComponentIndices.insert(index)
        }
    }

    func selectAllComponents() {
        selectedComponentIndices = Set(meshComponents.map { $0.index })
    }

    func deselectAllComponents() {
        selectedComponentIndices.removeAll()
    }

    private func runMeshProcessor(
        command: String,
        inputPath: String,
        outputPath: String? = nil,
        indices: [Int]? = nil,
        format: String? = nil
    ) async -> [String: Any]? {
        let appSupportDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("ModelrV3")
        let scriptPath = appSupportDir.appendingPathComponent("mesh_processor.py").path
        let venvPythonPath = appSupportDir.appendingPathComponent(".venv/bin/python").path

        // Check if script exists, copy from bundle if needed
        if !FileManager.default.fileExists(atPath: scriptPath) {
            if let bundlePath = Bundle.main.path(forResource: "mesh_processor", ofType: "py") {
                try? FileManager.default.copyItem(atPath: bundlePath, toPath: scriptPath)
            }
        }

        // Check if venv python exists
        guard FileManager.default.fileExists(atPath: venvPythonPath) else {
            print("[MeshProcessor] Python venv not found at \(venvPythonPath)")
            return nil
        }

        var args = [scriptPath, command, "--input", inputPath]

        if let outputPath = outputPath {
            args.append(contentsOf: ["--output", outputPath])
        }
        if let indices = indices {
            let indicesStr = indices.map { String($0) }.joined(separator: ",")
            args.append(contentsOf: ["--indices", indicesStr])
        }
        if let format = format {
            args.append(contentsOf: ["--format", format])
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: venvPythonPath)
        process.arguments = args
        process.currentDirectoryURL = appSupportDir

        var env = ProcessInfo.processInfo.environment
        env["PYTHONUNBUFFERED"] = "1"
        process.environment = env

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        do {
            try process.run()
            process.waitUntilExit()

            let outputData = stdout.fileHandleForReading.readDataToEndOfFile()
            let errorData = stderr.fileHandleForReading.readDataToEndOfFile()

            if let errorStr = String(data: errorData, encoding: .utf8), !errorStr.isEmpty {
                print("[MeshProcessor stderr] \(errorStr)")
            }

            if let outputStr = String(data: outputData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) {
                print("[MeshProcessor stdout] \(outputStr)")
                if let jsonData = outputStr.data(using: .utf8),
                   let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] {
                    return json
                }
            }
        } catch {
            print("[MeshProcessor] Error: \(error)")
        }

        return nil
    }
}
