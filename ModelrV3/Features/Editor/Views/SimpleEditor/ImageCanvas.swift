import SwiftUI
import UniformTypeIdentifiers

/// Image canvas for ContentViewSimple - handles image display and interactions
struct ImageCanvas: View {
    @ObservedObject var viewModel: SimpleEditorViewModel
    
    var body: some View {
        ZStack {
            Color(NSColor.textBackgroundColor).opacity(0.1)
            AppDesign.Checkerboard()
                .opacity(0.5)
                .allowsHitTesting(false)
            
            imageContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            
            breadcrumbOverlay
            
            if viewModel.inputImage != nil && !(viewModel.currentStep == .generate && viewModel.generated3DModelURL != nil) {
                ScrollWheelZoomOverlay(
                    zoomScale: $viewModel.zoomScale,
                    minZoom: 0.5,
                    maxZoom: 5.0
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onDrop(of: [.image, .fileURL], isTargeted: $viewModel.isDragging) { providers in
            handleDrop(providers: providers)
        }
    }
    
    @ViewBuilder
    private var imageContent: some View {
        Group {
            if viewModel.currentStep == .generate, let modelURL = viewModel.generated3DModelURL {
                ModelViewerContainer(modelURL: modelURL)
                    .padding(AppDesign.Spacing.p24)
            } else if viewModel.currentStep == .generate, let composite = viewModel.compositeImage {
                compositeImageView(composite)
            } else if let image = viewModel.inputImage {
                interactiveImageView(image)
            } else {
                dropZoneView
            }
        }
    }
    
    @ViewBuilder
    private var breadcrumbOverlay: some View {
        VStack {
            HStack {
                if let path = viewModel.inputImagePath {
                    let fileName = URL(fileURLWithPath: path).lastPathComponent
                    HStack(spacing: AppDesign.Spacing.p8) {
                        Image(systemName: "doc.fill")
                            .font(.system(size: 10))
                        Text(fileName)
                            .font(.system(size: AppDesign.FontSize.caption, weight: .medium))
                    }
                    .padding(.horizontal, AppDesign.Spacing.p12)
                    .padding(.vertical, AppDesign.Spacing.p6)
                    .background(.ultraThinMaterial)
                    .clipShape(Capsule())
                    .overlay(Capsule().stroke(Color.white.opacity(0.1), lineWidth: 1))
                    .padding(AppDesign.Spacing.p16)
                }
                Spacer()
            }
            Spacer()
        }
    }
    
    @ViewBuilder
    private func compositeImageView(_ composite: NSImage) -> some View {
        GeometryReader { geo in
            let size = viewModel.fitSize(composite.size, in: geo.size)
            VStack {
                Image(nsImage: composite)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: size.width, height: size.height)
                    .shadow(color: .black.opacity(0.2), radius: 20, y: 10)
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
    }
    
    @ViewBuilder
    private func interactiveImageView(_ image: NSImage) -> some View {
        GeometryReader { geo in
            let size = viewModel.fitSize(image.size, in: geo.size)
            
            ZStack {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: size.width, height: size.height)
                    .shadow(color: .black.opacity(0.15), radius: 15, y: 8)
                
                if viewModel.currentStep == .segment {
                    segmentationOverlays(size: size)
                }
                
                if viewModel.currentStep == .touchup {
                    touchupOverlays(size: size)
                }
            }
            .frame(width: size.width, height: size.height)
            .position(x: geo.size.width / 2, y: geo.size.height / 2)
            .contentShape(Rectangle())
            .addInteractions(viewModel: viewModel, geo: geo, displaySize: size)
            .scaleEffect(viewModel.zoomScale)
            .gesture(
                MagnificationGesture()
                    .onChanged { value in
                        viewModel.zoomScale = max(0.5, min(5.0, value))
                    }
            )
        }
        .overlay(alignment: .bottomTrailing) {
            zoomControls
        }
    }
    
    @ViewBuilder
    private func segmentationOverlays(size: CGSize) -> some View {
        // Non-selected masks
        ForEach(Array(viewModel.allMasks.enumerated()).filter { $0.offset != viewModel.selectedMaskIndex }, id: \.offset) { index, maskData in
            let color = viewModel.colorForMask(index)
            Rectangle()
                .fill(color)
                .frame(width: size.width, height: size.height)
                .mask(
                    Image(nsImage: maskData.image)
                        .resizable()
                        .frame(width: size.width, height: size.height)
                )
                .opacity(0.4)
                .allowsHitTesting(false)
        }
        
        // Selected mask
        if viewModel.selectedMaskIndex < viewModel.allMasks.count {
            let maskData = viewModel.allMasks[viewModel.selectedMaskIndex]
            let color = viewModel.colorForMask(viewModel.selectedMaskIndex)
            
            Rectangle()
                .fill(color)
                .frame(width: size.width, height: size.height)
                .mask(
                    Image(nsImage: maskData.image)
                        .resizable()
                        .frame(width: size.width, height: size.height)
                )
                .opacity(0.7)
                .allowsHitTesting(false)
            
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
                            .padding(6)
                            .blur(radius: 1)
                            .blendMode(.destinationOut)
                    }
                    .compositingGroup()
                )
                .opacity(1.0)
                .allowsHitTesting(false)
        }
        
        // Points overlay
        ForEach(viewModel.selectedPoints) { point in
            Circle()
                .fill(point.isPositive ? AppDesign.success : AppDesign.destructive)
                .frame(width: 12, height: 12)
                .overlay(Circle().stroke(Color.white, lineWidth: 2))
                .shadow(color: .black.opacity(0.3), radius: 2)
                .position(
                    x: point.normalizedCoords.x * size.width,
                    y: point.normalizedCoords.y * size.height
                )
        }
    }
    
    @ViewBuilder
    private func touchupOverlays(size: CGSize) -> some View {
        if let maskImage = viewModel.editableMaskImage {
            Rectangle()
                .fill(AppDesign.maskColor)
                .frame(width: size.width, height: size.height)
                .mask(
                    Image(nsImage: maskImage)
                        .resizable()
                        .frame(width: size.width, height: size.height)
                )
                .opacity(0.6)
                .allowsHitTesting(false)
            
            // Brush preview
            if let pos = viewModel.brushPreviewPosition {
                let scaledBrushSize = viewModel.brushSize * size.width / 500.0
                Circle()
                    .stroke(viewModel.brushMode == .add ? AppDesign.success : AppDesign.eraserColor, lineWidth: 2)
                    .frame(width: scaledBrushSize, height: scaledBrushSize)
                    .background(Circle().fill((viewModel.brushMode == .add ? AppDesign.success : AppDesign.eraserColor).opacity(0.1)))
                    .position(x: pos.x * size.width, y: pos.y * size.height)
                    .allowsHitTesting(false)
            }
        }
    }
    
    @ViewBuilder
    private var zoomControls: some View {
        if viewModel.zoomScale != 1.0 {
            Button(action: {
                withAnimation(.easeOut(duration: 0.2)) {
                    viewModel.zoomScale = 1.0
                }
            }) {
                HStack(spacing: 4) {
                    Text("\(Int(viewModel.zoomScale * 100))%")
                        .font(.system(size: AppDesign.FontSize.caption, weight: .medium, design: .monospaced))
                    Image(systemName: "arrow.counterclockwise")
                        .font(.system(size: AppDesign.FontSize.caption))
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(.ultraThinMaterial)
                .clipShape(Capsule())
                .overlay(Capsule().stroke(Color.white.opacity(0.1), lineWidth: 1))
            }
            .buttonStyle(.plain)
            .padding(AppDesign.Spacing.p24)
            .transition(.scale.combined(with: .opacity))
        }
    }
    
    @ViewBuilder
    private var dropZoneView: some View {
        VStack(spacing: AppDesign.Spacing.p24) {
            ZStack {
                Circle()
                    .fill(.ultraThinMaterial)
                    .frame(width: 100, height: 100)
                    .overlay(Circle().stroke(Color.primary.opacity(0.1), lineWidth: 1))
                
                Image(systemName: "square.and.arrow.down")
                    .font(.system(size: 40, weight: .light))
                    .foregroundColor(.accentColor)
            }
            .shadow(color: .black.opacity(0.1), radius: 20)
            
            VStack(spacing: AppDesign.Spacing.p8) {
                Text("Ready for Creation")
                    .font(.system(size: AppDesign.FontSize.title3, weight: .bold))
                
                Text("Drag and drop an image here or click to browse")
                    .font(.system(size: AppDesign.FontSize.body))
                    .foregroundColor(.secondary)
            }
            
            AppDesign.GlassButton("Select Image", icon: "photo") {
                selectImage()
            }
            .controlSize(.large)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 24)
                .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [8, 4]))
                .foregroundColor(.primary.opacity(0.1))
                .padding(AppDesign.Spacing.p48)
        )
    }
    
    // MARK: - Actions
    private func selectImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image, .png, .jpeg, .tiff, .bmp, .gif, .webP]
        panel.allowsMultipleSelection = false
        
        if panel.runModal() == .OK, let url = panel.url {
            viewModel.loadImage(from: url)
        }
    }
    
    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        
        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier) { item, _ in
                if let data = item as? Data, let url = URL(dataRepresentation: data, relativeTo: nil) {
                    DispatchQueue.main.async { viewModel.loadImage(from: url) }
                }
            }
            return true
        }
        
        if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
            provider.loadItem(forTypeIdentifier: UTType.image.identifier) { item, _ in
                if let data = item as? Data, let image = NSImage(data: data) {
                    let tempPath = NSTemporaryDirectory() + "dropped_image_\(UUID().uuidString).png"
                    if let tiff = image.tiffRepresentation,
                       let bitmap = NSBitmapImageRep(data: tiff),
                       let png = bitmap.representation(using: .png, properties: [:]) {
                        try? png.write(to: URL(fileURLWithPath: tempPath))
                    }
                    DispatchQueue.main.async {
                        viewModel.loadImage(from: URL(fileURLWithPath: tempPath))
                    }
                }
            }
            return true
        }
        
        return false
    }
}

