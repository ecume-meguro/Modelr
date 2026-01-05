import Foundation

enum GenerationPreset: String, CaseIterable, Identifiable {
    // Fast model (Hunyuan3D-2 Mini)
    case extraDraft = "Extra Draft"
    case draft = "Draft"
    case normal = "Normal"
    case high = "High"
    case quality = "Quality"
    // Quality model (Hunyuan3D-2.1) - requires additional download
    case xQuality = "XQuality"
    case xQualityHigh = "XQuality High"
    case xQualityMax = "XQuality Max"

    var id: String { rawValue }

    /// Whether this preset uses the large model (requires extra download)
    var usesLargeModel: Bool {
        switch self {
        case .extraDraft, .draft, .normal, .high, .quality:
            return false
        case .xQuality, .xQualityHigh, .xQualityMax:
            return true
        }
    }

    /// The model variant to use ("mini" or "std")
    var modelVariant: String {
        usesLargeModel ? "std" : "mini"
    }

    var steps: Int {
        switch self {
        case .extraDraft: return 15
        case .draft: return 25
        case .normal, .xQuality: return 35
        case .high, .xQualityHigh: return 50
        case .quality, .xQualityMax: return 75
        }
    }

    var resolution: Int {
        switch self {
        case .extraDraft: return 128
        case .draft: return 192
        case .normal, .xQuality: return 256
        case .high, .xQualityHigh: return 384
        case .quality, .xQualityMax: return 512
        }
    }

    var description: String {
        switch self {
        case .extraDraft: return "Fastest preview"
        case .draft: return "Quick preview"
        case .normal: return "Balanced"
        case .high: return "High quality"
        case .quality: return "Best fast model"
        case .xQuality: return "2.1 model, balanced"
        case .xQualityHigh: return "2.1 model, high quality"
        case .xQualityMax: return "2.1 model, maximum quality"
        }
    }

    var estimatedTime: String {
        switch self {
        case .extraDraft: return "~30s"
        case .draft: return "~1m"
        case .normal: return "~2m"
        case .high: return "~4m"
        case .quality: return "~6m"
        case .xQuality: return "~3m"
        case .xQualityHigh: return "~5m"
        case .xQualityMax: return "~10m"
        }
    }

    var downloadSize: String? {
        usesLargeModel ? "~7 GB" : nil
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
