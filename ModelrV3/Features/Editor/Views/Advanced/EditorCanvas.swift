import SwiftUI

struct EditorCanvas: View {
    @ObservedObject var viewModel: EditorViewModel
    
    var body: some View {
        ZStack {
            Color(NSColor.windowBackgroundColor).opacity(0.5)
            
            if viewModel.currentStep == .input && viewModel.inputImage == nil {
                DropZoneView(viewModel: viewModel)
            } else if viewModel.currentStep == .generate, let modelURL = viewModel.generated3DModelURL, !viewModel.isGenerating {
                Model3DViewer(viewModel: viewModel, modelURL: modelURL)
            } else if viewModel.currentStep == .generate && viewModel.isGenerating {
                GenerationProgressView(viewModel: viewModel)
            } else if let inputImage = viewModel.inputImage {
                imageEditorView(inputImage: inputImage)
            } else {
                DropZoneView(viewModel: viewModel)
            }
        }
        .onPasteCommand(of: [.image, .png, .jpeg, .tiff, .fileURL]) { providers in
            handlePaste(providers: providers)
        }
    }
    
    private func imageEditorView(inputImage: NSImage) -> some View {
        ZoomableImageView(
            magnification: $viewModel.magnification,
            onTap: { normalized in
                viewModel.handleTap(at: normalized, isNegative: false)
            },
            onOptionTap: { normalized in
                viewModel.handleTap(at: normalized, isNegative: true)
            },
            onRightClick: { normalized in
                viewModel.handleRightClick(at: normalized)
            },
            onDragStart: { point in
                viewModel.handleDragStart(at: point)
            },
            onDragChange: { start, current in
                viewModel.handleDragChange(start: start, current: current)
            },
            onDragEnd: { start, end in
                viewModel.handleDragEnd(start: start, end: end)
            },
            onPaintStart: { point in
                viewModel.handlePaintStart(at: point)
            },
            onPaintContinue: { point in
                viewModel.handlePaintContinue(at: point)
            },
            onPaintEnd: {
                viewModel.handlePaintEnd()
            },
            onLassoStart: { point in
                viewModel.handleLassoStart(at: point)
            },
            onLassoContinue: { point in
                viewModel.handleLassoContinue(at: point)
            },
            onLassoEnd: {
                viewModel.handleLassoEnd()
            },
            onMouseMoved: { point in
                viewModel.brushCursorPosition = point
            },
            onMouseExited: {
                viewModel.brushCursorPosition = nil
            },
            toolMode: viewModel.effectiveToolMode,
            contentSize: viewModel.displaySize,
            contentID: "\(viewModel.inputImagePath ?? "")_v\(viewModel.imageVersion)"
        ) {
            imageContentView(inputImage: inputImage)
        }
        .zoomControls(magnification: $viewModel.magnification)
    }
    
