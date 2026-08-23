import Foundation
import simd

/// A real UV unwrap: large charts with shared texels, not one square per triangle.
///
/// The per-triangle layout was quick and is fundamentally noisy. Neighbouring triangles share no
/// texels, so at any distance each screen pixel lands in a different isolated patch and the paint
/// shimmers; mip levels only average unrelated cells together and make a lattice instead. Filtering
/// cannot fix a layout with no continuity in it.
///
/// This groups faces by the view that faces them most squarely, splits each group into connected
/// pieces, and lays each piece out by its projection into that view. Within a piece the layout is
/// exactly the sheet's own — neighbouring triangles share edges and therefore texels — so the
/// paint is continuous and minifies properly. Seams exist only where the owning view changes,
/// which is the same place the sheets themselves disagree.
enum ChartUnwrap {

    struct Result {
        var vertices: [Float]
        var normals: [Float]
        var uvs: [Float]
        var faces: [UInt32]
        var parent: [Int]          // which original face each new face came from
        var charts: Int
        var atlas: Int
    }

    static func unwrap(vertices: [Float], normals: [Float], faces: [UInt32],
                       atlas: Int = 8192, padding: Int = 2) -> Result? {
        let n = vertices.count / 3, m = faces.count / 3
        guard n > 0, m > 0 else { return nil }

        let p = SheetStencil.normalised(vertices)
        let vn = SheetStencil.viewNormals(normals)
        let viewCount = SheetStencil.elevs.count
        var bases = [(SIMD3<Float>, SIMD3<Float>, SIMD3<Float>, SIMD3<Float>)]()
        for v in 0 ..< viewCount {
            bases.append(SheetStencil.basis(elev: SheetStencil.elevs[v],
                                            azim: SheetStencil.azims[v], dist: 1.45))
        }

        // Which view owns each face. Same sign convention as the bake: the map into this frame is
        // a reflection, so a face looking at a camera has a negative dot with its forward.
        var owner = [Int](repeating: 0, count: m)
        for f in 0 ..< m {
            var nrm = vn[Int(faces[f*3])] + vn[Int(faces[f*3+1])] + vn[Int(faces[f*3+2])]
            nrm = simd_length(nrm) > 1e-12 ? simd_normalize(nrm) : SIMD3(0, 0, 1)
            var best = -Float.greatestFiniteMagnitude
            for v in 0 ..< viewCount {
                let d = -simd_dot(nrm, bases[v].2)
                if d > best { best = d; owner[f] = v }
            }
        }

        // Connected pieces within each view — a chart may not span a fold the projection cannot
        // represent, and two parts of the car facing the same way must not overlap in the atlas.
        let welded = MeshCut.weldMap(vertices: vertices)
        var edgeFaces = [UInt64: [Int]]()
        edgeFaces.reserveCapacity(m * 3)
        for f in 0 ..< m {
            let v = [welded[Int(faces[f*3])], welded[Int(faces[f*3+1])], welded[Int(faces[f*3+2])]]
            for e in 0 ..< 3 {
                let a = v[e], b = v[(e + 1) % 3]
                let k = a < b ? UInt64(a) << 32 | UInt64(b) : UInt64(b) << 32 | UInt64(a)
                edgeFaces[k, default: []].append(f)
            }
        }
        var adjacency = [[Int]](repeating: [], count: m)
        for (_, fs) in edgeFaces where fs.count == 2 {
            if owner[fs[0]] == owner[fs[1]] {
                adjacency[fs[0]].append(fs[1]); adjacency[fs[1]].append(fs[0])
            }
        }
        var chartOf = [Int](repeating: -1, count: m)
        var chartFaces = [[Int]]()
        for f in 0 ..< m where chartOf[f] < 0 {
            let id = chartFaces.count
            var stack = [f], members = [Int]()
            chartOf[f] = id
            while let x = stack.popLast() {
                members.append(x)
                for y in adjacency[x] where chartOf[y] < 0 { chartOf[y] = id; stack.append(y) }
            }
            chartFaces.append(members)
        }

        // Each chart's own 2D layout: its faces projected into its view, in pixels.
        // First pass: measure each chart's bounding box in projected space.
        struct Chart { var w: Int; var h: Int; var lo: SIMD2<Float>; var scale: Float; var id: Int }
        struct ChartProj { var map: [Int: SIMD2<Float>]; var lo: SIMD2<Float>; var hi: SIMD2<Float>; var view: Int }
        var projs = [ChartProj]()
        for (id, members) in chartFaces.enumerated() {
            let v = owner[members[0]]
            let (right, up, _, eye) = bases[v]
            var map = [Int: SIMD2<Float>]()
            var lo = SIMD2<Float>(repeating: .greatestFiniteMagnitude)
            var hi = SIMD2<Float>(repeating: -.greatestFiniteMagnitude)
            for f in members {
                for k in 0 ..< 3 {
                    let i = Int(faces[f*3 + k])
                    if map[i] == nil {
                        let d = p[i] - eye
                        let q = SIMD2(simd_dot(d, right), simd_dot(d, up))
                        map[i] = q
                        lo = simd_min(lo, q); hi = simd_max(hi, q)
                    }
                }
            }
            projs.append(ChartProj(map: map, lo: lo, hi: hi, view: v))
        }

        // Binary search for the largest scale that packs into the atlas.
        func tryPack(_ scale: Float) -> (charts: [Chart], placement: [Int: SIMD2<Int>])? {
            var charts = [Chart]()
            for (id, proj) in projs.enumerated() {
                let w = max(1, Int(((proj.hi.x - proj.lo.x) * scale).rounded(.up))) + padding * 2
                let h = max(1, Int(((proj.hi.y - proj.lo.y) * scale).rounded(.up))) + padding * 2
                if w > atlas || h > atlas { return nil }
                charts.append(Chart(w: w, h: h, lo: proj.lo, scale: scale, id: id))
            }
            let order = charts.indices.sorted { charts[$0].h > charts[$1].h }
            var originX = 0, originY = 0, shelfH = 0
            var placement = [Int: SIMD2<Int>]()
            for idx in order {
                let c = charts[idx]
                if originX + c.w > atlas { originX = 0; originY += shelfH; shelfH = 0 }
                if originY + c.h > atlas { return nil }
                placement[idx] = SIMD2(originX, originY)
                originX += c.w
                shelfH = max(shelfH, c.h)
            }
            return (charts, placement)
        }

        let idealScale = Float(atlas) / 1.6
        var bestScale = idealScale
        var packed = tryPack(bestScale)
        if packed == nil {
            var lo: Float = 1, hi = bestScale
            for _ in 0 ..< 20 {
                let mid = (lo + hi) / 2
                if tryPack(mid) != nil { lo = mid } else { hi = mid }
            }
            bestScale = lo
            packed = tryPack(bestScale)
        }
        guard let (charts, placement) = packed else { return nil }
        print(String(format: "  chart scale: %.0f (ideal %.0f), %d charts", bestScale, idealScale, charts.count))
        var chartUV = [[Int: SIMD2<Float>]]()
        for proj in projs { chartUV.append(proj.map) }

        // Emit: vertices duplicated per chart, since a vertex on a chart border belongs to both.
        var outV = [Float](), outN = [Float](), outU = [Float](), outF = [UInt32]()
        var parent = [Int]()
        for (idx, c) in charts.enumerated() {
            guard let at = placement[idx] else { continue }
            var index = [Int: UInt32]()
            for f in chartFaces[c.id] {
                for k in 0 ..< 3 {
                    let i = Int(faces[f*3 + k])
                    if index[i] == nil {
                        let q = chartUV[idx][i]!
                        let x = Float(at.x + padding) + (q.x - c.lo.x) * c.scale
                        let y = Float(at.y + padding) + (q.y - c.lo.y) * c.scale
                        index[i] = UInt32(outV.count / 3)
                        outV.append(vertices[i*3]); outV.append(vertices[i*3+1])
                        outV.append(vertices[i*3+2])
                        outN.append(normals[i*3]); outN.append(normals[i*3+1])
                        outN.append(normals[i*3+2])
                        outU.append(x / Float(atlas)); outU.append(y / Float(atlas))
                    }
                }
                outF.append(index[Int(faces[f*3])]!)
                outF.append(index[Int(faces[f*3+1])]!)
                outF.append(index[Int(faces[f*3+2])]!)
                parent.append(f)
            }
        }
        return Result(vertices: outV, normals: outN, uvs: outU, faces: outF,
                      parent: parent, charts: charts.count, atlas: atlas)
    }
}
