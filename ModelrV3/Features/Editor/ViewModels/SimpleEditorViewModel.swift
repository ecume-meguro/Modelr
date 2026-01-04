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
    enum Step { case input, segment, touchup, generate }
    @Published var currentStep: Step = .input
    
    // MARK: - Segmentation State
    @Published var textPrompt: String = ""
    @Published var textSearchPerformed: Bool = false
    @Published var isSegmenting: Bool = false  // True while prediction is running
    @Published var selectedPoints: [SAMPoint] = []
    @Published var useExistingAlpha: Bool = false
    @Published var imageHasAlpha: Bool = false
    @Published var allMasks: [(image: NSImage, score: Double, url: URL)] = []
    @Published var selectedMaskIndex: Int = 0
    
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
    
    // MARK: - Warning Dialogs
    @Published var showBackWarning: Bool = false
    @Published var showDiscardModelWarning: Bool = false
    @Published var showDiscardImageWarning: Bool = false
    @Published var showStartOverWarning: Bool = false
    
    // MARK: - UI State
    @Published var isDragging = false
    
    // MARK: - Generation Types
    enum GenerationStage: String, CaseIterable {
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

        // Clear all previous data
        clearSegmentation()
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
    
    // MARK: - Segmentation
    func runTextPrediction() {
        guard !textPrompt.isEmpty else { return }
        textSearchPerformed = true
        isSegmenting = true
        Task {
            await performTextSearch()
            await MainActor.run { isSegmenting = false }
        }
    }

    private func performTextSearch() async {
        do {
            let (maskURLs, _, scores, _) = try await env.predict(
                points: [],
                box: nil,
                text: textPrompt,
                imageSize: imagePixelSize
            )

            // Load masks from URLs
            var masks: [(image: NSImage, score: Double, url: URL)] = []
            for (url, score) in zip(maskURLs, scores) {
                if let image = NSImage(contentsOf: url) {
                    masks.append((image: image, score: score, url: url))
                }
            }
            await MainActor.run {
                allMasks = masks
                selectedMaskIndex = 0
            }
        } catch {
            print("[Text] Error: \(error)")
        }
    }

    func addPoint(at normalized: CGPoint) {
        let point = SAMPoint(normalizedCoords: normalized.clamped, label: 1)
        selectedPoints.append(point)
        isSegmenting = true
        Task {
            await runPointPrediction()
            await MainActor.run { isSegmenting = false }
        }
    }

    private func runPointPrediction() async {
        guard !selectedPoints.isEmpty else { return }
        do {
            let (maskURLs, _, scores, _) = try await env.predict(
                points: selectedPoints,
                box: nil,
                text: nil,
                imageSize: imagePixelSize
            )

            // Load masks from URLs
            var masks: [(image: NSImage, score: Double, url: URL)] = []
            for (url, score) in zip(maskURLs, scores) {
                if let image = NSImage(contentsOf: url) {
                    masks.append((image: image, score: score, url: url))
                }
            }
            await MainActor.run {
                allMasks = masks
                selectedMaskIndex = 0
            }
        } catch {
            print("[Point] Error: \(error)")
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
            maskPixels[offset + 3] = white  // Alpha must match for SwiftUI mask()
        }
        
        guard let maskCGImage = maskContext.makeImage() else { return }
        let maskNSImage = NSImage(cgImage: maskCGImage, size: NSSize(width: width, height: height))
        
        // Save to temp file
        let tempURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("alpha_mask_\(UUID().uuidString).png")
        
        if let tiff = maskNSImage.tiffRepresentation,
           let bitmap = NSBitmapImageRep(data: tiff),
           let png = bitmap.representation(using: .png, properties: [:]) {
            try? png.write(to: tempURL)
        }
        
        allMasks = [(image: maskNSImage, score: 1.0, url: tempURL)]
        selectedMaskIndex = 0
    }
    
    func clearSegmentation() {
        allMasks.removeAll()
        selectedMaskIndex = 0
        selectedPoints.removeAll()
        textPrompt = ""
        textSearchPerformed = false
        isSegmenting = false
        editableMaskImage = nil
    }
    
    func findMaskAtPoint(_ normalized: CGPoint, displaySize: CGSize) -> Int? {
        for (index, maskData) in allMasks.enumerated().reversed() {
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
        guard selectedMaskIndex < allMasks.count else { return }
        editableMaskImage = allMasks[selectedMaskIndex].image
        maskHistory.removeAll()
        
        withAnimation(.easeOut(duration: 0.25)) {
            currentStep = .touchup
        }
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
        if status.contains("Extracting") {
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
        }
    }
    
    func goBack() {
        withAnimation(.easeOut(duration: 0.2)) {
            switch currentStep {
            case .input:
                break
            case .segment:
                clearSegmentation()
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
            }
        }
    }

    func clearAll() {
        withAnimation(.easeOut(duration: 0.2)) {
            inputImage = nil
            inputImagePath = nil
            allMasks.removeAll()
            selectedMaskIndex = 0
            selectedPoints.removeAll()
            textPrompt = ""
            textSearchPerformed = false
            isSegmenting = false
            useExistingAlpha = false
            imageHasAlpha = false
            editableMaskImage = nil
            maskHistory.removeAll()
            compositeImage = nil
            generated3DModelURL = nil
            generationStages = [:]
            generationStartTime = nil
            generationDuration = nil
            zoomScale = 1.0
            currentStep = .input
        }
    }
    
    // MARK: - Utilities
    func colorForMask(_ index: Int) -> Color {
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
}