    private func imageContentView(inputImage: NSImage) -> some View {
        ZStack {
            // Base image
            Image(nsImage: inputImage)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: viewModel.displaySize.width, height: viewModel.displaySize.height)
            
            // Mask overlay (segment/generate modes)
            if viewModel.currentStep != .refine && viewModel.currentStep != .input,
               let maskImage = viewModel.maskImage {
                Image(nsImage: maskImage)
                    .resizable()
                    .frame(width: viewModel.displaySize.width, height: viewModel.displaySize.height)
                    .allowsHitTesting(false)
                    .opacity(viewModel.maskOpacity)
            }
            
            // Live paint preview
            if viewModel.currentStep == .segment,
               viewModel.selectedTool == .paint,
               let liveMask = viewModel.livePaintMask {
                Image(nsImage: liveMask)
                    .resizable()
                    .frame(width: viewModel.displaySize.width, height: viewModel.displaySize.height)
                    .allowsHitTesting(false)
                    .opacity(viewModel.maskOpacity * 0.8)
            }
            
            // Confidence overlay
            if viewModel.currentStep != .refine && viewModel.currentStep != .input,
               viewModel.showConfidenceOverlay,
               let confidence = viewModel.confidenceOverlay {
                Image(nsImage: confidence)
                    .resizable()
                    .frame(width: viewModel.displaySize.width, height: viewModel.displaySize.height)
                    .blendMode(.screen)
                    .opacity(0.6)
                    .allowsHitTesting(false)
            }
            
            // Tool overlays
            toolOverlays
        }
        .frame(width: viewModel.displaySize.width, height: viewModel.displaySize.height)
    }
    
    @ViewBuilder
    private var toolOverlays: some View {
        // Paint strokes overlay
        if viewModel.currentStep == .segment {
            PaintStrokeOverlay(
                strokes: viewModel.paintStrokes,
                currentStroke: viewModel.currentPaintStroke,
                displayedSize: viewModel.displaySize
            )
            .frame(width: viewModel.displaySize.width, height: viewModel.displaySize.height)
        }
        
        // Lasso overlay (segment mode)
        if viewModel.currentStep == .segment && viewModel.selectedTool == .lasso {
            LassoOverlay(
                lassoSelections: viewModel.lassoSelections,
                currentLasso: viewModel.currentLasso,
                displayedSize: viewModel.displaySize,
                isPreprocessMode: false
            )
            .frame(width: viewModel.displaySize.width, height: viewModel.displaySize.height)
        }
        
        // Polygon overlay (segment mode)
        if viewModel.currentStep == .segment && !viewModel.skipSegmentation {
            PolygonOverlay(
                polygons: viewModel.polygonSelections,
                currentPolygon: viewModel.selectedTool == .polygon ? viewModel.currentPolygon : nil,
                displayedSize: viewModel.displaySize
            )
            .frame(width: viewModel.displaySize.width, height: viewModel.displaySize.height)
        }
        
        // Preprocess overlays
        if viewModel.currentStep == .refine {
            if viewModel.selectedPreprocessTool == .crop {
                CropOverlay(cropRect: viewModel.cropRect, displayedSize: viewModel.displaySize)
                    .frame(width: viewModel.displaySize.width, height: viewModel.displaySize.height)
            } else if viewModel.selectedPreprocessTool == .polygonCrop {
                LassoOverlay(
                    lassoSelections: [],
                    currentLasso: viewModel.preprocessLasso,
                    displayedSize: viewModel.displaySize,
                    isPreprocessMode: true
                )
                .frame(width: viewModel.displaySize.width, height: viewModel.displaySize.height)
            }
        }
        
        // Points overlay (segment mode)
        if viewModel.currentStep == .segment && !viewModel.skipSegmentation {
            PointsOverlay(
                points: viewModel.selectedPoints,
                displayedSize: viewModel.displaySize,
                selectedPointId: viewModel.selectedPointId,
                onPointTap: { point in
                    if viewModel.selectedPointId == point.id {
                        viewModel.selectedPointId = nil
                    } else {
                        viewModel.selectedPointId = point.id
                        viewModel.selectedBoxId = nil
                        viewModel.selectedLassoId = nil
                    }
                },
                onPointDragEnd: { _, _ in }
            )
            .frame(width: viewModel.displaySize.width, height: viewModel.displaySize.height)
        }
        
        // Bounding box overlay (segment mode)
        if viewModel.currentStep == .segment && !viewModel.skipSegmentation {
            BoundingBoxOverlay(
                boxes: viewModel.boundingBoxes,
                currentBox: viewModel.currentBox,
                displayedSize: viewModel.displaySize,
                imagePixelSize: viewModel.imagePixelSize,
                selectedBoxId: viewModel.selectedBoxId,
                onBoxTap: { box in
                    if viewModel.selectedBoxId == box.id {
                        viewModel.selectedBoxId = nil
                    } else {
                        viewModel.selectedBoxId = box.id
                        viewModel.selectedPointId = nil
                        viewModel.selectedLassoId = nil
                    }
                }
            )
            .frame(width: viewModel.displaySize.width, height: viewModel.displaySize.height)
        }
        
        // Brush cursor preview (segment paint mode)
        if viewModel.currentStep == .segment && viewModel.selectedTool == .paint {
            BrushCursorPreview(
                brushSize: viewModel.brushSize,
                isErasing: viewModel.isErasing,
                displayedSize: viewModel.displaySize,
                cursorPosition: viewModel.brushCursorPosition
            )
            .frame(width: viewModel.displaySize.width, height: viewModel.displaySize.height)
        }
    }
    
    private func handlePaste(providers: [NSItemProvider]) {
        guard let provider = providers.first else { return }
        viewModel.clearAnnotations()
        
        if provider.canLoadObject(ofClass: NSImage.self) {
            _ = provider.loadObject(ofClass: NSImage.self) { image, _ in
                if let image = image as? NSImage {
                    viewModel.saveAndLoad(image: image)
                }
            }
        }
    }
}

// MARK: - Drop Zone View

