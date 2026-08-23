import Foundation
import CoreGraphics
import ImageIO
import simd

/// The glass stencil, read from the view sheets instead of the atlas.
///
/// The sheets carry a clean stencil — the windows are crisp shapes with sharp edges, because that
/// is what the paint produced and what a person can edit by hand. The atlas does not: baking the
/// same alpha through the UV unwrap speckles it across the whole model, and on the black car 5.9%
/// of the atlas came out sub-opaque with the windows barely distinguishable from the noise. Every
/// ragged window edge traces back to cutting against that.
///
/// So the cut reads the sheets. Each face is projected into the six views the bake used, exactly
/// as the bake projects them, and sampled there. Nothing round-trips through the atlas, so the
/// edges arrive as sharp as they were drawn.
enum SheetStencil {

    /// Only the four side views may decide where glass is.
    ///
    /// The top and bottom views see a window nearly edge-on, and in plan a side window is a strip
    /// running along the flank — which lies over the door skin. Anything on the door that faces
    /// upwards, a handle recess most of all, sits inside that strip and gets claimed as glass. The
    /// side view sees the same handle squarely and is not confused for a moment. So the overhead
    /// views are excluded from the stencil entirely; they still contribute colour to the bake,
    /// where being edge-on costs nothing.
    static var stencilViews: [Int] {
        if let v = ProcessInfo.processInfo.environment["MODELR_STENCIL_VIEWS"] {
            let parsed = v.split(separator: ",").compactMap { Int($0) }
            if !parsed.isEmpty { return parsed }
        }
        // Top included, bottom not. The overhead view is only dangerous when it carries the
        // paint model's own alpha — that is what put a window strip over the door handles. Where
        // the cutouts are hand-drawn the view is as trustworthy as any other, and it is the only
        // one that describes a roof or a sunroof at all. The seeding veto still protects against
        // a face being claimed by a view that a better-facing view says is not glass.
        return [0, 1, 2, 3, 4]
    }

    /// The canonical six, in sheet order.
    static let elevs: [Float] = [0, 0, 0, 0, 90, -90]
    static let azims: [Float] = [0, 90, 180, 270, 0, 180]

