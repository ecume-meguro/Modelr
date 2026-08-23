import Foundation
import simd
import MLX
import HunyuanPaintMLX

/// In-process MLX paint/texture generation — the native-Swift replacement for the
/// Python paint worker. Holds a resident `PaintPipeline` (weights loaded once) and
/// runs the mesh+image → textured-mesh pipeline off-main on a serial queue.
final class PaintEngine {
    private let queue = DispatchQueue(label: "com.zimeng.Modelr.paint", qos: .userInitiated)
    private var cachedKey: String?
    private var cachedPipe: PaintPipeline?

    final class Run: CancellableRun {
        private let lock = NSLock()
        private var _cancelled = false
        var cancelled: Bool { lock.lock(); defer { lock.unlock() }; return _cancelled }
        func cancel() { lock.lock(); _cancelled = true; lock.unlock() }
    }

    /// 2.0 RGB (Color) paint. `viewsDir` is where streamed preview grids are written
    /// (the caller cleans them up). `seed` is the resolved concrete seed for this run.
    @discardableResult
    func paint(meshURL: URL, imageURL: URL, output: URL, texture: URL, weightsRoot: URL,
               res: Int, steps: Int, tex: Int, superres: Bool, seed: UInt64, viewsDir: URL,
               onProgress: @escaping (String, Double?) -> Void,
               onViews: @escaping (URL) -> Void,
               onFinish: @escaping (GenerationOutcome) -> Void) -> Run {
        let run = Run()
        queue.async { [weak self] in
            guard let self else { return }
            if run.cancelled { onFinish(.failure("Cancelled")); return }
            guard let loaded = Self.loadShapeMesh(meshURL) else {
                onFinish(.failure("Couldn't read the shape mesh.")); return
            }
            let pipe = self.residentPipe(weightsRoot: weightsRoot, res: res, steps: steps,
                                         tex: tex, superres: superres, onProgress: onProgress)
            if run.cancelled { onFinish(.failure("Cancelled")); return }

            var viewIdx = 0
            let result: PaintResult?
            do {
                result = try pipe.paintRGB(
                    mesh: loaded, imagePath: imageURL.path, guidance: 2.0, seed: seed,
                    onProgress: { stage, frac in onProgress(stage, Double(frac)) },
                    isCancelled: { run.cancelled },
                    onViews: { data in
                        let u = viewsDir.appendingPathComponent("paint_views_\(viewIdx).png")
                        viewIdx += 1
                        try? data.write(to: u)
                        onViews(u)
                    })
            } catch {
                self.cachedKey = nil; self.cachedPipe = nil      // failed load → retry fresh next time
                onFinish(.failure("Couldn't load the paint model: \(error.localizedDescription)"))
                return
            }

            if run.cancelled { onFinish(.failure("Cancelled")); return }
            guard let result else { onFinish(.failure("Couldn't unwrap or paint this mesh.")); return }
            do {
                try PaintMeshWriter.write(vertices: result.vertices, faces: result.faces,
                                          uvs: result.uvs, to: output)
                try result.albedoPNG.write(to: texture)
                if run.cancelled {                                // closed the post-write cancel window
                    try? FileManager.default.removeItem(at: output)
                    try? FileManager.default.removeItem(at: texture)
                    onFinish(.failure("Cancelled")); return
                }
                onFinish(.success)
            } catch {
                onFinish(.failure("Couldn't write the painted mesh: \(error.localizedDescription)"))
            }
        }
        return run
    }

