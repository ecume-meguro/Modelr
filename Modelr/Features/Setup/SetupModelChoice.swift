import Foundation

/// Model choice for initial setup
enum SetupModelChoice: String, CaseIterable {
    case fast = "fast"           // mini (Hunyuan3D-2 Mini)

    var displayName: String {
        switch self {
        case .fast: return "Fast"
        }
    }

    var modelVariant: String {
        switch self {
        case .fast: return "mini"
        }
    }

    /// Download size string - uses config values (no external queries for display)
    var downloadSize: String {
        let sizeGb: Double
        switch self {
        case .fast:
            sizeGb = ConfigurationService.shared.hunyuanMiniModelSizeGb
        }
        return "~\(String(format: "%.1f", sizeGb)) GB"
    }

    var modelName: String {
        switch self {
        case .fast: return "Hunyuan3D-2 Mini"
        }
    }

    var description: String {
        switch self {
        case .fast: return "Fast, efficient 3D generation"
        }
    }

    /// Whether this choice uses the mini repo
    var usesMiniRepo: Bool {
        switch self {
        case .fast: return true
        }
    }

    /// HuggingFace model page URL (links to specific subfolder)
    var huggingFaceURL: URL? {
        switch self {
        case .fast:
            return URL(string: "https://huggingface.co/tencent/Hunyuan3D-2mini/tree/main/hunyuan3d-dit-v2-mini")
        }
    }
}
