import Foundation
import CoreGraphics
import ImageIO
import simd

/// Re-cut a mesh so a selection's boundary follows a smooth curve instead of the triangulation.
///
/// Every tool so far could only choose *which* triangles are glass, never where the edge runs, so
/// the best possible answer was a sawtooth stepping along whichever edges happened to be there.
/// Morphology cleans that up a little and cannot do better in principle.
///
/// Since the mesh is ours to change, the boundary can simply be moved. The trick is to stop
/// thinking of the selection as a set of triangles and treat it as a *field*: give every vertex a
/// number, positive inside the selection and negative outside, and the boundary becomes the
/// contour where that number crosses zero. Smoothing the field smooths the contour — and unlike
/// smoothing a polyline, it cannot fold, self-intersect or collapse a triangle, because the
/// contour is derived rather than moved.
///
/// Cutting along the contour is then the standard marching-triangles case analysis: a triangle
/// with mixed signs is split at the two points where its edges cross zero. New vertices carry
/// linearly interpolated position, normal and UV, so the existing atlas still lines up exactly and
/// no re-bake is needed.
enum MeshCut {

    struct Mesh {
        var vertices: [Float]      // xyz
        var normals: [Float]       // xyz
        var uvs: [Float]           // uv
        var faces: [UInt32]        // triangle indices
        /// Which side of the cut each face ended up on.
        var inside: [Bool]
        /// For each new face, the face it came from — so face-indexed masks can be carried over.
        var parent: [Int]
    }

