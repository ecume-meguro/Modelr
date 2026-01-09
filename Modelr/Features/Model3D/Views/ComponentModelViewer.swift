import SwiftUI
import SceneKit
import ModelIO
import SceneKit.ModelIO

/// A 3D viewer that displays mesh components with keep/delete coloring and highlighting
struct ComponentModelViewer: NSViewRepresentable {
    let componentFiles: [ComponentFile]
    let keepIndices: Set<Int>
    let deleteIndices: Set<Int>
    let hoveredIndex: Int?
    let isolatedIndex: Int?
    let displayMode: SimpleEditorViewModel.MeshDisplayMode
    /// Pre-loaded SceneKit nodes for instant rendering (optional - falls back to loading from disk if empty)
    var preloadedNodes: [Int: SCNNode] = [:]
    /// Custom color override (when user selects a paint color)
    var customColor: NSColor? = nil

    // MARK: - Interaction Callbacks
    /// Called when a component is left-clicked in the viewport (keep)
    var onComponentClicked: ((Int) -> Void)? = nil
    /// Called when a component is right-clicked in the viewport (delete)
    var onComponentRightClicked: ((Int) -> Void)? = nil
    /// Called when empty space is clicked (deselect)
    var onEmptySpaceClicked: (() -> Void)? = nil
    /// Called when hover state changes (nil when not hovering over any component)
    var onComponentHovered: ((Int?) -> Void)? = nil

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

        // GPU acceleration settings
        scnView.preferredFramesPerSecond = 60
        scnView.rendersContinuously = false  // Only render when needed (saves GPU)
        scnView.isJitteringEnabled = true    // Temporal anti-aliasing for smoother edges

        let scene = SCNScene()
        scnView.scene = scene

        setupCameraAndLighting(scene: scene, view: scnView)

        // Set up interaction handling
        context.coordinator.scnView = scnView
        context.coordinator.onComponentClicked = onComponentClicked
        context.coordinator.onComponentRightClicked = onComponentRightClicked
        context.coordinator.onEmptySpaceClicked = onEmptySpaceClicked
        context.coordinator.onComponentHovered = onComponentHovered
        context.coordinator.setupInteraction(for: scnView)

