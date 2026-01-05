import SwiftUI
import UniformTypeIdentifiers

@MainActor
class EditorViewModel: BaseEditorViewModel {
    // Debug mode
    let autoLoadLatest3DModel: Bool
    
    // Image state
    @Published var maskImage: NSImage?
    @Published var cachedDisplaySize: CGSize = .zero
    
    // Multi-mask selection state
    @Published var maskOptions: [NSImage] = []
    @Published var maskScores: [Double] = []
    @Published var selectedMaskIndex: Int = 0
    @Published var maskOptionsPaths: [String] = []
    @Published var processedMaskCache: [Int: NSImage] = [:]
    
    // Confidence overlay state
    @Published var confidenceOverlay: NSImage?
    @Published var showConfidenceOverlay: Bool = false
    
    // Real-time paint preview state
    @Published var livePaintMask: NSImage?
    
    // Alpha channel cache
    @Published var sourceAlphaData: [UInt8] = []
    @Published var sourceAlphaWidth: Int = 0
    @Published var sourceAlphaHeight: Int = 0
    
    // Multi-point state
    @Published var selectedPoints: [SAMPoint] = []
    @Published var boundingBoxes: [SAMBox] = []
    @Published var currentBox: SAMBox?
    
    // Lasso state
    @Published var lassoSelections: [LassoSelection] = []
    @Published var currentLasso: LassoSelection?
    
    // Polygon tool state
    @Published var polygonSelections: [PolygonSelection] = []
    @Published var currentPolygon: PolygonSelection?
    
    // Paint tool state
    @Published var paintStrokes: [PaintStroke] = []
    @Published var currentPaintStroke: PaintStroke?
    @Published var brushSize: CGFloat = 0.03
    @Published var isErasing: Bool = false
    @Published var brushCursorPosition: CGPoint?
    
    // Preprocess state
    @Published var selectedPreprocessTool: PreprocessTool = .crop
    @Published var cropRect: SAMBox?
    @Published var preprocessLasso: LassoSelection?
    
    // Undo/Redo history
    @Published var undoStack: [UndoAction] = []
    @Published var redoStack: [UndoAction] = []
    
    // Tool state
    @Published var selectedTool: SAMTool = .point
    @Published var currentStep: WorkflowStep = .input
    
    // Skip segmentation mode
    @Published var skipSegmentation: Bool = false
    
    // Selection state
    @Published var selectedPointId: UUID?
    @Published var selectedBoxId: UUID?
    @Published var selectedLassoId: UUID?
    
    // Display options
    @Published var maskOpacity: Double = 0.6
    @Published var magnification: CGFloat = 1.0
    
    // Generate state
    @Published var selectedQualityPreset: QualityPreset = .normal
    @Published var generateSteps: Double = 50
    @Published var generateResolution: Double = 256
    @Published var generationProgress = GenerationProgress()
    @Published var generationError: String?
    @Published var selectedGeneratorModel: GeneratorModel = .hunyuan
    
    // Performance flags
    @Published var maskIsDirty = false
    @Published var imageVersion: Int = 0
    
    // Task management
    var currentTasks: Set<Task<Void, Never>> = []
    
    init(env: PythonEnvironment = PythonEnvironment(), autoLoadLatest3DModel: Bool = false) {
        self.autoLoadLatest3DModel = autoLoadLatest3DModel
        super.init(env: env)
    }
    
    // MARK: - Computed Properties
    
    var canMoveToNextStep: Bool {
        switch currentStep {
        case .input:
            return inputImage != nil
        case .refine:
            return inputImage != nil
        case .segment:
            return maskImage != nil || skipSegmentation
        case .generate:
            return false
        }
    }
    
    var hasSelection: Bool {
        selectedPointId != nil || selectedBoxId != nil || selectedLassoId != nil
    }
    
    var displaySize: CGSize {
        if cachedDisplaySize != .zero {
            return cachedDisplaySize
        }
        
        guard let inputImage = inputImage else { return CGSize(width: 800, height: 600) }
        let imageSize = inputImage.size
        let aspectRatio = imageSize.width / imageSize.height
        
        let baseHeight: CGFloat = 600
        let baseWidth = baseHeight * aspectRatio
        
        let size = CGSize(width: baseWidth, height: baseHeight)
        cachedDisplaySize = size
        return size
    }
    
