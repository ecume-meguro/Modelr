import SwiftUI
import UniformTypeIdentifiers

enum SidebarTab: String, CaseIterable {
    case segment = "Segment"
    case generate = "Generate"
}

struct ContentView: View {
    @StateObject private var env = PythonEnvironment()

    // Image state
    @State private var inputImage: NSImage?
    @State private var inputImagePath: String?
    @State private var maskImage: NSImage?
    @State private var isDragging = false
    @State private var imagePixelSize: CGSize = .zero

    // Multi-point state
    @State private var selectedPoints: [SAMPoint] = []
    @State private var boundingBoxes: [SAMBox] = []
    @State private var currentBox: SAMBox?

    // Tool state
    @State private var selectedTool: SAMTool = .point
    @State private var selectedTab: SidebarTab = .segment

    // Zoom state
    @State private var magnification: CGFloat = 1.0

    // Generate state
    @State private var generateSteps: Double = 30
    @State private var generateResolution: Double = 256
    @State private var isGenerating = false
    @State private var generateProgress: String = ""
    @State private var generated3DModelURL: URL?

    var body: some View {
        VStack(spacing: 0) {
            if !env.isSetup {
                SplashScreenView(env: env)
            } else {
                mainEditorView
            }
        }
        .frame(minWidth: 1000, minHeight: 700)
        // Re-inference triggers
        .onChange(of: selectedPoints.count) { _, _ in
            triggerReInference()
        }
        .onChange(of: boundingBoxes.count) { _, _ in
            triggerReInference()
        }
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
        guard let inputImage = inputImage else { return CGSize(width: 800, height: 600) }
        let imageSize = inputImage.size
        let aspectRatio = imageSize.width / imageSize.height

        // Use a reasonable base size that fits well in the view
        let baseHeight: CGFloat = 600
        let baseWidth = baseHeight * aspectRatio

        return CGSize(width: baseWidth, height: baseHeight)
    }

