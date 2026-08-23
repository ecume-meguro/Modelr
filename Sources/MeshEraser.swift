import Foundation
import CoreGraphics
import simd

/// Faces hidden from a mesh after the fact.
///
/// Generated meshes hallucinate: a stray shell floating beside the car, a lump welded to a sill,
/// a phantom mirror. There is no way to talk the model out of them after the fact, and re-rolling
/// the seed changes everything else too. Deleting them is the only remedy.
///
/// The deletion is stored beside the mesh rather than applied to it. Editing the `.tmesh` in place
/// would invalidate every texture baked against it — the UVs are per-vertex and the bake indexes
/// faces — and would make a mistake permanent. A mask costs one bit per face, is reversible, and
/// both the preview and the export simply skip the faces it names.
struct MeshEraser {
    private(set) var deleted: [Bool]

    var count: Int { deleted.lazy.filter { $0 }.count }
    var isEmpty: Bool { !deleted.contains(true) }

    init(faceCount: Int) { deleted = [Bool](repeating: false, count: faceCount) }
    init(deleted: [Bool]) { self.deleted = deleted }

    static func url(forMesh mesh: URL) -> URL {
        mesh.deletingLastPathComponent()
            .appendingPathComponent(mesh.deletingPathExtension().lastPathComponent + "_erased.bin")
    }

    static func load(forMesh mesh: URL) -> MeshEraser? {
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
        return MeshEraser(deleted: m)
    }

    func save(forMesh mesh: URL) {
        var d = Data()
        var n = UInt32(deleted.count)
        withUnsafeBytes(of: &n) { d.append(contentsOf: $0) }
        var bytes = [UInt8](repeating: 0, count: (deleted.count + 7) / 8)
        for i in 0 ..< deleted.count where deleted[i] { bytes[i / 8] |= 1 << UInt8(i % 8) }
        d.append(contentsOf: bytes)
        try? d.write(to: MeshEraser.url(forMesh: mesh))
    }

    static func clear(forMesh mesh: URL) {
        try? FileManager.default.removeItem(at: url(forMesh: mesh))
    }

    // MARK: - what to erase

    /// Every face reachable from this one across shared edges, ignoring how sharply it folds.
    ///
    /// This is the right tool for a hallucinated blob: such things are usually their own shell,
    /// disconnected from the body, so one click takes the whole thing and nothing else. Where the
    /// junk *is* welded to the car this will over-reach, which is what the crease and sphere modes
    /// are for.
    static func connectedComponent(from seed: Int, topology t: GlassSelection.Topology,
                                   limit: Int = 400_000) -> [Bool] {
        var out = [Bool](repeating: false, count: t.faceCount)
        guard seed >= 0, seed < t.faceCount else { return out }
        var stack = [seed]; out[seed] = true; var taken = 1
        while let f = stack.popLast(), taken < limit {
            for n in t.neighbours(of: f) where !out[n] {
                out[n] = true; taken += 1; stack.append(n)
            }
        }
        return out
    }

    /// Every face with a vertex inside a sphere — the literal spatial eraser.
    ///
    /// Radius is in mesh units, which the shape stage normalises, so a value near 0.05 is a small
    /// bite and 0.3 takes a whole corner regardless of how the mesh is connected.
    static func sphere(centre: SIMD3<Float>, radius: Float,
                       vertices: [Float], faces: [UInt32]) -> [Bool] {
        let m = faces.count / 3
        var out = [Bool](repeating: false, count: m)
        let r2 = radius * radius
        for f in 0 ..< m {
            for k in 0 ..< 3 {
                let i = Int(faces[f*3 + k])
                let v = SIMD3(vertices[i*3], vertices[i*3+1], vertices[i*3+2])
                if simd_length_squared(v - centre) <= r2 { out[f] = true; break }
            }
        }
        return out
    }

    /// Shells not connected to the largest one, with a size ceiling — the automatic pass.
    ///
    /// Hallucinated geometry is nearly always a small separate shell, so this finds the obvious
    /// candidates without any clicking. The ceiling keeps it from proposing, say, a detached
    /// wheel that genuinely belongs.
    static func looseShells(topology t: GlassSelection.Topology,
                            maxFractionOfLargest: Double = 0.05) -> (mask: [Bool], shells: Int) {
        var label = [Int](repeating: -1, count: t.faceCount)
        var sizes = [Int]()
        for f in 0 ..< t.faceCount where label[f] < 0 {
            let id = sizes.count
            var stack = [f]; label[f] = id; var n = 0
            while let x = stack.popLast() {
                n += 1
                for y in t.neighbours(of: x) where label[y] < 0 { label[y] = id; stack.append(y) }
            }
            sizes.append(n)
        }
        guard let biggest = sizes.max(), sizes.count > 1 else {
            return ([Bool](repeating: false, count: t.faceCount), 0)
        }
        let ceiling = Int(Double(biggest) * maxFractionOfLargest)
        var mask = [Bool](repeating: false, count: t.faceCount)
        var shells = 0
        for id in 0 ..< sizes.count where sizes[id] != biggest && sizes[id] <= ceiling {
            shells += 1
            for f in 0 ..< t.faceCount where label[f] == id { mask[f] = true }
        }
        return (mask, shells)
    }

