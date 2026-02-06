import Foundation

// MARK: - Modify Extension (Step 7)
extension SimpleEditorViewModel {

    /// Get the current mesh for modification (prioritizes processed > generated)
    var currentMeshForModify: URL? {
        processedModelURL ?? generated3DModelURL
    }

    /// Transition to modify step
    func transitionToModify() {
        // CRITICAL: Restore custom color if not set (back then forward navigation)
        if customModelColor == nil {
            loadDominantColorFromMetadata()
        }

        withStandardSpring {
            currentStep = .modify
            visitedSteps.insert(.modify)
        }
    }

    /// Apply voxelization
    func applyVoxelization() async {
        guard voxelResolution > 0, let meshURL = currentMeshForModify else {
            await MainActor.run {
                modifiedModelURL = nil
                isModifyingMesh = false
            }
            return
        }

        let outputPath = NSTemporaryDirectory() + "voxelized_\(UUID().uuidString).obj"

        await MainActor.run { isModifyingMesh = true }

        // Check for early cancellation
        guard !Task.isCancelled else {
            await MainActor.run { isModifyingMesh = false }
            return
        }

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

                // Track face counts
                if let faces = result["faces"] as? Int {
                    modifiedFaceCount = faces
                }

                ErrorReporter.info("Voxelization complete: \(path)", subsystem: .modify)
            } else if let error = result?["error"] as? String {
                ErrorReporter.error("Voxelization failed: \(error)", subsystem: .modify)
            }
        }
    }

    /// Apply low poly decimation
    func applyLowPoly() async {
        guard lowPolyReduction > 0, let meshURL = currentMeshForModify else {
            await MainActor.run {
                modifiedModelURL = nil
                isModifyingMesh = false
            }
            return
        }

        let outputPath = NSTemporaryDirectory() + "lowpoly_\(UUID().uuidString).obj"

        await MainActor.run { isModifyingMesh = true }

        // Check for early cancellation
        guard !Task.isCancelled else {
            await MainActor.run { isModifyingMesh = false }
            return
        }

        // Apply custom curve for fine control at low values, extreme reductions at high values
        let sliderValue = Double(lowPolyReduction)
        let exponentialReduction: Double
        if sliderValue <= AppConstants.lowPolySliderMidpoint {
            exponentialReduction = sliderValue * AppConstants.lowPolyFirstHalfMultiplier
        } else {
            exponentialReduction = AppConstants.lowPolySecondHalfBase +
                (sliderValue - AppConstants.lowPolySliderMidpoint) * AppConstants.lowPolySecondHalfMultiplier
        }

        let result = await runMeshModifier(
            command: "simplify",
            inputPath: meshURL.path,
            outputPath: outputPath,
            reduction: exponentialReduction
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

                // Track face counts
                if let originalFaces = result["original_faces"] as? Int {
                    originalFaceCount = originalFaces
                }
                if let finalFaces = result["final_faces"] as? Int {
                    modifiedFaceCount = finalFaces
                }

                ErrorReporter.info("Low poly complete: \(path)", subsystem: .modify)
            } else if let error = result?["error"] as? String {
                ErrorReporter.error("Low poly failed: \(error)", subsystem: .modify)
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

        ErrorReporter.debug("Running command: \(command)", subsystem: .modify)
        ErrorReporter.debug("Input: \(inputPath)", subsystem: .modify)
        ErrorReporter.debug("Output: \(outputPath)", subsystem: .modify)
        ErrorReporter.debug("Script path: \(scriptPath)", subsystem: .modify)
        ErrorReporter.debug("Python path: \(venvPythonPath)", subsystem: .modify)

        guard FileManager.default.fileExists(atPath: venvPythonPath) else {
            ErrorReporter.error("Tools Python venv not found at: \(venvPythonPath)", subsystem: .modify)
            return nil
        }

        guard FileManager.default.fileExists(atPath: scriptPath) else {
            ErrorReporter.error("mesh_processor.py not found at: \(scriptPath)", subsystem: .modify)
            return nil
        }

        guard FileManager.default.fileExists(atPath: inputPath) else {
            ErrorReporter.error("Input mesh not found at: \(inputPath)", subsystem: .modify)
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
                    ErrorReporter.debug(errorStr, subsystem: .modify)
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
                ErrorReporter.logError(error, subsystem: .modify, context: "Failed to run mesh modifier")
                continuation.resume(returning: nil)
            }
        }
    }
}
