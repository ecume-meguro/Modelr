import SwiftUI
import Combine

// MARK: - Generation
extension SimpleEditorViewModel {

    func setupGenerationObservation() {
        ServiceContainer.shared.generationService.$status
            .receive(on: DispatchQueue.main)
            .sink { [weak self] status in
                guard let self = self else { return }

                switch status {
                case .idle:
                    break
                case .preparing:
                    self.generationStatus = "Preparing..."
                case .inProgress(let stage, _):
                    self.generationStatus = stage
                    self.updateGenerationStages(status: stage)
                case .completed(let url):
                    self.isGenerating = false
                    self.generated3DModelURL = url
                    if let startTime = self.generationStartTime {
                        self.generationDuration = Date().timeIntervalSince(startTime)
                    }
                    self.markAllStagesCompleted()
                    self.checkLargeModelDownloaded()
                    // Notify coordinator that generation is complete
                    Task {
                        await ModelLoadingCoordinator.shared.onGenerationComplete(env: self.env)
                    }
                case .failed(let error):
                    self.isGenerating = false
                    print("[Gen] Error: \(error)")
                }
            }
            .store(in: &cancellables)
    }

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
            // Prepare for generation (offloads SAM if using conservative strategy)
            let coordinator = ModelLoadingCoordinator.shared
            _ = await coordinator.prepareForGeneration(env: env)

            await ServiceContainer.shared.generationService.generate(
                imagePath: tempImagePath,
                maskPath: tempMaskPath,
                steps: Int(customSteps),
                resolution: Int(customResolution),
                modelVariant: selectedPreset.modelVariant
            )
        }
    }

    func stopGeneration() {
        ServiceContainer.shared.generationService.cancel()
        isGenerating = false
        markRemainingStagesCancelled()
    }

    func updateGenerationStages(status: String) {
        if status.contains("Downloading") || status.contains("Fetching") {
            let needsDownload = (selectedPreset.usesLargeModel && !isLargeModelDownloaded) ||
                               (!selectedPreset.usesLargeModel && !isSmallModelDownloaded)
            if needsDownload {
                let info = ProgressParser.parseDetailedProgress(status)
                let progress = info.percentComplete / 100.0
                let detail = info.currentStep > 0 ? "\(info.currentStep)/\(info.totalSteps)" : "Downloading..."

                generationStages[.downloading] = StageProgress(status: .inProgress, progress: progress, detail: detail)

                // Start download monitoring if not already started
                if downloadTotalBytes == 0 {
                    // Determine the correct directory and total bytes for the monitor
                    let modelrDir = PathManager.appSupportDirectory
                    let hfCacheDir = modelrDir.appendingPathComponent("Cache/hf_cache/hub")
                    let modelCacheName = selectedPreset.usesLargeModel ? "models--tencent--Hunyuan3D-2.1" : "models--tencent--Hunyuan3D-2mini"
                    let modelCacheDir = hfCacheDir.appendingPathComponent(modelCacheName)
                    let total = selectedPreset.usesLargeModel ? DownloadConstants.hunyuanStandardModelBytes : DownloadConstants.hunyuanMiniModelBytes

                    downloadMonitor.startMonitoring(directory: modelCacheDir, totalBytes: Int64(total)) { [weak self] (monitor: DownloadMonitor) in
                        guard let self = self else { return }
                        Task { @MainActor in
                            self.downloadedBytes = monitor.downloadedBytes
                            self.downloadTotalBytes = monitor.downloadTotalBytes
                            self.downloadSpeed = monitor.downloadSpeed
                            self.downloadTimeRemaining = monitor.downloadTimeRemaining
                        }
                    }
                }
            }
        } else if status.contains("Extracting") {
            if generationStages[.downloading] != nil {
                generationStages[.downloading] = StageProgress(status: .completed, progress: 1.0, detail: "")
                // Stop download monitoring (handled by monitor task completion or reset)
            }
            generationStages[.extracting] = StageProgress(status: .inProgress, progress: 0, detail: "")
        } else if status.contains("Loading") {
            markPreviousStagesCompleted(before: .loading)
            generationStages[.extracting] = StageProgress(status: .completed, progress: 1.0, detail: "")
            generationStages[.loading] = StageProgress(status: .inProgress, progress: 0, detail: "")
        } else if status.contains("Diffusion Sampling") || status.contains("Generating 3D shape") {
            markPreviousStagesCompleted(before: .diffusion)
            let info = ProgressParser.parseDetailedProgress(status)
            let detail = info.totalSteps > 0 ? "\(info.currentStep)/\(info.totalSteps)" : ""
            generationStages[.diffusion] = StageProgress(status: .inProgress, progress: info.percentComplete / 100.0, detail: detail)
        } else if status.contains("Volume Decoding") {
            markPreviousStagesCompleted(before: .volumeDecoding)
            generationStages[.diffusion] = StageProgress(status: .completed, progress: 1.0, detail: "")
            let info = ProgressParser.parseDetailedProgress(status)
            let detail = info.totalSteps > 0 ? "\(info.currentStep)/\(info.totalSteps)" : ""
            generationStages[.volumeDecoding] = StageProgress(status: .inProgress, progress: info.percentComplete / 100.0, detail: detail)
        } else if status.contains("Saving") {
            markPreviousStagesCompleted(before: .saving)
            generationStages[.volumeDecoding] = StageProgress(status: .completed, progress: 1.0, detail: "")
            generationStages[.saving] = StageProgress(status: .inProgress, progress: 0, detail: "")
        }
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

    // MARK: - Download Monitoring During Generation
    // This section is now managed by the DownloadMonitor struct in Core/Services/
    // The old static properties and functions are no longer needed.
}
