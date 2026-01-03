import SwiftUI
import SceneKit
import ModelIO
import SceneKit.ModelIO
import UniformTypeIdentifiers

// MARK: - Debug View for Tuning 3D Viewer Settings

struct ModelViewerDebugView: View {
    @State private var modelURL: URL?
    @State private var isDragging = false

    // Lighting settings
    @State private var ambientIntensity: Double = 200
    @State private var keyLightIntensity: Double = 600
    @State private var fillLightIntensity: Double = 300
    @State private var rimLightIntensity: Double = 200

    @State private var keyLightX: Double = 5
    @State private var keyLightY: Double = 8
    @State private var keyLightZ: Double = 10

    @State private var fillLightX: Double = -5
    @State private var fillLightY: Double = 3
    @State private var fillLightZ: Double = 5

    @State private var rimLightX: Double = 0
    @State private var rimLightY: Double = 5
    @State private var rimLightZ: Double = -10

    // Material settings
    @State private var lightingModel: Int = 0  // 0=constant, 1=lambert, 2=blinn, 3=phong, 4=physicallyBased
    @State private var diffuseIntensity: Double = 1.0
    @State private var specularIntensity: Double = 0.0
    @State private var ambientIntensityMaterial: Double = 0.0
    @State private var shininess: Double = 0.0
    @State private var metalness: Double = 0.0
    @State private var roughness: Double = 0.5

    // Camera settings
    @State private var wantsHDR: Bool = false
    @State private var exposureOffset: Double = 0
    @State private var whitePoint: Double = 1.0
    @State private var contrast: Double = 0.0
    @State private var saturation: Double = 1.0
    @State private var fieldOfView: Double = 45

    // HDR Bloom settings
    @State private var bloomIntensity: Double = 0.0
    @State private var bloomThreshold: Double = 1.0
    @State private var bloomBlurRadius: Double = 4.0

    // Exposure limits
    @State private var minimumExposure: Double = -15.0
    @State private var maximumExposure: Double = 15.0

    // Scene settings
    @State private var backgroundColor: Double = 0.12
    @State private var useDefaultLighting: Bool = false

    // Update trigger
    @State private var updateTrigger = UUID()

    let lightingModels = ["Constant", "Lambert", "Blinn", "Phong", "Physically Based"]

