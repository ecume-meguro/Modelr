import Foundation
import AppKit
import SwiftUI

// MARK: - Setup Extension
extension SimpleEditorViewModel {

    // MARK: - Setup Flow Control

    /// Start environment configuration in background (called when setup view appears)
    func startBackgroundEnvironmentSetup() {
        // Only start if not already done
        guard !setupSubStepCompleted.contains(.configuringEnvironment),
              !isConfiguringEnvironment else { return }

        isConfiguringEnvironment = true

        Task {
            await configureEnvironmentInBackground()
        }
    }

    /// Configure environment while user is choosing model
    private func configureEnvironmentInBackground() async {
        let fm = FileManager.default
        guard let appSupportDir = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return }
        let modelrDir = appSupportDir.appendingPathComponent("ModelrV3")

        // Create directory
        try? fm.createDirectory(at: modelrDir, withIntermediateDirectories: true)

        // Copy resources and setup environment
        await copyResources(to: modelrDir)
        await setupPythonEnvironment(at: modelrDir)

        await MainActor.run {
            setupSubStepCompleted.insert(.configuringEnvironment)
            // Immediately start downloading SAM3 in background once environment is ready
            Task {
                await downloadSAMModel(at: modelrDir)
                await MainActor.run {
                    setupSubStepCompleted.insert(.downloadingSegmentation)
                }
            }
        }
        
