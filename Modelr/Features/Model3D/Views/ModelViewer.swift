import SwiftUI
import SceneKit
import ModelIO
import SceneKit.ModelIO

// MARK: - SceneKit 3D Viewer (Headlamp Lighting)

/// A robust 3D viewer that uses a camera-attached light ("Headlamp")
/// to ensure the model is always visible from the user's angle.
struct ModelViewer: NSViewRepresentable {
    let modelURL: URL?
    var viewMode: SimpleEditorViewModel.ViewMode = .shaded
    var displayMode: SimpleEditorViewModel.MeshDisplayMode = .solid
    var materialType: SimpleEditorViewModel.MaterialType = .matte
    var customColor: NSColor? = nil

    func makeNSView(context: Context) -> SCNView {
        let scnView = SCNView()

        // 1. Basic Setup
        scnView.allowsCameraControl = true
        scnView.autoenablesDefaultLighting = false
        scnView.backgroundColor = NSColor(calibratedWhite: 0.12, alpha: 1.0)
        scnView.antialiasingMode = .multisampling4X

        // GPU acceleration settings
        scnView.preferredFramesPerSecond = 60
        scnView.rendersContinuously = false  // Only render when needed (saves GPU)
        scnView.isJitteringEnabled = true    // Temporal anti-aliasing for smoother edges

        // 2. Scene Setup
        let scene = SCNScene()
        scnView.scene = scene

        // 3. Camera & Headlamp Setup
        setupCameraAndLighting(scene: scene, view: scnView)

        // 4. Load Model
        if let url = modelURL {
            context.coordinator.loadModel(url: url, into: scene, view: scnView, viewMode: viewMode, displayMode: displayMode, materialType: materialType, customColor: customColor)
        }

        return scnView
    }

