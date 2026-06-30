import Foundation

/// Location of the local Hunyuan3D-Paint-MLX pipeline (the texture/paint sibling of
/// the shape repo). Paint consumes a mesh + the input image and produces a textured mesh.
enum PaintConfig {
    static let repoRoot = URL(fileURLWithPath: "/Users/xzm/Projects/Hunyuan-3D-Paint-MLX")
    static var pythonExecutable: URL { repoRoot.appendingPathComponent(".venv/bin/python3.12") }

    /// Small (2.0) RGB texture model.
    static var weightsDir: URL { repoRoot.appendingPathComponent("weights/hunyuan3d-paint-v2-0") }

    static var isAvailable: Bool {
        FileManager.default.isExecutableFile(atPath: pythonExecutable.path)
            && FileManager.default.fileExists(atPath: weightsDir.appendingPathComponent("unet/config.json").path)
    }
}
