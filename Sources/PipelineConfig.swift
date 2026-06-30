import Foundation

/// The single place that knows where the local Hunyuan3D-Shape-MLX model lives
/// and the fixed generation parameters. Model + quantization are chosen per project.
enum PipelineConfig {
    /// Local checkout of the MLX shape pipeline.
    static let repoRoot = URL(fileURLWithPath: "/Users/xzm/Projects/Hunyuan3D-Shape-MLX")

    /// The repo's uv-managed virtualenv interpreter (pure-MLX, no PyTorch).
    static var pythonExecutable: URL { repoRoot.appendingPathComponent(".venv/bin/python3.12") }

    /// Weights directory for a given model.
    static func weightsDir(for model: ModelChoice) -> URL {
        repoRoot.appendingPathComponent(model.weightsSubpath)
    }

    // Fixed generation parameters (steps are per-model — see ModelChoice.steps).
    static let guidance = 5.0
    static let octree = 256
    static let dtype = "float16"

    static var pythonReady: Bool {
        FileManager.default.isExecutableFile(atPath: pythonExecutable.path)
    }

    /// True when the model's weights are actually present on disk.
    static func isAvailable(_ model: ModelChoice) -> Bool {
        let weights = weightsDir(for: model).appendingPathComponent("model.fp16.safetensors")
        return pythonReady && FileManager.default.fileExists(atPath: weights.path)
    }
}
