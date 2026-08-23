import Foundation
import CoreGraphics
import ImageIO
import simd

/// Which faces are glass, decided on the mesh rather than by sampling the texture.
///
/// Every previous approach asked "is this texel transparent?" and then tried to turn that into a
/// per-triangle answer. That question has no reliable answer at a window's edge: the UV atlas is
/// thousands of small charts whose seams run along exactly those edges, so the samples a boundary
/// triangle takes are as likely to land on frame as on glass. Threshold tuning, inclusive
/// boundaries, distance-field edges and four times the texel density each improved something and
/// left the same ragged seam.
///
/// A face is either glass or it is not, and the mesh already knows where a window ends: the frame
/// meets the glass at a sharp crease. Flooding across faces while refusing to cross that crease
/// gives an exact set whose boundary is the geometry's own edge — nothing to sample, nothing to
/// alias.
struct GlassSelection {
    /// One bit per face.
    private(set) var mask: [Bool]

    var count: Int { mask.lazy.filter { $0 }.count }
    var isEmpty: Bool { !mask.contains(true) }

    init(faceCount: Int) { mask = [Bool](repeating: false, count: faceCount) }
    init(mask: [Bool]) { self.mask = mask }

    // MARK: - persistence

    /// Sits beside the mesh as `<stem>_glass.bin`: a face count then a packed bitset. Kept out of
    /// the project index because it is per-mesh and can be large.
    static func url(forMesh mesh: URL) -> URL {
        mesh.deletingLastPathComponent()
            .appendingPathComponent(mesh.deletingPathExtension().lastPathComponent + "_glass.bin")
    }