    /// 2.1 PBR (Large) paint — same contract as `paint`, plus a metallic-roughness
    /// map written to `mrTexture` (G = roughness, B = metallic). Guidance is fixed at
    /// the 2.1 value (3.0); `seed` is the resolved concrete seed. The stage callbacks
    /// use the same strings the RGB path emits, so `mapPaintStage` maps them into the
    /// same reducer stages ("Baking textures" still matches the "Baking" prefix).
    @discardableResult
    func paintPBR(meshURL: URL, imageURL: URL, output: URL, texture: URL, mrTexture: URL,
                  weightsRoot: URL, res: Int, steps: Int, tex: Int, superres: Bool, seed: UInt64,
                  viewsDir: URL,
                  onProgress: @escaping (String, Double?) -> Void,
                  onViews: @escaping (URL) -> Void,
                  onFinish: @escaping (GenerationOutcome) -> Void) -> Run {
        let run = Run()
        queue.async { [weak self] in
            guard let self else { return }
            if run.cancelled { onFinish(.failure("Cancelled")); return }
            guard let loaded = Self.loadShapeMesh(meshURL) else {
                onFinish(.failure("Couldn't read the shape mesh.")); return
            }
            let pipe = self.residentPipe(weightsRoot: weightsRoot, res: res, steps: steps,
                                         tex: tex, superres: superres, onProgress: onProgress)
            if run.cancelled { onFinish(.failure("Cancelled")); return }

            var viewIdx = 0
            let result: PBRPaintResult?
            do {
                result = try pipe.paintPBR(
                    mesh: loaded, imagePath: imageURL.path, guidance: 3.0, seed: seed,
                    onProgress: { stage, frac in onProgress(stage, Double(frac)) },
                    isCancelled: { run.cancelled },
                    onViews: { data in
                        let u = viewsDir.appendingPathComponent("paint_views_\(viewIdx).png")
                        viewIdx += 1
                        try? data.write(to: u)
                        onViews(u)
                    })
            } catch {
                self.cachedKey = nil; self.cachedPipe = nil      // failed load → retry fresh next time
                onFinish(.failure("Couldn't load the paint model: \(error.localizedDescription)"))
                return
            }

            if run.cancelled { onFinish(.failure("Cancelled")); return }
            guard let result else { onFinish(.failure("Couldn't unwrap or paint this mesh.")); return }
            do {
                try PaintMeshWriter.write(vertices: result.vertices, faces: result.faces,
                                          uvs: result.uvs, to: output)
                try result.albedoPNG.write(to: texture)
                try result.metallicRoughnessPNG.write(to: mrTexture)
                // Sibling of the texture: "_coverage.png", magenta where no canonical view
                // painted head-on. The aligner shows it so the user can see what a reference
                // is allowed to cover.
                if let cov = result.coveragePNG {
                    let ns = mrTexture.deletingLastPathComponent()
                        .appendingPathComponent((texture.lastPathComponent as NSString)
                            .deletingPathExtension + "_coverage.png")
                    try? cov.write(to: ns)
                }
                if run.cancelled {                                // closed the post-write cancel window
                    for u in [output, texture, mrTexture] { try? FileManager.default.removeItem(at: u) }
                    onFinish(.failure("Cancelled")); return
                }
                onFinish(.success)
            } catch {
                onFinish(.failure("Couldn't write the painted mesh: \(error.localizedDescription)"))
            }
        }
        return run
    }

