import Foundation
import simd

/// Deterministic quadric-error-metric (QEM) edge-collapse decimation over the
/// app's binary `.mesh` format (DESIGN.md §4.5 paint prep). This is the pre-engine
/// "Unwrapping" stage's real work: bring a dense shape mesh under a face budget
/// before it's handed to the paint pipeline, whose xatlas UV-unwrap + rasterizer
/// cost scales with triangle count (painting a 240k-vert mesh cost ~238 s, mostly
/// there). The pipeline still unwraps internally — this stage only trims geometry.
///
/// Properties (all covered by MeshDecimatorTests):
/// - **Deterministic**: stable priority ordering (cost, then packed edge key) — the
///   same input always yields byte-identical output. No RNG, no set iteration order.
/// - **Boundary-preserving**: Garland-Heckbert boundary-edge penalty planes pin open
///   edges in place, so an open mesh keeps its silhouette.
/// - **Watertight-preserving**: the manifold link condition gates every collapse, so a
///   closed input stays closed (no holes, no non-manifold fans).
/// - **Safe**: collapses that flip a face normal or degenerate the mesh are rejected;
///   needle/degenerate input never crashes or emits NaNs.
///
/// Pure value logic in Sources/Core — no I/O beyond the explicit file entry point, so
/// the whole algorithm is unit-testable without UI, network, or GPU.
enum MeshDecimator {

    // MARK: - Public API

    struct Stats: Equatable {
        var inputVerts: Int
        var inputFaces: Int
        var outputVerts: Int
        var outputFaces: Int
        var collapses: Int
    }

    /// Outcome of decimating a `.mesh` file. `unchanged` means the mesh was already
    /// at/under budget (no rewrite needed — the caller keeps the original). `fallback`
    /// means decimation ran but produced nothing usable, so the caller should paint the
    /// original mesh (slow but correct, §4.5). `unreadable` is a genuine bad-mesh error.
    enum FileOutcome: Equatable {
        case unchanged(Stats)
        case decimated(Stats)
        case fallback(reason: String)
        case unreadable(String)
    }

    /// Decimate positions+faces to at most `faceBudget` triangles. A no-op copy when
    /// already at/under budget. Never returns NaN positions.
    static func decimate(positions: [SIMD3<Float>], faces: [SIMD3<UInt32>],
                         faceBudget: Int) -> (positions: [SIMD3<Float>], faces: [SIMD3<UInt32>], stats: Stats) {
        let inV = positions.count, inF = faces.count
        guard inF > faceBudget, faceBudget > 0, inV > 0 else {
            return (positions, faces, Stats(inputVerts: inV, inputFaces: inF,
                                            outputVerts: inV, outputFaces: inF, collapses: 0))
        }
        var engine = Engine(positions: positions, faces: faces)
        let collapses = engine.run(faceBudget: faceBudget)
        let (outP, outF) = engine.compact()
        return (outP, outF, Stats(inputVerts: inV, inputFaces: inF,
                                  outputVerts: outP.count, outputFaces: outF.count,
                                  collapses: collapses))
    }

    /// Read a `.mesh` file, decimate to the face budget if it's over, and write the
    /// result to `dst` (recomputing area-weighted normals to match the rest of the app).
    @discardableResult
    static func decimateMeshFile(at src: URL, faceBudget: Int, to dst: URL) -> FileOutcome {
        guard let raw = try? Data(contentsOf: src) else {
            return .unreadable("Couldn't read the shape mesh.")
        }
        guard let mesh = parse(raw) else {
            return .unreadable("The shape mesh is malformed.")
        }
        let stats0 = Stats(inputVerts: mesh.positions.count, inputFaces: mesh.faces.count,
                           outputVerts: mesh.positions.count, outputFaces: mesh.faces.count,
                           collapses: 0)
        guard mesh.faces.count > faceBudget, faceBudget > 0 else {
            return .unchanged(stats0)
        }
        let result = decimate(positions: mesh.positions, faces: mesh.faces, faceBudget: faceBudget)
        // Guard the fallback path: a collapse storm that wiped the mesh, or any
        // non-finite coordinate, means "paint the original instead".
        guard result.faces.count > 0, result.positions.count >= 3,
              result.positions.allSatisfy({ $0.x.isFinite && $0.y.isFinite && $0.z.isFinite }) else {
            return .fallback(reason: "Decimation produced an empty mesh.")
        }
        let out = serialize(positions: result.positions, faces: result.faces)
        do {
            try out.write(to: dst)
        } catch {
            return .fallback(reason: "Couldn't write the decimated mesh.")
        }
        return .decimated(result.stats)
    }

