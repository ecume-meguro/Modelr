import Foundation
import simd

/// Cut the mesh along the painted curve itself, in the view where it was painted.
///
/// Every previous attempt turned the stencil into a number per vertex and then looked for where
/// that number crossed zero. That makes the boundary a property of the mesh: it can only bend
/// where a vertex happens to be, and it inherits every flicker in how those vertices were
/// sampled. The stencil's own edge is smooth and known to sub-texel precision — the mesh is the
/// only thing that was ever jagged.
///
/// So the curve does the cutting. The stencil's contour is traced once, in 2D, at sub-texel
/// precision. Each triangle that the curve crosses is split *along the curve*, with the new
/// vertices placed exactly where the curve enters and leaves it. The boundary is then the painted
/// curve by construction, at whatever resolution it was drawn, no matter how coarse the triangle
/// it lands in.
enum MeshClip {

    /// A closed contour in one view's pixel space.
    typealias Contour = [SIMD2<Float>]

    /// Trace the stencil's edges with marching squares, interpolating each crossing.
    ///
    /// The interpolation is what buys sub-texel precision: a crossing is placed proportionally
    /// between the two texel centres by their distance values, rather than at a texel corner,
    /// so the traced curve is smooth even where the stencil is only a few hundred texels across.
    static func trace(_ sdf: [Float], w: Int, h: Int) -> [Contour] {
        // Segments first, keyed by their endpoints, then chained into contours.
        var segments = [(SIMD2<Float>, SIMD2<Float>)]()
        func lerp(_ x0: Int, _ y0: Int, _ x1: Int, _ y1: Int) -> SIMD2<Float> {
            let a = sdf[y0 * w + x0], b = sdf[y1 * w + x1]
            let t = abs(a - b) < 1e-9 ? 0.5 : a / (a - b)
            return SIMD2(Float(x0) + (Float(x1) - Float(x0)) * t,
                         Float(y0) + (Float(y1) - Float(y0)) * t)
        }
        for y in 0 ..< (h - 1) {
            for x in 0 ..< (w - 1) {
                let s00 = sdf[y * w + x] >= 0, s10 = sdf[y * w + x + 1] >= 0
                let s01 = sdf[(y + 1) * w + x] >= 0, s11 = sdf[(y + 1) * w + x + 1] >= 0
                let code = (s00 ? 1 : 0) | (s10 ? 2 : 0) | (s11 ? 4 : 0) | (s01 ? 8 : 0)
                if code == 0 || code == 15 { continue }
                let top = lerp(x, y, x + 1, y)
                let right = lerp(x + 1, y, x + 1, y + 1)
                let bottom = lerp(x, y + 1, x + 1, y + 1)
                let left = lerp(x, y, x, y + 1)
                switch code {
                case 1, 14:  segments.append((left, top))
                case 2, 13:  segments.append((top, right))
                case 3, 12:  segments.append((left, right))
                case 4, 11:  segments.append((right, bottom))
                case 5:      segments.append((left, top)); segments.append((right, bottom))
                case 6, 9:   segments.append((top, bottom))
                case 7, 8:   segments.append((left, bottom))
                case 10:     segments.append((left, bottom)); segments.append((top, right))
                default:     break
                }
            }
        }
        guard !segments.isEmpty else { return [] }

        // Chain segments into polylines by snapping endpoints to a fine grid.
        let snap: Float = 100
        func key(_ p: SIMD2<Float>) -> Int64 {
            Int64((p.x * snap).rounded()) << 32 | Int64(UInt32(bitPattern: Int32((p.y * snap).rounded())))
        }
        var starts = [Int64: [Int]]()
        for (i, s) in segments.enumerated() { starts[key(s.0), default: []].append(i) }
        var used = [Bool](repeating: false, count: segments.count)
        var out = [Contour]()
        for i in 0 ..< segments.count where !used[i] {
            var poly: Contour = [segments[i].0, segments[i].1]
            used[i] = true
            var tip = segments[i].1
            while true {
                guard let candidates = starts[key(tip)] else { break }
                var advanced = false
                for j in candidates where !used[j] {
                    used[j] = true
                    poly.append(segments[j].1)
                    tip = segments[j].1
                    advanced = true
                    break
                }
                if !advanced { break }
                if simd_length(tip - poly[0]) < 0.01 { break }        // closed
            }
            if poly.count > 3 { out.append(poly) }
        }
        return out
    }

