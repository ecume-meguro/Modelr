import Foundation

/// Resolves where model weights live, sandbox-first. The app's Application Support
/// directory is redirected into the sandbox container automatically, so it's the
/// only location a sandboxed build can read/write. We fall back to the developer's
/// local repo checkouts when they're present (non-sandbox dev), and a downloader
/// (ModelDownloader) populates the container layout when neither exists.
///
/// Container layout:
///   <AppSupport>/Modelr/models/shape/<model.weightsSubpath>/model.fp16.safetensors
///   <AppSupport>/Modelr/models/paint/hunyuan3d-paint-v2-0/{unet,vae}/...
///   <AppSupport>/Modelr/models/paint/realesrgan/rrdbnet_mlx.safetensors
enum ModelStore {
    /// Container-side models root (created on demand).
    static var modelsRoot: URL {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Modelr/models", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    static var shapeContainer: URL { modelsRoot.appendingPathComponent("shape", isDirectory: true) }
    static var paintContainer: URL { modelsRoot.appendingPathComponent("paint", isDirectory: true) }

    // MARK: - Shape

    /// The shape checkpoint for a model — container first, then the dev repo. nil if absent.
    static func shapeWeightsFile(for model: ModelChoice) -> URL? {
        let rel = "\(model.weightsSubpath)/model.fp16.safetensors"
        let container = shapeContainer.appendingPathComponent(rel)
        if FileManager.default.fileExists(atPath: container.path) { return container }
        let dev = PipelineConfig.repoRoot.appendingPathComponent(rel)
        if FileManager.default.fileExists(atPath: dev.path) { return dev }
        return nil
    }

    static func isShapeAvailable(_ model: ModelChoice) -> Bool {
        shapeWeightsFile(for: model) != nil
    }

    // MARK: - Paint

    private static let paintProbe = "hunyuan3d-paint-v2-0/unet/diffusion_pytorch_model.safetensors"

    /// The paint weights root (contains hunyuan3d-paint-v2-0/, realesrgan/) — container first,
    /// then the dev repo's `weights/`. nil if absent.
    static var paintWeightsRoot: URL? {
        if FileManager.default.fileExists(atPath: paintContainer.appendingPathComponent(paintProbe).path) {
            return paintContainer
        }
        let dev = PaintConfig.repoRoot.appendingPathComponent("weights")
        if FileManager.default.fileExists(atPath: dev.appendingPathComponent(paintProbe).path) { return dev }
        return nil
    }

    static var isPaintAvailable: Bool { paintWeightsRoot != nil }
}
