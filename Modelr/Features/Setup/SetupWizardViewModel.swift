import Foundation
import SwiftUI

/// Wizard step identifiers
enum SetupWizardStep: Int, CaseIterable {
    case welcome = 0
    case download = 1
    case complete = 2

    var title: String {
        switch self {
        case .welcome: return "Welcome"
        case .download: return "Download"
        case .complete: return "Ready"
        }
    }

    var next: SetupWizardStep? {
        SetupWizardStep(rawValue: rawValue + 1)
    }

    var previous: SetupWizardStep? {
        SetupWizardStep(rawValue: rawValue - 1)
    }
}

/// ViewModel for the setup wizard
@MainActor
class SetupWizardViewModel: ObservableObject {
    // MARK: - Published State

    @Published var currentStep: SetupWizardStep = .welcome
    @Published var selectedModelChoice: SetupModelChoice = .fast
    @Published var isDownloading = false
    @Published var downloadError: Error?
    @Published var isComplete = false

    // Environment setup state
    @Published var isSettingUpEnvironment = false
    @Published var environmentSetupStatus = ""
    @Published var environmentSetupProgress: Double = 0
    @Published var environmentSetupLogs: [String] = []

    // Enhanced progress tracking
    @Published var taskTracker: SetupTaskTracker?
    @Published var currentTaskName: String = ""
    @Published var currentTaskProgress: Double = 0
    @Published var overallProgress: Double = 0
    @Published var overallTimeRemaining: String = ""
    @Published var currentTaskTimeRemaining: String = ""
    @Published var downloadSpeed: String = ""

    // System info
    let systemRAM: UInt64
    let availableSpace: Int64

    // MARK: - Dependencies

    private let dependencyService = PythonDependencyService()
    private var downloadTask: Task<Void, Never>?
    private let processTracker = ProcessTracker()
    private let stateManager = SetupStateManager.shared
    private var setupState: SetupStateManager.SetupState?
    private var sleepPreventionActivity: NSObjectProtocol?

    // Filesystem-based progress monitor (replaces complex JSON parsing)
    private let downloadMonitor = DownloadMonitor()

    // Granular file tracking for resume support
    private var downloadedFiles: Set<String> = []
    private let downloadedFilesKey = "SetupDownloadedFiles"

    // MARK: - Initialization

    init() {
        systemRAM = ProcessInfo.processInfo.physicalMemory

        // Get available disk space
        if let values = try? FileManager.default.attributesOfFileSystem(forPath: NSHomeDirectory()),
           let freeSize = values[.systemFreeSize] as? NSNumber {
            availableSpace = freeSize.int64Value
        } else {
            availableSpace = 0
        }

        // Default to fast (mini) model
        selectedModelChoice = .fast

        // Wire up process tracker to dependency service
        dependencyService.processTracker = processTracker

        // Load previously downloaded files for resume support
        loadDownloadedFilesState()
    }

    deinit {
        // Ensure cleanup if view is dismissed during setup
        downloadTask?.cancel()
        processTracker.killAll()

        // Stop download monitor synchronously - it's safe to call from any thread
        // since it only cancels a timer and doesn't access UI state
        downloadMonitor.stopMonitoringSync()

        if let activity = sleepPreventionActivity {
            ProcessInfo.processInfo.endActivity(activity)
        }
    }

    // MARK: - Navigation

