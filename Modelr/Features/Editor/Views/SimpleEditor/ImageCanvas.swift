import SwiftUI
import UniformTypeIdentifiers

/// Image canvas for ContentViewSimple - handles image display and interactions
struct ImageCanvas: View {
    @ObservedObject var viewModel: SimpleEditorViewModel
    @ObservedObject private var sizeService = HuggingFaceModelSizeService.shared

    var body: some View {
        ZStack {
            Color(NSColor.textBackgroundColor).opacity(0.1)
            AppDesign.Checkerboard()
                .opacity(0.5)
                .allowsHitTesting(false)
            
            imageContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            
            breadcrumbOverlay
            
            if viewModel.inputImage != nil && viewModel.currentStep != .postProcess {
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
        ZStack {
            // Setup content
            if viewModel.currentStep == .setup {
                setupCanvasContent
                    .transition(.opacity.animation(.easeOut(duration: 0.2)))
            }

            // Post-process & Modify: show colored component viewer or modified mesh
            if viewModel.currentStep == .postProcess || viewModel.currentStep == .modify {
                ZStack {
                    Group {
                        if viewModel.isAnalyzingMesh || viewModel.isExtractingComponents || viewModel.isModifyingMesh {
                            postProcessLoadingView
                                .padding(AppDesign.Spacing.p24)
                        } else if !viewModel.componentFiles.isEmpty && !viewModel.preloadedComponentNodes.isEmpty {
                            // Show colored components (preloaded with materials) - instant!
                            ComponentModelViewerContainer(
                                componentFiles: viewModel.componentFiles.map {
                                    ComponentModelViewer.ComponentFile(index: $0.index, path: $0.path)
                                },
                                keepIndices: viewModel.keepIndices,
                                deleteIndices: viewModel.deleteIndices,
                                hoveredIndex: viewModel.hoveredComponentIndex,
                                isolatedIndex: viewModel.isolatedComponentIndex,
                                displayMode: $viewModel.meshDisplayMode,
                                preloadedNodes: viewModel.preloadedComponentNodes,
                                customColor: $viewModel.customModelColor,
                                sourceImage: viewModel.inputImage,
                                onComponentClicked: { index in
                                    withAnimation(.easeOut(duration: 0.15)) {
                                        viewModel.handleViewportComponentClick(index)
                                    }
                                },
                                onComponentHovered: { index in
                                    viewModel.handleViewportComponentHover(index)
                                }
                            )
                            .id("components-\(viewModel.componentFiles.count)")
                            .padding(AppDesign.Spacing.p24)
                        } else if !viewModel.componentFiles.isEmpty {
                            // Fallback: component files exist but no preloaded nodes (load from disk)
                            ComponentModelViewerContainer(
                                componentFiles: viewModel.componentFiles.map {
                                    ComponentModelViewer.ComponentFile(index: $0.index, path: $0.path)
                                },
                                keepIndices: viewModel.keepIndices,
                                deleteIndices: viewModel.deleteIndices,
                                hoveredIndex: viewModel.hoveredComponentIndex,
                                isolatedIndex: viewModel.isolatedComponentIndex,
                                displayMode: $viewModel.meshDisplayMode,
                                customColor: $viewModel.customModelColor,
                                sourceImage: viewModel.inputImage,
                                onComponentClicked: { index in
                                    withAnimation(.easeOut(duration: 0.15)) {
                                        viewModel.handleViewportComponentClick(index)
                                    }
                                },
                                onComponentHovered: { index in
                                    viewModel.handleViewportComponentHover(index)
                                }
                            )
                            .id("components-fallback-\(viewModel.componentFiles.count)")
                            .padding(AppDesign.Spacing.p24)
                        } else if let modelURL = viewModel.currentMeshURL {
                            // Final fallback: show raw model (includes modified mesh)
                            ModelViewerContainer(
                                modelURL: modelURL,
                                viewMode: viewModel.viewMode,
                                displayMode: $viewModel.meshDisplayMode,
                                materialType: $viewModel.materialType,
                                customColor: $viewModel.customModelColor,
                                sourceImage: viewModel.inputImage
                            )
                            .id("mesh-\(modelURL.lastPathComponent)-\(viewModel.viewMode)-\(viewModel.modifiedModelURL?.lastPathComponent ?? "none")")
                            .padding(AppDesign.Spacing.p24)
                        }
                    }
                    .id("postprocess-\(viewModel.componentFiles.isEmpty)-\(viewModel.modifiedModelURL?.lastPathComponent ?? "none")-\(viewModel.isModifyingMesh)")

                    // Controls are now inside ComponentModelViewerContainer
                }
                .transition(.asymmetric(
                    insertion: .opacity.combined(with: .scale(scale: 0.98)).animation(.spring(response: 0.25, dampingFraction: 0.9)),
                    removal: .opacity.animation(.easeOut(duration: 0.1))
                ))
            }

            // Generate settings: always show composite image
            if viewModel.currentStep == .generateSettings {
                if let composite = viewModel.compositeImage {
                    compositeImageView(composite)
                        .transition(.opacity.animation(.easeOut(duration: 0.18)))
                } else {
                    // Loading placeholder while composite is being created
                    ProgressView()
                        .scaleEffect(1.2)
                        .transition(.opacity.animation(.easeOut(duration: 0.15)))
                }
            }

            // Generate step: show composite during generation
            if viewModel.currentStep == .generate {
                if let composite = viewModel.compositeImage {
                    // Show composite during generation
                    compositeImageView(composite)
                        .transition(.opacity.animation(.easeOut(duration: 0.18)))
                } else {
                    // Loading placeholder while composite is being created
                    ProgressView()
                        .scaleEffect(1.2)
                        .transition(.opacity.animation(.easeOut(duration: 0.15)))
                }
            }

            // Segment and touchup steps with interactive image
            if (viewModel.currentStep == .segment || viewModel.currentStep == .touchup), let image = viewModel.inputImage {
                interactiveImageView(image)
                    .transition(.opacity.animation(.easeOut(duration: 0.18)))
            }

            // Input step - drop zone or image
            if viewModel.currentStep == .input {
                if let image = viewModel.inputImage {
                    interactiveImageView(image)
                        .transition(.opacity.animation(.easeOut(duration: 0.18)))
                } else {
                    dropZoneView
                        .transition(.opacity.animation(.easeOut(duration: 0.2)))
                }
            }
        }
        .animation(.spring(response: 0.2, dampingFraction: 0.9), value: viewModel.currentStep)
    }

    // MARK: - Setup Canvas Content

    @ViewBuilder
    private var setupCanvasContent: some View {
        if viewModel.currentSetupSubStep == .chooseModel && !viewModel.setupSubStepCompleted.contains(.chooseModel) {
            modelSelectorView
                .onAppear {
                    // Fetch live model sizes from HuggingFace
                    Task {
                        await sizeService.queryAllSizes()
                    }
                }
        } else {
            // Blank view during setup (tips will be added later)
            Color.clear
        }
    }

    @ViewBuilder
    private var modelSelectorView: some View {
        GeometryReader { geo in
            let isCompact = geo.size.width < 500 || geo.size.height < 500
            let titleSize: CGFloat = isCompact ? 36 : 64
            let spacing: CGFloat = isCompact ? AppDesign.Spacing.p24 : AppDesign.Spacing.p48

            ScrollView(showsIndicators: false) {
                VStack(spacing: spacing) {
                    // Header
                    Text("Modelr")
                        .font(.system(size: titleSize, weight: .bold))
                        .tracking(-2)
                        .foregroundStyle(.primary)

                    // Model Selection
                    VStack(spacing: AppDesign.Spacing.p16) {
                        Text("Choose your 3D generation model")
                            .font(.system(size: isCompact ? AppDesign.FontSize.subheadline : AppDesign.FontSize.headline, weight: .semibold))
                            .foregroundStyle(.primary)

                        // Stack vertically on compact, horizontally on larger
                        let cardLayout = isCompact ? AnyLayout(VStackLayout(spacing: AppDesign.Spacing.p12)) : AnyLayout(HStackLayout(spacing: AppDesign.Spacing.p24))
                        cardLayout {
                            ForEach(SetupModelChoice.allCases, id: \.self) { choice in
                                modelChoiceCard(choice: choice, isRecommended: choice == .fast, isCompact: isCompact)
                            }
                        }
                    }

                    // CTA
                    VStack(spacing: AppDesign.Spacing.p16) {
                        AppDesign.GlassButton("Get Started", icon: "arrow.right") {
                            viewModel.startSetup()
                        }
                        .controlSize(isCompact ? .regular : .large)

                        HStack(spacing: AppDesign.Spacing.p8) {
                            Image(systemName: "arrow.down.circle")
                                .font(.system(size: AppDesign.FontSize.caption))
                            Text("Requires \(sizeService.totalSetupSize(for: viewModel.selectedModelChoice)) for initial download")
                                .font(.system(size: AppDesign.FontSize.caption, weight: .medium))
                            if sizeService.isQuerying {
                                ProgressView()
                                    .controlSize(.mini)
                                    .scaleEffect(0.7)
                            }
                        }
                        .foregroundStyle(.tertiary)
                        .animation(.easeInOut(duration: 0.2), value: viewModel.selectedModelChoice)
                    }
                }
                .padding(isCompact ? AppDesign.Spacing.p16 : AppDesign.Spacing.p24)
                .frame(minHeight: geo.size.height)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private func modelChoiceCard(choice: SetupModelChoice, isRecommended: Bool, isCompact: Bool = false) -> some View {
        let isSelected = viewModel.selectedModelChoice == choice

        Button {
            withAnimation(.easeOut(duration: 0.15)) {
                viewModel.selectedModelChoice = choice
            }
        } label: {
            VStack(alignment: .center, spacing: AppDesign.Spacing.p6) {
                // Center content
                Text(choice.displayName)
                    .font(.system(size: isCompact ? AppDesign.FontSize.subheadline : AppDesign.FontSize.body, weight: .semibold))
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.center)

                if !isCompact {
                    Text(choice.description)
                        .font(.system(size: AppDesign.FontSize.caption))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }

                // Use live-fetched size from HuggingFace
                Text(sizeService.displaySize(for: choice))
                    .font(.system(size: AppDesign.FontSize.caption, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(isCompact ? AppDesign.Spacing.p12 : AppDesign.Spacing.p16)
            .frame(width: isCompact ? nil : 150, height: isCompact ? nil : 115)
            .frame(maxWidth: isCompact ? .infinity : nil)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(isSelected ? AppDesign.accent.opacity(0.1) : Color.primary.opacity(0.03))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(isSelected ? AppDesign.accent : Color.primary.opacity(0.1), lineWidth: isSelected ? 2 : 1)
            )
            .overlay(alignment: .topLeading) {
                // Recommended badge (small, top-left)
                if isRecommended {
                    Text("Recommended")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(AppDesign.accent, in: Capsule())
                        .padding(5)
                }
            }
            .overlay(alignment: .bottomTrailing) {
                // HuggingFace link (small, subtle)
                if let url = choice.huggingFaceURL {
                    Button {
                        NSWorkspace.shared.open(url)
                    } label: {
                        Text("🤗")
                            .font(.system(size: 10))
                            .opacity(0.5)
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .help("View on HuggingFace")
                }
            }
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var breadcrumbOverlay: some View {
        VStack {
            HStack {
                // Hide filename in postProcess and modify steps (3D viewer mode)
                if let path = viewModel.inputImagePath,
                   viewModel.currentStep != .postProcess && viewModel.currentStep != .modify {
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
            .offset(viewModel.panOffset)
            .gesture(
                MagnificationGesture()
                    .onChanged { value in
                        viewModel.zoomScale = max(0.5, min(5.0, value))
                    }
            )
            .highPriorityGesture(
                DragGesture()
                    .modifiers(.option)  // Option+drag to pan
                    .onChanged { value in
                        viewModel.panOffset = CGSize(
                            width: viewModel.panBase.width + value.translation.width,
                            height: viewModel.panBase.height + value.translation.height
                        )
                    }
                    .onEnded { value in
                        viewModel.panBase = viewModel.panOffset
                    }
            )
        }
        .overlay(alignment: .bottomTrailing) {
            zoomControls
        }
        .overlay(alignment: .bottomLeading) {
            toggleOriginalButton
        }
    }
    
    @ViewBuilder
    private func segmentationOverlays(size: CGSize) -> some View {
        // Hide all overlays when showing original image for comparison
        if !viewModel.showingOriginal {
            // Show selected masks from non-active (completed) segmentations with their unique neon color
            ForEach(Array(viewModel.segmentations.enumerated()), id: \.element.id) { segIndex, entry in
                if segIndex != viewModel.activeSegmentationIndex, let selectedMask = entry.selectedMask {
                    let color = viewModel.colorForSegmentation(segIndex)

                    // Semi-transparent fill to allow seeing underlying image details for edge verification
                    MaskOverlayView(
                        mask: selectedMask,
                        color: color,
                        size: size,
                        opacity: 0.5,
                        showBorder: true
                    )
                    .transition(.opacity.combined(with: .scale(scale: 0.98)))
                }
            }

            // Active segmentation - show all masks with selection
            if viewModel.activeSegmentationIndex < viewModel.segmentations.count {
                let activeEntry = viewModel.segmentations[viewModel.activeSegmentationIndex]
                let activeColor = viewModel.colorForSegmentation(viewModel.activeSegmentationIndex)

                // Non-selected masks in active segmentation (dimmer, for region selection)
                ForEach(Array(activeEntry.allMasks.enumerated()).filter { !activeEntry.selectedMaskIndices.contains($0.offset) }, id: \.offset) { index, maskData in
                    let color = viewModel.colorForMask(index)
                    MaskOverlayView(
                        mask: maskData.image,
                        color: color,
                        size: size,
                        opacity: 0.4,
                        showBorder: false
                    )
                    .transition(.opacity.animation(.easeOut(duration: 0.25)))
                }

                // All selected masks in active segmentation - semi-transparent for edge verification
                ForEach(Array(activeEntry.selectedMaskIndices.sorted()), id: \.self) { maskIndex in
                    if maskIndex < activeEntry.allMasks.count {
                        let maskData = activeEntry.allMasks[maskIndex]

                        MaskOverlayView(
                            mask: maskData.image,
                            color: activeColor,
                            size: size,
                            opacity: 0.5,
                            showBorder: true
                        )
                        .transition(.asymmetric(
                            insertion: .opacity.combined(with: .scale(scale: 0.95)).animation(.spring(response: 0.35, dampingFraction: 0.8)),
                            removal: .opacity.animation(.easeOut(duration: 0.2))
                        ))
                    }
                }

                // Bounding box overlay for active segmentation
                if let box = activeEntry.boundingBox {
                    BoundingBoxOverlay(
                        boxes: [box],
                        currentBox: nil,
                        displayedSize: size,
                        imagePixelSize: viewModel.imagePixelSize
                    )
                }

                // Current drawing box overlay
                if let currentBox = viewModel.currentDrawingBox {
                    BoundingBoxOverlay(
                        boxes: [],
                        currentBox: currentBox,
                        displayedSize: size,
                        imagePixelSize: viewModel.imagePixelSize
                    )
                }
            }
        }
    }
}

// MARK: - Mask Overlay View (animated)

private struct MaskOverlayView: View {
    let mask: NSImage
    let color: Color
    let size: CGSize
    let opacity: Double
    let showBorder: Bool

    @State private var isVisible = false

    var body: some View {
        // Single masked view with optional stroke effect via overlay
        // This avoids creating duplicate mask views for the border
        Image(nsImage: mask)
            .resizable()
            .frame(width: size.width, height: size.height)
            .colorMultiply(color)
            .opacity(isVisible ? opacity : 0)
            .overlay {
                // Border effect using stroke-style rendering
                if showBorder {
                    Image(nsImage: mask)
                        .resizable()
                        .frame(width: size.width, height: size.height)
                        .colorMultiply(color)
                        .blur(radius: 2)
                        .opacity(isVisible ? 0.6 : 0)
                }
            }
            .allowsHitTesting(false)
            .onAppear {
                withAnimation(.easeOut(duration: 0.3)) {
                    isVisible = true
                }
            }
    }
}

// MARK: - ImageCanvas Extensions

extension ImageCanvas {
    @ViewBuilder
    func touchupOverlays(size: CGSize) -> some View {
        if let maskImage = viewModel.editableMaskImage, !viewModel.showingOriginal {
            // Use same color as active segmentation for consistency
            let maskColor = viewModel.colorForSegmentation(viewModel.activeSegmentationIndex)

            MaskOverlayView(
                mask: maskImage,
                color: maskColor,
                size: size,
                opacity: 0.5,
                showBorder: true
            )

            // Current stroke overlay (live preview while drawing)
            if let currentStroke = viewModel.currentStroke {
                PaintStrokeOverlay(
                    strokes: [],
                    currentStroke: currentStroke,
                    displayedSize: size
                )
                .allowsHitTesting(false)
            }

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
        } else if viewModel.editableMaskImage == nil && !viewModel.showingOriginal {
            // Show subtle loading indicator while mask is being merged
            ProgressView()
                .scaleEffect(0.8)
                .frame(width: size.width, height: size.height)
                .background(Color.black.opacity(0.1))
                .transition(.opacity.animation(.easeOut(duration: 0.15)))
        }
    }

    @ViewBuilder
    var zoomControls: some View {
        let isPanned = viewModel.panOffset != .zero
        let isZoomed = viewModel.zoomScale != 1.0

        if isZoomed || isPanned {
            Button(action: {
                withAnimation(.easeOut(duration: 0.2)) {
                    viewModel.zoomScale = 1.0
                    viewModel.panOffset = .zero
                    viewModel.panBase = .zero
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


    /// Check if compare button should be shown (segment with masks or touchup with mask)
    private var shouldShowCompareButton: Bool {
        if viewModel.currentStep == .touchup && viewModel.editableMaskImage != nil {
            return true
        }
        if viewModel.currentStep == .segment && viewModel.totalValidMasks > 0 {
            return true
        }
        return false
    }

    @ViewBuilder
    var toggleOriginalButton: some View {
        if shouldShowCompareButton {
            Button(action: {}) {
                HStack(spacing: AppDesign.Spacing.p6) {
                    Image(systemName: viewModel.showingOriginal ? "eye.slash" : "eye")
                        .font(.system(size: AppDesign.FontSize.caption))
                    Text(viewModel.showingOriginal ? "Showing Original" : "Hold to Compare")
                        .font(.system(size: AppDesign.FontSize.caption, weight: .medium))
                }
                .padding(.horizontal, AppDesign.Spacing.p12)
                .padding(.vertical, AppDesign.Spacing.p6)
                .background(viewModel.showingOriginal ? AnyShapeStyle(AppDesign.accent.opacity(0.2)) : AnyShapeStyle(.ultraThinMaterial))
                .clipShape(Capsule())
                .overlay(
                    Capsule()
                        .stroke(viewModel.showingOriginal ? AppDesign.accent : Color.white.opacity(0.1), lineWidth: 1)
                )
            }
            .buttonStyle(.plain)
            .simultaneousGesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        if !viewModel.showingOriginal {
                            viewModel.showingOriginal = true
                        }
                    }
                    .onEnded { _ in
                        viewModel.showingOriginal = false
                    }
            )
            .padding(AppDesign.Spacing.p24)
            .transition(.scale.combined(with: .opacity))
        }
    }

    @ViewBuilder
    private var postProcessLoadingView: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(NSColor(calibratedWhite: 0.1, alpha: 1.0)))
                .shadow(color: .black.opacity(0.3), radius: 20, y: 10)

            VStack(spacing: AppDesign.Spacing.p16) {
                ProgressView()
                    .scaleEffect(1.2)
                Text("Preparing 3D view...")
                    .font(.system(size: AppDesign.FontSize.body))
                    .foregroundColor(.secondary)
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.white.opacity(0.1), lineWidth: 1)
        )
    }

    @ViewBuilder
    var dropZoneView: some View {
        GeometryReader { geo in
            let isCompact = geo.size.width < 400 || geo.size.height < 350
            let iconSize: CGFloat = isCompact ? 60 : 100
            let imageSize: CGFloat = isCompact ? 28 : 40
            let borderPadding: CGFloat = isCompact ? AppDesign.Spacing.p16 : AppDesign.Spacing.p48

            VStack(spacing: isCompact ? AppDesign.Spacing.p16 : AppDesign.Spacing.p24) {
                ZStack {
                    Circle()
                        .fill(.ultraThinMaterial)
                        .frame(width: iconSize, height: iconSize)
                        .overlay(Circle().stroke(Color.primary.opacity(0.1), lineWidth: 1))

                    Image(systemName: "square.and.arrow.down")
                        .font(.system(size: imageSize, weight: .light))
                        .foregroundColor(.accentColor)
                }
                .shadow(color: .black.opacity(0.1), radius: isCompact ? 10 : 20)

                VStack(spacing: AppDesign.Spacing.p8) {
                    Text("Ready for Creation")
                        .font(.system(size: isCompact ? AppDesign.FontSize.headline : AppDesign.FontSize.title3, weight: .bold))

                    Text(isCompact ? "Drop image or click to browse" : "Drag and drop an image here or click to browse")
                        .font(.system(size: isCompact ? AppDesign.FontSize.caption : AppDesign.FontSize.body))
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                }

                AppDesign.GlassButton("Select Image", icon: "photo") {
                    selectImage()
                }
                .controlSize(isCompact ? .regular : .large)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(
                RoundedRectangle(cornerRadius: isCompact ? 16 : 24)
                    .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [8, 4]))
                    .foregroundColor(.primary.opacity(0.1))
                    .padding(borderPadding)
            )
        }
    }
    
    // MARK: - Actions
    func selectImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image, .png, .jpeg, .tiff, .bmp, .gif, .webP]
        panel.allowsMultipleSelection = false

        if panel.runModal() == .OK, let url = panel.url {
            viewModel.loadImage(from: url)
        }
    }

    func handleDrop(providers: [NSItemProvider]) -> Bool {
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
