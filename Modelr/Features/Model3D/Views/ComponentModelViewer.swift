import SwiftUI
import SceneKit
import ModelIO
import SceneKit.ModelIO

/// A 3D viewer that displays mesh components with different colors and highlights selected ones
struct ComponentModelViewer: NSViewRepresentable {
    let componentFiles: [ComponentFile]
    let selectedIndices: Set<Int>

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
        context.coordinator.loadComponents(componentFiles, selectedIndices: selectedIndices, into: scene, view: scnView)

        return scnView
    }

    func updateNSView(_ scnView: SCNView, context: Context) {
        guard let scene = scnView.scene else { return }

        // Update component colors based on selection
        context.coordinator.updateColors(selectedIndices: selectedIndices, in: scene)
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

        func loadComponents(_ files: [ComponentFile], selectedIndices: Set<Int>, into scene: SCNScene, view: SCNView) {
            // Remove existing components
            scene.rootNode.childNode(withName: "componentsContainer", recursively: true)?.removeFromParentNode()
            componentNodes.removeAll()

            let containerNode = SCNNode()
            containerNode.name = "componentsContainer"

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
                        self.applyMaterial(node: cloned, index: file.index, isSelected: selectedIndices.contains(file.index))
                        componentNode.addChildNode(cloned)
                    }

                    allNodes.append((file.index, componentNode))
                }

                DispatchQueue.main.async {
                    for (index, node) in allNodes {
                        containerNode.addChildNode(node)
                        self.componentNodes[index] = node
                    }

                    scene.rootNode.addChildNode(containerNode)

                    // Center and scale
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

        func updateColors(selectedIndices: Set<Int>, in scene: SCNScene) {
            for (index, node) in componentNodes {
                let isSelected = selectedIndices.contains(index)
                updateNodeMaterial(node: node, index: index, isSelected: isSelected)
            }
        }

        private func applyMaterial(node: SCNNode, index: Int, isSelected: Bool) {
            let color = colorForComponent(index: index, isSelected: isSelected)

            node.geometry?.materials.forEach { material in
                material.isDoubleSided = true
                material.diffuse.contents = color
                material.lightingModel = .physicallyBased
            }

            for child in node.childNodes {
                applyMaterial(node: child, index: index, isSelected: isSelected)
            }
        }

        private func updateNodeMaterial(node: SCNNode, index: Int, isSelected: Bool) {
            let color = colorForComponent(index: index, isSelected: isSelected)

            node.geometry?.materials.forEach { material in
                material.diffuse.contents = color
            }

            for child in node.childNodes {
                updateNodeMaterial(node: child, index: index, isSelected: isSelected)
            }
        }

        private func colorForComponent(index: Int, isSelected: Bool) -> NSColor {
            // Use neon colors matching AppDesign
            let neonColors: [NSColor] = [
                NSColor(red: 0.0, green: 1.0, blue: 0.8, alpha: 1.0),   // Cyan
                NSColor(red: 1.0, green: 0.2, blue: 0.6, alpha: 1.0),   // Magenta
                NSColor(red: 0.4, green: 1.0, blue: 0.2, alpha: 1.0),   // Lime
                NSColor(red: 1.0, green: 0.6, blue: 0.0, alpha: 1.0),   // Orange
                NSColor(red: 0.6, green: 0.4, blue: 1.0, alpha: 1.0),   // Purple
                NSColor(red: 1.0, green: 1.0, blue: 0.2, alpha: 1.0),   // Yellow
            ]

            let baseColor = neonColors[index % neonColors.count]

            if isSelected {
                // Brighter when selected
                return baseColor
            } else {
                // Dimmer when not selected
                return baseColor.withAlphaComponent(0.4)
            }
        }
    }
}

/// Container for component model viewer with controls
struct ComponentModelViewerContainer: View {
    let componentFiles: [ComponentModelViewer.ComponentFile]
    let selectedIndices: Set<Int>

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(NSColor(calibratedWhite: 0.1, alpha: 1.0)))
                .shadow(color: .black.opacity(0.3), radius: 20, y: 10)

            if !componentFiles.isEmpty {
                ComponentModelViewer(componentFiles: componentFiles, selectedIndices: selectedIndices)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))

                VStack {
                    Spacer()
                    HStack {
                        Spacer()
                        HStack(spacing: AppDesign.Spacing.p6) {
                            Image(systemName: "hand.draw")
                            Text("Drag to rotate")
                        }
                        .font(.system(size: AppDesign.FontSize.xs, weight: .medium))
                        .foregroundColor(.white.opacity(0.8))
                        .padding(.horizontal, AppDesign.Spacing.p12)
                        .padding(.vertical, AppDesign.Spacing.p6)
                        .background(.ultraThinMaterial.opacity(0.8))
                        .clipShape(Capsule())
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
}