    /// 2.1 PBR paint end-to-end, but leaving the intermediate view sheets and un-baked geometry
    /// on disk so they can be edited and re-baked later via `bakePBR`. Behaves exactly like
    /// `paintPBR` from the caller's side — one `Run`, one `onFinish` — so it drops into the
    /// existing single-job flow; the sheets are simply a side effect rather than a new step.
    @discardableResult
    func paintAndBakePBR(meshURL: URL, imageURL: URL,
                         output: URL, texture: URL, mrTexture: URL,
                         albSheet: URL, mrSheet: URL, unbakedMesh: URL,
                         weightsRoot: URL, res: Int, steps: Int, tex: Int, superres: Bool,
                         seed: UInt64, viewsDir: URL, weights: [Float]? = nil,
                         onProgress: @escaping (String, Double?) -> Void,
                         onViews: @escaping (URL) -> Void,
                         onFinish: @escaping (GenerationOutcome) -> Void) -> Run {
        let run = Run()
        queue.async { [weak self] in
            guard let self else { return }
            if run.cancelled { onFinish(.failure("Cancelled")); return }
            guard let loaded = Self.loadShapeMesh(meshURL) else {
                onFinish(.failure("Couldn't read the shape mesh.")); return
            }
            let pipe = self.residentPipe(weightsRoot: weightsRoot, res: res, steps: steps,
                                         tex: tex, superres: superres, onProgress: onProgress)
            if run.cancelled { onFinish(.failure("Cancelled")); return }

            var viewIdx = 0
            let views: PaintViewsResult?
            do {
                views = try pipe.paintViewsPBR(
                    mesh: loaded, imagePath: imageURL.path, guidance: 3.0, seed: seed,
                    onProgress: { stage, frac in onProgress(stage, Double(frac)) },
                    isCancelled: { run.cancelled },
                    onViews: { data in
                        let u = viewsDir.appendingPathComponent("paint_views_\(viewIdx).png")
                        viewIdx += 1
                        try? data.write(to: u)
                        onViews(u)
                    })
            } catch {
                self.cachedKey = nil; self.cachedPipe = nil
                onFinish(.failure("Couldn't load the paint model: \(error.localizedDescription)"))
                return
            }
            if run.cancelled { onFinish(.failure("Cancelled")); return }
            guard let views else { onFinish(.failure("Couldn't unwrap or paint this mesh.")); return }

            // Persist the sheets + geometry BEFORE baking: diffusion is the expensive half, and
            // a failed bake must not throw it away. Stored v-flipped like every other .tmesh;
            // `bakePBR` un-flips on the way back in.
            do {
                var viewerUVs = views.uvs
                for i in 0..<(viewerUVs.count / 2) { viewerUVs[i*2+1] = 1 - viewerUVs[i*2+1] }
                try PaintMeshWriter.write(vertices: views.vertices, faces: views.faces,
                                          uvs: viewerUVs, to: unbakedMesh)
                try views.albedoSheetPNG.write(to: albSheet)
                try views.mrSheetPNG.write(to: mrSheet)
            } catch {
                onFinish(.failure("Couldn't write the view sheets: \(error.localizedDescription)"))
                return
            }

            guard let result = pipe.bakePBR(views: views, weights: weights,
                                            onProgress: { s, f in onProgress(s, Double(f)) })
            else { onFinish(.failure("Couldn't bake the painted views.")); return }
            if run.cancelled { onFinish(.failure("Cancelled")); return }

            do {
                try PaintMeshWriter.write(vertices: result.vertices, faces: result.faces,
                                          uvs: result.uvs, to: output)
                try result.albedoPNG.write(to: texture)
                try result.metallicRoughnessPNG.write(to: mrTexture)
                // Sibling of the texture: "_coverage.png", magenta where no canonical view
                // painted head-on. The aligner shows it so the user can see what a reference
                // is allowed to cover.
                if let cov = result.coveragePNG {
                    let ns = mrTexture.deletingLastPathComponent()
                        .appendingPathComponent((texture.lastPathComponent as NSString)
                            .deletingPathExtension + "_coverage.png")
                    try? cov.write(to: ns)
                }
                if run.cancelled {
                    for u in [output, texture, mrTexture, albSheet, mrSheet, unbakedMesh] {
                        try? FileManager.default.removeItem(at: u)
                    }
                    onFinish(.failure("Cancelled")); return
                }
                onFinish(.success)
            } catch {
                onFinish(.failure("Couldn't write the painted mesh: \(error.localizedDescription)"))
            }
        }
        return run
    }

