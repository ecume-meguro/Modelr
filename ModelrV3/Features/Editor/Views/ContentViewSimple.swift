import SwiftUI
import UniformTypeIdentifiers

/// Simple MVP ContentView - minimal UI for: Input -> Segment -> Generate
struct ContentViewSimple: View {
    @StateObject private var env = PythonEnvironment()

    // Core state
    @State private var inputImage: NSImage?
    @State private var inputImagePath: String?
    @State private var imagePixelSize: CGSize = .zero
    @State private var zoomScale: CGFloat = 1.0

    // Workflow state
    enum Step { case input, segment, touchup, generate }
    @State private var currentStep: Step = .input

    // Touchup state
    enum BrushMode { case add, remove }
    @State private var brushMode: BrushMode = .add
    @State private var brushSize: CGFloat = 30
    @State private var editableMaskImage: NSImage?
    @State private var brushPreviewPosition: CGPoint? = nil
    @State private var showBackWarning: Bool = false
    @State private var showDiscardModelWarning: Bool = false
    @State private var showDiscardImageWarning: Bool = false
    @State private var showStartOverWarning: Bool = false
    @State private var maskHistory: [NSImage] = []  // Undo stack
    @State private var isStrokeInProgress: Bool = false

    // Segmentation state
    @State private var textPrompt: String = ""
    @State private var textSearchPerformed: Bool = false
    @State private var selectedPoints: [SAMPoint] = []
    @State private var isDragging = false
    @State private var useExistingAlpha: Bool = false
    @State private var imageHasAlpha: Bool = false

    // Multi-mask state
    @State private var allMasks: [(image: NSImage, score: Double, url: URL)] = []
    @State private var selectedMaskIndex: Int = 0

    // Generation state
    @State private var isGenerating = false
    @State private var generationStatus = ""
    @State private var generated3DModelURL: URL?
    @State private var compositeImage: NSImage?
    @State private var generationStartTime: Date?
    @State private var generationDuration: TimeInterval?

    // Generation settings
    @State private var selectedPreset: QualityPreset = .normal
    @State private var showAdvancedSettings = false
    @State private var customSteps: Double = 35
    @State private var customResolution: Double = 256

    // Multi-stage generation progress
    @State private var generationStages: [GenerationStage: StageProgress] = [:]

    // Generation stage definitions
    enum GenerationStage: String, CaseIterable {
        case extracting = "Extracting"
        case loading = "Loading Model"
        case diffusion = "Diffusion Sampling"
        case volumeDecoding = "Volume Decoding"
        case saving = "Saving"
    }

    struct StageProgress {
        var status: StageStatus = .pending
        var progress: Double = 0  // 0-1
        var detail: String = ""
    }

    enum StageStatus {
        case pending
        case inProgress
        case completed
        case cancelled  // User stopped generation at this step
        case failed     // Remaining steps after cancellation
    }

    // 10 Neon colors for mask regions
    private let maskColors: [Color] = [
        Color(red: 0x39/255, green: 0xFF/255, blue: 0x14/255),  // #39FF14 Neon Green
        Color(red: 0xFF/255, green: 0x10/255, blue: 0xF0/255),  // #FF10F0 Neon Pink
        Color(red: 0xFF/255, green: 0xFF/255, blue: 0x00/255),  // #FFFF00 Neon Yellow
        Color(red: 0x00/255, green: 0xCA/255, blue: 0xFF/255),  // #00CAFF Neon Blue
        Color(red: 0xFF/255, green: 0x7E/255, blue: 0x00/255),  // #FF7E00 Neon Orange
        Color(red: 0xB9/255, green: 0x15/255, blue: 0xCC/255),  // #B915CC Neon Purple
        Color(red: 0xFF/255, green: 0x00/255, blue: 0x4D/255),  // #FF004D Neon Red
        Color(red: 0x00/255, green: 0xFF/255, blue: 0xFF/255),  // #00FFFF Neon Cyan
        Color(red: 0xDF/255, green: 0xFF/255, blue: 0x00/255),  // #DFFF00 Electric Lime
        Color(red: 0xFF/255, green: 0x00/255, blue: 0xFF/255),  // #FF00FF Hot Magenta
    ]

    private func colorForMask(_ index: Int) -> Color {
        maskColors[index % maskColors.count]
    }

    var body: some View {
        HStack(spacing: 0) {
            // Image area (main content)
            imageArea
                .frame(minWidth: 500)

            Divider()

            // Sidebar
            sidebar
                .frame(width: 260)
        }
        .frame(minWidth: 800, minHeight: 600)
        .onDrop(of: [.image, .fileURL], isTargeted: $isDragging) { providers in
            handleDrop(providers: providers)
        }
        .background(
            // Hidden button for Command+Z undo
            Button("") { if currentStep == .touchup { undo() } }
                .keyboardShortcut("z", modifiers: .command)
                .hidden()
        )
        .task {
            // Preload SAM model on app launch
            await env.preloadSAMModel()
        }
    }

    // MARK: - Image Area

    private var imageArea: some View {
        ZStack {
            Color(NSColor.textBackgroundColor).opacity(0.3)

            imageContent

            // Scroll wheel zoom overlay - captures scroll and converts to zoom
            // Only show when NOT viewing 3D model (3D viewer has its own controls)
            if !(currentStep == .generate && generated3DModelURL != nil) {
                ScrollWheelZoomOverlay(zoomScale: $zoomScale, minZoom: 0.5, maxZoom: 5.0)
            }
        }
    }

