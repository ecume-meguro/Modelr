// MARK: - Download Monitor

import Foundation

@MainActor
final class DownloadMonitor {

    private var monitorTask: Task<Void, Never>?
    private static var lastMonitoredPath: String?

    private(set) var downloadedBytes: Int64 = 0
    private(set) var downloadTotalBytes: Int64 = 0
    private(set) var downloadSpeed: Double = 0
    private(set) var downloadTimeRemaining: Double = 0
    private var speedHistory: [Double] = []
    private var lastDownloadBytes: Int64 = 0
    private var lastSpeedUpdateTime: Date? = nil

    var progress: Double {
        guard downloadTotalBytes > 0 else { return 0 }
        return Double(downloadedBytes) / Double(downloadTotalBytes)
    }

    var formattedProgress: String {
        let downloaded = ByteCountFormatter.string(fromByteCount: downloadedBytes, countStyle: .file)
        let total = ByteCountFormatter.string(fromByteCount: downloadTotalBytes, countStyle: .file)

        let speedStr: String
        if downloadSpeed > 1024 {
            speedStr = " • " + ByteCountFormatter.string(fromByteCount: Int64(downloadSpeed), countStyle: .file) + "/s"
        } else {
            speedStr = ""
        }

        return "\(downloaded) / \(total)\(speedStr)"
    }

    var formattedSpeed: String {
        if downloadSpeed > 1024 {
            return ByteCountFormatter.string(fromByteCount: Int64(downloadSpeed), countStyle: .file) + "/s"
        }
        return "—"
    }

    var formattedTimeRemaining: String {
        guard downloadTimeRemaining > 0 && downloadTimeRemaining < 86400 else { return "" }
        let minutes = Int(downloadTimeRemaining) / 60
        let seconds = Int(downloadTimeRemaining) % 60
        let timeStr = minutes > 0 ? "\(minutes)m \(seconds)s" : "\(seconds)s"
        return "\(timeStr) remaining"
    }

    func startMonitoring(directory: URL, totalBytes: Int64, progressCallback: @escaping (DownloadMonitor) -> Void) {
        // Update total bytes even if we don't restart the task
        downloadTotalBytes = totalBytes

        // Only restart if it's a new path or task is nil
        let path = directory.path
        if Self.lastMonitoredPath == path && monitorTask != nil {
            return
        }

        Self.lastMonitoredPath = path

        if monitorTask != nil {
            monitorTask?.cancel()
            monitorTask = nil
        }

        monitorTask = Task { [weak self] in
            while !Task.isCancelled {
                let size = await PathManager.getDirectorySize(directory)
                await MainActor.run {
                    guard let self else { return }
                    self.updateProgress(downloaded: size, total: totalBytes)
                    progressCallback(self)
                }

                if size >= totalBytes {
                    break
                }

                try? await Task.sleep(nanoseconds: 500_000_000) // 0.5 seconds
            }
        }
    }

    private func updateProgress(downloaded: Int64, total: Int64) {
        downloadedBytes = downloaded
        downloadTotalBytes = total

        let now = Date()
        if let lastTime = lastSpeedUpdateTime {
            let elapsed = now.timeIntervalSince(lastTime)
            if elapsed >= 0.5 {
                let bytesDownloaded = downloaded - lastDownloadBytes
                if bytesDownloaded > 0 {
                    let instantSpeed = Double(bytesDownloaded) / elapsed
                    speedHistory.append(instantSpeed)
                    if speedHistory.count > 5 { speedHistory.removeFirst() }
                    let avgSpeed = speedHistory.reduce(0, +) / Double(speedHistory.count)
                    downloadSpeed = avgSpeed
                }
                lastDownloadBytes = downloaded
                lastSpeedUpdateTime = now
                if downloadSpeed > 0 {
                    downloadTimeRemaining = Double(total - downloaded) / downloadSpeed
                }
            }
        } else {
            lastSpeedUpdateTime = now
            lastDownloadBytes = downloaded
        }
    }

    func resetProgress() {
        downloadedBytes = 0
        downloadTotalBytes = 0
        downloadSpeed = 0
        downloadTimeRemaining = 0
        speedHistory.removeAll()
        lastDownloadBytes = 0
        lastSpeedUpdateTime = nil
        stopMonitoring()
    }

    func stopMonitoring() {
        monitorTask?.cancel()
        monitorTask = nil
        Self.lastMonitoredPath = nil
    }
}