    /// Contour segments bucketed by pixel cell.
    ///
    /// A traced contour runs to tens of thousands of segments, and every triangle edge would
    /// otherwise be tested against all of them — hundreds of millions of tests per view. Each
    /// edge only ever crosses segments near itself.
    struct Index {
        let cell: Float
        let buckets: [Int64: [Int]]
        let segments: [(SIMD2<Float>, SIMD2<Float>)]

        init(_ contours: [Contour], cell: Float = 8) {
            var segs = [(SIMD2<Float>, SIMD2<Float>)]()
            for c in contours {
                var j = c.count - 1
                for i in 0 ..< c.count { segs.append((c[j], c[i])); j = i }
            }
            var b = [Int64: [Int]]()
            func key(_ x: Int, _ y: Int) -> Int64 { Int64(x) << 32 | Int64(UInt32(bitPattern: Int32(y))) }
            for (i, s) in segs.enumerated() {
                let x0 = Int(min(s.0.x, s.1.x) / cell), x1 = Int(max(s.0.x, s.1.x) / cell)
                let y0 = Int(min(s.0.y, s.1.y) / cell), y1 = Int(max(s.0.y, s.1.y) / cell)
                for y in y0 ... y1 { for x in x0 ... x1 { b[key(x, y), default: []].append(i) } }
            }
            self.cell = cell; self.buckets = b; self.segments = segs
        }

        func near(_ a: SIMD2<Float>, _ b: SIMD2<Float>) -> [Int] {
            func key(_ x: Int, _ y: Int) -> Int64 { Int64(x) << 32 | Int64(UInt32(bitPattern: Int32(y))) }
            let x0 = Int(min(a.x, b.x) / cell) - 1, x1 = Int(max(a.x, b.x) / cell) + 1
            let y0 = Int(min(a.y, b.y) / cell) - 1, y1 = Int(max(a.y, b.y) / cell) + 1
            var out = Set<Int>()
            for y in y0 ... y1 { for x in x0 ... x1 {
                if let list = buckets[key(x, y)] { out.formUnion(list) }
            }}
            return Array(out)
        }
    }

    /// Is this point inside the stencil, by the traced curve rather than by texels?
    static func inside(_ p: SIMD2<Float>, _ contours: [Contour]) -> Bool {
        var crossings = 0
        for c in contours {
            var j = c.count - 1
            for i in 0 ..< c.count {
                let a = c[j], b = c[i]
                if (a.y > p.y) != (b.y > p.y) {
                    let t = (p.y - a.y) / (b.y - a.y)
                    if a.x + t * (b.x - a.x) > p.x { crossings += 1 }
                }
                j = i
            }
        }
        return crossings % 2 == 1
    }

    /// Faces the curve crosses in a way a single split cannot express.
    ///
    /// These have to be subdivided *before* cutting, and conformingly — every neighbour sharing
    /// a split edge must split too. Subdividing a triangle on its own leaves a vertex sitting in
    /// the middle of a neighbour's edge: a T-junction, which is both a hairline crack and, worse
    /// here, a lost adjacency. The flood that decides which faces are glass walks that adjacency,
    /// so a T-junction is a hole in the fence.
    static func complexFaces(vertices: [Float], faces: [UInt32],
                             right: SIMD3<Float>, up: SIMD3<Float>, eye: SIMD3<Float>,
                             tile: Int, index: Index, position: [SIMD3<Float>]) -> [Bool] {
        let n = vertices.count / 3, m = faces.count / 3
        var p2 = [SIMD2<Float>](repeating: .zero, count: n)
        for i in 0 ..< n {
            let d = position[i] - eye
            p2[i] = SIMD2((simd_dot(d, right) / 0.6 * 0.5 + 0.5) * Float(tile - 1),
                          (simd_dot(d, up) / 0.6 * 0.5 + 0.5) * Float(tile - 1))
        }
        var out = [Bool](repeating: false, count: m)
        for f in 0 ..< m {
            let a = p2[Int(faces[f*3])], b = p2[Int(faces[f*3+1])], c = p2[Int(faces[f*3+2])]
            let t01 = crossings(a, b, index).count
            let t12 = crossings(b, c, index).count
            let t20 = crossings(c, a, index).count
            let total = t01 + t12 + t20
            if total > 0 && !(total == 2 && t01 <= 1 && t12 <= 1 && t20 <= 1) { out[f] = true }
        }
        return out
    }

