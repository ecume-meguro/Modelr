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
        cameraNode.position = SCNVector3(0, 0, 2) // Start slightly back
        
        // --- HEADLAMP SETUP ---
        // Attach lights TO THE CAMERA so they move with it.
        // This ensures the "front" of the model is always lit.
        
        // 1. Key Light (The Headlamp)
        let keyLightNode = SCNNode()
        keyLightNode.light = SCNLight()
        keyLightNode.light?.type = .directional
        keyLightNode.light?.intensity = 900
        keyLightNode.light?.color = NSColor.white
        keyLightNode.light?.castsShadow = true
        // Point slightly down relative to camera view
        keyLightNode.eulerAngles = SCNVector3(-0.2, 0, 0) 
        cameraNode.addChildNode(keyLightNode)
        
        // 2. Fill Light (Softer, fills shadows)
        let fillLightNode = SCNNode()
        fillLightNode.light = SCNLight()
        fillLightNode.light?.type = .directional
        fillLightNode.light?.intensity = 400
        fillLightNode.light?.color = NSColor(white: 0.9, alpha: 1.0)
        fillLightNode.light?.castsShadow = false
        // Angle from the side
        fillLightNode.eulerAngles = SCNVector3(0, -0.4, 0)
        cameraNode.addChildNode(fillLightNode)
        
        // Add Camera (with lights attached) to Scene
        scene.rootNode.addChildNode(cameraNode)
        
        // Set as view's point of view (allows orbit control)
        view.pointOfView = cameraNode
        
        // --- GLOBAL LIGHTING ---
        
        // 3. Ambient Light (Base visibility for everything)
        let ambientNode = SCNNode()
        ambientNode.light = SCNLight()
        ambientNode.light?.type = .ambient
        ambientNode.light?.intensity = 300 // Moderate ambient
        ambientNode.light?.color = NSColor(white: 0.8, alpha: 1.0)
        scene.rootNode.addChildNode(ambientNode)
        
        // 4. Environment (Reflections)
        // Neutral studio gray for PBR reflections
        scene.lightingEnvironment.contents = NSColor(white: 0.5, alpha: 1.0)
        scene.lightingEnvironment.intensity = 1.0
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