    // MARK: - Binary `.mesh` format
    //   [i32 nV][i32 nF][f32 verts nV*3][f32 normals nV*3][i32 faces nF*3]  (little-endian)

    struct ParsedMesh { var positions: [SIMD3<Float>]; var faces: [SIMD3<UInt32>] }

    static func parse(_ data: Data) -> ParsedMesh? {
        guard data.count >= 8 else { return nil }
        let n = Int(data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 0, as: Int32.self) })
        let m = Int(data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 4, as: Int32.self) })
        guard n > 0, m > 0 else { return nil }
        let vBytes = n * 12, nBytes = n * 12, fBytes = m * 12
        guard data.count >= 8 + vBytes + nBytes + fBytes else { return nil }

        var positions = [SIMD3<Float>](repeating: .zero, count: n)
        var faces = [SIMD3<UInt32>](repeating: .zero, count: m)
        data.withUnsafeBytes { raw in
            for i in 0..<n {
                let o = 8 + i * 12
                positions[i] = SIMD3(raw.loadUnaligned(fromByteOffset: o, as: Float.self),
                                     raw.loadUnaligned(fromByteOffset: o + 4, as: Float.self),
                                     raw.loadUnaligned(fromByteOffset: o + 8, as: Float.self))
            }
            let fo = 8 + vBytes + nBytes
            for f in 0..<m {
                let o = fo + f * 12
                faces[f] = SIMD3(raw.loadUnaligned(fromByteOffset: o, as: UInt32.self),
                                 raw.loadUnaligned(fromByteOffset: o + 4, as: UInt32.self),
                                 raw.loadUnaligned(fromByteOffset: o + 8, as: UInt32.self))
            }
        }
        return ParsedMesh(positions: positions, faces: faces)
    }

    /// Serialize with recomputed area-weighted vertex normals (identical convention to
    /// ShapeMeshWriter/PaintMeshWriter so downstream readers see a consistent mesh).
    static func serialize(positions: [SIMD3<Float>], faces: [SIMD3<UInt32>]) -> Data {
        let n = positions.count, m = faces.count
        var normals = [SIMD3<Float>](repeating: .zero, count: n)
        for f in faces {
            let i0 = Int(f.x), i1 = Int(f.y), i2 = Int(f.z)
            let fn = simd_cross(positions[i1] - positions[i0], positions[i2] - positions[i0])
            normals[i0] += fn; normals[i1] += fn; normals[i2] += fn
        }
        var data = Data()
        data.reserveCapacity(8 + n * 24 + m * 12)
        appendI32(&data, Int32(n)); appendI32(&data, Int32(m))
        for p in positions { appendF(&data, p.x); appendF(&data, p.y); appendF(&data, p.z) }
        for nrm in normals {
            let len = simd_length(nrm)
            let u = len > 1e-12 ? nrm / len : SIMD3<Float>(0, 0, 1)
            appendF(&data, u.x); appendF(&data, u.y); appendF(&data, u.z)
        }
        for f in faces { appendU32(&data, f.x); appendU32(&data, f.y); appendU32(&data, f.z) }
        return data
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

    // MARK: - QEM 4×4 symmetric error quadric

    /// Symmetric 4×4 quadric  [[a,b,c,d],[b,e,f,g],[c,f,h,i],[d,g,i,j]]  stored as its
    /// 10 upper-triangular entries. Error at homogeneous point (x,y,z,1) is vᵀQv.
    struct Quadric {
        var a = 0.0, b = 0.0, c = 0.0, d = 0.0
        var e = 0.0, f = 0.0, g = 0.0
        var h = 0.0, i = 0.0
        var j = 0.0

        /// Fundamental error quadric of the plane n·x + off = 0 (n unit), scaled by w.
        static func plane(_ n: SIMD3<Double>, _ off: Double, weight w: Double = 1) -> Quadric {
            let (x, y, z) = (n.x, n.y, n.z)
            return Quadric(a: w*x*x, b: w*x*y, c: w*x*z, d: w*x*off,
                           e: w*y*y, f: w*y*z, g: w*y*off,
                           h: w*z*z, i: w*z*off,
                           j: w*off*off)
        }

        static func + (l: Quadric, r: Quadric) -> Quadric {
            Quadric(a: l.a+r.a, b: l.b+r.b, c: l.c+r.c, d: l.d+r.d,
                    e: l.e+r.e, f: l.f+r.f, g: l.g+r.g,
                    h: l.h+r.h, i: l.i+r.i, j: l.j+r.j)
        }
        static func += (l: inout Quadric, r: Quadric) { l = l + r }

        func error(_ p: SIMD3<Double>) -> Double {
            let (x, y, z) = (p.x, p.y, p.z)
            return a*x*x + e*y*y + h*z*z + j
                + 2*(b*x*y + c*x*z + f*y*z)
                + 2*(d*x + g*y + i*z)
        }

        /// Position minimizing the quadric (solve the 3×3 top-left block), or nil if
        /// the block is near-singular (flat/degenerate neighborhood → caller falls back).
        func optimum() -> SIMD3<Double>? {
            let m = simd_double3x3(SIMD3(a, b, c), SIMD3(b, e, f), SIMD3(c, f, h))  // columns (symmetric)
            let det = m.determinant
            guard det.isFinite, abs(det) > 1e-12 else { return nil }
            let v = m.inverse * SIMD3(-d, -g, -i)
            guard v.x.isFinite, v.y.isFinite, v.z.isFinite else { return nil }
            return v
        }
    }

    // MARK: - Decimation engine (mutable working state)

    private struct Engine {
        var pos: [SIMD3<Double>]
        var vAlive: [Bool]
        var quad: [Quadric]
        /// vertex → incident face indices (into `face`), pruned as faces die.
        var vFaces: [Set<Int>]
        var face: [SIMD3<Int>]
        var fAlive: [Bool]
        var aliveFaces: Int

        /// Lazy-deletion heap: entries carry a version; a pop is stale if the edge's
        /// current version moved on. Determinism comes entirely from the comparator.
        var heap: [HeapEntry] = []
        var edgeVersion: [UInt64: Int] = [:]

        struct HeapEntry {
            var cost: Double
            var key: UInt64      // packed (min<<32 | max), also the tie-break
            var u: Int
            var v: Int
            var version: Int
            /// The collapse target, precomputed so the pop path stays cheap.
            var target: SIMD3<Double>
        }

        init(positions: [SIMD3<Float>], faces: [SIMD3<UInt32>]) {
            pos = positions.map { SIMD3(Double($0.x), Double($0.y), Double($0.z)) }
            vAlive = [Bool](repeating: true, count: positions.count)
            quad = [Quadric](repeating: Quadric(), count: positions.count)
            vFaces = [Set<Int>](repeating: [], count: positions.count)
            face = faces.map { SIMD3(Int($0.x), Int($0.y), Int($0.z)) }
            fAlive = [Bool](repeating: true, count: faces.count)
            aliveFaces = faces.count
            build()
        }

        // MARK: build initial quadrics + adjacency

        mutating func build() {
            // Per-face plane quadric → accumulate onto its 3 vertices; record adjacency.
            var boundaryCount: [UInt64: Int] = [:]
            var boundaryFace: [UInt64: Int] = [:]
            for (fi, f) in face.enumerated() {
                let (i0, i1, i2) = (f.x, f.y, f.z)
                // drop degenerate faces (repeated index) up front
                if i0 == i1 || i1 == i2 || i0 == i2 {
                    fAlive[fi] = false; aliveFaces -= 1; continue
                }
                vFaces[i0].insert(fi); vFaces[i1].insert(fi); vFaces[i2].insert(fi)
                let n = faceNormalRaw(i0, i1, i2)
                let len = simd_length(n)
                if len > 1e-18 {
                    let un = n / len
                    let off = -simd_dot(un, pos[i0])
                    // area-weight (|n| = 2·area) so large faces dominate, standard QEM.
                    let q = Quadric.plane(un, off, weight: len)
                    quad[i0] += q; quad[i1] += q; quad[i2] += q
                }
                for e in [edgeKey(i0, i1), edgeKey(i1, i2), edgeKey(i2, i0)] {
                    boundaryCount[e, default: 0] += 1
                    boundaryFace[e] = fi
                }
            }
            // Garland-Heckbert boundary constraint: pin edges used by a single face.
            // Sorted keys (not raw dict order) so accumulation order — and thus the
            // floating-point result — is identical across runs on open meshes too.
            for key in boundaryCount.keys.sorted() where boundaryCount[key] == 1 {
                let (u, v) = unpack(key)
                guard let fi = boundaryFace[key] else { continue }
                let fn = faceNormalRaw(face[fi].x, face[fi].y, face[fi].z)
                let flen = simd_length(fn)
                guard flen > 1e-18 else { continue }
                let edge = pos[v] - pos[u]
                let perp = simd_cross(edge, fn / flen)     // in-face, ⟂ to the boundary edge
                let plen = simd_length(perp)
                guard plen > 1e-18 else { continue }
                let n = perp / plen
                let off = -simd_dot(n, pos[u])
                let w = 1e3 * simd_length_squared(edge)     // heavy: boundaries barely move
                let q = Quadric.plane(n, off, weight: w)
                quad[u] += q; quad[v] += q
            }
            // Seed the heap with every surviving edge.
            for (fi, f) in face.enumerated() where fAlive[fi] {
                pushEdge(f.x, f.y); pushEdge(f.y, f.z); pushEdge(f.z, f.x)
            }
        }

        func faceNormalRaw(_ i0: Int, _ i1: Int, _ i2: Int) -> SIMD3<Double> {
            simd_cross(pos[i1] - pos[i0], pos[i2] - pos[i0])
        }

        // MARK: edge cost + heap

        /// Compute the collapse target + cost for edge (u,v) and (re)insert it. A new
        /// version invalidates any older heap entry for the same edge.
        mutating func pushEdge(_ ua: Int, _ va: Int) {
            let key = edgeKey(ua, va)
            let (u, v) = unpack(key)
            let q = quad[u] + quad[v]
            let mid = (pos[u] + pos[v]) * 0.5
            let target = q.optimum() ?? mid
            let cost = max(0, q.error(target))
            let version = (edgeVersion[key] ?? 0) + 1
            edgeVersion[key] = version
            heapPush(HeapEntry(cost: cost, key: key, u: u, v: v, version: version, target: target))
        }

        mutating func run(faceBudget: Int) -> Int {
            var collapses = 0
            while aliveFaces > faceBudget, !heap.isEmpty {
                let entry = heapPop()
                // stale (superseded version), or an endpoint already died?
                guard edgeVersion[entry.key] == entry.version,
                      vAlive[entry.u], vAlive[entry.v] else { continue }
                // Versions are monotonic and never reset — a rejected edge keeps its
                // version (no heap entry) and re-enters when a nearby collapse changes
                // its neighborhood (pushEdge bumps the version). Resetting to nil here
                // could resurrect an older, staler heap entry for the same key.
                if collapse(u: entry.u, v: entry.v, preferred: entry.target) { collapses += 1 }
            }
            return collapses
        }

        // MARK: the collapse

        /// Try to merge v into u at a safe position. Returns false (no-op) if every
        /// candidate target flips a normal or the collapse would break manifoldness.
        mutating func collapse(u: Int, v: Int, preferred: SIMD3<Double>) -> Bool {
            // Faces shared by the edge (the ones removed by the collapse).
            let shared = vFaces[u].intersection(vFaces[v])
            // Manifold link condition: the vertices opposite the edge must be exactly
            // the vertices adjacent to BOTH u and v. Otherwise the collapse folds the
            // surface onto itself (non-manifold fan) — reject.
            let opposite = shared.reduce(into: Set<Int>()) { acc, fi in
                for w in [face[fi].x, face[fi].y, face[fi].z] where w != u && w != v { acc.insert(w) }
            }
            if neighbors(u).intersection(neighbors(v)) != opposite { return false }
            // Boundary rule: an interior edge whose two endpoints are both on the
            // boundary would pinch the surface — reject (link check misses this case).
            if shared.count == 2, isBoundaryVertex(u), isBoundaryVertex(v) { return false }

            // Pick the first candidate target that flips no incident face normal.
            let mid = (pos[u] + pos[v]) * 0.5
            let candidates = [preferred, mid, pos[u], pos[v]]
            guard let target = candidates.first(where: { t in
                t.x.isFinite && t.y.isFinite && t.z.isFinite && !wouldFlip(u: u, v: v, to: t, shared: shared)
            }) else { return false }

            // Commit: move u, merge quadrics, rewrite v's faces onto u, kill shared faces.
            // Dead faces are removed from EVERY incident vertex's adjacency (u and v
            // below, but also the opposite vertices) — a lingering dead face corrupts
            // neighbors()/isBoundaryVertex() and stalls decimation far above budget.
            pos[u] = target
            quad[u] = quad[u] + quad[v]
            for fi in shared {
                fAlive[fi] = false
                let f = face[fi]
                for w in [f.x, f.y, f.z] { vFaces[w].remove(fi) }
            }
            aliveFaces -= shared.count

            var newU = vFaces[u]
            newU.subtract(shared)
            for fi in vFaces[v] where !shared.contains(fi) {
                var f = face[fi]
                if f.x == v { f.x = u }; if f.y == v { f.y = u }; if f.z == v { f.z = u }
                face[fi] = f
                newU.insert(fi)
            }
            vFaces[u] = newU
            vFaces[v] = []
            vAlive[v] = false

            // Prune u's adjacency of any face that went degenerate, then refresh the
            // costs of every edge now incident to u.
            for fi in Array(vFaces[u]) {
                let f = face[fi]
                if f.x == f.y || f.y == f.z || f.x == f.z {
                    fAlive[fi] = false; aliveFaces -= 1
                    vFaces[u].remove(fi)
                    for w in [f.x, f.y, f.z] where w != u { vFaces[w].remove(fi) }
                }
            }
            for w in neighbors(u) { pushEdge(u, w) }
            return true
        }

        /// Any incident face (not one of the removed shared faces) whose normal would
        /// invert if the merged vertex sat at `to`.
        func wouldFlip(u: Int, v: Int, to: SIMD3<Double>, shared: Set<Int>) -> Bool {
            for src in [u, v] {
                for fi in vFaces[src] where !shared.contains(fi) {
                    let f = face[fi]
                    let p0 = (f.x == u || f.x == v) ? to : pos[f.x]
                    let p1 = (f.y == u || f.y == v) ? to : pos[f.y]
                    let p2 = (f.z == u || f.z == v) ? to : pos[f.z]
                    let before = faceNormalRaw(f.x, f.y, f.z)
                    let after = simd_cross(p1 - p0, p2 - p0)
                    let bl = simd_length(before), al = simd_length(after)
                    if al < 1e-18 { return true }                    // collapsed to a sliver
                    if bl > 1e-18, simd_dot(before / bl, after / al) < 0.1 { return true }
                }
            }
            return false
        }

        func neighbors(_ u: Int) -> Set<Int> {
            var s = Set<Int>()
            for fi in vFaces[u] {
                let f = face[fi]
                for w in [f.x, f.y, f.z] where w != u { s.insert(w) }
            }
            return s
        }

        /// A vertex is on the boundary if one of its edges is used by a single face.
        func isBoundaryVertex(_ u: Int) -> Bool {
            var edgeFaceCount: [Int: Int] = [:]
            for fi in vFaces[u] {
                let f = face[fi]
                for w in [f.x, f.y, f.z] where w != u { edgeFaceCount[w, default: 0] += 1 }
            }
            return edgeFaceCount.values.contains { $0 == 1 }
        }

        // MARK: finalize

        /// Drop dead vertices/faces and reindex compactly.
        func compact() -> (positions: [SIMD3<Float>], faces: [SIMD3<UInt32>]) {
            var remap = [Int](repeating: -1, count: pos.count)
            var outPos: [SIMD3<Float>] = []
            outPos.reserveCapacity(pos.count)
            var outFaces: [SIMD3<UInt32>] = []
            outFaces.reserveCapacity(aliveFaces)
            for (fi, alive) in fAlive.enumerated() where alive {
                let f = face[fi]
                if f.x == f.y || f.y == f.z || f.x == f.z { continue }
                var out = SIMD3<UInt32>()
                for (k, idx) in [f.x, f.y, f.z].enumerated() {
                    if remap[idx] == -1 {
                        remap[idx] = outPos.count
                        outPos.append(SIMD3(Float(pos[idx].x), Float(pos[idx].y), Float(pos[idx].z)))
                    }
                    out[k] = UInt32(remap[idx])
                }
                outFaces.append(out)
            }
            return (outPos, outFaces)
        }

        // MARK: binary min-heap (comparator = (cost, key) → total, deterministic order)

        mutating func heapPush(_ e: HeapEntry) {
            heap.append(e)
            var i = heap.count - 1
            while i > 0 {
                let parent = (i - 1) / 2
                if less(heap[i], heap[parent]) { heap.swapAt(i, parent); i = parent } else { break }
            }
        }

        mutating func heapPop() -> HeapEntry {
            let top = heap[0]
            let last = heap.removeLast()
            if !heap.isEmpty {
                heap[0] = last
                var i = 0
                let count = heap.count
                while true {
                    let l = 2*i + 1, r = 2*i + 2
                    var m = i
                    if l < count, less(heap[l], heap[m]) { m = l }
                    if r < count, less(heap[r], heap[m]) { m = r }
                    if m == i { break }
                    heap.swapAt(i, m); i = m
                }
            }
            return top
        }

        func less(_ a: HeapEntry, _ b: HeapEntry) -> Bool {
            a.cost != b.cost ? a.cost < b.cost : a.key < b.key
        }
    }
}

// MARK: - packed undirected edge key (free functions: used by the nested Engine)

private func edgeKey(_ a: Int, _ b: Int) -> UInt64 {
    let lo = UInt64(min(a, b)), hi = UInt64(max(a, b))
    return (lo << 32) | hi
}
private func unpack(_ key: UInt64) -> (Int, Int) {
    (Int(key >> 32), Int(key & 0xFFFF_FFFF))
}
