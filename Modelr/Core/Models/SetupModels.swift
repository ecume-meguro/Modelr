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

// MARK: - Model Download Progress

/// Progress information for model downloads
struct ModelDownloadProgress {
    let downloadedBytes: Int64
    let totalBytes: Int64
    let bytesPerSecond: Double
    let estimatedTimeRemaining: TimeInterval?

    var progress: Double {
        guard totalBytes > 0 else { return 0 }
        return Double(downloadedBytes) / Double(totalBytes)
    }

    var formattedProgress: String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        let downloaded = formatter.string(fromByteCount: downloadedBytes)
        let total = formatter.string(fromByteCount: totalBytes)
        return "\(downloaded) / \(total)"
    }

    var formattedSpeed: String {
        guard bytesPerSecond > 0 else { return "—" }
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return "\(formatter.string(fromByteCount: Int64(bytesPerSecond)))/s"
    }

    var formattedETA: String {
        guard let eta = estimatedTimeRemaining, eta > 0 && eta.isFinite else { return "" }
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.hour, .minute, .second]
        formatter.unitsStyle = .abbreviated
        formatter.maximumUnitCount = 2
        return formatter.string(from: eta) ?? ""
    }
}
