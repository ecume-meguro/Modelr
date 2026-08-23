import Foundation

/// The four installable models (DESIGN.md §2).
enum ModelID: String, CaseIterable, Codable, Hashable, Identifiable, Sendable {
    case shapeSmall = "shape-small"
    case shapeLarge = "shape-large"
    case shapeMultiview = "shape-multiview"
    case paintSmall = "paint-small"
    case paintLarge = "paint-large"

    var id: String { rawValue }

    /// Directory name under `Application Support/Modelr/models/` (§2.3).
    var slug: String { rawValue }

    var kind: EngineKind {
        switch self {
        case .shapeSmall, .shapeLarge, .shapeMultiview: return .shape
        case .paintSmall, .paintLarge: return .paint
        }
    }
}

/// One file in a model's weight bundle. Download correctness = size + sha256 match.
struct CatalogFile: Hashable, Sendable {
    /// Path relative to the HF repo root.
    let path: String
    let bytes: Int64
    let sha256: String
    /// Where the file lands locally, when that differs from its path in the repo. Tencent's
    /// checkpoints sit in a versioned subfolder; the engine expects the checkpoint and its
    /// config.yaml side by side at the install root.
    var localPath: String? = nil

    var installName: String { localPath ?? path }
}

struct CatalogModel: Sendable {
    let id: ModelID
    let displayName: String
    let detail: String
    /// HuggingFace repo id (owned/curated — byte layout is a contract we control).
    let repo: String
    /// Pinned revision; nil resolves to `main` until the upload pins a commit.
    let revision: String?
    let files: [CatalogFile]

    var totalBytes: Int64 { files.reduce(0) { $0 + $1.bytes } }

    /// Resolve the download URL for one file.
    func remoteURL(for file: CatalogFile) -> URL {
        let rev = revision ?? "main"
        return URL(string: "https://huggingface.co/\(repo)/resolve/\(rev)/\(file.path)?download=true")!
    }
}

