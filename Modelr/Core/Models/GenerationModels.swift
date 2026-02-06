import Foundation

// MARK: - Hunyuan Model Variants

/// Hunyuan model variants available for 3D generation
enum HunyuanVariant: String, CaseIterable, Identifiable, Codable {
    case mini = "mini"  // Hunyuan3D-2 Mini - only supported variant

    var id: String { rawValue }
    var displayName: String { "Hunyuan3D-2 Mini" }
    var shortName: String { "Mini" }
    var description: String { "Fast generation with good quality" }
    var downloadSize: String { "~3.8 GB" }
    var sizeBytes: Int64 { AppConstants.hunyuanMiniModelBytes }
    var color: String { "blue" }

    var isDownloaded: Bool {
        PathManager.isHunyuanModelDownloaded(variant: rawValue)
    }

    var presets: [GenerationPreset] {
        [.miniDraft, .miniNormal, .miniHigh, .miniMax]
    }

    var defaultPreset: GenerationPreset { .miniNormal }
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
    case miniDraft = "Draft"
    case miniNormal = "Normal"
    case miniHigh = "High"
    case miniMax = "Max"

    var id: String { rawValue }
    var shortName: String { rawValue }
    var modelFamily: GeneratorModel { .hunyuan }
    var modelVariant: String { "mini" }
    var variant: HunyuanVariant { .mini }
    var usesHunyuan21: Bool { false }
    var isModelDownloaded: Bool { variant.isDownloaded }
    var requiresDownload: Bool { !isModelDownloaded }

    // MARK: - Hunyuan-specific settings

    var steps: Int {
        switch self {
        case .miniDraft: return 25
        case .miniNormal: return 35
        case .miniHigh: return 50
        case .miniMax: return 75
        }
    }

    var resolution: Int {
        switch self {
        case .miniDraft: return 192
        case .miniNormal: return 256
        case .miniHigh: return 384
        case .miniMax: return 512
        }
    }

    var description: String {
        switch self {
        case .miniDraft: return "Quick preview"
        case .miniNormal: return "Balanced"
        case .miniHigh: return "High quality"
        case .miniMax: return "Maximum quality"
        }
    }

    var estimatedTime: String {
        switch self {
        case .miniDraft: return "~1m"
        case .miniNormal: return "~2m"
        case .miniHigh: return "~4m"
        case .miniMax: return "~6m"
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

    /// User-friendly display name for the stage
    var displayName: String {
        switch self {
        case .setup: return "Initializing"
        case .downloading: return "Downloading Model"
        case .extracting: return "Processing"
        case .loading: return "Preparing"
        case .diffusion: return "Generating 3D"
        case .volumeDecoding: return "Decoding Volume"
        case .saving: return "Saving"
        case .handoff: return "Finalizing"
        }
    }

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