        context.coordinator.loadComponents(
            componentFiles,
            keepIndices: keepIndices,
            deleteIndices: deleteIndices,
            hoveredIndex: hoveredIndex,
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

        // Update callbacks in case they changed
        context.coordinator.onComponentClicked = onComponentClicked
        context.coordinator.onComponentRightClicked = onComponentRightClicked
        context.coordinator.onEmptySpaceClicked = onEmptySpaceClicked
        context.coordinator.onComponentHovered = onComponentHovered

        // Update component colors and visibility based on state
        context.coordinator.updateAppearance(
            keepIndices: keepIndices,
            deleteIndices: deleteIndices,
            hoveredIndex: hoveredIndex,
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

    class Coordinator: NSObject {
        private var componentNodes: [Int: SCNNode] = [:]

        // MARK: - Interaction Handling
        weak var scnView: SCNView?
        var onComponentClicked: ((Int) -> Void)?
        var onComponentRightClicked: ((Int) -> Void)?
        var onEmptySpaceClicked: (() -> Void)?
        var onComponentHovered: ((Int?) -> Void)?
        private var clickGestureRecognizer: NSClickGestureRecognizer?
        private var rightClickGestureRecognizer: NSClickGestureRecognizer?
        private var lastHoveredIndex: Int?

        // MARK: - Material System (Clay shader with artifact highlighting)

        // Clay shader - warm grey, matte finish (like ZBrush/Blender sculpting)
        private let clayColor = NSColor(red: 0.82, green: 0.80, blue: 0.76, alpha: 1.0)
        private let clayHoverColor = NSColor(red: 0.88, green: 0.86, blue: 0.82, alpha: 1.0)

        // Rim light colors for delete indication
        private let deleteRimColor = NSColor(red: 1.0, green: 0.2, blue: 0.2, alpha: 1.0)
        private let deleteRimHoverColor = NSColor(red: 1.0, green: 0.4, blue: 0.4, alpha: 1.0)

        // Hover glow for keep items
        private let keepHoverGlow = NSColor(red: 0.3, green: 0.8, blue: 1.0, alpha: 1.0)

        private let materialRoughness: CGFloat = 0.75  // Matte clay finish
        private let materialMetalness: CGFloat = 0.0   // No metalness for clay

        // Material state enum for cleaner logic
        enum MaterialState {
            case keep           // Kept items (clean clay)
            case keepHover      // Hovered kept items (clay with subtle glow)
            case delete         // Deleted items (clay with red rim light)
            case deleteHover    // Hovered deleted items (clay with brighter red rim)
        }

        // MARK: - Setup Interaction
        private var mouseMovedMonitor: Any?
        private var scrollStateObserver: Any?
        private var isScrolling = false
        private var scrollEndTimer: Timer?

        private func handleScrollEvent() {
            if !isScrolling {
                isScrolling = true
                // Clear hover during scroll
                if lastHoveredIndex != nil {
                    lastHoveredIndex = nil
                    onComponentHovered?(nil)
                }
            }
            // Reset end timer
            scrollEndTimer?.invalidate()
            scrollEndTimer = Timer.scheduledTimer(withTimeInterval: 0.12, repeats: false) { [weak self] _ in
                self?.isScrolling = false
            }
        }

        func setupInteraction(for scnView: SCNView) {
            // Add left-click gesture recognizer (keep)
            let clickRecognizer = NSClickGestureRecognizer(target: self, action: #selector(handleClick(_:)))
            scnView.addGestureRecognizer(clickRecognizer)
            self.clickGestureRecognizer = clickRecognizer

            // Add right-click gesture recognizer (delete)
            let rightClickRecognizer = NSClickGestureRecognizer(target: self, action: #selector(handleRightClick(_:)))
            rightClickRecognizer.buttonMask = 0x2  // Right mouse button
            scnView.addGestureRecognizer(rightClickRecognizer)
            self.rightClickGestureRecognizer = rightClickRecognizer

            // Set up mouse moved monitor for hover detection
            mouseMovedMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved]) { [weak self] event in
                self?.handleMouseMoved(event)
                return event
            }

            // Track scroll wheel events directly to skip expensive hit testing during scroll
            scrollStateObserver = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                if event.deltaY != 0 || event.deltaX != 0 {
                    self?.handleScrollEvent()
                }
                return event
            }
        }

        @objc private func handleClick(_ gesture: NSClickGestureRecognizer) {
            guard let scnView = scnView else { return }
            let location = gesture.location(in: scnView)

            if let componentIndex = hitTestForComponentIndex(at: location, in: scnView) {
                onComponentClicked?(componentIndex)
            } else {
                // Clicked on empty space - deselect
                onEmptySpaceClicked?()
            }
        }

        @objc private func handleRightClick(_ gesture: NSClickGestureRecognizer) {
            guard let scnView = scnView else { return }
            let location = gesture.location(in: scnView)

            if let componentIndex = hitTestForComponentIndex(at: location, in: scnView) {
                onComponentRightClicked?(componentIndex)
            }
        }

        private func handleMouseMoved(_ event: NSEvent) {
            // Skip expensive hit testing during scroll
            guard !isScrolling else { return }

            guard let scnView = scnView,
                  let window = scnView.window,
                  event.window == window else {
                return
            }

            let locationInWindow = event.locationInWindow
            let location = scnView.convert(locationInWindow, from: nil)

            // Only process if within bounds
            guard scnView.bounds.contains(location) else {
                if lastHoveredIndex != nil {
                    lastHoveredIndex = nil
                    onComponentHovered?(nil)
                }
                return
            }

            let componentIndex = hitTestForComponentIndex(at: location, in: scnView)
            if componentIndex != lastHoveredIndex {
                lastHoveredIndex = componentIndex
                onComponentHovered?(componentIndex)
            }
        }

        deinit {
            if let monitor = mouseMovedMonitor {
                NSEvent.removeMonitor(monitor)
            }
            if let observer = scrollStateObserver {
                NSEvent.removeMonitor(observer)
            }
            scrollEndTimer?.invalidate()
        }

        /// Perform hit test and return the component index if a component was hit
        private func hitTestForComponentIndex(at location: CGPoint, in scnView: SCNView) -> Int? {
            let hitResults = scnView.hitTest(location, options: [
                .searchMode: SCNHitTestSearchMode.closest.rawValue,
                .ignoreHiddenNodes: true
            ])

            // Find the first hit that belongs to a component node
            for hit in hitResults {
                var node: SCNNode? = hit.node
                // Walk up the node hierarchy to find the component node
                while let currentNode = node {
                    if let nodeName = currentNode.name,
                       nodeName.hasPrefix("component_"),
                       let indexStr = nodeName.components(separatedBy: "_").last,
                       let index = Int(indexStr) {
                        return index
                    }
                    node = currentNode.parent
                }
            }
            return nil
        }

        func loadComponents(
            _ files: [ComponentFile],
            keepIndices: Set<Int>,
            deleteIndices: Set<Int>,
            hoveredIndex: Int?,
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
                    if hoveredIndex == file.index {
                        self.applyMaterialToNode(
                            node: componentNode,
                            index: file.index,
                            keepIndices: keepIndices,
                            deleteIndices: deleteIndices,
                            hoveredIndex: hoveredIndex,
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
                                hoveredIndex: hoveredIndex,
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
            hoveredIndex: Int?,
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
                hoveredIndex: hoveredIndex,
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
            hoveredIndex: Int?,
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
                    hoveredIndex: hoveredIndex,
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
            hoveredIndex: Int?,
            isolatedIndex: Int?,
            displayMode: SimpleEditorViewModel.MeshDisplayMode,
            hasArtifacts: Bool,
            customColor: NSColor?
        ) {
            let state = materialStateForComponent(
                index: index,
                keepIndices: keepIndices,
                deleteIndices: deleteIndices,
                hoveredIndex: hoveredIndex,
                hasArtifacts: hasArtifacts
            )

            node.geometry?.materials.forEach { material in
                configureMaterial(material, state: state, displayMode: displayMode, customColor: customColor)
            }

            for child in node.childNodes {
                applyMaterial(
                    node: child,
                    index: index,
                    keepIndices: keepIndices,
                    deleteIndices: deleteIndices,
                    hoveredIndex: hoveredIndex,
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
            hoveredIndex: Int?,
            isolatedIndex: Int?,
            displayMode: SimpleEditorViewModel.MeshDisplayMode,
            hasArtifacts: Bool,
            customColor: NSColor?
        ) {
            let state = materialStateForComponent(
                index: index,
                keepIndices: keepIndices,
                deleteIndices: deleteIndices,
                hoveredIndex: hoveredIndex,
                hasArtifacts: hasArtifacts
            )

            node.geometry?.materials.forEach { material in
                configureMaterial(material, state: state, displayMode: displayMode, customColor: customColor)
            }

            for child in node.childNodes {
                updateNodeMaterial(
                    node: child,
                    index: index,
                    keepIndices: keepIndices,
                    deleteIndices: deleteIndices,
                    hoveredIndex: hoveredIndex,
                    isolatedIndex: isolatedIndex,
                    displayMode: displayMode,
                    hasArtifacts: hasArtifacts,
                    customColor: customColor
                )
            }
        }

        /// Determine material state for a component based on keep/delete/hover status
        private func materialStateForComponent(
            index: Int,
            keepIndices: Set<Int>,
            deleteIndices: Set<Int>,
            hoveredIndex: Int?,
            hasArtifacts: Bool
        ) -> MaterialState {
            let isHovered = hoveredIndex == index
            let isDeleted = hasArtifacts && deleteIndices.contains(index)

            if isDeleted {
                return isHovered ? .deleteHover : .delete
            } else {
                return isHovered ? .keepHover : .keep
            }
        }

        /// Configure material with clay shader and rim-light for artifacts
        private func configureMaterial(
            _ material: SCNMaterial,
            state: MaterialState,
            displayMode: SimpleEditorViewModel.MeshDisplayMode,
            customColor: NSColor?
        ) {
            material.isDoubleSided = true

            // Base configuration
            switch displayMode {
            case .solid:
                material.fillMode = .fill
                material.lightingModel = .physicallyBased
            case .wireframe:
                material.fillMode = .lines
                material.lightingModel = .constant
            }

            // Clay material base properties (matte, warm grey)
            material.metalness.contents = materialMetalness
            material.roughness.contents = materialRoughness
            material.transparency = 1.0
            material.transparencyMode = .default
            material.blendMode = .replace
            material.writesToDepthBuffer = true

            // Apply material based on state
            switch state {
            case .keep:
                // Clean clay - no effects
                material.diffuse.contents = customColor ?? clayColor
                material.emission.contents = NSColor.black
                material.emission.intensity = 0.0
                // Clear any rim/fresnel effects
                material.fresnelExponent = 0.0

            case .keepHover:
                // Clay with subtle cyan glow on hover
                material.diffuse.contents = customColor ?? clayHoverColor
                material.emission.contents = keepHoverGlow
                material.emission.intensity = 0.2
                material.fresnelExponent = 2.0  // Subtle edge glow

            case .delete:
                // Clay base with red rim light (Fresnel-based edge emission)
                material.diffuse.contents = customColor ?? clayColor
                material.emission.contents = deleteRimColor
                material.emission.intensity = 0.6
                material.fresnelExponent = 4.0  // Strong edge effect for rim light
                // Slightly reduce opacity to show it's marked for deletion
                material.transparency = 0.85

            case .deleteHover:
                // Brighter red rim light on hover
                material.diffuse.contents = customColor ?? clayHoverColor
                material.emission.contents = deleteRimHoverColor
                material.emission.intensity = 0.8
                material.fresnelExponent = 3.5  // Slightly softer but brighter
                material.transparency = 0.9
            }
        }

        // Helper to get color for a component (returns clay color, used for legend)
        private func colorForComponent(
            index: Int,
            keepIndices: Set<Int>,
            deleteIndices: Set<Int>,
            hoveredIndex: Int?,
            hasArtifacts: Bool,
            customColor: NSColor?
        ) -> NSColor {
            if let custom = customColor {
                return custom
            }

            let state = materialStateForComponent(
                index: index,
                keepIndices: keepIndices,
                deleteIndices: deleteIndices,
                hoveredIndex: hoveredIndex,
                hasArtifacts: hasArtifacts
            )

            switch state {
            case .keep, .keepHover:
                return clayColor
            case .delete, .deleteHover:
                // Return clay with red tint indication
                return clayColor
            }
        }
    }
}

/// Container for component model viewer with controls
struct ComponentModelViewerContainer: View {
    let componentFiles: [ComponentModelViewer.ComponentFile]
    let keepIndices: Set<Int>
    let deleteIndices: Set<Int>
    let hoveredIndex: Int?
    let isolatedIndex: Int?
    @Binding var displayMode: SimpleEditorViewModel.MeshDisplayMode
    var preloadedNodes: [Int: SCNNode] = [:]
    @Binding var customColor: NSColor?
    @State private var showColorPicker = false

    // Interaction callbacks (passed through to ComponentModelViewer)
    var onComponentClicked: ((Int) -> Void)? = nil
    var onComponentRightClicked: ((Int) -> Void)? = nil
    var onEmptySpaceClicked: (() -> Void)? = nil
    var onComponentHovered: ((Int?) -> Void)? = nil

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
                    hoveredIndex: hoveredIndex,
                    isolatedIndex: isolatedIndex,
                    displayMode: displayMode,
                    preloadedNodes: preloadedNodes,
                    customColor: customColor,
                    onComponentClicked: onComponentClicked,
                    onComponentRightClicked: onComponentRightClicked,
                    onEmptySpaceClicked: onEmptySpaceClicked,
                    onComponentHovered: onComponentHovered
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

    // MARK: - Material Legend

    // Clay color for legend
    private let legendClayColor = Color(red: 0.82, green: 0.80, blue: 0.76)
    private let legendRedRimColor = Color(red: 1.0, green: 0.3, blue: 0.3)
    private let legendCyanGlow = Color(red: 0.3, green: 0.8, blue: 1.0)

    @ViewBuilder
    private var colorLegend: some View {
        HStack(spacing: AppDesign.Spacing.p12) {
            // Clay material indicator (clean mesh)
            legendItem(style: .clay, label: "Keep")
            // Red rim indicator (artifact)
            legendItem(style: .redRim, label: "Artifact")
        }
        .font(.system(size: AppDesign.FontSize.xs, weight: .medium))
        .foregroundColor(.white.opacity(0.8))
        .padding(.horizontal, AppDesign.Spacing.p12)
        .padding(.vertical, AppDesign.Spacing.p6)
        .background(.ultraThinMaterial.opacity(0.8))
        .clipShape(Capsule())
    }

    private enum LegendStyle {
        case clay
        case redRim
    }

    @ViewBuilder
    private func legendItem(style: LegendStyle, label: String) -> some View {
        HStack(spacing: 4) {
            switch style {
            case .clay:
                // Clean clay circle
                Circle()
                    .fill(legendClayColor)
                    .frame(width: 10, height: 10)
                    .shadow(color: .black.opacity(0.3), radius: 1, y: 1)

            case .redRim:
                // Clay with red rim glow
                Circle()
                    .fill(legendClayColor)
                    .overlay(
                        Circle()
                            .stroke(legendRedRimColor, lineWidth: 2)
                            .blur(radius: 1)
                    )
                    .frame(width: 10, height: 10)
            }
            Text(label)
        }
    }
}
