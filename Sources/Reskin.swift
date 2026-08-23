import Foundation
import simd

/// Build our own mesh around the existing one.
///
/// Every attempt to cut a clean window out of the generated mesh has failed on the same thing:
/// that mesh is a jigsaw. Its winding is inconsistent, a fifth of its vertices are duplicates,
/// its triangles vary wildly in size, and its UV atlas is thousands of scraps. Each of those
/// forced a defensive workaround, and the workarounds are what produced sawtooth, speckle and
/// smear. The shape it describes is fine — it is the description that is a mess.
///
/// So this takes the shape and discards the description. The surface is sampled into a uniform
/// grid, and a new mesh is generated from that grid by surface nets: one vertex per cell that
/// straddles the surface, quads between neighbouring cells. What comes out has consistent
/// winding by construction, near-uniform triangle size, and topology we chose rather than
/// inherited — which is exactly what a clean cut needs.
enum Reskin {

    struct Mesh {
        var vertices: [Float]
        var normals: [Float]
        var faces: [UInt32]
    }

    /// - Parameter resolution: cells across the model's longest axis. 256 keeps a door handle;
    ///   below about 160 the shape starts to soften.
    static func wrap(vertices: [Float], faces: [UInt32], resolution: Int = 256) -> Mesh? {
        let vCount = vertices.count / 3, fCount = faces.count / 3
        guard vCount > 0, fCount > 0 else { return nil }

        var lo = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
        var hi = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
        for i in 0 ..< vCount {
            let p = SIMD3(vertices[i*3], vertices[i*3+1], vertices[i*3+2])
            lo = simd_min(lo, p); hi = simd_max(hi, p)
        }
        let extent = hi - lo
        let cell = extent.max() / Float(resolution)
        let pad = cell * 4
        lo -= pad; hi += pad
        let dim = SIMD3<Int>(Int(((hi.x - lo.x) / cell).rounded(.up)) + 1,
                             Int(((hi.y - lo.y) / cell).rounded(.up)) + 1,
                             Int(((hi.z - lo.z) / cell).rounded(.up)) + 1)
        let total = dim.x * dim.y * dim.z
        guard total > 0, total < 80_000_000 else { return nil }

        // Unsigned distance to the surface, computed only near it — the rest is irrelevant and
        // enormously more expensive.
        let band: Float = cell * 2.5
        var dist = [Float](repeating: .greatestFiniteMagnitude, count: total)
        func idx(_ x: Int, _ y: Int, _ z: Int) -> Int { (z * dim.y + y) * dim.x + x }

        for f in 0 ..< fCount {
            let i0 = Int(faces[f*3]), i1 = Int(faces[f*3+1]), i2 = Int(faces[f*3+2])
            let a = SIMD3(vertices[i0*3], vertices[i0*3+1], vertices[i0*3+2])
            let b = SIMD3(vertices[i1*3], vertices[i1*3+1], vertices[i1*3+2])
            let c = SIMD3(vertices[i2*3], vertices[i2*3+1], vertices[i2*3+2])
            let tlo = simd_min(a, simd_min(b, c)) - band
            let thi = simd_max(a, simd_max(b, c)) + band
            let x0 = max(Int((tlo.x - lo.x) / cell), 0), x1 = min(Int((thi.x - lo.x) / cell) + 1, dim.x - 1)
            let y0 = max(Int((tlo.y - lo.y) / cell), 0), y1 = min(Int((thi.y - lo.y) / cell) + 1, dim.y - 1)
            let z0 = max(Int((tlo.z - lo.z) / cell), 0), z1 = min(Int((thi.z - lo.z) / cell) + 1, dim.z - 1)
            guard x0 <= x1, y0 <= y1, z0 <= z1 else { continue }
            for z in z0 ... z1 {
                for y in y0 ... y1 {
                    for x in x0 ... x1 {
                        let p = lo + SIMD3(Float(x), Float(y), Float(z)) * cell
                        let d = pointTriangle(p, a, b, c)
                        let k = idx(x, y, z)
                        if d < dist[k] { dist[k] = d }
                    }
                }
            }
        }

        // Outside is whatever the air can reach from the corner of the grid without passing
        // through the shell. Doing it this way rather than by surface normals is deliberate: the
        // original's winding cannot be trusted, and air does not care which way a triangle faces.
        // How far outside the real surface the new one sits.
        //
        // An offset surface is not a scaled one: it fattens thin parts more than thick ones in
        // proportion, so features shift relative to the silhouette the sheets were drawn against.
        // A door handle a few millimetres below the window can be pushed into it.
        let skin = cell * (Float(ProcessInfo.processInfo.environment["MODELR_SKIN_OFFSET"] ?? "") ?? 1.2)
        var outside = [Bool](repeating: false, count: total)
        var stack = [idx(0, 0, 0)]
        outside[stack[0]] = true
        while let k = stack.popLast() {
            let x = k % dim.x, y = (k / dim.x) % dim.y, z = k / (dim.x * dim.y)
            for (dx, dy, dz) in [(1,0,0), (-1,0,0), (0,1,0), (0,-1,0), (0,0,1), (0,0,-1)] {
                let nx = x + dx, ny = y + dy, nz = z + dz
                guard nx >= 0, nx < dim.x, ny >= 0, ny < dim.y, nz >= 0, nz < dim.z else { continue }
                let n = idx(nx, ny, nz)
                if !outside[n] && dist[n] > skin { outside[n] = true; stack.append(n) }
            }
        }

        // Surface nets: one vertex per cell straddling the boundary, placed at the average of the
        // crossings on its edges, then quads joining neighbours. Simpler than marching cubes and
        // it yields a smoother, more even surface — which is the whole point here.
        // Distance with a sign: positive in the air, negative in the solid, so a crossing can be
        // located along an edge rather than assumed to be halfway.
        func signed(_ k: Int) -> Float {
            let d = dist[k] == .greatestFiniteMagnitude ? band : dist[k]
            return outside[k] ? (d - skin) : -(skin - min(d, skin))
        }

        var cellVertex = [Int32](repeating: -1, count: total)
        var outV = [Float](), outN = [Float]()
        for z in 0 ..< dim.z - 1 {
            for y in 0 ..< dim.y - 1 {
                for x in 0 ..< dim.x - 1 {
                    var sum = SIMD3<Float>.zero
                    var n = 0
                    let corners = [(0,0,0), (1,0,0), (0,1,0), (1,1,0),
                                   (0,0,1), (1,0,1), (0,1,1), (1,1,1)]
                    let edges = [(0,1), (2,3), (4,5), (6,7), (0,2), (1,3),
                                 (4,6), (5,7), (0,4), (1,5), (2,6), (3,7)]
                    for (ea, eb) in edges {
                        let ca = corners[ea], cb = corners[eb]
                        let ka = idx(x + ca.0, y + ca.1, z + ca.2)
                        let kb = idx(x + cb.0, y + cb.1, z + cb.2)
                        guard outside[ka] != outside[kb] else { continue }
                        // Where along the edge the surface actually lies, from the distances —
                        // not the midpoint. Snapping every crossing to a midpoint quantises the
                        // whole surface to the grid, which is the terracing that made the first
                        // wrap look like a contour map.
                        let da = signed(ka), db = signed(kb)
                        let t = abs(da - db) < 1e-9 ? Float(0.5)
                                                    : min(max(da / (da - db), 0), 1)
                        let pa = SIMD3(Float(x + ca.0), Float(y + ca.1), Float(z + ca.2))
                        let pb = SIMD3(Float(x + cb.0), Float(y + cb.1), Float(z + cb.2))
                        sum += pa + (pb - pa) * t
                        n += 1
                    }
                    guard n > 0 else { continue }
                    let p = lo + (sum / Float(n)) * cell
                    cellVertex[idx(x, y, z)] = Int32(outV.count / 3)
                    outV.append(p.x); outV.append(p.y); outV.append(p.z)
                    outN.append(0); outN.append(0); outN.append(0)
                }
            }
        }
        guard !outV.isEmpty else { return nil }

        var outF = [UInt32]()
        func quad(_ a: Int32, _ b: Int32, _ c: Int32, _ d: Int32, flip: Bool) {
            guard a >= 0, b >= 0, c >= 0, d >= 0 else { return }
            let q: [Int32] = flip ? [a, c, b, a, d, c] : [a, b, c, a, c, d]
            for v in q { outF.append(UInt32(v)) }
        }
        for z in 1 ..< dim.z - 1 {
            for y in 1 ..< dim.y - 1 {
                for x in 1 ..< dim.x - 1 {
                    let k = idx(x, y, z)
                    // One quad per sign-changing edge of the cell, joining the four cells around
                    // that edge. Winding follows the sign, so the result is consistently oriented.
                    if outside[k] != outside[idx(x + 1, y, z)] {
                        quad(cellVertex[k], cellVertex[idx(x, y - 1, z)],
                             cellVertex[idx(x, y - 1, z - 1)], cellVertex[idx(x, y, z - 1)],
                             flip: outside[k])
                    }
                    if outside[k] != outside[idx(x, y + 1, z)] {
                        quad(cellVertex[k], cellVertex[idx(x - 1, y, z)],
                             cellVertex[idx(x - 1, y, z - 1)], cellVertex[idx(x, y, z - 1)],
                             flip: !outside[k])
                    }
                    if outside[k] != outside[idx(x, y, z + 1)] {
                        quad(cellVertex[k], cellVertex[idx(x - 1, y, z)],
                             cellVertex[idx(x - 1, y - 1, z)], cellVertex[idx(x, y - 1, z)],
                             flip: outside[k])
                    }
                }
            }
        }
        guard !outF.isEmpty else { return nil }

        // A little relaxation. On a uniform mesh this is well behaved — every vertex has a
        // similar-sized neighbourhood — and it removes the last of the grid's fingerprint
        // without moving the surface anywhere it matters.
        do {
            var adjacency = [[Int]](repeating: [], count: outV.count / 3)
            for f in 0 ..< (outF.count / 3) {
                let i = Int(outF[f*3]), j = Int(outF[f*3+1]), k = Int(outF[f*3+2])
                adjacency[i].append(j); adjacency[j].append(i)
                adjacency[j].append(k); adjacency[k].append(j)
                adjacency[k].append(i); adjacency[i].append(k)
            }
            for _ in 0 ..< 3 {
                var next = outV
                for v in 0 ..< (outV.count / 3) where !adjacency[v].isEmpty {
                    var s = SIMD3<Float>.zero
                    for u in adjacency[v] { s += SIMD3(outV[u*3], outV[u*3+1], outV[u*3+2]) }
                    s /= Float(adjacency[v].count)
                    let p = SIMD3(outV[v*3], outV[v*3+1], outV[v*3+2])
                    let q = p + (s - p) * 0.5
                    next[v*3] = q.x; next[v*3+1] = q.y; next[v*3+2] = q.z
                }
                outV = next
            }
        }

        // Area-weighted vertex normals, correct by construction now that winding is consistent.
        for f in 0 ..< (outF.count / 3) {
            let i = Int(outF[f*3]), j = Int(outF[f*3+1]), k = Int(outF[f*3+2])
            let a = SIMD3(outV[i*3], outV[i*3+1], outV[i*3+2])
            let b = SIMD3(outV[j*3], outV[j*3+1], outV[j*3+2])
            let c = SIMD3(outV[k*3], outV[k*3+1], outV[k*3+2])
            let n = simd_cross(b - a, c - a)
            for v in [i, j, k] {
                outN[v*3] += n.x; outN[v*3+1] += n.y; outN[v*3+2] += n.z
            }
        }
        for v in 0 ..< (outV.count / 3) {
            let n = SIMD3(outN[v*3], outN[v*3+1], outN[v*3+2])
            let len = simd_length(n)
            let u = len > 1e-12 ? n / len : SIMD3<Float>(0, 1, 0)
            outN[v*3] = u.x; outN[v*3+1] = u.y; outN[v*3+2] = u.z
        }
        // Put the surface back where the original was.
        //
        // The wrap has to be built a little outside the real surface — closer than about one cell
        // and the outside flood leaks through the original's own gaps, leaving a porous lattice
        // instead of a car. But that offset is not a scale: it fattens thin parts more than thick
        // ones, so features drift relative to the silhouette the sheets were drawn against, and a
        // door handle just below a window can drift into it. Sliding each vertex back down its own
        // normal by the same distance undoes the inflation without ever making the flood leak.
        if ProcessInfo.processInfo.environment["MODELR_SKIN_NOSHRINK"] != "1" {
            for v in 0 ..< (outV.count / 3) {
                outV[v*3]     -= outN[v*3]     * skin
                outV[v*3 + 1] -= outN[v*3 + 1] * skin
                outV[v*3 + 2] -= outN[v*3 + 2] * skin
            }
        }
        return Mesh(vertices: outV, normals: outN, faces: outF)
    }

