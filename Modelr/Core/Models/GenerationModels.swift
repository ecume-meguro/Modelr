import Foundation

// MARK: - Hunyuan Model Variants

/// Hunyuan model variants available for 3D generation
enum HunyuanVariant: String, CaseIterable, Identifiable, Codable {
    case mini = "mini"      // Hunyuan3D-2 Mini - faster, smaller
    case standard = "std"   // Hunyuan3D-2.1 Standard - higher quality

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .mini: return "Hunyuan3D-2 Mini"
        case .standard: return "Hunyuan3D-2.1 Standard"
        }
    }

    var shortName: String {
        switch self {
        case .mini: return "Mini"
        case .standard: return "Standard"
        }
    }

    var description: String {
        switch self {
        case .mini: return "Fast generation with good quality"
        case .standard: return "Higher quality with more details"
        }
    }

    var downloadSize: String {
        switch self {
        case .mini: return "~3.8 GB"
        case .standard: return "~8.5 GB"
        }
    }

    var sizeBytes: Int64 {
        switch self {
        case .mini: return AppConstants.hunyuanMiniModelBytes
        case .standard: return AppConstants.hunyuanStdModelBytes
        }
    }

    var isDownloaded: Bool {
        PathManager.isHunyuanModelDownloaded(variant: rawValue)
    }

    /// Presets available for this variant
    var presets: [GenerationPreset] {
        switch self {
        case .mini:
            return [.miniDraft, .miniNormal, .miniHigh, .miniMax]
        case .standard:
            return [.stdDraft, .stdNormal, .stdHigh, .stdMax]
        }
    }

    var defaultPreset: GenerationPreset {
        switch self {
        case .mini: return .miniNormal
        case .standard: return .stdNormal
        }
    }

    var color: String {
        switch self {
        case .mini: return "blue"
        case .standard: return "purple"
        }
    }
}

/// Generator model families
enum GeneratorModel: String, CaseIterable, Identifiable {
    case hunyuan = "Hunyuan3D"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .hunyuan: return "Hunyuan3D"
        }
    }

    /// All variants available for this model
    var variants: [HunyuanVariant] {
        switch self {
        case .hunyuan:
            return HunyuanVariant.allCases
        }
    }

    /// All presets across all variants
    var allPresets: [GenerationPreset] {
        switch self {
        case .hunyuan:
            return GenerationPreset.allCases
        }
    }
}

enum GenerationPreset: String, CaseIterable, Identifiable {
    // Hunyuan3D-2 Mini presets (fast, smaller model ~3.8GB)
    case miniDraft = "Mini Draft"
    case miniNormal = "Mini Normal"
    case miniHigh = "Mini High"
    case miniMax = "Mini Max"

    // Hunyuan3D-2.1 Standard presets (higher quality ~8.5GB)
    case stdDraft = "Standard Draft"
    case stdNormal = "Standard Normal"
    case stdHigh = "Standard High"
    case stdMax = "Standard Max"

    var id: String { rawValue }

    /// Display name without variant prefix
    var shortName: String {
        switch self {
        case .miniDraft, .stdDraft: return "Draft"
        case .miniNormal, .stdNormal: return "Normal"
        case .miniHigh, .stdHigh: return "High"
        case .miniMax, .stdMax: return "Max"
        }
    }

    /// The model family to use
    var modelFamily: GeneratorModel {
        return .hunyuan
    }

    /// The model variant within the family
    var modelVariant: String {
        switch self {
        case .miniDraft, .miniNormal, .miniHigh, .miniMax:
            return "mini"
        case .stdDraft, .stdNormal, .stdHigh, .stdMax:
            return "std"
        }
    }

    /// The variant enum
    var variant: HunyuanVariant {
        switch self {
        case .miniDraft, .miniNormal, .miniHigh, .miniMax:
            return .mini
        case .stdDraft, .stdNormal, .stdHigh, .stdMax:
            return .standard
        }
    }

    /// Whether this preset uses the Hunyuan 2.1 (standard/larger) model
    var usesHunyuan21: Bool {
        modelVariant == "std"
    }