    /// A per-vertex field, positive inside the glass, for `MeshCut.cut`.
    ///
    /// One view answers for each window, and everything else is faded out continuously.
    ///
    /// Two earlier designs failed here and both failures are instructive. Sampling every view and
    /// keeping the most-inside answer serrated the boundary — not because of the maximum, which is
    /// continuous, but because the *gates* deciding which views were eligible are binary, and
    /// along a grazing edge they flicker vertex to vertex, fusing different view sets whose
    /// image-space distances disagree in magnitude. Removing the gates entirely then classified a
    /// quarter of the car as glass: an A-pillar is a rounded tube whose inboard half curls behind
    /// the pane and lands *inside* the window outline in a side projection, as do the sill's inner
    /// lip and the whole interior. Ungated, all of it reads as glass.
    ///
    /// So the gates become weights. Off-pane geometry is pulled towards "outside" smoothly rather
    /// than switched, using a depth map built from the window's own triangles — nothing else can
    /// occlude it, so nothing flickers — and a soft facing term. On the pane itself both weights
    /// are 1, so the contour is governed purely by the painted stencil, which was the point.
    /// (Diagnosis and design: Fable.)
    static func field(stencil: URL, vertices: [Float], normals: [Float], faces: [UInt32])
        -> [Float]? {
        guard let (sw, sh, inside) = GlassSheet.stencilMask(stencil), sw >= sh, sh > 0
        else { return nil }
        let views = min(sw / sh, elevs.count)
        guard views >= 4, inside.contains(true) else { return nil }

        var sdf = [[Float]](repeating: [], count: views)
        for v in stencilViews where v < views {
            var tile = [Bool](repeating: false, count: sh * sh)
            for y in 0 ..< sh {
                for x in 0 ..< sh { tile[y * sh + x] = inside[y * sw + v * sh + x] }
            }
            sdf[v] = signedDistance(tile, w: sh, h: sh)
        }

        let p = normalised(vertices)
        let n = vertices.count / 3
        var nrm = [SIMD3<Float>](repeating: .zero, count: n)
        for i in 0 ..< n {
            let q = SIMD3(-normals[i*3], normals[i*3+2], -normals[i*3+1])
            nrm[i] = simd_length(q) > 1e-9 ? simd_normalize(q) : SIMD3(0, 0, 1)
        }

        func sample(_ f: [Float], _ x: Float, _ y: Float) -> Float {
            let cx = min(max(x, 0), Float(sh - 1)), cy = min(max(y, 0), Float(sh - 1))
            let x0 = Int(cx), y0 = Int(cy)
            let x1 = min(x0 + 1, sh - 1), y1 = min(y0 + 1, sh - 1)
            let fx = cx - Float(x0), fy = cy - Float(y0)
            let a = f[y0 * sh + x0] * (1 - fx) + f[y0 * sh + x1] * fx
            let b = f[y1 * sh + x0] * (1 - fx) + f[y1 * sh + x1] * fx
            return a * (1 - fy) + b * fy
        }

        let welded = MeshCut.weldMap(vertices: vertices)
        var px = [[SIMD3<Float>]](repeating: [], count: views)
        var facing = [[Float]](repeating: [], count: views)
        var fwds = [SIMD3<Float>](repeating: .zero, count: views)
        // Which view each vertex belongs to: the one it faces most directly.
        //
        // A window belongs to the view that looks straight at it — the right view owns the right
        // side glass, the front view owns the windscreen — and no other view may claim it. This
        // is what stops a view that barely grazes a surface from marking it glass on the strength
        // of two or three texels, while three better-placed views say it is nowhere near a window.
        var owner = [Int](repeating: -1, count: n)
        do {
            var bestDot = [Float](repeating: 0.05, count: n)      // must face it at all
            for v in stencilViews where v < views {
                let (_, _, fwd, _) = basis(elev: elevs[v], azim: azims[v], dist: 1.45)
                for i in 0 ..< n {
                    // Same expression the seeding test uses, deliberately: written with the
                    // opposite sign these two conditions can never both hold, and the stencil
                    // silently produces nothing at all.
                    let d = simd_dot(nrm[i], fwd)
                    if d > bestDot[i] { bestDot[i] = d; owner[i] = v }
                }
            }
        }

        var confident = [Bool](repeating: false, count: n)
        var vetoed = [Bool](repeating: false, count: n)
        for v in stencilViews where v < views {
            let (right, up, fwd, eye) = basis(elev: elevs[v], azim: azims[v], dist: 1.45)
            fwds[v] = fwd
            var proj = [SIMD3<Float>](repeating: .zero, count: n)
            var face = [Float](repeating: 0, count: n)
            for i in 0 ..< n {
                let d = p[i] - eye
                proj[i] = SIMD3((simd_dot(d, right) / 0.6 * 0.5 + 0.5) * Float(sh - 1),
                                (simd_dot(d, up) / 0.6 * 0.5 + 0.5) * Float(sh - 1),
                                simd_dot(d, fwd))
                face[i] = simd_dot(nrm[i], fwd)
            }
            var depth = [Float](repeating: -.greatestFiniteMagnitude, count: sh * sh)
            rasteriseDepth(proj, faces: faces, w: sh, h: sh, into: &depth)
            for i in 0 ..< n where face[i] > 0.3 && owner[i] == v {
                let x = Int(proj[i].x.rounded()), y = Int(proj[i].y.rounded())
                guard x >= 0, x < sh, y >= 0, y < sh,
                      proj[i].z >= depth[y * sh + x] - 0.01 else { continue }
                let value = sample(sdf[v], proj[i].x, proj[i].y)
                // Marked on the welded representative: a duplicated seam vertex could otherwise
                // be confident while its representative was not, which fragments regions.
                // Solidly inside, not merely inside.
                //
                // At two texels, anything grazing the edge of a window in any view founds its own
                // "window" — and the diagnostic showed every stray patch on the car sitting
                // between two and six texels in, while a real pane is tens of texels deep. The
                // boundary is still the traced curve; this only decides where a window is allowed
                // to *start*.
                let seedDepth = Float(ProcessInfo.processInfo.environment["MODELR_SEED_DEPTH"] ?? "") ?? 10
                if value > seedDepth { confident[welded[i]] = true }
                // And a veto, for the door handle problem. A recessed handle faces upwards, so
                // the top view sees it and the side glass overlaps it in plan — it seeds a
                // "window" in the middle of a door. The side view sees that handle perfectly and
                // says it is nowhere near glass, so one clear dissent is enough to drop it.
                if value < -4 { vetoed[welded[i]] = true }
            }
            px[v] = proj; facing[v] = face
        }
        for i in 0 ..< n where vetoed[i] { confident[i] = false }
        guard confident.contains(true) else { return nil }

        var adjacency = [[Int]](repeating: [], count: n)
        for f in 0 ..< (faces.count / 3) {
            let a = welded[Int(faces[f*3])], b = welded[Int(faces[f*3+1])], c = welded[Int(faces[f*3+2])]
            adjacency[a].append(b); adjacency[b].append(a)
            adjacency[b].append(c); adjacency[c].append(b)
            adjacency[c].append(a); adjacency[a].append(c)
        }
        var region = [Int](repeating: -1, count: n)
        var regions = [[Int]]()
        for i in 0 ..< n where confident[welded[i]] && region[welded[i]] < 0 {
            let id = regions.count
            var stack = [welded[i]], members = [Int]()
            region[welded[i]] = id
            while let x = stack.popLast() {
                members.append(x)
                for y in adjacency[x] where confident[y] && region[y] < 0 {
                    region[y] = id; stack.append(y)
                }
            }
            regions.append(members)
        }

        var out = [Float](repeating: -1, count: n)
        let unit = max(Float(sh) / 512, 1)
        let tau: Float = 0.05                      // a few percent of the model's radius

        for members in regions {
            guard members.count > 8 else { continue }
            let set = Set(members)
            var bestView = stencilViews[0], bestScore: Float = -1
            for v in stencilViews where v < views {
                var score: Float = 0
                for i in members { score += max(0, facing[v][i]) }
                if score > bestScore { bestScore = score; bestView = v }
            }
            let fwd = fwds[bestView], proj = px[bestView], sdfV = sdf[bestView]

            // Depth of the window pane itself, from its own triangles only. Nothing else can
            // occlude it, so this map is smooth — unlike a whole-mesh depth buffer, whose
            // silhouette aliasing was half of the original flicker.
            var zpane = [Float](repeating: .greatestFiniteMagnitude, count: sh * sh)
            var paneFaces = [UInt32]()
            for t in 0 ..< (faces.count / 3) {
                let a = welded[Int(faces[t*3])], b = welded[Int(faces[t*3+1])], c = welded[Int(faces[t*3+2])]
                if set.contains(a) && set.contains(b) && set.contains(c) {
                    paneFaces.append(faces[t*3]); paneFaces.append(faces[t*3+1]); paneFaces.append(faces[t*3+2])
                }
            }
            guard !paneFaces.isEmpty else { continue }
            var paneDepth = [Float](repeating: -.greatestFiniteMagnitude, count: sh * sh)
            rasteriseDepth(proj, faces: paneFaces, w: sh, h: sh, into: &paneDepth)
            for k in 0 ..< (sh * sh) where paneDepth[k] > -.greatestFiniteMagnitude {
                zpane[k] = paneDepth[k]
            }
            nearestFill(&zpane, w: sh, h: sh)

            // Centre and radius, to stop one window's outline recruiting the far side of the car.
            var centre = SIMD3<Float>.zero
            for i in members { centre += p[i] }
            centre /= Float(members.count)
            var radius: Float = 0
            for i in members { radius = max(radius, simd_length(p[i] - centre)) }
            let reach = radius * 1.5 + 0.02

            for i in 0 ..< n {
                guard owner[i] == bestView else { continue }
                guard simd_length(p[i] - centre) <= reach else { continue }
                let s = sample(sdfV, proj[i].x, proj[i].y)
                guard abs(s) < 16 || s > 0 else { continue }
                let z = zpane[min(max(Int(proj[i].y.rounded()), 0), sh - 1) * sh
                            + min(max(Int(proj[i].x.rounded()), 0), sh - 1)]
                guard z < .greatestFiniteMagnitude else { continue }
                // Continuous, not a gate: geometry behind the pane fades out instead of
                // switching, so the field stays smooth exactly where the cut runs.
                let wDepth = max(0, min(1, 1 - abs(proj[i].z - z) / tau))
                let wFace = smoothstep(0.05, 0.30, simd_dot(nrm[i], fwd))
                let w = wDepth * wFace
                let value = w * (s / unit) + (1 - w) * -1
                out[i] = max(out[i], value)
            }
        }
        return out
    }