    func updateNSView(_ scnView: SCNView, context: Context) {
        // Update view mode, display mode, material type, and custom color
        context.coordinator.applyViewMode(viewMode, displayMode: displayMode, materialType: materialType, customColor: customColor, to: scnView)

        if let url = modelURL, context.coordinator.currentModelURL != url {
            if let scene = scnView.scene {
                // Remove old model
                scene.rootNode.childNode(withName: "loadedModel", recursively: true)?.removeFromParentNode()
                // Load new
                context.coordinator.loadModel(url: url, into: scene, view: scnView, viewMode: viewMode, displayMode: displayMode, materialType: materialType, customColor: customColor)
            }
        } else if context.coordinator.currentCustomColor != customColor || context.coordinator.currentMaterialType != materialType {
            // Color or material changed, update materials
            context.coordinator.applyViewMode(viewMode, displayMode: displayMode, materialType: materialType, customColor: customColor, to: scnView)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    private func setupCameraAndLighting(scene: SCNScene, view: SCNView) {
        // Create a dedicated camera node
        let cameraNode = SCNNode()
        cameraNode.name = "cameraNode"
        cameraNode.camera = SCNCamera()
        cameraNode.camera?.zNear = 0.01
        cameraNode.camera?.zFar = 1000
        cameraNode.position = SCNVector3(0, 0, 2)

        // Add Camera to Scene
        scene.rootNode.addChildNode(cameraNode)
        view.pointOfView = cameraNode

        // --- EVEN STUDIO LIGHTING (3-point + ambient) ---

        // 1. Key Light - Front-left, moderate intensity
        let keyLight = SCNNode()
        keyLight.light = SCNLight()
        keyLight.light?.type = .directional
        keyLight.light?.intensity = 400
        keyLight.light?.color = NSColor(white: 0.95, alpha: 1.0)
        keyLight.light?.castsShadow = false
        keyLight.position = SCNVector3(-2, 2, 2)
        keyLight.look(at: SCNVector3(0, 0, 0))
        scene.rootNode.addChildNode(keyLight)

        // 2. Fill Light - Front-right, softer
        let fillLight = SCNNode()
        fillLight.light = SCNLight()
        fillLight.light?.type = .directional
        fillLight.light?.intensity = 350
        fillLight.light?.color = NSColor(white: 0.9, alpha: 1.0)
        fillLight.light?.castsShadow = false
        fillLight.position = SCNVector3(2, 1, 2)
        fillLight.look(at: SCNVector3(0, 0, 0))
        scene.rootNode.addChildNode(fillLight)

        // 3. Back Light - Behind, for rim/separation
        let backLight = SCNNode()
        backLight.light = SCNLight()
        backLight.light?.type = .directional
        backLight.light?.intensity = 250
        backLight.light?.color = NSColor(white: 0.85, alpha: 1.0)
        backLight.light?.castsShadow = false
        backLight.position = SCNVector3(0, 1, -2)
        backLight.look(at: SCNVector3(0, 0, 0))
        scene.rootNode.addChildNode(backLight)

        // 4. Top Light - From above for even coverage
        let topLight = SCNNode()
        topLight.light = SCNLight()
        topLight.light?.type = .directional
        topLight.light?.intensity = 200
        topLight.light?.color = NSColor(white: 0.9, alpha: 1.0)
        topLight.light?.castsShadow = false
        topLight.position = SCNVector3(0, 3, 0)
        topLight.look(at: SCNVector3(0, 0, 0))
        scene.rootNode.addChildNode(topLight)

        // 5. Ambient Light - Base fill for all surfaces
        let ambientLight = SCNNode()
        ambientLight.light = SCNLight()
        ambientLight.light?.type = .ambient
        ambientLight.light?.intensity = 400
        ambientLight.light?.color = NSColor(white: 0.7, alpha: 1.0)
        scene.rootNode.addChildNode(ambientLight)

        // 6. Environment for subtle reflections
        scene.lightingEnvironment.contents = NSColor(white: 0.4, alpha: 1.0)
        scene.lightingEnvironment.intensity = 0.5
    }

    class Coordinator {
        var currentModelURL: URL?
        var currentViewMode: SimpleEditorViewModel.ViewMode = .shaded
        var currentDisplayMode: SimpleEditorViewModel.MeshDisplayMode = .solid
        var currentMaterialType: SimpleEditorViewModel.MaterialType = .matte
        var currentCustomColor: NSColor? = nil

        func loadModel(url: URL, into scene: SCNScene, view: SCNView, viewMode: SimpleEditorViewModel.ViewMode, displayMode: SimpleEditorViewModel.MeshDisplayMode, materialType: SimpleEditorViewModel.MaterialType, customColor: NSColor? = nil) {
            currentModelURL = url
            currentViewMode = viewMode
            currentDisplayMode = displayMode
            currentMaterialType = materialType
            currentCustomColor = customColor

            DispatchQueue.global(qos: .userInitiated).async {
                let asset = MDLAsset(url: url)
                asset.loadTextures()

                guard asset.count > 0 else { return }

                let loadedScene = SCNScene(mdlAsset: asset)

                DispatchQueue.main.async {
                    let containerNode = SCNNode()
                    containerNode.name = "loadedModel"

                    for child in loadedScene.rootNode.childNodes {
                        let cloned = child.clone()
                        self.fixMaterials(node: cloned, viewMode: viewMode, displayMode: displayMode, materialType: materialType, customColor: customColor)
                        containerNode.addChildNode(cloned)
                    }

                    scene.rootNode.addChildNode(containerNode)

                    // Center and Scale
                    let (min, max) = containerNode.boundingBox
                    let size = SCNVector3(max.x - min.x, max.y - min.y, max.z - min.z)
                    let maxDim = Swift.max(size.x, Swift.max(size.y, size.z))

                    if maxDim > 0 {
                        let scale = 1.5 / maxDim
                        containerNode.scale = SCNVector3(scale, scale, scale)

                        let center = SCNVector3((min.x + max.x) / 2, (min.y + max.y) / 2, (min.z + max.z) / 2)
                        containerNode.pivot = SCNMatrix4MakeTranslation(center.x, center.y, center.z)
                        containerNode.position = SCNVector3(0, 0, 0)
                    }
                }
            }
        }

        func applyViewMode(_ viewMode: SimpleEditorViewModel.ViewMode, displayMode: SimpleEditorViewModel.MeshDisplayMode, materialType: SimpleEditorViewModel.MaterialType, customColor: NSColor? = nil, to scnView: SCNView) {
            let viewModeChanged = viewMode != currentViewMode
            let displayModeChanged = displayMode != currentDisplayMode
            let materialChanged = materialType != currentMaterialType
            let colorChanged = customColor != currentCustomColor

            guard viewModeChanged || displayModeChanged || materialChanged || colorChanged else { return }

            currentViewMode = viewMode
            currentDisplayMode = displayMode
            currentMaterialType = materialType
            currentCustomColor = customColor

            guard let scene = scnView.scene,
                  let modelNode = scene.rootNode.childNode(withName: "loadedModel", recursively: true) else { return }

            applyViewModeToNode(modelNode, viewMode: viewMode, displayMode: displayMode, materialType: materialType, customColor: customColor)
        }

        private func applyViewModeToNode(_ node: SCNNode, viewMode: SimpleEditorViewModel.ViewMode, displayMode: SimpleEditorViewModel.MeshDisplayMode, materialType: SimpleEditorViewModel.MaterialType, customColor: NSColor?) {
            if let geometry = node.geometry {
                for material in geometry.materials {
                    // Apply display mode (solid/wireframe)
                    switch displayMode {
                    case .solid:
                        material.fillMode = .fill
                    case .wireframe:
                        material.fillMode = .lines
                    }

                    // Apply material properties (roughness, metalness, transparency)
                    material.roughness.contents = materialType.roughness
                    material.metalness.contents = materialType.metalness
                    material.transparency = materialType.transparency

                    // Apply view mode and color
                    switch viewMode {
                    case .wireframe:
                        material.diffuse.contents = NSColor.white
                    case .shaded:
                        // Use custom color if provided, otherwise use default gray
                        material.diffuse.contents = customColor ?? NSColor(white: 0.7, alpha: 1.0)
                    case .textured:
                        // Keep textures as loaded (don't apply custom color in textured mode)
                        break
                    }
                }
            }

            for child in node.childNodes {
                applyViewModeToNode(child, viewMode: viewMode, displayMode: displayMode, materialType: materialType, customColor: customColor)
            }
        }

        func fixMaterials(node: SCNNode, viewMode: SimpleEditorViewModel.ViewMode, displayMode: SimpleEditorViewModel.MeshDisplayMode, materialType: SimpleEditorViewModel.MaterialType, customColor: NSColor? = nil) {
            node.geometry?.materials.forEach { material in
                material.isDoubleSided = true

                if material.lightingModel == .constant {
                    material.lightingModel = .physicallyBased
                }

                // Apply display mode (solid/wireframe)
                switch displayMode {
                case .solid:
                    material.fillMode = .fill
                case .wireframe:
                    material.fillMode = .lines
                }

                // Apply material properties (roughness, metalness, transparency)
                material.roughness.contents = materialType.roughness
                material.metalness.contents = materialType.metalness
                material.transparency = materialType.transparency

                // Apply view mode and custom color
                switch viewMode {
                case .wireframe:
                    material.diffuse.contents = NSColor.white
                case .shaded:
                    material.diffuse.contents = customColor ?? NSColor(white: 0.7, alpha: 1.0)
                case .textured:
                    // Keep textures as loaded
                    break
                }
            }

            for child in node.childNodes {
                fixMaterials(node: child, viewMode: viewMode, displayMode: displayMode, materialType: materialType, customColor: customColor)
            }
        }
    }
}

/// A styled container for the model viewer
struct ModelViewerContainer: View {
    let modelURL: URL?
    var viewMode: SimpleEditorViewModel.ViewMode = .shaded
    @Binding var displayMode: SimpleEditorViewModel.MeshDisplayMode
    @Binding var materialType: SimpleEditorViewModel.MaterialType
    @Binding var customColor: NSColor?
    var sourceImage: NSImage? = nil

    @State private var showColorPicker = false
    @State private var showMaterialPicker = false
    @State private var extractedColors: [NSColor] = []

    var body: some View {
        ZStack {
            // Background
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(NSColor(calibratedWhite: 0.1, alpha: 1.0)))
                .shadow(color: .black.opacity(0.3), radius: 20, y: 10)

            if let url = modelURL {
                ModelViewer(modelURL: url, viewMode: viewMode, displayMode: displayMode, materialType: materialType, customColor: customColor)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))

                // Bottom-left controls (solid/wire/paint)
                VStack {
                    Spacer()
                    HStack {
                        viewerControls
                        Spacer()
                    }
                }
                .padding(AppDesign.Spacing.p12)
            } else {
                VStack(spacing: AppDesign.Spacing.p12) {
                    Image(systemName: "cube.transparent")
                        .font(.system(size: 40, weight: .light))
                        .foregroundColor(.secondary)
                    Text("Preparing 3D View...")
                        .font(.system(size: AppDesign.FontSize.body))
                        .foregroundColor(.secondary)
                }
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.white.opacity(0.1), lineWidth: 1)
        )
        .onAppear {
            if let image = sourceImage {
                extractColorsFromImage(image)
            }
        }
    }

    // MARK: - Viewer Controls

    @ViewBuilder
    private var viewerControls: some View {
        VStack(spacing: 6) {
            // Solid/Wire toggle
            ForEach(SimpleEditorViewModel.MeshDisplayMode.allCases, id: \.self) { mode in
                controlButton(
                    icon: mode == .solid ? "cube.fill" : "cube",
                    label: mode == .solid ? "Solid" : "Wire",
                    isSelected: displayMode == mode
                ) {
                    withAnimation(.easeOut(duration: 0.15)) {
                        displayMode = mode
                    }
                }
            }

            Divider()
                .frame(width: 32)
                .background(Color.white.opacity(0.2))
                .padding(.vertical, 2)

            // Paint button
            controlButton(
                icon: customColor != nil ? "paintbrush.fill" : "paintbrush",
                label: "Paint",
                isSelected: customColor != nil || showColorPicker,
                tint: customColor.map { Color(nsColor: $0) }
            ) {
                showColorPicker.toggle()
            }
            .popover(isPresented: $showColorPicker, arrowEdge: .trailing) {
                colorPickerPopover
            }

            Divider()
                .frame(width: 32)
                .background(Color.white.opacity(0.2))
                .padding(.vertical, 2)

            // Material button
            controlButton(
                icon: materialType.icon,
                label: "Material",
                isSelected: showMaterialPicker
            ) {
                showMaterialPicker.toggle()
            }
            .popover(isPresented: $showMaterialPicker, arrowEdge: .trailing) {
                materialPickerPopover
            }
        }
        .padding(8)
        .background(.ultraThinMaterial.opacity(0.9))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color.white.opacity(0.15), lineWidth: 1)
        )
    }

    @ViewBuilder
    private func controlButton(
        icon: String,
        label: String,
        isSelected: Bool,
        tint: Color? = nil,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(spacing: 2) {
                Image(systemName: icon)
                    .font(.system(size: 14, weight: isSelected ? .semibold : .regular))
                Text(label)
                    .font(.system(size: 9, weight: isSelected ? .semibold : .regular))
            }
            .foregroundStyle(tint ?? (isSelected ? .white : .white.opacity(0.7)))
            .frame(width: 44, height: 40)
            .background(
                isSelected ? Color.white.opacity(0.2) : Color.clear,
                in: RoundedRectangle(cornerRadius: 6)
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Color Picker

    @ViewBuilder
    private var colorPickerPopover: some View {
        VStack(alignment: .leading, spacing: AppDesign.Spacing.p12) {
            Text("Model Color")
                .font(.system(size: AppDesign.FontSize.caption, weight: .semibold))
                .foregroundStyle(.secondary)

            // Extracted colors from image (if available)
            if !extractedColors.isEmpty {
                VStack(alignment: .leading, spacing: AppDesign.Spacing.p6) {
                    Text("From Image")
                        .font(.system(size: AppDesign.FontSize.xs, weight: .medium))
                        .foregroundStyle(.tertiary)
                        .textCase(.uppercase)

                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 28))], spacing: 8) {
                        ForEach(extractedColors, id: \.self) { color in
                            Button {
                                customColor = color
                                showColorPicker = false
                            } label: {
                                Circle()
                                    .fill(Color(nsColor: color))
                                    .frame(width: 28, height: 28)
                                    .overlay(
                                        Circle()
                                            .strokeBorder(
                                                customColor == color ? Color.white : Color.clear,
                                                lineWidth: 2
                                            )
                                    )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                Divider()
            }

            // Preset colors
            VStack(alignment: .leading, spacing: AppDesign.Spacing.p6) {
                Text("Presets")
                    .font(.system(size: AppDesign.FontSize.xs, weight: .medium))
                    .foregroundStyle(.tertiary)
                    .textCase(.uppercase)

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 28))], spacing: 8) {
                    // Reset to default
                    Button {
                        customColor = nil
                        showColorPicker = false
                    } label: {
                        ZStack {
                            Circle()
                                .fill(Color(white: 0.7))
                                .frame(width: 28, height: 28)
                            if customColor == nil {
                                Circle()
                                    .strokeBorder(Color.white, lineWidth: 2)
                                    .frame(width: 28, height: 28)
                            }
                            Text("×")
                                .font(.system(size: 14, weight: .bold))
                                .foregroundStyle(.white.opacity(0.5))
                        }
                    }
                    .buttonStyle(.plain)
                    .help("Default (Gray)")

                    ForEach(presetColors, id: \.self) { color in
                        Button {
                            customColor = color
                            showColorPicker = false
                        } label: {
                            Circle()
                                .fill(Color(nsColor: color))
                                .frame(width: 28, height: 28)
                                .overlay(
                                    Circle()
                                        .strokeBorder(
                                            customColor == color ? Color.white : Color.clear,
                                            lineWidth: 2
                                        )
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .padding(AppDesign.Spacing.p12)
        .frame(width: 180)
    }

    // MARK: - Material Picker

    @ViewBuilder
    private var materialPickerPopover: some View {
        VStack(alignment: .leading, spacing: AppDesign.Spacing.p12) {
            Text("Material Type")
                .font(.system(size: AppDesign.FontSize.caption, weight: .semibold))
                .foregroundStyle(.secondary)

            VStack(spacing: AppDesign.Spacing.p8) {
                ForEach(SimpleEditorViewModel.MaterialType.allCases) { type in
                    Button {
                        materialType = type
                        showMaterialPicker = false
                    } label: {
                        HStack(spacing: AppDesign.Spacing.p10) {
                            Image(systemName: type.icon)
                                .font(.system(size: 16))
                                .frame(width: 20)
                                .foregroundStyle(materialType == type ? .white : .white.opacity(0.7))

                            VStack(alignment: .leading, spacing: 2) {
                                Text(type.rawValue)
                                    .font(.system(size: AppDesign.FontSize.body, weight: materialType == type ? .semibold : .regular))
                                    .foregroundStyle(materialType == type ? .white : .white.opacity(0.9))

                                Text(materialDescription(for: type))
                                    .font(.system(size: AppDesign.FontSize.xs))
                                    .foregroundStyle(.white.opacity(0.6))
                            }

                            Spacer()

                            if materialType == type {
                                Image(systemName: "checkmark.circle.fill")
                                    .font(.system(size: 16))
                                    .foregroundStyle(.white)
                            }
                        }
                        .padding(AppDesign.Spacing.p8)
                        .background(
                            materialType == type ? Color.white.opacity(0.15) : Color.clear,
                            in: RoundedRectangle(cornerRadius: 6)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(AppDesign.Spacing.p12)
        .frame(width: 220)
    }

    private func materialDescription(for type: SimpleEditorViewModel.MaterialType) -> String {
        switch type {
        case .matte: return "Soft diffuse finish"
        case .glossy: return "Smooth shiny finish"
        case .metallic: return "Reflective metal surface"
        }
    }

    private var presetColors: [NSColor] {
        [
            NSColor(red: 0.0, green: 0.5, blue: 1.0, alpha: 1.0),  // Blue
            NSColor(red: 1.0, green: 0.2, blue: 0.2, alpha: 1.0),  // Red
            NSColor(red: 0.2, green: 0.8, blue: 0.2, alpha: 1.0),  // Green
            NSColor(red: 1.0, green: 0.8, blue: 0.0, alpha: 1.0),  // Yellow
            NSColor(red: 1.0, green: 0.4, blue: 0.0, alpha: 1.0),  // Orange
            NSColor(red: 0.7, green: 0.3, blue: 1.0, alpha: 1.0),  // Purple
            NSColor(red: 1.0, green: 0.4, blue: 0.7, alpha: 1.0),  // Pink
            NSColor(red: 0.2, green: 0.8, blue: 0.8, alpha: 1.0),  // Cyan
        ]
    }

    private func extractColorsFromImage(_ image: NSImage) {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }

        let width = cgImage.width
        let height = cgImage.height
        let bytesPerPixel = 4
        let bytesPerRow = bytesPerPixel * width
        let bitsPerComponent = 8

        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: bitsPerComponent,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return }

        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        guard let data = context.data else { return }

        var colorCounts: [UInt32: Int] = [:]

        for y in 0..<height {
            for x in 0..<width {
                let pixelIndex = (y * width + x) * bytesPerPixel
                let r = data.load(fromByteOffset: pixelIndex, as: UInt8.self)
                let g = data.load(fromByteOffset: pixelIndex + 1, as: UInt8.self)
                let b = data.load(fromByteOffset: pixelIndex + 2, as: UInt8.self)

                // Quantize colors
                let qr = (UInt32(r) / 32) * 32
                let qg = (UInt32(g) / 32) * 32
                let qb = (UInt32(b) / 32) * 32
                let quantized = (qr << 16) | (qg << 8) | qb

                colorCounts[quantized, default: 0] += 1
            }
        }

        let sortedColors = colorCounts.sorted { $0.value > $1.value }
        extractedColors = sortedColors.prefix(8).map { colorValue, _ in
            let r = CGFloat((colorValue >> 16) & 0xFF) / 255.0
            let g = CGFloat((colorValue >> 8) & 0xFF) / 255.0
            let b = CGFloat(colorValue & 0xFF) / 255.0
            return NSColor(red: r, green: g, blue: b, alpha: 1.0)
        }
    }
}

#Preview {
    struct PreviewWrapper: View {
        @State private var displayMode: SimpleEditorViewModel.MeshDisplayMode = .solid
        @State private var materialType: SimpleEditorViewModel.MaterialType = .matte
        @State private var customColor: NSColor? = nil

        var body: some View {
            ModelViewerContainer(
                modelURL: nil,
                displayMode: $displayMode,
                materialType: $materialType,
                customColor: $customColor
            )
            .frame(width: 400, height: 300)
            .padding()
        }
    }

    return PreviewWrapper()
}
