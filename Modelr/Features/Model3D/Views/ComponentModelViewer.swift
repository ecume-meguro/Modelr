import SwiftUI
import SceneKit
import ModelIO
import SceneKit.ModelIO

/// A 3D viewer that displays mesh components with keep/delete coloring and highlighting
struct ComponentModelViewer: NSViewRepresentable {
    let componentFiles: [ComponentFile]
    let keepIndices: Set<Int>
    let deleteIndices: Set<Int>
    let highlightedIndex: Int?
    let isolatedIndex: Int?
    let displayMode: SimpleEditorViewModel.MeshDisplayMode
    /// Pre-loaded SceneKit nodes for instant rendering (optional - falls back to loading from disk if empty)
    var preloadedNodes: [Int: SCNNode] = [:]
    /// Custom color override (when user selects a paint color)
    var customColor: NSColor? = nil

    /// Check if artifacts are present (items in both keep and delete lists)
    var hasArtifacts: Bool {
        !keepIndices.isEmpty && !deleteIndices.isEmpty
    }

    struct ComponentFile: Identifiable {
        let id = UUID()
        let index: Int
        let path: String
    }

    func makeNSView(context: Context) -> SCNView {
        let scnView = SCNView()
        scnView.allowsCameraControl = true
        scnView.autoenablesDefaultLighting = false
        scnView.backgroundColor = NSColor(calibratedWhite: 0.12, alpha: 1.0)
        scnView.antialiasingMode = .multisampling4X

        let scene = SCNScene()
        scnView.scene = scene

        setupCameraAndLighting(scene: scene, view: scnView)
        context.coordinator.loadComponents(
            componentFiles,
            keepIndices: keepIndices,
            deleteIndices: deleteIndices,
            highlightedIndex: highlightedIndex,
            isolatedIndex: isolatedIndex,
            displayMode: displayMode,
            preloadedNodes: preloadedNodes,
            hasArtifacts: hasArtifacts,
            customColor: customColor,
            into: scene,
            view: scnView
        )

        return scnView
    }