    private static func smoothstep(_ a: Float, _ b: Float, _ x: Float) -> Float {
        let t = max(0, min(1, (x - a) / max(b - a, 1e-6)))
        return t * t * (3 - 2 * t)
    }

    /// Spread the nearest known value into the empty texels, by two sweeps.
    private static func nearestFill(_ f: inout [Float], w: Int, h: Int) {
        let big = Float.greatestFiniteMagnitude
        var dist = [Float](repeating: big, count: w * h)
        for k in 0 ..< (w * h) where f[k] < big { dist[k] = 0 }
        func relax(_ k: Int, _ j: Int, _ step: Float) {
            if dist[j] + step < dist[k] { dist[k] = dist[j] + step; f[k] = f[j] }
        }
        let d: Float = 1, dd: Float = 1.41421356
        for y in 0 ..< h {
            for x in 0 ..< w {
                let k = y * w + x
                if x > 0 { relax(k, k - 1, d) }
                if y > 0 { relax(k, k - w, d) }
                if x > 0, y > 0 { relax(k, k - w - 1, dd) }
                if x < w - 1, y > 0 { relax(k, k - w + 1, dd) }
            }
        }
        for y in stride(from: h - 1, through: 0, by: -1) {
            for x in stride(from: w - 1, through: 0, by: -1) {
                let k = y * w + x
                if x < w - 1 { relax(k, k + 1, d) }
                if y < h - 1 { relax(k, k + w, d) }
                if x < w - 1, y < h - 1 { relax(k, k + w + 1, dd) }
                if x > 0, y < h - 1 { relax(k, k + w - 1, dd) }
            }
        }
    }

