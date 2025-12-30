import SwiftUI
import SceneKit
import ModelIO
import SceneKit.ModelIO

/// Interactive 3D model viewer using SceneKit
struct ModelViewer: NSViewRepresentable {
    let modelURL: URL?

    func makeNSView(context: Context) -> SCNView {
        let scnView = SCNView()
        scnView.allowsCameraControl = true
        scnView.autoenablesDefaultLighting = false  // We use custom lights
        scnView.backgroundColor = NSColor(calibratedWhite: 0.15, alpha: 1.0)
        scnView.antialiasingMode = .multisampling4X

        // Create scene
        let scene = SCNScene()
        scnView.scene = scene

        // Add soft ambient light
        let ambientLight = SCNNode()
        ambientLight.light = SCNLight()
        ambientLight.light?.type = .ambient
        ambientLight.light?.intensity = 200
        ambientLight.light?.color = NSColor(calibratedWhite: 0.6, alpha: 1.0)
        scene.rootNode.addChildNode(ambientLight)

        // Key light from upper-right
        let keyLight = SCNNode()
        keyLight.light = SCNLight()
        keyLight.light?.type = .directional
        keyLight.light?.intensity = 400
        keyLight.light?.color = NSColor.white
        keyLight.position = SCNVector3(5, 10, 10)
        keyLight.look(at: SCNVector3(0, 0, 0))
        scene.rootNode.addChildNode(keyLight)

        // Fill light from opposite side (dimmer)
        let fillLight = SCNNode()
        fillLight.light = SCNLight()
        fillLight.light?.type = .directional
        fillLight.light?.intensity = 150
        fillLight.light?.color = NSColor(calibratedWhite: 0.8, alpha: 1.0)
        fillLight.position = SCNVector3(-5, 2, -5)
        fillLight.look(at: SCNVector3(0, 0, 0))
        scene.rootNode.addChildNode(fillLight)

        // Load model if available
        if let url = modelURL {
            loadModel(url: url, into: scene, scnView: scnView)
        }

        return scnView
    }

