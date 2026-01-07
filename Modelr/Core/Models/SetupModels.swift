import Foundation

/// Defines the deterministic stages of the setup process
enum SetupStage: String, Codable, CaseIterable {
    case preparing = "Preparing Resources"
    case syncingSAM = "Configuring Segmentation Environment"
    case downloadingSAM = "Downloading Segmentation Model"
    case syncingTools = "Configuring Mesh Tools"
    case syncingHunyuan = "Configuring 3D Generation Environment"
    case downloadingHunyuan = "Downloading 3D Generation Model"
    case completed = "Setup Complete"
    case failed = "Setup Failed"
    
    var progressWeight: Double {
        switch self {
        case .preparing: return 0.05
        case .syncingSAM: return 0.15
        case .downloadingSAM: return 0.25
        case .syncingTools: return 0.10
        case .syncingHunyuan: return 0.15
        case .downloadingHunyuan: return 0.30
        case .completed: return 0.0
        case .failed: return 0.0
        }
    }
}

/// Structured progress update from the setup service
struct SetupProgressUpdate {
    let stage: SetupStage
    let status: String
    let logLine: String?
    let isDetailedLog: Bool
    
    init(stage: SetupStage, status: String, logLine: String? = nil, isDetailedLog: Bool = false) {
        self.stage = stage
        self.status = status
        self.logLine = logLine
        self.isDetailedLog = isDetailedLog
    }
}
