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

    /// Run the centralized setup process driven by PythonDependencyService
    private func runSetup() async {
        resetDownloadProgress()
        
        // Secondary directory monitoring for visual progress (not for state control)
        let fm = FileManager.default
        guard let appSupportDir = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return }
        let modelrDir = appSupportDir.appendingPathComponent("ModelrV3")
        
        let samModelDir = modelrDir.appendingPathComponent("sam_cache/hub/models--mlx-community--sam3-image")
        let hfCacheDir = modelrDir.appendingPathComponent("Hunyuan3D/hf_cache")
        let modelCacheName = selectedModelChoice == .fast ? "models--tencent--Hunyuan3D-2mini" : "models--tencent--Hunyuan3D-2.1"
        let hunyuanModelDir = hfCacheDir.appendingPathComponent(modelCacheName)

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
                }
                
                if let log = update.logLine {
                    self.appendConsoleOutput(log, for: update.stage)
                }
                
                // 4. Trigger directory monitoring when reaching download stages
                if update.stage == .downloadingSAM {
                    self.startMonitoringDownload(directory: samModelDir, totalBytes: 3_200_000_000)
                } else if update.stage == .downloadingHunyuan {
                    let total = self.selectedModelChoice == .fast ? 7_200_000_000 : 7_400_000_000
                    self.startMonitoringDownload(directory: hunyuanModelDir, totalBytes: Int64(total))
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
            UserDefaults.standard.set(true, forKey: "SetupComplete")
            
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
                if setupConsoleOutput[subStep]!.count >= 50 {
                    setupConsoleOutput[subStep]!.removeFirst()
                }
                setupConsoleOutput[subStep]!.append(trimmed)
            }
        }
    }

    // MARK: - Download Monitoring

    private static var monitorTask: Task<Void, Never>?
    private static var lastMonitoredPath: String?

    private func startMonitoringDownload(directory: URL, totalBytes: Int64) {
        // Update total bytes even if we don't restart the task
        self.downloadTotalBytes = totalBytes
        
        // Only restart if it's a new path
        let path = directory.path
        if Self.lastMonitoredPath == path && Self.monitorTask != nil {
            return
        }
        
        Self.lastMonitoredPath = path
        
        if Self.monitorTask != nil {
            Self.monitorTask?.cancel()
            Self.monitorTask = nil
        }
        
        Self.monitorTask = Task {
            while !Task.isCancelled {
                let size = await getDirectorySize(directory)
                await MainActor.run {
                    self.updateDownloadProgress(downloaded: size, total: totalBytes)
                }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }

    private func stopMonitoring() {
        Self.monitorTask?.cancel()
        Self.monitorTask = nil
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

    func updateDownloadProgress(downloaded: Int64, total: Int64) {
        downloadedBytes = downloaded
        downloadTotalBytes = total

        let now = Date()
        if let lastTime = lastSpeedUpdateTime {
            let elapsed = now.timeIntervalSince(lastTime)
            if elapsed >= 0.5 {
                let bytesDownloaded = downloaded - lastDownloadBytes
                if bytesDownloaded > 0 {
                    let instantSpeed = Double(bytesDownloaded) / elapsed
                    speedHistory.append(instantSpeed)
                    if speedHistory.count > 5 { speedHistory.removeFirst() }
                    let avgSpeed = speedHistory.reduce(0, +) / Double(speedHistory.count)
                    downloadSpeed = avgSpeed
                }
                lastDownloadBytes = downloaded
                lastSpeedUpdateTime = now
                if downloadSpeed > 0 {
                    downloadTimeRemaining = Double(total - downloaded) / downloadSpeed
                }
            }
        } else {
            lastSpeedUpdateTime = now
            lastDownloadBytes = downloaded
        }
    }

    func resetDownloadProgress() {
        downloadedBytes = 0
        downloadTotalBytes = 0
        downloadSpeed = 0
        downloadTimeRemaining = 0
        speedHistory.removeAll()
        lastDownloadBytes = 0
        lastSpeedUpdateTime = nil
        stopMonitoring()
    }

    private func getDirectorySize(_ url: URL) async -> Int64 {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let process = Process()
                let pipe = Pipe()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/du")
                process.arguments = ["-sk", url.path]
                process.standardOutput = pipe
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
    
    var formattedDownloadProgress: String {
        let downloaded = ByteCountFormatter.string(fromByteCount: downloadedBytes, countStyle: .file)
        let total = ByteCountFormatter.string(fromByteCount: downloadTotalBytes, countStyle: .file)
        
        let speedStr: String
        if downloadSpeed > 1024 {
            speedStr = " • " + ByteCountFormatter.string(fromByteCount: Int64(downloadSpeed), countStyle: .file) + "/s"
        } else {
            speedStr = ""
        }
        
        return "\(downloaded) / \(total)\(speedStr)"
    }

    var formattedDownloadSpeed: String {
        if downloadSpeed > 1024 {
            return ByteCountFormatter.string(fromByteCount: Int64(downloadSpeed), countStyle: .file) + "/s"
        }
        return "—"
    }

    var formattedTimeRemaining: String {
        guard downloadTimeRemaining > 0 && downloadTimeRemaining < 86400 else { return "" }
        let minutes = Int(downloadTimeRemaining) / 60
        let seconds = Int(downloadTimeRemaining) % 60
        let timeStr = minutes > 0 ? "\(minutes)m \(seconds)s" : "\(seconds)s"
        return "\(timeStr) remaining"
    }
}