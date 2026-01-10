import Foundation

/// Model choice for initial setup
enum SetupModelChoice: String, CaseIterable {
    case fast = "fast"           // mini (Hunyuan3D-2 Mini)
    case ultra = "ultra"         // std (Hunyuan3D-2.1 Standard)

    var displayName: String {
        switch self {
        case .fast: return "Fast"
        case .ultra: return "Ultra"
        }
    }

    var modelVariant: String {
        switch self {
        case .fast: return "mini"
        case .ultra: return "std"
        }
    }

    /// Download size string - uses config values (no external queries for display)
    var downloadSize: String {
        let sizeGb: Double
        switch self {
        case .fast:
            sizeGb = ConfigurationService.shared.hunyuanMiniModelSizeGb
        case .ultra:
            sizeGb = ConfigurationService.shared.hunyuanStdModelSizeGb
        }
        return "~\(String(format: "%.1f", sizeGb)) GB"
    }

    /// Formatted size for display (alias for downloadSize)
    var formattedSize: String {
        downloadSize
    }

    /// Size in bytes for space calculations
    var sizeBytes: Int64 {
        switch self {
        case .fast:
            return AppConstants.hunyuanMiniModelBytes
        case .ultra:
            return AppConstants.hunyuanStdModelBytes
        }
    }

    var modelName: String {
        switch self {
        case .fast: return "Hunyuan3D-2 Mini"
        case .ultra: return "Hunyuan3D-2.1 Standard"
        }
    }

    var description: String {
        switch self {
        case .fast: return "Fast, efficient 3D generation"
        case .ultra: return "Higher quality with more detail"
        }
    }

    /// Whether this choice uses the mini repo
    var usesMiniRepo: Bool {
        switch self {
        case .fast: return true
        case .ultra: return false
        }
    }

    /// HuggingFace model page URL (links to specific subfolder)
    var huggingFaceURL: URL? {
        switch self {
        case .fast:
            return URL(string: "https://huggingface.co/tencent/Hunyuan3D-2mini/tree/main/hunyuan3d-dit-v2-mini")
        case .ultra:
            return URL(string: "https://huggingface.co/tencent/Hunyuan3D-2.1/tree/main/hunyuan3d-dit-v2-1")
        }
    }
}