    /// Swallow the specks a crease flood leaves behind.
    ///
    /// A generated mesh is noisy: inside an otherwise smooth panel, individual triangles fold
    /// sharply enough to look like the edge of the surface, so the flood stops at them and leaves
    /// a rash of unmarked slivers. Any face whose neighbours are mostly marked belongs with them —
    /// judged on the face graph, so it works regardless of how the mesh is laid out in UV space.
    static func fillGaps(_ mask: [Bool], topology t: GlassSelection.Topology,
                         rounds: Int = 4) -> [Bool] {
        var out = mask
        for _ in 0 ..< rounds {
            var next = out
            var changed = false
            for f in 0 ..< t.faceCount where !out[f] {
                let n = t.neighbours(of: f)
                guard !n.isEmpty else { continue }
                let marked = n.reduce(0) { $0 + (out[$1] ? 1 : 0) }
                // Two of three neighbours is enough: a sliver inside a marked area always has
                // at least that, while a face on the outside boundary has at most one.
                if marked >= 2 && marked >= n.count - 1 { next[f] = true; changed = true }
            }
            out = next
            if !changed { break }
        }
        return out
    }

    /// Close gaps by proximity in 3D rather than through the face graph.
    ///
    /// A generated mesh is not cleanly manifold: inside a marked area there are triangles that
    /// share no edge with anything around them. They are invisible to any adjacency-based fill —
    /// which is why growing, shrinking and graph-based filling all left them behind. Judging by
    /// where a face physically *is* catches them: a triangle surrounded in space by marked
    /// triangles belongs with them, however the index buffer happens to connect it.
    ///
    /// `strength` is in multiples of the mesh's typical face size, so it means the same thing on
    /// a coarse mesh as on a dense one.
    static func spatialFill(_ mask: [Bool], vertices: [Float], faces: [UInt32],
                            strength: Double, ratio: Double = 0.55) -> [Bool] {
        let m = faces.count / 3
        guard m > 0, strength > 0 else { return mask }
        var centre = [SIMD3<Float>](repeating: .zero, count: m)
        for f in 0 ..< m {
            var c = SIMD3<Float>.zero
            for k in 0 ..< 3 {
                let i = Int(faces[f*3 + k])
                c += SIMD3(vertices[i*3], vertices[i*3+1], vertices[i*3+2])
            }
            centre[f] = c / 3
        }
        // Typical face size, from a sample — the mesh is normalised but face density is not.
        var sample = [Float]()
        var f = 0
        while f < m, sample.count < 2000 {
            let i0 = Int(faces[f*3]), i1 = Int(faces[f*3+1])
            let a = SIMD3(vertices[i0*3], vertices[i0*3+1], vertices[i0*3+2])
            let b = SIMD3(vertices[i1*3], vertices[i1*3+1], vertices[i1*3+2])
            sample.append(simd_length(b - a))
            f += max(1, m / 2000)
        }
        sample.sort()
        let unit = sample.isEmpty ? Float(0.005) : sample[sample.count / 2]
        let radius = unit * Float(strength) * 2
        let r2 = radius * radius

        // Uniform grid over marked faces, so each test is local rather than a full scan.
        var lo = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
        var hi = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
        for i in 0 ..< m where mask[i] { lo = simd_min(lo, centre[i]); hi = simd_max(hi, centre[i]) }
        guard lo.x <= hi.x else { return mask }
        let cell = max(radius, 1e-5)
        func key(_ p: SIMD3<Float>) -> Int {
            let a = Int(floor(p.x / cell)), b = Int(floor(p.y / cell)), c = Int(floor(p.z / cell))
            return (a &* 73856093) ^ (b &* 19349663) ^ (c &* 83492791)
        }
        var buckets = [Int: [Int]]()
        for i in 0 ..< m where mask[i] { buckets[key(centre[i]), default: []].append(i) }

        var out = mask
        for i in 0 ..< m where !mask[i] {
            let p = centre[i]
            guard p.x >= lo.x - radius, p.x <= hi.x + radius,
                  p.y >= lo.y - radius, p.y <= hi.y + radius,
                  p.z >= lo.z - radius, p.z <= hi.z + radius else { continue }
            // Count marked faces around it, and how much of the sphere they surround.
            var near = 0
            var dirs = SIMD3<Float>.zero
            for dx in -1...1 { for dy in -1...1 { for dz in -1...1 {
                let q = p + SIMD3(Float(dx), Float(dy), Float(dz)) * cell
                for j in buckets[key(q)] ?? [] {
                    let d = centre[j] - p
                    if simd_length_squared(d) <= r2 {
                        near += 1
                        dirs += simd_normalize(d + SIMD3(1e-9, 0, 0))
                    }
                }
            }}}
            guard near >= 3 else { continue }
            // Surrounded means the neighbours pull in every direction and cancel out; a face on
            // the outside edge of a marked area has them all on one side.
            let bias = simd_length(dirs) / Float(near)
            if bias < Float(1 - ratio) { out[i] = true }
        }
        return out
    }