    /// 2.1 PBR paint, stopping before the atlas bake. Runs the expensive half (diffusion +
    /// super-res) and writes the two flat view sheets plus the unwrapped geometry, so the
    /// sheets can be exported, edited, and baked later via `bake`. Same callback contract as
    /// `paintPBR`; `onFinish(.success)` means the sheets are on disk, not that a texture exists.
    @discardableResult
    func paintViewsPBR(meshURL: URL, imageURL: URL, albSheet: URL, mrSheet: URL, unbakedMesh: URL,
                       weightsRoot: URL, res: Int, steps: Int, tex: Int, superres: Bool,
                       seed: UInt64, viewsDir: URL,
                       onProgress: @escaping (String, Double?) -> Void,
                       onViews: @escaping (URL) -> Void,
                       onFinish: @escaping (GenerationOutcome) -> Void) -> Run {
        let run = Run()
        queue.async { [weak self] in
            guard let self else { return }
            if run.cancelled { onFinish(.failure("Cancelled")); return }
            guard let loaded = Self.loadShapeMesh(meshURL) else {
                onFinish(.failure("Couldn't read the shape mesh.")); return
            }
            let pipe = self.residentPipe(weightsRoot: weightsRoot, res: res, steps: steps,
                                         tex: tex, superres: superres, onProgress: onProgress)
            if run.cancelled { onFinish(.failure("Cancelled")); return }

            var viewIdx = 0
            let views: PaintViewsResult?
            do {
                views = try pipe.paintViewsPBR(
                    mesh: loaded, imagePath: imageURL.path, guidance: 3.0, seed: seed,
                    onProgress: { stage, frac in onProgress(stage, Double(frac)) },
                    isCancelled: { run.cancelled },
                    onViews: { data in
                        let u = viewsDir.appendingPathComponent("paint_views_\(viewIdx).png")
                        viewIdx += 1
                        try? data.write(to: u)
                        onViews(u)
                    })
            } catch {
                self.cachedKey = nil; self.cachedPipe = nil      // failed load → retry fresh next time
                onFinish(.failure("Couldn't load the paint model: \(error.localizedDescription)"))
                return
            }

            if run.cancelled { onFinish(.failure("Cancelled")); return }
            guard let views else { onFinish(.failure("Couldn't unwrap or paint this mesh.")); return }
            do {
                // Stored v-flipped like every other .tmesh; `bake` un-flips on the way back in.
                var viewerUVs = views.uvs
                for i in 0..<(viewerUVs.count / 2) { viewerUVs[i*2+1] = 1 - viewerUVs[i*2+1] }
                try PaintMeshWriter.write(vertices: views.vertices, faces: views.faces,
                                          uvs: viewerUVs, to: unbakedMesh)
                try views.albedoSheetPNG.write(to: albSheet)
                try views.mrSheetPNG.write(to: mrSheet)
                if run.cancelled {
                    for u in [unbakedMesh, albSheet, mrSheet] { try? FileManager.default.removeItem(at: u) }
                    onFinish(.failure("Cancelled")); return
                }
                onFinish(.success)
            } catch {
                onFinish(.failure("Couldn't write the view sheets: \(error.localizedDescription)"))
            }
        }
        return run
    }

    /// Bake step: project (possibly hand-edited) view sheets onto the atlas. Loads no model
    /// weights — only the rasterizer — so this is seconds, and cheap to repeat after each edit.
    /// `weights` overrides the per-view blend weights; the defaults weight the top and bottom
    /// views at 0.05 against the reference view's 1.0, which is why hand-painted roof detail
    /// can otherwise get washed out by the gap-filling inpaint.
    @discardableResult
    func bakePBR(unbakedMesh: URL, albSheet: URL, mrSheet: URL,
                 output: URL, texture: URL, mrTexture: URL,
                 weightsRoot: URL, tex: Int, viewCount: Int = 6, weights: [Float]? = nil,
                 extraViews: [ExtraView] = [],
                 onProgress: @escaping (String, Double?) -> Void,
                 onFinish: @escaping (GenerationOutcome) -> Void) -> Run {
        let run = Run()
        queue.async {
            if run.cancelled { onFinish(.failure("Cancelled")); return }
            guard let m = PaintMeshWriter.read(unbakedMesh) else {
                onFinish(.failure("Couldn't read the un-baked mesh.")); return
            }
            guard let albData = try? Data(contentsOf: albSheet),
                  let mrData = try? Data(contentsOf: mrSheet) else {
                onFinish(.failure("Couldn't read the view sheets.")); return
            }
            var rawUVs = m.uvs                                  // undo the stored v-flip
            for i in 0..<(rawUVs.count / 2) { rawUVs[i*2+1] = 1 - rawUVs[i*2+1] }

            let views = PaintViewsResult(vertices: m.vertices, faces: m.faces, uvs: rawUVs,
                                         albedoSheetPNG: albData, mrSheetPNG: mrData,
                                         viewCount: viewCount)
            // Constructing a pipeline is free — `bakePBR` never calls `loadPBR`.
            let pipe = PaintPipeline(weightsRoot: weightsRoot.path, tex: tex)
            pipe.tex = tex
            onProgress("Baking textures", nil)
            guard let result = pipe.bakePBR(views: views,
                                            albedoSheetPath: albSheet.path,
                                            mrSheetPath: mrSheet.path,
                                            weights: weights,
                                            extraViews: extraViews,
                                            onProgress: { stage, frac in onProgress(stage, Double(frac)) })
            else { onFinish(.failure("Couldn't bake these view sheets.")); return }

            if run.cancelled { onFinish(.failure("Cancelled")); return }
            do {
                try PaintMeshWriter.write(vertices: result.vertices, faces: result.faces,
                                          uvs: result.uvs, to: output)
                try result.albedoPNG.write(to: texture)
                try result.metallicRoughnessPNG.write(to: mrTexture)
                // Sibling of the texture: "_coverage.png", magenta where no canonical view
                // painted head-on. The aligner shows it so the user can see what a reference
                // is allowed to cover.
                if let cov = result.coveragePNG {
                    let ns = mrTexture.deletingLastPathComponent()
                        .appendingPathComponent((texture.lastPathComponent as NSString)
                            .deletingPathExtension + "_coverage.png")
                    try? cov.write(to: ns)
                }
                if run.cancelled {
                    for u in [output, texture, mrTexture] { try? FileManager.default.removeItem(at: u) }
                    onFinish(.failure("Cancelled")); return
                }
                onFinish(.success)
            } catch {
                onFinish(.failure("Couldn't write the baked mesh: \(error.localizedDescription)"))
            }
        }
        return run
    }