    var body: some View {
        HSplitView {
            // Left: 3D Preview
            VStack {
                if let url = modelURL {
                    ConfigurableModelViewer(
                        modelURL: url,
                        config: currentConfig,
                        updateTrigger: updateTrigger
                    )
                    .frame(minWidth: 400, minHeight: 400)
                } else {
                    dropZone
                }
            }
            .frame(minWidth: 450)

            // Right: Controls
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    // Model drop zone (small)
                    if modelURL != nil {
                        smallDropZone
                    }

                    // Lighting Section
                    GroupBox("Lighting") {
                        VStack(alignment: .leading, spacing: 12) {
                            Toggle("Use Default Lighting", isOn: $useDefaultLighting)
                                .onChange(of: useDefaultLighting) { triggerUpdate() }

                            if !useDefaultLighting {
                                LabeledSlider(label: "Ambient", value: $ambientIntensity, range: 0...1000, onChange: triggerUpdate)

                                Divider()
                                Text("Key Light").font(.headline)
                                LabeledSlider(label: "Intensity", value: $keyLightIntensity, range: 0...2000, onChange: triggerUpdate)
                                HStack {
                                    LabeledSlider(label: "X", value: $keyLightX, range: -20...20, onChange: triggerUpdate)
                                    LabeledSlider(label: "Y", value: $keyLightY, range: -20...20, onChange: triggerUpdate)
                                    LabeledSlider(label: "Z", value: $keyLightZ, range: -20...20, onChange: triggerUpdate)
                                }

                                Divider()
                                Text("Fill Light").font(.headline)
                                LabeledSlider(label: "Intensity", value: $fillLightIntensity, range: 0...2000, onChange: triggerUpdate)
                                HStack {
                                    LabeledSlider(label: "X", value: $fillLightX, range: -20...20, onChange: triggerUpdate)
                                    LabeledSlider(label: "Y", value: $fillLightY, range: -20...20, onChange: triggerUpdate)
                                    LabeledSlider(label: "Z", value: $fillLightZ, range: -20...20, onChange: triggerUpdate)
                                }

                                Divider()
                                Text("Rim Light").font(.headline)
                                LabeledSlider(label: "Intensity", value: $rimLightIntensity, range: 0...2000, onChange: triggerUpdate)
                                HStack {
                                    LabeledSlider(label: "X", value: $rimLightX, range: -20...20, onChange: triggerUpdate)
                                    LabeledSlider(label: "Y", value: $rimLightY, range: -20...20, onChange: triggerUpdate)
                                    LabeledSlider(label: "Z", value: $rimLightZ, range: -20...20, onChange: triggerUpdate)
                                }
                            }
                        }
                        .padding(8)
                    }

                    // Material Section
                    GroupBox("Material") {
                        VStack(alignment: .leading, spacing: 12) {
                            Picker("Lighting Model", selection: $lightingModel) {
                                ForEach(0..<lightingModels.count, id: \.self) { i in
                                    Text(lightingModels[i]).tag(i)
                                }
                            }
                            .onChange(of: lightingModel) { triggerUpdate() }

                            // Explanation of current mode
                            Group {
                                switch lightingModel {
                                case 0:
                                    Text("Constant: Shows textures as-is, ignores lighting")
                                case 1:
                                    Text("Lambert: Basic diffuse shading, no specular")
                                case 2:
                                    Text("Blinn: Diffuse + specular highlights")
                                case 3:
                                    Text("Phong: Similar to Blinn, different specular calc")
                                case 4:
                                    Text("PBR: Realistic metalness/roughness workflow")
                                default:
                                    EmptyView()
                                }
                            }
                            .font(.caption)
                            .foregroundColor(.secondary)

                            if lightingModel > 0 {  // Not Constant
                                LabeledSlider(label: "Diffuse Intensity", value: $diffuseIntensity, range: 0...2, onChange: triggerUpdate)
                            }

                            if lightingModel >= 2 && lightingModel <= 3 {  // Blinn, Phong
                                Divider()
                                Text("Specular").font(.caption).foregroundColor(.secondary)
                                LabeledSlider(label: "Specular Intensity", value: $specularIntensity, range: 0...2, onChange: triggerUpdate)
                                LabeledSlider(label: "Shininess", value: $shininess, range: 0...128, onChange: triggerUpdate)
                            }

                            if lightingModel == 4 {  // Physically Based
                                Divider()
                                Text("PBR Properties").font(.caption).foregroundColor(.secondary)
                                LabeledSlider(label: "Metalness", value: $metalness, range: 0...1, onChange: triggerUpdate)
                                LabeledSlider(label: "Roughness", value: $roughness, range: 0...1, onChange: triggerUpdate)
                            }

                            if lightingModel > 0 {
                                Divider()
                                LabeledSlider(label: "Ambient Response", value: $ambientIntensityMaterial, range: 0...1, onChange: triggerUpdate)
                            }
                        }
                        .padding(8)
                    }

                    // Camera Section
                    GroupBox("Camera") {
                        VStack(alignment: .leading, spacing: 12) {
                            Toggle("HDR (enables tone mapping controls)", isOn: $wantsHDR)
                                .onChange(of: wantsHDR) { triggerUpdate() }

                            LabeledSlider(label: "Field of View", value: $fieldOfView, range: 20...120, onChange: triggerUpdate)

                            if wantsHDR {
                                Divider()
                                Text("Tone Mapping").font(.caption).foregroundColor(.secondary)
                                LabeledSlider(label: "Exposure Offset", value: $exposureOffset, range: -5...5, onChange: triggerUpdate)
                                LabeledSlider(label: "White Point", value: $whitePoint, range: 0...2, onChange: triggerUpdate)
                                LabeledSlider(label: "Contrast", value: $contrast, range: -1...1, onChange: triggerUpdate)
                                LabeledSlider(label: "Saturation", value: $saturation, range: 0...2, onChange: triggerUpdate)

                                Divider()
                                Text("Bloom Effect (glow on bright areas)").font(.caption).foregroundColor(.secondary)
                                LabeledSlider(label: "Bloom Intensity", value: $bloomIntensity, range: 0...2, onChange: triggerUpdate)
                                LabeledSlider(label: "Bloom Threshold", value: $bloomThreshold, range: 0...2, onChange: triggerUpdate)
                                LabeledSlider(label: "Bloom Blur Radius", value: $bloomBlurRadius, range: 0...20, onChange: triggerUpdate)

                                Divider()
                                Text("Exposure Adaptation Range").font(.caption).foregroundColor(.secondary)
                                LabeledSlider(label: "Min Exposure", value: $minimumExposure, range: -15...0, onChange: triggerUpdate)
                                LabeledSlider(label: "Max Exposure", value: $maximumExposure, range: 0...15, onChange: triggerUpdate)
                            } else {
                                Text("Enable HDR for tone mapping, bloom, and exposure controls")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                    .padding(.top, 4)
                            }
                        }
                        .padding(8)
                    }

                    // Scene Section
                    GroupBox("Scene") {
                        VStack(alignment: .leading, spacing: 12) {
                            LabeledSlider(label: "Background", value: $backgroundColor, range: 0...1, onChange: triggerUpdate)
                        }
                        .padding(8)
                    }

                    // Export Config
                    GroupBox("Export Configuration") {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Copy the configuration code to use in ModelViewer.swift")
                                .font(.caption)
                                .foregroundColor(.secondary)

                            Button("Copy Configuration to Clipboard") {
                                copyConfigToClipboard()
                            }
                            .buttonStyle(.borderedProminent)

                            Button("Reset to Defaults") {
                                resetToDefaults()
                            }
                            .buttonStyle(.bordered)
                        }
                        .padding(8)
                    }
                }
                .padding()
            }
            .frame(minWidth: 350, maxWidth: 450)
        }
        .frame(minWidth: 900, minHeight: 600)
    }

    var dropZone: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(white: backgroundColor))

            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(isDragging ? Color.accentColor : Color.gray.opacity(0.5), style: StrokeStyle(lineWidth: 2, dash: [8]))

            VStack(spacing: 12) {
                Image(systemName: "cube.transparent")
                    .font(.system(size: 48))
                    .foregroundColor(.gray)
                Text("Drop 3D Model Here")
                    .font(.title2)
                    .foregroundColor(.gray)
                Text("(.obj, .usdz, .dae, .scn)")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .onDrop(of: [.fileURL], isTargeted: $isDragging) { providers in
            handleDrop(providers: providers)
        }
    }

    var smallDropZone: some View {
        HStack {
            Text("Model: \(modelURL?.lastPathComponent ?? "None")")
                .font(.caption)
                .lineLimit(1)

            Spacer()

            Button("Change") {
                selectFile()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(8)
        .background(Color.secondary.opacity(0.1))
        .cornerRadius(8)
    }

    var currentConfig: ModelViewerConfig {
        ModelViewerConfig(
            ambientIntensity: ambientIntensity,
            keyLightIntensity: keyLightIntensity,
            keyLightPosition: SCNVector3(Float(keyLightX), Float(keyLightY), Float(keyLightZ)),
            fillLightIntensity: fillLightIntensity,
            fillLightPosition: SCNVector3(Float(fillLightX), Float(fillLightY), Float(fillLightZ)),
            rimLightIntensity: rimLightIntensity,
            rimLightPosition: SCNVector3(Float(rimLightX), Float(rimLightY), Float(rimLightZ)),
            lightingModel: SCNMaterial.LightingModel(rawValue: lightingModelValue),
            diffuseIntensity: diffuseIntensity,
            specularIntensity: specularIntensity,
            ambientIntensityMaterial: ambientIntensityMaterial,
            shininess: shininess,
            metalness: metalness,
            roughness: roughness,
            wantsHDR: wantsHDR,
            exposureOffset: exposureOffset,
            whitePoint: whitePoint,
            contrast: contrast,
            saturation: saturation,
            fieldOfView: fieldOfView,
            backgroundColor: backgroundColor,
            useDefaultLighting: useDefaultLighting,
            bloomIntensity: bloomIntensity,
            bloomThreshold: bloomThreshold,
            bloomBlurRadius: bloomBlurRadius,
            minimumExposure: minimumExposure,
            maximumExposure: maximumExposure
        )
    }

    var lightingModelValue: String {
        switch lightingModel {
        case 0: return SCNMaterial.LightingModel.constant.rawValue
        case 1: return SCNMaterial.LightingModel.lambert.rawValue
        case 2: return SCNMaterial.LightingModel.blinn.rawValue
        case 3: return SCNMaterial.LightingModel.phong.rawValue
        case 4: return SCNMaterial.LightingModel.physicallyBased.rawValue
        default: return SCNMaterial.LightingModel.constant.rawValue
        }
    }

    func triggerUpdate() {
        updateTrigger = UUID()
    }

    func handleDrop(providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }

        provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, error in
            guard let data = item as? Data,
                  let url = URL(dataRepresentation: data, relativeTo: nil) else { return }

            let validExtensions = ["obj", "usdz", "dae", "scn", "ply", "stl"]
            if validExtensions.contains(url.pathExtension.lowercased()) {
                DispatchQueue.main.async {
                    self.modelURL = url
                }
            }
        }
        return true
    }

    func selectFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [
            UTType(filenameExtension: "obj")!,
            UTType(filenameExtension: "usdz")!,
            UTType(filenameExtension: "dae")!,
            UTType(filenameExtension: "scn")!
        ]
        panel.allowsMultipleSelection = false

        if panel.runModal() == .OK, let url = panel.url {
            modelURL = url
        }
    }

    func resetToDefaults() {
        ambientIntensity = 200
        keyLightIntensity = 600
        fillLightIntensity = 300
        rimLightIntensity = 200
        keyLightX = 5; keyLightY = 8; keyLightZ = 10
        fillLightX = -5; fillLightY = 3; fillLightZ = 5
        rimLightX = 0; rimLightY = 5; rimLightZ = -10
        lightingModel = 0
        diffuseIntensity = 1.0
        specularIntensity = 0.0
        ambientIntensityMaterial = 0.0
        shininess = 0.0
        metalness = 0.0
        roughness = 0.5
        wantsHDR = false
        exposureOffset = 0
        whitePoint = 1.0
        contrast = 0.0
        saturation = 1.0
        fieldOfView = 45
        backgroundColor = 0.12
        useDefaultLighting = false
        bloomIntensity = 0.0
        bloomThreshold = 1.0
        bloomBlurRadius = 4.0
        minimumExposure = -15.0
        maximumExposure = 15.0
        triggerUpdate()
    }

    func copyConfigToClipboard() {
        let config = """
        // === 3D Viewer Configuration ===
        // Generated from ModelViewerDebug

        // Lighting
        let useDefaultLighting = \(useDefaultLighting)
        let ambientIntensity: CGFloat = \(Int(ambientIntensity))
        let keyLightIntensity: CGFloat = \(Int(keyLightIntensity))
        let keyLightPosition = SCNVector3(\(keyLightX), \(keyLightY), \(keyLightZ))
        let fillLightIntensity: CGFloat = \(Int(fillLightIntensity))
        let fillLightPosition = SCNVector3(\(fillLightX), \(fillLightY), \(fillLightZ))
        let rimLightIntensity: CGFloat = \(Int(rimLightIntensity))
        let rimLightPosition = SCNVector3(\(rimLightX), \(rimLightY), \(rimLightZ))

        // Material
        let lightingModel: SCNMaterial.LightingModel = .\(lightingModels[lightingModel].lowercased().replacingOccurrences(of: " ", with: ""))
        let diffuseIntensity: CGFloat = \(String(format: "%.2f", diffuseIntensity))
        let specularIntensity: CGFloat = \(String(format: "%.2f", specularIntensity))
        let ambientIntensityMaterial: CGFloat = \(String(format: "%.2f", ambientIntensityMaterial))
        let shininess: CGFloat = \(String(format: "%.1f", shininess))
        let metalness: CGFloat = \(String(format: "%.2f", metalness))
        let roughness: CGFloat = \(String(format: "%.2f", roughness))

        // Camera
        let wantsHDR = \(wantsHDR)
        let fieldOfView: CGFloat = \(Int(fieldOfView))
        let exposureOffset: CGFloat = \(String(format: "%.2f", exposureOffset))
        let whitePoint: CGFloat = \(String(format: "%.2f", whitePoint))
        let contrast: CGFloat = \(String(format: "%.2f", contrast))
        let saturation: CGFloat = \(String(format: "%.2f", saturation))

        // HDR Bloom
        let bloomIntensity: CGFloat = \(String(format: "%.2f", bloomIntensity))
        let bloomThreshold: CGFloat = \(String(format: "%.2f", bloomThreshold))
        let bloomBlurRadius: CGFloat = \(String(format: "%.1f", bloomBlurRadius))

        // Exposure Limits
        let minimumExposure: CGFloat = \(String(format: "%.1f", minimumExposure))
        let maximumExposure: CGFloat = \(String(format: "%.1f", maximumExposure))

        // Scene
        let backgroundColor: CGFloat = \(String(format: "%.2f", backgroundColor))
        """

        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(config, forType: .string)
    }
}