    var effectiveToolMode: SAMTool {
        switch currentStep {
        case .input:
            return .point
        case .refine:
            switch selectedPreprocessTool {
            case .crop:
                return .boundingBox
            case .polygonCrop:
                return .lasso
            }
        case .segment:
            return selectedTool
        case .generate:
            return .point
        }
    }
    
    var estimatedGenerationTime: String {
        let baseTime = generateSteps * (generateResolution / 256.0)
        let seconds = Int(baseTime)
        if seconds < 60 {
            return "\(seconds)s"
        } else {
            return "\(seconds / 60)m \(seconds % 60)s"
        }
    }
    
    var nextStepButtonTitle: String {
        switch currentStep {
        case .input: return "Proceed to Refine"
        case .refine: return "Proceed to Segment"
        case .segment: return "Proceed to Generate"
        case .generate: return "Done"
        }
    }
    
    var toolDescription: String {
        switch selectedTool {
        case .point:
            return "Click to add positive points (include), Option-click for negative points (exclude)"
        case .boundingBox:
            return "Drag to draw a bounding box around the object"
        case .lasso:
            return "Draw a freeform lasso around the object"
        case .paint:
            return isErasing ? "Paint over areas to remove from mask" : "Paint over areas to add to mask"
        case .polygon:
            return "Click points to create a polygon. Close by clicking near start or press Escape to finish."
        }
    }
    
    // MARK: - Image Loading
    
    func loadImage(from url: URL) {
        clearAnnotations()
        
        let task = Task.detached(priority: .userInitiated) {
            let loadedImage: NSImage? = await Task {
                return NSImage(contentsOf: url)
            }.value
            
            await MainActor.run {
                guard let image = loadedImage else {
                    self.env.status = "Error: Could not load image"
                    return
                }
                
                guard !Task.isCancelled else { return }
                
                self.inputImage = image
                self.maskImage = nil
                self.generated3DModelURL = nil
                self.imageVersion += 1
                self.cacheSourceAlpha()
                self.env.status = "Loaded: \(url.lastPathComponent)"
                
                let safeExtensions = ["png", "jpg", "jpeg", "bmp", "webp", "tiff"]
                let ext = url.pathExtension.lowercased()
                
                if safeExtensions.contains(ext) {
                    self.inputImagePath = url.path
                } else {
                    self.saveImageForBackend(image: image)
                }
                
                self.imagePixelSize = self.getOrientedPixelSize(for: image, at: url)
            }
        }
        
        Task { @MainActor in
            currentTasks.insert(task)
        }
    }
    
    func saveAndLoad(image: NSImage) {
        let tempDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/ModelrV3", isDirectory: true)
        let tempFile = tempDir.appendingPathComponent("pasted_image.png")
        
        do {
            try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
            guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
            let bitmap = NSBitmapImageRep(cgImage: cgImage)
            if let data = bitmap.representation(using: .png, properties: [:]) {
                try data.write(to: tempFile)
                loadImage(from: tempFile)
            }
        } catch {
            env.status = "Error: Could not save pasted image"
        }
    }
    
    private func getOrientedPixelSize(for image: NSImage, at url: URL) -> CGSize {
        if let source = CGImageSourceCreateWithURL(url as CFURL, nil),
           let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
           let pW = props[kCGImagePropertyPixelWidth] as? CGFloat,
           let pH = props[kCGImagePropertyPixelHeight] as? CGFloat {
            
            let orientation = props[kCGImagePropertyOrientation] as? Int ?? 1
            if orientation >= 5 && orientation <= 8 {
                return CGSize(width: pH, height: pW)
            }
            return CGSize(width: pW, height: pH)
        }
        
        if let rep = image.representations.first {
             return CGSize(width: CGFloat(rep.pixelsWide), height: CGFloat(rep.pixelsHigh))
        }
        
        return image.size
    }
    
    func saveImageForBackend(image: NSImage) {
        let tempDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/ModelrV3", isDirectory: true)
        let tempFile = tempDir.appendingPathComponent("backend_working_copy.png")
        
        do {
            try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
            guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
            let bitmap = NSBitmapImageRep(cgImage: cgImage)
            if let data = bitmap.representation(using: .png, properties: [:]) {
                try data.write(to: tempFile)
                self.inputImagePath = tempFile.path
            }
        } catch {
            self.env.status = "Error: conversion failed"
        }
    }
    
    // MARK: - Workflow Navigation
    
    func moveToNextStep() {
        guard let next = WorkflowStep(rawValue: currentStep.rawValue + 1) else { return }
        withAnimation(.spring()) {
            currentStep = next
        }
    }
    