    /// Whether the required model is downloaded
    var isModelDownloaded: Bool {
        variant.isDownloaded
    }

    /// Whether this preset requires a model download before use
    var requiresDownload: Bool {
        !isModelDownloaded
    }

    // MARK: - Hunyuan-specific settings

    var steps: Int {
        switch self {
        case .miniDraft, .stdDraft: return 25
        case .miniNormal, .stdNormal: return 35
        case .miniHigh, .stdHigh: return 50
        case .miniMax, .stdMax: return 75
        }
    }

    var resolution: Int {
        switch self {
        case .miniDraft, .stdDraft: return 192
        case .miniNormal, .stdNormal: return 256
        case .miniHigh, .stdHigh: return 384
        case .miniMax, .stdMax: return 512
        }
    }

    // MARK: - Display properties

    var description: String {
        switch self {
        case .miniDraft, .stdDraft: return "Quick preview"
        case .miniNormal, .stdNormal: return "Balanced"
        case .miniHigh, .stdHigh: return "High quality"
        case .miniMax, .stdMax: return "Maximum quality"
        }
    }

    var estimatedTime: String {
        switch self {
        case .miniDraft: return "~1m"
        case .miniNormal: return "~2m"
        case .miniHigh: return "~4m"
        case .miniMax: return "~6m"
        case .stdDraft: return "~2m"
        case .stdNormal: return "~4m"
        case .stdHigh: return "~6m"
        case .stdMax: return "~10m"
        }
    }
}

// Keep for backwards compatibility
typealias QualityPreset = GenerationPreset

struct GenerationProgress {
    var stage: String = ""
    var currentStep: Int = 0
    var totalSteps: Int = 0
    var iterationsPerSecond: Double = 0
    var elapsedTime: TimeInterval = 0
    var estimatedRemaining: TimeInterval = 0

    var isActive: Bool { totalSteps > 0 }

    var percentComplete: Double {
        guard totalSteps > 0 else { return 0 }
        return Double(currentStep) / Double(totalSteps) * 100
    }

    var formattedSpeed: String {
        if iterationsPerSecond >= 1 {
            return String(format: "%.1f it/s", iterationsPerSecond)
        } else if iterationsPerSecond > 0 {
            return String(format: "%.1f s/it", 1.0 / iterationsPerSecond)
        }
        return ""
    }

    var formattedETA: String {
        guard estimatedRemaining > 0 else { return "" }
        let minutes = Int(estimatedRemaining) / 60
        let seconds = Int(estimatedRemaining) % 60
        if minutes > 0 {
            return String(format: "%d:%02d remaining", minutes, seconds)
        } else {
            return String(format: "%ds remaining", seconds)
        }
    }

    var formattedElapsed: String {
        let minutes = Int(elapsedTime) / 60
        let seconds = Int(elapsedTime) % 60
        if minutes > 0 {
            return String(format: "%d:%02d elapsed", minutes, seconds)
        } else {
            return String(format: "%ds elapsed", seconds)
        }
    }
}

/// Stages of the 3D generation pipeline
enum GenerationStage: String, CaseIterable {
    // Common stages
    case setup = "Setting Up"
    case downloading = "Downloading Model"
    case extracting = "Extracting"
    case loading = "Loading Model"

    // Hunyuan-specific stages
    case diffusion = "Diffusion Sampling"
    case volumeDecoding = "Volume Decoding"

    // Common end stages
    case saving = "Saving"
    case handoff = "Handing Off"

    /// Get stages for a specific model family
    static func stages(for model: GeneratorModel) -> [GenerationStage] {
        switch model {
        case .hunyuan:
            return [.downloading, .extracting, .loading, .diffusion, .volumeDecoding, .saving, .handoff]
        }
    }
}

/// Progress information for a generation stage
struct StageProgress {
    var status: StageStatus = .pending
    var progress: Double = 0
    var detail: String = ""
}

/// Status of a generation stage
enum StageStatus {
    case pending
    case inProgress
    case completed
    case cancelled
    case failed
}