    func updateNSView(_ nsView: SCNView, context: Context) {
        if let url = modelURL,
           context.coordinator.currentModelURL != url {
            context.coordinator.currentModelURL = url
            if let scene = nsView.scene {
                scene.rootNode.childNodes
                    .filter { $0.name == "loadedModel" }
                    .forEach { $0.removeFromParentNode() }
                loadModel(url: url, into: scene, scnView: nsView)
            }
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    private func loadModel(url: URL, into scene: SCNScene, scnView: SCNView) {
        print("Loading 3D model from: \(url.path)")

        DispatchQueue.global(qos: .userInitiated).async {
            // Try loading with MDLAsset
            let asset = MDLAsset(url: url)
            asset.loadTextures()

            guard asset.count > 0 else {
                print("MDLAsset has no objects")
                return
            }

            print("MDLAsset loaded with \(asset.count) objects")

            // Convert to SceneKit
            let loadedScene = SCNScene(mdlAsset: asset)

            DispatchQueue.main.async {
                let containerNode = SCNNode()
                containerNode.name = "loadedModel"

                // Clone all children from loaded scene and apply default material
                for child in loadedScene.rootNode.childNodes {
                    let cloned = child.clone()
                    self.applyDefaultMaterial(to: cloned)
                    containerNode.addChildNode(cloned)
                    print("Added child node: \(child.name ?? "unnamed"), geometry: \(child.geometry != nil)")
                }

                // Add to scene first to get proper bounding box
                scene.rootNode.addChildNode(containerNode)

                // Get bounding box
                let (min, max) = containerNode.boundingBox
                print("Bounding box: min=\(min), max=\(max)")

                let sizeX = max.x - min.x
                let sizeY = max.y - min.y
                let sizeZ = max.z - min.z
                let maxSize = Swift.max(sizeX, Swift.max(sizeY, sizeZ))

                print("Model size: \(sizeX) x \(sizeY) x \(sizeZ), maxSize: \(maxSize)")

                guard maxSize > 0 && maxSize.isFinite else {
                    print("Invalid model size, trying alternative approach")
                    // Try to find geometry nodes recursively
                    var hasGeometry = false
                    containerNode.enumerateChildNodes { node, _ in
                        if node.geometry != nil {
                            hasGeometry = true
                            print("Found geometry in: \(node.name ?? "unnamed")")
                        }
                    }
                    if !hasGeometry {
                        print("No geometry found in model")
                    }
                    return
                }

                // Center the model
                let centerX = (min.x + max.x) / 2
                let centerY = (min.y + max.y) / 2
                let centerZ = (min.z + max.z) / 2

                // Create a pivot to center
                containerNode.pivot = SCNMatrix4MakeTranslation(centerX, centerY, centerZ)

                // Scale to fit in a 2-unit box
                let scale = 2.0 / maxSize
                containerNode.scale = SCNVector3(scale, scale, scale)

                print("Applied scale: \(scale)")

                // Position camera to see the model
                let cameraNode = SCNNode()
                cameraNode.camera = SCNCamera()
                cameraNode.camera?.automaticallyAdjustsZRange = true
                cameraNode.camera?.fieldOfView = 60
                cameraNode.position = SCNVector3(0, 0, 4)
                cameraNode.look(at: SCNVector3(0, 0, 0))
                scene.rootNode.addChildNode(cameraNode)
                scnView.pointOfView = cameraNode

                print("Model loaded successfully")
            }
        }
    }

    class Coordinator {
        var currentModelURL: URL?
    }

    /// Apply a neutral gray material to geometry nodes for better visibility
    private func applyDefaultMaterial(to node: SCNNode) {
        if let geometry = node.geometry {
            // Check if geometry has no materials or only white/default materials
            let needsMaterial = geometry.materials.isEmpty ||
                geometry.materials.allSatisfy { mat in
                    guard let diffuse = mat.diffuse.contents as? NSColor else { return true }
                    // Check if it's close to white (brightness > 0.9)
                    return diffuse.brightnessComponent > 0.9
                }

            if needsMaterial {
                let material = SCNMaterial()
                // Neutral clay-like gray for good shape visibility
                material.diffuse.contents = NSColor(calibratedRed: 0.6, green: 0.6, blue: 0.65, alpha: 1.0)
                material.specular.contents = NSColor(calibratedWhite: 0.3, alpha: 1.0)
                material.shininess = 0.2
                material.lightingModel = .physicallyBased
                material.roughness.contents = 0.7
                material.metalness.contents = 0.0
                geometry.materials = [material]
            }
        }

        // Recursively apply to children
        for child in node.childNodes {
            applyDefaultMaterial(to: child)
        }
    }
}

/// A styled container for the model viewer
struct ModelViewerContainer: View {
    let modelURL: URL?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(NSColor(calibratedWhite: 0.15, alpha: 1.0)))

            if let url = modelURL {
                ModelViewer(modelURL: url)

                VStack {
                    HStack {
                        Text("Low Quality Preview")
                            .font(.caption2)
                            .fontWeight(.semibold)
                            .foregroundColor(.white)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color.orange.opacity(0.8))
                            .cornerRadius(6)
                        Spacer()
                    }
                    
                    Spacer()
                    
                    HStack {
                        Spacer()
                        Text("Drag to rotate")
                            .font(.caption2)
                            .foregroundColor(.white.opacity(0.7))
                            .padding(6)
                            .background(Color.black.opacity(0.5))
                            .cornerRadius(4)
                    }
                }
                .padding(8)
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "cube.transparent")
                        .font(.system(size: 32))
                        .foregroundColor(.gray)
                    Text("No 3D model")
                        .font(.caption)
                        .foregroundColor(.gray)
                }
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.gray.opacity(0.3), lineWidth: 1)
        )
    }
}

#Preview {
    ModelViewerContainer(modelURL: nil)
        .frame(width: 400, height: 300)
        .padding()
}
