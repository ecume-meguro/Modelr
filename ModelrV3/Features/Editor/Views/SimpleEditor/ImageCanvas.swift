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
            
            if viewModel.inputImage != nil && viewModel.currentStep != .postProcess && !(viewModel.currentStep == .generate && viewModel.generated3DModelURL != nil) {
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
            if viewModel.currentStep == .setup {
                setupCanvasContent
            } else if viewModel.currentStep == .postProcess {
                if !viewModel.componentFiles.isEmpty {
                    // Use component viewer for highlighting when multiple components
                    ComponentModelViewerContainer(
                        componentFiles: viewModel.componentFiles.map {
                            ComponentModelViewer.ComponentFile(index: $0.index, path: $0.path)
                        },
                        selectedIndices: viewModel.selectedComponentIndices
                    )
                    .id(viewModel.componentFiles.count) // Refresh when components change
                    .padding(AppDesign.Spacing.p24)
                } else if let modelURL = viewModel.currentMeshURL {
                    // Fallback to regular viewer for single component
                    ModelViewerContainer(modelURL: modelURL, viewMode: viewModel.viewMode)
                        .id("\(modelURL)-\(viewModel.viewMode)")
                        .padding(AppDesign.Spacing.p24)
                }
            } else if viewModel.currentStep == .generate, let modelURL = viewModel.generated3DModelURL {
                ModelViewerContainer(modelURL: modelURL, viewMode: viewModel.viewMode)
                    .id("\(modelURL)-\(viewModel.viewMode)")
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

    // MARK: - Setup Canvas Content

    @ViewBuilder
    private var setupCanvasContent: some View {
        if viewModel.currentSetupSubStep == .chooseModel && !viewModel.setupSubStepCompleted.contains(.chooseModel) {
            modelSelectorView
                .onAppear {
                    // Start environment configuration in background while user chooses model
                    viewModel.startBackgroundEnvironmentSetup()
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
                    VStack(spacing: AppDesign.Spacing.p12) {
                        Text("Modelr")
                            .font(.system(size: titleSize, weight: .bold))
                            .tracking(-2)
                            .foregroundStyle(.primary)

                        if !isCompact {
                            Text("Professional Image to 3D Workflow")
                                .font(.system(size: AppDesign.FontSize.title3, weight: .medium))
                                .foregroundStyle(.secondary)
                        }
                    }

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

                        // Model info (hide on compact)
                        if !isCompact {
                            VStack(spacing: AppDesign.Spacing.p4) {
                                HStack(spacing: AppDesign.Spacing.p32) {
                                    Text("Small, Fast → \(SetupModelChoice.fast.modelName)")
                                    Text("Large, Higher Quality → \(SetupModelChoice.quality.modelName)")
                                }
                                .font(.system(size: AppDesign.FontSize.xs, design: .monospaced))
                                .foregroundStyle(.tertiary)
                            }
                            .padding(.top, AppDesign.Spacing.p8)
                        }
                    }

                    // CTA
                    VStack(spacing: AppDesign.Spacing.p16) {
                        AppDesign.GlassButton("Get Started", icon: "arrow.right") {
                            viewModel.startSetup()
                        }
                        .controlSize(isCompact ? .regular : .large)

                        HStack(spacing: AppDesign.Spacing.p8) {
                            Image(systemName: "info.circle.fill")
                                .font(.system(size: AppDesign.FontSize.caption))
                            Text("Requires ~10 GB for initial download")
                                .font(.system(size: AppDesign.FontSize.caption, weight: .medium))
                        }
                        .foregroundStyle(.tertiary)
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
            VStack(spacing: isCompact ? AppDesign.Spacing.p8 : AppDesign.Spacing.p12) {
                HStack {
                    if isRecommended {
                        Text("Recommended")
                            .font(.system(size: AppDesign.FontSize.xs, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(AppDesign.accent, in: Capsule())
                    }
                    Spacer()
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: isCompact ? AppDesign.FontSize.body : AppDesign.FontSize.title3))
                        .foregroundStyle(isSelected ? AppDesign.accent : .secondary.opacity(0.5))
                }

                VStack(spacing: AppDesign.Spacing.p4) {
                    Text(choice.displayName)
                        .font(.system(size: isCompact ? AppDesign.FontSize.subheadline : AppDesign.FontSize.headline, weight: .semibold))
                        .foregroundStyle(.primary)

                    Text(choice.downloadSize)
                        .font(.system(size: AppDesign.FontSize.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(isCompact ? AppDesign.Spacing.p12 : AppDesign.Spacing.p16)
            .frame(maxWidth: isCompact ? .infinity : 180)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(isSelected ? AppDesign.accent.opacity(0.1) : Color.primary.opacity(0.03))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(isSelected ? AppDesign.accent : Color.primary.opacity(0.1), lineWidth: isSelected ? 2 : 1)
            )
        }
        .buttonStyle(.plain)
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
        .overlay(alignment: .bottomLeading) {
            toggleOriginalButton
        }
    }
    
    @ViewBuilder
    private func segmentationOverlays(size: CGSize) -> some View {
        // Show selected masks from non-active (completed) segmentations with their unique neon color
        ForEach(Array(viewModel.segmentations.enumerated()), id: \.element.id) { segIndex, entry in
            if segIndex != viewModel.activeSegmentationIndex, let selectedMask = entry.selectedMask {
                let color = viewModel.colorForSegmentation(segIndex)

                // Strong fill with 90% opacity
                Rectangle()
                    .fill(color)
                    .frame(width: size.width, height: size.height)
                    .mask(
                        Image(nsImage: selectedMask)
                            .resizable()
                            .frame(width: size.width, height: size.height)
                    )
                    .opacity(0.9)
                    .allowsHitTesting(false)

                // 100% border
                Rectangle()
                    .fill(color)
                    .frame(width: size.width, height: size.height)
                    .mask(
                        ZStack {
                            Image(nsImage: selectedMask)
                                .resizable()
                                .frame(width: size.width, height: size.height)
                            Image(nsImage: selectedMask)
                                .resizable()
                                .frame(width: size.width, height: size.height)
                                .padding(4)
                                .blur(radius: 1)
                                .blendMode(.destinationOut)
                        }
                        .compositingGroup()
                    )
                    .opacity(1.0)
                    .allowsHitTesting(false)
            }
        }

        // Active segmentation - show all masks with selection
        if viewModel.activeSegmentationIndex < viewModel.segmentations.count {
            let activeEntry = viewModel.segmentations[viewModel.activeSegmentationIndex]
            let activeColor = viewModel.colorForSegmentation(viewModel.activeSegmentationIndex)

            // Non-selected masks in active segmentation (dimmer, for region selection)
            ForEach(Array(activeEntry.allMasks.enumerated()).filter { !activeEntry.selectedMaskIndices.contains($0.offset) }, id: \.offset) { index, maskData in
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

            // All selected masks in active segmentation - use segmentation's neon color with 90% opacity
            ForEach(Array(activeEntry.selectedMaskIndices.sorted()), id: \.self) { maskIndex in
                if maskIndex < activeEntry.allMasks.count {
                    let maskData = activeEntry.allMasks[maskIndex]

                    Rectangle()
                        .fill(activeColor)
                        .frame(width: size.width, height: size.height)
                        .mask(
                            Image(nsImage: maskData.image)
                                .resizable()
                                .frame(width: size.width, height: size.height)
                        )
                        .opacity(0.9)
                        .allowsHitTesting(false)

                    // 100% border
                    Rectangle()
                        .fill(activeColor)
                        .frame(width: size.width, height: size.height)
                        .mask(
                            ZStack {
                                Image(nsImage: maskData.image)
                                    .resizable()
                                    .frame(width: size.width, height: size.height)
                                Image(nsImage: maskData.image)
                                    .resizable()
                                    .frame(width: size.width, height: size.height)
                                    .padding(4)
                                    .blur(radius: 1)
                                    .blendMode(.destinationOut)
                            }
                            .compositingGroup()
                        )
                        .opacity(1.0)
                        .allowsHitTesting(false)
                }
            }

            // Points overlay for active segmentation
            ForEach(activeEntry.points) { point in
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
    }
    
    @ViewBuilder
    private func touchupOverlays(size: CGSize) -> some View {
        if let maskImage = viewModel.editableMaskImage, !viewModel.showingOriginal {
            // Use first neon color for merged mask with 90% opacity
            let maskColor = AppDesign.neonColors[0]

            Rectangle()
                .fill(maskColor)
                .frame(width: size.width, height: size.height)
                .mask(
                    Image(nsImage: maskImage)
                        .resizable()
                        .frame(width: size.width, height: size.height)
                )
                .opacity(0.9)
                .allowsHitTesting(false)

            // 100% border for the mask
            Rectangle()
                .fill(maskColor)
                .frame(width: size.width, height: size.height)
                .mask(
                    ZStack {
                        Image(nsImage: maskImage)
                            .resizable()
                            .frame(width: size.width, height: size.height)
                        Image(nsImage: maskImage)
                            .resizable()
                            .frame(width: size.width, height: size.height)
                            .padding(4)
                            .blur(radius: 1)
                            .blendMode(.destinationOut)
                    }
                    .compositingGroup()
                )
                .opacity(1.0)
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
    private var toggleOriginalButton: some View {
        if viewModel.currentStep == .touchup && viewModel.editableMaskImage != nil {
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
    private var dropZoneView: some View {
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
