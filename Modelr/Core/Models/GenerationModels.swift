import Foundation

enum GenerationPreset: String, CaseIterable, Identifiable {
    // Fast model (Hunyuan3D-2 Mini)
    case draft = "Draft"
    case normal = "Normal"
    case high = "High"
    case max = "Max"
    // Quality model (Hunyuan3D-2.1) - requires additional download
    case qualityDraft = "Quality Draft"
    case qualityNormal = "Quality Normal"
    case qualityHigh = "Quality High"
    case qualityMax = "Quality Max"

    var id: String { rawValue }

    /// Model category for grouping in UI
    enum ModelCategory: String {
        case fast = "Fast"        // mini
        case quality = "Quality"  // std (2.1)
    }

    var category: ModelCategory {
        switch self {
        case .draft, .normal, .high, .max:
            return .fast
        case .qualityDraft, .qualityNormal, .qualityHigh, .qualityMax:
            return .quality
        }
    }

    /// Whether this preset uses the large model (requires extra download)
    var usesLargeModel: Bool {
        category == .quality
    }

    /// Whether this preset uses the mini repo
    var usesMiniRepo: Bool {
        category == .fast
    }

    /// The model variant to use ("mini" or "std")
    var modelVariant: String {
        switch category {
        case .fast: return "mini"
        case .quality: return "std"
        }
    }

    var steps: Int {
        switch self {
        case .draft, .qualityDraft: return 25
        case .normal, .qualityNormal: return 35
        case .high, .qualityHigh: return 50
        case .max, .qualityMax: return 75
        }
    }

    var resolution: Int {
        switch self {
        case .draft, .qualityDraft: return 192
        case .normal, .qualityNormal: return 256
        case .high, .qualityHigh: return 384
        case .max, .qualityMax: return 512
        }
    }

    var description: String {
        switch self {
        case .draft: return "Quick preview"
        case .normal: return "Balanced"
        case .high: return "High quality"
        case .max: return "Maximum quality"
        case .qualityDraft: return "2.1 quick preview"
        case .qualityNormal: return "2.1 balanced"
        case .qualityHigh: return "2.1 high quality"
        case .qualityMax: return "2.1 maximum quality"
        }
    }

    var estimatedTime: String {
        switch self {
        case .draft: return "~1m"
        case .normal: return "~2m"
        case .high: return "~4m"
        case .max: return "~6m"
        case .qualityDraft: return "~2m"
        case .qualityNormal: return "~3m"
        case .qualityHigh: return "~5m"
        case .qualityMax: return "~10m"
        }
    }

    var downloadSize: String? {
        usesLargeModel ? SetupModelChoice.quality.downloadSize : nil
    }

    /// Presets grouped by category for UI display
    static var fastPresets: [GenerationPreset] {
        [.draft, .normal, .high, .max]
    }

    static var qualityPresets: [GenerationPreset] {
        [.qualityDraft, .qualityNormal, .qualityHigh, .qualityMax]
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
