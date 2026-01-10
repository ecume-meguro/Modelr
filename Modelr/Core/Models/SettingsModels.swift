import Foundation

// MARK: - User Settings

/// Memory loading strategy preference
enum MemoryStrategyPreference: String, CaseIterable, Codable {
    case auto = "auto"
    case conservative = "conservative"
    case aggressive = "aggressive"

    var displayName: String {
        switch self {
        case .auto: return "Auto"
        case .conservative: return "Conservative"
        case .aggressive: return "Aggressive"
        }
    }

    var description: String {
        switch self {
        case .auto: return "Automatically select based on system RAM"
        case .conservative: return "Load one model at a time (best for < 16GB RAM)"
        case .aggressive: return "Keep multiple models loaded (best for >= 16GB RAM)"
        }
    }
}

/// User preferences stored in UserDefaults
struct UserSettings: Codable {
    // Memory & Performance
    var memoryStrategy: MemoryStrategyPreference = .auto
    var preloadModelsOnStartup: Bool = true
    var enableAutoDetection: Bool = true

    // Model Selection
    var selectedVariant: HunyuanVariant = .mini // Active model variant for generation
    var preferredModelId: String? = nil // Legacy - use selectedVariant
    var preferredPresetId: String? = nil // User's preferred preset per variant

    // UI Preferences
    var showAdvancedSettings: Bool = false
    var showDownloadWarnings: Bool = true

    // Cache Management
    var maxCacheSizeGB: Double = 50.0

    // Debug
    var enableVerboseLogging: Bool = false

    // MARK: - Keys

    private enum Keys {
        static let settings = "UserSettings"
    }

    // MARK: - Load/Save

    static func load() -> UserSettings {
        guard let data = UserDefaults.standard.data(forKey: Keys.settings),
              let settings = try? JSONDecoder().decode(UserSettings.self, from: data) else {
            return UserSettings()
        }
        return settings
    }

    func save() {
        guard let data = try? JSONEncoder().encode(self) else { return }
        UserDefaults.standard.set(data, forKey: Keys.settings)
    }

    // MARK: - Computed Properties

    /// Get the effective memory strategy based on preference and system RAM
    var effectiveMemoryStrategy: ModelLoadingStrategy {
        switch memoryStrategy {
        case .auto:
            return ProcessInfo.processInfo.physicalMemory >= AppConstants.aggressiveLoadingRAMThreshold
                ? .aggressive : .conservative
        case .conservative:
            return .conservative
        case .aggressive:
            return .aggressive
        }
    }
}

// MARK: - Settings Manager

/// ObservableObject wrapper for UserSettings
@MainActor
class SettingsManager: ObservableObject {
    static let shared = SettingsManager()

    @Published var settings: UserSettings {
        didSet {
            settings.save()
            notifySettingsChanged()
        }
    }

    private init() {
        self.settings = UserSettings.load()
    }

    // MARK: - Convenience Accessors

    var memoryStrategy: MemoryStrategyPreference {
        get { settings.memoryStrategy }
        set { settings.memoryStrategy = newValue }
    }

    var preloadModelsOnStartup: Bool {
        get { settings.preloadModelsOnStartup }
        set { settings.preloadModelsOnStartup = newValue }
    }

    var enableAutoDetection: Bool {
        get { settings.enableAutoDetection }
        set { settings.enableAutoDetection = newValue }
    }

    var selectedVariant: HunyuanVariant {
        get { settings.selectedVariant }
        set { settings.selectedVariant = newValue }
    }

    var preferredModelId: String? {
        get { settings.preferredModelId }
        set { settings.preferredModelId = newValue }
    }

    var preferredPresetId: String? {
        get { settings.preferredPresetId }
        set { settings.preferredPresetId = newValue }
    }

    /// Get presets available for the selected variant
    var availablePresets: [GenerationPreset] {
        selectedVariant.presets
    }