    @ViewBuilder
    private var imageContent: some View {
        ZStack {

            if currentStep == .generate, let modelURL = generated3DModelURL {
                ModelViewerContainer(modelURL: modelURL)
            } else if currentStep == .generate, let composite = compositeImage {
                // Show composite image preview before/during generation
                GeometryReader { geo in
                    let size = fitSize(composite.size, in: geo.size)
                    VStack {
                        Image(nsImage: composite)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: size.width, height: size.height)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else if let image = inputImage {
                GeometryReader { geo in
                    let size = fitSize(image.size, in: geo.size)

                    ZStack {
                        Image(nsImage: image)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: size.width, height: size.height)

                        if currentStep == .segment {
                            // Show ALL masks - non-selected first, then selected on top
                            // Non-selected masks
                            ForEach(Array(allMasks.enumerated()).filter { $0.offset != selectedMaskIndex }, id: \.offset) { index, maskData in
                                let color = colorForMask(index)

                                // Mask fill
                                Rectangle()
                                    .fill(color)
                                    .frame(width: size.width, height: size.height)
                                    .mask(
                                        Image(nsImage: maskData.image)
                                            .resizable()
                                            .frame(width: size.width, height: size.height)
                                    )
                                    .opacity(0.60)
                                    .allowsHitTesting(false)

                                // Border
                                Rectangle()
                                    .fill(color)
                                    .frame(width: size.width, height: size.height)
                                    .mask(
                                        ZStack {
                                            Image(nsImage: maskData.image)
                                                .resizable()
                                                .frame(width: size.width, height: size.height)
                                            Image(nsImage: maskData.image)
                                                .resizable()
                                                .frame(width: size.width, height: size.height)
                                                .padding(8)
                                                .blur(radius: 1)
                                                .blendMode(.destinationOut)
                                        }
                                        .compositingGroup()
                                    )
                                    .opacity(1.0)
                                    .allowsHitTesting(false)
                            }

                            // Selected mask on top
                            if selectedMaskIndex < allMasks.count {
                                let maskData = allMasks[selectedMaskIndex]
                                let color = colorForMask(selectedMaskIndex)

                                // Mask fill
                                Rectangle()
                                    .fill(color)
                                    .frame(width: size.width, height: size.height)
                                    .mask(
                                        Image(nsImage: maskData.image)
                                            .resizable()
                                            .frame(width: size.width, height: size.height)
                                    )
                                    .opacity(0.90)
                                    .allowsHitTesting(false)

                                // Border
                                Rectangle()
                                    .fill(color)
                                    .frame(width: size.width, height: size.height)
                                    .mask(
                                        ZStack {
                                            Image(nsImage: maskData.image)
                                                .resizable()
                                                .frame(width: size.width, height: size.height)
                                            Image(nsImage: maskData.image)
                                                .resizable()
                                                .frame(width: size.width, height: size.height)
                                                .padding(12)
                                                .blur(radius: 1)
                                                .blendMode(.destinationOut)
                                        }
                                        .compositingGroup()
                                    )
                                    .opacity(1.0)
                                    .allowsHitTesting(false)
                            }

                            // Points overlay
                            ForEach(selectedPoints) { point in
                                Circle()
                                    .fill(point.isPositive ? Color.green : Color.red)
                                    .frame(width: 14, height: 14)
                                    .overlay(Circle().stroke(Color.white, lineWidth: 2))
                                    .position(
                                        x: point.normalizedCoords.x * size.width,
                                        y: point.normalizedCoords.y * size.height
                                    )
                            }
                        }

                        // Touchup mode - show editable mask
                        if currentStep == .touchup, let maskImage = editableMaskImage {
                            // Mask overlay
                            Rectangle()
                                .fill(Color.red)
                                .frame(width: size.width, height: size.height)
                                .mask(
                                    Image(nsImage: maskImage)
                                        .resizable()
                                        .frame(width: size.width, height: size.height)
                                )
                                .opacity(0.70)
                                .allowsHitTesting(false)

                            // Border
                            Rectangle()
                                .fill(Color.red)
                                .frame(width: size.width, height: size.height)
                                .mask(
                                    ZStack {
                                        Image(nsImage: maskImage)
                                            .resizable()
                                            .frame(width: size.width, height: size.height)
                                        Image(nsImage: maskImage)
                                            .resizable()
                                            .frame(width: size.width, height: size.height)
                                            .padding(10)
                                            .blur(radius: 1)
                                            .blendMode(.destinationOut)
                                    }
                                    .compositingGroup()
                                )
                                .opacity(1.0)
                                .allowsHitTesting(false)

                            // Brush preview circle
                            if let pos = brushPreviewPosition {
                                let scaledBrushSize = brushSize * size.width / 500.0
                                Circle()
                                    .stroke(brushMode == .add ? Color.green : Color.red, lineWidth: 2)
                                    .frame(width: scaledBrushSize, height: scaledBrushSize)
                                    .position(x: pos.x * size.width, y: pos.y * size.height)
                                    .allowsHitTesting(false)
                            }
                        }
                    }
                    .frame(width: size.width, height: size.height)
                    .position(x: geo.size.width / 2, y: geo.size.height / 2)
                    .contentShape(Rectangle())
                    .overlay(
                        RightClickHandler { location in
                            if currentStep == .segment {
                                let normalized = CGPoint(
                                    x: location.x / size.width,
                                    y: location.y / size.height
                                )
                                if normalized.x >= 0 && normalized.x <= 1 && normalized.y >= 0 && normalized.y <= 1 {
                                    addPoint(at: normalized)
                                }
                            }
                        }
                        .frame(width: size.width, height: size.height)
                    )
                    .onTapGesture { location in
                        let normalized = CGPoint(
                            x: (location.x - (geo.size.width - size.width) / 2) / size.width,
                            y: (location.y - (geo.size.height - size.height) / 2) / size.height
                        )
                        guard normalized.x >= 0 && normalized.x <= 1 && normalized.y >= 0 && normalized.y <= 1 else { return }

                        if currentStep == .segment && !allMasks.isEmpty {
                            // Left-click to select existing mask regions
                            if let clickedIndex = findMaskAtPoint(normalized, displaySize: size) {
                                selectedMaskIndex = clickedIndex
                            }
                        } else if currentStep == .touchup {
                            // Single click to paint
                            saveUndoState()
                            paintOnMask(at: normalized)
                        }
                    }
                    .onContinuousHover { phase in
                        if currentStep == .touchup {
                            switch phase {
                            case .active(let location):
                                let normalized = CGPoint(
                                    x: (location.x - (geo.size.width - size.width) / 2) / size.width,
                                    y: (location.y - (geo.size.height - size.height) / 2) / size.height
                                )
                                if normalized.x >= 0 && normalized.x <= 1 && normalized.y >= 0 && normalized.y <= 1 {
                                    brushPreviewPosition = normalized
                                } else {
                                    brushPreviewPosition = nil
                                }
                            case .ended:
                                brushPreviewPosition = nil
                            }
                        } else {
                            brushPreviewPosition = nil
                        }
                    }
                    .gesture(
                        currentStep == .touchup ?
                        DragGesture(minimumDistance: 1)
                            .onChanged { value in
                                // Save mask state at start of stroke
                                if !isStrokeInProgress {
                                    isStrokeInProgress = true
                                    saveUndoState()
                                }

                                let normalized = CGPoint(
                                    x: (value.location.x - (geo.size.width - size.width) / 2) / size.width,
                                    y: (value.location.y - (geo.size.height - size.height) / 2) / size.height
                                )
                                if normalized.x >= 0 && normalized.x <= 1 && normalized.y >= 0 && normalized.y <= 1 {
                                    brushPreviewPosition = normalized
                                    paintOnMask(at: normalized)
                                }
                            }
                            .onEnded { _ in
                                isStrokeInProgress = false
                            }
                        : nil
                    )
                    .scaleEffect(zoomScale)
                    .gesture(
                        MagnificationGesture()
                            .onChanged { value in
                                zoomScale = max(0.5, min(5.0, value))
                            }
                    )
                }
                .overlay(alignment: .bottomTrailing) {
                    // Zoom controls
                    if zoomScale != 1.0 {
                        Button(action: { withAnimation { zoomScale = 1.0 } }) {
                            HStack(spacing: 4) {
                                Text("\(Int(zoomScale * 100))%")
                                    .font(.caption.monospacedDigit())
                                Image(systemName: "arrow.counterclockwise")
                                    .font(.caption)
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(.ultraThinMaterial)
                            .cornerRadius(6)
                        }
                        .buttonStyle(.plain)
                        .padding(12)
                    }
                }
            } else {
                // Drop zone
                VStack(spacing: 12) {
                    Image(systemName: "photo")
                        .font(.system(size: 40))
                        .foregroundColor(.secondary)

                    Text("Drop image here")
                        .foregroundColor(.secondary)

                    Button("Select File") { selectImage() }
                        .buttonStyle(.borderedProminent)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [6, 3]))
                        .foregroundColor(.gray.opacity(0.4))
                        .padding(20)
                )
            }
        }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Title
            Text("Modelr")
                .font(.title2.bold())

            Divider()

            // Step 1: Input
            stepSection(number: 1, title: "Input", isActive: currentStep == .input, isDone: inputImage != nil) {
                if inputImage != nil {
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 12))
                            .foregroundColor(.green)
                        Text("Image loaded")
                            .font(.caption)
                    }
                }
            }

            // Step 2: Segment
            stepSection(number: 2, title: "Segment", isActive: currentStep == .segment, isDone: currentStep == .touchup || currentStep == .generate) {
                if currentStep == .segment {
                    // Full segment controls when active
                    VStack(alignment: .leading, spacing: 8) {
                        // Pre-segmented toggle (if image has alpha)
                        if imageHasAlpha {
                            Toggle(isOn: $useExistingAlpha) {
                                Text("Already segmented")
                                    .font(.caption)
                            }
                            .toggleStyle(.checkbox)
                            .onChange(of: useExistingAlpha) { _, newValue in
                                if newValue {
                                    createMaskFromAlpha()
                                } else {
                                    allMasks.removeAll()
                                    selectedMaskIndex = 0
                                }
                            }

                            if useExistingAlpha {
                                HStack(spacing: 6) {
                                    Image(systemName: "checkmark.circle.fill")
                                        .font(.system(size: 12))
                                        .foregroundColor(.green)
                                    Text("Using existing transparency")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                            }

                            Divider()
                                .padding(.vertical, 4)
                        }

                        if !useExistingAlpha {
                            // Text prompt
                            HStack {
                                TextField("e.g. dog, tree, person", text: $textPrompt)
                                    .textFieldStyle(.roundedBorder)
                                    .onSubmit { runTextPrediction() }

                                Button("Find") { runTextPrediction() }
                                    .disabled(textPrompt.isEmpty || env.isProcessing)
                            }

                            Text("Or right-click on the object")
                                .font(.caption)
                                .foregroundColor(.secondary)

                        // Message if text search found nothing
                        if textSearchPerformed && allMasks.isEmpty && !env.isProcessing {
                            HStack(spacing: 6) {
                                Image(systemName: "exclamationmark.circle")
                                    .foregroundColor(.orange)
                                Text("No '\(textPrompt)' found in image")
                                    .font(.caption)
                                    .foregroundColor(.orange)
                            }
                            .padding(.vertical, 6)
                            .padding(.horizontal, 8)
                            .background(Color.orange.opacity(0.1))
                            .cornerRadius(6)
                        }

                        // Mask selection (when multiple masks found)
                        if allMasks.count > 1 {
                            Text("Select region:")
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .padding(.top, 4)

                            ForEach(Array(allMasks.enumerated()), id: \.offset) { index, maskData in
                                let isSelected = index == selectedMaskIndex
                                let color = colorForMask(index)

                                Button(action: { selectedMaskIndex = index }) {
                                    HStack(spacing: 8) {
                                        // Neon color indicator
                                        Circle()
                                            .fill(color)
                                            .frame(width: 12, height: 12)
                                            .shadow(color: color.opacity(0.6), radius: isSelected ? 4 : 0)

                                        Text("Region \(index + 1)")
                                            .font(.caption)
                                            .fontWeight(isSelected ? .semibold : .regular)

                                        Spacer()

                                        // Confidence percentage
                                        Text(String(format: "%.0f%%", maskData.score * 100))
                                            .font(.caption.monospacedDigit())
                                            .foregroundColor(isSelected ? color : .secondary)

                                        if isSelected {
                                            Image(systemName: "checkmark.circle.fill")
                                                .font(.caption)
                                                .foregroundColor(color)
                                        }
                                    }
                                    .padding(.vertical, 4)
                                    .padding(.horizontal, 6)
                                    .background(
                                        RoundedRectangle(cornerRadius: 6)
                                            .fill(isSelected ? color.opacity(0.15) : Color.clear)
                                    )
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        } // End of if !useExistingAlpha

                        // Clear button - available in both modes
                        if !selectedPoints.isEmpty || !allMasks.isEmpty {
                            HStack {
                                if !selectedPoints.isEmpty {
                                    Text("\(selectedPoints.count) point(s)")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                                Spacer()
                                Button("Clear") {
                                    clearSegmentation()
                                    useExistingAlpha = false
                                }
                                    .font(.caption)
                            }
                        }
                    }
                } else if currentStep == .touchup || currentStep == .generate {
                    // Completed state - show checkmark with selected region
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 12))
                            .foregroundColor(.green)
                        Text("Region \(selectedMaskIndex + 1) selected")
                            .font(.caption)
                    }
                }
            }

            // Step 3: Touchup
            stepSection(number: 3, title: "Touchup", isActive: currentStep == .touchup, isDone: currentStep == .generate) {
                if currentStep == .touchup {
                    VStack(alignment: .leading, spacing: 10) {
                        // Brush mode toggle
                        Text("Brush mode:")
                            .font(.caption)
                            .foregroundColor(.secondary)

                        HStack(spacing: 8) {
                            Button(action: { brushMode = .add }) {
                                HStack {
                                    Image(systemName: "plus.circle.fill")
                                    Text("Add")
                                }
                                .padding(.vertical, 6)
                                .padding(.horizontal, 12)
                                .background(brushMode == .add ? Color.green.opacity(0.2) : Color.clear)
                                .cornerRadius(6)
                            }
                            .buttonStyle(.plain)
                            .foregroundColor(brushMode == .add ? .green : .secondary)

                            Button(action: { brushMode = .remove }) {
                                HStack {
                                    Image(systemName: "minus.circle.fill")
                                    Text("Remove")
                                }
                                .padding(.vertical, 6)
                                .padding(.horizontal, 12)
                                .background(brushMode == .remove ? Color.red.opacity(0.2) : Color.clear)
                                .cornerRadius(6)
                            }
                            .buttonStyle(.plain)
                            .foregroundColor(brushMode == .remove ? .red : .secondary)
                        }

                        // Brush size slider
                        HStack {
                            Text("Brush size:")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Spacer()
                            Text("\(Int(brushSize))px")
                                .font(.caption.monospacedDigit())
                                .foregroundColor(.primary)
                        }

                        HStack(spacing: 8) {
                            Text("1")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                            Slider(value: $brushSize, in: 1...150)
                                .controlSize(.small)
                            Text("150")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }

                        Text("Paint on the image to refine the mask")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                } else if currentStep == .generate {
                    // Completed state
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 12))
                            .foregroundColor(.green)
                        Text("Mask refined")
                            .font(.caption)
                    }
                }
            }

            // Step 4: Generate
            stepSection(number: 4, title: "Generate 3D", isActive: currentStep == .generate, isDone: generated3DModelURL != nil) {
                if currentStep == .generate {
                    if isGenerating {
                        // Multi-stage progress UI
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(GenerationStage.allCases, id: \.self) { stage in
                                stageProgressRow(stage: stage)
                            }
                        }
                        .padding(.vertical, 4)
                    } else if generated3DModelURL != nil {
                        // Completed state
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(spacing: 6) {
                                Image(systemName: "checkmark.circle.fill")
                                    .font(.system(size: 12))
                                    .foregroundColor(.green)
                                Text("Generation Complete")
                                    .font(.caption)
                                    .fontWeight(.medium)
                            }

                            // Duration stats
                            if let duration = generationDuration {
                                HStack(spacing: 4) {
                                    Image(systemName: "clock")
                                        .font(.system(size: 10))
                                        .foregroundColor(.secondary)
                                    Text(formatDuration(duration))
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                            }

                            Button(action: {
                                if let url = generated3DModelURL {
                                    NSWorkspace.shared.selectFile(url.path, inFileViewerRootedAtPath: url.deletingLastPathComponent().path)
                                }
                            }) {
                                HStack(spacing: 4) {
                                    Image(systemName: "folder")
                                    Text("Show in Finder")
                                }
                                .font(.caption)
                            }
                            .buttonStyle(.plain)
                            .foregroundColor(.accentColor)
                        }
                    } else {
                        // Settings before generation
                        VStack(alignment: .leading, spacing: 10) {
                            // Preset dropdown
                            HStack {
                                Text("Quality:")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                Spacer()
                                Picker("", selection: $selectedPreset) {
                                    ForEach(QualityPreset.allCases) { preset in
                                        Text(preset.rawValue).tag(preset)
                                    }
                                }
                                .pickerStyle(.menu)
                                .frame(width: 120)
                                .onChange(of: selectedPreset) { _, newValue in
                                    // Sync custom values when preset changes
                                    customSteps = Double(newValue.steps)
                                    customResolution = Double(newValue.resolution)
                                }
                            }

                            // Preset info
                            HStack(spacing: 8) {
                                Text(selectedPreset.description)
                                    .font(.system(size: 10))
                                    .foregroundColor(.secondary)
                                Spacer()
                                Text(selectedPreset.estimatedTime)
                                    .font(.system(size: 10))
                                    .foregroundColor(.secondary)
                            }

                            // Advanced settings disclosure
                            DisclosureGroup(
                                isExpanded: $showAdvancedSettings,
                                content: {
                                    VStack(alignment: .leading, spacing: 8) {
                                        // Steps slider
                                        VStack(alignment: .leading, spacing: 4) {
                                            HStack {
                                                Text("Steps:")
                                                    .font(.caption)
                                                    .foregroundColor(.secondary)
                                                Spacer()
                                                Text("\(Int(customSteps))")
                                                    .font(.caption.monospacedDigit())
                                            }
                                            Slider(value: $customSteps, in: 10...100, step: 5)
                                                .controlSize(.small)
                                        }

                                        // Resolution slider
                                        VStack(alignment: .leading, spacing: 4) {
                                            HStack {
                                                Text("Resolution:")
                                                    .font(.caption)
                                                    .foregroundColor(.secondary)
                                                Spacer()
                                                Text("\(Int(customResolution))")
                                                    .font(.caption.monospacedDigit())
                                            }
                                            Slider(value: $customResolution, in: 64...512, step: 32)
                                                .controlSize(.small)
                                        }

                                        Text("Higher values = better quality, longer time")
                                            .font(.system(size: 9))
                                            .foregroundColor(.secondary)
                                    }
                                    .padding(.top, 4)
                                },
                                label: {
                                    Text("Advanced")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                            )
                        }
                    }
                }
            }

            Spacer()

            // Status
            if env.isProcessing {
                HStack {
                    ProgressView().scaleEffect(0.6)
                    Text(env.status)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            // Action buttons stack: Next (blue), Back (gray), Start Over (red)
            actionButtons
        }
        .padding()
        .background(Color(NSColor.windowBackgroundColor))
    }

    @ViewBuilder
    private func stepSection(number: Int, title: String, isActive: Bool, isDone: Bool, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                ZStack {
                    Circle()
                        .fill(isDone ? Color.green : (isActive ? Color.accentColor : Color.gray.opacity(0.3)))
                        .frame(width: 20, height: 20)

                    if isDone {
                        Image(systemName: "checkmark")
                            .font(.caption2.bold())
                            .foregroundColor(.white)
                    } else {
                        Text("\(number)")
                            .font(.caption2.bold())
                            .foregroundColor(isActive ? .white : .secondary)
                    }
                }

                Text(title)
                    .font(.subheadline)
                    .fontWeight(isActive ? .semibold : .regular)
                    .foregroundColor(isActive ? .primary : .secondary)
            }

            if isActive || isDone {
                content()
                    .padding(.leading, 28)
            }
        }
    }

    @ViewBuilder
    private func stageProgressRow(stage: GenerationStage) -> some View {
        let stageData = generationStages[stage] ?? StageProgress()

        HStack(spacing: 8) {
            // Status indicator - fixed size container for alignment
            Group {
                switch stageData.status {
                case .completed:
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundColor(.green)
                case .inProgress:
                    ProgressView()
                        .scaleEffect(0.4)
                case .pending:
                    Circle()
                        .fill(Color.gray.opacity(0.25))
                        .frame(width: 12, height: 12)
                case .cancelled:
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundColor(.orange)
                case .failed:
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundColor(.red.opacity(0.6))
                }
            }
            .frame(width: 14, height: 14)

            // Stage info
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(stage.rawValue)
                        .font(.caption)
                        .fontWeight(stageData.status == .inProgress ? .medium : .regular)
                        .foregroundColor(stageTextColor(stageData.status))

                    // Show "Stopped" or "Skipped" label for cancelled/failed
                    if stageData.status == .cancelled {
                        Text("Stopped")
                            .font(.system(size: 9))
                            .foregroundColor(.orange)
                    } else if stageData.status == .failed {
                        Text("Skipped")
                            .font(.system(size: 9))
                            .foregroundColor(.red.opacity(0.6))
                    }
                }

                // Progress bar for stages with progress
                if stageData.status == .inProgress && stageData.progress > 0 {
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 2)
                                .fill(Color.gray.opacity(0.2))
                                .frame(height: 4)

                            RoundedRectangle(cornerRadius: 2)
                                .fill(Color.accentColor)
                                .frame(width: geo.size.width * stageData.progress, height: 4)
                        }
                    }
                    .frame(height: 4)
                }

                // Detail text
                if !stageData.detail.isEmpty && stageData.status == .inProgress {
                    Text(stageData.detail)
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)
                }
            }

            Spacer()

            // Percentage for active stages
            if stageData.status == .inProgress && stageData.progress > 0 {
                Text("\(Int(stageData.progress * 100))%")
                    .font(.caption2.monospacedDigit())
                    .foregroundColor(.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private var actionButtons: some View {
        VStack(spacing: 8) {
            // Next button (blue) or loading state
            switch currentStep {
            case .input:
                // Show loading state while SAM model loads
                if !env.samModelReady {
                    HStack(spacing: 8) {
                        ProgressView()
                            .scaleEffect(0.7)
                        Text("Loading model...")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                }

            case .segment:
                Button(action: { startTouchup() }) {
                    Text("Next: Touchup")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(allMasks.isEmpty)

            case .touchup:
                Button(action: {
                    transitionToGenerate()
                }) {
                    Text("Next: Generate 3D")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)

            case .generate:
                // Show Generate button when not generating and no model yet
                if !isGenerating && generated3DModelURL == nil {
                    Button(action: { generate3D() }) {
                        Text("Generate")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                } else if isGenerating {
                    // Stop button - styled like back button but red
                    Button(action: { stopGeneration() }) {
                        Text("Stop Generation")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .foregroundColor(.red)
                    .tint(.red)
                }
            }

            // Back button with destination - only show if not on first step
            if currentStep != .input {
                let backDestination: String = {
                    switch currentStep {
                    case .input: return ""
                    case .segment: return "Input"
                    case .touchup: return "Segment"
                    case .generate: return "Touchup"
                    }
                }()

                Button(action: {
                    handleBackAction()
                }) {
                    Text("Back: \(backDestination)")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .foregroundColor(.secondary)
                .disabled(isGenerating)
                .alert("Discard Touchup Changes?", isPresented: $showBackWarning) {
                    Button("Cancel", role: .cancel) { }
                    Button("Discard", role: .destructive) {
                        goBack()
                    }
                } message: {
                    Text("Your touchup edits will be lost if you go back to the Segment step.")
                }
                .alert("Discard Generated Model?", isPresented: $showDiscardModelWarning) {
                    Button("Cancel", role: .cancel) { }
                    Button("Discard", role: .destructive) {
                        goBack()
                    }
                } message: {
                    Text("The generated 3D model will be discarded. You can regenerate after making changes.")
                }
                .alert("Discard Image?", isPresented: $showDiscardImageWarning) {
                    Button("Cancel", role: .cancel) { }
                    Button("Discard", role: .destructive) {
                        clearAll()
                    }
                } message: {
                    Text("The current image will be discarded. You'll need to load a new image to continue.")
                }
            }

            // Start Over button (red) - only show if we have an image
            if inputImage != nil {
                Button(action: { showStartOverWarning = true }) {
                    Text("Start Over")
                        .foregroundColor(.red)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .tint(.red)
                .disabled(isGenerating)
                .alert("Start Over?", isPresented: $showStartOverWarning) {
                    Button("Cancel", role: .cancel) { }
                    Button("Start Over", role: .destructive) {
                        clearAll()
                    }
                } message: {
                    Text("This will discard your current image and all progress. You'll need to load a new image to continue.")
                }
            }
        }
    }

    /// Handles back button press - shows warnings if needed
    private func handleBackAction() {
        switch currentStep {
        case .input:
            break
        case .segment:
            // Warn about discarding the image
            showDiscardImageWarning = true
        case .touchup:
            // Warn about losing touchup changes
            showBackWarning = true
        case .generate:
            // Warn if model was generated
            if generated3DModelURL != nil {
                showDiscardModelWarning = true
            } else {
                goBack()
            }
        }
    }

    /// Executes the back navigation with proper state cleanup
    private func goBack() {
        switch currentStep {
        case .input:
            break

        case .segment:
            // Segment → Input: Clear segmentation data, keep image
            clearSegmentation()
            currentStep = .input

        case .touchup:
            // Touchup → Segment: Clear touchup data, keep masks for re-selection
            editableMaskImage = nil
            maskHistory.removeAll()
            brushPreviewPosition = nil
            currentStep = .segment

        case .generate:
            // Generate → Touchup: Clear generation data, keep touchup mask
            compositeImage = nil
            generated3DModelURL = nil
            generationStages = [:]
            generationStatus = ""
            generationStartTime = nil
            generationDuration = nil
            currentStep = .touchup
        }
    }

    // MARK: - Flow Transitions

    /// Input → Segment: Prepare for segmentation
    private func transitionToSegment() {
        // Clear any old segmentation data from previous session
        clearSegmentation()
        currentStep = .segment
    }

    /// Touchup → Generate: Create composite and show settings
    private func transitionToGenerate() {
        createCompositeImage()
        currentStep = .generate
        // Don't auto-start - let user configure settings and click Generate
    }

    // MARK: - Actions

    private func clearAll() {
        inputImage = nil
        inputImagePath = nil
        allMasks.removeAll()
        selectedMaskIndex = 0
        selectedPoints.removeAll()
        textPrompt = ""
        textSearchPerformed = false
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

    private func clearSegmentation() {
        allMasks.removeAll()
        selectedMaskIndex = 0
        selectedPoints.removeAll()
        textPrompt = ""
        textSearchPerformed = false
        editableMaskImage = nil
    }

    /// Check if the input image has an alpha channel with actual transparency
    private func checkImageHasAlpha() {
        guard let image = inputImage,
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            imageHasAlpha = false
            return
        }

        // Check if image has alpha channel
        let alphaInfo = cgImage.alphaInfo
        let hasAlphaChannel = alphaInfo == .first || alphaInfo == .last ||
                              alphaInfo == .premultipliedFirst || alphaInfo == .premultipliedLast

        guard hasAlphaChannel else {
            imageHasAlpha = false
            return
        }

        // Check if alpha channel has actual transparency (not all opaque)
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

        // Sample pixels to check for transparency (don't check all for performance)
        let sampleStep = max(1, (width * height) / 10000)
        for i in stride(from: 0, to: width * height, by: sampleStep) {
            let alpha = pixels[i * 4 + 3]
            if alpha < 250 {  // Allow small tolerance
                hasTransparency = true
                break
            }
        }

        imageHasAlpha = hasTransparency
    }

    /// Create a mask from the image's alpha channel
    private func createMaskFromAlpha() {
        guard let image = inputImage,
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }

        let width = cgImage.width
        let height = cgImage.height
        let colorSpace = CGColorSpaceCreateDeviceRGB()

        // Read source image
        guard let sourceContext = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ), let sourceData = sourceContext.data else { return }

        sourceContext.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        // Create mask context
        guard let maskContext = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ), let maskData = maskContext.data else { return }

        let sourcePixels = sourceData.bindMemory(to: UInt8.self, capacity: width * height * 4)
        let maskPixels = maskData.bindMemory(to: UInt8.self, capacity: width * height * 4)

        // Create mask: where alpha > 0, set mask to opaque blue (matching SAM mask format)
        for i in 0..<(width * height) {
            let offset = i * 4
            let alpha = sourcePixels[offset + 3]

            if alpha > 10 {  // Threshold to ignore near-transparent pixels
                // Blue-ish mask color (matching SAM output)
                maskPixels[offset + 0] = 200  // R
                maskPixels[offset + 1] = 100  // G
                maskPixels[offset + 2] = 50   // B
                maskPixels[offset + 3] = alpha // A
            } else {
                maskPixels[offset + 0] = 0
                maskPixels[offset + 1] = 0
                maskPixels[offset + 2] = 0
                maskPixels[offset + 3] = 0
            }
        }

        guard let maskCGImage = maskContext.makeImage() else { return }
        let maskNSImage = NSImage(cgImage: maskCGImage, size: NSSize(width: width, height: height))

        // Save to temp file (to match the format expected by allMasks)
        let tempURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("alpha_mask_\(UUID().uuidString).png")
        if let tiffData = maskNSImage.tiffRepresentation,
           let bitmap = NSBitmapImageRep(data: tiffData),
           let pngData = bitmap.representation(using: .png, properties: [:]) {
            try? pngData.write(to: tempURL)
        }

        // Add to masks array
        allMasks = [(image: maskNSImage, score: 1.0, url: tempURL)]
        selectedMaskIndex = 0
    }

    // MARK: - Touchup Functions

    private func startTouchup() {
        guard selectedMaskIndex < allMasks.count else { return }

        // Copy the selected mask to editable mask
        let selectedMask = allMasks[selectedMaskIndex].image
        editableMaskImage = selectedMask.copy() as? NSImage
        maskHistory.removeAll()  // Clear undo history
        currentStep = .touchup
    }

    private func paintOnMask(at normalizedPoint: CGPoint) {
        guard let maskImage = editableMaskImage,
              let cgImage = maskImage.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }

        let width = cgImage.width
        let height = cgImage.height

        // Create a mutable bitmap context
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else { return }

        // Draw existing mask
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        // Calculate pixel position (flip Y for CoreGraphics coordinate system)
        let pixelX = normalizedPoint.x * CGFloat(width)
        let pixelY = (1.0 - normalizedPoint.y) * CGFloat(height)

        // Scale brush size relative to image size
        let scaledBrushSize = brushSize * CGFloat(width) / 500.0

        // Draw circle at position
        let rect = CGRect(
            x: pixelX - scaledBrushSize / 2,
            y: pixelY - scaledBrushSize / 2,
            width: scaledBrushSize,
            height: scaledBrushSize
        )

        if brushMode == .add {
            // Add to mask - draw white with full alpha
            context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
            context.fillEllipse(in: rect)
        } else {
            // Remove from mask - clear the area
            context.setBlendMode(.clear)
            context.fillEllipse(in: rect)
            context.setBlendMode(.normal)
        }

        // Create new image from context
        guard let newCGImage = context.makeImage() else { return }

        // Update the editable mask
        let newImage = NSImage(cgImage: newCGImage, size: NSSize(width: width, height: height))
        editableMaskImage = newImage
    }

    private func saveTouchupMask() -> URL? {
        guard let maskImage = editableMaskImage,
              let cgImage = maskImage.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }

        let tempPath = NSTemporaryDirectory() + "touchup_mask_\(UUID().uuidString).png"
        let url = URL(fileURLWithPath: tempPath)

        let bitmapRep = NSBitmapImageRep(cgImage: cgImage)
        guard let pngData = bitmapRep.representation(using: .png, properties: [:]) else { return nil }

        do {
            try pngData.write(to: url)
            return url
        } catch {
            print("Failed to save touchup mask: \(error)")
            return nil
        }
    }

    // MARK: - Undo Functions

    private func saveUndoState() {
        guard let maskImage = editableMaskImage,
              let copy = maskImage.copy() as? NSImage else { return }
        maskHistory.append(copy)
        // Limit history to 50 states to avoid memory issues
        if maskHistory.count > 50 {
            maskHistory.removeFirst()
        }
    }

    private func undo() {
        guard !maskHistory.isEmpty else { return }
        editableMaskImage = maskHistory.removeLast()
    }

    private func createCompositeImage() {
        guard let sourceImage = inputImage,
              let sourceCG = sourceImage.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }

        // Get the mask - use touchup mask if available, otherwise selected mask
        let maskImage: NSImage?
        if let touchup = editableMaskImage {
            maskImage = touchup
        } else if selectedMaskIndex < allMasks.count {
            maskImage = allMasks[selectedMaskIndex].image
        } else {
            maskImage = nil
        }

        guard let mask = maskImage,
              let maskCG = mask.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }

        let width = sourceCG.width
        let height = sourceCG.height

        // Use non-premultiplied alpha to avoid color artifacts
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue)

        // Create context for source image (non-premultiplied)
        guard let sourceContext = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: bitmapInfo.rawValue
        ) else { return }

        // Draw the source image
        sourceContext.draw(sourceCG, in: CGRect(x: 0, y: 0, width: width, height: height))

        // Create context for mask (scaled to source size)
        guard let maskContext = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return }

        // Draw mask scaled to source size
        maskContext.draw(maskCG, in: CGRect(x: 0, y: 0, width: width, height: height))

        // Get pixel data
        guard let sourceData = sourceContext.data,
              let maskData = maskContext.data else { return }

        // Create output context with alpha
        guard let outputContext = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return }

        guard let outputData = outputContext.data else { return }

        let sourcePixels = sourceData.bindMemory(to: UInt8.self, capacity: width * height * 4)
        let maskPixels = maskData.bindMemory(to: UInt8.self, capacity: width * height * 4)
        let outputPixels = outputData.bindMemory(to: UInt8.self, capacity: width * height * 4)

        // Composite: copy source RGB where mask alpha > 0, set alpha from mask
        for i in 0..<(width * height) {
            let offset = i * 4
            let maskAlpha = maskPixels[offset + 3]  // Alpha channel of mask

            if maskAlpha > 0 {
                // Inside mask: copy source colors with mask alpha
                outputPixels[offset + 0] = sourcePixels[offset + 0]  // R
                outputPixels[offset + 1] = sourcePixels[offset + 1]  // G
                outputPixels[offset + 2] = sourcePixels[offset + 2]  // B
                outputPixels[offset + 3] = maskAlpha                  // A
            } else {
                // Outside mask: fully transparent
                outputPixels[offset + 0] = 0
                outputPixels[offset + 1] = 0
                outputPixels[offset + 2] = 0
                outputPixels[offset + 3] = 0
            }
        }

        // Create final image
        guard let finalImage = outputContext.makeImage() else { return }

        compositeImage = NSImage(cgImage: finalImage, size: NSSize(width: width, height: height))
    }

    private func selectImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image, .png, .jpeg]
        panel.allowsMultipleSelection = false

        if panel.runModal() == .OK, let url = panel.url {
            loadImage(from: url)
        }
    }

    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }

        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier) { item, _ in
                if let data = item as? Data, let url = URL(dataRepresentation: data, relativeTo: nil) {
                    DispatchQueue.main.async { loadImage(from: url) }
                }
            }
            return true
        }

        if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
            provider.loadItem(forTypeIdentifier: UTType.image.identifier) { item, _ in
                if let data = item as? Data, let image = NSImage(data: data) {
                    // Save to temp file so SAM can access it
                    let tempPath = NSTemporaryDirectory() + "dropped_image_\(UUID().uuidString).png"
                    if let tiff = image.tiffRepresentation,
                       let bitmap = NSBitmapImageRep(data: tiff),
                       let png = bitmap.representation(using: .png, properties: [:]) {
                        try? png.write(to: URL(fileURLWithPath: tempPath))
                    }
                    DispatchQueue.main.async {
                        self.loadImage(from: URL(fileURLWithPath: tempPath))
                    }
                }
            }
            return true
        }

        return false
    }

    private func loadImage(from url: URL) {
        guard let image = NSImage(contentsOf: url) else { return }

        // Set new image
        inputImage = image
        inputImagePath = url.path

        // Clear ALL previous session data for fresh start
        // Segmentation data
        allMasks.removeAll()
        selectedMaskIndex = 0
        selectedPoints.removeAll()
        textPrompt = ""
        textSearchPerformed = false

        // Touchup data
        editableMaskImage = nil
        maskHistory.removeAll()
        brushPreviewPosition = nil

        // Generation data
        compositeImage = nil
        generated3DModelURL = nil
        generationStages = [:]
        generationStatus = ""

        // Reset zoom
        zoomScale = 1.0

        // Reset alpha toggle
        useExistingAlpha = false

        // Get pixel dimensions
        if let rep = image.representations.first {
            imagePixelSize = CGSize(width: CGFloat(rep.pixelsWide), height: CGFloat(rep.pixelsHigh))
        }

        // Check if image has alpha channel
        checkImageHasAlpha()

        // Transition to segment step
        currentStep = .segment
        Task { await initializeImage() }
    }

    private func initializeImage() async {
        guard let path = inputImagePath else {
            print("[Init] No inputImagePath set!")
            return
        }
        do {
            print("[Init] Setting image: \(path)")
            let size = try await env.setImage(path: path)
            print("[Init] Image set, size: \(size)")
            await MainActor.run { imagePixelSize = size }
        } catch {
            print("[Init] Failed to set image: \(error)")
        }
    }

    /// Check if a normalized point is inside any mask and return the mask index
    private func findMaskAtPoint(_ normalized: CGPoint, displaySize: CGSize) -> Int? {
        // Check masks in reverse order (top-most first) so we select the visible one
        for (index, maskData) in allMasks.enumerated().reversed() {
            let image = maskData.image
            guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { continue }

            let pixelX = Int(normalized.x * CGFloat(cgImage.width))
            let pixelY = Int(normalized.y * CGFloat(cgImage.height))

            // Bounds check
            guard pixelX >= 0, pixelX < cgImage.width, pixelY >= 0, pixelY < cgImage.height else { continue }

            // Get pixel data - check alpha channel
            guard let dataProvider = cgImage.dataProvider,
                  let data = dataProvider.data,
                  let bytes = CFDataGetBytePtr(data) else { continue }

            let bytesPerPixel = cgImage.bitsPerPixel / 8
            let bytesPerRow = cgImage.bytesPerRow
            let pixelOffset = pixelY * bytesPerRow + pixelX * bytesPerPixel

            // Check alpha channel (last byte in RGBA)
            let alpha: UInt8
            if bytesPerPixel >= 4 {
                alpha = bytes[pixelOffset + 3]
            } else if bytesPerPixel >= 1 {
                alpha = bytes[pixelOffset]
            } else {
                continue
            }

            // If alpha > threshold, this mask contains the point
            if alpha > 128 {
                return index
            }
        }
        return nil
    }

    private func addPoint(at normalized: CGPoint) {
        let point = SAMPoint(normalizedCoords: normalized.clamped, label: 1)
        selectedPoints.append(point)
        Task { await runPointPrediction() }
    }

    private func runPointPrediction() async {
        guard !selectedPoints.isEmpty else { return }

        do {
            let (masks, _, scores, _) = try await env.predict(
                points: selectedPoints,
                imageSize: imagePixelSize
            )

            await MainActor.run {
                loadMasks(urls: masks, scores: scores)
            }
        } catch {
            print("Prediction failed: \(error)")
        }
    }

    private func runTextPrediction() {
        guard !textPrompt.isEmpty else { return }

        Task {
            do {
                print("[Text] Predicting: \(textPrompt)")
                let (masks, _, scores, _) = try await env.predict(
                    text: textPrompt,
                    imageSize: imagePixelSize
                )
                print("[Text] Got \(masks.count) masks, scores: \(scores)")

                await MainActor.run {
                    textSearchPerformed = true
                    loadMasks(urls: masks, scores: scores)
                }
            } catch {
                print("[Text] Prediction failed: \(error)")
                await MainActor.run {
                    textSearchPerformed = true
                    allMasks.removeAll()
                }
            }
        }
    }

    private func loadMasks(urls: [URL], scores: [Double]) {
        allMasks.removeAll()
        selectedMaskIndex = 0

        for (index, url) in urls.enumerated() {
            if let image = NSImage(contentsOf: url) {
                let score = index < scores.count ? scores[index] : 0.0
                allMasks.append((image: image, score: score, url: url))
            }
        }
        print("[Masks] Loaded \(allMasks.count) masks")
    }

    private var selectedMask: NSImage? {
        guard selectedMaskIndex < allMasks.count else { return nil }
        return allMasks[selectedMaskIndex].image
    }

    private var selectedMaskURL: URL? {
        guard selectedMaskIndex < allMasks.count else { return nil }
        return allMasks[selectedMaskIndex].url
    }

    private func generate3D() {
        // Use the exact composite image that was shown in preview
        // This ensures what user sees is what gets generated
        guard let composite = compositeImage else {
            // Fallback: create composite if not already created
            createCompositeImage()
            guard compositeImage != nil else {
                print("ERROR: No composite image available for 3D generation")
                return
            }
            return generate3D() // Retry with newly created composite
        }

        // Save composite image to temp file (PNG preserves alpha channel)
        let tempPath = NSTemporaryDirectory() + "composite_for_3d_\(UUID().uuidString).png"
        guard let cgImage = composite.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            print("ERROR: Failed to get CGImage from composite")
            return
        }

        let bitmapRep = NSBitmapImageRep(cgImage: cgImage)
        guard let pngData = bitmapRep.representation(using: .png, properties: [:]) else {
            print("ERROR: Failed to create PNG data from composite")
            return
        }

        do {
            try pngData.write(to: URL(fileURLWithPath: tempPath))
            print("============================================================")
            print("[3D Generation] COMPOSITE IMAGE SAVED")
            print("[3D Generation] Path: \(tempPath)")
            print("[3D Generation] Size: \(cgImage.width) x \(cgImage.height)")
            print("[3D Generation] This is the EXACT image being sent to 3D model")
            print("============================================================")
        } catch {
            print("ERROR: Failed to save composite image: \(error)")
            return
        }

        isGenerating = true
        generationStatus = "Starting..."
        generationStartTime = Date()
        generationDuration = nil

        // Initialize all stages to pending
        generationStages = [:]
        for stage in GenerationStage.allCases {
            generationStages[stage] = StageProgress()
        }

        Task {
            print("[3D Generation] Calling generate3DModel with:")
            print("[3D Generation]   imagePath: \(tempPath)")
            print("[3D Generation]   maskPath: (empty - composite has alpha)")

            // Pass composite as image with empty mask (composite already has alpha)
            // Use advanced settings if expanded, otherwise use preset values
            let steps = showAdvancedSettings ? Int(customSteps) : selectedPreset.steps
            let resolution = showAdvancedSettings ? Int(customResolution) : selectedPreset.resolution

            await env.generate3DModel(
                imagePath: tempPath,
                maskPath: "",  // No mask needed - composite already has transparency
                steps: steps,
                resolution: resolution,
                progress: { status in
                    DispatchQueue.main.async {
                        self.generationStatus = status
                        self.updateGenerationStage(from: status)
                    }
                },
                completion: { result in
                    DispatchQueue.main.async {
                        // Calculate duration
                        if let startTime = self.generationStartTime {
                            self.generationDuration = Date().timeIntervalSince(startTime)
                        }

                        self.isGenerating = false

                        switch result {
                        case .success(let url):
                            // Mark all stages as completed on success
                            for stage in GenerationStage.allCases {
                                self.generationStages[stage] = StageProgress(status: .completed, progress: 1.0, detail: "")
                            }
                            self.generated3DModelURL = url

                        case .failure(let error):
                            let errorMsg = error.localizedDescription
                            // Check if this was a cancellation
                            if errorMsg.contains("cancelled") || self.env.isGenerationCancelled {
                                // Reset to pre-generation state so user can adjust settings
                                self.generationStages = [:]
                                self.generationStatus = ""
                            } else {
                                self.generationStatus = "Error: \(errorMsg)"
                            }
                        }
                    }
                }
            )
        }
    }

    /// Stop the current 3D generation
    private func stopGeneration() {
        env.cancelGeneration()
        // The completion handler will be called with a cancellation error
    }

    /// Get text color for a stage status
    private func stageTextColor(_ status: StageStatus) -> Color {
        switch status {
        case .pending:
            return .secondary
        case .inProgress, .completed:
            return .primary
        case .cancelled:
            return .orange
        case .failed:
            return .secondary
        }
    }

    private func updateGenerationStage(from status: String) {
        // Parse status string and update appropriate stage
        // Progress strings from PythonEnvironment:
        // - "Extracting foreground..."
        // - "Loading model..."
        // - "Generating 3D shape..." (treated as loading)
        // - "Diffusion Sampling: XX% | step/total | time"
        // - "Volume Decoding: XX% | step/total | time"
        // - "Saving model..."

        if status.contains("Extracting") {
            markPreviousStagesCompleted(before: .extracting)
            generationStages[.extracting] = StageProgress(status: .inProgress, progress: 0, detail: "")
        } else if status.contains("Loading") || status.contains("Generating 3D shape") {
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

    private func parseProgressString(_ status: String) -> (Double, String) {
        // Parse strings like "Diffusion Sampling: 50% | 15/30 | 00:06<00:06"
        var progress: Double = 0
        var detail = ""

        // Extract percentage
        if let percentRange = status.range(of: #"(\d+)%"#, options: .regularExpression) {
            let percentStr = status[percentRange].dropLast() // Remove %
            if let percent = Double(percentStr) {
                progress = percent / 100.0
            }
        }

        // Extract step info like "15/30"
        if let stepRange = status.range(of: #"\d+/\d+"#, options: .regularExpression) {
            detail = String(status[stepRange])
        }

        return (progress, detail)
    }

    private func formatDuration(_ duration: TimeInterval) -> String {
        let minutes = Int(duration) / 60
        let seconds = Int(duration) % 60
        if minutes > 0 {
            return String(format: "%dm %ds", minutes, seconds)
        } else {
            return String(format: "%ds", seconds)
        }
    }

    private func fitSize(_ imageSize: CGSize, in containerSize: CGSize) -> CGSize {
        let imageAspect = imageSize.width / imageSize.height
        let containerAspect = containerSize.width / containerSize.height

        if imageAspect > containerAspect {
            let width = containerSize.width * 0.9
            return CGSize(width: width, height: width / imageAspect)
        } else {
            let height = containerSize.height * 0.9
            return CGSize(width: height * imageAspect, height: height)
        }
    }
}

#Preview {
    ContentViewSimple()
}

