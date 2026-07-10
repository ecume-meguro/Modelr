import Foundation

/// Pure planner for the §2.3 boot migration: files under the legacy
/// `models/shape/weights/**` and `models/paint/**` trees are MOVED into the new
/// per-model slots when both their legacy location maps to a known slot file and
/// their byte size matches the catalog; everything else is deleted.
///
/// Path mapping (not size alone) guards against distinct checkpoints that happen
/// to share a byte count — e.g. a legacy `2mini-turbo` download must never land
/// in the shape-small slot.
enum LegacyMigration {

    struct Move: Equatable {
        /// Path relative to the models root (e.g. `shape/weights/…/model.fp16.safetensors`).
        let from: String
        let model: ModelID
        /// Catalog-relative destination inside the model's install dir.
        let to: String
    }

    struct Plan: Equatable {
        var moves: [Move] = []
        /// Legacy-relative paths to delete (non-matching or unmapped files).
        var deletions: [String] = []
    }

    /// Where a legacy relative path belongs in the new layout, if anywhere.
    static func destination(for legacyPath: String) -> (model: ModelID, to: String)? {
        // Shape checkpoints: models/shape/weights/<RepoDir>/<ModelDir>/model.fp16.safetensors
        let shapeMap: [String: ModelID] = [
            "shape/weights/Hunyuan3D-2mini/hunyuan3d-dit-v2-mini/model.fp16.safetensors": .shapeSmall,
            "shape/weights/Hunyuan3D-2/hunyuan3d-dit-v2-0-turbo/model.fp16.safetensors": .shapeLarge,
        ]
        if let model = shapeMap[legacyPath] {
            return (model, "model.fp16.safetensors")
        }
        // Paint v2-0 (small): models/paint/hunyuan3d-paint-v2-0/{unet,vae}/…
        let paintPrefix = "paint/hunyuan3d-paint-v2-0/"
        if legacyPath.hasPrefix(paintPrefix) {
            let rel = String(legacyPath.dropFirst(paintPrefix.count))   // unet/…, vae/…
            if ModelCatalog.model(.paintSmall).files.contains(where: { $0.path == rel }) {
                return (.paintSmall, rel)
            }
            return nil
        }
        // Paint RealESRGAN: models/paint/realesrgan/rrdbnet_mlx.safetensors
        if legacyPath == "paint/realesrgan/rrdbnet_mlx.safetensors" {
            return (.paintSmall, "realesrgan/rrdbnet_mlx.safetensors")
        }
        return nil
    }

    /// Compute the migration for a set of legacy files (paths relative to the
    /// models root, with on-disk sizes). Pure — the runtime applies it.
    static func plan(files: [(path: String, bytes: Int64)]) -> Plan {
        var plan = Plan()
        for (path, bytes) in files {
            guard let (model, to) = destination(for: path),
                  let catalogFile = ModelCatalog.model(model).files.first(where: { $0.path == to }),
                  catalogFile.bytes == bytes
            else {
                plan.deletions.append(path)               // unmapped or size mismatch
                continue
            }
            plan.moves.append(Move(from: path, model: model, to: to))
        }
        return plan
    }
}