    /// Get the default preset for the selected variant
    var defaultPreset: GenerationPreset {
        selectedVariant.defaultPreset
    }

    var showAdvancedSettings: Bool {
        get { settings.showAdvancedSettings }
        set { settings.showAdvancedSettings = newValue }
    }

    var maxCacheSizeGB: Double {
        get { settings.maxCacheSizeGB }
        set { settings.maxCacheSizeGB = newValue }
    }

    // MARK: - Methods

    func resetToDefaults() {
        settings = UserSettings()
    }

    private func notifySettingsChanged() {
        NotificationCenter.default.post(name: .settingsDidChange, object: nil)
    }
}

// MARK: - Notification

extension Notification.Name {
    static let settingsDidChange = Notification.Name("SettingsDidChange")
}

// MARK: - Storage Info

/// Information about storage usage
struct StorageInfo {
    let modelsSize: Int64
    let cacheSize: Int64
    let projectsSize: Int64
    let totalSize: Int64
    let availableSpace: Int64

    var formattedModelsSize: String {
        ByteCountFormatter.string(fromByteCount: modelsSize, countStyle: .file)
    }

    var formattedCacheSize: String {
        ByteCountFormatter.string(fromByteCount: cacheSize, countStyle: .file)
    }

    var formattedProjectsSize: String {
        ByteCountFormatter.string(fromByteCount: projectsSize, countStyle: .file)
    }

    var formattedTotalSize: String {
        ByteCountFormatter.string(fromByteCount: totalSize, countStyle: .file)
    }

    var formattedAvailableSpace: String {
        ByteCountFormatter.string(fromByteCount: availableSpace, countStyle: .file)
    }

    static func calculate() async -> StorageInfo {
        let modelsSize = await PathManager.getDirectorySize(PathManager.modelsDirectory)
        let cacheSize = await PathManager.getDirectorySize(PathManager.cacheDirectory)
        let projectsSize = await PathManager.getDirectorySize(PathManager.projectsDirectory)
        let totalSize = modelsSize + cacheSize + projectsSize

        // Get available disk space
        var availableSpace: Int64 = 0
        if let values = try? FileManager.default.attributesOfFileSystem(forPath: PathManager.appSupportDirectory.path),
           let freeSize = values[.systemFreeSize] as? NSNumber {
            availableSpace = freeSize.int64Value
        }

        return StorageInfo(
            modelsSize: modelsSize,
            cacheSize: cacheSize,
            projectsSize: projectsSize,
            totalSize: totalSize,
            availableSpace: availableSpace
        )
    }
}

// MARK: - System Info

/// Information about the system for display in settings
struct SystemInfo {
    let totalRAM: UInt64
    let availableRAM: UInt64
    let processorName: String
    let gpuName: String?
    let recommendedStrategy: ModelLoadingStrategy

    var formattedTotalRAM: String {
        ByteCountFormatter.string(fromByteCount: Int64(totalRAM), countStyle: .memory)
    }

    var formattedAvailableRAM: String {
        ByteCountFormatter.string(fromByteCount: Int64(availableRAM), countStyle: .memory)
    }

    static func current() -> SystemInfo {
        let totalRAM = ProcessInfo.processInfo.physicalMemory
        let recommendedStrategy: ModelLoadingStrategy = totalRAM >= AppConstants.aggressiveLoadingRAMThreshold
            ? .aggressive : .conservative

        // Get processor name
        var size: size_t = 0
        sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0)
        var processorName = [CChar](repeating: 0, count: size)
        sysctlbyname("machdep.cpu.brand_string", &processorName, &size, nil, 0)
        let cpuName = String(cString: processorName)

        return SystemInfo(
            totalRAM: totalRAM,
            availableRAM: 0, // Would need additional APIs to get available
            processorName: cpuName.isEmpty ? "Unknown" : cpuName,
            gpuName: nil, // Would need Metal API to get GPU name
            recommendedStrategy: recommendedStrategy
        )
    }
}
