import Foundation

/// Defines the deterministic stages of the setup process
enum SetupStage: String, Codable, CaseIterable {
    case preparing = "Preparing Resources"
    case syncingSAM = "Configuring Inference Environment"
    case downloadingSAM = "Downloading Vision Models"
    case syncingHunyuan = "Configuring 3D Generation Environment"
    case downloadingHunyuan = "Downloading 3D Generation Model"
    case completed = "Setup Complete"
    case failed = "Setup Failed"

    var progressWeight: Double {
        switch self {
        case .preparing: return 0.05
        case .syncingSAM: return 0.15
        case .downloadingSAM: return 0.30  // Increased: SAM + VLM downloads
        case .syncingHunyuan: return 0.15
        case .downloadingHunyuan: return 0.35  // Increased slightly
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

// MARK: - Deprecated: Progress tracking is now handled by DownloadMonitor (filesystem polling)

// MARK: - Setup Task Tracking

/// Represents a single task in the setup process
struct SetupTask: Identifiable {
    let id: String
    let name: String
    let estimatedBytes: Int64 // bytes to download for this task
    var status: TaskStatus = .pending
    var progress: Double = 0
    var startTime: Date?
    var endTime: Date?

    enum TaskStatus {
        case pending
        case running
        case completed
        case failed
    }

    var actualDuration: TimeInterval? {
        guard let start = startTime, let end = endTime else { return nil }
        return end.timeIntervalSince(start)
    }
}

/// Tracks overall setup progress across multiple tasks
/// Time estimates now come from DownloadMonitor (filesystem polling)
struct SetupTaskTracker {
    var tasks: [SetupTask]
    var currentTaskIndex: Int = 0

    init(modelChoice: String) {
        let config = ConfigurationService.shared
        let isUltra = modelChoice == "std"
        let hunyuanSizeGb = isUltra ? config.hunyuanStdModelSizeGb : config.hunyuanMiniModelSizeGb

        // Define tasks with their estimated download sizes (5 tasks matching setup stages)
        tasks = [
            SetupTask(
                id: "prepare",
                name: "Preparing environment",
                estimatedBytes: 0 // No download
            ),
            SetupTask(
                id: "runtime",
                name: "Initializing AI runtime",
                estimatedBytes: Int64(config.uvPackagesSizeGb * 0.5 * 1_000_000_000) // Inference env packages
            ),
            SetupTask(
                id: "vision",
                name: "Installing vision models",
                estimatedBytes: Int64(config.samModelSizeGb * 1_000_000_000) + Int64(config.vlmModelSizeGb * 1_000_000_000)
            ),
            SetupTask(
                id: "pipeline",
                name: "Configuring 3D pipeline",
                estimatedBytes: Int64(config.uvPackagesSizeGb * 0.5 * 1_000_000_000) // Hunyuan env packages
            ),
            SetupTask(
                id: "model",
                name: "Downloading 3D model",
                estimatedBytes: Int64(hunyuanSizeGb * 1_000_000_000)
            )
        ]
    }

    var currentTask: SetupTask? {
        guard currentTaskIndex < tasks.count else { return nil }
        return tasks[currentTaskIndex]
    }

    var totalBytes: Int64 {
        tasks.reduce(0) { $0 + $1.estimatedBytes }
    }

    var completedBytes: Int64 {
        var bytes: Int64 = 0
        for (index, task) in tasks.enumerated() {
            if index < currentTaskIndex {
                bytes += task.estimatedBytes
            } else if index == currentTaskIndex {
                bytes += Int64(Double(task.estimatedBytes) * task.progress)
            }
        }
        return bytes
    }

    var overallProgress: Double {
        guard totalBytes > 0 else { return 0 }
        return Double(completedBytes) / Double(totalBytes)
    }

    /// Time remaining comes from DownloadMonitor, not calculated here
    var formattedTimeRemaining: String {
        return ""  // Placeholder - actual value comes from DownloadMonitor
    }

    mutating func startTask(at index: Int) {
        guard index < tasks.count else { return }
        currentTaskIndex = index
        tasks[index].status = .running
        tasks[index].startTime = Date()
        tasks[index].progress = 0
    }

    mutating func updateTaskProgress(_ progress: Double) {
        guard currentTaskIndex < tasks.count else { return }
        tasks[currentTaskIndex].progress = min(1.0, max(0, progress))
    }

    mutating func completeCurrentTask() {
        guard currentTaskIndex < tasks.count else { return }
        tasks[currentTaskIndex].status = .completed
        tasks[currentTaskIndex].progress = 1.0
        tasks[currentTaskIndex].endTime = Date()
    }

    mutating func failCurrentTask() {
        guard currentTaskIndex < tasks.count else { return }
        tasks[currentTaskIndex].status = .failed
        tasks[currentTaskIndex].endTime = Date()
    }
}
