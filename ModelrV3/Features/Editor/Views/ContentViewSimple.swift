import SwiftUI
import UniformTypeIdentifiers

/// Simple MVP ContentView - minimal UI for: Input -> Segment -> Generate
struct ContentViewSimple: View {
    @StateObject private var env = PythonEnvironment()

    // Core state
    @State private var inputImage: NSImage?
    @State private var inputImagePath: String?
    @State private var imagePixelSize: CGSize = .zero

    // Workflow state
    enum Step { case input, segment, generate }
    @State private var currentStep: Step = .input

    // Segmentation state
    @State private var textPrompt: String = ""
    @State private var textSearchPerformed: Bool = false
    @State private var selectedPoints: [SAMPoint] = []
    @State private var isDragging = false

    // Multi-mask state
    @State private var allMasks: [(image: NSImage, score: Double, url: URL)] = []
    @State private var selectedMaskIndex: Int = 0

    // Generation state
    @State private var isGenerating = false
    @State private var generationStatus = ""
    @State private var generated3DModelURL: URL?

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
    }

    // MARK: - Image Area

    private var imageArea: some View {
        ZStack {
            Color(NSColor.textBackgroundColor).opacity(0.3)

            if currentStep == .generate, let modelURL = generated3DModelURL {
                ModelViewerContainer(modelURL: modelURL)
            } else if let image = inputImage {
                GeometryReader { geo in
                    let size = fitSize(image.size, in: geo.size)

                    ZStack {
                        Image(nsImage: image)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: size.width, height: size.height)

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
                    .frame(width: size.width, height: size.height)
                    .position(x: geo.size.width / 2, y: geo.size.height / 2)
                    .contentShape(Rectangle())
                    .onTapGesture { location in
                        if currentStep == .segment {
                            let normalized = CGPoint(
                                x: (location.x - (geo.size.width - size.width) / 2) / size.width,
                                y: (location.y - (geo.size.height - size.height) / 2) / size.height
                            )
                            if normalized.x >= 0 && normalized.x <= 1 && normalized.y >= 0 && normalized.y <= 1 {
                                // If we have masks, try to select one by clicking on it
                                if !allMasks.isEmpty {
                                    if let clickedIndex = findMaskAtPoint(normalized, displaySize: size) {
                                        selectedMaskIndex = clickedIndex
                                        return
                                    }
                                }
                                // Otherwise add a point for segmentation
                                addPoint(at: normalized)
                            }
                        }
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
                    HStack {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green)
                        Text("Image loaded")
                            .font(.caption)
                    }
                }
            }

            // Step 2: Segment
            stepSection(number: 2, title: "Segment", isActive: currentStep == .segment, isDone: !allMasks.isEmpty) {
                if currentStep == .segment || !allMasks.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        // Text prompt
                        HStack {
                            TextField("e.g. dog, tree, person", text: $textPrompt)
                                .textFieldStyle(.roundedBorder)
                                .onSubmit { runTextPrediction() }

                            Button("Find") { runTextPrediction() }
                                .disabled(textPrompt.isEmpty || env.isProcessing)
                        }

                        Text("Or click on the object")
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

                        if !selectedPoints.isEmpty || !allMasks.isEmpty {
                            HStack {
                                if !selectedPoints.isEmpty {
                                    Text("\(selectedPoints.count) point(s)")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                                Spacer()
                                Button("Clear") { clearSegmentation() }
                                    .font(.caption)
                            }
                        }
                    }
                }
            }

            // Step 3: Generate
            stepSection(number: 3, title: "Generate 3D", isActive: currentStep == .generate, isDone: generated3DModelURL != nil) {
                if currentStep == .generate {
                    if isGenerating {
                        HStack {
                            ProgressView().scaleEffect(0.7)
                            Text(generationStatus)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    } else if generated3DModelURL != nil {
                        HStack {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundColor(.green)
                            Text("Done!")
                                .font(.caption)
                        }

                        Button("Show in Finder") {
                            if let url = generated3DModelURL {
                                NSWorkspace.shared.selectFile(url.path, inFileViewerRootedAtPath: url.deletingLastPathComponent().path)
                            }
                        }
                        .font(.caption)
                    }
                }
            }

            Spacer()

            // Action button
            actionButton

            // Status
            if env.isProcessing {
                HStack {
                    ProgressView().scaleEffect(0.6)
                    Text(env.status)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            // Reset
            if inputImage != nil {
                Button("Start Over") { clearAll() }
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
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
    private var actionButton: some View {
        switch currentStep {
        case .input:
            EmptyView()

        case .segment:
            Button(action: { currentStep = .generate }) {
                Text("Generate 3D")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(allMasks.isEmpty)

        case .generate:
            if generated3DModelURL == nil && !isGenerating {
                Button(action: { generate3D() }) {
                    Text("Generate")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
            } else if generated3DModelURL != nil {
                Button(action: { generated3DModelURL = nil; generate3D() }) {
                    Text("Regenerate")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
        }
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
        generated3DModelURL = nil
        currentStep = .input
    }

    private func clearSegmentation() {
        allMasks.removeAll()
        selectedMaskIndex = 0
        selectedPoints.removeAll()
        textPrompt = ""
        textSearchPerformed = false
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
        inputImage = image
        inputImagePath = url.path
        allMasks.removeAll()
        selectedMaskIndex = 0
        selectedPoints.removeAll()
        textPrompt = ""
        generated3DModelURL = nil

        if let rep = image.representations.first {
            imagePixelSize = CGSize(width: CGFloat(rep.pixelsWide), height: CGFloat(rep.pixelsHigh))
        }

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
        guard let imagePath = inputImagePath, !allMasks.isEmpty else { return }

        // Use the selected mask
        let maskPath = selectedMaskURL?.path ?? NSTemporaryDirectory() + "mask_for_3d.png"
        if let mask = selectedMask, selectedMaskURL == nil {
            if let tiff = mask.tiffRepresentation,
               let bitmap = NSBitmapImageRep(data: tiff),
               let png = bitmap.representation(using: .png, properties: [:]) {
                try? png.write(to: URL(fileURLWithPath: maskPath))
            }
        }

        isGenerating = true
        generationStatus = "Starting..."

        Task {
            await env.generate3DModel(
                imagePath: imagePath,
                maskPath: maskPath,
                steps: 30,
                resolution: 256,
                progress: { status in
                    DispatchQueue.main.async { generationStatus = status }
                },
                completion: { result in
                    DispatchQueue.main.async {
                        isGenerating = false
                        switch result {
                        case .success(let url):
                            generated3DModelURL = url
                        case .failure(let error):
                            generationStatus = "Error: \(error.localizedDescription)"
                        }
                    }
                }
            )
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