    /// UVs that make the view sheet itself the texture.
    ///
    /// The sheet is already six renders of this object from known cameras, laid out side by side.
    /// So a face needs no unwrapping at all: project it into the view that faces it most directly,
    /// and read off where it lands in that view's tile. The sheet becomes the texture unchanged —
    /// no bake, no atlas packing, and none of the chart fragmentation that made transferring the
    /// original's UVs produce blobs of somewhere else.
    ///
    /// Vertices are split per face because two faces meeting at a corner may be owned by
    /// different views, and each needs its own coordinate in its own tile.
    static func sheetUVs(vertices: [Float], normals: [Float], faces: [UInt32], tiles: Int)
        -> (vertices: [Float], normals: [Float], uvs: [Float], faces: [UInt32], owners: [Int]) {
        // All six views, not the stencil's four.
        //
        // Restricting to the side views is a rule about where *glass* is, and it has no business
        // here: a roof or a bonnet faces up, so no side view sees it, and every one of those
        // faces was landing on the sheet's grey background instead of on the car.
        let views = Array(0 ..< min(tiles, SheetStencil.elevs.count))
        var bases = [(SIMD3<Float>, SIMD3<Float>, SIMD3<Float>, SIMD3<Float>)]()
        for v in views {
            bases.append(SheetStencil.basis(elev: SheetStencil.elevs[v],
                                            azim: SheetStencil.azims[v], dist: 1.45))
        }
        let p = SheetStencil.normalised(vertices)
        let vn = SheetStencil.viewNormals(normals)

        var outV = [Float](), outN = [Float](), outU = [Float](), outF = [UInt32]()
        var owners = [Int]()
        let n = faces.count / 3
        outV.reserveCapacity(n * 9); outU.reserveCapacity(n * 6)
        for f in 0 ..< n {
            let idx = [Int(faces[f*3]), Int(faces[f*3+1]), Int(faces[f*3+2])]
            var nrm = vn[idx[0]] + vn[idx[1]] + vn[idx[2]]
            nrm = simd_length(nrm) > 1e-12 ? simd_normalize(nrm) : SIMD3(0, 0, 1)
            var owner = 0, best = -Float.greatestFiniteMagnitude
            for (k, b) in bases.enumerated() {
                let d = simd_dot(nrm, b.2)
                if d > best { best = d; owner = k }
            }
            let (right, up, _, eye) = bases[owner]
            let tile = views[owner]
            let base = UInt32(outV.count / 3)
            for k in 0 ..< 3 {
                let i = idx[k]
                outV.append(vertices[i*3]); outV.append(vertices[i*3+1]); outV.append(vertices[i*3+2])
                outN.append(normals[i*3]); outN.append(normals[i*3+1]); outN.append(normals[i*3+2])
                let d = p[i] - eye
                let sx = simd_dot(d, right) / 0.6 * 0.5 + 0.5
                let sy = simd_dot(d, up) / 0.6 * 0.5 + 0.5
                // Into this view's tile of the strip. v is flipped because the sheets are stored
                // top-down while the projection measures upwards.
                outU.append((Float(tile) + min(max(sx, 0), 1)) / Float(tiles))
                outU.append(1 - min(max(sy, 0), 1))
                outF.append(base + UInt32(k))
            }
            owners.append(tile)
        }
        return (outV, outN, outU, outF, owners)
    }

