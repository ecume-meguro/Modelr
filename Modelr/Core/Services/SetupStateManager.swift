import Foundation

/// Manages setup state for resume capability and stage-level retry
class SetupStateManager {
    static let shared = SetupStateManager()

    private var stateFilePath: URL {
        PathManager.configDirectory.appendingPathComponent("setup_state.json")
    }

    // MARK: - State Model

    struct SetupState: Codable {
        var modelVariant: String
        var completedStages: Set<SetupStage>
        var currentStage: SetupStage?
        var lastError: String?
        var lastUpdateTime: Date
        var appVersion: String
        var buildNumber: String

        enum SetupStage: String, Codable, CaseIterable {
            case resourceCopy
            case samEnvironment
            case samModelDownload
            case vlmModelDownload
            case hunyuanEnvironment
            case hunyuanModelDownload
        }
    }

    // MARK: - State Management

    /// Load the current setup state
    func loadState() -> SetupState? {
        guard FileManager.default.fileExists(atPath: stateFilePath.path) else {
            return nil
        }

        do {
            let data = try Data(contentsOf: stateFilePath)
            let state = try JSONDecoder().decode(SetupState.self, from: data)

            // Invalidate state if app version changed
            if state.appVersion != PathManager.currentAppVersion ||
               state.buildNumber != PathManager.currentBuildNumber {
                print("[SetupState] State invalidated due to version change")
                try? FileManager.default.removeItem(at: stateFilePath)
                return nil
            }

            return state
        } catch {
            print("[SetupState] Failed to load state: \(error)")
            return nil
        }
    }

    /// Save setup state atomically
    func saveState(_ state: SetupState) throws {
        try PathManager.ensureDirectoryExists(at: PathManager.configDirectory)

        // Encode to data
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        let data = try encoder.encode(state)

        // Write atomically using temp file + replace
        let tempPath = stateFilePath.deletingLastPathComponent()
            .appendingPathComponent("setup_state.tmp")

        try data.write(to: tempPath, options: .atomic)

        // Remove existing file if present, then move temp file
        if FileManager.default.fileExists(atPath: stateFilePath.path) {
            try FileManager.default.removeItem(at: stateFilePath)
        }
        try FileManager.default.moveItem(at: tempPath, to: stateFilePath)

        print("[SetupState] Saved state: current=\(state.currentStage?.rawValue ?? "nil"), completed=\(state.completedStages.count)")
    }

    /// Create a new setup state
    func createNewState(modelVariant: String) -> SetupState {
        SetupState(
            modelVariant: modelVariant,
            completedStages: [],
            currentStage: nil,
            lastError: nil,
            lastUpdateTime: Date(),
            appVersion: PathManager.currentAppVersion,
            buildNumber: PathManager.currentBuildNumber
        )
    }

    /// Mark a stage as completed
    func markStageComplete(_ stage: SetupState.SetupStage, state: inout SetupState) throws {
        state.completedStages.insert(stage)
        state.currentStage = nil
        state.lastError = nil
        state.lastUpdateTime = Date()
        try saveState(state)
    }

    /// Mark a stage as started
    func markStageStarted(_ stage: SetupState.SetupStage, state: inout SetupState) throws {
        state.currentStage = stage
        state.lastUpdateTime = Date()
        try saveState(state)
    }

    /// Mark a stage as failed
    func markStageFailed(_ stage: SetupState.SetupStage, error: String, state: inout SetupState) throws {
        state.currentStage = stage
        state.lastError = error
        state.lastUpdateTime = Date()
        try saveState(state)
    }

    /// Get the next stage to execute
    func getNextStage(state: SetupState) -> SetupState.SetupStage? {
        for stage in SetupState.SetupStage.allCases {
            if !state.completedStages.contains(stage) {
                return stage
            }
        }
        return nil
    }

    /// Check if setup is complete
    func isSetupComplete(state: SetupState) -> Bool {
        state.completedStages.count == SetupState.SetupStage.allCases.count
    }

    /// Clear all setup state
    func clearState() {
        try? FileManager.default.removeItem(at: stateFilePath)
        print("[SetupState] Cleared setup state")
    }

    /// Mark setup as fully complete (converts to PathManager marker)
    func markSetupFullyComplete(modelVariant: String) throws {
        try PathManager.markSetupComplete(modelVariant: modelVariant)
        clearState()
    }
}
