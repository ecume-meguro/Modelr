import Foundation

/// Model choice for initial setup
enum SetupModelChoice: String, CaseIterable {
    case fast = "fast"           // mini (Hunyuan3D-2 Mini)
    case quality = "quality"     // std (Hunyuan3D-2.1)

    var displayName: String {
        switch self {
        case .fast: return "Fast"
        case .quality: return "Quality"
        }
    }

    var modelVariant: String {
        switch self {
        case .fast: return "mini"
        case .quality: return "std"
        }
    }

    /// Download size string - uses config values (no external queries for display)
    var downloadSize: String {
        let sizeGb: Double
        switch self {
        case .fast:
            sizeGb = ConfigurationService.shared.hunyuanMiniModelSizeGb
        case .quality:
            sizeGb = ConfigurationService.shared.hunyuanLargeModelSizeGb
        }
        return "~\(String(format: "%.1f", sizeGb)) GB"
    }

    var modelName: String {
        switch self {
        case .fast: return "Hunyuan3D-2 Mini"
        case .quality: return "Hunyuan3D-2.1"
        }
    }

    var description: String {
        switch self {
        case .fast: return "Smaller, faster model"
        case .quality: return "Best quality, larger model"
        }
    }

    /// Whether this choice uses the mini repo
    var usesMiniRepo: Bool {
        switch self {
        case .fast: return true
        case .quality: return false
        }
    }

    /// HuggingFace model page URL (links to specific subfolder)
    var huggingFaceURL: URL? {
        switch self {
        case .fast:
            return URL(string: "https://huggingface.co/tencent/Hunyuan3D-2mini/tree/main/hunyuan3d-dit-v2-mini")
        case .quality:
            return URL(string: "https://huggingface.co/tencent/Hunyuan3D-2.1/tree/main/hunyuan3d-dit-v2-1")
        }
    }
}
