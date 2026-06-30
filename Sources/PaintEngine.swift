import Foundation
import simd
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

    /// Mirrors the old `GenerationService.paint` contract. `viewsDir` is where streamed
    /// preview grids are written (the caller cleans them up).
    @discardableResult
    func paint(meshURL: URL, imageURL: URL, output: URL, texture: URL, weightsRoot: URL,
               res: Int, steps: Int, tex: Int, superres: Bool, viewsDir: URL,
               onProgress: @escaping (String, Double?) -> Void,
               onViews: @escaping (URL) -> Void,
               onFinish: @escaping (GenerationService.Outcome) -> Void) -> Run {
        let run = Run()
        queue.async { [weak self] in
            guard let self else { return }
            if run.cancelled { onFinish(.failure("Cancelled")); return }
            guard let loaded = Self.loadShapeMesh(meshURL) else {
                onFinish(.failure("Couldn't read the shape mesh.")); return
            }

            let key = "\(weightsRoot.path)#\(res)#\(steps)#\(tex)#\(superres)"
            let pipe: PaintPipeline
            if self.cachedKey == key, let p = self.cachedPipe {
                pipe = p
            } else {
                onProgress("Loading paint model…", nil)
                self.cachedKey = nil
                self.cachedPipe = nil
                pipe = PaintPipeline(weightsRoot: weightsRoot.path, res: res, steps: steps,
                                     tex: tex, superRes: superres)
                self.cachedKey = key
                self.cachedPipe = pipe
            }
            if run.cancelled { onFinish(.failure("Cancelled")); return }

            var viewIdx = 0
            let result = pipe.paintRGB(
                mesh: loaded, imagePath: imageURL.path,
                onProgress: { stage, frac in onProgress(stage, Double(frac)) },
                isCancelled: { run.cancelled },
                onViews: { data in
                    let u = viewsDir.appendingPathComponent("paint_views_\(viewIdx).png")
                    viewIdx += 1
                    try? data.write(to: u)
                    onViews(u)
                })

            if run.cancelled { onFinish(.failure("Cancelled")); return }
            guard let result else { onFinish(.failure("Paint didn't produce a texture.")); return }
            do {
                try PaintMeshWriter.write(result, to: output)
                try result.albedoPNG.write(to: texture)
                onFinish(.success)
            } catch {
                onFinish(.failure("Couldn't write the painted mesh: \(error.localizedDescription)"))
            }
        }
        return run
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
    static func write(_ r: PaintResult, to url: URL) throws {
        let verts = r.vertices, faces = r.faces, uvs = r.uvs
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