    /// Fetch (or build) the resident pipeline for `weightsRoot`. Keys only on what
    /// changes the LOADED WEIGHTS (root + whether super-res loads); res/steps/tex are
    /// per-run knobs set on the cached pipe so changing quality — or switching between
    /// the Color and PBR checkpoints (different roots) — doesn't needlessly reload GBs.
    /// Must be called on `queue`.
    private func residentPipe(weightsRoot: URL, res: Int, steps: Int, tex: Int, superres: Bool,
                              onProgress: (String, Double?) -> Void) -> PaintPipeline {
        let key = "\(weightsRoot.path)#\(superres)"
        let pipe: PaintPipeline
        if cachedKey == key, let p = cachedPipe {
            pipe = p
        } else {
            onProgress("Loading paint model…", nil)
            cachedKey = nil
            cachedPipe = nil
            MLX.GPU.clearCache()
            pipe = PaintPipeline(weightsRoot: weightsRoot.path, res: res, steps: steps,
                                 tex: tex, superRes: superres)
            cachedKey = key
            cachedPipe = pipe
        }
        pipe.res = res; pipe.steps = steps; pipe.tex = tex
        return pipe
    }

    /// Drop the resident paint pipeline and free GPU buffers (called when the shape
    /// engine starts, so both model sets aren't resident at once).
    func evict() {
        queue.async {
            self.cachedKey = nil
            self.cachedPipe = nil
            MLX.GPU.clearCache()
        }
    }

    /// Eviction the EngineArbiter can await: returns only after the resident
    /// pipeline has actually been dropped on the engine queue.
    func evictAndWait() async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            queue.async {
                self.cachedKey = nil
                self.cachedPipe = nil
                MLX.GPU.clearCache()
                cont.resume()
            }
        }
    }

    /// Parse Modelr's `.mesh` (verts + normals + faces) into the paint package's
    /// `LoadedMesh` (positions + faces only).
    private static func loadShapeMesh(_ url: URL) -> LoadedMesh? {
        guard let d = try? Data(contentsOf: url), d.count >= 8 else { return nil }
        let n = Int(d.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 0, as: Int32.self) })
        let m = Int(d.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 4, as: Int32.self) })
        guard n > 0, m > 0 else { return nil }
        let vBytes = n * 12, nBytes = n * 12, fBytes = m * 12
        guard d.count >= 8 + vBytes + nBytes + fBytes else { return nil }
        var verts = [Float](repeating: 0, count: n * 3)
        var faces = [UInt32](repeating: 0, count: m * 3)
        d.withUnsafeBytes { raw in
            for i in 0..<(n * 3) { verts[i] = raw.loadUnaligned(fromByteOffset: 8 + i * 4, as: Float.self) }
            let foff = 8 + vBytes + nBytes
            for i in 0..<(m * 3) { faces[i] = raw.loadUnaligned(fromByteOffset: foff + i * 4, as: UInt32.self) }
        }
        return LoadedMesh(vertices: verts, faces: faces)
    }
}

