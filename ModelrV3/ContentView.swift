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

    // Multi-point state
    @State private var selectedPoints: [SAMPoint] = []
    @State private var boundingBoxes: [SAMBox] = []
    @State private var currentBox: SAMBox?

    // Tool state
    @State private var selectedTool: SAMTool = .point

    // Zoom state
    @State private var magnification: CGFloat = 1.0

    var body: some View {
        VStack(spacing: 0) {
            if !env.isSetup {
                SplashScreenView(env: env)
            } else {
                toolbar
                editorView
            }

            if env.isSetup {
                statusFooter
            }
        }
        .frame(minWidth: 800, minHeight: 600)
        // Re-inference triggers
        .onChange(of: selectedPoints.count) { _, _ in
            triggerReInference()
        }
        .onChange(of: boundingBoxes.count) { _, _ in
            triggerReInference()
        }
    }

    // MARK: - Toolbar

    var toolbar: some View {
        HStack(spacing: 16) {
            // Tool picker
            Picker("Tool", selection: $selectedTool) {
                ForEach(SAMTool.allCases) { tool in
                    Label(tool.rawValue, systemImage: tool.iconName)
                        .tag(tool)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 200)

            Divider()
                .frame(height: 20)

            // Point count
            if !selectedPoints.isEmpty || !boundingBoxes.isEmpty {
                HStack(spacing: 4) {
                    if !selectedPoints.isEmpty {
                        Label("\(selectedPoints.count)", systemImage: "hand.point.up.left.fill")
                            .font(.caption)
                    }
                    if !boundingBoxes.isEmpty {
                        Label("\(boundingBoxes.count)", systemImage: "rectangle.dashed")
                            .font(.caption)
                    }
                }
                .foregroundColor(.secondary)
            }

            Spacer()

            // Clear button
            if !selectedPoints.isEmpty || !boundingBoxes.isEmpty {
                Button(action: clearAnnotations) {
                    Label("Clear", systemImage: "xmark.circle")
                }
                .buttonStyle(.borderless)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(NSColor.windowBackgroundColor))
    }

    // MARK: - Editor View

    var editorView: some View {
        ZStack {
            if let inputImage = inputImage {
                ZoomableScrollView(magnification: $magnification) {
                    // Fixed size content for zoom/pan
                    let imageSize = inputImage.size
                    let baseWidth: CGFloat = max(800, imageSize.width)
                    let baseHeight: CGFloat = baseWidth * (imageSize.height / imageSize.width)

                    ZStack {
                        // Base image
                        Image(nsImage: inputImage)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: baseWidth, height: baseHeight)

                        // Mask overlay
                        if let maskImage = maskImage {
                            Image(nsImage: maskImage)
                                .resizable()
                                .frame(width: baseWidth, height: baseHeight)
                                .allowsHitTesting(false)
                                .opacity(0.6)
                        }

                        // Points overlay
                        PointsOverlay(points: selectedPoints, displayedSize: CGSize(width: baseWidth, height: baseHeight))
                            .frame(width: baseWidth, height: baseHeight)

                        // Bounding box overlay
                        BoundingBoxOverlay(
                            boxes: boundingBoxes,
                            currentBox: currentBox,
                            displayedSize: CGSize(width: baseWidth, height: baseHeight)
                        )
                        .frame(width: baseWidth, height: baseHeight)
                    }
                    .frame(width: baseWidth, height: baseHeight)
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 5)
                            .onChanged { value in
                                handleDrag(value: value, displayedSize: CGSize(width: baseWidth, height: baseHeight), offset: .zero)
                            }
                            .onEnded { value in
                                handleDragEnd(value: value, displayedSize: CGSize(width: baseWidth, height: baseHeight), offset: .zero)
                            }
                    )
                    .onTapGesture { location in
                        handleTap(at: location, containerSize: CGSize(width: baseWidth, height: baseHeight), displayedSize: CGSize(width: baseWidth, height: baseHeight), offset: .zero)
                    }
                    .onHover { isHovering in
                        handleHover(isHovering)
                    }
                }
                .zoomControls(magnification: $magnification)
            } else {
                dropZone
            }
        }
    }

    // MARK: - Drop Zone

    var dropZone: some View {
        RoundedRectangle(cornerRadius: 12)
            .strokeBorder(isDragging ? Color(red: 0.1, green: 0.3, blue: 0.7) : Color.gray.opacity(0.5), style: StrokeStyle(lineWidth: 2, dash: [10]))
            .background(Color.gray.opacity(0.05))
            .overlay(
                VStack(spacing: 12) {
                    Image(systemName: "photo.on.rectangle.angled")
                        .font(.system(size: 48))
                        .foregroundColor(.gray)
                    Text("Drop an image here")
                        .font(.title3)
                        .foregroundColor(.gray)
                }
            )
            .onDrop(of: [.image, .fileURL, .url], isTargeted: $isDragging) { providers in
                handleDrop(providers: providers)
                return true
            }
            .padding(40)
    }

    // MARK: - Status Footer

    var statusFooter: some View {
        HStack {
            // Status
            HStack(spacing: 6) {
                if env.isProcessing {
                    ProgressView()
                        .scaleEffect(0.6)
                        .frame(width: 12, height: 12)
                }
                Text(env.status)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer()

            // Clear image button
            if inputImage != nil {
                Button("Clear Image") {
                    clearAll()
                }
                .buttonStyle(.borderless)
                .font(.caption)
            }
        }
        .padding(8)
        .background(Color(NSColor.windowBackgroundColor))
    }

    // MARK: - Gesture Handlers

    private func handleTap(at location: CGPoint, containerSize: CGSize, displayedSize: CGSize, offset: CGPoint) {
        guard selectedTool == .point else { return }
        guard inputImage != nil, inputImagePath != nil else { return }

        // Convert to normalized coordinates
        let normalizedX = (location.x - offset.x) / displayedSize.width
        let normalizedY = (location.y - offset.y) / displayedSize.height

        // Bounds check
        guard normalizedX >= 0, normalizedX <= 1, normalizedY >= 0, normalizedY <= 1 else {
            print("Click outside image bounds")
            return
        }

        let point = SAMPoint(normalizedCoords: CGPoint(x: normalizedX, y: normalizedY))

        withAnimation(.spring(response: 0.3)) {
            selectedPoints.append(point)
        }

        print("Added point at normalized: (\(normalizedX), \(normalizedY))")
    }

    private func handleDrag(value: DragGesture.Value, displayedSize: CGSize, offset: CGPoint) {
        guard selectedTool == .boundingBox else { return }
        guard inputImage != nil else { return }

        // Normalize start and current positions
        let startNorm = normalizePoint(value.startLocation, displayedSize: displayedSize, offset: offset)
        let currentNorm = normalizePoint(value.location, displayedSize: displayedSize, offset: offset)

        if currentBox == nil {
            currentBox = SAMBox(startPoint: startNorm, endPoint: currentNorm)
        } else {
            currentBox?.endPoint = currentNorm
        }
    }

    private func handleDragEnd(value: DragGesture.Value, displayedSize: CGSize, offset: CGPoint) {
        guard selectedTool == .boundingBox else { return }
        guard let box = currentBox else { return }

        // Validate box has meaningful size
        guard box.isValid else {
            print("Box too small, discarding")
            currentBox = nil
            return
        }

        withAnimation(.spring(response: 0.3)) {
            boundingBoxes.append(box)
            currentBox = nil
        }

        print("Added bounding box")
    }

    private func handleHover(_ isHovering: Bool) {
        if isHovering && inputImage != nil {
            switch selectedTool {
            case .point:
                NSCursor.pointingHand.push()
            case .boundingBox:
                NSCursor.crosshair.push()
            }
        } else {
            NSCursor.pop()
        }
    }

    private func normalizePoint(_ point: CGPoint, displayedSize: CGSize, offset: CGPoint) -> CGPoint {
        CGPoint(
            x: max(0, min(1, (point.x - offset.x) / displayedSize.width)),
            y: max(0, min(1, (point.y - offset.y) / displayedSize.height))
        )
    }

    // MARK: - Re-inference

    private func triggerReInference() {
        guard !selectedPoints.isEmpty || !boundingBoxes.isEmpty else { return }
        guard let path = inputImagePath else { return }
        guard !env.isProcessing else { return }

        Task {
            do {
                // Set image if needed (persistent worker will cache it)
                let pixelSize = try await env.setImage(path: path)
                self.imagePixelSize = pixelSize

                // Run prediction
                let maskURL = try await env.predict(
                    points: selectedPoints,
                    box: boundingBoxes.first,  // Use first box for now
                    imageSize: pixelSize
                )

                if let newMask = NSImage(contentsOf: maskURL) {
                    await MainActor.run {
                        self.maskImage = newMask
                    }
                }
            } catch {
                print("Prediction error: \(error)")
                await MainActor.run {
                    env.status = "Error: \(error.localizedDescription)"
                }
            }
        }
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

        Task {
            try? await env.resetPredictor()
        }
    }

    // MARK: - Image Loading

    func handleDrop(providers: [NSItemProvider]) {
        print("Dropped items: \(providers.count)")
        guard let provider = providers.first else { return }
        print("Registered types: \(provider.registeredTypeIdentifiers)")

        // Clear previous annotations when loading new image
        clearAnnotations()

        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, error in
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
                print("Found compatible image type: \(type)")

                if provider.canLoadObject(ofClass: NSImage.self) {
                    _ = provider.loadObject(ofClass: NSImage.self) { image, error in
                        if let image = image as? NSImage {
                            self.saveAndLoad(image: image)
                        }
                    }
                    return
                }

                provider.loadItem(forTypeIdentifier: type, options: nil) { item, error in
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
        } else {
            print("No compatible types found for dropping")
            DispatchQueue.main.async {
                self.env.status = "Error: Unsupported drop type"
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
                print("Saved dropped image to temp file: \(tempFile.path)")
                self.loadImage(from: tempFile)
            }
        } catch {
            print("Failed to save dropped image: \(error.localizedDescription)")
        }
    }

    private func loadImage(from url: URL) {
        print("Attempting to load image from: \(url.path)")
        DispatchQueue.main.async {
            guard let image = NSImage(contentsOf: url) else {
                print("Failed to create NSImage from: \(url.path)")
                self.env.status = "Error: Could not load image"
                return
            }

            self.inputImage = image
            self.maskImage = nil
            self.env.status = "Loaded image: \(url.lastPathComponent)"
            print("Successfully loaded image from source")

            let safeExtensions = ["png", "jpg", "jpeg", "bmp", "webp", "tiff"]
            let ext = url.pathExtension.lowercased()

            if safeExtensions.contains(ext) {
                print("Format '\(ext)' is safe for backend.")
                self.inputImagePath = url.path
            } else {
                print("Source format '\(ext)' requires conversion for backend...")
                self.saveImageForBackend(image: image)
            }

            // Get pixel size
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
                print("Saved backend working copy: \(tempFile.path)")
                self.inputImagePath = tempFile.path
            }
        } catch {
            print("Failed to save converting image: \(error.localizedDescription)")
            self.env.status = "Error: conversion failed"
        }
    }
}

#Preview {
    ContentView()
}
