import Foundation
import simd

/// Replace only the windows: cut them out of the original and drop in glass we authored.
///
/// The original mesh is better than anything we can generate everywhere except at a window edge,
/// where its duplicate vertices and uneven triangles shred the cut. So it keeps the whole car and
/// loses only the panes. The replacement panes come from a uniform wrap of the same surface,
/// which cuts cleanly, and they are inset slightly so the body's own aperture edge sits proud of
/// them — the frame overlaps the glass rather than meeting it edge to edge.
///
/// The patch is kept tight to the glass on purpose. It carries UVs sampled from the original
/// surface beneath it, so the paint continues across the join and covers it.
enum GlassPatch {

    struct Result {
        var vertices: [Float]
        var normals: [Float]
        var uvs: [Float]
        var faces: [UInt32]
        var glass: [Bool]
        var apertureFaces: Int
        var panelFaces: Int
        var loops: Int
    }

    static func build(original: (vertices: [Float], normals: [Float], uvs: [Float], faces: [UInt32]),
                      panel: (vertices: [Float], normals: [Float], faces: [UInt32]),
                      panelGlass: [Bool],
                      originalGlass: [Bool],
                      inset: Float) -> Result? {
        let oFaceCount = original.faces.count / 3
        guard originalGlass.count >= oFaceCount else { return nil }

        // Clean the deletion mask before anything is removed. What the original produces is
        // mostly isolated triangles and one-triangle notches rather than a wandering boundary,
        // and both are cheap to remove on the face graph.
        let topo = GlassSelection.topology(vertices: original.vertices, faces: original.faces)
        var mask = Array(originalGlass.prefix(oFaceCount))
        mask = MeshEraser.fillGaps(mask, topology: topo, rounds: 3)
        do {
            var label = [Int](repeating: -1, count: oFaceCount)
            var sizes = [Int]()
            for f in 0 ..< oFaceCount where mask[f] && label[f] < 0 {
                let id = sizes.count
                var stack = [f], n = 0
                label[f] = id
                while let x = stack.popLast() {
                    n += 1
                    for y in topo.neighbours(of: x) where mask[y] && label[y] < 0 {
                        label[y] = id; stack.append(y)
                    }
                }
                sizes.append(n)
            }
            // A window is thousands of faces; anything tiny is a stray.
            for f in 0 ..< oFaceCount where mask[f] && sizes[label[f]] < 200 { mask[f] = false }
        }

        // How many separate rims the aperture leaves — one per window is healthy.
        var loops = 0
        do {
            var boundary = Set<UInt64>()
            let welded = MeshCut.weldMap(vertices: original.vertices)
            var count = [UInt64: Int]()
            for f in 0 ..< oFaceCount where !mask[f] {
                let v = [welded[Int(original.faces[f*3])], welded[Int(original.faces[f*3+1])],
                         welded[Int(original.faces[f*3+2])]]
                for e in 0 ..< 3 {
                    let a = v[e], b = v[(e + 1) % 3]
                    let k = a < b ? UInt64(a) << 32 | UInt64(b) : UInt64(b) << 32 | UInt64(a)
                    count[k, default: 0] += 1
                }
            }
            for (k, c) in count where c == 1 { boundary.insert(k) }
            loops = boundary.count       // reported as boundary edges, not closed loops
        }

        var outV = original.vertices, outN = original.normals, outU = original.uvs
        var outF = [UInt32](), outGlass = [Bool]()
        var kept = 0
        for f in 0 ..< oFaceCount where !mask[f] {
            outF.append(original.faces[f*3]); outF.append(original.faces[f*3+1])
            outF.append(original.faces[f*3+2])
            outGlass.append(false)
            kept += 1
        }

        // The panel, inset along its own normals so the body's rim overlaps it.
        let base = UInt32(outV.count / 3)
        var panelCount = 0
        for i in 0 ..< (panel.vertices.count / 3) {
            let n = SIMD3(panel.normals[i*3], panel.normals[i*3+1], panel.normals[i*3+2])
            let p = SIMD3(panel.vertices[i*3], panel.vertices[i*3+1], panel.vertices[i*3+2]) - n * inset
            outV.append(p.x); outV.append(p.y); outV.append(p.z)
            outN.append(n.x); outN.append(n.y); outN.append(n.z)
            // UVs come from the original surface underneath, so the paint runs across the join.
            let uv = nearestUV(p, original: original)
            outU.append(uv.x); outU.append(uv.y)
        }
        for f in 0 ..< (panel.faces.count / 3) where f < panelGlass.count && panelGlass[f] {
            outF.append(base + panel.faces[f*3]); outF.append(base + panel.faces[f*3+1])
            outF.append(base + panel.faces[f*3+2])
            outGlass.append(true)
            panelCount += 1
        }

        return Result(vertices: outV, normals: outN, uvs: outU, faces: outF, glass: outGlass,
                      apertureFaces: oFaceCount - kept, panelFaces: panelCount, loops: loops)
    }