/// Serializes a `PaintResult` into Modelr's `.tmesh`
/// (`[i32 nV][i32 nF][f32 verts][f32 normals][f32 uvs][i32 faces]`), computing
/// area-weighted vertex normals.
enum PaintMeshWriter {
    /// Inverse of `write`, minus the normals (the bake recomputes nothing from them).
    /// The `uvs` returned are in the same viewer convention `write` stored — v-flipped —
    /// so a caller feeding them back into the paint package must un-flip first.
    static func read(_ url: URL) -> (vertices: [Float], faces: [UInt32], uvs: [Float])? {
        guard let d = try? Data(contentsOf: url), d.count >= 8 else { return nil }
        let n = Int(d.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 0, as: Int32.self) })
        let m = Int(d.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 4, as: Int32.self) })
        guard n > 0, m > 0 else { return nil }
        let vBytes = n * 12, nBytes = n * 12, uvBytes = n * 8, fBytes = m * 12
        guard d.count >= 8 + vBytes + nBytes + uvBytes + fBytes else { return nil }
        var verts = [Float](repeating: 0, count: n * 3)
        var uvs = [Float](repeating: 0, count: n * 2)
        var faces = [UInt32](repeating: 0, count: m * 3)
        d.withUnsafeBytes { raw in
            for i in 0..<(n * 3) { verts[i] = raw.loadUnaligned(fromByteOffset: 8 + i * 4, as: Float.self) }
            let uoff = 8 + vBytes + nBytes
            for i in 0..<(n * 2) { uvs[i] = raw.loadUnaligned(fromByteOffset: uoff + i * 4, as: Float.self) }
            let foff = uoff + uvBytes
            for i in 0..<(m * 3) { faces[i] = raw.loadUnaligned(fromByteOffset: foff + i * 4, as: UInt32.self) }
        }
        return (verts, faces, uvs)
    }

    /// Serialize unwrapped geometry + UVs (shared by the RGB and PBR paint paths —
    /// both produce the same geometry contract, differing only in their baked maps).
    static func write(vertices verts: [Float], faces: [UInt32], uvs: [Float], to url: URL) throws {
        let n = verts.count / 3, m = faces.count / 3
        guard n > 0, m > 0, uvs.count == n * 2 else {
            throw NSError(domain: "PaintMeshWriter", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "malformed paint result"])
        }

        var normals = [Float](repeating: 0, count: n * 3)
        func vert(_ i: Int) -> SIMD3<Float> { SIMD3(verts[i*3], verts[i*3+1], verts[i*3+2]) }
        for f in 0..<m {
            let i0 = Int(faces[f*3]), i1 = Int(faces[f*3+1]), i2 = Int(faces[f*3+2])
            let fn = simd_cross(vert(i1) - vert(i0), vert(i2) - vert(i0))   // area-weighted
            for i in [i0, i1, i2] { normals[i*3]+=fn.x; normals[i*3+1]+=fn.y; normals[i*3+2]+=fn.z }
        }
        for i in 0..<n {
            let v = SIMD3<Float>(normals[i*3], normals[i*3+1], normals[i*3+2])
            let l = simd_length(v)
            let u = l > 1e-12 ? v / l : SIMD3<Float>(0, 0, 1)
            normals[i*3] = u.x; normals[i*3+1] = u.y; normals[i*3+2] = u.z
        }

        var data = Data()
        data.reserveCapacity(8 + n * 12 + n * 12 + n * 8 + m * 12)
        appendI32(&data, Int32(n)); appendI32(&data, Int32(m))
        for i in 0..<(n * 3) { appendF(&data, verts[i]) }
        for i in 0..<(n * 3) { appendF(&data, normals[i]) }
        for i in 0..<(n * 2) { appendF(&data, uvs[i]) }
        for i in 0..<(m * 3) { appendU32(&data, faces[i]) }
        try data.write(to: url)
    }

    private static func appendF(_ d: inout Data, _ v: Float) {
        var x = v.bitPattern.littleEndian; withUnsafeBytes(of: &x) { d.append(contentsOf: $0) }
    }
    private static func appendI32(_ d: inout Data, _ v: Int32) {
        var x = v.littleEndian; withUnsafeBytes(of: &x) { d.append(contentsOf: $0) }
    }
    private static func appendU32(_ d: inout Data, _ v: UInt32) {
        var x = v.littleEndian; withUnsafeBytes(of: &x) { d.append(contentsOf: $0) }
    }
}
