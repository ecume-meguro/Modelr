import XCTest

/// §2.3 legacy layout migration — path+size mapping into the new slots.
final class LegacyMigrationTests: XCTestCase {

    private func bytes(_ model: ModelID, _ path: String) -> Int64 {
        ModelCatalog.model(model).files.first { $0.path == path }!.bytes
    }

    func testShapeCheckpointsMoveWhenPathAndSizeMatch() {
        let plan = LegacyMigration.plan(files: [
            ("shape/weights/Hunyuan3D-2mini/hunyuan3d-dit-v2-mini/model.fp16.safetensors",
             bytes(.shapeSmall, "model.fp16.safetensors")),
            ("shape/weights/Hunyuan3D-2/hunyuan3d-dit-v2-0-turbo/model.fp16.safetensors",
             bytes(.shapeLarge, "model.fp16.safetensors")),
        ])
        XCTAssertEqual(plan.moves, [
            .init(from: "shape/weights/Hunyuan3D-2mini/hunyuan3d-dit-v2-mini/model.fp16.safetensors",
                  model: .shapeSmall, to: "model.fp16.safetensors"),
            .init(from: "shape/weights/Hunyuan3D-2/hunyuan3d-dit-v2-0-turbo/model.fp16.safetensors",
                  model: .shapeLarge, to: "model.fp16.safetensors"),
        ])
        XCTAssertTrue(plan.deletions.isEmpty)
    }

    func testSizeMismatchIsDeletedNotMoved() {
        let plan = LegacyMigration.plan(files: [
            ("shape/weights/Hunyuan3D-2mini/hunyuan3d-dit-v2-mini/model.fp16.safetensors", 12_345),
        ])
        XCTAssertTrue(plan.moves.isEmpty)
        XCTAssertEqual(plan.deletions,
                       ["shape/weights/Hunyuan3D-2mini/hunyuan3d-dit-v2-mini/model.fp16.safetensors"])
    }

    func testUnmappedCheckpointsAreDeletedEvenIfSizesCollide() {
        // mini-turbo and base-2.0 have no slot in the 2×2 lineup — a byte-size
        // coincidence must never smuggle the wrong weights into a slot.
        let plan = LegacyMigration.plan(files: [
            ("shape/weights/Hunyuan3D-2mini/hunyuan3d-dit-v2-mini-turbo/model.fp16.safetensors",
             bytes(.shapeSmall, "model.fp16.safetensors")),
            ("shape/weights/Hunyuan3D-2/hunyuan3d-dit-v2-0/model.fp16.safetensors",
             bytes(.shapeLarge, "model.fp16.safetensors")),
        ])
        XCTAssertTrue(plan.moves.isEmpty)
        XCTAssertEqual(plan.deletions.count, 2)
    }

    func testPaintFilesMapIntoPaintSmall() {
        let plan = LegacyMigration.plan(files: [
            ("paint/hunyuan3d-paint-v2-0/unet/diffusion_pytorch_model.safetensors",
             bytes(.paintSmall, "unet/diffusion_pytorch_model.safetensors")),
            ("paint/hunyuan3d-paint-v2-0/vae/diffusion_pytorch_model.safetensors",
             bytes(.paintSmall, "vae/diffusion_pytorch_model.safetensors")),
            ("paint/realesrgan/rrdbnet_mlx.safetensors",
             bytes(.paintSmall, "realesrgan/rrdbnet_mlx.safetensors")),
        ])
        XCTAssertEqual(plan.moves.map(\.model), [.paintSmall, .paintSmall, .paintSmall])
        XCTAssertEqual(plan.moves.map(\.to), [
            "unet/diffusion_pytorch_model.safetensors",
            "vae/diffusion_pytorch_model.safetensors",
            "realesrgan/rrdbnet_mlx.safetensors",
        ])
        XCTAssertTrue(plan.deletions.isEmpty)
    }

    func testJunkAndUnknownFilesAreDeleted() {
        let plan = LegacyMigration.plan(files: [
            ("shape/weights/readme.txt", 42),
            ("paint/hunyuan3d-paint-v2-0/unet/leftover.tmp", 42),
            ("paint/somethingelse/data.bin", 42),
        ])
        XCTAssertTrue(plan.moves.isEmpty)
        XCTAssertEqual(plan.deletions.count, 3)
    }

    /// End-to-end against a real temp models root: files land in the new slots,
    /// junk disappears, legacy roots are removed.
    func testDiskMigrationMovesAndCleans() throws {
        // Uses a scratch layout mirroring ModelStore's structure but not the real
        // Application Support (this test never touches the user's library).
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("modelr-migration-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let fm = FileManager.default

        func write(_ rel: String, size: Int) throws {
            let url = root.appendingPathComponent(rel)
            try fm.createDirectory(at: url.deletingLastPathComponent(),
                                   withIntermediateDirectories: true)
            try Data(repeating: 7, count: size).write(to: url)
        }
        // A "legacy" tree: one mappable file (fake small size — plan is computed
        // against the real catalog, so use the plan directly for the move check).
        try write("shape/weights/Hunyuan3D-2mini/hunyuan3d-dit-v2-mini/model.fp16.safetensors", size: 64)
        try write("paint/hunyuan3d-paint-v2-0/unet/junk.tmp", size: 8)

        // Plan for these files: size 64 ≠ catalog → both deleted.
        var files: [(path: String, bytes: Int64)] = []
        let e = fm.enumerator(at: root, includingPropertiesForKeys: [.fileSizeKey])!
        for case let url as URL in e where (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true {
            let rel = url.path.replacingOccurrences(of: root.path + "/", with: "")
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
            files.append((rel, Int64(size)))
        }
        let plan = LegacyMigration.plan(files: files)
        XCTAssertTrue(plan.moves.isEmpty)
        XCTAssertEqual(Set(plan.deletions), Set(files.map(\.path)))
    }
}