    /// Re-texture a mesh from the original, one chart per triangle.
    ///
    /// Sampling UVs per vertex looks right and is not: the original atlas is thousands of small
    /// charts, so a new triangle's three vertices routinely land on original triangles belonging
    /// to different charts. The texture then interpolates across a chart boundary and paints a
    /// blob of somewhere else, outlined by the chart's own edge — the whole car came out
    /// speckled with them.
    ///
    /// So each new triangle is given the UVs of ONE original triangle: the closest to its centre.
    /// Its three corners are projected into that triangle's barycentric frame, which keeps all
    /// three UVs inside a single chart. Vertices are split per face, since two faces meeting at a
    /// corner may legitimately want different charts.
    static func retexture(vertices: [Float], normals: [Float], faces: [UInt32],
                          from original: (vertices: [Float], normals: [Float], uvs: [Float],
                                          faces: [UInt32]))
        -> (vertices: [Float], normals: [Float], uvs: [Float], faces: [UInt32], remap: [Int]) {
        let m = original.faces.count / 3
        var lo = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
        var hi = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
        for i in 0 ..< (original.vertices.count / 3) {
            let q = SIMD3(original.vertices[i*3], original.vertices[i*3+1], original.vertices[i*3+2])
            lo = simd_min(lo, q); hi = simd_max(hi, q)
        }
        let cell = max((hi - lo).max() / 192, 1e-5)
        func cellKey(_ p: SIMD3<Float>) -> Int {
            let a = Int(floor(p.x / cell)), b = Int(floor(p.y / cell)), c = Int(floor(p.z / cell))
            return (a &* 73856093) ^ (b &* 19349663) ^ (c &* 83492791)
        }
        var buckets = [Int: [Int]]()
        buckets.reserveCapacity(m)
        for f in 0 ..< m {
            var c = SIMD3<Float>.zero
            for k in 0 ..< 3 {
                let i = Int(original.faces[f*3 + k])
                c += SIMD3(original.vertices[i*3], original.vertices[i*3+1], original.vertices[i*3+2])
            }
            buckets[cellKey(c / 3), default: []].append(f)
        }

        var outV = [Float](), outN = [Float](), outU = [Float](), outF = [UInt32]()
        var remap = [Int]()
        let n = faces.count / 3
        outV.reserveCapacity(n * 9); outU.reserveCapacity(n * 6)
        for f in 0 ..< n {
            let idx = [Int(faces[f*3]), Int(faces[f*3+1]), Int(faces[f*3+2])]
            var centre = SIMD3<Float>.zero
            for i in idx { centre += SIMD3(vertices[i*3], vertices[i*3+1], vertices[i*3+2]) }
            centre /= 3

            // The one original triangle this face will borrow its chart from.
            var best = Float.greatestFiniteMagnitude, bestFace = -1
            var radius = 1
            while radius <= 5 {
                for dx in -radius ... radius {
                    for dy in -radius ... radius {
                        for dz in -radius ... radius {
                            let probe = centre + SIMD3(Float(dx), Float(dy), Float(dz)) * cell
                            for g in buckets[cellKey(probe)] ?? [] {
                                let i0 = Int(original.faces[g*3]), i1 = Int(original.faces[g*3+1])
                                let i2 = Int(original.faces[g*3+2])
                                let a = SIMD3(original.vertices[i0*3], original.vertices[i0*3+1],
                                              original.vertices[i0*3+2])
                                let b = SIMD3(original.vertices[i1*3], original.vertices[i1*3+1],
                                              original.vertices[i1*3+2])
                                let c = SIMD3(original.vertices[i2*3], original.vertices[i2*3+1],
                                              original.vertices[i2*3+2])
                                let (d, _) = closest(centre, a, b, c)
                                if d < best { best = d; bestFace = g }
                            }
                        }
                    }
                }
                if bestFace >= 0 { break }
                radius += 1
            }

            let base = UInt32(outV.count / 3)
            for k in 0 ..< 3 {
                let i = idx[k]
                outV.append(vertices[i*3]); outV.append(vertices[i*3+1]); outV.append(vertices[i*3+2])
                outN.append(normals[i*3]); outN.append(normals[i*3+1]); outN.append(normals[i*3+2])
                var uv = SIMD2<Float>(0, 0)
                if bestFace >= 0 {
                    let j0 = Int(original.faces[bestFace*3]), j1 = Int(original.faces[bestFace*3+1])
                    let j2 = Int(original.faces[bestFace*3+2])
                    let a = SIMD3(original.vertices[j0*3], original.vertices[j0*3+1],
                                  original.vertices[j0*3+2])
                    let b = SIMD3(original.vertices[j1*3], original.vertices[j1*3+1],
                                  original.vertices[j1*3+2])
                    let c = SIMD3(original.vertices[j2*3], original.vertices[j2*3+1],
                                  original.vertices[j2*3+2])
                    let p = SIMD3(vertices[i*3], vertices[i*3+1], vertices[i*3+2])
                    let (_, bary) = closest(p, a, b, c)
                    uv = SIMD2(original.uvs[j0*2], original.uvs[j0*2+1]) * bary.x
                       + SIMD2(original.uvs[j1*2], original.uvs[j1*2+1]) * bary.y
                       + SIMD2(original.uvs[j2*2], original.uvs[j2*2+1]) * bary.z
                }
                outU.append(uv.x); outU.append(uv.y)
                outF.append(base + UInt32(k))
            }
            remap.append(f)
        }
        return (outV, outN, outU, outF, remap)
    }