    func updateNSView(_ scnView: SCNView, context: Context) {
        guard let scene = scnView.scene else { return }

        // Update component colors and visibility based on state
        context.coordinator.updateAppearance(
            keepIndices: keepIndices,
            deleteIndices: deleteIndices,
            highlightedIndex: highlightedIndex,
            isolatedIndex: isolatedIndex,
            displayMode: displayMode,
            hasArtifacts: hasArtifacts,
            customColor: customColor,
            in: scene
        )
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    private func setupCameraAndLighting(scene: SCNScene, view: SCNView) {
        let cameraNode = SCNNode()
        cameraNode.name = "cameraNode"
        cameraNode.camera = SCNCamera()
        cameraNode.camera?.zNear = 0.01
        cameraNode.camera?.zFar = 1000
        cameraNode.position = SCNVector3(0, 0, 2)
        scene.rootNode.addChildNode(cameraNode)
        view.pointOfView = cameraNode

        // Key Light
        let keyLight = SCNNode()
        keyLight.light = SCNLight()
        keyLight.light?.type = .directional
        keyLight.light?.intensity = 400
        keyLight.light?.color = NSColor(white: 0.95, alpha: 1.0)
        keyLight.position = SCNVector3(-2, 2, 2)
        keyLight.look(at: SCNVector3(0, 0, 0))
        scene.rootNode.addChildNode(keyLight)

        // Fill Light
        let fillLight = SCNNode()
        fillLight.light = SCNLight()
        fillLight.light?.type = .directional
        fillLight.light?.intensity = 350
        fillLight.light?.color = NSColor(white: 0.9, alpha: 1.0)
        fillLight.position = SCNVector3(2, 1, 2)
        fillLight.look(at: SCNVector3(0, 0, 0))
        scene.rootNode.addChildNode(fillLight)

        // Back Light
        let backLight = SCNNode()
        backLight.light = SCNLight()
        backLight.light?.type = .directional
        backLight.light?.intensity = 250
        backLight.light?.color = NSColor(white: 0.85, alpha: 1.0)
        backLight.position = SCNVector3(0, 1, -2)
        backLight.look(at: SCNVector3(0, 0, 0))
        scene.rootNode.addChildNode(backLight)

        // Ambient Light
        let ambientLight = SCNNode()
        ambientLight.light = SCNLight()
        ambientLight.light?.type = .ambient
        ambientLight.light?.intensity = 400
        ambientLight.light?.color = NSColor(white: 0.7, alpha: 1.0)
        scene.rootNode.addChildNode(ambientLight)
    }

    class Coordinator {
        private var componentNodes: [Int: SCNNode] = [:]

        // Color constants
        private let keepColor = NSColor(red: 0.2, green: 0.85, blue: 0.4, alpha: 1.0)      // Green
        private let deleteColor = NSColor(red: 0.95, green: 0.3, blue: 0.3, alpha: 1.0)   // Red
        private let highlightColor = NSColor(red: 1.0, green: 0.9, blue: 0.2, alpha: 1.0) // Yellow
        private let neutralColor = NSColor(white: 0.7, alpha: 1.0)                         // Gray clay

        func loadComponents(
            _ files: [ComponentFile],
            keepIndices: Set<Int>,
            deleteIndices: Set<Int>,
            highlightedIndex: Int?,
            isolatedIndex: Int?,
            displayMode: SimpleEditorViewModel.MeshDisplayMode,
            preloadedNodes: [Int: SCNNode],
            hasArtifacts: Bool,
            customColor: NSColor?,
            into scene: SCNScene,
            view: SCNView
        ) {
            // Remove existing components
            scene.rootNode.childNode(withName: "componentsContainer", recursively: true)?.removeFromParentNode()
            componentNodes.removeAll()

            let containerNode = SCNNode()
            containerNode.name = "componentsContainer"

            // Check if we have preloaded nodes available
            let hasPreloadedNodes = !preloadedNodes.isEmpty

            if hasPreloadedNodes {
                // Use pre-loaded nodes for instant rendering (main thread)
                // Materials are already applied during preload, so this is very fast
                for file in files {
                    guard let preloadedNode = preloadedNodes[file.index] else { continue }

                    // Clone the pre-loaded node (materials are preserved in clone)
                    let componentNode = preloadedNode.clone()
                    componentNode.name = "component_\(file.index)"

                    // Only re-apply materials if highlighted (yellow override) or display mode changed
                    // Otherwise use the pre-baked materials for instant display
                    if highlightedIndex == file.index {
                        self.applyMaterialToNode(
                            node: componentNode,
                            index: file.index,
                            keepIndices: keepIndices,
                            deleteIndices: deleteIndices,
                            highlightedIndex: highlightedIndex,
                            isolatedIndex: isolatedIndex,
                            displayMode: displayMode,
                            hasArtifacts: hasArtifacts,
                            customColor: customColor
                        )
                    }

                    // Set initial visibility based on isolation
                    if let isolated = isolatedIndex {
                        componentNode.isHidden = file.index != isolated
                    }

                    containerNode.addChildNode(componentNode)
                    self.componentNodes[file.index] = componentNode
                }

                scene.rootNode.addChildNode(containerNode)
                self.centerAndScaleContainer(containerNode)
            } else {
                // Fall back to loading from disk (background thread)
                DispatchQueue.global(qos: .userInitiated).async {
                    var allNodes: [(Int, SCNNode)] = []

                    for file in files {
                        let url = URL(fileURLWithPath: file.path)
                        guard FileManager.default.fileExists(atPath: file.path) else { continue }

                        let asset = MDLAsset(url: url)
                        asset.loadTextures()

                        guard asset.count > 0 else { continue }

                        let loadedScene = SCNScene(mdlAsset: asset)

                        let componentNode = SCNNode()
                        componentNode.name = "component_\(file.index)"

                        for child in loadedScene.rootNode.childNodes {
                            let cloned = child.clone()
                            self.applyMaterial(
                                node: cloned,
                                index: file.index,
                                keepIndices: keepIndices,
                                deleteIndices: deleteIndices,
                                highlightedIndex: highlightedIndex,
                                isolatedIndex: isolatedIndex,
                                displayMode: displayMode,
                                hasArtifacts: hasArtifacts,
                                customColor: customColor
                            )
                            componentNode.addChildNode(cloned)
                        }

                        // Set initial visibility based on isolation
                        if let isolated = isolatedIndex {
                            componentNode.isHidden = file.index != isolated
                        }

                        allNodes.append((file.index, componentNode))
                    }

                    DispatchQueue.main.async {
                        for (index, node) in allNodes {
                            containerNode.addChildNode(node)
                            self.componentNodes[index] = node
                        }

                        scene.rootNode.addChildNode(containerNode)
                        self.centerAndScaleContainer(containerNode)
                    }
                }
            }
        }

        /// Apply material recursively to a node and all its children
        private func applyMaterialToNode(
            node: SCNNode,
            index: Int,
            keepIndices: Set<Int>,
            deleteIndices: Set<Int>,
            highlightedIndex: Int?,
            isolatedIndex: Int?,
            displayMode: SimpleEditorViewModel.MeshDisplayMode,
            hasArtifacts: Bool,
            customColor: NSColor?
        ) {
            applyMaterial(
                node: node,
                index: index,
                keepIndices: keepIndices,
                deleteIndices: deleteIndices,
                highlightedIndex: highlightedIndex,
                isolatedIndex: isolatedIndex,
                displayMode: displayMode,
                hasArtifacts: hasArtifacts,
                customColor: customColor
            )
        }

        /// Center and scale the container node
        private func centerAndScaleContainer(_ containerNode: SCNNode) {
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

        func updateAppearance(
            keepIndices: Set<Int>,
            deleteIndices: Set<Int>,
            highlightedIndex: Int?,
            isolatedIndex: Int?,
            displayMode: SimpleEditorViewModel.MeshDisplayMode,
            hasArtifacts: Bool,
            customColor: NSColor?,
            in scene: SCNScene
        ) {
            for (index, node) in componentNodes {
                // Update visibility based on isolation
                if let isolated = isolatedIndex {
                    node.isHidden = index != isolated
                } else {
                    node.isHidden = false
                }

                // Update materials
                updateNodeMaterial(
                    node: node,
                    index: index,
                    keepIndices: keepIndices,
                    deleteIndices: deleteIndices,
                    highlightedIndex: highlightedIndex,
                    isolatedIndex: isolatedIndex,
                    displayMode: displayMode,
                    hasArtifacts: hasArtifacts,
                    customColor: customColor
                )
            }
        }

        private func applyMaterial(
            node: SCNNode,
            index: Int,
            keepIndices: Set<Int>,
            deleteIndices: Set<Int>,
            highlightedIndex: Int?,
            isolatedIndex: Int?,
            displayMode: SimpleEditorViewModel.MeshDisplayMode,
            hasArtifacts: Bool,
            customColor: NSColor?
        ) {
            let color = colorForComponent(
                index: index,
                keepIndices: keepIndices,
                deleteIndices: deleteIndices,
                highlightedIndex: highlightedIndex,
                hasArtifacts: hasArtifacts,
                customColor: customColor
            )

            node.geometry?.materials.forEach { material in
                material.isDoubleSided = true
                material.diffuse.contents = color
                configureMaterial(material, for: displayMode)
            }

            for child in node.childNodes {
                applyMaterial(
                    node: child,
                    index: index,
                    keepIndices: keepIndices,
                    deleteIndices: deleteIndices,
                    highlightedIndex: highlightedIndex,
                    isolatedIndex: isolatedIndex,
                    displayMode: displayMode,
                    hasArtifacts: hasArtifacts,
                    customColor: customColor
                )
            }
        }

        private func updateNodeMaterial(
            node: SCNNode,
            index: Int,
            keepIndices: Set<Int>,
            deleteIndices: Set<Int>,
            highlightedIndex: Int?,
            isolatedIndex: Int?,
            displayMode: SimpleEditorViewModel.MeshDisplayMode,
            hasArtifacts: Bool,
            customColor: NSColor?
        ) {
            let color = colorForComponent(
                index: index,
                keepIndices: keepIndices,
                deleteIndices: deleteIndices,
                highlightedIndex: highlightedIndex,
                hasArtifacts: hasArtifacts,
                customColor: customColor
            )

            node.geometry?.materials.forEach { material in
                material.diffuse.contents = color
                configureMaterial(material, for: displayMode)
            }

            for child in node.childNodes {
                updateNodeMaterial(
                    node: child,
                    index: index,
                    keepIndices: keepIndices,
                    deleteIndices: deleteIndices,
                    highlightedIndex: highlightedIndex,
                    isolatedIndex: isolatedIndex,
                    displayMode: displayMode,
                    hasArtifacts: hasArtifacts,
                    customColor: customColor
                )
            }
        }

        private func configureMaterial(_ material: SCNMaterial, for displayMode: SimpleEditorViewModel.MeshDisplayMode) {
            switch displayMode {
            case .solid:
                material.fillMode = .fill
                material.transparency = 1.0
                material.transparencyMode = .default
                material.blendMode = .replace
                material.writesToDepthBuffer = true
                material.lightingModel = .physicallyBased
            case .wireframe:
                material.fillMode = .lines
                material.transparency = 1.0
                material.transparencyMode = .default
                material.blendMode = .replace
                material.writesToDepthBuffer = true
                material.lightingModel = .constant
            }
        }

        private func colorForComponent(
            index: Int,
            keepIndices: Set<Int>,
            deleteIndices: Set<Int>,
            highlightedIndex: Int?,
            hasArtifacts: Bool,
            customColor: NSColor?
        ) -> NSColor {
            // Highlighted overrides everything - bright yellow
            if highlightedIndex == index {
                return highlightColor
            }

            // Custom color takes priority (user paint selection)
            if let custom = customColor {
                return custom
            }

            // Only show keep/delete colors if there are actual artifacts (items in both lists)
            if hasArtifacts {
                if keepIndices.contains(index) {
                    return keepColor
                } else if deleteIndices.contains(index) {
                    return deleteColor
                }
            }

            // No artifacts or fallback - use neutral gray clay
            return neutralColor
        }
    }
}

/// Container for component model viewer with controls
struct ComponentModelViewerContainer: View {
    let componentFiles: [ComponentModelViewer.ComponentFile]
    let keepIndices: Set<Int>
    let deleteIndices: Set<Int>
    let highlightedIndex: Int?
    let isolatedIndex: Int?
    @Binding var displayMode: SimpleEditorViewModel.MeshDisplayMode
    var preloadedNodes: [Int: SCNNode] = [:]
    @Binding var customColor: NSColor?
    @State private var showColorPicker = false

    /// Check if artifacts are present (items in both keep and delete lists)
    private var hasArtifacts: Bool {
        !keepIndices.isEmpty && !deleteIndices.isEmpty
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(NSColor(calibratedWhite: 0.1, alpha: 1.0)))
                .shadow(color: .black.opacity(0.3), radius: 20, y: 10)

            if !componentFiles.isEmpty {
                ComponentModelViewer(
                    componentFiles: componentFiles,
                    keepIndices: keepIndices,
                    deleteIndices: deleteIndices,
                    highlightedIndex: highlightedIndex,
                    isolatedIndex: isolatedIndex,
                    displayMode: displayMode,
                    preloadedNodes: preloadedNodes,
                    customColor: customColor
                )
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))

                // Bottom-left vertical controls
                VStack {
                    Spacer()
                    HStack {
                        viewerControls
                        Spacer()
                        // Legend only when artifacts present
                        if hasArtifacts {
                            colorLegend
                        }
                    }
                }
                .padding(AppDesign.Spacing.p12)
            } else {
                VStack(spacing: AppDesign.Spacing.p12) {
                    ProgressView()
                    Text("Loading components...")
                        .font(.system(size: AppDesign.FontSize.body))
                        .foregroundColor(.secondary)
                }
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.white.opacity(0.1), lineWidth: 1)
        )
    }

    // MARK: - Viewer Controls (Bottom-Left, Vertical)

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

            // Preset colors
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

            Divider()

            // Custom color picker
            ColorPicker("Custom", selection: Binding(
                get: { Color(nsColor: customColor ?? NSColor.gray) },
                set: { customColor = NSColor($0) }
            ))
            .labelsHidden()
        }
        .padding(AppDesign.Spacing.p12)
        .frame(width: 180)
    }

    private var presetColors: [NSColor] {
        [
            NSColor(red: 0.95, green: 0.6, blue: 0.5, alpha: 1.0),   // Terracotta
            NSColor(red: 0.9, green: 0.85, blue: 0.7, alpha: 1.0),  // Cream
            NSColor(red: 0.6, green: 0.75, blue: 0.85, alpha: 1.0), // Sky blue
            NSColor(red: 0.7, green: 0.85, blue: 0.7, alpha: 1.0),  // Mint
            NSColor(red: 0.85, green: 0.7, blue: 0.85, alpha: 1.0), // Lavender
            NSColor(red: 1.0, green: 0.85, blue: 0.5, alpha: 1.0),  // Gold
            NSColor(red: 0.4, green: 0.4, blue: 0.45, alpha: 1.0),  // Dark gray
            NSColor(red: 0.95, green: 0.95, blue: 0.95, alpha: 1.0) // White
        ]
    }

    // MARK: - Color Legend

    @ViewBuilder
    private var colorLegend: some View {
        HStack(spacing: AppDesign.Spacing.p12) {
            legendItem(color: .green, label: "Keep")
            legendItem(color: .red, label: "Delete")
            if highlightedIndex != nil {
                legendItem(color: .yellow, label: "Selected")
            }
        }
        .font(.system(size: AppDesign.FontSize.xs, weight: .medium))
        .foregroundColor(.white.opacity(0.8))
        .padding(.horizontal, AppDesign.Spacing.p12)
        .padding(.vertical, AppDesign.Spacing.p6)
        .background(.ultraThinMaterial.opacity(0.8))
        .clipShape(Capsule())
    }

    @ViewBuilder
    private func legendItem(color: Color, label: String) -> some View {
        HStack(spacing: 4) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
            Text(label)
        }
    }
}
