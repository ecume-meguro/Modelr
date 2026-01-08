import Foundation
import AppKit
import SwiftUI

// MARK: - Setup Extension
extension SimpleEditorViewModel {

    // MARK: - Setup Flow Control

    /// Start the setup process
    func startSetup() {
        guard currentSetupSubStep == .chooseModel else { return }

        setupSubStepCompleted.insert(.chooseModel)
        currentSetupSubStep = .configuringSegmentation
        downloadStartTime = Date()
        setupProgress = 0

        Task {
            await runSetup()
        }
    }

    /// Run environment-only refresh (called when build number changes)
    /// This syncs venvs without re-downloading models
    func runEnvironmentRefresh() async {
        await MainActor.run {
            setupProgress = 0
            environmentRefreshStatus = "Updating environments..."
        }

        let success = await env.refreshEnvironments { [weak self] update in
            Task { @MainActor in
                guard let self = self else { return }

                // Map stage to substep for visual progress
                let newSubStep = self.mapStageToSubStep(update.stage)
                self.currentSetupSubStep = newSubStep
                self.currentSetupStage = update.stage
                self.calculateCumulativeProgress(currentStage: update.stage)

                if !update.status.isEmpty {
                    self.environmentRefreshStatus = update.status
                    print("[EnvRefresh][\(update.stage.rawValue)] \(update.status)")
                }
            }
        }

        await MainActor.run {
            isRefreshingEnvironments = false

            if success {
                setupProgress = 1.0
                environmentRefreshStatus = "Environments updated"

                // Mark environment ready and transition to input
                env.markHunyuanReady()

                withAnimation(.easeOut(duration: 0.3)) {
                    currentStep = .input
                }
                print("[EnvRefresh] Environment refresh completed successfully")
            } else {
                environmentRefreshStatus = "Environment update failed"
                print("[EnvRefresh] Environment refresh failed")
            }
        }
    }

    /// Run the centralized setup process driven by PythonDependencyService
    private func runSetup() async {
        resetDownloadProgress()
        
        // Secondary directory monitoring for visual progress (not for state control)
        let modelrDir = PathManager.appSupportDirectory

        // Download monitoring paths (purely visual, not used for correctness)
        let modelsHubDir = modelrDir.appendingPathComponent("Models/hub")
        let samModelDir = modelsHubDir.appendingPathComponent("models--mlx-community--sam3-image")
        // Mini variants (fast, turbo) share the same repo; quality uses 2.1
        let modelCacheName = selectedModelChoice.usesMiniRepo ? "models--tencent--Hunyuan3D-2mini" : "models--tencent--Hunyuan3D-2.1"
        let hunyuanModelDir = modelsHubDir.appendingPathComponent(modelCacheName)

        // The setup service now drives the entire sequence
        let success = await env.setup(modelChoice: selectedModelChoice) { [weak self] update in
            Task { @MainActor in
                guard let self = self else { return }
                
                // 1. Map Stage to UI SubStep
                self.currentSetupStage = update.stage
                let newSubStep = self.mapStageToSubStep(update.stage)
                
                // If moving forward, mark previous steps as completed for checkmarks
                if self.currentSetupSubStep != newSubStep {
                    self.markPreviousSubStepsCompleted(upTo: newSubStep)
                    self.currentSetupSubStep = newSubStep
                }
                
                // 2. Handle Progress Progress
                self.calculateCumulativeProgress(currentStage: update.stage)
                
                // 3. Handle Status & Logs
                if !update.status.isEmpty {
                    self.setupStatus = update.status
                    print("[Setup][\(update.stage.rawValue)] \(update.status)")
                }
                
                if let log = update.logLine {
                    self.appendConsoleOutput(log, for: update.stage)
                }
                
                // 4. Trigger directory monitoring when reaching download stages
                if update.stage == .downloadingSAM {
                    self.ensurePinnedTotalBytesForDownloadStage(stage: .downloadingSAM)
                    self.startMonitoringDownload(directory: samModelDir, totalBytes: self.downloadTotalBytes > 0 ? self.downloadTotalBytes : AppConstants.samModelBytes)
                } else if update.stage == .downloadingHunyuan {
                    self.ensurePinnedTotalBytesForDownloadStage(stage: .downloadingHunyuan)
                    // Mini variants (fast, turbo) use mini size; quality uses std size
                    let fallback = self.selectedModelChoice.usesMiniRepo ? AppConstants.hunyuanMiniModelBytes : AppConstants.hunyuanStandardModelBytes
                    let total = self.downloadTotalBytes > 0 ? self.downloadTotalBytes : fallback
                    self.startMonitoringDownload(directory: hunyuanModelDir, totalBytes: total)
                }
            }
        }

        if success {
            await finalizeSetup()
        } else {
            await MainActor.run {
                self.setupStatus = "Setup failed. Check logs for details."
            }
        }
    }