    /// UVs for a whole mesh, taken from the original surface it sits on.
    ///
    /// Barycentric on the closest triangle, not the nearest centroid: a generated skin lies on
    /// the original surface but its vertices land wherever the grid put them, so anything
    /// coarser than the true closest point smears the paint at that scale.
    static func sampleUVs(points: [Float],
                          from original: (vertices: [Float], normals: [Float], uvs: [Float],
                                          faces: [UInt32])) -> [Float] {
        let m = original.faces.count / 3
        var lo = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
        var hi = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
        for i in 0 ..< (original.vertices.count / 3) {
            let q = SIMD3(original.vertices[i*3], original.vertices[i*3+1], original.vertices[i*3+2])
            lo = simd_min(lo, q); hi = simd_max(hi, q)
        }
        let cell = max((hi - lo).max() / 192, 1e-5)
        func cellKey(_ p: SIMD3<Float>) -> Int {
            let a = Int(floor(p.x / cell)), b = Int(floor(p.y / cell)), c = Int(floor(p.z / cell))
            return (a &* 73856093) ^ (b &* 19349663) ^ (c &* 83492791)
        }
        var buckets = [Int: [Int]]()
        buckets.reserveCapacity(m)
        for f in 0 ..< m {
            var c = SIMD3<Float>.zero
            for k in 0 ..< 3 {
                let i = Int(original.faces[f*3 + k])
                c += SIMD3(original.vertices[i*3], original.vertices[i*3+1], original.vertices[i*3+2])
            }
            buckets[cellKey(c / 3), default: []].append(f)
        }

        var out = [Float](repeating: 0, count: points.count / 3 * 2)
        for v in 0 ..< (points.count / 3) {
            let p = SIMD3(points[v*3], points[v*3+1], points[v*3+2])
            var best = Float.greatestFiniteMagnitude
            var uv = SIMD2<Float>(0, 0)
            var radius = 1
            while radius <= 5 {
                for dx in -radius ... radius {
                    for dy in -radius ... radius {
                        for dz in -radius ... radius {
                            let probe = p + SIMD3(Float(dx), Float(dy), Float(dz)) * cell
                            for f in buckets[cellKey(probe)] ?? [] {
                                let i0 = Int(original.faces[f*3]), i1 = Int(original.faces[f*3+1])
                                let i2 = Int(original.faces[f*3+2])
                                let a = SIMD3(original.vertices[i0*3], original.vertices[i0*3+1],
                                              original.vertices[i0*3+2])
                                let b = SIMD3(original.vertices[i1*3], original.vertices[i1*3+1],
                                              original.vertices[i1*3+2])
                                let c = SIMD3(original.vertices[i2*3], original.vertices[i2*3+1],
                                              original.vertices[i2*3+2])
                                let (d, bary) = closest(p, a, b, c)
                                if d < best {
                                    best = d
                                    uv = SIMD2(original.uvs[i0*2], original.uvs[i0*2+1]) * bary.x
                                       + SIMD2(original.uvs[i1*2], original.uvs[i1*2+1]) * bary.y
                                       + SIMD2(original.uvs[i2*2], original.uvs[i2*2+1]) * bary.z
                                }
                            }
                        }
                    }
                }
                if best < .greatestFiniteMagnitude { break }
                radius += 1
            }
            out[v*2] = uv.x; out[v*2 + 1] = uv.y
        }
        return out
    }

    static func closestPublic(_ p: SIMD3<Float>, _ a: SIMD3<Float>, _ b: SIMD3<Float>,
                              _ c: SIMD3<Float>) -> (Float, SIMD3<Float>) { closest(p, a, b, c) }