    /// Split every triangle the curve crosses, along the curve.
    ///
    /// The visibility and facing tests here are allowed to be hard yes/no answers, which is the
    /// difference from every earlier attempt. They decide only *which triangles take part*; they
    /// no longer influence *where the boundary lies*, because that comes from the traced curve.
    /// A gate that flickers between neighbouring triangles used to move the boundary and serrate
    /// it — now it can at worst include or exclude a whole triangle that the curve then cuts
    /// identically either way.
    static func cut(vertices: [Float], normals: [Float], uvs: [Float], faces: [UInt32],
                    right: SIMD3<Float>, up: SIMD3<Float>, fwd: SIMD3<Float>, eye: SIMD3<Float>,
                    tile: Int, index: Index, sdf: [Float], position: [SIMD3<Float>],
                    facing normalsInView: [SIMD3<Float>])
        -> (vertices: [Float], normals: [Float], uvs: [Float], faces: [UInt32],
            inside: [Bool], parent: [Int], onCurve: [Bool]) {
        let n = vertices.count / 3, m = faces.count / 3
        var px = [SIMD3<Float>](repeating: .zero, count: n)
        for i in 0 ..< n {
            let d = position[i] - eye
            px[i] = SIMD3((simd_dot(d, right) / 0.6 * 0.5 + 0.5) * Float(tile - 1),
                          (simd_dot(d, up) / 0.6 * 0.5 + 0.5) * Float(tile - 1),
                          simd_dot(d, fwd))
        }
        var depth = [Float](repeating: -.greatestFiniteMagnitude, count: tile * tile)
        rasterise(px, faces: faces, w: tile, h: tile, into: &depth)

        var outV = vertices, outN = normals, outU = uvs
        var outF = [UInt32](), outInside = [Bool](), outParent = [Int]()
        outF.reserveCapacity(faces.count)
        let debug = ProcessInfo.processInfo.environment["MODELR_CLIP_DEBUG"] == "1"
        var statFacing = 0, statVisible = 0, statBoth = 0, statInsideStencil = 0
        var statBackstop = 0, statSimple = 0, statUntouched = 0

        func side(_ p: SIMD2<Float>) -> Bool {
            let cx = min(max(p.x, 0), Float(tile - 1)), cy = min(max(p.y, 0), Float(tile - 1))
            let x0 = Int(cx), y0 = Int(cy)
            let x1 = min(x0 + 1, tile - 1), y1 = min(y0 + 1, tile - 1)
            let fx = cx - Float(x0), fy = cy - Float(y0)
            let a = sdf[y0 * tile + x0] * (1 - fx) + sdf[y0 * tile + x1] * fx
            let b = sdf[y1 * tile + x0] * (1 - fx) + sdf[y1 * tile + x1] * fx
            return a * (1 - fy) + b * fy > 0
        }

        // Vertices are addressed by barycentric coordinate within their parent triangle, so a
        // point on a shared edge resolves to the same coordinate from both sides and the two
        // triangles agree on it. Keyed on the raw corner indices, since triangles across a UV
        // seam hold different UVs for the same corner and must keep their own copies.
        var made = [String: UInt32]()
        func vertex(_ f: Int, _ bary: SIMD3<Float>) -> UInt32 {
            let i0 = Int(faces[f*3]), i1 = Int(faces[f*3+1]), i2 = Int(faces[f*3+2])
            if bary.x > 0.9999 { return UInt32(i0) }
            if bary.y > 0.9999 { return UInt32(i1) }
            if bary.z > 0.9999 { return UInt32(i2) }
            // On an edge, key by the two corner indices and the position along it, so the
            // neighbouring triangle produces the same key and the mesh stays watertight.
            let key: String
            if bary.z < 1e-6 { key = edgeKey(i0, i1, bary.y) }
            else if bary.x < 1e-6 { key = edgeKey(i1, i2, bary.z) }
            else if bary.y < 1e-6 { key = edgeKey(i2, i0, bary.x) }
            else { key = "f\(f):\(Int(bary.x * 4096)):\(Int(bary.y * 4096))" }
            if let v = made[key] { return v }
            let idx = UInt32(outV.count / 3)
            for k in 0 ..< 3 {
                outV.append(vertices[i0*3 + k] * bary.x + vertices[i1*3 + k] * bary.y
                          + vertices[i2*3 + k] * bary.z)
                outN.append(normals[i0*3 + k] * bary.x + normals[i1*3 + k] * bary.y
                          + normals[i2*3 + k] * bary.z)
            }
            for k in 0 ..< 2 {
                outU.append(uvs[i0*2 + k] * bary.x + uvs[i1*2 + k] * bary.y
                          + uvs[i2*2 + k] * bary.z)
            }
            made[key] = idx
            return idx
        }
        func edgeKey(_ a: Int, _ b: Int, _ t: Float) -> String {
            let (i, j, u) = a < b ? (a, b, t) : (b, a, 1 - t)
            return "e\(i):\(j):\(Int(u * 65536))"
        }
        // Which vertices sit on the curve.
        //
        // The wall was previously a set of vertex *pairs*, and a later view splitting one of
        // those edges left the pair naming an edge that no longer exists — the fence silently
        // lost that stretch, and the growth escaped through the gap. Marking the endpoints
        // instead survives every later split: an edge is a wall whenever both its ends are on
        // the curve, and splitting a wall edge produces two edges whose new midpoint is on the
        // curve as well.
        var onCurve = [Bool](repeating: false, count: vertices.count / 3)
        func markCut(_ a: UInt32, _ b: UInt32) {
            for v in [a, b] {
                let i = Int(v)
                if i >= onCurve.count { onCurve.append(contentsOf:
                    [Bool](repeating: false, count: i - onCurve.count + 1)) }
                onCurve[i] = true
            }
        }
        func emit(_ a: UInt32, _ b: UInt32, _ c: UInt32, _ glass: Bool, _ parent: Int) {
            guard a != b, b != c, a != c else { return }
            outF.append(a); outF.append(b); outF.append(c)
            outInside.append(glass); outParent.append(parent)
        }

        for f in 0 ..< m {
            let i0 = Int(faces[f*3]), i1 = Int(faces[f*3+1]), i2 = Int(faces[f*3+2])
            let a = SIMD2(px[i0].x, px[i0].y), b = SIMD2(px[i1].x, px[i1].y)
            let c = SIMD2(px[i2].x, px[i2].y)

            // Facing comes from the mesh's own vertex normals, never from the winding order.
            //
            // These shells are not consistently wound — the renderer already draws them
            // double-sided for that reason — so a cross-product normal points inward for an
            // arbitrary subset of triangles, and the facing test then accepts a scattered half
            // of every window while rejecting a scattered half of the frame beside it.
            var nrm = normalsInView[i0] + normalsInView[i1] + normalsInView[i2]
            nrm = simd_length(nrm) > 1e-12 ? simd_normalize(nrm) : SIMD3(0, 0, 1)
            // Note the sign. The map into the bake's space, (x, y, z) -> (-x, z, -y), has
            // determinant -1 — it is a reflection — so a normal carried through it ends up on
            // the wrong side of its own surface. Verified rather than reasoned: with the other
            // sign, "faces the camera" and "is not hidden" shared 2,895 faces out of 37,303,
            // which no solid object can do; with this one they share 28,423 of 47,102.
            let bar = Float(ProcessInfo.processInfo.environment["MODELR_CLIP_FACE"] ?? "") ?? 0.1
            let towardsCamera = simd_dot(nrm, fwd) < -bar
            let z = (px[i0].z + px[i1].z + px[i2].z) / 3
            let centre2 = (a + b + c) / 3
            let sx = min(max(Int(centre2.x.rounded()), 0), tile - 1)
            let sy = min(max(Int(centre2.y.rounded()), 0), tile - 1)
            let tol = Float(ProcessInfo.processInfo.environment["MODELR_CLIP_TOL"] ?? "") ?? 0.02
            let visible = z >= depth[sy * tile + sx] - tol
            if debug {
                if towardsCamera { statFacing += 1 }
                if visible { statVisible += 1 }
                if towardsCamera && visible { statBoth += 1 }
                if side(centre2) { statInsideStencil += 1 }
            }
            guard towardsCamera, visible else {
                emit(UInt32(i0), UInt32(i1), UInt32(i2), false, f); continue
            }

            /// Cut one (sub)triangle, given its corners in barycentric coordinates of `f`.
            ///
            /// Where the curve enters and leaves once, split there and stop. Where it does
            /// something more involved — a window corner, the tight radius at a pillar base —
            /// quarter the triangle and look again. Classifying such a triangle whole was what
            /// left single wrong triangles scattered along an otherwise clean edge.
            func carve(_ b0: SIMD3<Float>, _ b1: SIMD3<Float>, _ b2: SIMD3<Float>, _ depth: Int) {
                func at(_ bary: SIMD3<Float>) -> SIMD2<Float> {
                    SIMD2(a.x * bary.x + b.x * bary.y + c.x * bary.z,
                          a.y * bary.x + b.y * bary.y + c.y * bary.z)
                }
                let p0 = at(b0), p1 = at(b1), p2 = at(b2)
                let t01 = crossings(p0, p1, index)
                let t12 = crossings(p1, p2, index)
                let t20 = crossings(p2, p0, index)
                let total = t01.count + t12.count + t20.count
                if total == 0 { statUntouched += 1 }
                if total == 0 {
                    // Deliberately not classified. A triangle the curve does not touch is
                    // decided later, by growing outwards from the cut, and only if it can be
                    // reached without crossing the curve. Classifying it here — by whether its
                    // centre happens to project inside the window outline — is what swept in the
                    // far side of the car, the interior and anything else standing behind a
                    // window in that view.
                    emit(vertex(f, b0), vertex(f, b1), vertex(f, b2), false, f)
                    return
                }
                let simple = t01.count + t12.count + t20.count == 2
                    && t01.count <= 1 && t12.count <= 1 && t20.count <= 1
                if simple { statSimple += 1 }
                if simple {
                    // Rotate so the lone corner is first.
                    let (q0, q1, q2, tA, tB): (SIMD3<Float>, SIMD3<Float>, SIMD3<Float>, Float, Float)
                    if t01.count == 1 && t20.count == 1 { (q0, q1, q2, tA, tB) = (b0, b1, b2, t01[0], 1 - t20[0]) }
                    else if t01.count == 1 && t12.count == 1 { (q0, q1, q2, tA, tB) = (b1, b2, b0, t12[0], 1 - t01[0]) }
                    else { (q0, q1, q2, tA, tB) = (b2, b0, b1, t20[0], 1 - t12[0]) }
                    let mA = q0 + (q1 - q0) * tA
                    let mB = q0 + (q2 - q0) * tB
                    // Each piece is asked about itself, at its own centre.
                    //
                    // Deciding one corner's side and giving the other pieces the opposite assumes
                    // the split really did separate the two sides. It often does not: a crossing
                    // can be reported where the curve merely grazes an edge, and then both pieces
                    // lie on the same side while one is labelled as though it did not. With the
                    // flood disabled the boundary showed this directly — a checkerboard of glass
                    // and body sub-triangles rather than two clean sides.
                    markCut(vertex(f, mA), vertex(f, mB))
                    emit(vertex(f, q0), vertex(f, mA), vertex(f, mB),
                         side((at(q0) + at(mA) + at(mB)) / 3), f)
                    emit(vertex(f, mA), vertex(f, q1), vertex(f, q2),
                         side((at(mA) + at(q1) + at(q2)) / 3), f)
                    emit(vertex(f, mA), vertex(f, q2), vertex(f, mB),
                         side((at(mA) + at(q2) + at(mB)) / 3), f)
                    return
                }
                // Kept as a backstop only. With conforming refinement done beforehand this
                // should not be reached; if it is, one triangle is classified whole rather than
                // leaving a T-junction behind.
                guard depth < 3 else {
                    statBackstop += 1
                    emit(vertex(f, b0), vertex(f, b1), vertex(f, b2),
                         side((p0 + p1 + p2) / 3), f)
                    return
                }
                let m01 = (b0 + b1) / 2, m12 = (b1 + b2) / 2, m20 = (b2 + b0) / 2
                carve(b0, m01, m20, depth + 1)
                carve(m01, b1, m12, depth + 1)
                carve(m20, m12, b2, depth + 1)
                carve(m01, m12, m20, depth + 1)
            }
            carve(SIMD3(1, 0, 0), SIMD3(0, 1, 0), SIMD3(0, 0, 1), 0)
        }
        if debug {
            print(String(format: "      view: %d faces, facing %d, visible %d, both %d, "
                                 + "centroid-in-stencil %d, glass out %d | simple %d, backstop %d, "
                         + "untouched %d",
                         m, statFacing, statVisible, statBoth, statInsideStencil,
                         outInside.filter { $0 }.count, statSimple, statBackstop,
                         statUntouched))
        }
        if onCurve.count < outV.count / 3 {
            onCurve.append(contentsOf: [Bool](repeating: false,
                                              count: outV.count / 3 - onCurve.count))
        }
        return (outV, outN, outU, outF, outInside, outParent, onCurve)
    }