    private func markPreviousSubStepsCompleted(upTo current: SetupSubStep) {
        let allSteps = SetupSubStep.allCases
        guard let currentIndex = allSteps.firstIndex(of: current) else { return }
        
        for i in 0..<currentIndex {
            setupSubStepCompleted.insert(allSteps[i])
        }
    }

    private func mapStageToSubStep(_ stage: SetupStage) -> SetupSubStep {
        switch stage {
        case .preparing, .syncingSAM:
            return .configuringSegmentation
        case .downloadingSAM:
            return .downloadingSegmentation
        case .syncingHunyuan:
            return .configuringGeneration
        case .downloadingHunyuan:
            return .downloadingGeneration
        case .syncingTools:
            return .configuringPostProcess
        case .completed:
            return .configuringPostProcess
        case .failed:
            return currentSetupSubStep
        }
    }

    private func calculateCumulativeProgress(currentStage: SetupStage) {
        let stages = SetupStage.allCases
        var cumulative: Double = 0
        
        for stage in stages {
            if stage == currentStage {
                // Add half of the current stage's weight to show we are "in" it
                cumulative += stage.progressWeight * 0.5
                break
            }
            cumulative += stage.progressWeight
        }
        
        self.setupProgress = cumulative
    }

    private func finalizeSetup() async {
        await MainActor.run {
            setupProgress = 1.0
            setupStatus = "Setup Complete"
            setupSubStepCompleted = Set(SetupSubStep.allCases)
            isSetupComplete = true

            // Write setup completion marker file
            do {
                try PathManager.markSetupComplete(modelVariant: selectedModelChoice.modelVariant)
                print("[Setup] Setup completion marker written to: \(PathManager.setupCompletionMarkerPath.path)")
            } catch {
                print("[Setup] Warning: Failed to write setup completion marker: \(error)")
            }

            // Mark Python environment ready for generation
            env.markHunyuanReady()

            // Final check for models
            checkModelsDownloaded()

            withAnimation(.easeOut(duration: 0.3)) {
                currentStep = .input
            }
        }
    }

    // MARK: - Console Output

