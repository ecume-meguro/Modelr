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
                case .inProgress(let stage, let percent):
                    self.generationStatus = stage
                    self.updateGenerationStages(status: stage, percent: percent)
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

    func updateGenerationStages(status: String, percent: Double = 0) {
        // Extract step info from status string (handles formats like "Stage (5/25)" or "Stage: 5/25")
        let stepDetail = extractStepDetail(from: status)

        if status.contains("Downloading") || status.contains("Fetching") {
            let needsDownload = (selectedPreset.usesLargeModel && !isLargeModelDownloaded) ||
                               (!selectedPreset.usesLargeModel && !isSmallModelDownloaded)
            if needsDownload {
                let info = ProgressParser.parseDetailedProgress(status)
                let progress = info.percentComplete / 100.0
                let detail = info.currentStep > 0 ? "\(info.currentStep)/\(info.totalSteps)" : "Downloading..."

                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                    generationStages[.downloading] = StageProgress(status: .inProgress, progress: progress, detail: detail)
                }

                // Start download monitoring if not already started
                if downloadTotalBytes == 0 {
                    // Determine the correct directory and total bytes for the monitor
                    let modelrDir = PathManager.appSupportDirectory
                    let hfCacheDir = modelrDir.appendingPathComponent("Cache/hf_cache/hub")
                    let modelCacheName = selectedPreset.usesLargeModel ? "models--tencent--Hunyuan3D-2.1" : "models--tencent--Hunyuan3D-2mini"
                    let modelCacheDir = hfCacheDir.appendingPathComponent(modelCacheName)
                    let total = selectedPreset.usesLargeModel ? AppConstants.hunyuanStandardModelBytes : AppConstants.hunyuanMiniModelBytes

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
            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                if generationStages[.downloading] != nil {
                    generationStages[.downloading] = StageProgress(status: .completed, progress: 1.0, detail: "")
                }
                generationStages[.extracting] = StageProgress(status: .inProgress, progress: 0, detail: "")
            }
        } else if status.contains("Loading") && !status.contains("Volume") {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                markPreviousStagesCompleted(before: .loading)
                generationStages[.extracting] = StageProgress(status: .completed, progress: 1.0, detail: "")
                generationStages[.loading] = StageProgress(status: .inProgress, progress: 0, detail: "")
            }
        } else if status.contains("Volume Decoding") || status.contains("volume_decoding") || status.contains("Decoding volume") {
            // Check for volume decoding BEFORE diffusion to handle transitions properly
            let info = ProgressParser.parseDetailedProgress(status)
            // For volume decoding, use step detail if available, otherwise extract any detail text from status
            var detail = stepDetail
            if detail.isEmpty && info.totalSteps > 0 {
                detail = "\(info.currentStep)/\(info.totalSteps)"
            } else if detail.isEmpty {
                // Try to extract detail like "Extracting mesh..." from the status
                detail = extractDetailText(from: status)
            }
            // Use passed percent (from GenerationService) - it's already 0-1 scale
            let progressValue = percent > 0 ? percent : info.percentComplete / 100.0
            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                markPreviousStagesCompleted(before: .volumeDecoding)
                generationStages[.diffusion] = StageProgress(status: .completed, progress: 1.0, detail: "")
                generationStages[.volumeDecoding] = StageProgress(status: .inProgress, progress: progressValue, detail: detail)
            }
        } else if status.contains("Diffusion Sampling") || status.contains("Generating 3D shape") || status.contains("diffusion") {
            let info = ProgressParser.parseDetailedProgress(status)
            let detail = stepDetail.isEmpty ? (info.totalSteps > 0 ? "\(info.currentStep)/\(info.totalSteps)" : "") : stepDetail
            // Use passed percent (from GenerationService) - it's already 0-1 scale
            let progressValue = percent > 0 ? percent : info.percentComplete / 100.0
            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                markPreviousStagesCompleted(before: .diffusion)
                generationStages[.diffusion] = StageProgress(status: .inProgress, progress: progressValue, detail: detail)
            }
        } else if status.contains("Exporting") || status.contains("export") {
            // Transition from diffusion to saving when exporting starts
            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                markPreviousStagesCompleted(before: .saving)
                generationStages[.diffusion] = StageProgress(status: .completed, progress: 1.0, detail: "")
                generationStages[.volumeDecoding] = StageProgress(status: .completed, progress: 1.0, detail: "")
                generationStages[.saving] = StageProgress(status: .inProgress, progress: 0, detail: "")
            }
        } else if status.contains("PROGRESS:") {
            // Handle progress from persistent server (format: "PROGRESS:X% - detail")
            let info = ProgressParser.parseDetailedProgress(status)
            let progress = info.percentComplete / 100.0
            let detail = stepDetail

            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                // Determine stage based on progress value
                if progress < 0.85 {
                    // Still in diffusion phase
                    markPreviousStagesCompleted(before: .diffusion)
                    generationStages[.diffusion] = StageProgress(status: .inProgress, progress: progress, detail: detail)
                } else if progress < 0.95 {
                    // Volume decoding / exporting phase
                    markPreviousStagesCompleted(before: .volumeDecoding)
                    generationStages[.diffusion] = StageProgress(status: .completed, progress: 1.0, detail: "")
                    generationStages[.volumeDecoding] = StageProgress(status: .inProgress, progress: (progress - 0.85) / 0.1, detail: "")
                }
            }
        } else if status.contains("Saving") {
            let detail = extractDetailText(from: status)
            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                markPreviousStagesCompleted(before: .saving)
                generationStages[.volumeDecoding] = StageProgress(status: .completed, progress: 1.0, detail: "")
                generationStages[.saving] = StageProgress(status: .inProgress, progress: 0, detail: detail)
            }
        }
    }

    /// Extract step detail from status string (handles formats like "Stage (5/25)" or "5/25")
    private func extractStepDetail(from status: String) -> String {
        // Try to find step counts in parentheses first (e.g., "Diffusion Sampling (5/25)")
        if let parenMatch = status.range(of: #"\((\d+)/(\d+)\)"#, options: .regularExpression) {
            let stepStr = String(status[parenMatch])
            return stepStr.trimmingCharacters(in: CharacterSet(charactersIn: "()"))
        }
        // Fall back to ProgressParser
        if let steps = ProgressParser.extractSteps(status) {
            return "\(steps.current)/\(steps.total)"
        }
        return ""
    }

    /// Extract non-numeric detail text from status (e.g., "Extracting mesh..." from "Volume Decoding (Extracting mesh...)")
    private func extractDetailText(from status: String) -> String {
        // Try to find text in parentheses that isn't a step count
        if let parenMatch = status.range(of: #"\(([^)]+)\)"#, options: .regularExpression) {
            let content = String(status[parenMatch]).trimmingCharacters(in: CharacterSet(charactersIn: "()"))
            // Skip if it looks like a step count
            if content.range(of: #"^\d+/\d+$"#, options: .regularExpression) == nil {
                return content
            }
        }
        return ""
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