    /// How big a region is, as a fraction of the whole model.
    ///
    /// Measured as the diagonal of its bounding box over the mesh's own diagonal, so it means the
    /// same thing whatever scale the mesh arrived at, and so a long thin sliver counts as small.
    static func extent(_ region: [Bool], vertices: [Float], faces: [UInt32],
                       meshDiagonal: Float) -> Float {
        var lo = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
        var hi = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
        var any = false
        for f in 0 ..< min(region.count, faces.count / 3) where region[f] {
            for k in 0 ..< 3 {
                let i = Int(faces[f*3 + k])
                let v = SIMD3(vertices[i*3], vertices[i*3+1], vertices[i*3+2])
                lo = simd_min(lo, v); hi = simd_max(hi, v); any = true
            }
        }
        guard any, meshDiagonal > 1e-9 else { return 0 }
        return simd_length(hi - lo) / meshDiagonal
    }

    /// A region, or nothing if it is bigger than `maxFraction` of the model.
    ///
    /// Refusing rather than trimming is the point: the panel behind a cloud of specks should be
    /// impossible to catch, so with the cap down you can sweep the cursor across the whole cloud
    /// and only the specks ever answer.
    static func capped(_ region: [Bool], vertices: [Float], faces: [UInt32],
                       meshDiagonal: Float, maxFraction: Double) -> [Bool]? {
        guard maxFraction < 0.999 else { return region }
        let e = extent(region, vertices: vertices, faces: faces, meshDiagonal: meshDiagonal)
        return e <= Float(maxFraction) ? region : nil
    }

    static func meshDiagonal(vertices: [Float]) -> Float {
        var lo = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
        var hi = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
        var i = 0
        while i + 2 < vertices.count {
            let v = SIMD3(vertices[i], vertices[i+1], vertices[i+2])
            lo = simd_min(lo, v); hi = simd_max(hi, v); i += 3
        }
        return max(simd_length(hi - lo), 1e-9)
    }

    /// Every detached piece smaller than a given size — floating debris, by definition.
    ///
    /// Two conditions, and both matter. *Detached* means its own connected component: a speck
    /// welded to the door is not floating, and deleting it would tear a hole in the door. *Small*
    /// is measured spatially, as a share of the model's own diagonal, so it means the same thing
    /// on any mesh and so a piece is judged by how big it looks rather than how finely it happens
    /// to be tessellated — a hundred-triangle speck and a hundred-triangle wing mirror are not
    /// the same thing.
    ///
    /// The largest component is always spared: that is the car.
    static func floatingPieces(topology t: GlassSelection.Topology,
                               vertices: [Float], faces: [UInt32],
                               meshDiagonal: Float,
                               maxFraction: Double) -> (mask: [Bool], pieces: Int) {
        let (label, extent) = componentExtents(topology: t, vertices: vertices, faces: faces,
                                               meshDiagonal: meshDiagonal)
        guard extent.count > 1 else { return ([Bool](repeating: false, count: t.faceCount), 0) }
        let body = extent.firstIndex(of: extent.max()!)!
        var take = Set<Int>()
        for id in 0 ..< extent.count where id != body && extent[id] <= Float(maxFraction) {
            take.insert(id)
        }
        var mask = [Bool](repeating: false, count: t.faceCount)
        for f in 0 ..< t.faceCount where take.contains(label[f]) { mask[f] = true }
        return (mask, take.count)
    }