    func appendConsoleOutput(_ text: String, for stage: SetupStage) {
        let subStep = mapStageToSubStep(stage)
        
        let lines = text.replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: .newlines)
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }

        if setupConsoleOutput[subStep] == nil {
            setupConsoleOutput[subStep] = []
        }

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty {
                print("[Setup][\(stage.rawValue)] \(trimmed)")

                // Prefer HuggingFace/tqdm byte totals (e.g. `2.49G/3.82G`) over directory-size-based
                // monitoring. This prevents stale totals like 7.2GB from showing up.
                if stage == .downloadingHunyuan || stage == .downloadingSAM {
                    if let hf = ProgressParser.parseHuggingFaceByteProgress(trimmed) {
                        if !isUsingHuggingFaceDownloadProgress {
                            isUsingHuggingFaceDownloadProgress = true
                            stopMonitoring()
                        }

                        downloadedBytes = hf.downloadedBytes
                        // Prefer a pinned total (queried from HF) when available.
                        if pinnedDownloadTotalBytes == nil {
                            downloadTotalBytes = hf.totalBytes
                        }

                        if let speed = hf.speedBytesPerSecond {
                            downloadSpeed = speed
                            if speed > 0 {
                                let total = pinnedDownloadTotalBytes ?? hf.totalBytes
                                downloadTimeRemaining = Double(max(0, total - hf.downloadedBytes)) / speed
                            }
                        }
                    }
                }

                if setupConsoleOutput[subStep]!.count >= 50 {
                    setupConsoleOutput[subStep]!.removeFirst()
                }
                setupConsoleOutput[subStep]!.append(trimmed)
            }
        }
    }

    // MARK: - Download Monitoring

    private func resetDownloadProgress() {
        downloadedBytes = 0
        downloadTotalBytes = 0
        downloadSpeed = 0
        downloadTimeRemaining = 0

        pinnedDownloadTotalBytes = nil
        didQueryCurrentDownloadTotal = false

        isUsingHuggingFaceDownloadProgress = false

        downloadStartTime = nil
        lastDownloadBytes = 0
        lastSpeedUpdateTime = nil
        speedHistory.removeAll()
        lastValidSpeed = 0

        downloadMonitor.resetProgress()
    }

    private func ensurePinnedTotalBytesForDownloadStage(stage: SetupStage) {
        // Only query for download stages
        guard stage == .downloadingHunyuan || stage == .downloadingSAM else { return }

        // SAM uses constant fallback, only query HF for Hunyuan
        guard stage == .downloadingHunyuan else { return }

        // Only query once per download stage
        guard !didQueryCurrentDownloadTotal else { return }
        didQueryCurrentDownloadTotal = true

        Task { [weak self] in
            guard let self else { return }

            let (repoId, subfolder): (String, String) = {
                switch self.selectedModelChoice {
                case .fast:
                    return ("tencent/Hunyuan3D-2mini", "hunyuan3d-dit-v2-mini")
                case .quality:
                    return ("tencent/Hunyuan3D-2.1", "hunyuan3d-dit-v2-1")
                }
            }()

            let files: [HuggingFaceModelSizeService.FileSpec] = [
                .init(repoId: repoId, path: "\(subfolder)/config.yaml"),
                .init(repoId: repoId, path: "\(subfolder)/model.fp16.safetensors"),
            ]

            if let total = await HuggingFaceModelSizeService.totalBytes(for: files), total > 0 {
                await MainActor.run {
                    self.pinnedDownloadTotalBytes = total
                    self.downloadTotalBytes = total
                }
            }
        }
    }

    private func startMonitoringDownload(directory: URL, totalBytes: Int64) {
        // If HF is already providing progress, don't start a directory-size monitor that might
        // overwrite totals.
        if isUsingHuggingFaceDownloadProgress {
            return
        }
        downloadMonitor.startMonitoring(directory: directory, totalBytes: totalBytes) { [weak self] monitor in
            guard let self = self else { return }
            Task { @MainActor in
                if self.isUsingHuggingFaceDownloadProgress {
                    return
                }
                self.downloadedBytes = monitor.downloadedBytes
                self.downloadTotalBytes = monitor.downloadTotalBytes
                self.downloadSpeed = monitor.downloadSpeed
                self.downloadTimeRemaining = monitor.downloadTimeRemaining
            }
        }
    }

    private func stopMonitoring() {
        downloadMonitor.stopMonitoring()
    }

    // MARK: - Navigation Helpers (Legacy Compatibility)

    func startBackgroundEnvironmentSetup() {
        // Run setup sequentially
    }

    func handleBackAction() {
        if currentStep == .setup && currentSetupSubStep != .chooseModel {
            showStartOverWarning = true
        } else {
            goBack()
        }
    }

    // MARK: - Shared Utilities


    


}
