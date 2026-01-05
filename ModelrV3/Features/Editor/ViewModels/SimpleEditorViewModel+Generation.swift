import SwiftUI

// MARK: - Generation
extension SimpleEditorViewModel {

    func transitionToGenerate() {
        createCompositeImage()
        checkModelsDownloaded()
        withAnimation(.easeOut(duration: 0.25)) {
            currentStep = .generate
        }
    }

    func createCompositeImage() {
        guard let sourceImage = inputImage,
              let sourceCGImage = sourceImage.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let maskImage = editableMaskImage,
              let maskCGImage = maskImage.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }

        let width = sourceCGImage.width
        let height = sourceCGImage.height
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let totalPixels = width * height

        guard let sourceContext = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ), let sourceData = sourceContext.data else { return }

        sourceContext.draw(sourceCGImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        guard let maskContext = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ), let maskData = maskContext.data else { return }

        maskContext.draw(maskCGImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        guard let outputContext = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ), let outputData = outputContext.data else { return }

        let sourcePixels = sourceData.bindMemory(to: UInt32.self, capacity: totalPixels)
        let maskPixels = maskData.bindMemory(to: UInt8.self, capacity: totalPixels * 4)
        let outputPixels = outputData.bindMemory(to: UInt32.self, capacity: totalPixels)

        let chunkSize = 65536
        let chunks = (totalPixels + chunkSize - 1) / chunkSize

        DispatchQueue.concurrentPerform(iterations: chunks) { chunk in
            let start = chunk * chunkSize
            let end = min(start + chunkSize, totalPixels)

            for i in start..<end {
                let maskValue = maskPixels[i * 4]
                if maskValue > 0 {
                    let sourceVal = sourcePixels[i]
                    outputPixels[i] = (sourceVal & 0x00FFFFFF) | 0xFF000000
                } else {
                    outputPixels[i] = 0
                }
            }
        }

        guard let finalImage = outputContext.makeImage() else { return }
        compositeImage = NSImage(cgImage: finalImage, size: NSSize(width: width, height: height))
    }

    func generate3D() {
        guard let composite = compositeImage else { return }

        let tempImagePath = NSTemporaryDirectory() + "composite_\(UUID().uuidString).png"
        if let tiff = composite.tiffRepresentation,
           let bitmap = NSBitmapImageRep(data: tiff),
           let png = bitmap.representation(using: .png, properties: [:]) {
            do {
                try png.write(to: URL(fileURLWithPath: tempImagePath))
            } catch {
                print("[Generation] Failed to write composite image: \(error)")
            }
        }

        let tempMaskPath: String
        if let maskImage = editableMaskImage {
            tempMaskPath = NSTemporaryDirectory() + "mask_\(UUID().uuidString).png"
            if let tiff = maskImage.tiffRepresentation,
               let bitmap = NSBitmapImageRep(data: tiff),
               let png = bitmap.representation(using: .png, properties: [:]) {
                do {
                    try png.write(to: URL(fileURLWithPath: tempMaskPath))
                } catch {
                    print("[Generation] Failed to write mask image: \(error)")
                }
            }
        } else {
            tempMaskPath = ""
        }

        isGenerating = true
        generationStartTime = Date()
        generationStages = [:]

        Task {
            await env.generate3DModel(
                imagePath: tempImagePath,
                maskPath: tempMaskPath,
                steps: Int(customSteps),
                resolution: Int(customResolution),
                modelVariant: selectedPreset.modelVariant,
                progress: { [weak self] status in
                    Task { @MainActor in
                        self?.generationStatus = status
                        self?.updateGenerationStages(status: status)
                    }
                },
                completion: { [weak self] result in
                    Task { @MainActor in
                        self?.isGenerating = false
                        switch result {
                        case .success(let modelURL):
                            self?.generated3DModelURL = modelURL
                            if let startTime = self?.generationStartTime {
                                self?.generationDuration = Date().timeIntervalSince(startTime)
                            }
                            self?.markAllStagesCompleted()
                            self?.checkLargeModelDownloaded()
                        case .failure(let error):
                            print("[Gen] Error: \(error)")
                        }
                    }
                }
            )
        }
    }

    func stopGeneration() {
        env.cancelGeneration()
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
