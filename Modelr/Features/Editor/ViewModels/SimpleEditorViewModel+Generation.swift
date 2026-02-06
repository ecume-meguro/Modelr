import SwiftUI
import Combine
import os.log

// MARK: - Generation
extension SimpleEditorViewModel {

    /// Get or set the handoff task (stored via objc_setAssociatedObject for extension compatibility)
    /// Uses the key from the main class to ensure deinit can access and cancel it
    private var handoffTask: Task<Void, Never>? {
        get {
            objc_getAssociatedObject(self, &Self.handoffTaskKeyStorage) as? Task<Void, Never>
        }
        set {
            objc_setAssociatedObject(self, &Self.handoffTaskKeyStorage, newValue, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        }
    }

    func setupGenerationObservation() {
        ServiceContainer.shared.generationService.$status
            .receive(on: DispatchQueue.main)
            .sink { [weak self] status in
                guard let self = self else { return }

                // CRITICAL: Filter by projectId to prevent cross-talk between projects
                if let statusProjectId = status.projectId, statusProjectId != self.projectId {
                    // This status update is for a different project, ignore it
                    return
                }

                switch status {
                case .idle:
                    break
                case .preparing(let projectId):
                    guard projectId == self.projectId else { return }
                    self.generationStatus = "Preparing..."
                case .inProgress(let projectId, let stage, let percent):
                    guard projectId == self.projectId else { return }
                    self.generationStatus = stage
                    self.updateGenerationStages(status: stage, percent: percent)
                case .completed(let projectId, let url):
                    guard projectId == self.projectId else { return }
                    // IMPORTANT: Set handoff stage FIRST, before changing isGenerating/URL
                    // This ensures isInHandoff is true when SwiftUI re-renders, preventing
                    // a flash of "Generation Complete" before handoff progress shows
                    self.markPreviousStagesCompleted(before: .handoff)
                    self.generationStages[.saving] = StageProgress(status: .completed, progress: 1.0, detail: "")
                    self.generationStages[.handoff] = StageProgress(status: .inProgress, progress: 0, detail: "Analyzing...")

                    // Now safe to update these - isInHandoff is already true
                    self.isGenerating = false
                    self.generated3DModelURL = url
                    if let startTime = self.generationStartTime {
                        self.generationDuration = Date().timeIntervalSince(startTime)
                    }
                    self.checkModelsDownloaded()

                    // Regenerate 3D model preview thumbnail in background
                    if let projectId = self.projectId {
                        ThumbnailCache.shared.regenerateModelPreview(for: projectId)
                    }
                    // Notify coordinator that generation is complete
                    Task { [weak self] in
                        guard let self = self else { return }
                        do {
                            try Task.checkCancellation()
                            await ModelLoadingCoordinator.shared.onGenerationComplete(env: self.env)
                        } catch {
                            // Task cancelled, ignore
                        }
                    }

                    // Cancel any existing handoff task before starting a new one
                    self.handoffTask?.cancel()

                    // Start pre-loading mesh analysis and wait for it before transitioning
                    self.handoffTask = Task { @MainActor [weak self] in
                        guard let self = self else { return }

                        print("[Gen] Starting handoff task...")

                        // Check for cancellation before starting work
                        var wasCancelled = self.generationStages.values.contains { $0.status == .cancelled }

                        do {
                            try Task.checkCancellation()

                            if !wasCancelled {
                                // Optimize mesh first (this updates generated3DModelURL)
                                self.updateHandoffProgress(progress: 0.1, detail: "Optimizing mesh...")
                                await self.optimizeMesh()

                                // Check cancellation after mesh optimization
                                try Task.checkCancellation()
                                wasCancelled = self.generationStages.values.contains { $0.status == .cancelled }

                                if !wasCancelled {
                                    // Then analyze the optimized mesh
                                    // Progress updates are handled inside preloadMeshAnalysis
                                    await self.preloadMeshAnalysis()

                                    // Check cancellation after preload
                                    try Task.checkCancellation()
                                    wasCancelled = self.generationStages.values.contains { $0.status == .cancelled }

                                    print("[Gen] Preload complete")
                                }
                            }

                            // Only transition if not cancelled
                            if !wasCancelled {
                                print("[Gen] Calling transitionToPostProcess...")

                                // Mark handoff complete - set directly without explicit animation
                                // The sidebar has implicit .animation(value:) that handles this
                                self.generationStages[.handoff] = StageProgress(status: .completed, progress: 1.0, detail: "")

                                // Transition to post-process (also sets state directly, letting implicit animations work)
                                self.transitionToPostProcess()

                                print("[Gen] transitionToPostProcess returned, currentStep=\(String(describing: self.currentStep))")
                            } else {
                                print("[Gen] Handoff: generation was cancelled, skipping transition")
                            }
                        } catch is CancellationError {
                            print("[Gen] Handoff task cancelled")
                        } catch {
                            print("[Gen] Handoff error: \(error)")
                            self.handleError(error)
                        }
                    }
                case .failed(let projectId, let error):
                    guard projectId == self.projectId else { return }
                    self.isGenerating = false
                    print("[Gen] Error: \(error)")
                }
            }
            .store(in: &cancellables)
    }

    /// Cancel the handoff task (called during cleanup)
    func cancelHandoffTask() {
        handoffTask?.cancel()
        handoffTask = nil
    }

    /// Transition to generate settings step (for customizing settings before generation)
    func transitionToGenerateSettings() {
        // CRITICAL: Restore custom color if not set (back then forward navigation)
        if customModelColor == nil {
            loadDominantColorFromMetadata()
        }

        // Check models downloaded (fast filesystem check)
        checkModelsDownloaded()

        // Prepare composite image in background
        prepareCompositeImage()

        // Start preloading Hunyuan model to reduce generation wait time
        Task {
            _ = await ModelLoadingCoordinator.shared.ensureHunyuanReady(
                env: self.env,
                variant: self.selectedPreset.modelVariant
            )
        }

        // Transition to settings step
        withFastSpring {
            currentStep = .generateSettings
        }
    }

    /// Start generation from the settings step
    func startGeneration() {
        transitionToGenerateInternal(autoStart: true, preset: nil)
    }

    /// Immediately start generation with a preset (skips the settings screen)
    func generateImmediately(with preset: GenerationPreset? = nil) {
        if let preset = preset {
            selectedPreset = preset
            customSteps = CGFloat(preset.steps)
            customResolution = CGFloat(preset.resolution)
        }
        transitionToGenerateInternal(autoStart: true, preset: selectedPreset)
    }

    /// Prepare composite image for generation (called when entering settings or generating)
    private func prepareCompositeImage() {
        // Capture data on main actor before detaching
        let existingMask = editableMaskImage
        let masks = segmentations.flatMap { $0.selectedMasks }
        let source = inputImage

        // Try to use preloaded composite first (only if it belongs to this project)
        let preloadedComposite = projectId.flatMap { preloadManager.getPreloadedComposite(for: $0) }

        if let composite = preloadedComposite {
            // Use preloaded composite immediately
            withAnimation(.easeOut(duration: 0.2)) {
                compositeImage = composite
            }
            // Clear preloaded data
            preloadManager.clearPreloadedComposite()
        } else {
            // Fall back to async composite creation
            Task {
                // If no mask yet, merge in background
                let maskToUse: NSImage? = await {
                    if let existing = existingMask {
                        return existing
                    }
                    return await Task.detached(priority: .userInitiated) {
                        ImageService.shared.mergeMasks(masks)
                    }.value
                }()

                guard let mask = maskToUse else {
                    print("[Generation] Warning: Failed to create mask for composite preview")
                    return
                }

                // Store the mask if we just created it
                if editableMaskImage == nil {
                    editableMaskImage = mask
                }

                // Create composite in background
                guard let source = source else {
                    print("[Generation] Warning: No source image for composite preview")
                    return
                }
                let composite = await Task.detached(priority: .userInitiated) {
                    ImageService.shared.createCompositeImage(source: source, mask: mask)
                }.value

                withAnimation(.easeOut(duration: 0.2)) {
                    compositeImage = composite
                }
            }
        }
    }

    private func transitionToGenerateInternal(autoStart: Bool, preset: GenerationPreset?) {
        // CRITICAL: Clear stale generation cache to prevent restoring old data
        cachedGeneration = nil

        // CRITICAL: Clear all downstream state from current step (prevents stale data from previous generations)
        clearDownstreamState(from: currentStep)

        // Check models downloaded (fast filesystem check)
        checkModelsDownloaded()

        // Track the step user was on before generation (for returning on cancel/stop)
        stepBeforeGeneration = currentStep

        // Set generation state BEFORE changing step to avoid flash
        isGenerating = true
        generationStartTime = Date()
        generationStages = [:]

        // Change step WITHOUT animation when auto-starting to prevent flash
        currentStep = .generate

        // If composite is already ready (from settings step), start generation immediately
        if compositeImage != nil {
            generate3D()
            return
        }

        // Otherwise prepare composite and then start generation
        // Capture data on main actor before detaching
        let existingMask = editableMaskImage
        let masks = segmentations.flatMap { $0.selectedMasks }
        let source = inputImage

        // Try to use preloaded composite first (only if it belongs to this project)
        let preloadedComposite = projectId.flatMap { preloadManager.getPreloadedComposite(for: $0) }

        if let composite = preloadedComposite {
            // Use preloaded composite immediately
            withAnimation(.easeOut(duration: 0.2)) {
                compositeImage = composite
            }
            // Clear preloaded data
            preloadManager.clearPreloadedComposite()
            // Start generation
            generate3D()
        } else {
            // Fall back to async composite creation
            Task {
                // If no mask yet, merge in background
                let maskToUse: NSImage? = await {
                    if let existing = existingMask {
                        return existing
                    }
                    return await Task.detached(priority: .userInitiated) {
                        ImageService.shared.mergeMasks(masks)
                    }.value
                }()

                guard let mask = maskToUse else {
                    // Reset isGenerating and notify user of the failure
                    isGenerating = false
                    lastError = AppError.imageProcessing("Failed to create mask. Please ensure you have selected an object to segment.")
                    showErrorAlert = true
                    return
                }

                // Store the mask if we just created it
                if editableMaskImage == nil {
                    editableMaskImage = mask
                }

                // Create composite in background
                guard let source = source else {
                    // Reset isGenerating and notify user of the failure
                    isGenerating = false
                    lastError = AppError.imageProcessing("No source image available. Please load an image first.")
                    showErrorAlert = true
                    return
                }
                let composite = await Task.detached(priority: .userInitiated) {
                    ImageService.shared.createCompositeImage(source: source, mask: mask)
                }.value

                withAnimation(.easeOut(duration: 0.2)) {
                    compositeImage = composite
                }

                // Start generation now that composite is ready
                generate3D()
            }
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
              let mask = editableMaskImage else {
            // CRITICAL: Reset isGenerating on early failure to prevent stuck UI
            isGenerating = false
            lastError = AppError.generation("No composite image or mask available")
            showErrorAlert = true
            return
        }

        // Use the centralized ImageService to convert images to PNG, preserving alpha
        guard let tempImagePath = ImageService.shared.convertToPNG(image: composite, originalName: "composite"),
              let tempMaskPath = ImageService.shared.convertToPNG(image: mask, originalName: "mask") else {
            // CRITICAL: Reset isGenerating on early failure to prevent stuck UI
            isGenerating = false
            lastError = AppError.imageProcessing("Failed to create temporary images for processing")
            showErrorAlert = true
            return
        }

        print("[Generation] Composite image: \(tempImagePath)")
        print("[Generation] Mask image: \(tempMaskPath)")

        // Cancel any previous generation task
        generationTask?.cancel()

        isGenerating = true
        generationStartTime = Date()
        generationStages = [:]
        lastError = nil

        // Generate using Hunyuan
        generateHunyuan(imagePath: tempImagePath, maskPath: tempMaskPath)
    }

    /// Generate 3D model using Hunyuan
    private func generateHunyuan(imagePath: String, maskPath: String) {
        // CRITICAL: Task must be @MainActor to safely mutate @Published properties
        generationTask = Task { @MainActor [weak self] in
            guard let self = self else { return }

            do {
                // Check for cancellation
                try Task.checkCancellation()

                // Prepare for generation (offloads SAM if using conservative strategy)
                // Pass the model variant to ensure the correct Hunyuan model is loaded
                let coordinator = ModelLoadingCoordinator.shared
                let ready = await coordinator.prepareForGeneration(env: self.env, variant: self.selectedPreset.modelVariant)

                guard ready else {
                    throw AppError.generation("Failed to prepare generation environment")
                }

                // Check for cancellation before starting generation
                try Task.checkCancellation()

                // Pass projectId to ensure status updates are properly scoped
                guard let projectId = self.projectId else {
                    throw AppError.generation("No project ID available")
                }

                await ServiceContainer.shared.generationService.generate(
                    projectId: projectId,
                    imagePath: imagePath,
                    maskPath: maskPath,
                    steps: Int(self.customSteps),
                    resolution: Int(self.customResolution),
                    modelVariant: self.selectedPreset.modelVariant,
                    guidanceScale: Double(self.customGuidanceScaleHunyuan),
                    boxV: Double(self.customBoxV),
                    mcLevel: Double(self.customMcLevel)
                )
            } catch is CancellationError {
                print("[Generation] Hunyuan generation cancelled")
                // Already on MainActor - safe to mutate
                self.isGenerating = false
            } catch {
                print("[Generation] Hunyuan error: \(error)")
                // Already on MainActor - safe to mutate
                self.isGenerating = false
                self.lastError = (error as? AppError) ?? AppError.generation(error.localizedDescription)
                self.showErrorAlert = true
            }
        }
    }

    func stopGeneration() {
        // Cancel the generation task
        generationTask?.cancel()
        generationTask = nil

        // Cancel the handoff task
        cancelHandoffTask()

        // Cancel via the coordinator
        ModelLoadingCoordinator.shared.cancelGeneration()

        // Also cancel via the service to reset status
        ServiceContainer.shared.generationService.cancel()

        isGenerating = false
        markRemainingStagesCancelled()
        print("[Gen] Generation stopped by user")

        // Stay on generate step to show stopped state (user can restart or go back)
        // Don't auto-navigate back - let user decide
    }

    /// Restart generation after it was stopped or failed
    func restartGeneration() {
        // Clear previous generation state
        generationStages = [:]
        generationStatus = ""
        lastError = nil

        // Start fresh generation
        generate3D()
    }

    /// Reset generation state when changing models or starting fresh
    /// Call this when model preset changes to clear any stale state
    func resetGenerationState() {
        // Cancel any ongoing generation
        generationTask?.cancel()
        generationTask = nil

        // Clear all generation state
        isGenerating = false
        generationStages = [:]
        generationStatus = ""
        generationStartTime = nil
        generationDuration = nil
        lastError = nil

        // Clear composite (will be regenerated)
        compositeImage = nil

        // Reset download monitoring
        resetDownloadMonitoringState()

        print("[Gen] Generation state reset (model changed)")
    }

    func updateGenerationStages(status: String, percent: Double = 0) {
        // Extract step info from status string (handles formats like "Stage (5/25)" or "Stage: 5/25")
        let stepDetail = ProgressParser.formatStepDetail(status)

        if status.contains("Downloading") || status.contains("Fetching") {
            // Check if the model is already downloaded (only mini model supported)
            if !isSmallModelDownloaded {
                let info = ProgressParser.parseDetailedProgress(status)
                let progress = info.percentComplete / 100.0
                let detail = info.currentStep > 0 ? "\(info.currentStep)/\(info.totalSteps)" : "Downloading..."

                withFastSpring {
                    generationStages[.downloading] = StageProgress(status: .inProgress, progress: progress, detail: detail)
                }

                // Start download monitoring if not already started
                if downloadTotalBytes == 0 {
                    let modelrDir = PathManager.appSupportDirectory
                    let hfCacheDir = modelrDir.appendingPathComponent("Cache/hf_cache/hub")
                    let modelCacheName = "models--tencent--Hunyuan3D-2mini"
                    let total = AppConstants.hunyuanMiniModelBytes
                    let modelCacheDir = hfCacheDir.appendingPathComponent(modelCacheName)

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
            withFastSpring {
                if generationStages[.downloading] != nil {
                    generationStages[.downloading] = StageProgress(status: .completed, progress: 1.0, detail: "")
                    // Stop download monitoring when extracting starts
                    downloadMonitor.stopMonitoring()
                }
                generationStages[.extracting] = StageProgress(status: .inProgress, progress: 0, detail: "")
            }
        } else if status.contains("Loading") && !status.contains("Volume") {
            withFastSpring {
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
                detail = ProgressParser.extractDetailText(status)
            }
            // Calculate STAGE-SPECIFIC progress from step counts, NOT overall progress
            let stageProgress: Double
            if info.totalSteps > 0 {
                stageProgress = Double(info.currentStep) / Double(info.totalSteps)
            } else {
                stageProgress = 0
            }
            withFastSpring {
                markPreviousStagesCompleted(before: .volumeDecoding)
                generationStages[.diffusion] = StageProgress(status: .completed, progress: 1.0, detail: "")
                generationStages[.volumeDecoding] = StageProgress(status: .inProgress, progress: stageProgress, detail: detail)
            }
        } else if status.contains("Diffusion Sampling") || status.contains("Generating 3D shape") || status.contains("diffusion") {
            let info = ProgressParser.parseDetailedProgress(status)
            let detail = stepDetail.isEmpty ? (info.totalSteps > 0 ? "\(info.currentStep)/\(info.totalSteps)" : "") : stepDetail
            // Calculate STAGE-SPECIFIC progress from step counts, NOT overall progress
            let stageProgress: Double
            if info.totalSteps > 0 {
                stageProgress = Double(info.currentStep) / Double(info.totalSteps)
            } else {
                stageProgress = 0
            }
            withFastSpring {
                markPreviousStagesCompleted(before: .diffusion)
                generationStages[.diffusion] = StageProgress(status: .inProgress, progress: stageProgress, detail: detail)
            }
        } else if status.contains("Exporting") || status.contains("export") {
            // Transition from diffusion to saving when exporting starts
            withFastSpring {
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

            withFastSpring {
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
            let detail = ProgressParser.extractDetailText(status)
            withFastSpring {
                markPreviousStagesCompleted(before: .saving)
                generationStages[.volumeDecoding] = StageProgress(status: .completed, progress: 1.0, detail: "")
                generationStages[.saving] = StageProgress(status: .inProgress, progress: 0, detail: detail)
            }
        }
    }

    // Progress parsing is now centralized in ProgressParser:
    // - Use ProgressParser.formatStepDetail() instead of extractStepDetail()
    // - Use ProgressParser.extractDetailText() instead of extractDetailText()

    func markPreviousStagesCompleted(before stage: GenerationStage) {
        // Use model-specific stages to avoid marking irrelevant stages
        let modelStages = GenerationStage.stages(for: selectedPreset.modelFamily)
        guard let targetIndex = modelStages.firstIndex(of: stage) else { return }

        for i in 0..<targetIndex {
            let prevStage = modelStages[i]
            if generationStages[prevStage]?.status != .completed {
                generationStages[prevStage] = StageProgress(status: .completed, progress: 1.0, detail: "")
            }
        }
    }

    func markAllStagesCompleted() {
        // Use model-specific stages
        let modelStages = GenerationStage.stages(for: selectedPreset.modelFamily)
        for stage in modelStages {
            generationStages[stage] = StageProgress(status: .completed, progress: 1.0, detail: "")
        }
    }

    func markRemainingStagesCancelled() {
        // Use model-specific stages
        let modelStages = GenerationStage.stages(for: selectedPreset.modelFamily)
        for stage in modelStages {
            if generationStages[stage]?.status != .completed {
                generationStages[stage] = StageProgress(status: .cancelled, progress: 0, detail: "")
            }
        }
    }

    // MARK: - Download Monitoring During Generation
    // This section is now managed by the DownloadMonitor struct in Core/Services/
    // The old static properties and functions are no longer needed.
}