// MARK: - Right Click Handler

struct RightClickHandler: NSViewRepresentable {
    let onRightClick: (CGPoint) -> Void

    func makeNSView(context: Context) -> RightClickView {
        let view = RightClickView()
        view.onRightClick = onRightClick
        return view
    }

    func updateNSView(_ nsView: RightClickView, context: Context) {
        nsView.onRightClick = onRightClick
    }

    class RightClickView: NSView {
        var onRightClick: ((CGPoint) -> Void)?

        override func rightMouseDown(with event: NSEvent) {
            let location = convert(event.locationInWindow, from: nil)
            // Flip Y coordinate for SwiftUI
            let flippedLocation = CGPoint(x: location.x, y: bounds.height - location.y)
            onRightClick?(flippedLocation)
        }

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
            return true
        }
    }
}

// MARK: - Scroll Wheel Zoom Handler

/// An NSViewRepresentable that intercepts scroll wheel events for zooming
struct ScrollWheelZoomOverlay: NSViewRepresentable {
    @Binding var zoomScale: CGFloat
    let minZoom: CGFloat
    let maxZoom: CGFloat

    func makeNSView(context: Context) -> ScrollWheelCaptureView {
        let view = ScrollWheelCaptureView()
        view.coordinator = context.coordinator
        return view
    }

