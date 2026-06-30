import Foundation

/// Location of the local Hunyuan3D-Paint-MLX pipeline (the texture/paint sibling of
/// the shape repo). Paint consumes a mesh + the input image and produces a textured mesh.
enum PaintConfig {
    static let repoRoot = URL(fileURLWithPath: "/Users/xzm/Projects/Hunyuan-3D-Paint-MLX")
    static var pythonExecutable: URL { repoRoot.appendingPathComponent(".venv/bin/python3.12") }

    /// Directory that contains the per-model weight subdirs (hunyuan3d-paint-v2-0,
    /// realesrgan, …); the in-process `PaintPipeline` resolves subpaths under it.
    static var weightsRoot: URL { repoRoot.appendingPathComponent("weights") }

    /// Small (2.0) RGB texture model.
    static var weightsDir: URL { weightsRoot.appendingPathComponent("hunyuan3d-paint-v2-0") }

    /// Paint now runs in-process (vendored HunyuanPaintMLX); only the weights need to exist.
    static var isAvailable: Bool {
        FileManager.default.fileExists(
            atPath: weightsDir.appendingPathComponent("unet/diffusion_pytorch_model.safetensors").path)
    }
}
