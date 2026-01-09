import SwiftUI
import SceneKit
import ModelIO
import SceneKit.ModelIO

// MARK: - Post-Processing
extension SimpleEditorViewModel {

    /// URL of the mesh to process (either generated or processed)
    var currentMeshURL: URL? {
        processedModelURL ?? generated3DModelURL
    }

    /// Update handoff progress during preloading
    func updateHandoffProgress(progress: Double, detail: String) {
        withAnimation(.spring(response: 0.2, dampingFraction: 0.8)) {
            generationStages[.handoff] = StageProgress(status: .inProgress, progress: progress, detail: detail)
        }
    }

    /// Pre-load mesh analysis in background (called immediately when generation completes)
    /// This runs the heavy Python processing AND SceneKit loading BEFORE the UI transition
    func preloadMeshAnalysis() async {
        guard let modelURL = generated3DModelURL else { return }

        print("[PostProcess] Starting mesh pre-load for: \(modelURL.lastPathComponent)")
        let startTime = Date()

        // Phase 1: Analyze mesh (0% - 30%)
        updateHandoffProgress(progress: 0.1, detail: "Analyzing...")
        let analysisResult = await runMeshProcessor(command: "analyze", inputPath: modelURL.path)

        guard let result = analysisResult,
              result["success"] as? Bool == true,
              let components = result["components"] as? [[String: Any]] else {
            print("[PostProcess] Pre-load analysis failed")
            return
        }

        // Parse components
        let parsedComponents = components.compactMap { comp -> MeshComponent? in
            guard let index = comp["index"] as? Int,
                  let vertexCount = comp["vertex_count"] as? Int,
                  let faceCount = comp["face_count"] as? Int else { return nil }

            return MeshComponent(
                index: index,
                vertexCount: vertexCount,
                faceCount: faceCount,
                boundsMin: comp["bounds_min"] as? [Double] ?? [0, 0, 0],
                boundsMax: comp["bounds_max"] as? [Double] ?? [0, 0, 0],
                center: comp["center"] as? [Double] ?? [0, 0, 0],
                size: comp["size"] as? Double ?? 0,
                isWatertight: comp["is_watertight"] as? Bool ?? false
            )
        }

        // Phase 2: Extract components (30% - 60%)
        updateHandoffProgress(progress: 0.3, detail: "Extracting...")
        let tempDir = NSTemporaryDirectory() + "mesh_components_\(UUID().uuidString)"
        let extractResult = await runMeshProcessor(
            command: "extract_all",
            inputPath: modelURL.path,
            outputPath: tempDir
        )

        var extractedFiles: [ComponentFile] = []
        if let result = extractResult,
           result["success"] as? Bool == true,
           let extractedComponents = result["components"] as? [[String: Any]] {
            extractedFiles = extractedComponents.compactMap { comp -> ComponentFile? in
                guard let index = comp["index"] as? Int,
                      let path = comp["path"] as? String else { return nil }
                return ComponentFile(index: index, path: path)
            }
        }

        let analysisElapsed = Date().timeIntervalSince(startTime)
        print("[PostProcess] Mesh analysis complete in \(String(format: "%.2f", analysisElapsed))s - \(parsedComponents.count) components")

        // Store results on main actor and compute keep/delete indices
        var computedKeepIndices: Set<Int> = []
        var computedDeleteIndices: Set<Int> = []

        await MainActor.run {
            // Only apply if we haven't transitioned yet and these are fresh results
            if currentStep != .postProcess || meshComponents.isEmpty {
                meshComponents = parsedComponents
                componentFiles = extractedFiles
                autoSortComponents()
            }
            // Capture the computed indices for preloading with materials
            computedKeepIndices = keepIndices
            computedDeleteIndices = deleteIndices
        }

        // Phase 3: Pre-load SceneKit nodes WITH MATERIALS (60% - 100%)
        updateHandoffProgress(progress: 0.6, detail: "Preparing 3D...")
        print("[PostProcess] Pre-loading SceneKit nodes with materials...")
        await MainActor.run { isPreloadingScenes = true }

        let preloadedNodes = await preloadSceneKitNodes(
            from: extractedFiles,
            keepIndices: computedKeepIndices,
            deleteIndices: computedDeleteIndices
        )

        await MainActor.run {
            preloadedComponentNodes = preloadedNodes
            isPreloadingScenes = false
        }

        updateHandoffProgress(progress: 0.95, detail: "Ready")

        let totalElapsed = Date().timeIntervalSince(startTime)
        print("[PostProcess] Total pre-load complete in \(String(format: "%.2f", totalElapsed))s - \(preloadedNodes.count) SceneKit nodes cached with materials")
        print("[PostProcess] State: componentFiles=\(componentFiles.count), preloadedNodes=\(preloadedComponentNodes.count), meshComponents=\(meshComponents.count)")
    }

