import Foundation

enum GenerationPreset: String, CaseIterable, Identifiable {
    // Hunyuan3D-2 Mini presets (fast, smaller model)
    case draft = "Draft"
    case normal = "Normal"
    case high = "High"
    case max = "Max"

    // Hunyuan3D-2.1 Standard preset (larger model, better quality)
    case ultra = "Ultra"

    var id: String { rawValue }

    /// The model variant to use
    var modelVariant: String {
        switch self {
        case .draft, .normal, .high, .max:
            return "mini"
        case .ultra:
            return "std"
        }
    }

    /// Whether this preset uses the Hunyuan 2.1 (standard/larger) model
    var usesHunyuan21: Bool {
        modelVariant == "std"
    }

    /// Whether this preset requires a separate model download
    var requiresAdditionalDownload: Bool {
        usesHunyuan21
    }

    /// Download size for the required model (approximate)
    var modelDownloadSize: String {
        switch self {
        case .ultra:
            return "~8.5 GB"
        default:
            return ""
        }
    }

    var steps: Int {
        switch self {
        case .draft: return 25
        case .normal: return 35
        case .high: return 50
        case .max: return 75
        case .ultra: return 50
        }
    }

    var resolution: Int {
        switch self {
        case .draft: return 192
        case .normal: return 256
        case .high: return 384
        case .max: return 512
        case .ultra: return 512
        }
    }

    var description: String {
        switch self {
        case .draft: return "Quick preview"
        case .normal: return "Balanced"
        case .high: return "High quality"
        case .max: return "Maximum quality"
        case .ultra: return "Hunyuan 2.1 model"
        }
    }

    var estimatedTime: String {
        switch self {
        case .draft: return "~1m"
        case .normal: return "~2m"
        case .high: return "~4m"
        case .max: return "~6m"
        case .ultra: return "~8m"
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
    case downloading = "Downloading Model"
    case extracting = "Extracting"
    case loading = "Loading Model"
    case diffusion = "Diffusion Sampling"
    case volumeDecoding = "Volume Decoding"
    case saving = "Saving"
    case handoff = "Handing Off"
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