    func clearAll() {
        inputImage = nil
        inputImagePath = nil
        maskImage = nil
        generated3DModelURL = nil
        clearAnnotations()
        undoStack.removeAll()
        redoStack.removeAll()
        currentStep = .input
        skipSegmentation = false
        maskOptions.removeAll()
        maskScores.removeAll()
        selectedMaskIndex = 0
        processedMaskCache.removeAll()
        confidenceOverlay = nil
        showConfidenceOverlay = false
        cachedDisplaySize = .zero
        imageVersion = 0
        env.status = "Ready"
    }
    
    // MARK: - Segmentation State Persistence
    
    private var savedSegmentationState: (
        points: [SAMPoint],
        boxes: [SAMBox],
        lassos: [LassoSelection],
        polygons: [PolygonSelection],
        paintStrokes: [PaintStroke]
    )?
    
    func saveSegmentationState() {
        savedSegmentationState = (
            selectedPoints,
            boundingBoxes,
            lassoSelections,
            polygonSelections,
            paintStrokes
        )
    }
    
    func restoreSegmentationState() {
        if let saved = savedSegmentationState {
            selectedPoints = saved.points
            boundingBoxes = saved.boxes
            lassoSelections = saved.lassos
            polygonSelections = saved.polygons
            paintStrokes = saved.paintStrokes
        }
    }
    
    // MARK: - Annotations
    
    func clearAnnotations() {
        selectedPoints.removeAll()
        boundingBoxes.removeAll()
        lassoSelections.removeAll()
        polygonSelections.removeAll()
        paintStrokes.removeAll()
        currentBox = nil
        currentLasso = nil
        currentPolygon = nil
        currentPaintStroke = nil
        selectedPointId = nil
        selectedBoxId = nil
        selectedLassoId = nil
    }
    
    func formatElapsedTime(_ elapsed: TimeInterval) -> String {
        let minutes = Int(elapsed) / 60
        let seconds = Int(elapsed) % 60
        if minutes > 0 {
            return String(format: "Elapsed: %d:%02d", minutes, seconds)
        } else {
            return String(format: "Elapsed: %ds", seconds)
        }
    }
    
    // MARK: - Alpha Channel Cache
    
    func cacheSourceAlpha() {
        guard let image = inputImage,
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            sourceAlphaData = []
            sourceAlphaWidth = 0
            sourceAlphaHeight = 0
            return
        }
        
        let width = cgImage.width
        let height = cgImage.height
        
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bytesPerPixel = 4
        let bytesPerRow = bytesPerPixel * width
        var pixels = [UInt8](repeating: 0, count: height * bytesPerRow)
        