/// Static, baked manifest (DESIGN.md §2.2): repo ids and file-level byte sizes +
/// sha256 digests for every model. No runtime manifest fetch.
///
/// REGENERATION: the constants below are generated from `model_manifest.json`
/// at the repo root (produced at HF upload time from the staged bundles).
/// To regenerate after re-uploading weights, run:
///
///     swift scripts/gen_catalog.swift model_manifest.json
///
/// and replace the `all` array below with its output.
enum ModelCatalog {
    static let all: [CatalogModel] = [
        CatalogModel(
            id: .shapeSmall,
            displayName: "Shape · Small",
            detail: "Hunyuan3D 2mini · 0.6B · ~5 s per shape",
            repo: "zimengxiong/hunyuan3d-mlx-shape-small",
            revision: "b7536809d38ad13fe6a9b7769a41fd5d42e520df",
            files: [
                CatalogFile(path: "config.yaml", bytes: 1_628,
                            sha256: "cabcba7f6115752c8fe5b370e12bf714936f70377a8a80f151872f76c2d64609"),
                CatalogFile(path: "model.fp16.safetensors", bytes: 3_819_958_234,
                            sha256: "3cc66f3bea33e4062b7dbc875ffe1d70c4888914aec3e91b60f94e9bd01b522b"),
            ]),
        CatalogModel(
            id: .shapeLarge,
            displayName: "Shape · Large",
            detail: "Hunyuan3D 2.0 turbo · 1.1B distilled · ~17 s per shape",
            repo: "zimengxiong/hunyuan3d-mlx-shape-large",
            revision: "5ad04593521ff80875ac007ef8185209368f18bc",
            files: [
                CatalogFile(path: "config.yaml", bytes: 1_663,
                            sha256: "4712421fe32d57c678be3be2b608acdb8871985f0b81646a883d136abc63feb7"),
                CatalogFile(path: "model.fp16.safetensors", bytes: 4_930_777_530,
                            sha256: "5ee5a81e4df08a1c65b79910bf5b145a90376e526794f4607a4d5d068d62f269"),
            ]),
        CatalogModel(
            id: .shapeMultiview,
            displayName: "Shape · Multiview",
            detail: "Hunyuan3D 2mv · 1.1B · up to 4 views · best geometry",
            // Tencent's own weights, not a re-upload: the checkpoint layout this engine expects
            // (model. / vae. / conditioner.main_image_encoder.model.) is what they already ship,
            // and the DiT dimensions match the single-image model exactly. Only the conditioning
            // differs. Digests are the repo's LFS oids.
            repo: "tencent/Hunyuan3D-2mv",
            revision: nil,
            files: [
                CatalogFile(path: "hunyuan3d-dit-v2-mv/config.yaml", bytes: 1_608,
                            sha256: "315fd5bf601d1d103130b9fda202f1bd28eda495e68ed1621bc823d5519c5e5b",
                            localPath: "config.yaml"),
                CatalogFile(path: "hunyuan3d-dit-v2-mv/model.fp16.safetensors", bytes: 4_928_151_562,
                            sha256: "d36f5881bcdc56726b73e517cd444c13c60732431622da7268145355c8d38e9c",
                            localPath: "model.fp16.safetensors"),
            ]),
        CatalogModel(
            id: .paintSmall,
            displayName: "Paint · Small",
            detail: "Color texture (SD2.1) · 2048 atlas",
            repo: "zimengxiong/hunyuan3d-mlx-paint-small",
            revision: "29bab9dbf2a4a4f9c6988a41b0e891156a517a23",
            files: [
                CatalogFile(path: "realesrgan/rrdbnet_mlx.safetensors", bytes: 66_857_885,
                            sha256: "67fbfb07607e3457154dddf9d29dfa6c65f393c2c531af700ae4370499c978ff"),
                CatalogFile(path: "unet/config.json", bytes: 911,
                            sha256: "ce0c6d379e3b1d3e1f79338de70c80a1e36f17a6372439a8249b6fb0dfa1b608"),
                CatalogFile(path: "unet/diffusion_pytorch_model.safetensors", bytes: 3_662_636_472,
                            sha256: "1c5ce434ba976b30bbb51a080917ecd39f8d8761691887b5df3be765ef4bd9e9"),
                CatalogFile(path: "vae/config.json", bytes: 553,
                            sha256: "424117cb534ce03497c41305ed868980123917b2b6abba4bbaa615e968772903"),
                CatalogFile(path: "vae/diffusion_pytorch_model.safetensors", bytes: 167_335_310,
                            sha256: "abcec86e499e1ce9f05d1630725d386dc533b61fe0947ab034f07f89042e7a61"),
            ]),
        CatalogModel(
            id: .paintLarge,
            displayName: "Paint · Large",
            detail: "PBR texture (albedo + metallic-roughness) · 4096 atlas",
            repo: "zimengxiong/hunyuan3d-mlx-paint-large",
            revision: "b56e8b86b4d1e62b0bb3bbef7e2070d6ec22620e",
            files: [
                CatalogFile(path: "dinov2/config.json", bytes: 548,
                            sha256: "15d2e68b709674c0eb9bb5cc8b73e57ebe9a169a425bef224f46ae10053806a2"),
                CatalogFile(path: "dinov2/model.safetensors", bytes: 4_546_005_432,
                            sha256: "917d3c470db999d32a312f8542149be91c7cbac61ee8fb4b67ae3d82b79ce21f"),
                CatalogFile(path: "dinov2/preprocessor_config.json", bytes: 436,
                            sha256: "14e780d86fa1861f8751f868d7f45425b5feb55c38ca26f152ca5097ab30f828"),
                CatalogFile(path: "realesrgan/rrdbnet_mlx.safetensors", bytes: 66_857_885,
                            sha256: "67fbfb07607e3457154dddf9d29dfa6c65f393c2c531af700ae4370499c978ff"),
                CatalogFile(path: "scheduler/scheduler_config.json", bytes: 387,
                            sha256: "9a6a7268e4d7c1bc5000450927070e338dc57a51f4530078627c88f5828e792d"),
                CatalogFile(path: "unet/config.json", bytes: 911,
                            sha256: "ce0c6d379e3b1d3e1f79338de70c80a1e36f17a6372439a8249b6fb0dfa1b608"),
                CatalogFile(path: "unet/diffusion_pytorch_model.safetensors", bytes: 3_924_737_160,
                            sha256: "7b5bbe5ce5e40b816e55e0d0e3b8236759bdbd8b4cbaa90d497b3278fa68f10c"),
                CatalogFile(path: "vae/config.json", bytes: 553,
                            sha256: "424117cb534ce03497c41305ed868980123917b2b6abba4bbaa615e968772903"),
                CatalogFile(path: "vae/diffusion_pytorch_model.safetensors", bytes: 167_335_310,
                            sha256: "abcec86e499e1ce9f05d1630725d386dc533b61fe0947ab034f07f89042e7a61"),
            ]),
    ]

    static func model(_ id: ModelID) -> CatalogModel {
        all.first { $0.id == id }!
    }

    // MARK: onboarding bundles (§4.2)

    /// Fast start: small pair (~7.7 GB).
    static let fastStart: Set<ModelID> = [.shapeSmall, .paintSmall]
    /// Best quality: large pair (~13.6 GB).
    static let bestQuality: Set<ModelID> = [.shapeLarge, .paintLarge]
    /// Everything (~21.3 GB).
    static let everything: Set<ModelID> = Set(ModelID.allCases)

    static func totalBytes(of models: Set<ModelID>) -> Int64 {
        models.reduce(0) { $0 + model($1).totalBytes }
    }
}
