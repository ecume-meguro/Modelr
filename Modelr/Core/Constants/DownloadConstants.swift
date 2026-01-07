// MARK: - Download Constants
// Default fallback values from config. Actual download progress uses
// HuggingFace-reported sizes when available during the download itself.

struct DownloadConstants {
    static var samModelBytes: Int64 {
        Int64(ConfigurationService.shared.samModelSizeGb * 1_000_000_000)
    }

    static var hunyuanMiniModelBytes: Int64 {
        Int64(ConfigurationService.shared.hunyuanMiniModelSizeGb * 1_000_000_000)
    }

    static var hunyuanStandardModelBytes: Int64 {
        Int64(ConfigurationService.shared.hunyuanLargeModelSizeGb * 1_000_000_000)
    }
}
