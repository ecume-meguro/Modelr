import Foundation

/// Lightweight Hugging Face size queries (no SDK required).
///
/// We use `HEAD` requests against the exact files we intend to download.
/// This avoids brittle parsing of tqdm output and prevents stale hard-coded totals.
@MainActor
class HuggingFaceModelSizeService: ObservableObject {
    static let shared = HuggingFaceModelSizeService()

    struct FileSpec: Sendable {
        let repoId: String
        let path: String
    }

    // MARK: - Model File Specifications
    // Note: These are the main weight files used to estimate download size

    static let hunyuanMiniFiles: [FileSpec] = [
        FileSpec(repoId: "tencent/Hunyuan3D-2mini", path: "hunyuan3d-dit-v2-mini/model.fp16.safetensors")
    ]

    static let sam3Files: [FileSpec] = [
        FileSpec(repoId: "mlx-community/sam3-image", path: "model.safetensors")
    ]

    // MARK: - Fallback sizes (used when HF query fails)
    private static let miniFallbackGb: Double = 3.84
    private static let samFallbackGb: Double = 3.4

    // MARK: - Cached Sizes

    @Published var hunyuanMiniBytes: Int64?
    @Published var sam3Bytes: Int64?
    @Published var isQuerying = false

    private var hasQueried = false

    private init() {}

    // MARK: - Computed Display Strings

    /// Returns true if bytes is valid (> 100MB, to filter out failed queries)
    private func isValidSize(_ bytes: Int64?) -> Bool {
        guard let b = bytes else { return false }
        return b > 100_000_000  // Must be > 100MB to be valid
    }

    var hunyuanMiniDisplaySize: String {
        if isValidSize(hunyuanMiniBytes) {
            return formatBytes(hunyuanMiniBytes!)
        }
        return "~\(String(format: "%.1f", Self.miniFallbackGb)) GB"
    }

    var sam3DisplaySize: String {
        if isValidSize(sam3Bytes) {
            return formatBytes(sam3Bytes!)
        }
        return "~\(String(format: "%.1f", Self.samFallbackGb)) GB"
    }

    /// Get display size for a specific model choice (uses live data if available)
    func displaySize(for choice: SetupModelChoice) -> String {
        switch choice {
        case .fast:
            return hunyuanMiniDisplaySize
        }
    }

    /// Get raw bytes for a specific model choice (uses live data if available, else fallback)
    func bytes(for choice: SetupModelChoice) -> Int64 {
        switch choice {
        case .fast:
            if isValidSize(hunyuanMiniBytes) {
                return hunyuanMiniBytes!
            }
            return Int64(Self.miniFallbackGb * 1_000_000_000)
        }
    }

    /// Get SAM model bytes (uses live data if available, else fallback)
    var samBytes: Int64 {
        if isValidSize(sam3Bytes) {
            return sam3Bytes!
        }
        return Int64(Self.samFallbackGb * 1_000_000_000)
    }

    /// Get total download size for initial setup (selected model + SAM)
    func totalSetupSize(for choice: SetupModelChoice) -> String {
        let modelBytes = bytes(for: choice)
        let sam = samBytes
        let totalBytes = modelBytes + sam
        return formatBytes(totalBytes)
    }

    private func formatBytes(_ bytes: Int64) -> String {
        let gb = Double(bytes) / 1_000_000_000.0
        return "~\(String(format: "%.1f", gb)) GB"
    }

    // MARK: - Query Methods

    /// Query all model sizes from HuggingFace (runs once, caches results)
    func queryAllSizes() async {
        guard !isQuerying && !hasQueried else {
            print("[HFSizeService] Skipping query (isQuerying=\(isQuerying), hasQueried=\(hasQueried))")
            return
        }

        print("[HFSizeService] Starting HuggingFace size queries...")
        isQuerying = true
        defer {
            isQuerying = false
            hasQueried = true
        }

        // Query in parallel
        async let miniTask = Self.totalBytes(for: Self.hunyuanMiniFiles)
        async let samTask = Self.totalBytes(for: Self.sam3Files)

        let (mini, sam) = await (miniTask, samTask)

        hunyuanMiniBytes = mini
        sam3Bytes = sam

        print("[HFSizeService] Query complete - mini: \(mini.map { "\($0)" } ?? "nil"), sam: \(sam.map { "\($0)" } ?? "nil")")
    }

    /// Force refresh sizes (clears cache)
    func refreshSizes() async {
        hasQueried = false
        hunyuanMiniBytes = nil
        sam3Bytes = nil
        await queryAllSizes()
    }

    // MARK: - Static API

    /// Returns `Content-Length` for a given HF file (bytes).
    /// Follows redirects (HF often redirects to a CDN/LFS backend).
    static func fetchContentLengthBytes(for file: FileSpec) async throws -> Int64 {
        let escapedRepoId = file.repoId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? file.repoId
        let escapedPath = file.path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? file.path

        guard let url = URL(string: "https://huggingface.co/\(escapedRepoId)/resolve/main/\(escapedPath)") else {
            throw URLError(.badURL)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        request.setValue("Modelr", forHTTPHeaderField: "User-Agent")

        // URLSession will follow redirects; we only care about the final Content-Length.
        let (_, response) = try await URLSession.shared.data(for: request)

        if let http = response as? HTTPURLResponse,
           let lengthString = http.value(forHTTPHeaderField: "Content-Length"),
           let length = Int64(lengthString)
        {
            return length
        }

        let length = response.expectedContentLength
        if length >= 0 {
            return length
        }

        throw URLError(.cannotParseResponse)
    }

    static func totalBytes(for files: [FileSpec]) async -> Int64? {
        var total: Int64 = 0
        do {
            for file in files {
                let bytes = try await fetchContentLengthBytes(for: file)
                print("[HFSizeService] \(file.repoId)/\(file.path): \(bytes) bytes")
                total += bytes
            }
            print("[HFSizeService] Total for \(files.first?.repoId ?? "unknown"): \(total) bytes (\(String(format: "%.2f", Double(total) / 1_000_000_000)) GB)")
            return total
        } catch {
            print("[HFSizeService] Failed to fetch size for \(files.first?.repoId ?? "unknown"): \(error)")
            return nil
        }
    }
}
