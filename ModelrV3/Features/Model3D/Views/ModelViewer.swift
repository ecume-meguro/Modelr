import SwiftUI
import SceneKit
import ModelIO
import SceneKit.ModelIO

// Model cache for efficient reuse
class ModelCache {
    static let shared = ModelCache()
    private let cache = NSCache<NSString, MDLAsset>()
    private let materialCache = NSCache<NSString, SCNMaterial>()

    init() {
        cache.countLimit = 5
        cache.totalCostLimit = 500 * 1024 * 1024 // 500MB
        materialCache.countLimit = 20
        materialCache.totalCostLimit = 10 * 1024 * 1024 // 10MB
    }

    func getAsset(for url: URL) -> MDLAsset? {
        let key = url.path as NSString
        if let asset = cache.object(forKey: key) {
            return asset
        }
        let asset = MDLAsset(url: url)
        asset.loadTextures()
        cache.setObject(asset, forKey: key)
        return asset
    }

    func getCachedSCNMaterial(for key: String) -> SCNMaterial? {
        return materialCache.object(forKey: key as NSString)
    }

    func setCachedSCNMaterial(_ material: SCNMaterial, for key: String) {
        materialCache.setObject(material, forKey: key as NSString)
    }

    func clear() {
        cache.removeAllObjects()
        materialCache.removeAllObjects()
    }
}

/// Interactive 3D model viewer using SceneKit with improved camera controls
struct ModelViewer: NSViewRepresentable {
    let modelURL: URL?

    func makeNSView(context: Context) -> SCNView {
        let scnView = SCNView()
        scnView.allowsCameraControl = true
        scnView.autoenablesDefaultLighting = false
        scnView.backgroundColor = NSColor(calibratedWhite: 0.15, alpha: 1.0)
        scnView.antialiasingMode = .multisampling4X

        // Configure camera control behavior for smoother interaction
        scnView.defaultCameraController.interactionMode = .orbitTurntable
        scnView.defaultCameraController.inertiaEnabled = true
        scnView.defaultCameraController.inertiaFriction = 0.9
        scnView.defaultCameraController.maximumVerticalAngle = 89
        scnView.defaultCameraController.minimumVerticalAngle = -89

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
                    .filter { $0.name == "loadedModel" || $0.name == "cameraNode" }
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
            // Try loading from cache first
            let asset = ModelCache.shared.getAsset(for: url) ?? MDLAsset(url: url)
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

                // Center the model at origin
                let centerX = (min.x + max.x) / 2
                let centerY = (min.y + max.y) / 2
                let centerZ = (min.z + max.z) / 2

                // Create a pivot to center the model at origin
                containerNode.pivot = SCNMatrix4MakeTranslation(centerX, centerY, centerZ)
                containerNode.position = SCNVector3(0, 0, 0)

                // Scale to fit in a 2-unit box
                let scale = 2.0 / maxSize
                containerNode.scale = SCNVector3(scale, scale, scale)

                print("Applied scale: \(scale)")

                // Create camera with proper settings for orbit control
                let cameraNode = SCNNode()
                cameraNode.name = "cameraNode"
                cameraNode.camera = SCNCamera()
                cameraNode.camera?.automaticallyAdjustsZRange = true
                cameraNode.camera?.fieldOfView = 45
                // Set reasonable z-range for zooming
                cameraNode.camera?.zNear = 0.01
                cameraNode.camera?.zFar = 1000

                // Position camera at a good viewing distance
                let cameraDistance: Float = 5.0
                cameraNode.position = SCNVector3(0, 0, cameraDistance)
                cameraNode.look(at: SCNVector3(0, 0, 0))
                scene.rootNode.addChildNode(cameraNode)
                scnView.pointOfView = cameraNode

                // Set the camera controller's target to the model center
                scnView.defaultCameraController.target = SCNVector3(0, 0, 0)

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
                // Use cached material if available
                let cacheKey = "default_neutral_gray"
                if let cachedMaterial = ModelCache.shared.getCachedSCNMaterial(for: cacheKey) {
                    geometry.materials = [cachedMaterial]
                } else {
                    // Create new material and cache it
                    let material = SCNMaterial()
                    // Neutral clay-like gray for good shape visibility
                    material.diffuse.contents = NSColor(calibratedRed: 0.6, green: 0.6, blue: 0.65, alpha: 1.0)
                    material.specular.contents = NSColor(calibratedWhite: 0.3, alpha: 1.0)
                    material.shininess = 0.2
                    material.lightingModel = .physicallyBased
                    material.roughness.contents = 0.7
                    material.metalness.contents = 0.0
                    geometry.materials = [material]
                    ModelCache.shared.setCachedSCNMaterial(material, for: cacheKey)
                }
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
                    Spacer()

                    HStack {
                        Spacer()
                        Text("Drag to rotate • Scroll to zoom")
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
