import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @StateObject private var env = PythonEnvironment()

    // Debug mode: auto-load latest 3D model and go to generate tab
    let autoLoadLatest3DModel: Bool

    init(autoLoadLatest3DModel: Bool = false) {
        self.autoLoadLatest3DModel = autoLoadLatest3DModel
    }

    // Image state
    @State private var inputImage: NSImage?
    @State private var inputImagePath: String?
    @State private var maskImage: NSImage?
    @State private var isDragging = false
    @State private var imagePixelSize: CGSize = .zero
    @State private var cachedDisplaySize: CGSize = .zero

    // Multi-mask selection state
    @State private var maskOptions: [NSImage] = []
    @State private var maskScores: [Double] = []
    @State private var selectedMaskIndex: Int = 0
    @State private var maskOptionsPaths: [String] = []
    @State private var processedMaskCache: [Int: NSImage] = [:]  // Pre-processed masks for instant switching

    // Confidence overlay state
    @State private var confidenceOverlay: NSImage?
    @State private var showConfidenceOverlay: Bool = false

    // Real-time paint preview state
    @State private var livePaintMask: NSImage?

    // Alpha channel cache for filtering segmentation on transparent areas
    @State private var sourceAlphaData: [UInt8] = []
    @State private var sourceAlphaWidth: Int = 0
    @State private var sourceAlphaHeight: Int = 0

    // Multi-point state
    @State private var selectedPoints: [SAMPoint] = []
    @State private var boundingBoxes: [SAMBox] = []
    @State private var currentBox: SAMBox?

    // Lasso state
    @State private var lassoSelections: [LassoSelection] = []
    @State private var currentLasso: LassoSelection?

    // Polygon tool state
    @State private var polygonSelections: [PolygonSelection] = []
    @State private var currentPolygon: PolygonSelection?

    // Paint tool state
    @State private var paintStrokes: [PaintStroke] = []
    @State private var currentPaintStroke: PaintStroke?
    @State private var brushSize: CGFloat = 0.03  // Normalized (3% of image width)
    @State private var isErasing: Bool = false
    @State private var brushCursorPosition: CGPoint?  // For brush preview

    // Preprocess state
    @State private var selectedPreprocessTool: PreprocessTool = .crop
    @State private var cropRect: SAMBox?
    @State private var preprocessLasso: LassoSelection?

    // Undo/Redo history
    @State private var undoStack: [UndoAction] = []
    @State private var redoStack: [UndoAction] = []

    // Tool state
    @State private var selectedTool: SAMTool = .point
    @State private var currentStep: WorkflowStep = .input

    // Skip segmentation mode (for pre-cutout images)
    @State private var skipSegmentation: Bool = false

    // Selection state for annotations
    @State private var selectedPointId: UUID?
    @State private var selectedBoxId: UUID?
    @State private var selectedLassoId: UUID?

    // Mask display options
    @State private var maskOpacity: Double = 0.6

    // Zoom state
    @State private var magnification: CGFloat = 1.0

    // Generate state
    @State private var selectedQualityPreset: QualityPreset = .normal
    @State private var generateSteps: Double = 50
    @State private var generateResolution: Double = 256
    @State private var isGenerating = false
    @State private var generationProgress = GenerationProgress()
    @State private var generationStartTime: Date?
    @State private var generated3DModelURL: URL?
    @State private var generationError: String?
    
    // Model selection for 3D generation
    @State private var selectedGeneratorModel: GeneratorModel = .hunyuan

    // Performance optimization: dirty flag for mask to avoid unnecessary file writes
    @State private var maskIsDirty = false

    // Task cancellation support
    @State private var currentTasks: Set<Task<Void, Never>> = []
    
    // State to force UI refresh when image content changes but path stays same
    @State private var imageVersion: Int = 0

    var body: some View {
        VStack(spacing: 0) {
            // Workflow Progress Bar (Header)
            ZStack {
                Color(NSColor.windowBackgroundColor)
                
                WorkflowProgressBar(currentStep: $currentStep, canMoveToNext: canMoveToNextStep)
                    .padding(.vertical, 12)
            }
            .frame(height: 100) // Fixed height for the header area
            .zIndex(1)
            
            Divider()
            
            mainEditorView
        }
        .frame(minWidth: 1000, minHeight: 700)
        .toolbar {
            editorToolbar
        }
        // Re-inference triggers - combined for efficiency
        .onChange(of: selectedPoints.count) { _, _ in triggerReInference() }
        .onChange(of: boundingBoxes.count) { _, _ in triggerReInference() }
        .onChange(of: lassoSelections.count) { _, _ in triggerReInference() }
        // State persistence for step switching
        .onChange(of: currentStep) { oldStep, newStep in
            if oldStep == .segment && newStep != .segment {
                saveSegmentationState()
            }
            if newStep == .segment && oldStep != .segment {
                restoreSegmentationState()
            }
        }
        .background(keyboardShortcuts)
    }

    private var canMoveToNextStep: Bool {
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

    @ToolbarContentBuilder
    private var editorToolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            if inputImage != nil {
                Button(action: clearAll) {
                    Label("New", systemImage: "plus")
                }
                .help("Clear current image")
            }
        }
        
        // Principal item removed as WorkflowProgressBar is now in the main view
        ToolbarItem(placement: .principal) {
            Text("Modelr")
                .font(.headline)
                .foregroundColor(.secondary)
        }
    }

    private var keyboardShortcuts: some View {
        Group {
            // Undo: Cmd+Z
            Button("") { performUndo() }
                .keyboardShortcut("z", modifiers: .command)
                .opacity(0)

            // Redo: Cmd+Shift+Z
            Button("") { performRedo() }
                .keyboardShortcut("z", modifiers: [.command, .shift])
                .opacity(0)

            // Tool shortcuts (1-4)
            Button("") { if currentStep == .segment { selectedTool = .point } }
                .keyboardShortcut("1", modifiers: [])
                .opacity(0)

            Button("") { if currentStep == .segment { selectedTool = .boundingBox } }
                .keyboardShortcut("2", modifiers: [])
                .opacity(0)

            Button("") { if currentStep == .segment { selectedTool = .lasso } }
                .keyboardShortcut("3", modifiers: [])
                .opacity(0)

            Button("") { if currentStep == .segment { selectedTool = .paint } }
                .keyboardShortcut("4", modifiers: [])
                .opacity(0)

            Button("") { if currentStep == .segment { selectedTool = .polygon } }
                .keyboardShortcut("5", modifiers: [])
                .opacity(0)

            // Delete selected annotation: Backspace/Delete
            Button("") { deleteSelectedAnnotation() }
                .keyboardShortcut(.delete, modifiers: [])
                .opacity(0)

            // Cancel polygon drawing: Escape
            Button("") { cancelPolygon() }
                .keyboardShortcut(.escape, modifiers: [])
                .opacity(0)

            // Toggle erase mode: E
            Button("") { if selectedTool == .paint { isErasing.toggle() } }
                .keyboardShortcut("e", modifiers: [])
                .opacity(0)
        }
    }

    // MARK: - Main Editor View

    var mainEditorView: some View {
        HSplitView {
            // Left: Image area (70%)
            imageArea
                .frame(minWidth: 500)

            // Right: Sidebar (30%)
            sidebarView
                .frame(minWidth: 280, maxWidth: 350)
        }
    }

    // MARK: - Image Area

    // Compute display size for the image (reasonable default size)
    private var displaySize: CGSize {
        if cachedDisplaySize != .zero {
            return cachedDisplaySize
        }

        guard let inputImage = inputImage else { return CGSize(width: 800, height: 600) }
        let imageSize = inputImage.size
        let aspectRatio = imageSize.width / imageSize.height

        // Use a reasonable base size that fits well in the view
        let baseHeight: CGFloat = 600
        let baseWidth = baseHeight * aspectRatio

        let size = CGSize(width: baseWidth, height: baseHeight)
        cachedDisplaySize = size
        return size
    }

    // Map current step/tool to SAMTool for ZoomableImageView
    private var effectiveToolMode: SAMTool {
        switch currentStep {
        case .input:
            return .point // Not used
        case .refine:
            // Map refine tools to equivalent SAMTool gestures
            switch selectedPreprocessTool {
            case .crop:
                return .boundingBox  // Uses drag for rectangle
            case .polygonCrop:
                return .lasso  // Uses lasso gesture
            }
        case .segment:
            return selectedTool
        case .generate:
            return .point  // Default, not really used in generate tab
        }
    }

    var imageArea: some View {
        ZStack {
            Color(NSColor.windowBackgroundColor).opacity(0.5)

            if currentStep == .input && inputImage == nil {
                dropZoneView
            }
            // Show 3D viewer only on Generate tab when we have a model
            else if currentStep == .generate, let modelURL = generated3DModelURL, !isGenerating {
                model3DViewer(url: modelURL)
            }
            // Show generation progress during generation (only on Generate tab)
            else if currentStep == .generate && isGenerating {
                generationProgressView
            }
            // Show image editor for Preprocess/Segment tabs, or Generate tab without a model
            else if let inputImage = inputImage {
                ZoomableImageView(
                    magnification: $magnification,
                    onTap: { normalized in
                        handleTap(at: normalized, isNegative: false)
                    },
                    onOptionTap: { normalized in
                        handleTap(at: normalized, isNegative: true)
                    },
                    onRightClick: { normalized in
                        handleRightClick(at: normalized)
                    },
                    onDragStart: { point in
                        handleDragStart(at: point)
                    },
                    onDragChange: { start, current in
                        handleDragChange(start: start, current: current)
                    },
                    onDragEnd: { start, end in
                        handleDragEnd(start: start, end: end)
                    },
                    onPaintStart: { point in
                        handlePaintStart(at: point)
                    },
                    onPaintContinue: { point in
                        handlePaintContinue(at: point)
                    },
                    onPaintEnd: {
                        handlePaintEnd()
                    },
                    onLassoStart: { point in
                        handleLassoStart(at: point)
                    },
                    onLassoContinue: { point in
                        handleLassoContinue(at: point)
                    },
                    onLassoEnd: {
                        handleLassoEnd()
                    },
                    onMouseMoved: { point in
                        brushCursorPosition = point
                    },
                    onMouseExited: {
                        brushCursorPosition = nil
                    },
                    toolMode: effectiveToolMode,
                    contentSize: displaySize,
                    contentID: "\(inputImagePath ?? "")_v\(imageVersion)"
                ) {
                    ZStack {
                        Image(nsImage: inputImage)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: displaySize.width, height: displaySize.height)

                        // Only show mask in segment/generate modes (or skip segmentation mode)
                        if currentStep != .refine && currentStep != .input, let maskImage = maskImage {
                            Image(nsImage: maskImage)
                                .resizable()
                                .frame(width: displaySize.width, height: displaySize.height)
                                .allowsHitTesting(false)
                                .opacity(maskOpacity)
                        }

                        // Live paint preview (shows mask while painting)
                        if currentStep == .segment, selectedTool == .paint, let liveMask = livePaintMask {
                            Image(nsImage: liveMask)
                                .resizable()
                                .frame(width: displaySize.width, height: displaySize.height)
                                .allowsHitTesting(false)
                                .opacity(maskOpacity * 0.8)
                        }

                        // Confidence overlay (shows per-pixel uncertainty heatmap from SAM2 logits)
                        if currentStep != .refine && currentStep != .input, showConfidenceOverlay, let confidence = confidenceOverlay {
                            Image(nsImage: confidence)
                                .resizable()
                                .frame(width: displaySize.width, height: displaySize.height)
                                .blendMode(.screen)
                                .opacity(0.6)
                                .allowsHitTesting(false)
                        }

                        // Paint strokes overlay (segment mode)
                        if currentStep == .segment {
                            PaintStrokeOverlay(
                                strokes: paintStrokes,
                                currentStroke: currentPaintStroke,
                                displayedSize: displaySize
                            )
                            .frame(width: displaySize.width, height: displaySize.height)
                        }

                        // Lasso overlay for segment mode
                        if currentStep == .segment && selectedTool == .lasso {
                            LassoOverlay(
                                lassoSelections: lassoSelections,
                                currentLasso: currentLasso,
                                displayedSize: displaySize,
                                isPreprocessMode: false
                            )
                            .frame(width: displaySize.width, height: displaySize.height)
                        }

                        // Polygon overlay for segment mode - always show completed polygons, show current only in polygon mode
                        if currentStep == .segment && !skipSegmentation {
                            PolygonOverlay(
                                polygons: polygonSelections,
                                currentPolygon: selectedTool == .polygon ? currentPolygon : nil,
                                displayedSize: displaySize
                            )
                            .frame(width: displaySize.width, height: displaySize.height)
                        }

                        // Preprocess overlays
                        if currentStep == .refine {
                            if selectedPreprocessTool == .crop {
                                CropOverlay(cropRect: cropRect, displayedSize: displaySize)
                                    .frame(width: displaySize.width, height: displaySize.height)
                            } else if selectedPreprocessTool == .polygonCrop {
                                LassoOverlay(
                                    lassoSelections: [],
                                    currentLasso: preprocessLasso,
                                    displayedSize: displaySize,
                                    isPreprocessMode: true
                                )
                                .frame(width: displaySize.width, height: displaySize.height)
                            }
                        }

                        // Points overlay (segment mode) - supports tap to select, drag to move
                        if currentStep == .segment && !skipSegmentation {
                            PointsOverlay(
                                points: selectedPoints,
                                displayedSize: displaySize,
                                selectedPointId: selectedPointId,
                                onPointTap: { point in
                                    if selectedPointId == point.id {
                                        selectedPointId = nil
                                    } else {
                                        selectedPointId = point.id
                                        selectedBoxId = nil
                                        selectedLassoId = nil
                                    }
                                },
                                onPointDragEnd: { originalPoint, newPosition in
                                    handlePointDragEnd(point: originalPoint, newPosition: newPosition)
                                }
                            )
                            .frame(width: displaySize.width, height: displaySize.height)
                        }

                        // Bounding box overlay (segment mode)
                        if currentStep == .segment && !skipSegmentation {
                            BoundingBoxOverlay(
                                boxes: boundingBoxes,
                                currentBox: currentBox,
                                displayedSize: displaySize,
                                imagePixelSize: imagePixelSize,
                                selectedBoxId: selectedBoxId,
                                onBoxTap: { box in
                                    if selectedBoxId == box.id {
                                        selectedBoxId = nil
                                    } else {
                                        selectedBoxId = box.id
                                        selectedPointId = nil
                                        selectedLassoId = nil
                                    }
                                }
                            )
                            .frame(width: displaySize.width, height: displaySize.height)
                        }

                        // Brush cursor preview (segment paint mode)
                        if currentStep == .segment && selectedTool == .paint {
                            BrushCursorPreview(
                                brushSize: brushSize,
                                isErasing: isErasing,
                                displayedSize: displaySize,
                                cursorPosition: brushCursorPosition
                            )
                            .frame(width: displaySize.width, height: displaySize.height)
                        }
                    }
                    .frame(width: displaySize.width, height: displaySize.height)
                }
                .zoomControls(magnification: $magnification)
            } else {
                dropZoneView
            }
        }
        .onPasteCommand(of: [.image, .png, .jpeg, .tiff, .fileURL]) { providers in
            handlePaste(providers: providers)
        }
    }

    // MARK: - Generation Progress View

    var generationProgressView: some View {
        VStack(spacing: 24) {
            Spacer()

            // Animated cube icon
            Image(systemName: "cube.fill")
                .font(.system(size: 64))
                .foregroundStyle(
                    LinearGradient(
                        colors: [.blue, .purple],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .symbolEffect(.pulse, options: .repeating)

            VStack(spacing: 8) {
                Text("Generating 3D Model")
                    .font(.title2.bold())

                if !generationProgress.stage.isEmpty {
                    Text(generationProgress.stage)
                        .font(.headline)
                        .foregroundColor(.secondary)
                }
            }

            // Progress bar
            if generationProgress.isActive {
                VStack(spacing: 12) {
                    // Progress bar
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 6)
                                .fill(Color.gray.opacity(0.2))
                                .frame(height: 12)

                            RoundedRectangle(cornerRadius: 6)
                                .fill(
                                    LinearGradient(
                                        colors: [.blue, .purple],
                                        startPoint: .leading,
                                        endPoint: .trailing
                                    )
                                )
                                .frame(width: geo.size.width * CGFloat(generationProgress.percentComplete / 100), height: 12)
                                .animation(.easeInOut(duration: 0.3), value: generationProgress.percentComplete)
                        }
                    }
                    .frame(height: 12)
                    .frame(maxWidth: 400)

                    // Progress details
                    HStack(spacing: 20) {
                        // Percentage
                        Text(String(format: "%.0f%%", generationProgress.percentComplete))
                            .font(.system(.title3, design: .monospaced).bold())
                            .foregroundColor(.primary)

                        // Step count
                        Text("\(generationProgress.currentStep)/\(generationProgress.totalSteps)")
                            .font(.system(.body, design: .monospaced))
                            .foregroundColor(.secondary)

                        // Speed
                        if !generationProgress.formattedSpeed.isEmpty {
                            HStack(spacing: 4) {
                                Image(systemName: "speedometer")
                                Text(generationProgress.formattedSpeed)
                            }
                            .font(.system(.body, design: .monospaced))
                            .foregroundColor(.secondary)
                        }

                        // ETA
                        if !generationProgress.formattedETA.isEmpty {
                            HStack(spacing: 4) {
                                Image(systemName: "clock")
                                Text(generationProgress.formattedETA)
                            }
                            .font(.system(.body, design: .monospaced))
                            .foregroundColor(.secondary)
                        }
                    }
                }
                .padding(.horizontal, 40)
            } else {
                // Loading indicator when no detailed progress available
                ProgressView()
                    .scaleEffect(1.5)
                    .padding()

                Text("Preparing...")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }

            // Elapsed time
            if let startTime = generationStartTime {
                let elapsed = Date().timeIntervalSince(startTime)
                Text(formatElapsedTime(elapsed))
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - 3D Model Viewer

    func model3DViewer(url: URL) -> some View {
        VStack(spacing: 0) {
            // Header with back button
            HStack {
                Button(action: {
                    // Go back to image editing
                    generated3DModelURL = nil
                }) {
                    HStack(spacing: 6) {
                        Image(systemName: "chevron.left")
                        Text("Back to Image")
                    }
                    .font(.subheadline)
                }
                .buttonStyle(.bordered)

                Spacer()

                Text("3D Model Preview")
                    .font(.headline)
                    .foregroundColor(.secondary)

                Spacer()

                // Export button placeholder
                Button(action: {
                    // TODO: Export functionality
                    NSWorkspace.shared.selectFile(url.path, inFileViewerRootedAtPath: url.deletingLastPathComponent().path)
                }) {
                    HStack(spacing: 6) {
                        Image(systemName: "square.and.arrow.up")
                        Text("Show in Finder")
                    }
                    .font(.subheadline)
                }
                .buttonStyle(.bordered)
            }
            .padding()
            .background(Color(NSColor.windowBackgroundColor).opacity(0.9))

            // Full 3D viewer
            ModelViewerContainer(modelURL: url)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var estimatedGenerationTime: String {
        // Rough estimate: 1 second per step at 256 res, more for higher res
        let baseTime = generateSteps * (generateResolution / 256.0)
        let seconds = Int(baseTime)
        if seconds < 60 {
            return "\(seconds)s"
        } else {
            return "\(seconds / 60)m \(seconds % 60)s"
        }
    }

    private func formatElapsedTime(_ elapsed: TimeInterval) -> String {
        let minutes = Int(elapsed) / 60
        let seconds = Int(elapsed) % 60
        if minutes > 0 {
            return String(format: "Elapsed: %d:%02d", minutes, seconds)
        } else {
            return String(format: "Elapsed: %ds", seconds)
        }
    }

    // MARK: - Sidebar View

    var sidebarView: some View {
        VStack(spacing: 0) {
            // Tab content
            ScrollView {
                switch currentStep {
                case .input:
                    EmptyView() // Input content is shown in drop zone
                case .refine:
                    preprocessTabContent
                case .segment:
                    segmentTabContent
                case .generate:
                    generateTabContent
                }
            }
            .disabled(inputImage == nil && currentStep != .input)
            .opacity(inputImage == nil && currentStep != .input ? 0.6 : 1.0)

            Divider()

            // Status footer with undo/redo
            enhancedStatusFooter
        }
        .background(.ultraThinMaterial)
    }

    var inputTabContent: some View {
        VStack(spacing: 0) {
            Spacer()
            
            // Hero section with icon and text
            VStack(spacing: 20) {
                // Animated icon
                ZStack {
                    Circle()
                        .fill(
                            LinearGradient(
                                colors: [Color.accentColor.opacity(0.15), Color.purple.opacity(0.1)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 120, height: 120)
                    
                    Image(systemName: "photo.on.rectangle.angled")
                        .font(.system(size: 48, weight: .light))
                        .foregroundStyle(
                            LinearGradient(
                                colors: [.accentColor, .purple],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .symbolEffect(.pulse, options: .repeating.speed(0.5))
                }
                
                VStack(spacing: 8) {
                    Text("Start with an Image")
                        .font(.title2.bold())
                    
                    Text("Drag and drop, paste, or select an image to begin creating your 3D model.")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 280)
                }
            }
            
            Spacer()
                .frame(height: 32)
            
            // Action buttons
            VStack(spacing: 12) {
                Button(action: selectImage) {
                    HStack(spacing: 10) {
                        Image(systemName: "folder")
                        Text("Select Image")
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                
                HStack(spacing: 16) {
                    Button(action: pasteFromClipboard) {
                        HStack(spacing: 6) {
                            Image(systemName: "doc.on.clipboard")
                            Text("Paste")
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.regular)
                    
                    Button(action: {}) {
                        HStack(spacing: 6) {
                            Image(systemName: "camera")
                            Text("Camera")
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.regular)
                    .disabled(true)
                }
            }
            .padding(.horizontal, 24)
            
            Spacer()
            
            // Examples section
            VStack(alignment: .leading, spacing: 12) {
                Divider()
                    .padding(.horizontal)
                
                Text("Try an Example")
                    .font(.headline)
                    .foregroundColor(.secondary)
                    .padding(.horizontal)
                
                exampleImagesGallery
                    .padding(.bottom, 8)
            }
        }
        .padding(.vertical)
    }

    var dropZoneView: some View {
        ZStack {
            // Drop zone overlay
            if isDragging {
                RoundedRectangle(cornerRadius: 16)
                    .strokeBorder(
                        LinearGradient(
                            colors: [.accentColor, .purple],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        style: StrokeStyle(lineWidth: 3, dash: [10, 5])
                    )
                    .background(
                        RoundedRectangle(cornerRadius: 16)
                            .fill(Color.accentColor.opacity(0.1))
                    )
                    .padding(20)
                    .transition(.opacity)
            }
            
            inputTabContent
        }
        .animation(.easeInOut(duration: 0.2), value: isDragging)
    }

    var exampleImagesGallery: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                ForEach([
                    ("Toy", "example_000.png", "🧸"),
                    ("Character", "example_002.png", "🎭"),
                    ("Statue", "004.png", "🗿"),
                    ("Object", "052.png", "📦")
                ], id: \.1) { item in
                    Button(action: { loadExample(item.1) }) {
                        VStack(spacing: 8) {
                            ZStack {
                                if let image = loadExampleThumbnail(item.1) {
                                    Image(nsImage: image)
                                        .resizable()
                                        .aspectRatio(contentMode: .fill)
                                        .frame(width: 72, height: 72)
                                        .clipShape(RoundedRectangle(cornerRadius: 10))
                                } else {
                                    RoundedRectangle(cornerRadius: 10)
                                        .fill(Color.gray.opacity(0.2))
                                        .frame(width: 72, height: 72)
                                        .overlay {
                                            Text(item.2)
                                                .font(.title)
                                        }
                                }
                            }
                            .shadow(color: .black.opacity(0.1), radius: 4, y: 2)
                            
                            Text(item.0)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                    .scaleEffect(1.0)
                    .animation(.spring(response: 0.3), value: isDragging)
                }
            }
            .padding(.horizontal)
        }
    }


    private func loadExampleThumbnail(_ filename: String) -> NSImage? {
        let path = "/Users/zimengx/Code/MacOS_Utilities/Modelr/v3/Hunyuan3D-2/assets/example_images/\(filename)"
        return NSImage(contentsOfFile: path)
    }

    private func loadExample(_ filename: String) {
        let path = "/Users/zimengx/Code/MacOS_Utilities/Modelr/v3/Hunyuan3D-2/assets/example_images/\(filename)"
        guard let image = NSImage(contentsOfFile: path) else { return }
        
        inputImage = image
        // Reset state for new image
        maskImage = nil
        generated3DModelURL = nil
        
        // Auto-advance to next step
        withAnimation {
            currentStep = .refine
        }
    }

    // MARK: - Preprocess Tab

    var preprocessTabContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            // AI Automation
            VStack(alignment: .leading, spacing: 8) {
                Text("AI Automation")
                    .font(.headline)
                    .foregroundColor(.secondary)
                
                Button(action: autoRemoveBackground) {
                    Label("Remove Background", systemImage: "wand.and.stars")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.purple)
                .disabled(env.isProcessing)
                
                Text("Automatically isolate the primary object.")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }

            Divider()

            // Tool Selection
            VStack(alignment: .leading, spacing: 8) {
                Text("Manual Refinement")
                    .font(.headline)
                    .foregroundColor(.secondary)

                Picker("Tool", selection: $selectedPreprocessTool) {
                    ForEach(PreprocessTool.allCases) { tool in
                        Label(tool.rawValue, systemImage: tool.iconName)
                            .tag(tool)
                    }
                }
                .pickerStyle(.segmented)
            }

            Divider()

            // Tool-specific controls
            if selectedPreprocessTool == .crop {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Crop Image")
                        .font(.headline)
                        .foregroundColor(.secondary)

                    Text("Draw a rectangle on the image to define the crop area.")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    if cropRect != nil {
                        HStack(spacing: 8) {
                            Button(action: applyCrop) {
                                Label("Apply Crop", systemImage: "checkmark.circle")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.borderedProminent)

                            Button(action: clearCrop) {
                                Label("Clear", systemImage: "xmark.circle")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.bordered)
                        }
                    } else {
                        Text("No crop area selected")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .italic()
                    }
                }
            } else if selectedPreprocessTool == .polygonCrop {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Polygon Crop")
                        .font(.headline)
                        .foregroundColor(.secondary)

                    Text("Draw a freeform selection. Everything outside will be removed.")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    if preprocessLasso != nil && (preprocessLasso?.isValid ?? false) {
                        HStack(spacing: 8) {
                            Button(action: applyPolygonCrop) {
                                Label("Crop to Selection", systemImage: "crop")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(.blue)

                            Button(action: clearPreprocessLasso) {
                                Label("Clear", systemImage: "xmark.circle")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.bordered)
                        }
                    } else {
                        Text("No selection drawn")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .italic()
                    }
                }
            }

            Divider()

            // Instructions
            VStack(alignment: .leading, spacing: 8) {
                Text("Instructions")
                    .font(.headline)
                    .foregroundColor(.secondary)

                Group {
                    switch selectedPreprocessTool {
                    case .crop:
                        Text("• Drag to draw a crop rectangle")
                        Text("• Click Apply to crop the image")
                        Text("• Use Cmd+Z to undo")
                    case .polygonCrop:
                        Text("• Drag to draw a selection")
                        Text("• Click Crop to keep only the selected area")
                        Text("• Use Cmd+Z to undo")
                    }
                }
                .font(.caption)
                .foregroundColor(.secondary)
            }

            Spacer()

            // Next step hint
            VStack(spacing: 8) {
                Text("When done refining, proceed to segmentation.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)

                Button(action: moveToNextStep) {
                    Label("Proceed to Segment", systemImage: "arrow.right")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(!canMoveToNextStep)
            }
        }
        .padding()
    }

    // MARK: - Multi-Mask Selection View
    @ViewBuilder
    private var multiMaskSelectionView: some View {
        Divider()

        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Mask Options")
                    .font(.headline)
                    .foregroundColor(.secondary)
                Spacer()
                Text("\(maskOptions.count) found")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            ForEach(0..<maskOptions.count, id: \.self) { index in
                maskOptionRow(index: index)
            }

            Button(action: clearMaskOptions) {
                Label("Clear Masks", systemImage: "xmark.circle")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
        }
    }

    @ViewBuilder
    private func maskOptionRow(index: Int) -> some View {
        Button(action: { selectMask(at: index) }) {
            HStack(spacing: 8) {
                maskScoreIndicator(index: index)
                maskPreviewThumbnail(index: index)
                maskScoreText(index: index)
                Spacer()
                selectionCheckmark(index: index)
            }
            .padding(8)
            .background(selectedMaskIndex == index ? Color.accentColor.opacity(0.1) : Color.clear)
            .cornerRadius(8)
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func maskScoreIndicator(index: Int) -> some View {
        ZStack {
            Circle()
                .stroke(Color.gray.opacity(0.3), lineWidth: 2)
                .frame(width: 24, height: 24)

            Circle()
                .trim(from: 0, to: maskScores[safe: index] ?? 0)
                .stroke(
                    Color(red: 1.0 - (maskScores[safe: index] ?? 0),
                          green: (maskScores[safe: index] ?? 0),
                          blue: 0),
                    style: StrokeStyle(lineWidth: 2, lineCap: .round)
                )
                .frame(width: 24, height: 24)
                .rotationEffect(.degrees(-90))

            Text("\(index + 1)")
                .font(.caption2)
                .fontWeight(.bold)
        }
    }

    @ViewBuilder
    private func maskPreviewThumbnail(index: Int) -> some View {
        Group {
            if let image = maskOptions[safe: index] {
                Image(nsImage: image)
                    .resizable()
                    .frame(width: 32, height: 32)
                    .cornerRadius(4)
                    .scaleEffect(1.0)
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .stroke(selectedMaskIndex == index ? Color.accentColor : Color.clear, lineWidth: 2)
                    )
            }
        }
    }

    @ViewBuilder
    private func maskScoreText(index: Int) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Mask \(index + 1)")
                .font(.caption)
                .fontWeight(selectedMaskIndex == index ? .semibold : .regular)
            Text(String(format: "Score: %.2f", maskScores[safe: index] ?? 0))
                .font(.caption2)
                .foregroundColor(.secondary)
        }
    }

    @ViewBuilder
    private func selectionCheckmark(index: Int) -> some View {
        Group {
            if selectedMaskIndex == index {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.accentColor)
            }
        }
    }

    // MARK: - Segment Tab

    private var toolDescription: String {
        switch selectedTool {
        case .point: return "Click to add points. Option-click to exclude."
        case .boundingBox: return "Drag a box around the object."
        case .lasso: return "Draw freeform around the object."
        case .paint: return "Paint to refine the mask."
        case .polygon: return "Click to add polygon vertices."
        }
    }

    var segmentTabContent: some View {
        VStack(alignment: .leading, spacing: 20) {
            // Header with skip toggle
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Segmentation")
                        .font(.title3.bold())
                    Text("Select the object to extract")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                
                Spacer()
                
                Toggle("", isOn: $skipSegmentation)
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .help("Skip segmentation if image is already cut out")
                    .onChange(of: skipSegmentation) { _, newValue in
                        if newValue {
                            createFullImageMask()
                        } else {
                            maskImage = nil
                        }
                    }
            }
            .padding()
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(.ultraThinMaterial)
            )

            if !skipSegmentation {
                // Tool Grid
                VStack(alignment: .leading, spacing: 10) {
                    Text("Tools")
                        .font(.headline)
                        .foregroundColor(.secondary)
                    
                    LazyVGrid(columns: [
                        GridItem(.flexible()),
                        GridItem(.flexible()),
                        GridItem(.flexible())
                    ], spacing: 8) {
                        ForEach(SAMTool.allCases) { tool in
                            ToolButton(
                                tool: tool,
                                isSelected: selectedTool == tool,
                                action: { selectedTool = tool }
                            )
                        }
                    }
                    
                    // Tool hint
                    Text(toolDescription)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 4)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                // Paint Tool Options
                if selectedTool == .paint {
                    paintToolOptions
                }

                // Mask Visibility
                VStack(alignment: .leading, spacing: 8) {
                    Text("Mask")
                        .font(.headline)
                        .foregroundColor(.secondary)
                    
                    HStack(spacing: 12) {
                        Image(systemName: "eye.slash")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Slider(value: $maskOpacity, in: 0...1)
                        Image(systemName: "eye")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    
                    // Confidence toggle if available
                    if !maskScores.isEmpty {
                        Toggle(isOn: $showConfidenceOverlay) {
                            Label("Confidence Overlay", systemImage: "chart.bar.fill")
                                .font(.subheadline)
                        }
                        .toggleStyle(.switch)
                        .tint(.orange)
                    }
                }

                // Multi-Mask Selection
                if !maskOptions.isEmpty {
                    multiMaskSelectionView
                }

                // Annotations Summary
                annotationsSummary

            } else {
                // Skip mode
                VStack(spacing: 16) {
                    ZStack {
                        Circle()
                            .fill(Color.green.opacity(0.15))
                            .frame(width: 80, height: 80)
                        
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 40))
                            .foregroundColor(.green)
                    }

                    Text("Ready for Generation")
                        .font(.headline)

                    Text("Using pre-cutout image directly")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 32)
            }

            Spacer()

            // Action buttons
            VStack(spacing: 12) {
                Button(action: moveToNextStep) {
                    HStack {
                        Text("Continue to Generate")
                        Image(systemName: "arrow.right")
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(!canMoveToNextStep)
                
                Button(action: clearAll) {
                    Label("Start Over", systemImage: "arrow.counterclockwise")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .foregroundColor(.red)
            }
        }
        .padding()
    }
    
    private var paintToolOptions: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Brush")
                .font(.headline)
                .foregroundColor(.secondary)

            // Brush size
            HStack {
                Image(systemName: "circle")
                    .font(.system(size: 8))
                Slider(value: $brushSize, in: 0.01...0.15, step: 0.005)
                Image(systemName: "circle.fill")
                    .font(.system(size: 16))
            }
            .foregroundColor(.secondary)

            // Mode toggle
            HStack {
                Button(action: { isErasing = false }) {
                    Label("Add", systemImage: "plus.circle.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .tint(isErasing ? .secondary : .blue)
                .opacity(isErasing ? 0.6 : 1.0)
                
                Button(action: { isErasing = true }) {
                    Label("Erase", systemImage: "minus.circle.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .tint(isErasing ? .red : .secondary)
                .opacity(isErasing ? 1.0 : 0.6)
            }
            .controlSize(.small)

            if !paintStrokes.isEmpty {
                Button(action: clearPaintStrokes) {
                    Label("Clear Strokes", systemImage: "xmark.circle")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.secondary.opacity(0.1))
        )
    }
    
    private var annotationsSummary: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Annotations")
                    .font(.headline)
                    .foregroundColor(.secondary)
                
                Spacer()
                
                if hasSelection {
                    Button(action: deleteSelectedAnnotation) {
                        Image(systemName: "trash")
                            .font(.caption)
                    }
                    .buttonStyle(.borderless)
                    .foregroundColor(.red)
                }
            }

            HStack(spacing: 16) {
                annotationBadge(
                    count: selectedPoints.filter { $0.isPositive }.count,
                    icon: "plus.circle.fill",
                    color: .green
                )
                annotationBadge(
                    count: selectedPoints.filter { $0.isNegative }.count,
                    icon: "minus.circle.fill",
                    color: .red
                )
                annotationBadge(
                    count: boundingBoxes.count,
                    icon: "rectangle.dashed",
                    color: .blue
                )
                annotationBadge(
                    count: lassoSelections.count + paintStrokes.count,
                    icon: "scribble",
                    color: .purple
                )
            }

            if !selectedPoints.isEmpty || !boundingBoxes.isEmpty || !lassoSelections.isEmpty || !paintStrokes.isEmpty {
                Button(action: clearAnnotations) {
                    Label("Clear All", systemImage: "trash")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
    }
    
    @ViewBuilder
    private func annotationBadge(count: Int, icon: String, color: Color) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .foregroundColor(color)
            Text("\(count)")
                .font(.caption.bold())
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(color.opacity(0.1))
        .cornerRadius(6)
    }

    private var hasSelection: Bool {
        selectedPointId != nil || selectedBoxId != nil || selectedLassoId != nil
    }

    // MARK: - Generate Tab

    var generateTabContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Prerequisites check
            if maskImage == nil {
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 32))
                        .foregroundColor(.orange)
                    Text("Segment First")
                        .font(.headline)
                    Text("Use the Segment tab to select an object before generating a 3D model.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 40)
            } else {
                // Model Selection (Hunyuan3D-2 only)
                VStack(alignment: .leading, spacing: 8) {
                    Text("Hunyuan3D-2")
                        .font(.headline)
                    
                    Text(GeneratorModel.hunyuan.description)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }

                Divider()

                // Quality Presets
                VStack(alignment: .leading, spacing: 8) {
                    Text("Quality Preset")
                        .font(.headline)
                        .foregroundColor(.secondary)
                    
                    Picker("Quality", selection: $selectedQualityPreset) {
                        ForEach(QualityPreset.allCases) { preset in
                            Text(preset.rawValue).tag(preset)
                        }
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: selectedQualityPreset) { _, newValue in
                        generateSteps = Double(newValue.steps)
                        generateResolution = Double(newValue.resolution)
                    }
                    
                    Text(selectedQualityPreset.description)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .italic()
                        .padding(.top, 4)
                }

                Divider()

                // Advanced Parameters (Collapsible)
                DisclosureGroup("Advanced Parameters") {
                    VStack(alignment: .leading, spacing: 12) {
                        // Steps slider
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text("Diffusion Steps")
                                Spacer()
                                Text("\(Int(generateSteps))")
                                    .foregroundColor(.secondary)
                            }
                            .font(.subheadline)

                            Slider(value: $generateSteps, in: 10...256, step: 1)
                        }

                        // Resolution slider
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text("Mesh Resolution")
                                Spacer()
                                Text("\(Int(generateResolution))")
                                    .foregroundColor(.secondary)
                            }
                            .font(.subheadline)

                            Slider(value: $generateResolution, in: 64...1024, step: 64)
                        }
                    }
                    .padding(.top, 8)
                }
                .font(.subheadline)

                Divider()

                // Estimated Time
                HStack {
                    Image(systemName: "clock")
                    Text("Estimated time: \(estimatedGenerationTime)")
                }
                .font(.caption)
                .foregroundColor(.secondary)

                Spacer()

                // Generate button
                VStack(spacing: 12) {
                    Button(action: startGeneration) {
                        HStack {
                            if isGenerating {
                                ProgressView()
                                    .scaleEffect(0.8)
                                    .frame(width: 16, height: 16)
                            } else {
                                Image(systemName: "cube.fill")
                            }
                            Text(isGenerating ? "Generating..." : "Generate 3D Model")
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 4)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isGenerating)
                }

                // Status messages
                if isGenerating {
                    Divider()
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Status")
                            .font(.headline)
                            .foregroundColor(.secondary)

                        HStack {
                            Image(systemName: "info.circle")
                                .foregroundColor(.blue)
                            Text("See progress in the left pane")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                } else if generated3DModelURL != nil {
                    Divider()
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundColor(.green)
                            Text("Generation Complete")
                                .font(.subheadline.bold())
                        }

                        Text("View your 3D model in the left pane. Click 'Back to Image' to return to editing.")
                            .font(.caption)
                            .foregroundColor(.secondary)

                        Button(action: {
                            generated3DModelURL = nil
                        }) {
                            Label("New Generation", systemImage: "arrow.counterclockwise")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                    }
                } else if let error = generationError {
                    Divider()
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundColor(.red)
                            Text("Generation Failed")
                                .font(.headline)
                                .foregroundColor(.red)
                        }

                        Text(error)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }
            
            Spacer()
        }
        .padding()
    }

    // MARK: - Status Footer

    var statusFooter: some View {
        HStack {
            if env.isProcessing {
                ProgressView()
                    .scaleEffect(0.6)
                    .frame(width: 12, height: 12)
            }
            Text(env.status)
                .font(.caption)
                .foregroundColor(.secondary)
                .lineLimit(1)
            Spacer()
        }
        .padding(8)
    }

    // MARK: - Enhanced Status Footer with Undo/Redo

    var enhancedStatusFooter: some View {
        HStack(spacing: 12) {
            // Undo/Redo buttons
            HStack(spacing: 4) {
                Button(action: performUndo) {
                    Image(systemName: "arrow.uturn.backward")
                        .font(.system(size: 12))
                }
                .buttonStyle(.borderless)
                .disabled(undoStack.isEmpty)
                .help("Undo (Cmd+Z)")

                Button(action: performRedo) {
                    Image(systemName: "arrow.uturn.forward")
                        .font(.system(size: 12))
                }
                .buttonStyle(.borderless)
                .disabled(redoStack.isEmpty)
                .help("Redo (Cmd+Shift+Z)")

                if !undoStack.isEmpty || !redoStack.isEmpty {
                    Text("\(undoStack.count)")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Color.secondary.opacity(0.2))
                        .cornerRadius(3)
                }
            }

            Divider()
                .frame(height: 16)

            // Status
            if env.isProcessing {
                ProgressView()
                    .scaleEffect(0.6)
                    .frame(width: 12, height: 12)
            }
            Text(env.status)
                .font(.caption)
                .foregroundColor(.secondary)
                .lineLimit(1)

            Spacer()

            // Image dimensions
            if imagePixelSize != .zero {
                Text("\(Int(imagePixelSize.width))×\(Int(imagePixelSize.height))")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.secondary)
            }

            if canMoveToNextStep {
                Button(action: moveToNextStep) {
                    HStack {
                        Text(nextStepButtonTitle)
                        Image(systemName: "chevron.right")
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 4)
                }
                .buttonStyle(.borderedProminent)
                .tint(.blue)
                .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var nextStepButtonTitle: String {
        switch currentStep {
        case .input: return "Proceed to Refine"
        case .refine: return "Proceed to Segment"
        case .segment: return "Proceed to Generate"
        case .generate: return "Done"
        }
    }

    private func moveToNextStep() {
        guard let next = WorkflowStep(rawValue: currentStep.rawValue + 1) else { return }
        withAnimation(.spring()) {
            currentStep = next
        }
    }

    // MARK: - File Picker

    private func selectImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image, .png, .jpeg, .tiff, .bmp, .gif, .webP]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "Choose an image to segment"

        if panel.runModal() == .OK, let url = panel.url {
            loadImage(from: url)
        }
    }

    // MARK: - Paste Handler

    private func pasteFromClipboard() {
        let pasteboard = NSPasteboard.general
        
        // Try to get image data from clipboard
        if let imageData = pasteboard.data(forType: .tiff) ?? pasteboard.data(forType: .png),
           let image = NSImage(data: imageData) {
            clearAnnotations()
            saveAndLoad(image: image)
            return
        }
        
        // Try to get file URL from clipboard
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL],
           let url = urls.first,
           let image = NSImage(contentsOf: url) {
            clearAnnotations()
            saveAndLoad(image: image)
            return
        }
    }

    private func handlePaste(providers: [NSItemProvider]) {
        guard let provider = providers.first else { return }
        clearAnnotations()

        if provider.canLoadObject(ofClass: NSImage.self) {
            _ = provider.loadObject(ofClass: NSImage.self) { image, _ in
                if let image = image as? NSImage {
                    self.saveAndLoad(image: image)
                }
            }
        }
    }

    // MARK: - Gesture Handlers (receive normalized 0-1 coordinates from AppKit)

    private func handleTap(at normalized: CGPoint, isNegative: Bool) {
        guard currentStep == .segment, !skipSegmentation else { return }
        guard inputImage != nil, inputImagePath != nil else { return }

        // Handle polygon tool
        if selectedTool == .polygon {
            handlePolygonTap(at: normalized)
            return
        }

        // Handle point tool
        guard selectedTool == .point else { return }

        // Reject points on transparent areas
        if isTransparentAt(normalized: normalized) {
            env.status = "Cannot place point on transparent area"
            return
        }

        // Coordinates are already normalized 0-1 from ImageCanvasView
        // label: 1 = foreground (include), 0 = background (exclude)
        let point = SAMPoint(normalizedCoords: normalized, label: isNegative ? 0 : 1)

        withAnimation(.spring(response: 0.3)) {
            selectedPoints.append(point)
            undoStack.append(.addPoint(point))
            redoStack.removeAll()  // Clear redo stack on new action
        }

        // Clear selection
        selectedPointId = nil
        selectedBoxId = nil
        selectedLassoId = nil
    }

    private func handleRightClick(at normalized: CGPoint) {
        // Find and delete the nearest annotation at this position
        let threshold: CGFloat = 0.05  // 5% of image size

        // Check points
        if let nearest = selectedPoints.first(where: { point in
            let dx = point.normalizedCoords.x - normalized.x
            let dy = point.normalizedCoords.y - normalized.y
            return sqrt(dx*dx + dy*dy) < threshold
        }) {
            withAnimation {
                selectedPoints.removeAll { $0.id == nearest.id }
                undoStack.append(.addPoint(nearest))
                redoStack.removeAll()
            }
            triggerReInference()
            return
        }

        // Check if click is inside a box
        if let box = boundingBoxes.first(where: { box in
            let rect = box.normalizedRect
            return rect.contains(normalized)
        }) {
            withAnimation {
                boundingBoxes.removeAll { $0.id == box.id }
                undoStack.append(.addBox(box))
                redoStack.removeAll()
            }
            triggerReInference()
            return
        }
    }

    private func deleteSelectedAnnotation() {
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

    private func createFullImageMask() {
        guard let image = inputImage else { return }

        // Create a mask that respects the alpha channel of the input image
        // Only non-transparent pixels should be included in the mask
        let width = Int(image.size.width)
        let height = Int(image.size.height)

        guard width > 0 && height > 0 else {
            env.status = "Invalid image dimensions"
            return
        }

        // Get CGImage from NSImage
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            env.status = "Failed to get CGImage"
            return
        }

        // Create a context to draw the source image in a known RGBA format
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bytesPerPixel = 4
        let bytesPerRow = bytesPerPixel * width
        var sourcePixels = [UInt8](repeating: 0, count: height * bytesPerRow)

        guard let sourceContext = CGContext(
            data: &sourcePixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            env.status = "Failed to create source context"
            return
        }

        // Draw source image into context (converts to known RGBA format)
        sourceContext.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        // Create output mask pixels
        var maskPixels = [UInt8](repeating: 0, count: height * bytesPerRow)

        // SAM2 mask color: RGB(50, 100, 200)
        let maskR: UInt8 = 50
        let maskG: UInt8 = 100
        let maskB: UInt8 = 200

        // Process each pixel - check alpha from source, apply mask color where opaque
        var opaquePixels = 0
        for y in 0..<height {
            for x in 0..<width {
                let offset = (y * bytesPerRow) + (x * bytesPerPixel)
                // Source is RGBA (premultiplied), alpha is at offset+3
                let sourceAlpha = sourcePixels[offset + 3]

                if sourceAlpha > 2 {  // More than ~1% alpha (255 * 0.01 ≈ 2.55)
                    // Set mask color with full opacity
                    maskPixels[offset + 0] = maskR
                    maskPixels[offset + 1] = maskG
                    maskPixels[offset + 2] = maskB
                    maskPixels[offset + 3] = 255
                    opaquePixels += 1
                } else {
                    // Fully transparent
                    maskPixels[offset + 0] = 0
                    maskPixels[offset + 1] = 0
                    maskPixels[offset + 2] = 0
                    maskPixels[offset + 3] = 0
                }
            }
        }

        // Create mask CGImage from pixels
        guard let maskContext = CGContext(
            data: &maskPixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ),
        let maskCGImage = maskContext.makeImage() else {
            env.status = "Failed to create mask image"
            return
        }

        // Create NSImage from CGImage
        let size = NSSize(width: width, height: height)
        let newMask = NSImage(cgImage: maskCGImage, size: size)
        maskImage = newMask

        // Save mask to disk
        maskIsDirty = true
        flushMaskToDisk()

        let coverage = Double(opaquePixels) / Double(width * height) * 100
        env.status = String(format: "Mask from alpha channel (%.1f%% coverage)", coverage)
    }

    /// Cache the alpha channel data from the input image for quick lookups
    private func cacheSourceAlpha() {
        guard let image = inputImage,
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            sourceAlphaData = []
            sourceAlphaWidth = 0
            sourceAlphaHeight = 0
            return
        }

        let width = cgImage.width
        let height = cgImage.height

        guard width > 0 && height > 0 else {
            sourceAlphaData = []
            sourceAlphaWidth = 0
            sourceAlphaHeight = 0
            return
        }

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
            sourceAlphaWidth = 0
            sourceAlphaHeight = 0
            return
        }

        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        // Extract just the alpha channel
        var alphaData = [UInt8](repeating: 0, count: width * height)
        for i in 0..<(width * height) {
            alphaData[i] = pixels[i * 4 + 3]  // Alpha is at offset 3 in RGBA
        }

        sourceAlphaData = alphaData
        sourceAlphaWidth = width
        sourceAlphaHeight = height
    }

    /// Check if a normalized coordinate (0-1) is on a transparent pixel
    /// Returns true if the pixel is transparent (should be excluded from segmentation)
    private func isTransparentAt(normalized: CGPoint) -> Bool {
        guard !sourceAlphaData.isEmpty,
              sourceAlphaWidth > 0,
              sourceAlphaHeight > 0 else {
            return false  // No alpha data means image has no transparency
        }

        // Convert normalized coords to pixel coords
        // Note: CGImage coordinates have origin at top-left
        let x = Int(normalized.x * CGFloat(sourceAlphaWidth))
        let y = Int(normalized.y * CGFloat(sourceAlphaHeight))

        // Clamp to valid range
        let clampedX = max(0, min(x, sourceAlphaWidth - 1))
        let clampedY = max(0, min(y, sourceAlphaHeight - 1))

        let index = clampedY * sourceAlphaWidth + clampedX
        guard index >= 0 && index < sourceAlphaData.count else {
            return false
        }

        // Consider transparent if alpha < ~1% (2.55)
        return sourceAlphaData[index] < 3
    }

    /// Apply the source alpha mask to a generated mask image
    /// This removes any mask pixels that are over transparent source areas
    private func applyAlphaMaskToMask(_ mask: NSImage) -> NSImage {
        guard !sourceAlphaData.isEmpty,
              sourceAlphaWidth > 0,
              sourceAlphaHeight > 0 else {
            return mask  // No alpha data, return unchanged
        }

        guard let cgImage = mask.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return mask
        }

        let width = cgImage.width
        let height = cgImage.height

        // Ensure dimensions match
        guard width == sourceAlphaWidth && height == sourceAlphaHeight else {
            return mask  // Dimension mismatch, return unchanged
        }

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
            return mask
        }

        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        // Clear mask pixels where source is transparent
        for y in 0..<height {
            for x in 0..<width {
                let alphaIndex = y * width + x
                if alphaIndex < sourceAlphaData.count && sourceAlphaData[alphaIndex] < 3 {
                    // Source is transparent here, clear the mask
                    let pixelOffset = (y * bytesPerRow) + (x * bytesPerPixel)
                    pixels[pixelOffset + 0] = 0  // R
                    pixels[pixelOffset + 1] = 0  // G
                    pixels[pixelOffset + 2] = 0  // B
                    pixels[pixelOffset + 3] = 0  // A
                }
            }
        }

        guard let outputContext = CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ),
        let outputCGImage = outputContext.makeImage() else {
            return mask
        }

        return NSImage(cgImage: outputCGImage, size: NSSize(width: width, height: height))
    }

    /// Thread-safe version of applyAlphaMaskToMask for background processing
    /// Takes alpha data as parameters to avoid accessing @State from background
    private func applyAlphaMaskToMaskBackground(
        _ mask: NSImage,
        alphaData: [UInt8],
        alphaWidth: Int,
        alphaHeight: Int
    ) -> NSImage {
        guard !alphaData.isEmpty, alphaWidth > 0, alphaHeight > 0 else {
            return mask  // No alpha data, return unchanged
        }

        guard let cgImage = mask.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return mask
        }

        let width = cgImage.width
        let height = cgImage.height

        // Ensure dimensions match
        guard width == alphaWidth && height == alphaHeight else {
            return mask  // Dimension mismatch, return unchanged
        }

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
            return mask
        }

        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        // Clear mask pixels where source is transparent
        for y in 0..<height {
            for x in 0..<width {
                let alphaIndex = y * width + x
                if alphaIndex < alphaData.count && alphaData[alphaIndex] < 3 {
                    // Source is transparent here, clear the mask
                    let pixelOffset = (y * bytesPerRow) + (x * bytesPerPixel)
                    pixels[pixelOffset + 0] = 0  // R
                    pixels[pixelOffset + 1] = 0  // G
                    pixels[pixelOffset + 2] = 0  // B
                    pixels[pixelOffset + 3] = 0  // A
                }
            }
        }

        guard let outputContext = CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ),
        let outputCGImage = outputContext.makeImage() else {
            return mask
        }

        return NSImage(cgImage: outputCGImage, size: NSSize(width: width, height: height))
    }

    // MARK: - Multi-Mask Selection

    /// Generate confidence overlay visualization based on mask scores
    private func generateConfidenceOverlay(from scores: [Double]) {
        guard !scores.isEmpty else {
            confidenceOverlay = nil
            return
        }

        // Create a visual representation of confidence
        // Higher scores = more green, lower scores = more red
        let maxScore = scores.max() ?? 1.0
        let minScore = scores.min() ?? 0.0
        let scoreRange = maxScore - minScore

        let width = 256
        let height = 32 * scores.count

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bytesPerPixel = 4
        let bytesPerRow = bytesPerPixel * width
        var pixels = [UInt8](repeating: 0, count: height * bytesPerRow)

        for (index, score) in scores.enumerated() {
            let normalizedScore = scoreRange > 0 ? (score - minScore) / scoreRange : 1.0

            // Green to Red gradient based on confidence
            let red = UInt8((1.0 - normalizedScore) * 255)
            let green = UInt8(normalizedScore * 255)

            for y in 0..<32 {
                for x in 0..<width {
                    let pixelOffset = ((index * 32 + y) * bytesPerRow) + (x * bytesPerPixel)

                    // Bar on the left, gradient on the right
                    if x < 32 {
                        pixels[pixelOffset + 0] = red
                        pixels[pixelOffset + 1] = green
                        pixels[pixelOffset + 2] = 0
                        pixels[pixelOffset + 3] = 255
                    } else {
                        let alpha = Float(x - 32) / Float(width - 32)
                        pixels[pixelOffset + 0] = red
                        pixels[pixelOffset + 1] = green
                        pixels[pixelOffset + 2] = 0
                        pixels[pixelOffset + 3] = UInt8(alpha * 200)
                    }
                }
            }
        }

        guard let context = CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ), let cgImage = context.makeImage() else {
            confidenceOverlay = nil
            return
        }

        confidenceOverlay = NSImage(cgImage: cgImage, size: NSSize(width: width, height: height))
    }

    /// Select a different mask from the available options
    private func selectMask(at index: Int) {
        guard index >= 0 && index < maskOptions.count else { return }

        selectedMaskIndex = index

        // Use pre-processed cache for instant switching (no disk I/O or reprocessing)
        if let cachedMask = processedMaskCache[index] {
            maskImage = cachedMask
            maskIsDirty = true
        } else {
            // Fallback: process on-demand if cache miss (shouldn't happen normally)
            maskImage = applyAlphaMaskToMask(maskOptions[index])
            processedMaskCache[index] = maskImage
            maskIsDirty = true
        }
    }

    /// Clear all mask options
    private func clearMaskOptions() {
        maskOptions = []
        maskOptionsPaths = []
        maskScores = []
        selectedMaskIndex = 0
        confidenceOverlay = nil
        processedMaskCache = [:]  // Clear the pre-processed cache
    }

    // MARK: - Real-Time Paint Preview

    /// Update live paint preview mask
    private func updateLivePaintPreview(at point: CGPoint) {
        guard currentStep == .segment, selectedTool == .paint, var currentStroke = currentPaintStroke else {
            livePaintMask = nil
            return
        }

        // Point is already normalized from ImageCanvasView
        currentStroke.addPoint(point)

        // Generate preview mask from current mask + this stroke
        if let currentMask = maskImage {
            livePaintMask = applyStrokesToMask(currentMask, strokes: [currentStroke])
        }
    }

    /// Clear live paint preview
    private func clearLivePaintPreview() {
        livePaintMask = nil
    }

    private func handleDragStart(at point: CGPoint) {
        guard inputImage != nil else { return }

        if currentStep == .refine && selectedPreprocessTool == .crop {
            cropRect = SAMBox(startPoint: point, endPoint: point)
        } else if currentStep == .segment && selectedTool == .boundingBox {
            currentBox = SAMBox(startPoint: point, endPoint: point)
        }
    }

    private func handleDragChange(start: CGPoint, current: CGPoint) {
        if currentStep == .refine && selectedPreprocessTool == .crop {
            cropRect?.endPoint = current
        } else if currentStep == .segment && selectedTool == .boundingBox {
            currentBox?.endPoint = current
        }
    }

    private func handleDragEnd(start: CGPoint, end: CGPoint) {
        if currentStep == .refine && selectedPreprocessTool == .crop {
            // Crop rect stays until user applies or clears
            return
        }

        guard currentStep == .segment, selectedTool == .boundingBox else { return }
        guard let box = currentBox else { return }

        guard box.isValid else {
            currentBox = nil
            return
        }

        withAnimation(.spring(response: 0.3)) {
            boundingBoxes.append(box)
            undoStack.append(.addBox(box))
            currentBox = nil
        }
    }

    // MARK: - Lasso Handlers

    private func handleLassoStart(at point: CGPoint) {
        guard inputImage != nil else { return }

        if currentStep == .refine && selectedPreprocessTool == .polygonCrop {
            preprocessLasso = LassoSelection(startPoint: point)
        } else if currentStep == .segment && selectedTool == .lasso {
            currentLasso = LassoSelection(startPoint: point)
        }
    }

    private func handleLassoContinue(at point: CGPoint) {
        if currentStep == .refine && selectedPreprocessTool == .polygonCrop {
            if var lasso = preprocessLasso {
                lasso.addPoint(point)
                preprocessLasso = lasso
            }
        } else if currentStep == .segment && selectedTool == .lasso {
            if var lasso = currentLasso {
                lasso.addPoint(point)
                currentLasso = lasso
            }
        }
    }

    private func handleLassoEnd() {
        if currentStep == .refine && selectedPreprocessTool == .polygonCrop {
            // Keep the lasso until user applies crop
            return
        }

        guard currentStep == .segment, selectedTool == .lasso else { return }
        guard let lasso = currentLasso, lasso.isValid else {
            currentLasso = nil
            return
        }

        withAnimation(.spring(response: 0.3)) {
            lassoSelections.append(lasso)
            undoStack.append(.addLasso(lasso))
            currentLasso = nil
        }
    }

    // MARK: - Paint Handlers

    private func handlePaintStart(at point: CGPoint) {
        guard selectedTool == .paint else { return }
        guard inputImage != nil else { return }

        currentPaintStroke = PaintStroke(
            startPoint: point,
            brushSize: brushSize,
            isErasing: isErasing
        )
    }

    private func handlePaintContinue(at point: CGPoint) {
        guard selectedTool == .paint else { return }
        
        if var stroke = currentPaintStroke {
            stroke.addPoint(point)
            currentPaintStroke = stroke
        }

        // Update live paint preview (optional, can be slow)
        // updateLivePaintPreview(at: point)
    }

    private func handlePaintEnd() {
        guard selectedTool == .paint else { return }

        // Clear live preview
        clearLivePaintPreview()

        guard let stroke = currentPaintStroke, stroke.points.count >= 1 else {
            currentPaintStroke = nil
            return
        }

        withAnimation(.easeOut(duration: 0.1)) {
            paintStrokes.append(stroke)
            currentPaintStroke = nil
        }

        // Auto-apply paint strokes to mask after each stroke
        autoApplyPaintStroke(stroke)
    }

    /// Auto-apply a single paint stroke to the mask (called after each stroke ends)
    private func autoApplyPaintStroke(_ stroke: PaintStroke) {
        guard let currentMask = maskImage else {
            // If no mask exists yet, need to create one first via SAM2
            if selectedPoints.isEmpty && boundingBoxes.isEmpty && lassoSelections.isEmpty {
                env.status = "Create initial mask with Point or Box first"
                // Remove the stroke since we can't apply it
                paintStrokes.removeAll { $0.id == stroke.id }
            }
            return
        }

        // Apply just this stroke to the existing mask
        let modifiedMask = applyStrokesToMask(currentMask, strokes: [stroke])
        maskImage = modifiedMask

        // Mark mask as dirty
        maskIsDirty = true

        // Clear applied stroke from the overlay (keep it in history for undo)
        paintStrokes.removeAll { $0.id == stroke.id }
        undoStack.append(.addPaintStroke(stroke))
        redoStack.removeAll()

        env.status = stroke.isErasing ? "Erased from mask" : "Added to mask"
    }

    private func clearPaintStrokes() {
        withAnimation {
            paintStrokes.removeAll()
            currentPaintStroke = nil
        }
    }

    private func applyPaintToMask() {
        guard !paintStrokes.isEmpty else { return }
        guard let currentMask = maskImage else {
            env.status = "Create a mask first with Point or Box tool"
            return
        }

        // Apply paint strokes to the mask image
        let modifiedMask = applyStrokesToMask(currentMask, strokes: paintStrokes)
        maskImage = modifiedMask

        // Mark mask as dirty (write to disk before generation)
        maskIsDirty = true

        // Clear the strokes after applying
        clearPaintStrokes()

        env.status = "Paint applied to mask"
    }

    private func applyStrokesToMask(_ mask: NSImage, strokes: [PaintStroke]) -> NSImage {
        guard let tiffData = mask.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData) else {
            return mask
        }

        let width = bitmap.pixelsWide
        let height = bitmap.pixelsHigh
        let imageSize = NSSize(width: width, height: height)

        // Create new bitmap with Core Graphics
        guard let newBitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: width,
            pixelsHigh: height,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: width * 4,
            bitsPerPixel: 32
        ) else {
            return mask
        }

        // Copy existing mask
        NSGraphicsContext.saveGraphicsState()
        let context = NSGraphicsContext(bitmapImageRep: newBitmap)
        NSGraphicsContext.current = context
        bitmap.draw(in: NSRect(origin: .zero, size: imageSize))

        let cgWidth = CGFloat(width)
        let cgHeight = CGFloat(height)

        // Use vector graphics for smooth strokes
        for stroke in strokes {
            guard stroke.points.count > 1 else { continue }

            let brushRadius = stroke.brushSize * cgWidth / 2
            let path = NSBezierPath()

            // Convert normalized points to pixel coordinates (pre-allocated for efficiency)
            // Note: Flip Y coordinate because Core Graphics origin is bottom-left, specific to the valid implementation of NSGraphicsContext
            // but SwiftUI/Input coordinates are top-left normalized
            let firstPoint = stroke.points[0]
            path.move(to: CGPoint(
                x: firstPoint.x * cgWidth,
                y: (1.0 - firstPoint.y) * cgHeight
            ))

            for i in 1..<stroke.points.count {
                let point = stroke.points[i]
                path.line(to: CGPoint(
                    x: point.x * cgWidth,
                    y: (1.0 - point.y) * cgHeight
                ))
            }

            // Set stroke color and properties
            if stroke.isErasing {
                context?.compositingOperation = .copy
                NSColor.clear.setStroke()
                NSColor.clear.setFill()
            } else {
                NSColor(red: 50/255, green: 100/255, blue: 200/255, alpha: 1.0).setStroke()
                NSColor(red: 50/255, green: 100/255, blue: 200/255, alpha: 1.0).setFill()
            }

            path.lineWidth = brushRadius * 2
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            path.stroke()

            // Add circles at each point to fill gaps (optimized with direct fill)
            for point in stroke.points {
                let circle = NSBezierPath(ovalIn: NSRect(
                    x: point.x * cgWidth - brushRadius,
                    y: (1.0 - point.y) * cgHeight - brushRadius,
                    width: brushRadius * 2,
                    height: brushRadius * 2
                ))
                circle.fill()
            }

            // Reset compositing operation if we were erasing
            if stroke.isErasing {
                context?.compositingOperation = .sourceOver
            }
        }

        NSGraphicsContext.restoreGraphicsState()

        let newImage = NSImage(size: imageSize)
        newImage.addRepresentation(newBitmap)

        // Apply alpha filtering to exclude transparent source areas
        return applyAlphaMaskToMask(newImage)
    }

    private func saveMaskImage(_ mask: NSImage) {
        maskIsDirty = true
    }

    private func flushMaskToDisk() {
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

    private func triggerReInference() {
        guard !selectedPoints.isEmpty || !boundingBoxes.isEmpty || !lassoSelections.isEmpty else { return }
        guard let path = inputImagePath else { return }
        guard !env.isProcessing else { return }

        // Get the best box: prefer explicit bounding boxes, then lasso bounding boxes
        let effectiveBox: SAMBox? = boundingBoxes.first ?? lassoSelections.first?.boundingBox

        let task = Task.detached(priority: .userInitiated) {
            do {
                // Use setImageIfNeeded to skip redundant SAM image encoding
                let pixelSize = try await env.setImageIfNeeded(path: path)
                await MainActor.run {
                    guard !Task.isCancelled else { return }
                    self.imagePixelSize = pixelSize
                }

                 let (maskURLs, primaryMaskURL, scores, confidenceMapURL) = try await env.predict(
                    points: selectedPoints,
                    box: effectiveBox,
                    imageSize: pixelSize
                )

                // Load all mask options
                var loadedMasks: [NSImage] = []
                var loadedPaths: [String] = []
                for url in maskURLs {
                    if let mask = NSImage(contentsOf: url) {
                        loadedMasks.append(mask)
                        loadedPaths.append(url.path)
                    }
                }

                // Load primary mask (first/highest scored)
                if loadedMasks.isEmpty {
                    await MainActor.run {
                        self.env.status = "Error: Failed to load masks"
                    }
                    return
                }

                // Pre-process all masks in background for instant switching
                // Capture sourceAlphaData for background processing
                let alphaData = await MainActor.run { self.sourceAlphaData }
                let alphaWidth = await MainActor.run { self.sourceAlphaWidth }
                let alphaHeight = await MainActor.run { self.sourceAlphaHeight }

                var processedCache: [Int: NSImage] = [:]
                for (index, mask) in loadedMasks.enumerated() {
                    // Apply alpha mask processing in background
                    let processed = self.applyAlphaMaskToMaskBackground(
                        mask,
                        alphaData: alphaData,
                        alphaWidth: alphaWidth,
                        alphaHeight: alphaHeight
                    )
                    processedCache[index] = processed
                }

                // Load confidence heatmap if available
                var loadedConfidenceMap: NSImage?
                if let confURL = confidenceMapURL {
                    loadedConfidenceMap = NSImage(contentsOf: confURL)
                }

                await MainActor.run {
                    guard !Task.isCancelled else { return }
                    // Store all mask options
                    self.maskOptions = loadedMasks
                    self.maskOptionsPaths = loadedPaths
                    self.maskScores = scores
                    self.selectedMaskIndex = 0
                    self.processedMaskCache = processedCache

                    // Use pre-processed first mask for instant display
                    self.maskImage = processedCache[0] ?? loadedMasks.first!

                    // Use real per-pixel confidence heatmap from SAM2 logits
                    if let confMap = loadedConfidenceMap {
                        self.confidenceOverlay = confMap
                    } else {
                        // Fallback to score-based visualization if heatmap not available
                        self.generateConfidenceOverlay(from: scores)
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

    // MARK: - 3D Generation

    private func startGeneration() {
        guard let imagePath = inputImagePath else {
            generationProgress.stage = "Error: No image loaded"
            return
        }

        // Flush mask to disk before generation if dirty
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

    /// Parse progress string from Hunyuan and update GenerationProgress struct
    private func updateGenerationProgress(_ progressString: String) {
        // Parse formats like:
        // "Diffusion Sampling: 50% (15/30) [2.5 it/s]"
        // "Volume Decoding: 25% (5/20) [1.2 it/s]"
        // "Extracting foreground..."
        // "Loading model..."

        // Check for stage name
        if progressString.contains("Extracting foreground") {
            generationProgress.stage = "Extracting Foreground"
            generationProgress.currentStep = 0
            generationProgress.totalSteps = 0
        } else if progressString.contains("Loading") {
            generationProgress.stage = "Loading Model"
            generationProgress.currentStep = 0
            generationProgress.totalSteps = 0
        } else if progressString.contains("Diffusion Sampling") {
            generationProgress.stage = "Diffusion Sampling"
            parseProgressDetails(progressString)
        } else if progressString.contains("Volume Decoding") {
            generationProgress.stage = "Volume Decoding"
            parseProgressDetails(progressString)
        } else if progressString.contains("Saving") {
            generationProgress.stage = "Saving Model"
            generationProgress.currentStep = generationProgress.totalSteps
        }

        // Update elapsed and estimated time
        if let startTime = generationStartTime {
            generationProgress.elapsedTime = Date().timeIntervalSince(startTime)

            if generationProgress.currentStep > 0 && generationProgress.totalSteps > 0 {
                let remaining = generationProgress.totalSteps - generationProgress.currentStep
                if generationProgress.iterationsPerSecond > 0 {
                    generationProgress.estimatedRemaining = Double(remaining) / generationProgress.iterationsPerSecond
                }
            }
        }
    }

    /// Parse step count and speed from progress string
    private func parseProgressDetails(_ progressString: String) {
        // Try to extract current/total steps: "15/30" or "(15/30)"
        if let stepMatch = progressString.range(of: #"(\d+)/(\d+)"#, options: .regularExpression) {
            let stepStr = String(progressString[stepMatch])
            let parts = stepStr.split(separator: "/")
            if parts.count == 2 {
                generationProgress.currentStep = Int(parts[0]) ?? 0
                generationProgress.totalSteps = Int(parts[1]) ?? 0
            }
        }

        // Try to extract speed: "2.5 it/s" or "2.5it/s"
        if let speedMatch = progressString.range(of: #"(\d+\.?\d*)\s*it/s"#, options: .regularExpression) {
            let speedStr = String(progressString[speedMatch])
            if let numMatch = speedStr.range(of: #"\d+\.?\d*"#, options: .regularExpression) {
                generationProgress.iterationsPerSecond = Double(speedStr[numMatch]) ?? 0
            }
        }

        // Try to extract s/it format: "0.5 s/it"
        if let sitMatch = progressString.range(of: #"(\d+\.?\d*)\s*s/it"#, options: .regularExpression) {
            let sitStr = String(progressString[sitMatch])
            if let numMatch = sitStr.range(of: #"\d+\.?\d*"#, options: .regularExpression) {
                if let secsPerIt = Double(sitStr[numMatch]), secsPerIt > 0 {
                    generationProgress.iterationsPerSecond = 1.0 / secsPerIt
                }
            }
        }
    }

    private func getMaskPath() -> String? {
        // If mask hasn't been edited, use the original SAM2 mask directly
        // This preserves the proper alpha channel from SAM2's save_mask function
        if !maskIsDirty, !maskOptionsPaths.isEmpty, selectedMaskIndex < maskOptionsPaths.count {
            return maskOptionsPaths[selectedMaskIndex]
        }
        
        // If mask was edited, use the flushed mask.png
        let maskURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/ModelrV3/mask.png")
        return FileManager.default.fileExists(atPath: maskURL.path) ? maskURL.path : nil
    }

    // MARK: - Clear Actions

    private func clearAnnotations() {
        withAnimation {
            selectedPoints.removeAll()
            boundingBoxes.removeAll()
            currentBox = nil
            lassoSelections.removeAll()
            currentLasso = nil
            paintStrokes.removeAll()
            currentPaintStroke = nil
            polygonSelections.removeAll()
            currentPolygon = nil
            maskImage = nil
            undoStack.removeAll()
        }
    }

    // MARK: - Polygon Tool Handling

    /// Handle tap for polygon tool - add vertices or close polygon
    private func handlePolygonTap(at normalized: CGPoint) {
        if var current = currentPolygon {
            // Check if clicking near first vertex to close polygon
            if current.vertices.count >= 3 {
                let firstVertex = current.vertices[0]
                let distance = hypot(normalized.x - firstVertex.x, normalized.y - firstVertex.y)
                // Consider "close" if within 3% of image size
                if distance < 0.03 {
                    current.close()
                    polygonSelections.append(current)
                    currentPolygon = nil

                    // Use polygon's bounding box for SAM inference
                    if let box = current.boundingBox {
                        boundingBoxes.append(box)
                        // Trigger re-inference with the polygon's bounding box
                        triggerReInference()
                    }
                    return
                }
            }

            // Add new vertex
            current.addVertex(normalized)
            currentPolygon = current
        } else {
            // Start new polygon
            currentPolygon = PolygonSelection(vertices: [normalized])
        }
    }

    /// Cancel current polygon drawing
    private func cancelPolygon() {
        currentPolygon = nil
    }

    // MARK: - Point Drag Handling

    /// Handle when a point is dragged to a new position
    private func handlePointDragEnd(point: SAMPoint, newPosition: CGPoint) {
        // Create the new point with the same label but updated position
        let updatedPoint = SAMPoint(normalizedCoords: newPosition, label: point.label)

        // Find and replace the point in the array
        if let index = selectedPoints.firstIndex(where: { $0.id == point.id }) {
            selectedPoints[index] = updatedPoint

            // Record for undo (store original -> new for reversal)
            undoStack.append(.movePoint(from: point, to: updatedPoint))
            redoStack.removeAll()

            // Select the moved point
            selectedPointId = updatedPoint.id

            // Trigger re-inference with the updated point position
            triggerReInference()
        }
    }

    // MARK: - Undo/Redo

    private func performUndo() {
        guard !undoStack.isEmpty else { return }
        let action = undoStack.removeLast()

        withAnimation(.easeOut(duration: 0.2)) {
            switch action {
            case .addPoint(let point):
                // If point exists, remove it; if not, add it back (was a delete)
                if selectedPoints.contains(where: { $0.id == point.id }) {
                    selectedPoints.removeAll { $0.id == point.id }
                    redoStack.append(.addPoint(point))
                } else {
                    selectedPoints.append(point)
                    redoStack.append(.addPoint(point))
                }
            case .addBox(let box):
                if boundingBoxes.contains(where: { $0.id == box.id }) {
                    boundingBoxes.removeAll { $0.id == box.id }
                    redoStack.append(.addBox(box))
                } else {
                    boundingBoxes.append(box)
                    redoStack.append(.addBox(box))
                }
            case .addLasso(let lasso):
                if lassoSelections.contains(where: { $0.id == lasso.id }) {
                    lassoSelections.removeAll { $0.id == lasso.id }
                    redoStack.append(.addLasso(lasso))
                } else {
                    lassoSelections.append(lasso)
                    redoStack.append(.addLasso(lasso))
                }
            case .addPaintStroke(let stroke):
                paintStrokes.removeAll { $0.id == stroke.id }
                redoStack.append(.addPaintStroke(stroke))
            case .crop(let originalImage, let originalPath):
                // Store current state for redo
                if let currentImage = inputImage, let currentPath = inputImagePath {
                    redoStack.append(.crop(originalImage: currentImage, originalPath: currentPath))
                }
                inputImage = originalImage
                inputImagePath = originalPath
            case .movePoint(let originalPoint, let movedPoint):
                // Undo: replace the moved point with the original
                if let index = selectedPoints.firstIndex(where: { $0.id == movedPoint.id }) {
                    selectedPoints[index] = originalPoint
                    redoStack.append(.movePoint(from: originalPoint, to: movedPoint))
                }
            }
        }

        // Trigger re-inference after undo
        triggerReInference()
    }

    private func performRedo() {
        guard !redoStack.isEmpty else { return }
        let action = redoStack.removeLast()

        withAnimation(.easeOut(duration: 0.2)) {
            switch action {
            case .addPoint(let point):
                if selectedPoints.contains(where: { $0.id == point.id }) {
                    selectedPoints.removeAll { $0.id == point.id }
                    undoStack.append(.addPoint(point))
                } else {
                    selectedPoints.append(point)
                    undoStack.append(.addPoint(point))
                }
            case .addBox(let box):
                if boundingBoxes.contains(where: { $0.id == box.id }) {
                    boundingBoxes.removeAll { $0.id == box.id }
                    undoStack.append(.addBox(box))
                } else {
                    boundingBoxes.append(box)
                    undoStack.append(.addBox(box))
                }
            case .addLasso(let lasso):
                if lassoSelections.contains(where: { $0.id == lasso.id }) {
                    lassoSelections.removeAll { $0.id == lasso.id }
                    undoStack.append(.addLasso(lasso))
                } else {
                    lassoSelections.append(lasso)
                    undoStack.append(.addLasso(lasso))
                }
            case .addPaintStroke(let stroke):
                paintStrokes.append(stroke)
                undoStack.append(.addPaintStroke(stroke))
            case .crop(let originalImage, let originalPath):
                if let currentImage = inputImage, let currentPath = inputImagePath {
                    undoStack.append(.crop(originalImage: currentImage, originalPath: currentPath))
                }
                inputImage = originalImage
                inputImagePath = originalPath
            case .movePoint(let originalPoint, let movedPoint):
                // Redo: replace original with the moved point
                if let index = selectedPoints.firstIndex(where: { $0.id == originalPoint.id }) {
                    selectedPoints[index] = movedPoint
                    undoStack.append(.movePoint(from: originalPoint, to: movedPoint))
                }
            }
        }

        // Trigger re-inference after redo
        triggerReInference()
    }

    // MARK: - Preprocess Actions

    private func autoRemoveBackground() {
        Task {
            do {
                // Save current for undo
                if let image = inputImage {
                    await MainActor.run {
                        undoStack.append(.crop(originalImage: image, originalPath: inputImagePath))
                    }
                }
                
                let url = try await env.removeBackground()
                await MainActor.run {
                    loadImage(from: url)
                    env.status = "Background removed"
                    // Auto-transition to segmentation
                    moveToNextStep()
                }
            } catch {
                await MainActor.run {
                    env.status = "Error: \(error.localizedDescription)"
                }
            }
        }
    }

    private func applyCrop() {
        guard let image = inputImage,
              let crop = cropRect,
              crop.isValid else { return }

        // Save for undo
        undoStack.append(.crop(originalImage: image, originalPath: inputImagePath))

        let pixelW = imagePixelSize.width
        let pixelH = imagePixelSize.height
        if pixelW == 0 || pixelH == 0 { return }

        // Use CIImage to extract the crop at full resolution
        guard let tiffData = image.tiffRepresentation,
              let ciImage = CIImage(data: tiffData) else { return }
        
        let rect = crop.normalizedRect
        var cropRectPixels = CGRect(
            x: rect.minX * pixelW,
            y: (1.0 - rect.maxY) * pixelH,
            width: rect.width * pixelW,
            height: rect.height * pixelH
        )
        
        // Intersect with image bounds to handle out-of-bounds selections
        let imageBounds = CGRect(x: 0, y: 0, width: pixelW, height: pixelH)
        cropRectPixels = cropRectPixels.intersection(imageBounds)
        
        // Ensure the intersection is valid (not empty)
        guard cropRectPixels.width > 0 && cropRectPixels.height > 0 else {
            cropRect = nil
            env.status = "Error: Selection outside image"
            return
        }

        let croppedCI = ciImage.cropped(to: cropRectPixels)
        let context = CIContext(options: nil)
        
        guard let cgImage = context.createCGImage(croppedCI, from: croppedCI.extent) else { return }
        
        let croppedImage = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        
        self.inputImage = croppedImage
        self.imagePixelSize = CGSize(width: cgImage.width, height: cgImage.height)
        self.cacheSourceAlpha()  // Cache alpha for transparency filtering
        saveAndLoad(image: croppedImage)

        cropRect = nil
        env.status = "Image cropped"
        
        // Auto-transition to segmentation
        moveToNextStep()
    }



    private func applyPolygonCrop() {
        guard let image = inputImage,
              let lasso = preprocessLasso,
              lasso.isValid else { return }

        // Save for undo
        undoStack.append(.crop(originalImage: image, originalPath: inputImagePath))

        // Apply polygon crop (keep inside, delete outside)
        if let croppedImage = cropToPolygon(image, lasso: lasso) {
            inputImage = croppedImage
            saveAndLoad(image: croppedImage)
        }

        preprocessLasso = nil
        env.status = "Polygon crop applied"
        
        // Auto-transition to segmentation
        moveToNextStep()
    }

    private func cropToPolygon(_ image: NSImage, lasso: LassoSelection) -> NSImage? {
        // Use the primary CGImage representation to avoid resolution loss
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        
        let width = cgImage.width
        let height = cgImage.height
        let imageSize = NSSize(width: width, height: height)

        // Create new bitmap with alpha
        guard let newBitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: width,
            pixelsHigh: height,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: width * 4,
            bitsPerPixel: 32
        ) else { return nil }

        // Create context from CGImage
        NSGraphicsContext.saveGraphicsState()
        let context = NSGraphicsContext(bitmapImageRep: newBitmap)
        NSGraphicsContext.current = context
        
        // Start with a clear background
        NSColor.clear.set()
        NSRect(origin: .zero, size: imageSize).fill()

        let cgWidth = CGFloat(width)
        let cgHeight = CGFloat(height)

        // Use NSBezierPath to define the clipping area
        guard lasso.points.count >= 3 else { return image }

        let path = NSBezierPath()

        // Convert normalized points to pixel coordinates (pre-allocated for efficiency)
        let firstPoint = lasso.points[0]
        path.move(to: CGPoint(
            x: firstPoint.x * cgWidth,
            y: (1.0 - firstPoint.y) * cgHeight
        ))

        for i in 1..<lasso.points.count {
            let point = lasso.points[i]
            path.line(to: CGPoint(
                x: point.x * cgWidth,
                y: (1.0 - point.y) * cgHeight
            ))
        }
        path.close()

        // Set the path as clipping path
        path.addClip()

        // Draw the original image - only the part inside the clip will be drawn
        let ciContext = CIContext(options: nil)
        let ciImage = CIImage(cgImage: cgImage)
        if let cgDrawn = ciContext.createCGImage(ciImage, from: ciImage.extent) {
            let nsDrawn = NSImage(cgImage: cgDrawn, size: imageSize)
            nsDrawn.draw(in: NSRect(origin: .zero, size: imageSize))
        }

        NSGraphicsContext.restoreGraphicsState()

        let newImage = NSImage(size: imageSize)
        newImage.addRepresentation(newBitmap)
        return newImage
    }

    private func clearCrop() {
        cropRect = nil
    }

    private func clearPreprocessLasso() {
        preprocessLasso = nil
    }

    // MARK: - State Persistence for Tab Switching

    /// Structure to hold segmentation state for persistence
    private struct SegmentationStateData: Codable {
        let points: [SAMPoint]
        let boxes: [SAMBox]
        let polygons: [PolygonSelection]
        let selectedMaskIndex: Int
        let maskScores: [Double]
    }

    private static let segmentationStateKey = "com.modelr.segmentationState"

    /// Save segmentation state when leaving segment tab
    private func saveSegmentationState() {
        let state = SegmentationStateData(
            points: selectedPoints,
            boxes: boundingBoxes,
            polygons: polygonSelections,
            selectedMaskIndex: selectedMaskIndex,
            maskScores: maskScores
        )
        if let data = try? JSONEncoder().encode(state) {
            UserDefaults.standard.set(data, forKey: Self.segmentationStateKey)
        }
    }

    /// Restore segmentation state when returning to segment tab
    private func restoreSegmentationState() {
        guard let data = UserDefaults.standard.data(forKey: Self.segmentationStateKey),
              let state = try? JSONDecoder().decode(SegmentationStateData.self, from: data) else {
            return
        }

        // Only restore if we have the same image loaded (compare by checking if we have an image)
        guard inputImage != nil else { return }

        // Restore points, boxes, and polygons
        if selectedPoints.isEmpty && !state.points.isEmpty {
            selectedPoints = state.points
        }
        if boundingBoxes.isEmpty && !state.boxes.isEmpty {
            boundingBoxes = state.boxes
        }
        if polygonSelections.isEmpty && !state.polygons.isEmpty {
            polygonSelections = state.polygons
        }

        // Restore mask selection state if we have masks
        if !maskOptions.isEmpty && state.selectedMaskIndex < maskOptions.count {
            selectedMaskIndex = state.selectedMaskIndex
            selectMask(at: selectedMaskIndex)
        }
    }

    private func clearAll() {
        // Cancel all running tasks
        currentTasks.forEach { $0.cancel() }
        currentTasks.removeAll()

        clearAnnotations()
        inputImage = nil
        inputImagePath = nil
        imagePixelSize = .zero
        generated3DModelURL = nil
        generationProgress = GenerationProgress()

        Task {
            try? await env.resetPredictor()
        }
    }

    // MARK: - Image Loading

    func handleDrop(providers: [NSItemProvider]) {
        guard let provider = providers.first else { return }
        clearAnnotations()

        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                if let data = item as? Data, let url = URL(dataRepresentation: data, relativeTo: nil) {
                    self.loadImage(from: url)
                } else if let url = item as? URL {
                    self.loadImage(from: url)
                }
            }
            return
        }

        for type in provider.registeredTypeIdentifiers {
            if let utType = UTType(type), utType.conforms(to: .image) {
                if provider.canLoadObject(ofClass: NSImage.self) {
                    _ = provider.loadObject(ofClass: NSImage.self) { image, _ in
                        if let image = image as? NSImage {
                            self.saveAndLoad(image: image)
                        }
                    }
                    return
                }

                provider.loadItem(forTypeIdentifier: type, options: nil) { item, _ in
                    if let url = item as? URL {
                        self.loadImage(from: url)
                    } else if let data = item as? Data, let image = NSImage(data: data) {
                        self.saveAndLoad(image: image)
                    }
                }
                return
            }
        }

        if provider.canLoadObject(ofClass: URL.self) {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                if let url = url {
                    self.loadImage(from: url)
                }
            }
        }
    }

    private func saveAndLoad(image: NSImage) {
        let tempDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/ModelrV3", isDirectory: true)
        let tempFile = tempDir.appendingPathComponent("temp_drop.png")

        Task.detached(priority: .userInitiated) {
            do {
                try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
                // Use a proper bitmap rep from the image to preserve quality
                guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
                let bitmap = NSBitmapImageRep(cgImage: cgImage)
                if let data = bitmap.representation(using: .png, properties: [:]) {
                    try data.write(to: tempFile)
                    await MainActor.run {
                        self.loadImage(from: tempFile)
                    }
                }
            } catch {
                print("Failed to save dropped image: \(error.localizedDescription)")
            }
        }
    }

    private func loadImage(from url: URL) {
        // Cancel any existing tasks
        currentTasks.forEach { $0.cancel() }
        currentTasks.removeAll()

        // Invalidate cached display size
        cachedDisplaySize = .zero

        // Load image on background thread with high priority
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
                self.cacheSourceAlpha()  // Cache alpha for transparency filtering
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

    private func getOrientedPixelSize(for image: NSImage, at url: URL) -> CGSize {
        // Use CGImageSource to get metadata without loading full pixels into memory if possible
        if let source = CGImageSourceCreateWithURL(url as CFURL, nil),
           let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
           let pW = props[kCGImagePropertyPixelWidth] as? CGFloat,
           let pH = props[kCGImagePropertyPixelHeight] as? CGFloat {
            
            let orientation = props[kCGImagePropertyOrientation] as? Int ?? 1
            // 5-8 means 90 or 270 degree rotation (and possibly mirroring)
            if orientation >= 5 && orientation <= 8 {
                return CGSize(width: pH, height: pW)
            }
            return CGSize(width: pW, height: pH)
        }
        
        // Fallback: Use NSImage.size but treat it as pixels (often true if no 1x/2x reps)
        // Or get it from the first representation
        if let rep = image.representations.first {
             return CGSize(width: CGFloat(rep.pixelsWide), height: CGFloat(rep.pixelsHigh))
        }
        
        return image.size
    }

    private func saveImageForBackend(image: NSImage) {
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
}

// MARK: - ToolButton Component

struct ToolButton: View {
    let tool: SAMTool
    let isSelected: Bool
    let action: () -> Void
    
    @State private var isHovered = false
    
    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: tool.iconName)
                    .font(.system(size: 16, weight: isSelected ? .semibold : .regular))
                    .symbolRenderingMode(.hierarchical)
                
                Text(tool.rawValue)
                    .font(.caption2)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 50)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isSelected ? Color.accentColor.opacity(0.2) : (isHovered ? Color.secondary.opacity(0.1) : Color.clear))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(isSelected ? Color.accentColor : Color.clear, lineWidth: 1.5)
            )
        }
        .buttonStyle(.plain)
        .foregroundColor(isSelected ? .accentColor : .primary)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovered = hovering
            }
        }
    }
}

#Preview {
    ContentView()
}