// MARK: - View Extension for Interactions
extension View {
    @ViewBuilder
    func addInteractions(viewModel: SimpleEditorViewModel, geo: GeometryProxy, displaySize: CGSize) -> some View {
        self
            .overlay(
                RightClickHandler { location in
                    if viewModel.currentStep == .segment {
                        let normalized = CGPoint(
                            x: location.x / displaySize.width,
                            y: location.y / displaySize.height
                        )
                        if normalized.x >= 0 && normalized.x <= 1 && normalized.y >= 0 && normalized.y <= 1 {
                            viewModel.addPoint(at: normalized)
                        }
                    }
                }
                .frame(width: displaySize.width, height: displaySize.height)
                .position(x: geo.size.width / 2, y: geo.size.height / 2)
            )
            .onTapGesture { location in
                let imageX = (geo.size.width - displaySize.width) / 2
                let imageY = (geo.size.height - displaySize.height) / 2
                
                let normalized = CGPoint(
                    x: (location.x - imageX) / displaySize.width,
                    y: (location.y - imageY) / displaySize.height
                )
                guard normalized.x >= 0 && normalized.x <= 1 && normalized.y >= 0 && normalized.y <= 1 else { return }
                
                if viewModel.currentStep == .segment && !viewModel.allMasks.isEmpty {
                    if let clickedIndex = viewModel.findMaskAtPoint(normalized, displaySize: displaySize) {
                        withAnimation(.easeOut(duration: 0.15)) {
                            viewModel.selectedMaskIndex = clickedIndex
                        }
                    }
                } else if viewModel.currentStep == .touchup {
                    viewModel.saveUndoState()
                    viewModel.paintOnMask(at: normalized)
                }
            }
            .onContinuousHover { phase in
                if viewModel.currentStep == .touchup {
                    switch phase {
                    case .active(let location):
                        let imageX = (geo.size.width - displaySize.width) / 2
                        let imageY = (geo.size.height - displaySize.height) / 2
                        
                        let normalized = CGPoint(
                            x: (location.x - imageX) / displaySize.width,
                            y: (location.y - imageY) / displaySize.height
                        )
                        if normalized.x >= 0 && normalized.x <= 1 && normalized.y >= 0 && normalized.y <= 1 {
                            viewModel.brushPreviewPosition = normalized
                        } else {
                            viewModel.brushPreviewPosition = nil
                        }
                    case .ended:
                        viewModel.brushPreviewPosition = nil
                    }
                } else {
                    viewModel.brushPreviewPosition = nil
                }
            }
            .gesture(
                viewModel.currentStep == .touchup ?
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        if !viewModel.isStrokeInProgress {
                            viewModel.isStrokeInProgress = true
                            viewModel.saveUndoState()
                        }
                        
                        let imageX = (geo.size.width - displaySize.width) / 2
                        let imageY = (geo.size.height - displaySize.height) / 2
                        
                        let normalized = CGPoint(
                            x: (value.location.x - imageX) / displaySize.width,
                            y: (value.location.y - imageY) / displaySize.height
                        )
                        if normalized.x >= 0 && normalized.x <= 1 && normalized.y >= 0 && normalized.y <= 1 {
                            viewModel.brushPreviewPosition = normalized
                            viewModel.paintOnMask(at: normalized)
                        }
                    }
                    .onEnded { _ in
                        viewModel.isStrokeInProgress = false
                    }
                : nil
            )
    }
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
        private var rightClickMonitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()

            if let monitor = rightClickMonitor {
                NSEvent.removeMonitor(monitor)
                rightClickMonitor = nil
            }

            if window != nil {
                rightClickMonitor = NSEvent.addLocalMonitorForEvents(matching: .rightMouseDown) { [weak self] event in
                    guard let self = self,
                          let window = self.window,
                          event.window == window else {
                        return event
                    }

                    let locationInWindow = event.locationInWindow
                    let locationInView = self.convert(locationInWindow, from: nil)

                    if self.bounds.contains(locationInView) {
                        let flippedLocation = CGPoint(x: locationInView.x, y: self.bounds.height - locationInView.y)
                        self.onRightClick?(flippedLocation)
                        return nil  // Consume the event
                    }
                    return event
                }
            }
        }

        override func viewWillMove(toWindow newWindow: NSWindow?) {
            super.viewWillMove(toWindow: newWindow)
            if newWindow == nil, let monitor = rightClickMonitor {
                NSEvent.removeMonitor(monitor)
                rightClickMonitor = nil
            }
        }

        // Return nil so left clicks pass through to SwiftUI gestures
        override func hitTest(_ point: NSPoint) -> NSView? {
            return nil
        }
    }
}

// MARK: - Scroll Wheel Zoom
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
        private var scrollMonitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()

            // Remove any existing monitor
            if let monitor = scrollMonitor {
                NSEvent.removeMonitor(monitor)
                scrollMonitor = nil
            }

            // Add local event monitor for scroll wheel events
            if window != nil {
                scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                    guard let self = self,
                          let window = self.window,
                          event.window == window else {
                        return event
                    }

                    // Check if mouse is within our bounds
                    let locationInWindow = event.locationInWindow
                    let locationInView = self.convert(locationInWindow, from: nil)

                    if self.bounds.contains(locationInView) {
                        let delta = event.deltaY
                        if abs(delta) > 0.001 {
                            self.coordinator?.handleScroll(deltaY: delta)
                            return nil  // Consume the event
                        }
                    }
                    return event
                }
            }
        }

        override func viewWillMove(toWindow newWindow: NSWindow?) {
            super.viewWillMove(toWindow: newWindow)
            if newWindow == nil, let monitor = scrollMonitor {
                NSEvent.removeMonitor(monitor)
                scrollMonitor = nil
            }
        }

        // Return nil so clicks/drags pass through to SwiftUI gestures below
        override func hitTest(_ point: NSPoint) -> NSView? {
            return nil
        }
    }
}