    static func load(forMesh mesh: URL) -> GlassSelection? {
        let u = url(forMesh: mesh)
        guard let d = try? Data(contentsOf: u), d.count >= 4 else { return nil }
        let n = Int(d.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 0, as: UInt32.self) })
        guard n > 0, d.count >= 4 + (n + 7) / 8 else { return nil }
        var m = [Bool](repeating: false, count: n)
        d.withUnsafeBytes { raw in
            for i in 0 ..< n {
                let byte = raw.loadUnaligned(fromByteOffset: 4 + i / 8, as: UInt8.self)
                m[i] = (byte >> UInt8(i % 8)) & 1 == 1
            }
        }
        return GlassSelection(mask: m)
    }

    func save(forMesh mesh: URL) {
        var d = Data()
        var n = UInt32(mask.count)
        withUnsafeBytes(of: &n) { d.append(contentsOf: $0) }
        var bytes = [UInt8](repeating: 0, count: (mask.count + 7) / 8)
        for i in 0 ..< mask.count where mask[i] { bytes[i / 8] |= 1 << UInt8(i % 8) }
        d.append(contentsOf: bytes)
        try? d.write(to: GlassSelection.url(forMesh: mesh))
    }

    static func clear(forMesh mesh: URL) {
        try? FileManager.default.removeItem(at: url(forMesh: mesh))
    }

    // MARK: - mesh topology

    /// Faces sharing an edge, plus each face's normal — everything the flood needs.
    struct Topology {
        let faceCount: Int
        let normals: [SIMD3<Float>]
        /// Neighbours per face, flattened with an offset table (faces have at most 3).
        let neighbourStart: [Int]
        let neighbours: [Int]

        func neighbours(of face: Int) -> ArraySlice<Int> {
            neighbours[neighbourStart[face] ..< neighbourStart[face + 1]]
        }
    }

    static func topology(vertices: [Float], faces: [UInt32]) -> Topology {
        let m = faces.count / 3
        var normals = [SIMD3<Float>](repeating: .zero, count: m)
        for f in 0 ..< m {
            let i = Int(faces[f*3]), j = Int(faces[f*3+1]), k = Int(faces[f*3+2])
            let a = SIMD3(vertices[i*3], vertices[i*3+1], vertices[i*3+2])
            let b = SIMD3(vertices[j*3], vertices[j*3+1], vertices[j*3+2])
            let c = SIMD3(vertices[k*3], vertices[k*3+1], vertices[k*3+2])
            let n = cross(b - a, c - a)
            let len = simd_length(n)
            normals[f] = len > 1e-12 ? n / len : SIMD3(0, 1, 0)
        }

        // Weld by position before looking for shared edges.
        //
        // The .tmesh is NOT welded by index: a fifth of its vertices are duplicates sitting at
        // the same point, because the UV unwrap splits a vertex once per chart that uses it. Two
        // triangles can therefore meet along a seam in space while sharing no vertex index at
        // all, and an edge test on raw indices declares them unconnected.
        //
        // The cost of missing this was everything downstream: the car came out as 4,717 separate
        // "pieces" instead of one, so every tool built on connectivity misbehaved — floating-bit
        // detection marked half the bodywork, gap filling could not cross a seam, and grow and
        // shrink stopped at chart boundaries. Welded, the same mesh is 3 components: the car, one
        // 4,360-face lump, and an 8-face speck.
        //
        // The tolerance is relative to the model, and a duplicate is an exact copy of the same
        // float, so this only ever merges points that were already identical.
        var lo = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
        var hi = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
        var vi = 0
        while vi + 2 < vertices.count {
            let v = SIMD3(vertices[vi], vertices[vi+1], vertices[vi+2])
            lo = simd_min(lo, v); hi = simd_max(hi, v); vi += 3
        }
        let quantum = max(simd_length(hi - lo) * 1e-5, 1e-9)
        let vertexCount = vertices.count / 3
        var welded = [Int32](repeating: 0, count: vertexCount)
        var seen = [SIMD3<Int32>: Int32]()
        seen.reserveCapacity(vertexCount)
        for i in 0 ..< vertexCount {
            let key = SIMD3<Int32>(Int32((vertices[i*3]     / quantum).rounded()),
                                   Int32((vertices[i*3 + 1] / quantum).rounded()),
                                   Int32((vertices[i*3 + 2] / quantum).rounded()))
            if let r = seen[key] { welded[i] = r } else { seen[key] = Int32(i); welded[i] = Int32(i) }
        }

        var edgeFaces = [UInt64: [Int]]()
        edgeFaces.reserveCapacity(m * 3)
        for f in 0 ..< m {
            let v = [welded[Int(faces[f*3])], welded[Int(faces[f*3+1])], welded[Int(faces[f*3+2])]]
            for e in 0 ..< 3 {
                let a = UInt32(bitPattern: v[e]), b = UInt32(bitPattern: v[(e + 1) % 3])
                let key = a < b ? (UInt64(a) << 32 | UInt64(b)) : (UInt64(b) << 32 | UInt64(a))
                edgeFaces[key, default: []].append(f)
            }
        }
        var lists = [[Int]](repeating: [], count: m)
        for (_, fs) in edgeFaces where fs.count >= 2 {
            // Usually two, but a welded seam can gather more; join them all rather than dropping
            // the edge, which would leave the very seams this welding exists to close.
            for i in 0 ..< fs.count {
                for j in (i + 1) ..< fs.count {
                    lists[fs[i]].append(fs[j]); lists[fs[j]].append(fs[i])
                }
            }
        }
        var start = [Int](repeating: 0, count: m + 1)
        var flat = [Int](); flat.reserveCapacity(m * 3)
        for f in 0 ..< m { start[f] = flat.count; flat.append(contentsOf: lists[f]) }
        start[m] = flat.count
        return Topology(faceCount: m, normals: normals, neighbourStart: start, neighbours: flat)
    }

    // MARK: - selection

    /// Grow from a face across neighbours whose normals agree, stopping at creases.
    ///
    /// `creaseDegrees` is the fold angle that counts as an edge of the surface. A windscreen is
    /// smooth to within a few degrees across itself and meets its surround at a hard angle, so
    /// anything from about 25 to 40 degrees separates them cleanly.
    static func flood(from seed: Int, topology t: Topology, creaseDegrees: Double = 32,
                      limit: Int = 200_000) -> [Bool] {
        var out = [Bool](repeating: false, count: t.faceCount)
        guard seed >= 0, seed < t.faceCount else { return out }
        let cosLimit = Float(cos(creaseDegrees * .pi / 180))
        var stack = [seed]
        out[seed] = true
        var taken = 1
        while let f = stack.popLast(), taken < limit {
            for n in t.neighbours(of: f) where !out[n] {
                // Compare against the neighbour we came from, not the seed: a curved windscreen
                // drifts a long way from its starting normal while never folding sharply.
                if simd_dot(t.normals[f], t.normals[n]) >= cosLimit {
                    out[n] = true; taken += 1; stack.append(n)
                }
            }
        }
        return out
    }

    /// Everything the texture already believes is glass, used only to seed the flood.
    ///
    /// The alpha is a good indicator of *where* the windows are and a poor one of exactly which
    /// triangles they cover. So it picks the seeds and the mesh decides the extent.
    static func autoSelect(vertices: [Float], faces: [UInt32], texture: URL,
                           uvs: [Float], creaseDegrees: Double = 32) -> GlassSelection {
        let t = topology(vertices: vertices, faces: faces)
        var sel = GlassSelection(faceCount: t.faceCount)
        guard let cg = loadCG(texture), let alpha = alphaPlane(cg) else { return sel }
        let (w, h, px) = alpha
        let cut = alphaCut(px)

        // A face seeds only if its centre is *solidly* transparent — seeds should be
        // unambiguous; the flood supplies the reach.
        var seeds = [Int]()
        for f in 0 ..< t.faceCount {
            var u: Float = 0, v: Float = 0
            for k in 0 ..< 3 {
                let i = Int(faces[f*3 + k]); u += uvs[i*2]; v += uvs[i*2 + 1]
            }
            let x = min(max(Int(u / 3 * Float(w - 1)), 0), w - 1)
            let y = min(max(Int(v / 3 * Float(h - 1)), 0), h - 1)
            if Float(px[y * w + x]) / 255 < cut - 0.08 { seeds.append(f) }
        }
        guard !seeds.isEmpty else { return sel }

        // Flood from each seed, skipping seeds already covered — a window is reached once.
        var mask = [Bool](repeating: false, count: t.faceCount)
        for s in seeds where !mask[s] {
            let region = flood(from: s, topology: t, creaseDegrees: creaseDegrees)
            // Only keep a region if the texture agrees about most of it. A crease-bounded flood
            // from a stray seed can otherwise run across a whole body panel.
            var inRegion = 0, agreeing = 0
            for f in 0 ..< t.faceCount where region[f] {
                inRegion += 1
                if seedsSet(seeds).contains(f) { agreeing += 1 }
            }
            if inRegion > 0, Double(agreeing) / Double(inRegion) > 0.35 {
                for f in 0 ..< t.faceCount where region[f] { mask[f] = true }
            } else {
                mask[s] = true
            }
        }
        sel = GlassSelection(mask: mask)
        return sel
    }

    private static var cachedSeeds: (key: Int, set: Set<Int>)?
    private static func seedsSet(_ seeds: [Int]) -> Set<Int> {
        if let c = cachedSeeds, c.key == seeds.count { return c.set }
        let s = Set(seeds); cachedSeeds = (seeds.count, s); return s
    }

    mutating func add(_ region: [Bool]) {
        for i in 0 ..< min(mask.count, region.count) where region[i] { mask[i] = true }
    }

    mutating func remove(_ region: [Bool]) {
        for i in 0 ..< min(mask.count, region.count) where region[i] { mask[i] = false }
    }

    // MARK: - texture helpers

    private static func loadCG(_ url: URL) -> CGImage? {
        guard let d = try? Data(contentsOf: url),
              let src = CGImageSourceCreateWithData(d as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(src, 0, nil)
    }

    private static func alphaPlane(_ cg: CGImage) -> (Int, Int, [UInt8])? {
        let w = cg.width, h = cg.height
        guard w > 0, h > 0 else { return nil }
        var rgba = [UInt8](repeating: 0, count: w * h * 4)
        guard let ctx = CGContext(data: &rgba, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        var a = [UInt8](repeating: 255, count: w * h)
        for i in 0 ..< (w * h) { a[i] = rgba[i * 4 + 3] }
        return (w, h, a)
    }

    /// Same measured cut the bake uses: each model paints its glass at its own alpha.
    private static func alphaCut(_ a: [UInt8]) -> Float {
        var soft = [Float]()
        let step = max(1, a.count / 200_000)
        var i = 0
        while i < a.count {
            let v = Float(a[i]) / 255
            if v < 0.995 { soft.append(v) }
            i += step
        }
        guard soft.count > 64 else { return 0.75 }
        soft.sort()
        return min(0.9, max(0.5, soft[soft.count * 5 / 100] + 0.08))
    }
}