        await MainActor.run {
            isConfiguringEnvironment = false
        }
    }

    /// Start the setup process after model selection
    func startSetup() {
        guard currentSetupSubStep == .chooseModel else { return }

        setupSubStepCompleted.insert(.chooseModel)
        downloadStartTime = Date()

        // If environment is still configuring, wait for it, otherwise skip to downloads
        if setupSubStepCompleted.contains(.configuringEnvironment) {
            currentSetupSubStep = .downloadingSegmentation
        } else {
            currentSetupSubStep = .configuringEnvironment
        }

        Task {
            await runSetupSequence()
        }
    }

    /// Run the complete setup sequence
    private func runSetupSequence() async {
        let fm = FileManager.default
        guard let appSupportDir = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return }
        let modelrDir = appSupportDir.appendingPathComponent("ModelrV3")

        // Create directory
        try? fm.createDirectory(at: modelrDir, withIntermediateDirectories: true)

        // Stage 1: Wait for environment if not done yet
        if !setupSubStepCompleted.contains(.configuringEnvironment) {
            currentSetupSubStep = .configuringEnvironment
            setupProgress = 0.05

            // Wait for background task to complete
            while !setupSubStepCompleted.contains(.configuringEnvironment) {
                try? await Task.sleep(nanoseconds: 100_000_000) // 100ms
            }
        }
        setupProgress = 0.2

        // Stage 2: Download SAM model
        if !setupSubStepCompleted.contains(.downloadingSegmentation) {
            currentSetupSubStep = .downloadingSegmentation
            setupProgress = 0.3
            
            // If background setup already started it, we just wait for it.
            // If not, we start it now.
            // (Note: In current flow it starts immediately after configuringEnvironment)
            while !setupSubStepCompleted.contains(.downloadingSegmentation) {
                // If it wasn't even started, we might need a flag to check, 
                // but configureEnvironmentInBackground starts it.
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }
        setupProgress = 0.5

        // Stage 3: Setup and download Hunyuan
        currentSetupSubStep = .downloadingGeneration
        setupProgress = 0.6
        await setupHunyuanEnvironment(at: modelrDir)
        await downloadHunyuanModel(at: modelrDir)
        setupSubStepCompleted.insert(.downloadingGeneration)

        // Complete
        setupProgress = 1.0
        setupStatus = "Setup Complete"
        isSetupComplete = true
        UserDefaults.standard.set(true, forKey: "SetupComplete")

        // Mark the Python environment as ready for generation
        env.markHunyuanReady()

        withAnimation(.easeOut(duration: 0.3)) {
            currentStep = .input
        }
    }

    /// Skip to input if setup already complete (for verification)
    func verifySetupAndContinue() {
        // Quick check if all models are present
        let fm = FileManager.default
        guard let appSupportDir = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            currentStep = .setup
            return
        }

        let modelrDir = appSupportDir.appendingPathComponent("ModelrV3")
        let samCacheDir = modelrDir.appendingPathComponent("sam_cache")
        let hunyuanCacheDir = modelrDir.appendingPathComponent("Hunyuan3D/hf_cache")

        let samExists = fm.fileExists(atPath: samCacheDir.path)
        let hunyuanExists = fm.fileExists(atPath: hunyuanCacheDir.path)

        if samExists && hunyuanExists {
            isSetupComplete = true
            setupSubStepCompleted = Set(SetupSubStep.allCases)
            currentStep = .input
        } else {
            // Need to re-run setup
            isSetupComplete = false
            setupSubStepCompleted.removeAll()
            currentSetupSubStep = .chooseModel
            currentStep = .setup
        }
    }

    // MARK: - Console Output

    func appendConsoleOutput(_ text: String, for subStep: SetupSubStep) {
        let lines = text.replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: .newlines)
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }

        if setupConsoleOutput[subStep] == nil {
            setupConsoleOutput[subStep] = []
        }

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty {
                // Log to stdout for CLI visibility
                print("[\(subStep.rawValue)] \(trimmed)")

                // Keep last 20 lines per substep
                if setupConsoleOutput[subStep]!.count >= 20 {
                    setupConsoleOutput[subStep]!.removeFirst()
                }
                setupConsoleOutput[subStep]!.append(trimmed)
                setupStatus = trimmed
            }
        }
    }

    // MARK: - Download Progress Tracking

    func updateDownloadProgress(downloaded: Int64, total: Int64) {
        downloadedBytes = downloaded
        downloadTotalBytes = total

        // Calculate speed using moving average
        let now = Date()
        if let lastTime = lastSpeedUpdateTime {
            let elapsed = now.timeIntervalSince(lastTime)
            if elapsed >= 0.3 {  // Update every 300ms for smoother updates
                let bytesDownloaded = downloaded - lastDownloadBytes

                if bytesDownloaded > 0 {
                    // Calculate instantaneous speed
                    let instantSpeed = Double(bytesDownloaded) / elapsed

                    // Add to history (keep last 10 samples for ~3-5 second average)
                    speedHistory.append(instantSpeed)
                    if speedHistory.count > 10 {
                        speedHistory.removeFirst()
                    }

                    // Calculate moving average
                    let avgSpeed = speedHistory.reduce(0, +) / Double(speedHistory.count)

                    // Apply exponential smoothing: 70% new average, 30% previous
                    if lastValidSpeed > 0 {
                        downloadSpeed = avgSpeed * 0.7 + lastValidSpeed * 0.3
                    } else {
                        downloadSpeed = avgSpeed
                    }

                    lastValidSpeed = downloadSpeed
                } else {
                    // No bytes downloaded - gradually decay speed instead of jumping to 0
                    if lastValidSpeed > 0 {
                        downloadSpeed = lastValidSpeed * 0.95  // Slow decay
                        lastValidSpeed = downloadSpeed
                    }
                }

                lastDownloadBytes = downloaded
                lastSpeedUpdateTime = now

                // Calculate time remaining based on smoothed speed
                if downloadSpeed > 100 && total > downloaded {  // Minimum 100 bytes/s threshold
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
        downloadStartTime = nil
        lastDownloadBytes = 0
        lastSpeedUpdateTime = nil
        speedHistory.removeAll()
        lastValidSpeed = 0
    }

    var formattedDownloadProgress: String {
        let downloaded = ByteCountFormatter.string(fromByteCount: downloadedBytes, countStyle: .file)
        if downloadTotalBytes > 0 {
            let total = ByteCountFormatter.string(fromByteCount: downloadTotalBytes, countStyle: .file)
            return "\(downloaded) / \(total)"
        }
        return downloaded
    }

    var formattedDownloadSpeed: String {
        // Show speed if we have a valid measurement (even if currently 0 but had recent activity)
        if downloadSpeed > 100 || lastValidSpeed > 100 {
            let displaySpeed = downloadSpeed > 100 ? downloadSpeed : lastValidSpeed
            let speed = ByteCountFormatter.string(fromByteCount: Int64(displaySpeed), countStyle: .file)
            return "\(speed)/s"
        }
        // Show "Calculating..." during initial ramp-up
        if downloadedBytes > 0 && speedHistory.count < 3 {
            return "Calculating..."
        }
        return "—"
    }

    var formattedTimeRemaining: String {
        guard downloadTimeRemaining > 0 && downloadTimeRemaining.isFinite && downloadTimeRemaining < 86400 else {
            if downloadedBytes > 0 && speedHistory.count < 3 {
                return "Estimating..."
            }
            return "—"
        }
        let minutes = Int(downloadTimeRemaining) / 60
        let seconds = Int(downloadTimeRemaining) % 60
        if minutes > 60 {
            let hours = minutes / 60
            let mins = minutes % 60
            return "\(hours)h \(mins)m remaining"
        } else if minutes > 0 {
            return "\(minutes)m \(seconds)s remaining"
        }
        return "\(seconds)s remaining"
    }

    // MARK: - Setup Steps Implementation

    private func copyResources(to appSupportDir: URL) async {
        appendConsoleOutput("Copying and verifying resources...", for: .configuringEnvironment)
        await env.copyResources()
        appendConsoleOutput("✓ Resources prepared", for: .configuringEnvironment)
    }

    private func setupPythonEnvironment(at appSupportDir: URL) async {
        appendConsoleOutput("Installing Python and dependencies...", for: .configuringEnvironment)
        let success = await env.syncEnvironment()
        
        if success {
            appendConsoleOutput("✓ Python environment ready", for: .configuringEnvironment)
        } else {
            appendConsoleOutput("✗ Environment setup failed. Check logs.", for: .configuringEnvironment)
        }
        setupProgress = 0.2
    }

    private func downloadSAMModel(at appSupportDir: URL) async {
        guard let uvPath = Bundle.main.path(forResource: "uv", ofType: nil) ??
                          Bundle.main.path(forResource: "uv", ofType: nil, inDirectory: "Resources") else {
            appendConsoleOutput("Error: uv not found", for: .downloadingSegmentation)
            return
        }

        appendConsoleOutput("Downloading SAM model (~3.2 GB)...", for: .downloadingSegmentation)
        downloadTotalBytes = 3_200_000_000  // Approximate

        let samWrapper = appSupportDir.appendingPathComponent("sam_wrapper.py")
        let venvDir = appSupportDir.appendingPathComponent(".venv")
        let samCacheDir = appSupportDir.appendingPathComponent("sam_cache")

        try? FileManager.default.createDirectory(at: samCacheDir, withIntermediateDirectories: true)

        // Specific model directory to monitor
        let samModelDir = samCacheDir.appendingPathComponent("hub/models--mlx-community--sam3-image")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: uvPath)
        process.arguments = ["run", samWrapper.path, "--test"]
        process.currentDirectoryURL = appSupportDir
        process.environment = [
            "UV_PROJECT_ENVIRONMENT": venvDir.path,
            "UV_PYTHON_INSTALL_DIR": appSupportDir.appendingPathComponent("python_runtimes").path,
            "UV_CACHE_DIR": appSupportDir.appendingPathComponent("uv_cache").path,
            "UV_PYTHON_PREFERENCE": "only-managed",
            "PYTHONUNBUFFERED": "1",
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "HF_HOME": samCacheDir.path
        ]

        // Start monitoring specific SAM model directory for progress
        let monitorTask = startDirectoryMonitoring(samModelDir)

        await runProcessWithOutput(process, subStep: .downloadingSegmentation)

        monitorTask.cancel()
        resetDownloadProgress()
        setupProgress = 0.5
    }

    private func setupHunyuanEnvironment(at appSupportDir: URL) async {
        guard let uvPath = Bundle.main.path(forResource: "uv", ofType: nil) ??
                          Bundle.main.path(forResource: "uv", ofType: nil, inDirectory: "Resources") else {
            return
        }

        let hunyuanDir = appSupportDir.appendingPathComponent("Hunyuan3D")
        try? FileManager.default.createDirectory(at: hunyuanDir, withIntermediateDirectories: true)

        // Copy Hunyuan resources
        if let sourcePath = Bundle.main.path(forResource: "pyproject_hunyuan.toml", ofType: nil) ??
                           Bundle.main.path(forResource: "pyproject_hunyuan.toml", ofType: nil, inDirectory: "Resources") {
            let targetPath = hunyuanDir.appendingPathComponent("pyproject.toml")
            do {
                try? FileManager.default.removeItem(at: targetPath)
                try FileManager.default.copyItem(at: URL(fileURLWithPath: sourcePath), to: targetPath)
            } catch {
                appendConsoleOutput("Failed to copy pyproject: \(error.localizedDescription)", for: .downloadingGeneration)
            }
        }

        if let sourcePath = Bundle.main.path(forResource: "hunyuan_wrapper.py", ofType: nil) ??
                           Bundle.main.path(forResource: "hunyuan_wrapper.py", ofType: nil, inDirectory: "Resources") {
            let targetPath = hunyuanDir.appendingPathComponent("hunyuan_wrapper.py")
            do {
                try? FileManager.default.removeItem(at: targetPath)
                try FileManager.default.copyItem(at: URL(fileURLWithPath: sourcePath), to: targetPath)
            } catch {
                appendConsoleOutput("Failed to copy wrapper: \(error.localizedDescription)", for: .downloadingGeneration)
            }
        }

        appendConsoleOutput("Installing Hunyuan3D dependencies...", for: .downloadingGeneration)

        let venvDir = appSupportDir.appendingPathComponent(".venv_hunyuan")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: uvPath)
        process.arguments = ["sync", "--python", "3.10"]
        process.currentDirectoryURL = hunyuanDir
        process.environment = [
            "UV_PROJECT_ENVIRONMENT": venvDir.path,
            "UV_PYTHON_INSTALL_DIR": appSupportDir.appendingPathComponent("python_runtimes").path,
            "UV_CACHE_DIR": appSupportDir.appendingPathComponent("uv_cache").path,
            "UV_PYTHON_PREFERENCE": "only-managed",
            "PYTHONUNBUFFERED": "1",
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin"
        ]

        await runProcessWithOutput(process, subStep: .downloadingGeneration)
        setupProgress = 0.7
    }

    private func downloadHunyuanModel(at appSupportDir: URL) async {
        guard let uvPath = Bundle.main.path(forResource: "uv", ofType: nil) ??
                          Bundle.main.path(forResource: "uv", ofType: nil, inDirectory: "Resources") else {
            return
        }

        let modelSize = selectedModelChoice == .fast ? "~7.2 GB" : "~7.4 GB"
        let variant = selectedModelChoice.modelVariant
        appendConsoleOutput("Selected model: \(selectedModelChoice.rawValue) → variant: \(variant)", for: .downloadingGeneration)
        appendConsoleOutput("Downloading \(selectedModelChoice.modelName) (\(modelSize))...", for: .downloadingGeneration)

        let totalBytes: Int64 = selectedModelChoice == .fast ? 7_200_000_000 : 7_400_000_000
        downloadTotalBytes = totalBytes

        let hunyuanDir = appSupportDir.appendingPathComponent("Hunyuan3D")
        let venvDir = appSupportDir.appendingPathComponent(".venv_hunyuan")
        let hfCacheDir = hunyuanDir.appendingPathComponent("hf_cache")

        // Determine the specific model cache directory to monitor
        // HuggingFace uses HUGGINGFACE_HUB_CACHE env var which is set to hf_cache/
        let modelCacheName = selectedModelChoice == .fast ? "models--tencent--Hunyuan3D-2mini" : "models--tencent--Hunyuan3D-2.1"
        let modelCacheDir = hfCacheDir.appendingPathComponent(modelCacheName)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: uvPath)
        let wrapperPath = hunyuanDir.appendingPathComponent("hunyuan_wrapper.py").path
        process.arguments = ["run", wrapperPath, "--warmup", "--model", variant]
        process.currentDirectoryURL = hunyuanDir
        appendConsoleOutput("Command: uv run ... --warmup --model \(variant)", for: .downloadingGeneration)
        process.environment = [
            "UV_PROJECT_ENVIRONMENT": venvDir.path,
            "UV_PYTHON_INSTALL_DIR": appSupportDir.appendingPathComponent("python_runtimes").path,
            "UV_CACHE_DIR": appSupportDir.appendingPathComponent("uv_cache").path,
            "UV_PYTHON_PREFERENCE": "only-managed",
            "PYTHONUNBUFFERED": "1",
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "HF_HOME": hfCacheDir.path
        ]

        // Start monitoring specific model directory size for progress
        let monitorTask = startDirectoryMonitoring(modelCacheDir)

        await runProcessWithOutput(process, subStep: .downloadingGeneration)

        monitorTask.cancel()
        resetDownloadProgress()

        // Save the selected model choice
        UserDefaults.standard.set(selectedModelChoice.modelVariant, forKey: "SelectedHunyuanModel")
        setupProgress = 0.95
    }

    // MARK: - Process Execution

    private func runProcessWithOutput(_ process: Process, subStep: SetupSubStep) async {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let pipe = Pipe()
                let errorPipe = Pipe()
                process.standardOutput = pipe
                process.standardError = errorPipe

                pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
                    let data = handle.availableData
                    if !data.isEmpty, let output = String(data: data, encoding: .utf8) {
                        Task { @MainActor in
                            self?.appendConsoleOutput(output, for: subStep)
                        }
                    }
                }

                errorPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
                    let data = handle.availableData
                    if !data.isEmpty, let output = String(data: data, encoding: .utf8) {
                        Task { @MainActor in
                            self?.appendConsoleOutput(output, for: subStep)
                        }
                    }
                }

                do {
                    try process.run()
                    process.waitUntilExit()
                } catch {
                    Task { @MainActor in
                        self.appendConsoleOutput("Error: \(error.localizedDescription)", for: subStep)
                    }
                }

                pipe.fileHandleForReading.readabilityHandler = nil
                errorPipe.fileHandleForReading.readabilityHandler = nil
                continuation.resume()
            }
        }
    }

    // MARK: - Directory Size Monitoring

    private func startDirectoryMonitoring(_ directory: URL) -> Task<Void, Never> {
        Task {
            while !Task.isCancelled {
                let size = await getDirectorySize(directory)
                let total = await MainActor.run { downloadTotalBytes }

                await MainActor.run {
                    updateDownloadProgress(downloaded: size, total: downloadTotalBytes)
                }

                // Stop monitoring once download is complete
                if size >= total {
                    break
                }

                try? await Task.sleep(nanoseconds: 500_000_000)  // 500ms for smoother updates
            }
        }
    }

    private func getDirectorySize(_ url: URL) async -> Int64 {
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
                        continuation.resume(returning: sizeKB * 1024)  // Convert KB to bytes
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