    /// Connected pieces, and how big each one is relative to the whole model.
    static func componentExtents(topology t: GlassSelection.Topology,
                                 vertices: [Float], faces: [UInt32],
                                 meshDiagonal: Float) -> (label: [Int], extent: [Float]) {
        var label = [Int](repeating: -1, count: t.faceCount)
        var lo = [SIMD3<Float>](), hi = [SIMD3<Float>]()
        for f in 0 ..< t.faceCount where label[f] < 0 {
            let id = lo.count
            var a = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
            var b = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
            var stack = [f]; label[f] = id
            while let x = stack.popLast() {
                for k in 0 ..< 3 {
                    let i = Int(faces[x*3 + k])
                    let v = SIMD3(vertices[i*3], vertices[i*3+1], vertices[i*3+2])
                    a = simd_min(a, v); b = simd_max(b, v)
                }
                for y in t.neighbours(of: x) where label[y] < 0 { label[y] = id; stack.append(y) }
            }
            lo.append(a); hi.append(b)
        }
        let d = max(meshDiagonal, 1e-9)
        return (label, (0 ..< lo.count).map { simd_length(hi[$0] - lo[$0]) / d })
    }

    /// Everything inside a box drawn on screen, small enough to be debris.
    ///
    /// The size cap does the real work: a hundred specks scattered over a door are impossible to
    /// box without also boxing the door, so the box says *where* and the cap says *what*. A piece
    /// is taken whole once the box touches it, which means the box only has to graze each speck
    /// rather than contain it.
    ///
    /// There is deliberately no depth test — a box catches the far side of the model too. With the
    /// cap set for debris that is harmless, and without it, it is the expected behaviour of a
    /// rubber band.
    static func lasso(rect: CGRect, project: (SIMD3<Float>) -> CGPoint?,
                      topology t: GlassSelection.Topology,
                      vertices: [Float], faces: [UInt32],
                      meshDiagonal: Float, maxFraction: Double) -> [Bool] {
        var out = [Bool](repeating: false, count: t.faceCount)
        let capped = maxFraction < 0.999
        let comp = capped ? componentExtents(topology: t, vertices: vertices, faces: faces,
                                             meshDiagonal: meshDiagonal) : nil
        var touched = Set<Int>()
        for f in 0 ..< t.faceCount {
            var c = SIMD3<Float>.zero
            for k in 0 ..< 3 {
                let i = Int(faces[f*3 + k])
                c += SIMD3(vertices[i*3], vertices[i*3+1], vertices[i*3+2])
            }
            guard let p = project(c / 3), rect.contains(p) else { continue }
            if let comp {
                let id = comp.label[f]
                if comp.extent[id] <= Float(maxFraction) { touched.insert(id) }
            } else {
                out[f] = true
            }
        }
        if let comp, !touched.isEmpty {
            for f in 0 ..< t.faceCount where touched.contains(comp.label[f]) { out[f] = true }
        }
        return out
    }

    /// Straighten a ragged boundary without moving it.
    ///
    /// A crease flood stops per-triangle, and where glass meets its frame there is a bevel — a
    /// ring of triangles at angles between the two surfaces. Some clear the crease threshold and
    /// some do not, so the edge comes out as a sawtooth that follows the triangulation rather
    /// than the shape. Filling by neighbour majority cannot help: a notch triangle usually has
    /// only one marked neighbour.
    ///
    /// Growing `rounds` rings and then shrinking the same number is the standard answer. The
    /// growth swallows the notches; the shrink puts the outer boundary back where it was, since
    /// a straight edge returns to itself while a notch does not.
    static func smoothEdge(_ mask: [Bool], topology t: GlassSelection.Topology,
                           rounds: Int) -> [Bool] {
        guard rounds > 0 else { return mask }
        var m = mask
        // Close removes the notches that bite inwards…
        for _ in 0 ..< rounds { m = grow(m, topology: t) }
        for _ in 0 ..< rounds { m = shrink(m, topology: t) }
        // …and open removes the spikes that stick outwards. A sawtooth has both, so one without
        // the other only straightens half of it.
        for _ in 0 ..< rounds { m = shrink(m, topology: t) }
        for _ in 0 ..< rounds { m = grow(m, topology: t) }
        return m
    }

    /// Add one ring of neighbouring faces.
    static func grow(_ mask: [Bool], topology t: GlassSelection.Topology) -> [Bool] {
        var out = mask
        for f in 0 ..< t.faceCount where mask[f] {
            for n in t.neighbours(of: f) { out[n] = true }
        }
        return out
    }

    /// Remove one ring from the edge.
    static func shrink(_ mask: [Bool], topology t: GlassSelection.Topology) -> [Bool] {
        var out = mask
        for f in 0 ..< t.faceCount where mask[f] {
            if t.neighbours(of: f).contains(where: { !mask[$0] }) { out[f] = false }
        }
        return out
    }

    mutating func add(_ region: [Bool]) {
        for i in 0 ..< min(deleted.count, region.count) where region[i] { deleted[i] = true }
    }

    mutating func remove(_ region: [Bool]) {
        for i in 0 ..< min(deleted.count, region.count) where region[i] { deleted[i] = false }
    }
}