// MARK: - Labeled Slider Helper

struct LabeledSlider: View {
    let label: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let onChange: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(label)
                    .font(.caption)
                Spacer()
                Text(formatValue(value))
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .monospacedDigit()
            }
            Slider(value: $value, in: range)
                .onChange(of: value) { onChange() }
        }
    }

    func formatValue(_ val: Double) -> String {
        if range.upperBound - range.lowerBound > 10 {
            return String(format: "%.0f", val)
        } else {
            return String(format: "%.2f", val)
        }
    }
}

// MARK: - Configuration Struct

struct ModelViewerConfig {
    var ambientIntensity: Double
    var keyLightIntensity: Double
    var keyLightPosition: SCNVector3
    var fillLightIntensity: Double
    var fillLightPosition: SCNVector3
    var rimLightIntensity: Double
    var rimLightPosition: SCNVector3
    var lightingModel: SCNMaterial.LightingModel
    var diffuseIntensity: Double
    var specularIntensity: Double
    var ambientIntensityMaterial: Double
    var shininess: Double
    var metalness: Double
    var roughness: Double
    var wantsHDR: Bool
    var exposureOffset: Double
    var whitePoint: Double
    var contrast: Double
    var saturation: Double
    var fieldOfView: Double
    var backgroundColor: Double
    var useDefaultLighting: Bool
    // HDR Bloom
    var bloomIntensity: Double
    var bloomThreshold: Double
    var bloomBlurRadius: Double
    // Exposure limits
    var minimumExposure: Double
    var maximumExposure: Double
}

