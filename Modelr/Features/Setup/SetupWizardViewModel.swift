import os.log
import Foundation
import SwiftUI
import Combine

/// Wizard step identifiers
enum SetupWizardStep: Int, CaseIterable {
    case welcome = 0
    case modelSelection = 1
    case download = 2
    case complete = 3

    var title: String {
        switch self {
        case .welcome: return "Welcome"
        case .modelSelection: return "Choose Model"
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
    @Published var downloadProgress: ModelDownloadProgress?
    @Published var downloadError: Error?
    @Published var isComplete = false

    // Environment setup state
    @Published var isSettingUpEnvironment = false
    @Published var environmentSetupStatus = ""
    @Published var environmentSetupProgress: Double = 0
    @Published var environmentSetupLogs: [String] = []

    // System info
    let systemRAM: UInt64
    let availableSpace: Int64

    // MARK: - Dependencies

    private let dependencyService = PythonDependencyService()
    private var cancellables = Set<AnyCancellable>()
    private var downloadTask: Task<Void, Never>?

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
    }

    // MARK: - Navigation

    func goToNext() {
        guard let next = currentStep.next else { return }

        if currentStep == .modelSelection {
            // Start download when moving from selection to download step
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

        isDownloading = true
        downloadError = nil
        isSettingUpEnvironment = true
        environmentSetupStatus = "Preparing environments..."
        environmentSetupProgress = 0
        environmentSetupLogs = []

        downloadTask = Task {
            do {
                // Step 1: Set up Python environments
                environmentSetupStatus = "Setting up Python environments..."
                let envSuccess = await setupPythonEnvironments()

                guard envSuccess else {
                    throw NSError(domain: "Setup", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to set up Python environments"])
                }

                // Step 2: Model download happens via the environment setup
                isSettingUpEnvironment = false
                environmentSetupStatus = "Setup complete"

                // Step 3: Mark setup as complete
                if downloadError == nil {
                    markSetupComplete()
                    withAnimation {
                        currentStep = .complete
                        isComplete = true
                    }
                }
            } catch {
                downloadError = error
                isSettingUpEnvironment = false
            }

            isDownloading = false
        }
    }

    func cancelDownload() {
        downloadTask?.cancel()
        downloadTask = nil
        isDownloading = false
        downloadProgress = nil
    }

    private func setupPythonEnvironments() async -> Bool {
        let success = await dependencyService.setup(modelChoice: selectedModelChoice) { [weak self] update in
            Task { @MainActor in
                guard let self = self else { return }

                switch update.stage {
                case .preparing:
                    self.environmentSetupStatus = "Preparing resources..."
                    self.environmentSetupProgress = 0.05
                case .syncingSAM:
                    self.environmentSetupStatus = "Setting up segmentation environment..."
                    self.environmentSetupProgress = 0.2
                case .downloadingSAM:
                    self.environmentSetupStatus = "Downloading segmentation model..."
                    self.environmentSetupProgress = 0.35
                case .syncingHunyuan:
                    self.environmentSetupStatus = "Setting up 3D generation environment..."
                    self.environmentSetupProgress = 0.5
                case .downloadingHunyuan:
                    self.environmentSetupStatus = "Downloading 3D model..."
                    self.environmentSetupProgress = 0.6
                case .syncingTools:
                    self.environmentSetupStatus = "Setting up mesh tools..."
                    self.environmentSetupProgress = 0.8
                case .completed:
                    self.environmentSetupStatus = "Environment ready"
                    self.environmentSetupProgress = 1.0
                case .failed:
                    self.environmentSetupStatus = "Setup failed"
                }

                if let logLine = update.logLine {
                    self.environmentSetupLogs.append(logLine)
                    // Keep only last 50 lines
                    if self.environmentSetupLogs.count > 50 {
                        self.environmentSetupLogs.removeFirst()
                    }
                }
            }
        }

        return success
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
}