    func goToNext() {
        guard let next = currentStep.next else { return }

        if currentStep == .welcome {
            // Start download when moving from welcome to download step
            startSetup()
        }

        withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
            currentStep = next
        }
    }

    func goToPrevious() {
        guard let previous = currentStep.previous else { return }

        // Cancel download if going back from download step
        if currentStep == .download && isDownloading {
            cancelDownload()
        }

        withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
            currentStep = previous
        }
    }

    func skipToComplete() {
        withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
            currentStep = .complete
            isComplete = true
        }
    }

    // MARK: - Setup Process

    func startSetup() {
        guard !isDownloading else { return }

        // Check network connectivity first
        guard NetworkMonitor.isNetworkAvailable() else {
            let errorMsg = NetworkMonitor.getNetworkErrorMessage(connectionType: NetworkMonitor.shared.connectionType)
            downloadError = NSError(domain: "Setup", code: -1, userInfo: [
                NSLocalizedDescriptionKey: "No internet connection",
                NSLocalizedRecoverySuggestionErrorKey: errorMsg
            ])
            return
        }

        isDownloading = true
        downloadError = nil
        isSettingUpEnvironment = true
        environmentSetupStatus = "Preparing environments..."
        environmentSetupProgress = 0
        environmentSetupLogs = []

        // Initialize task tracker immediately to show initial time estimate
        taskTracker = SetupTaskTracker(modelChoice: selectedModelChoice.modelVariant)
        updateProgressFromTracker()

        // Start filesystem-based download monitor
        startDownloadMonitor()

        // Prevent system sleep during setup
        sleepPreventionActivity = ProcessInfo.processInfo.beginActivity(
            options: [.idleSystemSleepDisabled, .userInitiated],
            reason: "Downloading models and setting up environments"
        )

        // Load or create setup state
        setupState = stateManager.loadState() ?? stateManager.createNewState(modelVariant: selectedModelChoice.modelVariant)

        downloadTask = Task { [weak self] in
            await self?.performSetup()
        }
    }

    private func performSetup() async {
        do {
            // Step 1: Set up Python environments
            environmentSetupStatus = "Setting up Python environments..."
            let envSuccess = await setupPythonEnvironments()

            guard envSuccess else {
                throw NSError(domain: "Setup", code: 1, userInfo: [
                    NSLocalizedDescriptionKey: "Failed to set up Python environments",
                    NSLocalizedRecoverySuggestionErrorKey: "Check your internet connection and try again. View logs for details."
                ])
            }

            // Step 2: Model download happens via the environment setup
            isSettingUpEnvironment = false
            environmentSetupStatus = "Setup complete"

            // Step 3: Mark setup as complete
            if downloadError == nil, let state = setupState {
                try stateManager.markSetupFullyComplete(modelVariant: state.modelVariant)
                markSetupComplete()
                stopDownloadMonitor()
                withAnimation {
                    currentStep = .complete
                    isComplete = true
                }
            }
        } catch {
            downloadError = error
            isSettingUpEnvironment = false
            stopDownloadMonitor()

            // Save failed state for potential retry
            if var state = setupState, let currentStage = state.currentStage {
                try? stateManager.markStageFailed(currentStage, error: error.localizedDescription, state: &state)
            }
        }

        isDownloading = false

        // End sleep prevention
        if let activity = sleepPreventionActivity {
            ProcessInfo.processInfo.endActivity(activity)
            sleepPreventionActivity = nil
        }
    }

    func cancelDownload() {
        print("[Setup] Cancelling setup...")

        // Cancel the task
        downloadTask?.cancel()
        downloadTask = nil

        // Kill all spawned processes
        processTracker.killAll()

        // Stop download monitoring
        stopDownloadMonitor()

        // End sleep prevention
        if let activity = sleepPreventionActivity {
            ProcessInfo.processInfo.endActivity(activity)
            sleepPreventionActivity = nil
        }

        // Reset UI state
        isDownloading = false
        isSettingUpEnvironment = false

        print("[Setup] Setup cancelled successfully")
    }

    private func setupPythonEnvironments() async -> Bool {
        let success = await dependencyService.setup(modelChoice: selectedModelChoice) { [weak self] update in
            Task { @MainActor in
                guard let self = self else { return }

                // Map stage to task index and update tracker
                let taskIndex: Int
                let taskName: String

                switch update.stage {
                case .preparing:
                    taskIndex = 0
                    taskName = "Preparing environment"
                case .syncingSAM:
                    taskIndex = 1
                    taskName = "Initializing AI runtime"
                case .downloadingSAM:
                    taskIndex = 2
                    taskName = "Installing vision models"
                case .syncingHunyuan:
                    taskIndex = 3
                    taskName = "Configuring 3D pipeline"
                case .downloadingHunyuan:
                    taskIndex = 4
                    taskName = "Downloading 3D generation model"
                case .completed:
                    taskIndex = -1
                    taskName = "Ready"
                    self.taskTracker?.completeCurrentTask()
                case .failed:
                    taskIndex = -1
                    taskName = "Setup failed"
                    self.taskTracker?.failCurrentTask()
                }

                // Update current task if changed
                if taskIndex >= 0 && self.taskTracker?.currentTaskIndex != taskIndex {
                    if let tracker = self.taskTracker, tracker.currentTaskIndex < taskIndex {
                        self.taskTracker?.completeCurrentTask()
                    }
                    self.taskTracker?.startTask(at: taskIndex)
                }

                self.environmentSetupStatus = taskName
                self.currentTaskName = taskName

                // Try to parse JSON progress from log line
                if let logLine = update.logLine {
                    self.processLogLine(logLine)
                }

                // Update overall progress from tracker
                self.updateProgressFromTracker()
            }
        }

        return success
    }

    /// Process a log line - just add to logs, progress comes from filesystem monitor
    private func processLogLine(_ line: String) {
        // Skip JSON lines (they were for the old broken progress system)
        if line.hasPrefix("{") && line.hasSuffix("}") {
            return
        }

        // Add to log display
        environmentSetupLogs.append(line)
        if environmentSetupLogs.count > AppConstants.maxConsoleOutputLines {
            environmentSetupLogs.removeFirst()
        }
    }

    /// Update published progress properties from tracker
    private func updateProgressFromTracker() {
        guard let tracker = taskTracker else { return }

        overallProgress = tracker.overallProgress
        overallTimeRemaining = tracker.formattedTimeRemaining
        currentTaskProgress = tracker.currentTask?.progress ?? 0
        environmentSetupProgress = overallProgress
    }

    /// Start filesystem-based download monitoring
    private func startDownloadMonitor() {
        // Calculate total expected bytes (only mini model supported)
        let config = ConfigurationService.shared
        let samBytes = Int64(config.samModelSizeGb * 1_000_000_000)
        let vlmBytes = Int64(config.vlmModelSizeGb * 1_000_000_000)
        let hunyuanBytes = Int64(config.hunyuanMiniModelSizeGb * 1_000_000_000)
        let totalBytes = samBytes + vlmBytes + hunyuanBytes

        downloadMonitor.startMonitoring(
            directory: PathManager.modelsDirectory,
            totalBytes: totalBytes
        ) { [weak self] monitor in
            Task { @MainActor in
                guard let self = self else { return }

                // Update progress from filesystem monitor
                self.currentTaskProgress = monitor.progress
                self.downloadSpeed = monitor.formattedSpeed
                self.currentTaskTimeRemaining = monitor.formattedTimeRemaining

                // Also update task tracker with real progress
                self.taskTracker?.updateTaskProgress(monitor.progress)
            }
        }
    }

    /// Stop download monitoring
    private func stopDownloadMonitor() {
        downloadMonitor.stopMonitoring()
    }

    private func markSetupComplete() {
        // Write setup completion marker with model variant
        do {
            try PathManager.markSetupComplete(modelVariant: selectedModelChoice.modelVariant)
        } catch {
            print("[SetupWizard] Failed to mark setup complete: \(error)")
        }
    }

    // MARK: - Model Info

    var formattedSystemRAM: String {
        ByteCountFormatter.string(fromByteCount: Int64(systemRAM), countStyle: .memory)
    }

    var formattedAvailableSpace: String {
        ByteCountFormatter.string(fromByteCount: availableSpace, countStyle: .file)
    }

    var hasEnoughSpace: Bool {
        return availableSpace > selectedModelChoice.sizeBytes + (5 * 1024 * 1024 * 1024) // Model size + 5GB buffer
    }

    // MARK: - Granular Resume Support

    /// Load the set of already downloaded files from persistent storage
    private func loadDownloadedFilesState() {
        if let savedFiles = UserDefaults.standard.array(forKey: downloadedFilesKey) as? [String] {
            downloadedFiles = Set(savedFiles)
            print("[Setup] Loaded \(downloadedFiles.count) previously downloaded files")
        }

        // Also scan models directory for existing complete files
        scanExistingModelFiles()
    }

    /// Scan the models directory and mark existing complete files as downloaded
    private func scanExistingModelFiles() {
        let modelsDir = PathManager.modelsDirectory
        let fileManager = FileManager.default

        // Key model files and their expected minimum sizes (in bytes)
        let expectedFiles: [(path: String, minSize: Int64)] = [
            ("sam3/model.safetensors", 100_000_000),  // SAM model ~300MB
            ("SmolVLM-256M-Instruct", 100_000_000),   // VLM directory
            ("hunyuan/hunyuan-mini", 500_000_000),    // Hunyuan mini
            ("hunyuan/hunyuan-std", 1_000_000_000)    // Hunyuan standard
        ]

        for (relativePath, minSize) in expectedFiles {
            let fullPath = modelsDir.appendingPathComponent(relativePath)
            var isDirectory: ObjCBool = false

            if fileManager.fileExists(atPath: fullPath.path, isDirectory: &isDirectory) {
                if isDirectory.boolValue {
                    // For directories, check if they contain significant files
                    if let contents = try? fileManager.contentsOfDirectory(atPath: fullPath.path),
                       !contents.isEmpty {
                        downloadedFiles.insert(relativePath)
                    }
                } else {
                    // For files, check size
                    if let attrs = try? fileManager.attributesOfItem(atPath: fullPath.path),
                       let fileSize = attrs[.size] as? Int64,
                       fileSize >= minSize {
                        downloadedFiles.insert(relativePath)
                    }
                }
            }
        }

        saveDownloadedFilesState()
    }

    /// Save the set of downloaded files to persistent storage
    private func saveDownloadedFilesState() {
        UserDefaults.standard.set(Array(downloadedFiles), forKey: downloadedFilesKey)
    }

    /// Mark a file or model as successfully downloaded
    func markFileDownloaded(_ identifier: String) {
        downloadedFiles.insert(identifier)
        saveDownloadedFilesState()
        print("[Setup] Marked '\(identifier)' as downloaded")
    }

    /// Check if a file or model has already been downloaded
    func isFileDownloaded(_ identifier: String) -> Bool {
        return downloadedFiles.contains(identifier)
    }

    /// Clear downloaded files state (for full reset)
    func clearDownloadedFilesState() {
        downloadedFiles.removeAll()
        UserDefaults.standard.removeObject(forKey: downloadedFilesKey)
        print("[Setup] Cleared downloaded files state")
    }

    /// Get the list of files that still need to be downloaded
    func getPendingDownloads() -> [String] {
        let allFiles = ["sam3", "vlm", "hunyuan"]
        return allFiles.filter { !isFileDownloaded($0) }
    }
}