    static func rasterise(_ px: [SIMD3<Float>], faces: [UInt32], w: Int, h: Int,
                          into depth: inout [Float]) {
        for f in 0 ..< (faces.count / 3) {
            let a = px[Int(faces[f*3])], b = px[Int(faces[f*3+1])], c = px[Int(faces[f*3+2])]
            let minX = max(Int(min(a.x, b.x, c.x)), 0), maxX = min(Int(max(a.x, b.x, c.x)) + 1, w - 1)
            let minY = max(Int(min(a.y, b.y, c.y)), 0), maxY = min(Int(max(a.y, b.y, c.y)) + 1, h - 1)
            guard minX <= maxX, minY <= maxY else { continue }
            let area = (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x)
            guard abs(area) > 1e-9 else { continue }
            for y in minY ... maxY {
                for x in minX ... maxX {
                    let fx = Float(x), fy = Float(y)
                    let w0 = ((b.x - a.x) * (fy - a.y) - (b.y - a.y) * (fx - a.x)) / area
                    let w1 = ((c.x - b.x) * (fy - b.y) - (c.y - b.y) * (fx - b.x)) / area
                    let w2 = ((a.x - c.x) * (fy - c.y) - (a.y - c.y) * (fx - c.x)) / area
                    guard (w0 >= 0 && w1 >= 0 && w2 >= 0) || (w0 <= 0 && w1 <= 0 && w2 <= 0)
                    else { continue }
                    let z = (a.z + b.z + c.z) / 3
                    if z > depth[y * w + x] { depth[y * w + x] = z }
                }
            }
        }
    }

    /// Where a segment crosses the contour, as parameters along that segment, sorted.
    static func crossings(_ a: SIMD2<Float>, _ b: SIMD2<Float>, _ index: Index) -> [Float] {
        var ts = [Float]()
        let d = b - a
        for si in index.near(a, b) {
            do {
                let p = index.segments[si].0, q = index.segments[si].1
                let e = q - p
                let denom = d.x * e.y - d.y * e.x
                if abs(denom) < 1e-12 { continue }
                let diff = p - a
                let t = (diff.x * e.y - diff.y * e.x) / denom
                let u = (diff.x * d.y - diff.y * d.x) / denom
                if t > 1e-5, t < 1 - 1e-5, u >= 0, u <= 1 { ts.append(t) }
            }
        }
        ts.sort()
        // Two crossings within a whisker of each other are the curve grazing a corner; keeping
        // both makes a sliver triangle with no area and a rendering artefact where there is none.
        var kept = [Float]()
        for t in ts where kept.last.map({ t - $0 > 1e-4 }) ?? true { kept.append(t) }
        return kept
    }
}