        guard let context = CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            sourceAlphaData = []
            return
        }
        
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        
        var alphaChannel = [UInt8](repeating: 0, count: width * height)
        for y in 0..<height {
            for x in 0..<width {
                let pixelOffset = (y * bytesPerRow) + (x * bytesPerPixel)
                alphaChannel[y * width + x] = pixels[pixelOffset + 3]
            }
        }
        
        sourceAlphaData = alphaChannel
        sourceAlphaWidth = width
        sourceAlphaHeight = height
    }
    
    func isTransparentAt(normalized: CGPoint) -> Bool {
        guard !sourceAlphaData.isEmpty, sourceAlphaWidth > 0, sourceAlphaHeight > 0 else {
            return false
        }
        
        let x = Int(normalized.x * CGFloat(sourceAlphaWidth))
        let y = Int(normalized.y * CGFloat(sourceAlphaHeight))
        
        guard x >= 0, x < sourceAlphaWidth, y >= 0, y < sourceAlphaHeight else {
            return false
        }
        
        let index = y * sourceAlphaWidth + x
        guard index < sourceAlphaData.count else { return false }
        
        return sourceAlphaData[index] < 3
    }
    
    // MARK: - Undo/Redo
    
    func performUndo() {
        guard !undoStack.isEmpty else { return }
        let action = undoStack.removeLast()
        
        switch action {
        case .addPoint(let point):
            selectedPoints.removeAll { $0.id == point.id }
            redoStack.append(action)
            triggerReInference()
        case .addBox(let box):
            boundingBoxes.removeAll { $0.id == box.id }
            redoStack.append(action)
            triggerReInference()
        case .addLasso(let lasso):
            lassoSelections.removeAll { $0.id == lasso.id }
            redoStack.append(action)
            triggerReInference()
        case .addPaintStroke(let stroke):
            paintStrokes.removeAll { $0.id == stroke.id }
            redoStack.append(action)
            triggerReInference()
        case .crop(let original, _):
            inputImage = original
            imageVersion += 1
            redoStack.append(action)
        case .movePoint:
            break // Handle if needed
        }
    }
    
    func performRedo() {
        guard !redoStack.isEmpty else { return }
        let action = redoStack.removeLast()
        
        switch action {
        case .addPoint(let point):
            selectedPoints.append(point)
            undoStack.append(action)
            triggerReInference()
        case .addBox(let box):
            boundingBoxes.append(box)
            undoStack.append(action)
            triggerReInference()
        case .addLasso(let lasso):
            lassoSelections.append(lasso)
            undoStack.append(action)
            triggerReInference()
        case .addPaintStroke(let stroke):
            paintStrokes.append(stroke)
            undoStack.append(action)
            triggerReInference()
        case .crop(let cropped, _):
            inputImage = cropped
            imageVersion += 1
            undoStack.append(action)
        case .movePoint:
            break // Handle if needed
        }
    }
    
    // MARK: - Segmentation Actions
    
    func clearPaintStrokes() {
        paintStrokes.removeAll()
        triggerReInference()
    }
    
    func deleteSelectedAnnotation() {
        if let pointId = selectedPointId,
           let point = selectedPoints.first(where: { $0.id == pointId }) {
            withAnimation {
                selectedPoints.removeAll { $0.id == pointId }
                undoStack.append(.addPoint(point))
                redoStack.removeAll()
                selectedPointId = nil
            }
            triggerReInference()
        } else if let boxId = selectedBoxId,
                  let box = boundingBoxes.first(where: { $0.id == boxId }) {
            withAnimation {
                boundingBoxes.removeAll { $0.id == boxId }
                undoStack.append(.addBox(box))
                redoStack.removeAll()
                selectedBoxId = nil
            }
            triggerReInference()
        } else if let lassoId = selectedLassoId,
                  let lasso = lassoSelections.first(where: { $0.id == lassoId }) {
            withAnimation {
                lassoSelections.removeAll { $0.id == lassoId }
                undoStack.append(.addLasso(lasso))
                redoStack.removeAll()
                selectedLassoId = nil
            }
            triggerReInference()
        }
    }
    
    func selectMask(at index: Int) {
        guard index >= 0 && index < maskOptions.count else { return }
        selectedMaskIndex = index
        
        if let cachedMask = processedMaskCache[index] {
            maskImage = cachedMask
            maskIsDirty = true
        } else {
            maskImage = maskOptions[index]
            maskIsDirty = true
        }
    }
    
    func clearMaskOptions() {
        maskOptions = []
        maskOptionsPaths = []
        maskScores = []
        selectedMaskIndex = 0
        confidenceOverlay = nil
        processedMaskCache = [:]
    }
    
    // MARK: - 3D Generation
    
    func startGeneration() {
        guard let imagePath = inputImagePath else {
            generationProgress.stage = "Error: No image loaded"
            return
        }
        
        flushMaskToDisk()
        
        guard let maskPath = getMaskPath() else {
            generationProgress.stage = "Error: No mask available"
            return
        }
        
        isGenerating = true
        generationProgress = GenerationProgress()
        generationProgress.stage = "Preparing..."
        generationStartTime = Date()
        generated3DModelURL = nil
        generationError = nil
        
        Task {
            await env.generate3DModel(
                imagePath: imagePath,
                maskPath: maskPath,
                steps: Int(generateSteps),
                resolution: Int(generateResolution)
            ) { progressInfo in
                Task { @MainActor in
                    self.updateGenerationProgress(progressInfo)
                }
            } completion: { result in
                Task { @MainActor in
                    self.handleGenerationResult(result)
                }
            }
        }
    }
    
    func cancelGeneration() {
        env.cancelGeneration()
        isGenerating = false
        generationProgress.stage = "Cancelled"
    }
    
    private func handleGenerationResult(_ result: Result<URL, Error>) {
        isGenerating = false
        generationStartTime = nil
        switch result {
        case .success(let url):
            generated3DModelURL = url
            generationProgress = GenerationProgress()
        case .failure(let error):
            generationProgress.stage = "Error: \(error.localizedDescription)"
            generationError = error.localizedDescription
        }
    }
    
    private func updateGenerationProgress(_ progressString: String) {
        // Set totalSteps to 100 for percentage-based tracking
        generationProgress.totalSteps = 100
        
        if progressString.contains("Extracting foreground") {
            generationProgress.stage = "Extracting Foreground"
            generationProgress.currentStep = 5
        } else if progressString.contains("Loading model") {
            generationProgress.stage = "Loading Model"
            generationProgress.currentStep = 10
        } else if progressString.contains("Diffusion Sampling") {
            generationProgress.stage = "Diffusion Sampling"
            if let percentage = extractPercentage(from: progressString) {
                generationProgress.currentStep = 10 + Int(percentage * 60)
            }
        } else if progressString.contains("Volume Decoding") {
            generationProgress.stage = "Volume Decoding"
            if let percentage = extractPercentage(from: progressString) {
                generationProgress.currentStep = 70 + Int(percentage * 20)
            }
        } else if progressString.contains("Extracting mesh") {
            generationProgress.stage = "Extracting Mesh"
            generationProgress.currentStep = 95
        } else {
            generationProgress.stage = progressString
        }
    }
    
    private func extractPercentage(from string: String) -> Double? {
        let pattern = #"(\d+)%"#
        if let regex = try? NSRegularExpression(pattern: pattern),
           let match = regex.firstMatch(in: string, range: NSRange(string.startIndex..., in: string)),
           let percentRange = Range(match.range(at: 1), in: string),
           let percent = Int(string[percentRange]) {
            return Double(percent) / 100.0
        }
        return nil
    }
    
    private func getMaskPath() -> String? {
        guard maskImage != nil else { return nil }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/ModelrV3/mask.png")
            .path
    }
    
    func flushMaskToDisk() {
        guard maskIsDirty, let mask = maskImage else { return }
        
        let maskURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/ModelrV3/mask.png")
        
        guard let tiffData = mask.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData),
              let pngData = bitmap.representation(using: .png, properties: [:]) else {
            return
        }
        
        try? pngData.write(to: maskURL)
        maskIsDirty = false
    }
    
    // MARK: - Re-inference
    
    func triggerReInference() {
        guard !selectedPoints.isEmpty || !boundingBoxes.isEmpty || !lassoSelections.isEmpty else { return }
        guard let path = inputImagePath else { return }
        guard !env.isProcessing else { return }
        
        let effectiveBox: SAMBox? = boundingBoxes.first ?? lassoSelections.first?.boundingBox
        
        let task = Task.detached(priority: .userInitiated) {
            do {
                let pixelSize = try await self.env.setImage(path: path)
                await MainActor.run {
                    guard !Task.isCancelled else { return }
                    self.imagePixelSize = pixelSize
                }
                
                let (maskURLs, primaryMaskURL, scores, confidenceMapURL) = try await self.env.predict(
                    points: self.selectedPoints,
                    box: effectiveBox,
                    imageSize: pixelSize
                )
                
                var loadedMasks: [NSImage] = []
                var loadedPaths: [String] = []
                for url in maskURLs {
                    if let mask = NSImage(contentsOf: url) {
                        loadedMasks.append(mask)
                        loadedPaths.append(url.path)
                    }
                }
                
                if loadedMasks.isEmpty {
                    await MainActor.run {
                        self.env.status = "Error: Failed to load masks"
                    }
                    return
                }
                
                let alphaData = await MainActor.run { self.sourceAlphaData }
                let alphaWidth = await MainActor.run { self.sourceAlphaWidth }
                let alphaHeight = await MainActor.run { self.sourceAlphaHeight }
                
                var processedCache: [Int: NSImage] = [:]
                for (index, mask) in loadedMasks.enumerated() {
                    processedCache[index] = mask
                }
                
                var loadedConfidenceMap: NSImage?
                if let confURL = confidenceMapURL {
                    loadedConfidenceMap = NSImage(contentsOf: confURL)
                }
                
                await MainActor.run {
                    guard !Task.isCancelled else { return }
                    self.maskOptions = loadedMasks
                    self.maskOptionsPaths = loadedPaths
                    self.maskScores = scores
                    self.selectedMaskIndex = 0
                    self.processedMaskCache = processedCache
                    self.maskImage = processedCache[0] ?? loadedMasks.first!
                    
                    if let confMap = loadedConfidenceMap {
                        self.confidenceOverlay = confMap
                    }
                }
            } catch {
                await MainActor.run {
                    guard !Task.isCancelled else { return }
                    self.env.status = "Error: \(error.localizedDescription)"
                }
            }
        }
        
        Task { @MainActor in
            self.currentTasks.insert(task)
        }
    }
}