    /// Pre-load SceneKit nodes from component files WITH materials pre-applied (runs on background thread)
    private func preloadSceneKitNodes(
        from files: [ComponentFile],
        keepIndices: Set<Int>,
        deleteIndices: Set<Int>
    ) async -> [Int: SCNNode] {
        // Check if there are artifacts (both keep and delete items)
        let hasArtifacts = !keepIndices.isEmpty && !deleteIndices.isEmpty

        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                var nodes: [Int: SCNNode] = [:]

                // Material constants from AppConstants (matching ComponentModelViewer)
                let clayColor = AppConstants.clayColor
                let ghostColor = AppConstants.ghostColor
                let ghostOpacity = AppConstants.ghostOpacity
                let clayRoughness = AppConstants.clayRoughness

                for file in files {
                    let url = URL(fileURLWithPath: file.path)
                    guard FileManager.default.fileExists(atPath: file.path) else { continue }

                    let asset = MDLAsset(url: url)
                    asset.loadTextures()

                    guard asset.count > 0 else { continue }

                    let loadedScene = SCNScene(mdlAsset: asset)

                    let componentNode = SCNNode()
                    componentNode.name = "component_\(file.index)"

                    // Determine if this is a ghost (discarded) item
                    let isGhost = hasArtifacts && deleteIndices.contains(file.index)

                    for child in loadedScene.rootNode.childNodes {
                        let cloned = child.clone()
                        // Apply material based on state
                        self.applyMaterialRecursively(
                            to: cloned,
                            color: isGhost ? ghostColor : clayColor,
                            isGhost: isGhost,
                            ghostOpacity: ghostOpacity,
                            roughness: clayRoughness
                        )
                        componentNode.addChildNode(cloned)
                    }

                    nodes[file.index] = componentNode
                }

                continuation.resume(returning: nodes)
            }
        }
    }

    /// Apply material recursively to a node during preload (nonisolated for background thread use)
    private nonisolated func applyMaterialRecursively(
        to node: SCNNode,
        color: NSColor,
        isGhost: Bool,
        ghostOpacity: CGFloat,
        roughness: CGFloat
    ) {
        node.geometry?.materials.forEach { material in
            material.isDoubleSided = true
            material.diffuse.contents = color
            material.fillMode = .fill
            material.lightingModel = .physicallyBased
            material.metalness.contents = 0.0
            material.roughness.contents = roughness
            material.emission.contents = NSColor.black

            if isGhost {
                material.transparency = ghostOpacity
                material.transparencyMode = .dualLayer
                material.blendMode = .alpha
                material.writesToDepthBuffer = false
            } else {
                material.transparency = 1.0
                material.transparencyMode = .default
                material.blendMode = .replace
                material.writesToDepthBuffer = true
            }
        }
        for child in node.childNodes {
            applyMaterialRecursively(to: child, color: color, isGhost: isGhost, ghostOpacity: ghostOpacity, roughness: roughness)
        }
    }

    func transitionToPostProcess() {
        print("[PostProcess] transitionToPostProcess called - currentStep was: \(currentStep)")

        // Set step directly - views have implicit animations via .animation(value: currentStep)
        // Using explicit withAnimation here conflicts with those implicit animations, causing glitches
        currentStep = .postProcess

        print("[PostProcess] transitionToPostProcess - currentStep is now: \(currentStep)")
        print("[PostProcess] Data check: componentFiles=\(componentFiles.count), preloadedNodes=\(preloadedComponentNodes.count), meshComponents=\(meshComponents.count)")

        // If preload didn't populate data (edge case), run fresh analysis
        if meshComponents.isEmpty {
            print("[PostProcess] meshComponents empty, running fresh analysis")
            Task {
                await analyzeMesh()
            }
        }
    }

    func analyzeMesh() async {
        guard let modelURL = currentMeshURL else { return }

        await MainActor.run {
            isAnalyzingMesh = true
            meshComponents.removeAll()
            keepIndices.removeAll()
            deleteIndices.removeAll()
            highlightedComponentIndex = nil
            componentFiles.removeAll()
        }

        let result = await runMeshProcessor(command: "analyze", inputPath: modelURL.path)

        await MainActor.run {
            isAnalyzingMesh = false
            if let result = result,
               result["success"] as? Bool == true,
               let components = result["components"] as? [[String: Any]] {

                meshComponents = components.compactMap { comp -> MeshComponent? in
                    guard let index = comp["index"] as? Int,
                          let vertexCount = comp["vertex_count"] as? Int,
                          let faceCount = comp["face_count"] as? Int else { return nil }

                    return MeshComponent(
                        index: index,
                        vertexCount: vertexCount,
                        faceCount: faceCount,
                        boundsMin: comp["bounds_min"] as? [Double] ?? [0, 0, 0],
                        boundsMax: comp["bounds_max"] as? [Double] ?? [0, 0, 0],
                        center: comp["center"] as? [Double] ?? [0, 0, 0],
                        size: comp["size"] as? Double ?? 0,
                        isWatertight: comp["is_watertight"] as? Bool ?? false
                    )
                }
            }
        }

        // Always extract components for visualization (even single component gets colored)
        // Note: autoSortComponents() is called inside extractComponentsForVisualization()
        // in the same MainActor block to avoid flash of gray (unsorted) components
        if !meshComponents.isEmpty {
            await extractComponentsForVisualization()
        }
    }

    func extractComponentsForVisualization() async {
        guard let modelURL = currentMeshURL else { return }

        await MainActor.run {
            isExtractingComponents = true
            componentFiles.removeAll()
        }

        let tempDir = NSTemporaryDirectory() + "mesh_components_\(UUID().uuidString)"

        let result = await runMeshProcessor(
            command: "extract_all",
            inputPath: modelURL.path,
            outputPath: tempDir
        )

        await MainActor.run {
            isExtractingComponents = false
            if let result = result,
               result["success"] as? Bool == true,
               let components = result["components"] as? [[String: Any]] {

                componentFiles = components.compactMap { comp -> ComponentFile? in
                    guard let index = comp["index"] as? Int,
                          let path = comp["path"] as? String else { return nil }
                    return ComponentFile(index: index, path: path)
                }

                // Auto-sort in same update to avoid flash of gray (unsorted) components
                autoSortComponents()
            }
        }
    }

    func exportMesh(to url: URL) async -> Bool {
        guard let modelURL = currentMeshURL else { return false }

        await MainActor.run {
            isProcessingMesh = true
        }

        let result = await runMeshProcessor(
            command: "export",
            inputPath: modelURL.path,
            outputPath: url.path,
            format: selectedExportFormat.fileExtension
        )

        await MainActor.run {
            isProcessingMesh = false
        }

        return result?["success"] as? Bool == true
    }

    // MARK: - Two-List Management

    /// Auto-sort components: main meshes (>= threshold faces) to keep, artifacts to delete
    func autoSortComponents() {
        keepIndices.removeAll()
        deleteIndices.removeAll()

        for component in meshComponents {
            if component.faceCount >= AppConstants.minimumFaceCountForMainMesh {
                keepIndices.insert(component.index)
            } else {
                deleteIndices.insert(component.index)
            }
        }
    }

    /// Move a component from delete list to keep list
    func moveToKeep(_ index: Int) {
        deleteIndices.remove(index)
        keepIndices.insert(index)
    }

    /// Move a component from keep list to delete list
    func moveToDelete(_ index: Int) {
        keepIndices.remove(index)
        deleteIndices.insert(index)
    }

    /// Highlight a component in the viewer (for click selection)
    func highlightComponent(_ index: Int?) {
        highlightedComponentIndex = index
    }

    /// Handle click on a component in the 3D viewport (toggle keep/delete)
    func handleViewportComponentClick(_ index: Int) {
        // Toggle between keep and delete states
        if keepIndices.contains(index) {
            // Can only move to delete if there's more than one item in keep
            if keepIndices.count > 1 {
                moveToDelete(index)
            }
        } else if deleteIndices.contains(index) {
            moveToKeep(index)
        }
    }

    /// Handle hover state from viewport raycasting
    /// Hover highlighting is disabled when there's only one component
    func handleViewportComponentHover(_ index: Int?) {
        // Skip hover highlighting when there's only one component
        guard componentFiles.count > 1 else {
            hoveredComponentIndex = nil
            return
        }
        hoveredComponentIndex = index
    }

    /// Check if there are pending changes (items in delete list)
    var hasPendingDeletions: Bool {
        !deleteIndices.isEmpty
    }

    /// Apply changes: delete all components in the delete list
    func applyChanges() async {
        guard hasPendingDeletions, let modelURL = currentMeshURL else { return }

        let indicesToDelete = Array(deleteIndices).sorted()
        let outputPath = NSTemporaryDirectory() + "processed_mesh_\(UUID().uuidString).obj"

        await MainActor.run {
            isProcessingMesh = true
        }

        let result = await runMeshProcessor(
            command: "delete",
            inputPath: modelURL.path,
            outputPath: outputPath,
            indices: indicesToDelete
        )

        await MainActor.run {
            isProcessingMesh = false
            if let result = result,
               result["success"] as? Bool == true,
               let outputPathStr = result["output_path"] as? String {
                processedModelURL = URL(fileURLWithPath: outputPathStr)
                highlightedComponentIndex = nil
            }
        }

        await analyzeMesh()
    }

    /// Keep only the largest component (quick action)
    func keepLargestOnly() {
        guard let largest = meshComponents.first else { return }
        keepIndices = [largest.index]
        deleteIndices = Set(meshComponents.dropFirst().map { $0.index })
    }

    /// Keep only a specific component, move all others to delete
    func keepOnlyThis(_ index: Int) {
        keepIndices = [index]
        deleteIndices = Set(meshComponents.filter { $0.index != index }.map { $0.index })
    }

    /// Isolate a component (show only this one in viewer)
    func isolateComponent(_ index: Int) {
        isolatedComponentIndex = index
        highlightedComponentIndex = index
    }

    /// Exit isolation mode (show all components)
    func exitIsolation() {
        isolatedComponentIndex = nil
    }

    /// Toggle isolation for a component
    func toggleIsolation(_ index: Int) {
        if isolatedComponentIndex == index {
            exitIsolation()
        } else {
            isolateComponent(index)
        }
    }

    func runMeshProcessor(
        command: String,
        inputPath: String,
        outputPath: String? = nil,
        indices: [Int]? = nil,
        format: String? = nil
    ) async -> [String: Any]? {
        let projectDir = PathManager.toolsProjectDirectory
        let envDir = PathManager.toolsEnvironmentDirectory
        let scriptPath = projectDir.appendingPathComponent("mesh_processor.py").path
        let venvPythonPath = envDir.appendingPathComponent(".venv/bin/python").path

        guard FileManager.default.fileExists(atPath: venvPythonPath) else {
            print("[MeshProcessor] Tools Python venv not found at \(venvPythonPath)")
            return nil
        }

        guard FileManager.default.fileExists(atPath: scriptPath) else {
            print("[MeshProcessor] mesh_processor.py not found at \(scriptPath)")
            return nil
        }

        var args = [scriptPath, command, "--input", inputPath]

        if let outputPath = outputPath {
            args.append(contentsOf: ["--output", outputPath])
        }
        if let indices = indices {
            let indicesStr = indices.map { String($0) }.joined(separator: ",")
            args.append(contentsOf: ["--indices", indicesStr])
        }
        if let format = format {
            args.append(contentsOf: ["--format", format])
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: venvPythonPath)
        process.arguments = args
        process.currentDirectoryURL = projectDir

        var env = ProcessInfo.processInfo.environment
        env["PYTHONUNBUFFERED"] = "1"
        process.environment = env

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        return await withCheckedContinuation { continuation in
            // Use termination handler for non-blocking wait
            process.terminationHandler = { [stdout, stderr] terminatedProcess in
                let outputData = stdout.fileHandleForReading.readDataToEndOfFile()
                let errorData = stderr.fileHandleForReading.readDataToEndOfFile()

                if let errorStr = String(data: errorData, encoding: .utf8), !errorStr.isEmpty {
                    print("[MeshProcessor stderr] \(errorStr)")
                }

                if let outputStr = String(data: outputData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) {
                    print("[MeshProcessor stdout] \(outputStr)")
                    if let jsonData = outputStr.data(using: .utf8),
                       let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] {
                        continuation.resume(returning: json)
                        return
                    }
                }
                continuation.resume(returning: nil)
            }

            do {
                try process.run()

                // Set up timeout using Task
                Task {
                    try? await Task.sleep(for: .seconds(AppConstants.meshProcessorTimeout))
                    if process.isRunning {
                        print("[MeshProcessor] Timeout after \(AppConstants.meshProcessorTimeout)s, terminating process")
                        process.terminate()
                    }
                }
            } catch {
                print("[MeshProcessor] Error: \(error)")
                continuation.resume(returning: nil)
            }
        }
    }
}
