import Foundation

/// One remote weight file → its destination in the ModelStore container.
struct ModelFile: Sendable {
    let remote: URL
    let dest: URL
}

/// Downloads model weights from HuggingFace into the ModelStore container so a
/// sandboxed / freshly-installed app can fetch what it needs at runtime (no Python,
/// no conversion — `ShapeGenerator`/`PaintPipeline` load the original HF safetensors).
///
/// RealESRGAN is a converted (non-HF) file; set `realesrganURL` to a host you control
/// to include it, otherwise paint runs without the x4 upscale.
final class ModelDownloader: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let hfBase = "https://huggingface.co"
    var realesrganURL: URL?

    // MARK: - File maps

    private func hfURL(repo: String, file: String) -> URL {
        URL(string: "\(hfBase)/\(repo)/resolve/main/\(file)?download=true")!
    }

    /// HF source + container dest for a shape checkpoint.
    /// `weightsSubpath` is `weights/<RepoDir>/<ModelDir>` → repo `tencent/<RepoDir>`,
    /// file `<ModelDir>/model.fp16.safetensors`.
    func shapeFiles(for model: ModelChoice) -> [ModelFile] {
        let parts = model.weightsSubpath.split(separator: "/").map(String.init)
        guard parts.count == 3 else { return [] }
        let repoDir = parts[1], modelDir = parts[2]
        let dest = ModelStore.shapeContainer
            .appendingPathComponent(model.weightsSubpath)
            .appendingPathComponent("model.fp16.safetensors")
        return [ModelFile(remote: hfURL(repo: "tencent/\(repoDir)", file: "\(modelDir)/model.fp16.safetensors"),
                          dest: dest)]
    }

    /// Paint base weights (vae + unet) from HF, plus RealESRGAN if `realesrganURL` is set.
    func paintFiles() -> [ModelFile] {
        let repo = "tencent/Hunyuan3D-2"
        func paintDest(_ rel: String) -> URL { ModelStore.paintContainer.appendingPathComponent(rel) }
        var files = [
            ModelFile(remote: hfURL(repo: repo, file: "hunyuan3d-paint-v2-0/vae/diffusion_pytorch_model.safetensors"),
                      dest: paintDest("hunyuan3d-paint-v2-0/vae/diffusion_pytorch_model.safetensors")),
            ModelFile(remote: hfURL(repo: repo, file: "hunyuan3d-paint-v2-0/unet/diffusion_pytorch_model.safetensors"),
                      dest: paintDest("hunyuan3d-paint-v2-0/unet/diffusion_pytorch_model.safetensors")),
        ]
        if let r = realesrganURL {
            files.append(ModelFile(remote: r, dest: paintDest("realesrgan/rrdbnet_mlx.safetensors")))
        }
        return files
    }

    // MARK: - Download

    enum DownloadError: Error, LocalizedError {
        case http(Int, String)
        var errorDescription: String? {
            switch self { case .http(let c, let f): return "Download failed (HTTP \(c)) for \(f)" }
        }
    }

    /// Download `files` sequentially into their dests, skipping ones already present.
    /// `onProgress` reports overall fraction in [0,1] and the current file's name.
    func download(_ files: [ModelFile], onProgress: @escaping @Sendable (Double, String) -> Void) async throws {
        let pending = files.filter { !FileManager.default.fileExists(atPath: $0.dest.path) }
        guard !pending.isEmpty else { onProgress(1, "Up to date"); return }
        for (i, f) in pending.enumerated() {
            try FileManager.default.createDirectory(at: f.dest.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try await downloadOne(f) { frac in
                onProgress((Double(i) + frac) / Double(pending.count), f.dest.lastPathComponent)
            }
        }
        onProgress(1, "Done")
    }

    // One download at a time → storing the continuation/callback on the instance is safe.
    private var continuation: CheckedContinuation<Void, Error>?
    private var fileProgress: (@Sendable (Double) -> Void)?
    private var currentDest: URL?

    private func downloadOne(_ f: ModelFile, onFileProgress: @escaping @Sendable (Double) -> Void) async throws {
        let session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
        self.fileProgress = onFileProgress
        self.currentDest = f.dest
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            self.continuation = c
            session.downloadTask(with: f.remote).resume()
        }
        session.finishTasksAndInvalidate()
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        fileProgress?(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        guard let dest = currentDest else { return }
        if let http = downloadTask.response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            continuation?.resume(throwing: DownloadError.http(http.statusCode, dest.lastPathComponent))
            continuation = nil
            return
        }
        do {
            try? FileManager.default.removeItem(at: dest)
            try FileManager.default.moveItem(at: location, to: dest)   // must move before this returns
            continuation?.resume()
        } catch {
            continuation?.resume(throwing: error)
        }
        continuation = nil
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            continuation?.resume(throwing: error)
            continuation = nil
        }
    }
}
