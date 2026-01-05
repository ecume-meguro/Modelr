import SwiftUI

// MARK: - Generation
extension SimpleEditorViewModel {

    func transitionToGenerate() {
        // If we are coming directly from segment step, we might not have initialized editableMaskImage yet
        if editableMaskImage == nil {
            editableMaskImage = mergeAllSelectedMasks()
        }
        
        createCompositeImage()
        checkModelsDownloaded()
        withAnimation(.easeOut(duration: 0.25)) {
            currentStep = .generate
        }
    }

    func createCompositeImage() {
        guard let sourceImage = inputImage else { return }
        
        // Use editableMaskImage if available, otherwise try to merge current segmentations
        let maskToUse = editableMaskImage ?? mergeAllSelectedMasks()
        
        guard let mask = maskToUse else {
            print("[Generation] Warning: No mask available for composite")
            return
        }
        
        compositeImage = ImageService.shared.createCompositeImage(source: sourceImage, mask: mask)
    }

    func generate3D() {
        guard let composite = compositeImage,
              let mask = editableMaskImage else { return }

        // Use the centralized ImageService to convert images to PNG, preserving alpha
        guard let tempImagePath = ImageService.shared.convertToPNG(image: composite, originalName: "composite"),
              let tempMaskPath = ImageService.shared.convertToPNG(image: mask, originalName: "mask") else {
            print("[Generation] Failed to create temporary images for processing")
            return
        }

        print("[Generation] Composite image: \(tempImagePath)")
        print("[Generation] Mask image: \(tempMaskPath)")

        isGenerating = true
        generationStartTime = Date()
        generationStages = [:]

        Task {
            await GenerationService.shared.generate(
                imagePath: tempImagePath,
                maskPath: tempMaskPath,
                steps: Int(customSteps),
                resolution: Int(customResolution),
                modelVariant: selectedPreset.modelVariant
            )
            
            // Sync status from service
            if case .completed(let url) = GenerationService.shared.status {
                self.isGenerating = false
                self.generated3DModelURL = url
                if let startTime = self.generationStartTime {
                    self.generationDuration = Date().timeIntervalSince(startTime)
                }
                self.markAllStagesCompleted()
                self.checkLargeModelDownloaded()
            } else if case .inProgress(let stage, _) = GenerationService.shared.status {
                self.generationStatus = stage
                // Map the simple status to the complex stages for SimpleEditorView
                self.updateGenerationStages(status: stage)
            } else if case .failed(let error) = GenerationService.shared.status {
                self.isGenerating = false
                print("[Gen] Error: \(error)")
            }
        }
    }

    func stopGeneration() {
        GenerationService.shared.cancel()
        isGenerating = false
        markRemainingStagesCancelled()
    }

    func updateGenerationStages(status: String) {
        if status.contains("Downloading") || status.contains("Fetching") {
            let needsDownload = (selectedPreset.usesLargeModel && !isLargeModelDownloaded) ||
                               (!selectedPreset.usesLargeModel && !isSmallModelDownloaded)
            if needsDownload {
                let (progress, detail) = parseDownloadProgress(status)
                generationStages[.downloading] = StageProgress(status: .inProgress, progress: progress, detail: detail)

                // Start download monitoring if not already started
                if downloadTotalBytes == 0 {
                    startGenerationDownloadMonitoring()
                }
            }
        } else if status.contains("Extracting") {
            if generationStages[.downloading] != nil {
                generationStages[.downloading] = StageProgress(status: .completed, progress: 1.0, detail: "")
                // Stop download monitoring
                stopGenerationDownloadMonitoring()
            }
            generationStages[.extracting] = StageProgress(status: .inProgress, progress: 0, detail: "")
        } else if status.contains("Loading") {
            markPreviousStagesCompleted(before: .loading)
            generationStages[.extracting] = StageProgress(status: .completed, progress: 1.0, detail: "")
            generationStages[.loading] = StageProgress(status: .inProgress, progress: 0, detail: "")
        } else if status.contains("Diffusion Sampling") {
            markPreviousStagesCompleted(before: .diffusion)
            let (progress, detail) = parseProgressString(status)
            generationStages[.diffusion] = StageProgress(status: .inProgress, progress: progress, detail: detail)
        } else if status.contains("Volume Decoding") {
            markPreviousStagesCompleted(before: .volumeDecoding)
            generationStages[.diffusion] = StageProgress(status: .completed, progress: 1.0, detail: "")
            let (progress, detail) = parseProgressString(status)
            generationStages[.volumeDecoding] = StageProgress(status: .inProgress, progress: progress, detail: detail)
        } else if status.contains("Saving") {
            markPreviousStagesCompleted(before: .saving)
            generationStages[.volumeDecoding] = StageProgress(status: .completed, progress: 1.0, detail: "")
            generationStages[.saving] = StageProgress(status: .inProgress, progress: 0, detail: "")
        }
    }