    var imageArea: some View {
        ZStack {
            Color(NSColor.windowBackgroundColor).opacity(0.5)

            if let inputImage = inputImage {
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
                    toolMode: selectedTool,
                    contentSize: displaySize,
                    contentID: inputImagePath ?? ""
                ) {
                    ZStack {
                        Image(nsImage: inputImage)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: displaySize.width, height: displaySize.height)

                        if let maskImage = maskImage {
                            Image(nsImage: maskImage)
                                .resizable()
                                .frame(width: displaySize.width, height: displaySize.height)
                                .allowsHitTesting(false)
                                .opacity(0.6)
                        }

                        PointsOverlay(points: selectedPoints, displayedSize: displaySize)
                            .frame(width: displaySize.width, height: displaySize.height)

                        BoundingBoxOverlay(
                            boxes: boundingBoxes,
                            currentBox: currentBox,
                            displayedSize: displaySize
                        )
                        .frame(width: displaySize.width, height: displaySize.height)
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
                    }
                    .font(.subheadline)

                    Spacer()

                    if !selectedPoints.isEmpty || !boundingBoxes.isEmpty {
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
                    if selectedTool == .point {
                        Text("• Click to add points on the object")
                        Text("• Multiple points refine the selection")
                    } else {
                        Text("• Drag to draw a bounding box")
                        Text("• Box should contain the object")
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

                        Slider(value: $generateSteps, in: 10...50, step: 5)

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

                        Slider(value: $generateResolution, in: 128...384, step: 32)

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

                    if !generateProgress.isEmpty {
                        Text(generateProgress)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                    }
                }

                // Show 3D model if generated
                if let modelURL = generated3DModelURL {
                    Divider()

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Result")
                            .font(.headline)
                            .foregroundColor(.secondary)

                        ModelViewerContainer(modelURL: modelURL)
                            .frame(height: 200)
                            .cornerRadius(8)
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
        guard selectedTool == .point else { return }
        guard inputImage != nil, inputImagePath != nil else { return }

        // Coordinates are already normalized 0-1 from ImageCanvasView
        let point = SAMPoint(normalizedCoords: normalized)

        withAnimation(.spring(response: 0.3)) {
            selectedPoints.append(point)
        }
    }

    private func handleDragStart(at point: CGPoint) {
        guard selectedTool == .boundingBox else { return }
        guard inputImage != nil else { return }

        currentBox = SAMBox(startPoint: point, endPoint: point)
    }

    private func handleDragChange(start: CGPoint, current: CGPoint) {
        guard selectedTool == .boundingBox else { return }
        currentBox?.endPoint = current
    }

    private func handleDragEnd(start: CGPoint, end: CGPoint) {
        guard selectedTool == .boundingBox else { return }
        guard let box = currentBox else { return }

        guard box.isValid else {
            currentBox = nil
            return
        }

        withAnimation(.spring(response: 0.3)) {
            boundingBoxes.append(box)
            currentBox = nil
        }
    }

    // MARK: - Re-inference

    private func triggerReInference() {
        guard !selectedPoints.isEmpty || !boundingBoxes.isEmpty else { return }
        guard let path = inputImagePath else { return }
        guard !env.isProcessing else { return }

        Task {
            do {
                let pixelSize = try await env.setImage(path: path)
                self.imagePixelSize = pixelSize

                let maskURL = try await env.predict(
                    points: selectedPoints,
                    box: boundingBoxes.first,
                    imageSize: pixelSize
                )

                if let newMask = NSImage(contentsOf: maskURL) {
                    await MainActor.run {
                        self.maskImage = newMask
                    }
                }
            } catch {
                await MainActor.run {
                    env.status = "Error: \(error.localizedDescription)"
                }
            }
        }
    }

    // MARK: - 3D Generation

    private func startGeneration() {
        guard let imagePath = inputImagePath else {
            generateProgress = "Error: No image loaded"
            return
        }

        guard let maskPath = getMaskPath() else {
            generateProgress = "Error: No mask available. Segment an object first."
            return
        }

        isGenerating = true
        generateProgress = "Starting generation..."
        generated3DModelURL = nil

        Task {
            await env.generate3DModel(
                imagePath: imagePath,
                maskPath: maskPath,
                steps: Int(generateSteps),
                resolution: Int(generateResolution)
            ) { progress in
                Task { @MainActor in
                    self.generateProgress = progress
                }
            } completion: { result in
                Task { @MainActor in
                    self.isGenerating = false
                    switch result {
                    case .success(let url):
                        self.generated3DModelURL = url
                        self.generateProgress = "Generation complete!"
                    case .failure(let error):
                        self.generateProgress = "Error: \(error.localizedDescription)"
                    }
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
            maskImage = nil
        }
    }

    private func clearAll() {
        clearAnnotations()
        inputImage = nil
        inputImagePath = nil
        imagePixelSize = .zero
        generated3DModelURL = nil
        generateProgress = ""

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

        do {
            try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
            if let tiffData = image.tiffRepresentation,
               let bitmap = NSBitmapImageRep(data: tiffData),
               let data = bitmap.representation(using: .png, properties: [:]) {
                try data.write(to: tempFile)
                self.loadImage(from: tempFile)
            }
        } catch {
            print("Failed to save dropped image: \(error.localizedDescription)")
        }
    }

    private func loadImage(from url: URL) {
        DispatchQueue.main.async {
            guard let image = NSImage(contentsOf: url) else {
                self.env.status = "Error: Could not load image"
                return
            }

            self.inputImage = image
            self.maskImage = nil
            self.generated3DModelURL = nil
            self.env.status = "Loaded: \(url.lastPathComponent)"

            let safeExtensions = ["png", "jpg", "jpeg", "bmp", "webp", "tiff"]
            let ext = url.pathExtension.lowercased()

            if safeExtensions.contains(ext) {
                self.inputImagePath = url.path
            } else {
                self.saveImageForBackend(image: image)
            }

            if let rep = image.representations.first {
                self.imagePixelSize = CGSize(
                    width: CGFloat(rep.pixelsWide),
                    height: CGFloat(rep.pixelsHigh)
                )
            }
        }
    }

    private func saveImageForBackend(image: NSImage) {
        let tempDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/ModelrV3", isDirectory: true)
        let tempFile = tempDir.appendingPathComponent("backend_working_copy.png")

        do {
            try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
            if let tiffData = image.tiffRepresentation,
               let bitmap = NSBitmapImageRep(data: tiffData),
               let data = bitmap.representation(using: .png, properties: [:]) {
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
