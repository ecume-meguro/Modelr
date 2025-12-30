import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @StateObject private var env = PythonEnvironment()

    // Image state
    @State private var inputImage: NSImage?
    @State private var inputImagePath: String?
    @State private var maskImage: NSImage?
    @State private var isDragging = false
    @State private var imagePixelSize: CGSize = .zero
    @State private var cachedDisplaySize: CGSize = .zero

    // Multi-point state
    @State private var selectedPoints: [SAMPoint] = []
    @State private var boundingBoxes: [SAMBox] = []
    @State private var currentBox: SAMBox?

    // Lasso state
    @State private var lassoSelections: [LassoSelection] = []
    @State private var currentLasso: LassoSelection?

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

    // Undo history
    @State private var undoStack: [UndoAction] = []

    // Tool state
    @State private var selectedTool: SAMTool = .point
    @State private var selectedTab: SidebarTab = .preprocess

    // Zoom state
    @State private var magnification: CGFloat = 1.0

    // Generate state
    @State private var generateSteps: Double = 30
    @State private var generateResolution: Double = 256
    @State private var isGenerating = false
    @State private var generationProgress = GenerationProgress()
    @State private var generationStartTime: Date?
    @State private var generated3DModelURL: URL?

    // Performance optimization: dirty flag for mask to avoid unnecessary file writes
    @State private var maskIsDirty = false

    // Task cancellation support
    @State private var currentTasks: Set<Task<Void, Never>> = []
    
    // State to force UI refresh when image content changes but path stays same
    @State private var imageVersion: Int = 0

    var body: some View {
        VStack(spacing: 0) {
            if !env.isSetup {
                SplashScreenView(env: env)
            } else {
                mainEditorView
            }
        }
        .frame(minWidth: 1000, minHeight: 700)
        // Re-inference triggers - combined for efficiency
        .onChange(of: selectedPoints.count) { _, _ in triggerReInference() }
        .onChange(of: boundingBoxes.count) { _, _ in triggerReInference() }
        .onChange(of: lassoSelections.count) { _, _ in triggerReInference() }
        // Hidden button for Cmd+Z undo keyboard shortcut
        .background(
            Button("") { performUndo() }
                .keyboardShortcut("z", modifiers: .command)
                .opacity(0)
        )
    }

    // MARK: - Main Editor View

    var mainEditorView: some View {
        HSplitView {
            // Left: Image area (70%)
            imageArea
                .frame(minWidth: 500)

            // Right: Sidebar (30%) - only show when image loaded
            if inputImage != nil {
                sidebarView
                    .frame(minWidth: 280, maxWidth: 350)
            }
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

    // Map current tab/tool to SAMTool for ZoomableImageView
    private var effectiveToolMode: SAMTool {
        switch selectedTab {
        case .preprocess:
            // Map preprocess tools to equivalent SAMTool gestures
            switch selectedPreprocessTool {
            case .crop:
                return .boundingBox  // Uses drag for rectangle
            case .lassoDelete:
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

            // Show 3D viewer only on Generate tab when we have a model
            if selectedTab == .generate, let modelURL = generated3DModelURL, !isGenerating {
                model3DViewer(url: modelURL)
            }
            // Show generation progress during generation (only on Generate tab)
            else if selectedTab == .generate && isGenerating {
                generationProgressView
            }
            // Show image editor for Preprocess/Segment tabs, or Generate tab without a model
            else if let inputImage = inputImage {
                ZoomableImageView(
                    magnification: $magnification,
                    onTap: { normalized in
                        handleTap(at: normalized)
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
                    toolMode: effectiveToolMode,
                    contentSize: displaySize,
                    contentID: "\(inputImagePath ?? "")_v\(imageVersion)"
                ) {
                    ZStack {
                        Image(nsImage: inputImage)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: displaySize.width, height: displaySize.height)

                        // Only show mask in segment/generate modes
                        if selectedTab != .preprocess, let maskImage = maskImage {
                            Image(nsImage: maskImage)
                                .resizable()
                                .frame(width: displaySize.width, height: displaySize.height)
                                .allowsHitTesting(false)
                                .opacity(0.6)
                        }

                        // Paint strokes overlay (segment mode)
                        if selectedTab == .segment {
                            PaintStrokeOverlay(
                                strokes: paintStrokes,
                                currentStroke: currentPaintStroke,
                                displayedSize: displaySize
                            )
                            .frame(width: displaySize.width, height: displaySize.height)
                        }

                        // Lasso overlay for segment mode
                        if selectedTab == .segment && selectedTool == .lasso {
                            LassoOverlay(
                                lassoSelections: lassoSelections,
                                currentLasso: currentLasso,
                                displayedSize: displaySize,
                                isPreprocessMode: false
                            )
                            .frame(width: displaySize.width, height: displaySize.height)
                        }

                        // Preprocess overlays
                        if selectedTab == .preprocess {
                            if selectedPreprocessTool == .crop {
                                CropOverlay(cropRect: cropRect, displayedSize: displaySize)
                                    .frame(width: displaySize.width, height: displaySize.height)
                            } else if selectedPreprocessTool == .lassoDelete {
                                LassoOverlay(
                                    lassoSelections: [],
                                    currentLasso: preprocessLasso,
                                    displayedSize: displaySize,
                                    isPreprocessMode: true
                                )
                                .frame(width: displaySize.width, height: displaySize.height)
                            }
                        }

                        // Points overlay (segment mode)
                        if selectedTab == .segment {
                            PointsOverlay(points: selectedPoints, displayedSize: displaySize)
                                .frame(width: displaySize.width, height: displaySize.height)
                        }

                        // Bounding box overlay (segment mode)
                        if selectedTab == .segment {
                            BoundingBoxOverlay(
                                boxes: boundingBoxes,
                                currentBox: currentBox,
                                displayedSize: displaySize
                            )
                            .frame(width: displaySize.width, height: displaySize.height)
                        }

                        // Brush cursor preview (segment paint mode)
                        if selectedTab == .segment && selectedTool == .paint {
                            BrushCursorPreview(
                                brushSize: brushSize,
                                isErasing: isErasing,
                                displayedSize: displaySize
                            )
                            .frame(width: displaySize.width, height: displaySize.height)
                        }
                    }
                    .frame(width: displaySize.width, height: displaySize.height)
                }
                .zoomControls(magnification: $magnification)
            } else {
                dropZone
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

    private func formatElapsedTime(_ elapsed: TimeInterval) -> String {
        let minutes = Int(elapsed) / 60
        let seconds = Int(elapsed) % 60
        if minutes > 0 {
            return String(format: "Elapsed: %d:%02d", minutes, seconds)
        } else {
            return String(format: "Elapsed: %ds", seconds)
        }
    }

    // MARK: - Drop Zone

    var dropZone: some View {
        RoundedRectangle(cornerRadius: 12)
            .strokeBorder(isDragging ? Color(red: 0.1, green: 0.3, blue: 0.7) : Color.gray.opacity(0.5), style: StrokeStyle(lineWidth: 2, dash: [10]))
            .background(Color.gray.opacity(0.05))
            .overlay(
                VStack(spacing: 16) {
                    Image(systemName: "photo.on.rectangle.angled")
                        .font(.system(size: 56))
                        .foregroundColor(.gray)
                    Text("Drop an image here")
                        .font(.title2)
                        .foregroundColor(.gray)
                    Text("or click to browse")
                        .font(.subheadline)
                        .foregroundColor(.secondary)

                    Button(action: openFilePicker) {
                        Label("Choose Image", systemImage: "folder")
                            .padding(.horizontal, 20)
                            .padding(.vertical, 10)
                    }
                    .buttonStyle(.borderedProminent)
                    .padding(.top, 8)

                    Text("⌘V to paste from clipboard")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .padding(.top, 4)
                }
            )
            .contentShape(Rectangle())
            .onTapGesture {
                openFilePicker()
            }
            .onDrop(of: [.image, .fileURL, .url], isTargeted: $isDragging) { providers in
                handleDrop(providers: providers)
                return true
            }
            .padding(40)
    }

    // MARK: - Sidebar View

    var sidebarView: some View {
        VStack(spacing: 0) {
            // Tab picker
            Picker("", selection: $selectedTab) {
                ForEach(SidebarTab.allCases, id: \.self) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .padding()

            Divider()

            // Tab content
            ScrollView {
                switch selectedTab {
                case .preprocess:
                    preprocessTabContent
                case .segment:
                    segmentTabContent
                case .generate:
                    generateTabContent
                }
            }

            Divider()

            // Status footer
            statusFooter
        }
        .background(Color(NSColor.windowBackgroundColor))
    }

    // MARK: - Preprocess Tab

    var preprocessTabContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Tool Selection
            VStack(alignment: .leading, spacing: 8) {
                Text("Tool")
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
            } else if selectedPreprocessTool == .lassoDelete {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Lasso Delete")
                        .font(.headline)
                        .foregroundColor(.secondary)

                    Text("Draw a freeform selection around the area you want to remove.")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    if preprocessLasso != nil && (preprocessLasso?.isValid ?? false) {
                        HStack(spacing: 8) {
                            Button(action: applyLassoDelete) {
                                Label("Delete Selection", systemImage: "trash")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(.red)

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
                    case .lassoDelete:
                        Text("• Drag to draw a selection")
                        Text("• Click Delete to remove the area")
                        Text("• Use Cmd+Z to undo")
                    }
                }
                .font(.caption)
                .foregroundColor(.secondary)
            }

            Spacer()

            // Next step hint
            VStack(spacing: 8) {
                Text("When done preprocessing, switch to the Segment tab.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)

                Button(action: { selectedTab = .segment }) {
                    Label("Go to Segment", systemImage: "arrow.right")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
        }
        .padding()
    }

    // MARK: - Segment Tab

    var segmentTabContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Tool Selection
            VStack(alignment: .leading, spacing: 8) {
                Text("Tool")
                    .font(.headline)
                    .foregroundColor(.secondary)

                Picker("Tool", selection: $selectedTool) {
                    ForEach(SAMTool.allCases) { tool in
                        Label(tool.rawValue, systemImage: tool.iconName)
                            .tag(tool)
                    }
                }
                .pickerStyle(.segmented)
            }

            // Paint Tool Options
            if selectedTool == .paint {
                Divider()

                VStack(alignment: .leading, spacing: 8) {
                    Text("Brush Settings")
                        .font(.headline)
                        .foregroundColor(.secondary)

                    // Brush size slider
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("Brush Size")
                            Spacer()
                            Text("\(Int(brushSize * 100))%")
                                .foregroundColor(.secondary)
                        }
                        .font(.subheadline)

                        Slider(value: $brushSize, in: 0.01...0.15, step: 0.005)

                        Text("Size relative to image width")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }

                    // Erase toggle - use SAM2 mask color for add mode
                    Toggle(isOn: $isErasing) {
                        HStack {
                            Image(systemName: isErasing ? "eraser.fill" : "paintbrush.pointed.fill")
                                .foregroundColor(isErasing ? .red : Color(red: 50/255, green: 100/255, blue: 200/255))
                            Text(isErasing ? "Erase Mode" : "Add Mode")
                        }
                    }
                    .toggleStyle(.switch)

                    // Apply/Clear paint buttons
                    HStack(spacing: 8) {
                        Button(action: applyPaintToMask) {
                            Label("Apply", systemImage: "checkmark.circle")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(paintStrokes.isEmpty)

                        Button(action: clearPaintStrokes) {
                            Label("Clear", systemImage: "xmark.circle")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .disabled(paintStrokes.isEmpty)
                    }
                }
            }

            Divider()

            // Annotations
            VStack(alignment: .leading, spacing: 8) {
                Text("Annotations")
                    .font(.headline)
                    .foregroundColor(.secondary)

                HStack {
                    VStack(alignment: .leading) {
                        HStack(spacing: 4) {
                            Image(systemName: "hand.point.up.left.fill")
                                .foregroundColor(.red)
                            Text("\(selectedPoints.count) points")
                        }
                        HStack(spacing: 4) {
                            Image(systemName: "rectangle.dashed")
                                .foregroundColor(.blue)
                            Text("\(boundingBoxes.count) boxes")
                        }
                        HStack(spacing: 4) {
                            Image(systemName: "lasso")
                                .foregroundColor(Color(red: 50/255, green: 100/255, blue: 200/255))
                            Text("\(lassoSelections.count) lassos")
                        }
                        HStack(spacing: 4) {
                            Image(systemName: "paintbrush.pointed.fill")
                                .foregroundColor(Color(red: 50/255, green: 100/255, blue: 200/255))
                            Text("\(paintStrokes.count) strokes")
                        }
                    }
                    .font(.subheadline)

                    Spacer()

                    if !selectedPoints.isEmpty || !boundingBoxes.isEmpty || !lassoSelections.isEmpty || !paintStrokes.isEmpty {
                        Button("Clear") {
                            clearAnnotations()
                        }
                        .buttonStyle(.bordered)
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
                    switch selectedTool {
                    case .point:
                        Text("• Click to add points on the object")
                        Text("• Multiple points refine the selection")
                    case .boundingBox:
                        Text("• Drag to draw a bounding box")
                        Text("• Box should contain the object")
                    case .lasso:
                        Text("• Drag to draw a freeform selection")
                        Text("• Lasso should surround the object")
                        Text("• Uses bounding box for SAM2 inference")
                    case .paint:
                        Text("• Drag to paint on the mask")
                        Text("• Use Add mode to extend selection")
                        Text("• Use Erase mode to remove areas")
                        Text("• Click Apply to update the mask")
                    }
                }
                .font(.caption)
                .foregroundColor(.secondary)
            }

            Spacer()

            // Clear Image Button
            Button(action: clearAll) {
                Label("Clear Image", systemImage: "xmark.circle")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
        }
        .padding()
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
                // Parameters
                VStack(alignment: .leading, spacing: 8) {
                    Text("Parameters")
                        .font(.headline)
                        .foregroundColor(.secondary)

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

                        Text("Higher = better quality, slower")
                            .font(.caption2)
                            .foregroundColor(.secondary)
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

                        Slider(value: $generateResolution, in: 128...1024, step: 64)

                        Text("Higher = finer detail, more memory")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }

                Divider()

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

    // MARK: - File Picker

    private func openFilePicker() {
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

    private func handleTap(at normalized: CGPoint) {
        guard selectedTab == .segment, selectedTool == .point else { return }
        guard inputImage != nil, inputImagePath != nil else { return }

        // Coordinates are already normalized 0-1 from ImageCanvasView
        let point = SAMPoint(normalizedCoords: normalized)

        withAnimation(.spring(response: 0.3)) {
            selectedPoints.append(point)
            undoStack.append(.addPoint(point))
        }
    }

    private func handleDragStart(at point: CGPoint) {
        guard inputImage != nil else { return }

        if selectedTab == .preprocess && selectedPreprocessTool == .crop {
            cropRect = SAMBox(startPoint: point, endPoint: point)
        } else if selectedTab == .segment && selectedTool == .boundingBox {
            currentBox = SAMBox(startPoint: point, endPoint: point)
        }
    }

    private func handleDragChange(start: CGPoint, current: CGPoint) {
        if selectedTab == .preprocess && selectedPreprocessTool == .crop {
            cropRect?.endPoint = current
        } else if selectedTab == .segment && selectedTool == .boundingBox {
            currentBox?.endPoint = current
        }
    }

    private func handleDragEnd(start: CGPoint, end: CGPoint) {
        if selectedTab == .preprocess && selectedPreprocessTool == .crop {
            // Crop rect stays until user applies or clears
            return
        }

        guard selectedTab == .segment, selectedTool == .boundingBox else { return }
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

        if selectedTab == .preprocess && selectedPreprocessTool == .lassoDelete {
            preprocessLasso = LassoSelection(startPoint: point)
        } else if selectedTab == .segment && selectedTool == .lasso {
            currentLasso = LassoSelection(startPoint: point)
        }
    }

    private func handleLassoContinue(at point: CGPoint) {
        if selectedTab == .preprocess && selectedPreprocessTool == .lassoDelete {
            preprocessLasso?.addPoint(point)
        } else if selectedTab == .segment && selectedTool == .lasso {
            currentLasso?.addPoint(point)
        }
    }

    private func handleLassoEnd() {
        if selectedTab == .preprocess && selectedPreprocessTool == .lassoDelete {
            // Keep the lasso until user applies delete
            return
        }

        guard selectedTab == .segment, selectedTool == .lasso else { return }
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
        currentPaintStroke?.addPoint(point)
    }

    private func handlePaintEnd() {
        guard selectedTool == .paint else { return }
        guard let stroke = currentPaintStroke, stroke.points.count >= 1 else {
            currentPaintStroke = nil
            return
        }

        withAnimation(.easeOut(duration: 0.1)) {
            paintStrokes.append(stroke)
            currentPaintStroke = nil
        }
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
            let firstPoint = stroke.points[0]
            path.move(to: CGPoint(
                x: firstPoint.x * cgWidth,
                y: firstPoint.y * cgHeight
            ))

            for i in 1..<stroke.points.count {
                let point = stroke.points[i]
                path.line(to: CGPoint(
                    x: point.x * cgWidth,
                    y: point.y * cgHeight
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
                    y: point.y * cgHeight - brushRadius,
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
        return newImage
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
                let pixelSize = try await env.setImage(path: path)
                await MainActor.run {
                    guard !Task.isCancelled else { return }
                    self.imagePixelSize = pixelSize
                }

                 let maskURL = try await env.predict(
                    points: selectedPoints,
                    box: effectiveBox,
                    imageSize: pixelSize
                )

                if let newMask = NSImage(contentsOf: maskURL) {
                    await MainActor.run {
                        guard !Task.isCancelled else { return }
                        self.maskImage = newMask
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
                    self.isGenerating = false
                    self.generationStartTime = nil
                    switch result {
                    case .success(let url):
                        self.generated3DModelURL = url
                        self.generationProgress = GenerationProgress()
                    case .failure(let error):
                        self.generationProgress.stage = "Error: \(error.localizedDescription)"
                    }
                }
            }
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
        // The mask is saved by the predict function as mask.png
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
            maskImage = nil
            undoStack.removeAll()
        }
    }

    // MARK: - Undo

    private func performUndo() {
        guard !undoStack.isEmpty else { return }
        let action = undoStack.removeLast()

        withAnimation(.easeOut(duration: 0.2)) {
            switch action {
            case .addPoint(let point):
                selectedPoints.removeAll { $0.id == point.id }
            case .addBox(let box):
                boundingBoxes.removeAll { $0.id == box.id }
            case .addLasso(let lasso):
                lassoSelections.removeAll { $0.id == lasso.id }
            case .addPaintStroke(let stroke):
                paintStrokes.removeAll { $0.id == stroke.id }
            case .crop(let originalImage, let originalPath):
                inputImage = originalImage
                inputImagePath = originalPath
            }
        }

        // Trigger re-inference after undo
        triggerReInference()
    }

    // MARK: - Preprocess Actions

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
        saveAndLoad(image: croppedImage)

        cropRect = nil
        env.status = "Image cropped"
    }



    private func applyLassoDelete() {
        guard let image = inputImage,
              let lasso = preprocessLasso,
              lasso.isValid else { return }

        // Save for undo
        undoStack.append(.crop(originalImage: image, originalPath: inputImagePath))

        // Apply lasso deletion (fill with transparency)
        if let deletedImage = deleteInsideLasso(image, lasso: lasso) {
            inputImage = deletedImage
            saveAndLoad(image: deletedImage)
        }

        preprocessLasso = nil
        env.status = "Selection deleted"
    }

    private func deleteInsideLasso(_ image: NSImage, lasso: LassoSelection) -> NSImage? {
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
        
        let ciContext = CIContext(options: nil)
        let ciImage = CIImage(cgImage: cgImage)
        if let cgDrawn = ciContext.createCGImage(ciImage, from: ciImage.extent) {
            let nsDrawn = NSImage(cgImage: cgDrawn, size: imageSize)
            nsDrawn.draw(in: NSRect(origin: .zero, size: imageSize))
        }

        let cgWidth = CGFloat(width)
        let cgHeight = CGFloat(height)

        // Use NSBezierPath to clear the lasso area efficiently
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

        // Use copy compositing operation to clear pixels with transparent color
        let originalComposite = context?.compositingOperation
        context?.compositingOperation = .copy

        // Fill lasso area with transparent color
        NSColor.clear.setFill()
        path.fill()

        // Restore original compositing operation
        if let originalOp = originalComposite {
            context?.compositingOperation = originalOp
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

#Preview {
    ContentView()
}