    /// How the mesh is oriented for the sheet cameras. Found by search, not by reasoning.
    struct Convention {
        var elevSign: Float = 1
        var azimOffset: Float = 0
        var flipX = false
        var flipY = false
        var axes = 0            // which of the plausible axis remaps to use
    }

    /// Try the plausible conventions and report how well each matches the sheets.
    ///
    /// Every sign in a camera basis is a coin flip I have now lost three times, and each loss
    /// cost a round trip through a rendered picture. The silhouette is a cheap, objective score,
    /// so the machine can try all of them and say which is right.
    static func search(sheet: URL, vertices: [Float], faces: [UInt32])
        -> [(Convention, Double)] {
        var results = [(Convention, Double)]()
        for axes in 0 ..< 3 {
            for elevSign in [Float(1), -1] {
                for azimOffset in [Float(0), 90, 180, 270] {
                    for flipX in [false, true] {
                        for flipY in [false, true] {
                            var c = Convention()
                            c.axes = axes; c.elevSign = elevSign; c.azimOffset = azimOffset
                            c.flipX = flipX; c.flipY = flipY
                            let s = silhouetteAgreement(sheet: sheet, vertices: vertices,
                                                        faces: faces, convention: c)
                            let mean = s.isEmpty ? 0 : s.map(\.iou).reduce(0, +) / Double(s.count)
                            results.append((c, mean))
                        }
                    }
                }
            }
        }
        return results.sorted { $0.1 > $1.1 }
    }