    func parseDownloadProgress(_ status: String) -> (Double, String) {
        var progress: Double = 0
        var detail = ""

        if let percentRange = status.range(of: #"(\d+)%"#, options: .regularExpression) {
            let percentStr = status[percentRange].dropLast()
            if let percent = Double(percentStr) {
                progress = percent / 100.0
            }
        }

        if let filesRange = status.range(of: #"(\d+)/(\d+)"#, options: .regularExpression) {
            detail = String(status[filesRange])
        } else if status.contains("files") {
            detail = "Downloading..."
        }

        return (progress, detail)
    }

    func markPreviousStagesCompleted(before stage: GenerationStage) {
        let allStages = GenerationStage.allCases
        guard let targetIndex = allStages.firstIndex(of: stage) else { return }

        for i in 0..<targetIndex {
            let prevStage = allStages[i]
            if generationStages[prevStage]?.status != .completed {
                generationStages[prevStage] = StageProgress(status: .completed, progress: 1.0, detail: "")
            }
        }
    }

    func markAllStagesCompleted() {
        for stage in GenerationStage.allCases {
            generationStages[stage] = StageProgress(status: .completed, progress: 1.0, detail: "")
        }
    }

    func markRemainingStagesCancelled() {
        for stage in GenerationStage.allCases {
            if generationStages[stage]?.status != .completed {
                generationStages[stage] = StageProgress(status: .cancelled, progress: 0, detail: "")
            }
        }
    }

    func parseProgressString(_ status: String) -> (Double, String) {
        var progress: Double = 0
        var detail = ""

        if let percentRange = status.range(of: #"(\d+)%"#, options: .regularExpression) {
            let percentStr = status[percentRange].dropLast()
            if let percent = Double(percentStr) {
                progress = percent / 100.0
            }
        }

        if let stepRange = status.range(of: #"\d+/\d+"#, options: .regularExpression) {
            detail = String(status[stepRange])
        }

        return (progress, detail)
    }

    // MARK: - Download Monitoring During Generation

    private static var generationDownloadMonitorTask: Task<Void, Never>?

    func startGenerationDownloadMonitoring() {
        let fm = FileManager.default
        guard let appSupportDir = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return }

        let hunyuanDir = appSupportDir.appendingPathComponent("ModelrV3/Hunyuan3D")
        let hfCacheDir = hunyuanDir.appendingPathComponent("hf_cache")

        // Determine which model is being downloaded
        let modelCacheName = selectedPreset.usesLargeModel ? "models--tencent--Hunyuan3D-2.1" : "models--tencent--Hunyuan3D-2mini"
        let modelCacheDir = hfCacheDir.appendingPathComponent(modelCacheName)

        // Set total bytes based on model
        downloadTotalBytes = selectedPreset.usesLargeModel ? 7_400_000_000 : 7_200_000_000
        resetDownloadProgress()
        downloadTotalBytes = selectedPreset.usesLargeModel ? 7_400_000_000 : 7_200_000_000

        Self.generationDownloadMonitorTask = Task {
            while !Task.isCancelled {
                let size = await getGenerationDirectorySize(modelCacheDir)
                let total = downloadTotalBytes

                updateDownloadProgress(downloaded: size, total: total)

                if size >= total {
                    break
                }

                try? await Task.sleep(nanoseconds: 500_000_000)
            }
        }
    }

    func stopGenerationDownloadMonitoring() {
        Self.generationDownloadMonitorTask?.cancel()
        Self.generationDownloadMonitorTask = nil
        resetDownloadProgress()
    }

    private func getGenerationDirectorySize(_ url: URL) async -> Int64 {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let process = Process()
                let pipe = Pipe()

                process.executableURL = URL(fileURLWithPath: "/usr/bin/du")
                process.arguments = ["-sk", url.path]
                process.standardOutput = pipe
                process.standardError = nil

                do {
                    try process.run()
                    process.waitUntilExit()

                    let data = pipe.fileHandleForReading.readDataToEndOfFile()
                    if let output = String(data: data, encoding: .utf8),
                       let sizeStr = output.split(separator: "\t").first,
                       let sizeKB = Int64(sizeStr) {
                        continuation.resume(returning: sizeKB * 1024)
                    } else {
                        continuation.resume(returning: 0)
                    }
                } catch {
                    continuation.resume(returning: 0)
                }
            }
        }
    }
}