    /// Per-vertex field read from the atlas's own alpha, for cutting along the painted window
    /// edge rather than along a face selection.
    ///
    /// The face selection is the coarsest description of a window there is — one bit per triangle.
    /// The alpha channel already holds the same boundary at texel resolution, drawn by the bake
    /// from the views themselves. Using it as the field means the cut lands on the edge the paint
    /// actually has, and the mesh is re-cut to match the texture instead of the other way round.
    ///
    /// Samples are taken inside each face rather than at its vertices: a vertex sits on a chart
    /// corner where a sample can land in the padding of a neighbouring chart, while a point
    /// pulled towards the centroid is always within the face's own island.
    static func alphaField(texture: URL, vertices: [Float], uvs: [Float], faces: [UInt32],
                           cut: Float) -> [Float]? {
        guard let (w, h, alpha) = loadAlpha(texture) else { return nil }
        let n = w * h

        // 1. Hard mask. The bake's soft ramp is not an anti-aliased edge, it is dirt.
        var inside = [Bool](repeating: false, count: n)
        for i in 0 ..< n { inside[i] = Float(alpha[i]) / 255 < cut }
        guard inside.contains(true) else { return nil }

        // 2. Clean it as a mask, in the atlas. This is where the jaggies actually live: the
        //    stencil's boundary is speckled at texel scale, and no amount of smoothing on the
        //    vertex graph can remove detail finer than the vertices themselves — it only turns
        //    texel noise into random per-vertex noise, which is the sawtooth. Opening removes
        //    the specks that stick out, closing fills the pinholes that bite in.
        func morph(_ m: [Bool], dilate: Bool) -> [Bool] {
            var out = m
            for y in 0 ..< h {
                for x in 0 ..< w {
                    let k = y * w + x
                    if m[k] == dilate { continue }
                    var hit = false
                    if x > 0, m[k-1] == dilate { hit = true }
                    if !hit, x < w-1, m[k+1] == dilate { hit = true }
                    if !hit, y > 0, m[k-w] == dilate { hit = true }
                    if !hit, y < h-1, m[k+w] == dilate { hit = true }
                    if hit { out[k] = dilate }
                }
            }
            return out
        }
        let radius = max(1, min(3, h / 1024))
        for _ in 0 ..< radius { inside = morph(inside, dilate: false) }   // open: erode…
        for _ in 0 ..< (radius * 2) { inside = morph(inside, dilate: true) }  // …dilate, close…
        for _ in 0 ..< radius { inside = morph(inside, dilate: false) }   // …erode back

        // 3. Signed distance to the boundary, in texels, by two chamfer passes.
        //
        //    A binary mask sampled per face only ever answers in or out, so the contour can land
        //    nowhere but on a triangle edge. A distance field answers *how far*, which is what
        //    lets the cut place its crossing points partway along an edge and produce a curve
        //    rather than a staircase. It is also smooth by construction, so the noise that
        //    survived cleaning is averaged away instead of being sampled raw.
        let big: Float = 1e9
        var d = [Float](repeating: big, count: n)
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
        for y in 0 ..< h {                                   // forward
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
        for y in stride(from: h - 1, through: 0, by: -1) {   // backward
            for x in stride(from: w - 1, through: 0, by: -1) {
                let k = y * w + x
                var v = d[k]
                if x < w-1 { v = min(v, d[k+1] + 1) }
                if y < h-1 { v = min(v, d[k+w] + 1) }
                if x < w-1, y < h-1 { v = min(v, d[k+w+1] + diag) }
                if x > 0, y < h-1 { v = min(v, d[k+w-1] + diag) }
                d[k] = v
            }
        }
        // Positive inside the glass, in units of a few texels so the field is well scaled.
        let scale = max(Float(h) / 512, 2)
        var signed = [Float](repeating: 0, count: n)
        for i in 0 ..< n { signed[i] = (inside[i] ? d[i] : -d[i]) / scale }

        // 4. Sample it per face, inset from the corners.
        //
        //    A vertex sits on a chart corner where a sample can land in the padding of a
        //    neighbouring chart; a point pulled towards the centroid is always within the face's
        //    own island.
        let welded = weldMap(vertices: vertices)
        let count = vertices.count / 3
        var sum = [Float](repeating: 0, count: count)
        var cnt = [Float](repeating: 0, count: count)
        let inset: [(Float, Float, Float)] = [(0.6, 0.2, 0.2), (0.2, 0.6, 0.2), (0.2, 0.2, 0.6)]
        for f in 0 ..< (faces.count / 3) {
            let i = [Int(faces[f*3]), Int(faces[f*3+1]), Int(faces[f*3+2])]
            for k in 0 ..< 3 {
                let b = inset[k]
                let u = b.0 * uvs[i[0]*2]     + b.1 * uvs[i[1]*2]     + b.2 * uvs[i[2]*2]
                let v = b.0 * uvs[i[0]*2 + 1] + b.1 * uvs[i[1]*2 + 1] + b.2 * uvs[i[2]*2 + 1]
                let x = min(max(Int(u * Float(w - 1)), 0), w - 1)
                let y = min(max(Int(v * Float(h - 1)), 0), h - 1)
                let r = welded[i[k]]
                sum[r] += signed[y * w + x]
                cnt[r] += 1
            }
        }
        var field = [Float](repeating: -1, count: count)
        for i in 0 ..< count where cnt[welded[i]] > 0 { field[i] = sum[welded[i]] / cnt[welded[i]] }
        return field
    }

    /// The alpha level that separates glass from body, measured from the atlas itself — each car
    /// paints its windows at its own transparency.
    static func alphaCut(texture: URL) -> Float {
        guard let (_, _, a) = loadAlpha(texture) else { return 0.75 }
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
        // Separate *any* transparency from the opaque body, rather than splitting the
        // transparent texels among themselves.
        //
        // A car often paints its windows at more than one alpha — the black car has 201k texels
        // at 74 and 47k at 164. A median-based threshold lands at 0.44, between the two, so the
        // lighter glass counts as bodywork and the contour is dragged through the middle of a
        // window along whatever texel noise separates the levels. That is the ragged edge.
        //
        // Halfway between the *least* transparent glass and fully opaque puts every window on
        // the glass side and still leaves a wide margin against anti-aliased body edges.
        let top = soft[min(soft.count - 1, soft.count * 98 / 100)]
        return min(0.97, max(0.5, (top + 1) / 2))
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
        var out = [UInt8](repeating: 255, count: w * h)
        for i in 0 ..< (w * h) { out[i] = rgba[i*4 + 3] }
        return (w, h, out)
    }

    /// - Parameters:
    ///   - smoothing: passes of averaging over the field. More passes, rounder boundary. Past
    ///     roughly 30 the contour starts pulling away from the shape it came from.
    ///   - tension: how far each pass moves the field towards its neighbours, 0...1.
    static func cut(vertices: [Float], normals: [Float], uvs: [Float], faces: [UInt32],
                    inside mask: [Bool], smoothing: Int = 12, tension: Float = 0.5,
                    field given: [Float]? = nil, preserveArea: Bool = true) -> Mesh? {
        let vCount = vertices.count / 3
        let fCount = faces.count / 3
        guard vCount > 0, fCount > 0, mask.count >= fCount else { return nil }

        // Weld first. The .tmesh splits a vertex once per UV chart, so two triangles can meet in
        // space while sharing no index; a field defined on raw indices would be discontinuous
        // along every chart seam and the contour would tear there.
        let welded = weldMap(vertices: vertices)
        let repCount = vCount

        // Seed the field: how much of the geometry around a vertex is selected, mapped to -1...1.
        var sum = [Float](repeating: 0, count: repCount)
        var cnt = [Float](repeating: 0, count: repCount)
        for f in 0 ..< fCount {
            let v = mask[f] ? Float(1) : Float(-1)
            for k in 0 ..< 3 {
                let r = welded[Int(faces[f*3 + k])]
                sum[r] += v; cnt[r] += 1
            }
        }
        var field = [Float](repeating: 0, count: repCount)
        for i in 0 ..< repCount where cnt[i] > 0 { field[i] = sum[i] / cnt[i] }
        if let given, given.count == repCount { field = given }

        /// Faces on the positive side of the field as it stands.
        func positiveFaces(_ f: [Float]) -> Int {
            var n = 0
            for t in 0 ..< fCount {
                let v = (f[welded[Int(faces[t*3])]] + f[welded[Int(faces[t*3+1])]]
                       + f[welded[Int(faces[t*3+2])]]) / 3
                if v >= 0 { n += 1 }
            }
            return n
        }
        // How much glass there is *before* smoothing — the area to hold on to afterwards. Taken
        // from the field itself rather than the passed mask, since an alpha-derived field
        // describes the windows and the mask may be empty.
        let areaTarget = given != nil ? positiveFaces(field)
                                      : mask.prefix(fCount).lazy.filter { $0 }.count

        // Smooth it over the welded edge graph. This is what turns a staircase into a curve.
        var adjacency = [[Int]](repeating: [], count: repCount)
        var seen = Set<UInt64>()
        seen.reserveCapacity(fCount * 3)
        for f in 0 ..< fCount {
            let a = welded[Int(faces[f*3])], b = welded[Int(faces[f*3+1])], c = welded[Int(faces[f*3+2])]
            for (x, y) in [(a, b), (b, c), (c, a)] {
                let key = x < y ? UInt64(x) << 32 | UInt64(y) : UInt64(y) << 32 | UInt64(x)
                if seen.insert(key).inserted {
                    adjacency[x].append(y); adjacency[y].append(x)
                }
            }
        }
        for _ in 0 ..< max(0, smoothing) {
            var next = field
            for i in 0 ..< repCount where !adjacency[i].isEmpty {
                var s: Float = 0
                for j in adjacency[i] { s += field[j] }
                next[i] = field[i] + tension * (s / Float(adjacency[i].count) - field[i])
            }
            field = next
        }

        // Re-anchor the contour before cutting.
        //
        // Averaging a signed indicator does not just smooth the boundary, it *moves* it: every
        // pass pulls the field towards the surrounding majority, so a selection that covers a
        // small share of the mesh shrinks a little each time and eventually disappears. Measured
        // on one windscreen: 4,269 glass faces at zero passes, 248 at six, none at twelve.
        //
        // The cure is to stop insisting the contour sits at zero. Smoothing preserves the *shape*
        // of the field; only its level is unreliable. So pick the level that reproduces the
        // original area — rank the faces by field value and cut where the selected count lands —
        // and the boundary keeps its size while gaining its smoothness.
        let target = areaTarget
        var level: Float = 0
        // Alpha already carries a meaningful zero — the transparency threshold — so its contour
        // is where it should be and re-levelling would only drag it off the painted edge. The
        // levelling exists for the indicator field, whose zero drifts as it is smoothed.
        if preserveArea, target > 0, target < fCount {
            var faceValue = [Float](repeating: 0, count: fCount)
            for f in 0 ..< fCount {
                faceValue[f] = (field[welded[Int(faces[f*3])]]
                              + field[welded[Int(faces[f*3+1])]]
                              + field[welded[Int(faces[f*3+2])]]) / 3
            }
            let sorted = faceValue.sorted(by: >)
            level = sorted[min(target, sorted.count - 1)]
        }
        for i in 0 ..< repCount { field[i] -= level }

        // Marching triangles along field = 0.
        var outV = vertices, outN = normals, outU = uvs
        var outF = [UInt32](), outInside = [Bool](), outParent = [Int]()
        outF.reserveCapacity(faces.count)
        var edgePoint = [UInt64: UInt32]()      // one shared vertex per cut edge, so no cracks

        func value(_ vertexIndex: Int) -> Float { field[welded[vertexIndex]] }

        /// The vertex where the contour crosses this edge, created once and reused.
        ///
        /// Keyed on the *raw* index pair, not the welded one. Two triangles either side of a UV
        /// seam meet in space but belong to different charts, and each holds its own UVs for the
        /// shared corner. Giving them one vertex forces one chart's UVs on both, so the far side
        /// samples a random part of the atlas — which shows up as long white slashes across the
        /// body. Splitting them costs a duplicate vertex and nothing else: the field is welded,
        /// so both copies interpolate at the same t and land on exactly the same point in space.
        func crossing(_ i: Int, _ j: Int) -> UInt32 {
            let key = i < j ? UInt64(i) << 32 | UInt64(j) : UInt64(j) << 32 | UInt64(i)
            if let e = edgePoint[key] { return e }
            let fi = field[welded[i]], fj = field[welded[j]]
            // Guard the degenerate case; a zero denominator would put the point at infinity.
            let denom = fi - fj
            let t = abs(denom) < 1e-9 ? Float(0.5) : min(max(fi / denom, 0.001), 0.999)
            let idx = UInt32(outV.count / 3)
            for k in 0 ..< 3 {
                outV.append(vertices[i*3 + k] + t * (vertices[j*3 + k] - vertices[i*3 + k]))
                outN.append(normals[i*3 + k] + t * (normals[j*3 + k] - normals[i*3 + k]))
            }
            for k in 0 ..< 2 {
                // UVs are interpolated in the same proportion, which is what keeps the existing
                // atlas valid: the new vertex samples exactly where the old edge did.
                outU.append(uvs[i*2 + k] + t * (uvs[j*2 + k] - uvs[i*2 + k]))
            }
            edgePoint[key] = idx
            return idx
        }

        func emit(_ a: UInt32, _ b: UInt32, _ c: UInt32, inside: Bool, parent: Int) {
            guard a != b, b != c, a != c else { return }
            outF.append(a); outF.append(b); outF.append(c)
            outInside.append(inside); outParent.append(parent)
        }

        for f in 0 ..< fCount {
            let i0 = Int(faces[f*3]), i1 = Int(faces[f*3+1]), i2 = Int(faces[f*3+2])
            let f0 = value(i0), f1 = value(i1), f2 = value(i2)
            let p0 = f0 >= 0, p1 = f1 >= 0, p2 = f2 >= 0
            if p0 == p1 && p1 == p2 {
                emit(UInt32(i0), UInt32(i1), UInt32(i2), inside: p0, parent: f)
                continue
            }
            // Rotate so `a` is the odd one out; then the contour crosses edges a-b and a-c.
            let (a, b, c, lone): (Int, Int, Int, Bool)
            if p1 == p2 { (a, b, c, lone) = (i0, i1, i2, p0) }
            else if p0 == p2 { (a, b, c, lone) = (i1, i2, i0, p1) }
            else { (a, b, c, lone) = (i2, i0, i1, p2) }
            let ab = crossing(a, b), ac = crossing(a, c)
            emit(UInt32(a), ab, ac, inside: lone, parent: f)
            emit(ab, UInt32(b), UInt32(c), inside: !lone, parent: f)
            emit(ab, UInt32(c), ac, inside: !lone, parent: f)
        }

        return Mesh(vertices: outV, normals: outN, uvs: outU, faces: outF,
                    inside: outInside, parent: outParent)
    }

    /// Add vertices where the cut is about to land, so the boundary is not limited by whatever
    /// triangle density the shape stage happened to leave.
    ///
    /// The contour can only bend at mesh edges. Where triangles are large — the base of a
    /// windscreen, typically — that is far coarser than the painted stencil, and the cut
    /// polygonalises into teeth no matter how clean the field is. Splitting only the band the
    /// contour passes through costs a few thousand triangles instead of subdividing the car.
    ///
    /// Red-green refinement: triangles in the band split four ways, and their neighbours split
    /// to match so no vertex is left hanging in the middle of an edge.
    static func refine(vertices: [Float], normals: [Float], uvs: [Float], faces: [UInt32],
                       band: [Bool], onCurve: [Bool] = [])
        -> (vertices: [Float], normals: [Float], uvs: [Float], faces: [UInt32], parent: [Int],
            onCurve: [Bool]) {
        let m = faces.count / 3
        var splitEdge = Set<UInt64>()
        func key(_ a: Int, _ b: Int) -> UInt64 {
            a < b ? UInt64(a) << 32 | UInt64(b) : UInt64(b) << 32 | UInt64(a)
        }
        // Marked on welded indices so both sides of a UV seam agree that an edge is split.
        let welded = weldMap(vertices: vertices)
        for f in 0 ..< m where f < band.count && band[f] {
            let i = [Int(faces[f*3]), Int(faces[f*3+1]), Int(faces[f*3+2])]
            for e in 0 ..< 3 { splitEdge.insert(key(welded[i[e]], welded[i[(e+1) % 3]])) }
        }
        var curve = onCurve
        if curve.count < vertices.count / 3 {
            curve.append(contentsOf: [Bool](repeating: false,
                                            count: vertices.count / 3 - curve.count))
        }
        guard !splitEdge.isEmpty else {
            return (vertices, normals, uvs, faces, Array(0 ..< m), curve)
        }

        var outV = vertices, outN = normals, outU = uvs
        var mid = [UInt64: UInt32]()
        // Keyed on raw indices: two triangles across a UV seam need their own copies, or one
        // chart's UVs get forced on the other — the same trap as the cut itself.
        func midpoint(_ a: Int, _ b: Int) -> UInt32 {
            let k = key(a, b)
            if let v = mid[k] { return v }
            let idx = UInt32(outV.count / 3)
            for c in 0 ..< 3 {
                outV.append((vertices[a*3 + c] + vertices[b*3 + c]) / 2)
                outN.append((normals[a*3 + c] + normals[b*3 + c]) / 2)
            }
            for c in 0 ..< 2 { outU.append((uvs[a*2 + c] + uvs[b*2 + c]) / 2) }
            // Splitting a wall edge yields two wall edges: the new midpoint is on the curve too.
            curve.append(curve[a] && curve[b])
            mid[k] = idx
            return idx
        }

        var outF = [UInt32](), parent = [Int]()
        outF.reserveCapacity(faces.count * 2)
        func emit(_ a: UInt32, _ b: UInt32, _ c: UInt32, _ p: Int) {
            outF.append(a); outF.append(b); outF.append(c); parent.append(p)
        }
        for f in 0 ..< m {
            let i = [Int(faces[f*3]), Int(faces[f*3+1]), Int(faces[f*3+2])]
            let e = (0 ..< 3).map { splitEdge.contains(key(welded[i[$0]], welded[i[($0+1) % 3]])) }
            let count = e.filter { $0 }.count
            switch count {
            case 3:
                let ab = midpoint(i[0], i[1]), bc = midpoint(i[1], i[2]), ca = midpoint(i[2], i[0])
                emit(UInt32(i[0]), ab, ca, f); emit(ab, UInt32(i[1]), bc, f)
                emit(ca, bc, UInt32(i[2]), f); emit(ab, bc, ca, f)
            case 2:
                // Rotate so the unsplit edge is last.
                let r = e[0] && e[1] ? 0 : (e[1] && e[2] ? 1 : 2)
                let a = i[r], b = i[(r+1) % 3], c = i[(r+2) % 3]
                let ab = midpoint(a, b), bc = midpoint(b, c)
                emit(UInt32(a), ab, bc, f); emit(ab, UInt32(b), bc, f)
                emit(UInt32(a), bc, UInt32(c), f)
            case 1:
                let r = e[0] ? 0 : (e[1] ? 1 : 2)
                let a = i[r], b = i[(r+1) % 3], c = i[(r+2) % 3]
                let ab = midpoint(a, b)
                emit(UInt32(a), ab, UInt32(c), f); emit(ab, UInt32(b), UInt32(c), f)
            default:
                emit(UInt32(i[0]), UInt32(i[1]), UInt32(i[2]), f)
            }
        }
        return (outV, outN, outU, outF, parent, curve)
    }

    // MARK: - undo

    static func backupURL(forMesh mesh: URL) -> URL {
        mesh.deletingPathExtension().appendingPathExtension("precut.tmesh")
    }

    static func hasBackup(forMesh mesh: URL) -> Bool {
        FileManager.default.fileExists(atPath: backupURL(forMesh: mesh).path)
    }

    /// Put back the uncut mesh.
    ///
    /// The glass and erase masks are face-indexed and the cut renumbered every face, so they are
    /// dropped rather than restored: a mask left over from the cut mesh would silently select the
    /// wrong triangles on the original, which is worse than selecting none.
    static func revert(mesh: URL) -> Bool {
        let backup = backupURL(forMesh: mesh)
        guard FileManager.default.fileExists(atPath: backup.path) else { return false }
        try? FileManager.default.removeItem(at: mesh)
        do { try FileManager.default.copyItem(at: backup, to: mesh) } catch { return false }
        try? FileManager.default.removeItem(at: backup)
        GlassSelection.clear(forMesh: mesh)
        MeshEraser.clear(forMesh: mesh)
        return true
    }

    // MARK: - tmesh io

    static func loadFull(_ url: URL) -> (vertices: [Float], normals: [Float],
                                         uvs: [Float], faces: [UInt32])? {
        guard let d = try? Data(contentsOf: url), d.count > 8 else { return nil }
        let n = Int(d.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 0, as: Int32.self) })
        let m = Int(d.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 4, as: Int32.self) })
        guard n > 0, m > 0, d.count >= 8 + n*12 + n*12 + n*8 + m*12 else { return nil }
        var v = [Float](repeating: 0, count: n*3), nm = [Float](repeating: 0, count: n*3)
        var uv = [Float](repeating: 0, count: n*2), f = [UInt32](repeating: 0, count: m*3)
        d.withUnsafeBytes { raw in
            for i in 0 ..< n*3 { v[i] = raw.loadUnaligned(fromByteOffset: 8 + i*4, as: Float.self) }
            for i in 0 ..< n*3 { nm[i] = raw.loadUnaligned(fromByteOffset: 8 + n*12 + i*4, as: Float.self) }
            let uo = 8 + n*12 + n*12
            for i in 0 ..< n*2 { uv[i] = raw.loadUnaligned(fromByteOffset: uo + i*4, as: Float.self) }
            let fo = uo + n*8
            for i in 0 ..< m*3 { f[i] = raw.loadUnaligned(fromByteOffset: fo + i*4, as: UInt32.self) }
        }
        return (v, nm, uv, f)
    }

    static func save(vertices: [Float], normals: [Float], uvs: [Float], faces: [UInt32],
                     to url: URL) -> Bool {
        var d = Data()
        var n = Int32(vertices.count / 3), m = Int32(faces.count / 3)
        withUnsafeBytes(of: &n) { d.append(contentsOf: $0) }
        withUnsafeBytes(of: &m) { d.append(contentsOf: $0) }
        vertices.withUnsafeBufferPointer { d.append(contentsOf: UnsafeRawBufferPointer($0)) }
        normals.withUnsafeBufferPointer { d.append(contentsOf: UnsafeRawBufferPointer($0)) }
        uvs.withUnsafeBufferPointer { d.append(contentsOf: UnsafeRawBufferPointer($0)) }
        faces.withUnsafeBufferPointer { d.append(contentsOf: UnsafeRawBufferPointer($0)) }
        do { try d.write(to: url); return true } catch { return false }
    }

    /// Vertex index -> representative index for the same point in space.
    static func weldMap(vertices: [Float]) -> [Int] {
        let count = vertices.count / 3
        var lo = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
        var hi = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
        for i in 0 ..< count {
            let v = SIMD3(vertices[i*3], vertices[i*3+1], vertices[i*3+2])
            lo = simd_min(lo, v); hi = simd_max(hi, v)
        }
        let q = max(simd_length(hi - lo) * 1e-5, 1e-9)
        var map = [Int](repeating: 0, count: count)
        var seen = [SIMD3<Int32>: Int]()
        seen.reserveCapacity(count)
        for i in 0 ..< count {
            let key = SIMD3<Int32>(Int32((vertices[i*3]   / q).rounded()),
                                   Int32((vertices[i*3+1] / q).rounded()),
                                   Int32((vertices[i*3+2] / q).rounded()))
            if let r = seen[key] { map[i] = r } else { seen[key] = i; map[i] = i }
        }
        return map
    }
}