struct DropZoneView: View {
    @ObservedObject var viewModel: EditorViewModel
    
    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 64))
                .foregroundColor(.secondary)
            
            Text("Drop an image here or click to select")
                .font(.title3)
                .foregroundColor(.secondary)
            
            Button(action: selectImage) {
                Label("Select Image", systemImage: "folder")
                    .font(.headline)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .onDrop(of: [.image, .fileURL], isTargeted: $viewModel.isDragging) { providers in
            handleDrop(providers: providers)
            return true
        }
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [10]))
                .foregroundColor(viewModel.isDragging ? .accentColor : .secondary.opacity(0.3))
                .padding()
        )
    }
    
    private func selectImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image, .png, .jpeg, .tiff, .bmp, .gif, .webP]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "Choose an image to segment"
        
        if panel.runModal() == .OK, let url = panel.url {
            viewModel.loadImage(from: url)
        }
    }
    
    private func handleDrop(providers: [NSItemProvider]) {
        guard let provider = providers.first else { return }
        
        if provider.hasItemConformingToTypeIdentifier("public.file-url") {
            _ = provider.loadItem(forTypeIdentifier: "public.file-url", options: nil) { (data, error) in
                if let data = data as? Data,
                   let url = URL(dataRepresentation: data, relativeTo: nil) {
                    DispatchQueue.main.async {
                        viewModel.loadImage(from: url)
                    }
                }
            }
        } else if provider.canLoadObject(ofClass: NSImage.self) {
            _ = provider.loadObject(ofClass: NSImage.self) { image, error in
                if let image = image as? NSImage {
                    DispatchQueue.main.async {
                        viewModel.saveAndLoad(image: image)
                    }
                }
            }
        }
    }
}

// MARK: - 3D Model Viewer

struct Model3DViewer: View {
    @ObservedObject var viewModel: EditorViewModel
    let modelURL: URL
    
    var body: some View {
        VStack(spacing: 0) {
            // Header with back button
            HStack {
                Button(action: {
                    viewModel.generated3DModelURL = nil
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
                
                Button(action: {
                    NSWorkspace.shared.selectFile(modelURL.path, inFileViewerRootedAtPath: modelURL.deletingLastPathComponent().path)
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
            ModelViewerContainer(modelURL: modelURL)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

// MARK: - Generation Progress View

struct GenerationProgressView: View {
    @ObservedObject var viewModel: EditorViewModel
    
    var body: some View {
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
                
                if !viewModel.generationProgress.stage.isEmpty {
                    Text(viewModel.generationProgress.stage)
                        .font(.headline)
                        .foregroundColor(.secondary)
                }
            }
            
            // Progress bar
            if viewModel.generationProgress.isActive {
                VStack(spacing: 12) {
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
                                .frame(width: geo.size.width * CGFloat(viewModel.generationProgress.percentComplete / 100), height: 12)
                                .animation(.easeInOut(duration: 0.3), value: viewModel.generationProgress.percentComplete)
                        }
                    }
                    .frame(height: 12)
                    .frame(maxWidth: 400)
                    
                    // Progress details
                    HStack(spacing: 20) {
                        Text(String(format: "%.0f%%", viewModel.generationProgress.percentComplete))
                            .font(.system(.title3, design: .monospaced).bold())
                        
                        Text("\(viewModel.generationProgress.currentStep)/\(viewModel.generationProgress.totalSteps)")
                            .font(.system(.body, design: .monospaced))
                            .foregroundColor(.secondary)
                        
                        if !viewModel.generationProgress.formattedSpeed.isEmpty {
                            HStack(spacing: 4) {
                                Image(systemName: "speedometer")
                                Text(viewModel.generationProgress.formattedSpeed)
                            }
                            .font(.system(.body, design: .monospaced))
                            .foregroundColor(.secondary)
                        }
                        
                        if !viewModel.generationProgress.formattedETA.isEmpty {
                            HStack(spacing: 4) {
                                Image(systemName: "clock")
                                Text(viewModel.generationProgress.formattedETA)
                            }
                            .font(.system(.body, design: .monospaced))
                            .foregroundColor(.secondary)
                        }
                    }
                }
                .padding(.horizontal, 40)
            } else {
                ProgressView()
                    .scaleEffect(1.5)
                    .padding()
                
                Text("Preparing...")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
            
            // Elapsed time
            if let startTime = viewModel.generationStartTime {
                let elapsed = Date().timeIntervalSince(startTime)
                Text(viewModel.formatElapsedTime(elapsed))
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            // Cancel button
            Button(action: {
                viewModel.cancelGeneration()
            }) {
                Label("Cancel", systemImage: "xmark.circle")
                    .font(.headline)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .tint(.red)
            
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