    /// Does the projection line up with the sheets at all?
    ///
    /// Sign conventions in a camera basis are guessable and I guessed wrong twice, each time
    /// discovering it from a picture of a car with black underneath. The silhouette settles it
    /// without opinion: rasterise the mesh into each view and compare with the pixels the sheet
    /// actually painted. A correct projection overlaps almost exactly; a flipped one does not.
    static func silhouetteAgreement(sheet: URL, vertices: [Float], faces: [UInt32],
                                    convention c: Convention = Convention())
        -> [(view: Int, iou: Double)] {
        // The car, as distinct from the ground it is drawn on.
        //
        // Alpha cannot answer this: the sheets are painted on an opaque grey ground, so "has
        // alpha" is true for the entire tile — which is why the first version of this test gave
        // every convention the same score and looked like proof of a broken projection. The
        // ground is one flat colour, so anything that is not that colour is the car.
        guard let (sw, sh, rgba) = loadRGBA(sheet), sw >= sh, sh > 0 else { return [] }
        let corner = SIMD3<Int>(Int(rgba[0]), Int(rgba[1]), Int(rgba[2]))
        var painted = [Bool](repeating: false, count: sw * sh)
        for i in 0 ..< (sw * sh) {
            let d = abs(Int(rgba[i*4]) - corner.x) + abs(Int(rgba[i*4+1]) - corner.y)
                  + abs(Int(rgba[i*4+2]) - corner.z)
            painted[i] = d > 24 || rgba[i*4+3] < 250
        }
        let views = sw / sh
        let p = normalised(vertices, axes: c.axes)
        var out = [(Int, Double)]()
        for v in 0 ..< min(views, elevs.count) {
            let (right, up, fwd, eye) = basis(elev: elevs[v] * c.elevSign,
                                              azim: azims[v] + c.azimOffset, dist: 1.45)
            var px = [SIMD3<Float>](repeating: .zero, count: p.count)
            for i in 0 ..< p.count {
                let d = p[i] - eye
                var sx = simd_dot(d, right) / 0.6 * 0.5 + 0.5
                var sy = simd_dot(d, up) / 0.6 * 0.5 + 0.5
                if c.flipX { sx = 1 - sx }
                if !c.flipY { sy = 1 - sy }
                px[i] = SIMD3(sx * Float(sh - 1), sy * Float(sh - 1), simd_dot(d, fwd))
            }
            var depth = [Float](repeating: -.greatestFiniteMagnitude, count: sh * sh)
            rasteriseDepth(px, faces: faces, w: sh, h: sh, into: &depth)
            var inter = 0, union = 0
            for y in 0 ..< sh {
                for x in 0 ..< sh {
                    let mesh = depth[y * sh + x] > -.greatestFiniteMagnitude
                    let p = painted[y * sw + v * sh + x]
                    if mesh || p { union += 1 }
                    if mesh && p { inter += 1 }
                }
            }
            out.append((v, union > 0 ? Double(inter) / Double(union) : 0))
        }
        return out
    }

    /// Vertex normals rotated into the same space as `normalised` positions.
    ///
    /// Negated, and that is not a fudge. The map the renderer applies to positions —
    /// `(x, y, z) -> (-x, z, -y)` — has determinant -1: it is a reflection, not a rotation.
    /// Applying it to a normal reverses which side of the surface the normal is on, so an
    /// outward normal arrives pointing into the model. Every facing test built on it was
    /// therefore inverted: it selected the faces looking *away* from each camera. Measured on
    /// one car, front-facing and depth-visible had almost no faces in common — 2,895 out of
    /// 37,303 — which is impossible for a real surface and is the signature of this bug.
    /// Negating restores it: the same two sets then overlap by 60%, as a solid object should.
    static func viewNormals(_ normals: [Float]) -> [SIMD3<Float>] {
        let n = normals.count / 3
        var out = [SIMD3<Float>](repeating: SIMD3(0, 0, 1), count: n)
        for i in 0 ..< n {
            let flip: Float = ProcessInfo.processInfo.environment["MODELR_VN_FLIP"] == "1" ? -1 : 1
            let q = flip * SIMD3(normals[i*3], -normals[i*3+2], normals[i*3+1])
            if simd_length(q) > 1e-9 { out[i] = simd_normalize(q) }
        }
        return out
    }

    static func normalised(_ vertices: [Float], axes: Int = 0) -> [SIMD3<Float>] {
        let n = vertices.count / 3
        var p = [SIMD3<Float>](repeating: .zero, count: n)
        for i in 0 ..< n {
            let x = vertices[i*3], y = vertices[i*3+1], z = vertices[i*3+2]
            switch axes {
            case 1:  p[i] = SIMD3(x, y, z)              // as-is
            case 2:  p[i] = SIMD3(x, z, y)              // Y up -> Z up, no mirroring
            default: p[i] = SIMD3(-x, z, -y)            // what loadMesh does
            }
        }
        var lo = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
        var hi = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
        for q in p { lo = simd_min(lo, q); hi = simd_max(hi, q) }
        let ctr = (lo + hi) / 2
        var maxr: Float = 0
        for q in p { maxr = max(maxr, simd_length(q - ctr)) }
        let s = 1.15 / max(maxr * 2, 1e-6)
        for i in 0 ..< n { p[i] = (p[i] - ctr) * s }
        return p
    }

