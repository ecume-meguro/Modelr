import SwiftUI

// MARK: - Post-Processing
extension SimpleEditorViewModel {

    /// URL of the mesh to process (either generated or processed)
    var currentMeshURL: URL? {
        processedModelURL ?? generated3DModelURL
    }

    func transitionToPostProcess() {
        withAnimation(.easeOut(duration: 0.25)) {
            currentStep = .postProcess
        }
        Task {
            await analyzeMesh()
        }
    }

    func analyzeMesh() async {
        guard let modelURL = currentMeshURL else { return }

        await MainActor.run {
            isAnalyzingMesh = true
            meshComponents.removeAll()
            selectedComponentIndices.removeAll()
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
            }
        }
    }

    func deleteSelectedComponents() async {
        guard !selectedComponentIndices.isEmpty,
              let modelURL = currentMeshURL else { return }

        let indicesToDelete = selectedComponentIndices.sorted()
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
                selectedComponentIndices.removeAll()
            }
        }

        await analyzeMesh()
    }

    func keepLargestComponent() async {
        await keepLargestComponents(count: 1)
    }

    func keepLargestComponents(count: Int) async {
        guard let modelURL = currentMeshURL else { return }

        let outputPath = NSTemporaryDirectory() + "processed_mesh_\(UUID().uuidString).obj"

        await MainActor.run {
            isProcessingMesh = true
        }

        // Delete all components except the first `count` (they're already sorted by size)
        let indicesToDelete = Array(count..<meshComponents.count)

        let result: [String: Any]?
        if indicesToDelete.isEmpty {
            // Nothing to delete
            await MainActor.run { isProcessingMesh = false }
            return
        } else {
            result = await runMeshProcessor(
                command: "delete",
                inputPath: modelURL.path,
                outputPath: outputPath,
                indices: indicesToDelete
            )
        }

        await MainActor.run {
            isProcessingMesh = false
            if let result = result,
               result["success"] as? Bool == true,
               let outputPathStr = result["output_path"] as? String {
                processedModelURL = URL(fileURLWithPath: outputPathStr)
                selectedComponentIndices.removeAll()
            }
        }

        await analyzeMesh()
    }

    func keepSelectedComponents() async {
        guard !selectedComponentIndices.isEmpty,
              let modelURL = currentMeshURL else { return }

        // Delete everything NOT selected
        let indicesToDelete = meshComponents.map { $0.index }.filter { !selectedComponentIndices.contains($0) }

        guard !indicesToDelete.isEmpty else { return }

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
                selectedComponentIndices.removeAll()
            }
        }

        await analyzeMesh()
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

    func toggleComponentSelection(_ index: Int) {
        if selectedComponentIndices.contains(index) {
            selectedComponentIndices.remove(index)
        } else {
            selectedComponentIndices.insert(index)
        }
    }

    func selectAllComponents() {
        selectedComponentIndices = Set(meshComponents.map { $0.index })
    }

    func deselectAllComponents() {
        selectedComponentIndices.removeAll()
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

        do {
            try process.run()
            process.waitUntilExit()

            let outputData = stdout.fileHandleForReading.readDataToEndOfFile()
            let errorData = stderr.fileHandleForReading.readDataToEndOfFile()

            if let errorStr = String(data: errorData, encoding: .utf8), !errorStr.isEmpty {
                print("[MeshProcessor stderr] \(errorStr)")
            }

            if let outputStr = String(data: outputData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) {
                print("[MeshProcessor stdout] \(outputStr)")
                if let jsonData = outputStr.data(using: .utf8),
                   let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] {
                    return json
                }
            }
        } catch {
            print("[MeshProcessor] Error: \(error)")
        }

        return nil
    }
}