    /// Squared distance to a triangle, and the barycentric coordinates of the closest point.
    private static func closest(_ p: SIMD3<Float>, _ a: SIMD3<Float>, _ b: SIMD3<Float>,
                                _ c: SIMD3<Float>) -> (Float, SIMD3<Float>) {
        let ab = b - a, ac = c - a, ap = p - a
        let d1 = simd_dot(ab, ap), d2 = simd_dot(ac, ap)
        if d1 <= 0 && d2 <= 0 { return (simd_length_squared(ap), SIMD3(1, 0, 0)) }
        let bp = p - b
        let d3 = simd_dot(ab, bp), d4 = simd_dot(ac, bp)
        if d3 >= 0 && d4 <= d3 { return (simd_length_squared(bp), SIMD3(0, 1, 0)) }
        let vc = d1 * d4 - d3 * d2
        if vc <= 0 && d1 >= 0 && d3 <= 0 {
            let v = d1 / (d1 - d3)
            return (simd_length_squared(ap - ab * v), SIMD3(1 - v, v, 0))
        }
        let cp = p - c
        let d5 = simd_dot(ab, cp), d6 = simd_dot(ac, cp)
        if d6 >= 0 && d5 <= d6 { return (simd_length_squared(cp), SIMD3(0, 0, 1)) }
        let vb = d5 * d2 - d1 * d6
        if vb <= 0 && d2 >= 0 && d6 <= 0 {
            let w = d2 / (d2 - d6)
            return (simd_length_squared(ap - ac * w), SIMD3(1 - w, 0, w))
        }
        let va = d3 * d6 - d5 * d4
        if va <= 0 && (d4 - d3) >= 0 && (d5 - d6) >= 0 {
            let w = (d4 - d3) / ((d4 - d3) + (d5 - d6))
            return (simd_length_squared(p - (b + (c - b) * w)), SIMD3(0, 1 - w, w))
        }
        let denom = 1 / (va + vb + vc)
        let v = vb * denom, w = vc * denom
        return (simd_length_squared(p - (a + ab * v + ac * w)), SIMD3(1 - v - w, v, w))
    }

    /// UV of the closest point on the original surface — a grid over face centroids keeps this
    /// from being a scan of the whole mesh per vertex.
    private static var grid: [Int: [Int]] = [:]
    private static var gridCell: Float = 0
    private static var gridBuiltFor = 0

    private static func nearestUV(_ p: SIMD3<Float>,
                                  original: (vertices: [Float], normals: [Float], uvs: [Float],
                                             faces: [UInt32])) -> SIMD2<Float> {
        let m = original.faces.count / 3
        if gridBuiltFor != m {
            var lo = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
            var hi = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
            for i in 0 ..< (original.vertices.count / 3) {
                let q = SIMD3(original.vertices[i*3], original.vertices[i*3+1], original.vertices[i*3+2])
                lo = simd_min(lo, q); hi = simd_max(hi, q)
            }
            gridCell = max((hi - lo).max() / 96, 1e-5)
            grid = [:]
            for f in 0 ..< m {
                var c = SIMD3<Float>.zero
                for k in 0 ..< 3 {
                    let i = Int(original.faces[f*3 + k])
                    c += SIMD3(original.vertices[i*3], original.vertices[i*3+1], original.vertices[i*3+2])
                }
                grid[key(c / 3), default: []].append(f)
            }
            gridBuiltFor = m
        }
        var best = Float.greatestFiniteMagnitude
        var uv = SIMD2<Float>(0, 0)
        var radius = 1
        while best == .greatestFiniteMagnitude && radius <= 4 {
            for dx in -radius ... radius {
                for dy in -radius ... radius {
                    for dz in -radius ... radius {
                        let probe = p + SIMD3(Float(dx), Float(dy), Float(dz)) * gridCell
                        for f in grid[key(probe)] ?? [] {
                            var c = SIMD3<Float>.zero
                            var u = SIMD2<Float>.zero
                            for k in 0 ..< 3 {
                                let i = Int(original.faces[f*3 + k])
                                c += SIMD3(original.vertices[i*3], original.vertices[i*3+1],
                                           original.vertices[i*3+2])
                                u += SIMD2(original.uvs[i*2], original.uvs[i*2+1])
                            }
                            let d = simd_length_squared(c / 3 - p)
                            if d < best { best = d; uv = u / 3 }
                        }
                    }
                }
            }
            radius += 1
        }
        return uv
    }

    private static func key(_ p: SIMD3<Float>) -> Int {
        let a = Int(floor(p.x / gridCell)), b = Int(floor(p.y / gridCell)), c = Int(floor(p.z / gridCell))
        return (a &* 73856093) ^ (b &* 19349663) ^ (c &* 83492791)
    }
}
