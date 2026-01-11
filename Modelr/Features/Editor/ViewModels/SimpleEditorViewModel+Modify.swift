import Foundation

// MARK: - Modify Extension (Step 7)
extension SimpleEditorViewModel {

    /// Get the current mesh for modification (prioritizes processed > generated)
    var currentMeshForModify: URL? {
        processedModelURL ?? generated3DModelURL
    }

    /// Apply voxelization
    func applyVoxelization() async {
        guard voxelResolution > 0, let meshURL = currentMeshForModify else {
            await MainActor.run {
                modifiedModelURL = nil
            }
            return
        }

        let outputPath = NSTemporaryDirectory() + "voxelized_\(UUID().uuidString).obj"

        await MainActor.run { isModifyingMesh = true }

        let result = await runMeshModifier(
            command: "voxelize",
            inputPath: meshURL.path,
            outputPath: outputPath,
            pitch: Double(voxelResolution)
        )

        await MainActor.run {
            isModifyingMesh = false
            if let result = result,
               result["success"] as? Bool == true,
               let path = result["output_path"] as? String {
                modifiedModelURL = URL(fileURLWithPath: path)

                // CRITICAL: Clear component data to force ModelViewerContainer fallback
                componentFiles.removeAll()
                preloadedComponentNodes.removeAll()

                print("[Modify] Voxelization complete: \(path)")
            } else if let error = result?["error"] as? String {
                print("[Modify] Voxelization failed: \(error)")
            }
        }
    }

    /// Apply low poly decimation
    func applyLowPoly() async {
        guard lowPolyReduction > 0, let meshURL = currentMeshForModify else {
            await MainActor.run {
                modifiedModelURL = nil
            }
            return
        }

        let outputPath = NSTemporaryDirectory() + "lowpoly_\(UUID().uuidString).obj"

        await MainActor.run { isModifyingMesh = true }

        let result = await runMeshModifier(
            command: "simplify",
            inputPath: meshURL.path,
            outputPath: outputPath,
            reduction: Double(lowPolyReduction)
        )

        await MainActor.run {
            isModifyingMesh = false
            if let result = result,
               result["success"] as? Bool == true,
               let path = result["output_path"] as? String {
                modifiedModelURL = URL(fileURLWithPath: path)

                // CRITICAL: Clear component data to force ModelViewerContainer fallback
                componentFiles.removeAll()
                preloadedComponentNodes.removeAll()

                print("[Modify] Low poly complete: \(path)")
            } else if let error = result?["error"] as? String {
                print("[Modify] Low poly failed: \(error)")
            }
        }
    }

    /// Run mesh modification command
    private func runMeshModifier(
        command: String,
        inputPath: String,
        outputPath: String,
        pitch: Double? = nil,
        reduction: Double? = nil
    ) async -> [String: Any]? {
        let projectDir = PathManager.toolsProjectDirectory
        let envDir = PathManager.toolsEnvironmentDirectory
        let scriptPath = projectDir.appendingPathComponent("mesh_processor.py").path
        let venvPythonPath = envDir.appendingPathComponent(".venv/bin/python").path

        print("[MeshModifier] Running command: \(command)")
        print("[MeshModifier] Input: \(inputPath)")
        print("[MeshModifier] Output: \(outputPath)")
        print("[MeshModifier] Script path: \(scriptPath)")
        print("[MeshModifier] Python path: \(venvPythonPath)")

        guard FileManager.default.fileExists(atPath: venvPythonPath) else {
            print("[MeshModifier] Tools Python venv not found at: \(venvPythonPath)")
            return nil
        }

        guard FileManager.default.fileExists(atPath: scriptPath) else {
            print("[MeshModifier] mesh_processor.py not found at: \(scriptPath)")
            return nil
        }

        guard FileManager.default.fileExists(atPath: inputPath) else {
            print("[MeshModifier] Input mesh not found at: \(inputPath)")
            return nil
        }

        var args = [scriptPath, command, "--input", inputPath, "--output", outputPath]

        if let pitch = pitch {
            args.append(contentsOf: ["--pitch", String(pitch)])
        }
        if let reduction = reduction {
            args.append(contentsOf: ["--reduction", String(reduction)])
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
            process.terminationHandler = { [stdout, stderr] terminatedProcess in
                let outputData = stdout.fileHandleForReading.readDataToEndOfFile()
                let errorData = stderr.fileHandleForReading.readDataToEndOfFile()

                if let errorStr = String(data: errorData, encoding: .utf8), !errorStr.isEmpty {
                    print("[MeshModifier stderr] \(errorStr)")
                }

                if let outputStr = String(data: outputData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) {
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
            } catch {
                print("[MeshModifier] Failed to run process: \(error)")
                continuation.resume(returning: nil)
            }
        }
    }
}