// MARK: - Configurable Model Viewer

struct ConfigurableModelViewer: NSViewRepresentable {
    let modelURL: URL
    let config: ModelViewerConfig
    let updateTrigger: UUID

    func makeNSView(context: Context) -> SCNView {
        let scnView = SCNView()
        scnView.allowsCameraControl = true
        scnView.antialiasingMode = .multisampling4X
        scnView.defaultCameraController.interactionMode = .orbitTurntable
        scnView.defaultCameraController.inertiaEnabled = true
        scnView.defaultCameraController.inertiaFriction = 0.9

        let scene = SCNScene()
        scnView.scene = scene

        context.coordinator.scnView = scnView
        context.coordinator.loadModel(url: modelURL, config: config)

        return scnView
    }

    func updateNSView(_ nsView: SCNView, context: Context) {
        context.coordinator.applyConfig(config)

        // Check if model URL changed
        if context.coordinator.currentModelURL != modelURL {
            context.coordinator.loadModel(url: modelURL, config: config)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    class Coordinator {
        var scnView: SCNView?
        var currentModelURL: URL?
        var containerNode: SCNNode?
        var cameraNode: SCNNode?
        var ambientNode: SCNNode?
        var keyLightNode: SCNNode?
        var fillLightNode: SCNNode?
        var rimLightNode: SCNNode?

        func loadModel(url: URL, config: ModelViewerConfig) {
            guard let scnView = scnView, let scene = scnView.scene else { return }

            currentModelURL = url

            // Clear existing
            scene.rootNode.childNodes.forEach { $0.removeFromParentNode() }

            // Load model
            let asset = MDLAsset(url: url)
            asset.loadTextures()

            guard asset.count > 0 else { return }

            let loadedScene = SCNScene(mdlAsset: asset)

            containerNode = SCNNode()
            containerNode?.name = "loadedModel"

            for child in loadedScene.rootNode.childNodes {
                let cloned = child.clone()
                containerNode?.addChildNode(cloned)
            }

            scene.rootNode.addChildNode(containerNode!)

            // Center and scale
            let (min, max) = containerNode!.boundingBox
            let sizeX = max.x - min.x
            let sizeY = max.y - min.y
            let sizeZ = max.z - min.z
            let maxSize = Swift.max(sizeX, Swift.max(sizeY, sizeZ))

            guard maxSize > 0 && maxSize.isFinite else { return }

            let centerX = (min.x + max.x) / 2
            let centerY = (min.y + max.y) / 2
            let centerZ = (min.z + max.z) / 2

            containerNode?.pivot = SCNMatrix4MakeTranslation(centerX, centerY, centerZ)
            containerNode?.position = SCNVector3(0, 0, 0)

            let scale = 2.0 / maxSize
            containerNode?.scale = SCNVector3(scale, scale, scale)

            // Setup lighting
            setupLighting(scene: scene, config: config)

            // Setup camera
            cameraNode = SCNNode()
            cameraNode?.name = "cameraNode"
            cameraNode?.camera = SCNCamera()
            cameraNode?.position = SCNVector3(0, 0.5, 4)
            cameraNode?.look(at: SCNVector3(0, 0, 0))
            scene.rootNode.addChildNode(cameraNode!)
            scnView.pointOfView = cameraNode

            applyConfig(config)
        }

        func setupLighting(scene: SCNScene, config: ModelViewerConfig) {
            // Ambient
            ambientNode = SCNNode()
            ambientNode?.light = SCNLight()
            ambientNode?.light?.type = .ambient
            ambientNode?.light?.color = NSColor.white
            scene.rootNode.addChildNode(ambientNode!)

            // Key light
            keyLightNode = SCNNode()
            keyLightNode?.light = SCNLight()
            keyLightNode?.light?.type = .directional
            keyLightNode?.light?.color = NSColor.white
            keyLightNode?.light?.castsShadow = false
            scene.rootNode.addChildNode(keyLightNode!)

            // Fill light
            fillLightNode = SCNNode()
            fillLightNode?.light = SCNLight()
            fillLightNode?.light?.type = .directional
            fillLightNode?.light?.color = NSColor(white: 0.9, alpha: 1.0)
            scene.rootNode.addChildNode(fillLightNode!)

            // Rim light
            rimLightNode = SCNNode()
            rimLightNode?.light = SCNLight()
            rimLightNode?.light?.type = .directional
            rimLightNode?.light?.color = NSColor(white: 0.8, alpha: 1.0)
            scene.rootNode.addChildNode(rimLightNode!)
        }

        func applyConfig(_ config: ModelViewerConfig) {
            guard let scnView = scnView else { return }

            // Background
            scnView.backgroundColor = NSColor(calibratedWhite: config.backgroundColor, alpha: 1.0)

            // Default lighting toggle
            scnView.autoenablesDefaultLighting = config.useDefaultLighting

            // Hide custom lights if using default
            ambientNode?.isHidden = config.useDefaultLighting
            keyLightNode?.isHidden = config.useDefaultLighting
            fillLightNode?.isHidden = config.useDefaultLighting
            rimLightNode?.isHidden = config.useDefaultLighting

            // Light intensities and positions
            ambientNode?.light?.intensity = config.ambientIntensity

            keyLightNode?.light?.intensity = config.keyLightIntensity
            keyLightNode?.position = config.keyLightPosition
            keyLightNode?.look(at: SCNVector3(0, 0, 0))

            fillLightNode?.light?.intensity = config.fillLightIntensity
            fillLightNode?.position = config.fillLightPosition
            fillLightNode?.look(at: SCNVector3(0, 0, 0))

            rimLightNode?.light?.intensity = config.rimLightIntensity
            rimLightNode?.position = config.rimLightPosition
            rimLightNode?.look(at: SCNVector3(0, 0, 0))

            // Camera settings
            cameraNode?.camera?.wantsHDR = config.wantsHDR
            cameraNode?.camera?.fieldOfView = config.fieldOfView
            cameraNode?.camera?.automaticallyAdjustsZRange = true

            if config.wantsHDR {
                // HDR tone mapping controls
                cameraNode?.camera?.exposureOffset = config.exposureOffset
                cameraNode?.camera?.whitePoint = config.whitePoint
                cameraNode?.camera?.contrast = config.contrast
                cameraNode?.camera?.saturation = config.saturation

                // Bloom effect (very visible indicator that HDR is working)
                cameraNode?.camera?.bloomIntensity = config.bloomIntensity
                cameraNode?.camera?.bloomThreshold = config.bloomThreshold
                cameraNode?.camera?.bloomBlurRadius = config.bloomBlurRadius

                // Exposure adaptation
                cameraNode?.camera?.minimumExposure = config.minimumExposure
                cameraNode?.camera?.maximumExposure = config.maximumExposure
                cameraNode?.camera?.exposureAdaptationBrighteningSpeedFactor = 0.4
                cameraNode?.camera?.exposureAdaptationDarkeningSpeedFactor = 0.6
            }

            // Material settings - apply to all materials in model
            if let container = containerNode {
                applyMaterialSettings(to: container, config: config)
            }
        }

        func applyMaterialSettings(to node: SCNNode, config: ModelViewerConfig) {
            if let geometry = node.geometry {
                for material in geometry.materials {
                    material.lightingModel = config.lightingModel

                    // Diffuse - works with all lighting models except constant
                    material.diffuse.intensity = config.diffuseIntensity

                    // Specular - needs contents set for intensity to work (Blinn/Phong)
                    if config.specularIntensity > 0 && config.lightingModel != .constant && config.lightingModel != .lambert {
                        material.specular.contents = NSColor.white
                        material.specular.intensity = config.specularIntensity
                    } else {
                        material.specular.contents = nil
                    }

                    // Ambient response
                    material.ambient.intensity = config.ambientIntensityMaterial

                    // Shininess (for Blinn/Phong)
                    material.shininess = config.shininess

                    // PBR properties - use .contents not .intensity
                    if config.lightingModel == .physicallyBased {
                        material.metalness.contents = config.metalness
                        material.roughness.contents = config.roughness
                    }

                    material.isDoubleSided = true
                }
            }

            for child in node.childNodes {
                applyMaterialSettings(to: child, config: config)
            }
        }
    }
}

#Preview {
    ModelViewerDebugView()
}