    private static func pointTriangle(_ p: SIMD3<Float>, _ a: SIMD3<Float>,
                                      _ b: SIMD3<Float>, _ c: SIMD3<Float>) -> Float {
        let ab = b - a, ac = c - a, ap = p - a
        let d1 = simd_dot(ab, ap), d2 = simd_dot(ac, ap)
        if d1 <= 0 && d2 <= 0 { return simd_length(ap) }
        let bp = p - b
        let d3 = simd_dot(ab, bp), d4 = simd_dot(ac, bp)
        if d3 >= 0 && d4 <= d3 { return simd_length(bp) }
        let vc = d1 * d4 - d3 * d2
        if vc <= 0 && d1 >= 0 && d3 <= 0 {
            let v = d1 / (d1 - d3); return simd_length(ap - ab * v)
        }
        let cp = p - c
        let d5 = simd_dot(ab, cp), d6 = simd_dot(ac, cp)
        if d6 >= 0 && d5 <= d6 { return simd_length(cp) }
        let vb = d5 * d2 - d1 * d6
        if vb <= 0 && d2 >= 0 && d6 <= 0 {
            let w = d2 / (d2 - d6); return simd_length(ap - ac * w)
        }
        let va = d3 * d6 - d5 * d4
        if va <= 0 && (d4 - d3) >= 0 && (d5 - d6) >= 0 {
            let w = (d4 - d3) / ((d4 - d3) + (d5 - d6))
            return simd_length(p - (b + (c - b) * w))
        }
        let denom = 1 / (va + vb + vc)
        let v = vb * denom, w = vc * denom
        return simd_length(p - (a + ab * v + ac * w))
    }
}
