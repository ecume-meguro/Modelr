import Foundation

/// Model choice for initial setup
enum SetupModelChoice: String, CaseIterable {
    case fast = "fast"
    case quality = "quality"

    var displayName: String {
        switch self {
        case .fast: return "Small, Fast"
        case .quality: return "Large, Higher Quality"
        }
    }

    var modelVariant: String {
        switch self {
        case .fast: return "mini"
        case .quality: return "std"
        }
    }

    var downloadSize: String {
        switch self {
        case .fast: return "~7.2 GB"
        case .quality: return "~7.4 GB"
        }
    }

    var modelName: String {
        switch self {
        case .fast: return "Hunyuan3D-2 Mini"
        case .quality: return "Hunyuan3D-2.1"
        }
    }
}
