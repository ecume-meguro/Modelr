import SwiftUI
import SceneKit
import ModelIO
import SceneKit.ModelIO

// MARK: - SceneKit 3D Viewer (Headlamp Lighting)

/// A robust 3D viewer that uses a camera-attached light ("Headlamp") 
/// to ensure the model is always visible from the user's angle.
struct ModelViewer: NSViewRepresentable {
    let modelURL: URL?

    func makeNSView(context: Context) -> SCNView {
        let scnView = SCNView()
        
        // 1. Basic Setup
        scnView.allowsCameraControl = true
        scnView.autoenablesDefaultLighting = false
        scnView.backgroundColor = NSColor(calibratedWhite: 0.12, alpha: 1.0)
        scnView.antialiasingMode = .multisampling4X
        
        // 2. Scene Setup
        let scene = SCNScene()
        scnView.scene = scene
        
        // 3. Camera & Headlamp Setup
        setupCameraAndLighting(scene: scene, view: scnView)
        
        // 4. Load Model
        if let url = modelURL {
            context.coordinator.loadModel(url: url, into: scene, view: scnView)
        }

        return scnView
    }

    func updateNSView(_ scnView: SCNView, context: Context) {
        if let url = modelURL, context.coordinator.currentModelURL != url {
            if let scene = scnView.scene {
                // Remove old model
                scene.rootNode.childNode(withName: "loadedModel", recursively: true)?.removeFromParentNode()
                // Load new
                context.coordinator.loadModel(url: url, into: scene, view: scnView)
            }
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
        
        func loadModel(url: URL, into scene: SCNScene, view: SCNView) {
            currentModelURL = url
            
            DispatchQueue.global(qos: .userInitiated).async {
                let asset = MDLAsset(url: url)
                asset.loadTextures() // Ensure textures are loaded
                
                guard asset.count > 0 else { return }
                
                let loadedScene = SCNScene(mdlAsset: asset)
                
                DispatchQueue.main.async {
                    let containerNode = SCNNode()
                    containerNode.name = "loadedModel"
                    
                    for child in loadedScene.rootNode.childNodes {
                        let cloned = child.clone()
                        self.fixMaterials(node: cloned)
                        containerNode.addChildNode(cloned)
                    }
                    
                    scene.rootNode.addChildNode(containerNode)
                    
                    // Center and Scale
                    let (min, max) = containerNode.boundingBox
                    let size = SCNVector3(max.x - min.x, max.y - min.y, max.z - min.z)
                    let maxDim = Swift.max(size.x, Swift.max(size.y, size.z))
                    
                    if maxDim > 0 {
                        let scale = 1.5 / maxDim // Scale to fit nicely
                        containerNode.scale = SCNVector3(scale, scale, scale)
                        
                        let center = SCNVector3((min.x + max.x) / 2, (min.y + max.y) / 2, (min.z + max.z) / 2)
                        containerNode.pivot = SCNMatrix4MakeTranslation(center.x, center.y, center.z)
                        containerNode.position = SCNVector3(0, 0, 0)
                    }
                }
            }
        }
        
        func fixMaterials(node: SCNNode) {
            node.geometry?.materials.forEach { material in
                // Force double-sided to avoid holes in single-sided meshes
                material.isDoubleSided = true
                
                // Ensure the material responds to lighting
                if material.lightingModel == .constant {
                    material.lightingModel = .physicallyBased
                }
            }
            
            for child in node.childNodes {
                fixMaterials(node: child)
            }
        }
    }
}

/// A styled container for the model viewer
struct ModelViewerContainer: View {
    let modelURL: URL?

    var body: some View {
        ZStack {
            // Background
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(NSColor(calibratedWhite: 0.1, alpha: 1.0)))
                .shadow(color: .black.opacity(0.3), radius: 20, y: 10)

            if let url = modelURL {
                ModelViewer(modelURL: url)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))

                // Interaction hint
                VStack {
                    Spacer()
                    HStack {
                        Spacer()
                        HStack(spacing: AppDesign.Spacing.p6) {
                            Image(systemName: "hand.draw")
                            Text("Drag to rotate • Scroll to zoom")
                        }
                        .font(.system(size: AppDesign.FontSize.xs, weight: .medium))
                        .foregroundColor(.white.opacity(0.8))
                        .padding(.horizontal, AppDesign.Spacing.p12)
                        .padding(.vertical, AppDesign.Spacing.p6)
                        .background(.ultraThinMaterial.opacity(0.8))
                        .clipShape(Capsule())
                        .overlay(Capsule().stroke(Color.white.opacity(0.1), lineWidth: 1))
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
    }
}

#Preview {
    ModelViewerContainer(modelURL: nil)
        .frame(width: 400, height: 300)
        .padding()
}