    func updateNSView(_ nsView: ScrollWheelCaptureView, context: Context) {
        context.coordinator.zoomScale = $zoomScale
        context.coordinator.minZoom = minZoom
        context.coordinator.maxZoom = maxZoom
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(zoomScale: $zoomScale, minZoom: minZoom, maxZoom: maxZoom)
    }

    class Coordinator {
        var zoomScale: Binding<CGFloat>
        var minZoom: CGFloat
        var maxZoom: CGFloat

        init(zoomScale: Binding<CGFloat>, minZoom: CGFloat, maxZoom: CGFloat) {
            self.zoomScale = zoomScale
            self.minZoom = minZoom
            self.maxZoom = maxZoom
        }

        func handleScroll(deltaY: CGFloat) {
            let currentScale = zoomScale.wrappedValue
            let newScale = currentScale * (1.0 + deltaY * 0.05)
            zoomScale.wrappedValue = max(minZoom, min(maxZoom, newScale))
        }
    }

    class ScrollWheelCaptureView: NSView {
        weak var coordinator: Coordinator?

        override var acceptsFirstResponder: Bool { true }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            // Request to become first responder to receive scroll events
            window?.makeFirstResponder(self)
        }

        override func scrollWheel(with event: NSEvent) {
            // Capture scroll wheel and convert to zoom
            let delta = event.deltaY
            if abs(delta) > 0.001 {
                coordinator?.handleScroll(deltaY: delta)
            }
            // Don't call super - consume all scroll events
        }

        // Pass through mouse events to views below
        override func hitTest(_ point: NSPoint) -> NSView? {
            // Return self only for scroll wheel (handled via scrollWheel override)
            // For other events, let them pass through
            return self
        }

        override func mouseDown(with event: NSEvent) {
            // Forward to next responder
            nextResponder?.mouseDown(with: event)
        }

        override func mouseUp(with event: NSEvent) {
            nextResponder?.mouseUp(with: event)
        }

        override func mouseDragged(with event: NSEvent) {
            nextResponder?.mouseDragged(with: event)
        }

        override func rightMouseDown(with event: NSEvent) {
            nextResponder?.rightMouseDown(with: event)
        }

        override func rightMouseUp(with event: NSEvent) {
            nextResponder?.rightMouseUp(with: event)
        }
    }
}