    // MARK: - helpers

    static func basis(elev: Float, azim: Float, dist: Float)
        -> (right: SIMD3<Float>, up: SIMD3<Float>, fwd: SIMD3<Float>, eye: SIMD3<Float>) {
        let e = Double(-elev), a = Double(azim) + 90
        let er = e * .pi / 180, ar = a * .pi / 180
        let eye = SIMD3<Float>(Float(Double(dist) * cos(er) * cos(ar)),
                               Float(Double(dist) * cos(er) * sin(ar)),
                               Float(Double(dist) * sin(er)))
        let look = simd_normalize(-eye)
        var up = SIMD3<Float>(0, 0, 1)
        let right = simd_normalize(simd_cross(look, up))
        up = simd_normalize(simd_cross(right, look))
        return (right, up, -look, eye)
    }

    private static func rasteriseDepth(_ px: [SIMD3<Float>], faces: [UInt32], w: Int, h: Int,
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

    static func signedDistance(_ inside: [Bool], w: Int, h: Int) -> [Float] {
        let big: Float = 1e9
        var d = [Float](repeating: big, count: w * h)
        for y in 0 ..< h {
            for x in 0 ..< w {
                let k = y * w + x
                var edge = false
                if x > 0, inside[k] != inside[k-1] { edge = true }
                if !edge, x < w-1, inside[k] != inside[k+1] { edge = true }
                if !edge, y > 0, inside[k] != inside[k-w] { edge = true }
                if !edge, y < h-1, inside[k] != inside[k+w] { edge = true }
                if edge { d[k] = 0 }
            }
        }
        let diag: Float = 1.41421356
        for y in 0 ..< h {
            for x in 0 ..< w {
                let k = y * w + x
                var v = d[k]
                if x > 0 { v = min(v, d[k-1] + 1) }
                if y > 0 { v = min(v, d[k-w] + 1) }
                if x > 0, y > 0 { v = min(v, d[k-w-1] + diag) }
                if x < w-1, y > 0 { v = min(v, d[k-w+1] + diag) }
                d[k] = v
            }
        }
        for y in stride(from: h-1, through: 0, by: -1) {
            for x in stride(from: w-1, through: 0, by: -1) {
                let k = y * w + x
                var v = d[k]
                if x < w-1 { v = min(v, d[k+1] + 1) }
                if y < h-1 { v = min(v, d[k+w] + 1) }
                if x < w-1, y < h-1 { v = min(v, d[k+w+1] + diag) }
                if x > 0, y < h-1 { v = min(v, d[k+w-1] + diag) }
                d[k] = v
            }
        }
        var out = [Float](repeating: 0, count: w * h)
        for i in 0 ..< (w * h) { out[i] = inside[i] ? d[i] : -d[i] }
        return out
    }

    private static func loadRGBA(_ url: URL) -> (Int, Int, [UInt8])? {
        guard let d = try? Data(contentsOf: url),
              let src = CGImageSourceCreateWithData(d as CFData, nil),
              let cg = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
        let w = cg.width, h = cg.height
        var rgba = [UInt8](repeating: 0, count: w * h * 4)
        guard let ctx = CGContext(data: &rgba, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        return (w, h, rgba)
    }

    private static func loadAlpha(_ url: URL) -> (Int, Int, [UInt8])? {
        guard let d = try? Data(contentsOf: url),
              let src = CGImageSourceCreateWithData(d as CFData, nil),
              let cg = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
        let w = cg.width, h = cg.height
        var rgba = [UInt8](repeating: 0, count: w * h * 4)
        guard let ctx = CGContext(data: &rgba, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        var a = [UInt8](repeating: 0, count: w * h)
        for i in 0 ..< (w * h) { a[i] = rgba[i*4 + 3] }
        return (w, h, a)
    }
}
