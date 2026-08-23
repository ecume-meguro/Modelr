import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import simd

/// Give the new mesh its own atlas, and fill it from the paint that already exists.
///
/// Borrowing the original's UVs never really works: that atlas is laid out for a different mesh,
/// in thousands of scraps, and any transfer either crosses a chart boundary or has to pin whole
/// triangles to single charts and lose sub-triangle detail. The new mesh is uniform, so it can
/// have the simplest possible layout instead — one small square per triangle, in a grid.
///
/// Nothing is inferred: each texel of that square is a point on a known triangle, so its position
/// in space is known exactly, and its colour is whatever the original surface has at the nearest
/// point. The result is a proper atlas for this mesh, carrying the paint the pipeline already
/// produced.
enum SkinBake {

    struct Baked {
        let uvs: [Float]
        let texture: URL
        let size: Int
        let cell: Int
    }

    /// Fill a chart atlas by rasterising every face into it.
    ///
    /// Unlike the per-triangle layout, neighbouring faces here share texels, so the result
    /// minifies properly and mip levels average things that genuinely belong together. Each texel
    /// covered by a face knows its own 3D position from the face's barycentric coordinates, and
    /// takes its colour from the views that can see that point.
    static func bakeCharts(vertices: [Float], normals: [Float], uvs: [Float], faces: [UInt32],
                           sheet: URL, atlas: Int, to output: URL, gutter: Int = 4) -> URL? {
        guard let src = loadRGBA(sheet) else { return nil }
        let tile = src.h, views = min(src.w / src.h, SheetStencil.elevs.count)
        guard views >= 4 else { return nil }

        let p = SheetStencil.normalised(vertices)
        let vn = SheetStencil.viewNormals(normals)
        var bases = [(SIMD3<Float>, SIMD3<Float>, SIMD3<Float>, SIMD3<Float>)]()
        var depths = [[Float]]()
        for v in 0 ..< views {
            let b = SheetStencil.basis(elev: SheetStencil.elevs[v], azim: SheetStencil.azims[v],
                                       dist: 1.45)
            bases.append(b)
            var proj = [SIMD3<Float>](repeating: .zero, count: p.count)
            for i in 0 ..< p.count {
                let d = p[i] - b.3
                proj[i] = SIMD3((simd_dot(d, b.0) / 0.6 * 0.5 + 0.5) * Float(tile - 1),
                                (simd_dot(d, b.1) / 0.6 * 0.5 + 0.5) * Float(tile - 1),
                                simd_dot(d, b.2))
            }
            var depth = [Float](repeating: -.greatestFiniteMagnitude, count: tile * tile)
            MeshClip.rasterise(proj, faces: faces, w: tile, h: tile, into: &depth)
            depths.append(depth)
        }

        var px = [UInt8](repeating: 0, count: atlas * atlas * 4)
        var covered = [Bool](repeating: false, count: atlas * atlas)

        func shade(_ q: SIMD3<Float>, _ nrm: SIMD3<Float>) -> SIMD3<Float>? {
            var acc = SIMD3<Float>.zero
            var total: Float = 0
            for vi in 0 ..< views {
                let (right, up, fwd, eye) = bases[vi]
                let facing = -simd_dot(nrm, fwd)
                guard facing > 0.05 else { continue }
                let d = q - eye
                let sx = (simd_dot(d, right) / 0.6 * 0.5 + 0.5) * Float(tile - 1)
                let sy = (simd_dot(d, up) / 0.6 * 0.5 + 0.5) * Float(tile - 1)
                let xi = Int(sx.rounded()), yi = Int(sy.rounded())
                guard xi >= 0, xi < tile, yi >= 0, yi < tile else { continue }
                guard simd_dot(d, fwd) >= depths[vi][yi * tile + xi] - 0.03 else { continue }
                let w = facing * facing
                let si = ((yi * src.w) + vi * tile + xi) * 4
                acc += SIMD3(Float(src.px[si]), Float(src.px[si+1]), Float(src.px[si+2])) * w
                total += w
            }
            return total > 0 ? acc / total : nil
        }

        for f in 0 ..< (faces.count / 3) {
            let i0 = Int(faces[f*3]), i1 = Int(faces[f*3+1]), i2 = Int(faces[f*3+2])
            let a2 = SIMD2(uvs[i0*2] * Float(atlas), uvs[i0*2+1] * Float(atlas))
            let b2 = SIMD2(uvs[i1*2] * Float(atlas), uvs[i1*2+1] * Float(atlas))
            let c2 = SIMD2(uvs[i2*2] * Float(atlas), uvs[i2*2+1] * Float(atlas))
            let minX = max(Int(min(a2.x, b2.x, c2.x)) - 1, 0)
            let maxX = min(Int(max(a2.x, b2.x, c2.x)) + 1, atlas - 1)
            let minY = max(Int(min(a2.y, b2.y, c2.y)) - 1, 0)
            let maxY = min(Int(max(a2.y, b2.y, c2.y)) + 1, atlas - 1)
            guard minX <= maxX, minY <= maxY else { continue }
            let area = (b2.x - a2.x) * (c2.y - a2.y) - (b2.y - a2.y) * (c2.x - a2.x)
            guard abs(area) > 1e-9 else { continue }
            let nrm = simd_normalize(vn[i0] + vn[i1] + vn[i2])
            for y in minY ... maxY {
                for x in minX ... maxX {
                    let q2 = SIMD2(Float(x) + 0.5, Float(y) + 0.5)
                    var w0 = ((b2.x - a2.x) * (q2.y - a2.y) - (b2.y - a2.y) * (q2.x - a2.x)) / area
                    var w1 = ((c2.x - b2.x) * (q2.y - b2.y) - (c2.y - b2.y) * (q2.x - b2.x)) / area
                    // A little tolerance so the seam between two faces has no unpainted row.
                    guard w0 > -0.02, w1 > -0.02, w0 + w1 < 1.02 else { continue }
                    w0 = min(max(w0, 0), 1); w1 = min(max(w1, 0), 1)
                    let w2 = max(0, 1 - w0 - w1)
                    let q = p[i0] * w2 + p[i1] * w0 + p[i2] * w1
                    guard let colour = shade(q, nrm) else { continue }
                    let di = (y * atlas + x) * 4
                    px[di] = UInt8(min(max(colour.x, 0), 255))
                    px[di+1] = UInt8(min(max(colour.y, 0), 255))
                    px[di+2] = UInt8(min(max(colour.z, 0), 255))
                    px[di+3] = 255
                    covered[y * atlas + x] = true
                }
            }
        }

        // Spread the edge colours outward, so filtering at a chart's border never reaches into
        // empty atlas and darkens the seam.
        for _ in 0 ..< gutter {
            var next = covered
            for y in 0 ..< atlas {
                for x in 0 ..< atlas where !covered[y * atlas + x] {
                    var acc = SIMD3<Float>.zero
                    var count: Float = 0
                    for (dx, dy) in [(1,0), (-1,0), (0,1), (0,-1)] {
                        let nx = x + dx, ny = y + dy
                        guard nx >= 0, nx < atlas, ny >= 0, ny < atlas,
                              covered[ny * atlas + nx] else { continue }
                        let si = (ny * atlas + nx) * 4
                        acc += SIMD3(Float(px[si]), Float(px[si+1]), Float(px[si+2]))
                        count += 1
                    }
                    guard count > 0 else { continue }
                    let c = acc / count
                    let di = (y * atlas + x) * 4
                    px[di] = UInt8(c.x); px[di+1] = UInt8(c.y); px[di+2] = UInt8(c.z); px[di+3] = 255
                    next[y * atlas + x] = true
                }
            }
            covered = next
        }

        return write(px, atlas, atlas, to: output) ? output : nil
    }

    /// Bake the chart atlas straight from the user's (flat) albedo sheet, each chart taking its
    /// colour from a SINGLE owning view — never a blend of several.
    ///
    /// This is the reskin's "use my albedo only, no repaint" path. The multi-view blend in
    /// `bakeCharts`/the pipeline re-bake is what put wipers back on the car: the near-horizontal
    /// cowl at the base of the windshield is grazing in every view, so with a loose depth test
    /// the dark window-surround from a side/rear view bleeds down onto the body as wiper-shaped
    /// fingers. Projecting each face through only the view that faces it most squarely — and only
    /// among the front/side/rear ring, never the top or bottom — removes both the bleed and the
    /// cross-hatching, and reproduces exactly what the sheet draws with nothing invented.
    ///
    /// `views` are the sheet-tile indices allowed to own a face: the elev-0 ring
    /// [0,1,2,3] = front, right, rear, left, plus the BOTTOM tile (5) so the car's underside is
    /// covered instead of left transparent. The TOP tile (4) is deliberately left out: including
    /// it let the overhead view win on roof-edge and rear-deck faces where its projection is
    /// grazing, which speckled the window borders and put stray transparency at the rear. Bottom
    /// is safe because only genuinely down-facing floor faces can ever pick it.
    static func bakeChartsFromSheetOwner(
        vertices: [Float], normals: [Float], uvs: [Float], faces: [UInt32],
        sheet: URL, atlas: Int, to output: URL, gutter: Int = 4,
        views allowed: [Int] = [0, 1, 2, 3, 5]
    ) -> URL? {
        guard let src = loadRGBA(sheet) else { return nil }
        let tile = src.h
        let available = min(src.w / src.h, SheetStencil.elevs.count)
        let views = allowed.filter { $0 < available }
        guard views.count >= 3 else { return nil }

        let p = SheetStencil.normalised(vertices)
        let vn = SheetStencil.viewNormals(normals)

        // Camera basis and a depth buffer per allowed view, so a point occluded in the view that
        // faces it can be rejected and handed to the next-best view instead of taking a colour
        // off the surface in front of it.
        var right = [SIMD3<Float>](), up = [SIMD3<Float>](), fwd = [SIMD3<Float>](), eye = [SIMD3<Float>]()
        var depths = [[Float]]()
        for v in views {
            let b = SheetStencil.basis(elev: SheetStencil.elevs[v], azim: SheetStencil.azims[v],
                                       dist: 1.45)
            right.append(b.0); up.append(b.1); fwd.append(b.2); eye.append(b.3)
            var proj = [SIMD3<Float>](repeating: .zero, count: p.count)
            for i in 0 ..< p.count {
                let d = p[i] - b.3
                proj[i] = SIMD3((simd_dot(d, b.0) / 0.6 * 0.5 + 0.5) * Float(tile - 1),
                                (simd_dot(d, b.1) / 0.6 * 0.5 + 0.5) * Float(tile - 1),
                                simd_dot(d, b.2))
            }
            var depth = [Float](repeating: -.greatestFiniteMagnitude, count: tile * tile)
            MeshClip.rasterise(proj, faces: faces, w: tile, h: tile, into: &depth)
            depths.append(depth)
        }

        // Sample `q` (with surface normal `nrm`) from the allowed views in order of how squarely
        // each faces it, taking the FIRST that both sees the point (facing > 0) and passes the
        // depth test. No blending: the winning view's pixel is the answer.
        func sample(_ q: SIMD3<Float>, _ nrm: SIMD3<Float>) -> SIMD3<Float>? {
            let order = views.indices.sorted { -simd_dot(nrm, fwd[$0]) > -simd_dot(nrm, fwd[$1]) }
            for vi in order {
                guard -simd_dot(nrm, fwd[vi]) > 0.02 else { continue }
                let d = q - eye[vi]
                let sx = (simd_dot(d, right[vi]) / 0.6 * 0.5 + 0.5) * Float(tile - 1)
                let sy = (simd_dot(d, up[vi]) / 0.6 * 0.5 + 0.5) * Float(tile - 1)
                let xi = Int(sx.rounded()), yi = Int(sy.rounded())
                guard xi >= 0, xi < tile, yi >= 0, yi < tile else { continue }
                guard simd_dot(d, fwd[vi]) >= depths[vi][yi * tile + xi] - 0.03 else { continue }
                let si = ((yi * src.w) + views[vi] * tile + xi) * 4
                return SIMD3(Float(src.px[si]), Float(src.px[si+1]), Float(src.px[si+2]))
            }
            return nil
        }

        var px = [UInt8](repeating: 0, count: atlas * atlas * 4)
        var covered = [Bool](repeating: false, count: atlas * atlas)

        for f in 0 ..< (faces.count / 3) {
            let i0 = Int(faces[f*3]), i1 = Int(faces[f*3+1]), i2 = Int(faces[f*3+2])
            let a2 = SIMD2(uvs[i0*2] * Float(atlas), uvs[i0*2+1] * Float(atlas))
            let b2 = SIMD2(uvs[i1*2] * Float(atlas), uvs[i1*2+1] * Float(atlas))
            let c2 = SIMD2(uvs[i2*2] * Float(atlas), uvs[i2*2+1] * Float(atlas))
            let minX = max(Int(min(a2.x, b2.x, c2.x)) - 1, 0)
            let maxX = min(Int(max(a2.x, b2.x, c2.x)) + 1, atlas - 1)
            let minY = max(Int(min(a2.y, b2.y, c2.y)) - 1, 0)
            let maxY = min(Int(max(a2.y, b2.y, c2.y)) + 1, atlas - 1)
            guard minX <= maxX, minY <= maxY else { continue }
            let area = (b2.x - a2.x) * (c2.y - a2.y) - (b2.y - a2.y) * (c2.x - a2.x)
            guard abs(area) > 1e-9 else { continue }
            let nrm = simd_normalize(vn[i0] + vn[i1] + vn[i2])
            for y in minY ... maxY {
                for x in minX ... maxX {
                    let q2 = SIMD2(Float(x) + 0.5, Float(y) + 0.5)
                    var w0 = ((b2.x - a2.x) * (q2.y - a2.y) - (b2.y - a2.y) * (q2.x - a2.x)) / area
                    var w1 = ((c2.x - b2.x) * (q2.y - b2.y) - (c2.y - b2.y) * (q2.x - b2.x)) / area
                    guard w0 > -0.02, w1 > -0.02, w0 + w1 < 1.02 else { continue }
                    w0 = min(max(w0, 0), 1); w1 = min(max(w1, 0), 1)
                    let w2 = max(0, 1 - w0 - w1)
                    let q = p[i0] * w2 + p[i1] * w0 + p[i2] * w1
                    guard let colour = sample(q, nrm) else { continue }
                    let di = (y * atlas + x) * 4
                    px[di] = UInt8(min(max(colour.x, 0), 255))
                    px[di+1] = UInt8(min(max(colour.y, 0), 255))
                    px[di+2] = UInt8(min(max(colour.z, 0), 255))
                    px[di+3] = 255
                    covered[y * atlas + x] = true
                }
            }
        }

        // Spread edge colours outward so filtering at a chart border never reaches empty atlas.
        for _ in 0 ..< gutter {
            var next = covered
            for y in 0 ..< atlas {
                for x in 0 ..< atlas where !covered[y * atlas + x] {
                    var acc = SIMD3<Float>.zero; var count: Float = 0
                    for (dx, dy) in [(1,0), (-1,0), (0,1), (0,-1)] {
                        let nx = x + dx, ny = y + dy
                        guard nx >= 0, nx < atlas, ny >= 0, ny < atlas,
                              covered[ny * atlas + nx] else { continue }
                        let si = (ny * atlas + nx) * 4
                        acc += SIMD3(Float(px[si]), Float(px[si+1]), Float(px[si+2]))
                        count += 1
                    }
                    guard count > 0 else { continue }
                    let clr = acc / count
                    let di = (y * atlas + x) * 4
                    px[di] = UInt8(clr.x); px[di+1] = UInt8(clr.y); px[di+2] = UInt8(clr.z); px[di+3] = 255
                    next[y * atlas + x] = true
                }
            }
            covered = next
        }

        return write(px, atlas, atlas, to: output) ? output : nil
    }

    /// Bake straight from the view sheets, rather than copying the original atlas.
    ///
    /// Resampling the atlas is a copy of a copy: the paint was already projected once into that
    /// layout, and reading it back at points that do not line up with its texels loses a little
    /// more each time. The sheets are the original renders, so a texel can be projected into the
    /// views that see it and blended there — the same thing the pipeline's own bake does. Facing
    /// weight decides the blend, a depth test rejects views that cannot see the point, and the
    /// result is the paint at first hand.
    static func bakeFromSheets(vertices: [Float], normals: [Float], faces: [UInt32],
                               sheet: URL, to output: URL,
                               atlas: Int = 8192, cell: Int = 16) -> Baked? {
        let n = faces.count / 3
        var cell = cell
        while cell > 4 && (atlas / cell) * (atlas / cell) < n { cell -= 1 }
        let perRow = atlas / cell
        guard perRow * perRow >= n, let src = loadRGBA(sheet) else { return nil }
        let tile = src.h, views = min(src.w / src.h, SheetStencil.elevs.count)
        guard views >= 4 else { return nil }

        var uvs = [Float](repeating: 0, count: n * 3 * 2)
        let inset: Float = 0.75
        for f in 0 ..< n {
            let cx = Float((f % perRow) * cell), cy = Float((f / perRow) * cell)
            let corners: [SIMD2<Float>] = [SIMD2(cx + inset, cy + inset),
                                           SIMD2(cx + Float(cell) - inset, cy + inset),
                                           SIMD2(cx + inset, cy + Float(cell) - inset)]
            for k in 0 ..< 3 {
                uvs[(f*3 + k) * 2]     = corners[k].x / Float(atlas)
                uvs[(f*3 + k) * 2 + 1] = corners[k].y / Float(atlas)
            }
        }

        // The mesh in the renderer's frame, and a depth buffer per view so a texel on the far
        // side of the car is not painted with what the near side shows.
        let p = SheetStencil.normalised(vertices)
        let vn = SheetStencil.viewNormals(normals)
        var bases = [(SIMD3<Float>, SIMD3<Float>, SIMD3<Float>, SIMD3<Float>)]()
        var depths = [[Float]]()
        for v in 0 ..< views {
            let b = SheetStencil.basis(elev: SheetStencil.elevs[v], azim: SheetStencil.azims[v],
                                       dist: 1.45)
            bases.append(b)
            var proj = [SIMD3<Float>](repeating: .zero, count: p.count)
            for i in 0 ..< p.count {
                let d = p[i] - b.3
                proj[i] = SIMD3((simd_dot(d, b.0) / 0.6 * 0.5 + 0.5) * Float(tile - 1),
                                (simd_dot(d, b.1) / 0.6 * 0.5 + 0.5) * Float(tile - 1),
                                simd_dot(d, b.2))
            }
            var depth = [Float](repeating: -.greatestFiniteMagnitude, count: tile * tile)
            MeshClip.rasterise(proj, faces: faces, w: tile, h: tile, into: &depth)
            depths.append(depth)
        }

        var px = [UInt8](repeating: 0, count: atlas * atlas * 4)
        for f in 0 ..< n {
            let i0 = Int(faces[f*3]), i1 = Int(faces[f*3+1]), i2 = Int(faces[f*3+2])
            let a = p[i0], b = p[i1], c = p[i2]
            var nrm = vn[i0] + vn[i1] + vn[i2]
            nrm = simd_length(nrm) > 1e-12 ? simd_normalize(nrm) : SIMD3(0, 0, 1)
            let cx = (f % perRow) * cell, cy = (f / perRow) * cell
            for ty in 0 ..< cell {
                for tx in 0 ..< cell {
                    var u = (Float(tx) + 0.5 - inset) / (Float(cell) - 2 * inset)
                    var v = (Float(ty) + 0.5 - inset) / (Float(cell) - 2 * inset)
                    if u + v > 1 { u = 1 - u; v = 1 - v }
                    u = min(max(u, 0), 1); v = min(max(v, 0), 1)
                    let w = max(0, 1 - u - v)
                    let q = a * w + b * u + c * v

                    var acc = SIMD3<Float>.zero
                    var total: Float = 0
                    for vi in 0 ..< views {
                        let (right, up, fwd, eye) = bases[vi]
                        // Negative, because the map into this frame is a reflection and turns a
                        // normal inside out. Verified by result rather than by argument: with the
                        // other sign only grazing silhouette faces found any view at all and the
                        // car came out the background's grey.
                        let facing = -simd_dot(nrm, fwd)
                        guard facing > 0.05 else { continue }
                        let d = q - eye
                        let sx = (simd_dot(d, right) / 0.6 * 0.5 + 0.5) * Float(tile - 1)
                        let sy = (simd_dot(d, up) / 0.6 * 0.5 + 0.5) * Float(tile - 1)
                        // No row flip: the loaded sheet buffer already runs the same way the
                        // projection measures. Flipping it painted the car with the row mirrored
                        // about its middle, which reads as the paint sliding off the geometry.
                        let xi = Int(sx.rounded()), yi = Int(sy.rounded())
                        guard xi >= 0, xi < tile, yi >= 0, yi < tile else { continue }
                        // Anything meaningfully behind the nearest surface in this view is
                        // looking at the wrong side of the car.
                        guard simd_dot(d, fwd) >= depths[vi][yi * tile + xi] - 0.03 else { continue }
                        let weight = facing * facing        // squared: the squarest view leads
                        let si = ((yi * src.w) + vi * tile + xi) * 4
                        acc += SIMD3(Float(src.px[si]), Float(src.px[si+1]), Float(src.px[si+2]))
                             * weight
                        total += weight
                    }
                    let colour = total > 0 ? acc / total : SIMD3<Float>(128, 128, 128)
                    let di = ((cy + ty) * atlas + (cx + tx)) * 4
                    px[di] = UInt8(min(max(colour.x, 0), 255))
                    px[di+1] = UInt8(min(max(colour.y, 0), 255))
                    px[di+2] = UInt8(min(max(colour.z, 0), 255))
                    px[di+3] = 255
                }
            }
        }
        guard write(px, atlas, atlas, to: output) else { return nil }
        return Baked(uvs: uvs, texture: output, size: atlas, cell: cell)
    }

    /// Chart UVs + original atlas color. No shimmer (chart UVs share texels across triangles),
    /// no distortion (colors come from the original paint, not re-projected views).
    static func bakeChartsFromOriginal(
        vertices: [Float], normals: [Float], uvs: [Float], faces: [UInt32],
        original: (vertices: [Float], normals: [Float], uvs: [Float], faces: [UInt32]),
        originalTexture: URL, atlas: Int, to output: URL, gutter: Int = 4
    ) -> URL? {
        guard let src = loadRGBA(originalTexture) else { return nil }

        let m = original.faces.count / 3
        var lo = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
        var hi = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
        for i in 0 ..< (original.vertices.count / 3) {
            let q = SIMD3(original.vertices[i*3], original.vertices[i*3+1], original.vertices[i*3+2])
            lo = simd_min(lo, q); hi = simd_max(hi, q)
        }
        let gcell = max((hi - lo).max() / 160, 1e-5)
        func key(_ p: SIMD3<Float>) -> Int {
            let a = Int(floor(p.x / gcell)), b = Int(floor(p.y / gcell)), c = Int(floor(p.z / gcell))
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
            buckets[key(c / 3), default: []].append(f)
        }

        func sampleOriginal(_ p: SIMD3<Float>) -> SIMD3<Float> {
            var best = Float.greatestFiniteMagnitude
            var uv = SIMD2<Float>(0, 0)
            for radius in 1 ... 4 {
                for dx in -radius ... radius {
                    for dy in -radius ... radius {
                        for dz in -radius ... radius {
                            let probe = p + SIMD3(Float(dx), Float(dy), Float(dz)) * gcell
                            for g in buckets[key(probe)] ?? [] {
                                let j0 = Int(original.faces[g*3])
                                let j1 = Int(original.faces[g*3+1])
                                let j2 = Int(original.faces[g*3+2])
                                let qa = SIMD3(original.vertices[j0*3], original.vertices[j0*3+1],
                                               original.vertices[j0*3+2])
                                let qb = SIMD3(original.vertices[j1*3], original.vertices[j1*3+1],
                                               original.vertices[j1*3+2])
                                let qc = SIMD3(original.vertices[j2*3], original.vertices[j2*3+1],
                                               original.vertices[j2*3+2])
                                let (d, bary) = GlassPatch.closestPublic(p, qa, qb, qc)
                                if d < best {
                                    best = d
                                    uv = SIMD2(original.uvs[j0*2], original.uvs[j0*2+1]) * bary.x
                                       + SIMD2(original.uvs[j1*2], original.uvs[j1*2+1]) * bary.y
                                       + SIMD2(original.uvs[j2*2], original.uvs[j2*2+1]) * bary.z
                                }
                            }
                        }
                    }
                }
                if best < .greatestFiniteMagnitude { break }
            }
            let sx = min(max(Int(uv.x * Float(src.w - 1)), 0), src.w - 1)
            let sy = min(max(Int(uv.y * Float(src.h - 1)), 0), src.h - 1)
            let si = (sy * src.w + sx) * 4
            return SIMD3(Float(src.px[si]), Float(src.px[si+1]), Float(src.px[si+2]))
        }

        var px = [UInt8](repeating: 0, count: atlas * atlas * 4)
        var covered = [Bool](repeating: false, count: atlas * atlas)
        let fc = faces.count / 3
        for f in 0 ..< fc {
            let i0 = Int(faces[f*3]), i1 = Int(faces[f*3+1]), i2 = Int(faces[f*3+2])
            let a2 = SIMD2(uvs[i0*2] * Float(atlas), uvs[i0*2+1] * Float(atlas))
            let b2 = SIMD2(uvs[i1*2] * Float(atlas), uvs[i1*2+1] * Float(atlas))
            let c2 = SIMD2(uvs[i2*2] * Float(atlas), uvs[i2*2+1] * Float(atlas))
            let minX = max(Int(min(a2.x, b2.x, c2.x)) - 1, 0)
            let maxX = min(Int(max(a2.x, b2.x, c2.x)) + 1, atlas - 1)
            let minY = max(Int(min(a2.y, b2.y, c2.y)) - 1, 0)
            let maxY = min(Int(max(a2.y, b2.y, c2.y)) + 1, atlas - 1)
            guard minX <= maxX, minY <= maxY else { continue }
            let area = (b2.x - a2.x) * (c2.y - a2.y) - (b2.y - a2.y) * (c2.x - a2.x)
            guard abs(area) > 1e-9 else { continue }
            let a3 = SIMD3(vertices[i0*3], vertices[i0*3+1], vertices[i0*3+2])
            let b3 = SIMD3(vertices[i1*3], vertices[i1*3+1], vertices[i1*3+2])
            let c3 = SIMD3(vertices[i2*3], vertices[i2*3+1], vertices[i2*3+2])
            for y in minY ... maxY {
                for x in minX ... maxX {
                    let q2 = SIMD2(Float(x) + 0.5, Float(y) + 0.5)
                    let w0 = ((b2.x - a2.x) * (q2.y - a2.y) - (b2.y - a2.y) * (q2.x - a2.x)) / area
                    let w1 = ((c2.x - b2.x) * (q2.y - b2.y) - (c2.y - b2.y) * (q2.x - b2.x)) / area
                    guard w0 > -0.02, w1 > -0.02, w0 + w1 < 1.02 else { continue }
                    let cw0 = min(max(w0, 0), 1), cw1 = min(max(w1, 0), 1)
                    let cw2 = max(0, 1 - cw0 - cw1)
                    let p3 = a3 * cw2 + b3 * cw0 + c3 * cw1
                    let colour = sampleOriginal(p3)
                    let di = (y * atlas + x) * 4
                    px[di] = UInt8(min(max(colour.x, 0), 255))
                    px[di+1] = UInt8(min(max(colour.y, 0), 255))
                    px[di+2] = UInt8(min(max(colour.z, 0), 255))
                    px[di+3] = 255
                    covered[y * atlas + x] = true
                }
            }
        }

        for _ in 0 ..< gutter {
            var next = covered
            for y in 0 ..< atlas {
                for x in 0 ..< atlas where !covered[y * atlas + x] {
                    var acc = SIMD3<Float>.zero; var count: Float = 0
                    for (dx, dy) in [(1,0), (-1,0), (0,1), (0,-1)] {
                        let nx = x + dx, ny = y + dy
                        guard nx >= 0, nx < atlas, ny >= 0, ny < atlas,
                              covered[ny * atlas + nx] else { continue }
                        let si = (ny * atlas + nx) * 4
                        acc += SIMD3(Float(px[si]), Float(px[si+1]), Float(px[si+2]))
                        count += 1
                    }
                    guard count > 0 else { continue }
                    let clr = acc / count
                    let di = (y * atlas + x) * 4
                    px[di] = UInt8(clr.x); px[di+1] = UInt8(clr.y); px[di+2] = UInt8(clr.z); px[di+3] = 255
                    next[y * atlas + x] = true
                }
            }
            covered = next
        }

        return write(px, atlas, atlas, to: output) ? output : nil
    }

    static func bake(vertices: [Float], faces: [UInt32],
                     original: (vertices: [Float], normals: [Float], uvs: [Float], faces: [UInt32]),
                     originalTexture: URL, to output: URL,
                     atlas: Int = 4096, cell: Int = 8) -> Baked? {
        let n = faces.count / 3
        // Shrink the cell until every triangle has one, rather than failing. A denser car simply
        // gets fewer texels each; refusing to bake it at all helps nobody.
        var cell = cell
        while cell > 4 && (atlas / cell) * (atlas / cell) < n { cell -= 1 }
        let perRow = atlas / cell
        guard perRow * perRow >= n else { return nil }
        guard let src = loadRGBA(originalTexture) else { return nil }

        // UVs: one cell per triangle, inset by half a texel so neighbouring cells never bleed.
        var uvs = [Float](repeating: 0, count: n * 3 * 2)
        let inset: Float = 0.75
        for f in 0 ..< n {
            let cx = Float((f % perRow) * cell), cy = Float((f / perRow) * cell)
            let corners: [SIMD2<Float>] = [SIMD2(cx + inset, cy + inset),
                                           SIMD2(cx + Float(cell) - inset, cy + inset),
                                           SIMD2(cx + inset, cy + Float(cell) - inset)]
            for k in 0 ..< 3 {
                uvs[(f*3 + k) * 2]     = corners[k].x / Float(atlas)
                uvs[(f*3 + k) * 2 + 1] = corners[k].y / Float(atlas)
            }
        }

        // A grid over the original's triangles, so each texel's lookup is local.
        let m = original.faces.count / 3
        var lo = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
        var hi = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
        for i in 0 ..< (original.vertices.count / 3) {
            let q = SIMD3(original.vertices[i*3], original.vertices[i*3+1], original.vertices[i*3+2])
            lo = simd_min(lo, q); hi = simd_max(hi, q)
        }
        let gcell = max((hi - lo).max() / 160, 1e-5)
        func key(_ p: SIMD3<Float>) -> Int {
            let a = Int(floor(p.x / gcell)), b = Int(floor(p.y / gcell)), c = Int(floor(p.z / gcell))
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
            buckets[key(c / 3), default: []].append(f)
        }

        var px = [UInt8](repeating: 0, count: atlas * atlas * 4)
        for f in 0 ..< n {
            let i0 = Int(faces[f*3]), i1 = Int(faces[f*3+1]), i2 = Int(faces[f*3+2])
            let a = SIMD3(vertices[i0*3], vertices[i0*3+1], vertices[i0*3+2])
            let b = SIMD3(vertices[i1*3], vertices[i1*3+1], vertices[i1*3+2])
            let c = SIMD3(vertices[i2*3], vertices[i2*3+1], vertices[i2*3+2])
            let cx = (f % perRow) * cell, cy = (f / perRow) * cell
            for ty in 0 ..< cell {
                for tx in 0 ..< cell {
                    // Barycentric of this texel within the cell, then the same point in 3D.
                    var u = (Float(tx) + 0.5 - inset) / (Float(cell) - 2 * inset)
                    var v = (Float(ty) + 0.5 - inset) / (Float(cell) - 2 * inset)
                    // A triangle fills half a square cell. The other half still has to hold
                    // something sensible, because bilinear filtering reaches into it from just
                    // inside the triangle's edge — and clamping u and v separately put those
                    // samples nowhere near the surface, so they came back with a colour from
                    // somewhere else and drew a dark line along every triangle edge. Reflecting
                    // across the diagonal mirrors the triangle into its own spare corner, so the
                    // colour there continues rather than jumping.
                    if u + v > 1 { u = 1 - u; v = 1 - v }
                    u = min(max(u, 0), 1); v = min(max(v, 0), 1)
                    let w = max(0, 1 - u - v)
                    let p = a * w + b * u + c * v
                    var best = Float.greatestFiniteMagnitude
                    var uv = SIMD2<Float>(0, 0)
                    var radius = 1
                    while radius <= 4 {
                        for dx in -radius ... radius {
                            for dy in -radius ... radius {
                                for dz in -radius ... radius {
                                    let probe = p + SIMD3(Float(dx), Float(dy), Float(dz)) * gcell
                                    for g in buckets[key(probe)] ?? [] {
                                        let j0 = Int(original.faces[g*3])
                                        let j1 = Int(original.faces[g*3+1])
                                        let j2 = Int(original.faces[g*3+2])
                                        let qa = SIMD3(original.vertices[j0*3], original.vertices[j0*3+1],
                                                       original.vertices[j0*3+2])
                                        let qb = SIMD3(original.vertices[j1*3], original.vertices[j1*3+1],
                                                       original.vertices[j1*3+2])
                                        let qc = SIMD3(original.vertices[j2*3], original.vertices[j2*3+1],
                                                       original.vertices[j2*3+2])
                                        let (d, bary) = GlassPatch.closestPublic(p, qa, qb, qc)
                                        if d < best {
                                            best = d
                                            uv = SIMD2(original.uvs[j0*2], original.uvs[j0*2+1]) * bary.x
                                               + SIMD2(original.uvs[j1*2], original.uvs[j1*2+1]) * bary.y
                                               + SIMD2(original.uvs[j2*2], original.uvs[j2*2+1]) * bary.z
                                        }
                                    }
                                }
                            }
                        }
                        if best < .greatestFiniteMagnitude { break }
                        radius += 1
                    }
                    let sx = min(max(Int(uv.x * Float(src.w - 1)), 0), src.w - 1)
                    let sy = min(max(Int(uv.y * Float(src.h - 1)), 0), src.h - 1)
                    let si = (sy * src.w + sx) * 4
                    let di = ((cy + ty) * atlas + (cx + tx)) * 4
                    px[di] = src.px[si]; px[di+1] = src.px[si+1]
                    px[di+2] = src.px[si+2]; px[di+3] = 255
                }
            }
        }
        guard write(px, atlas, atlas, to: output) else { return nil }
        return Baked(uvs: uvs, texture: output, size: atlas, cell: cell)
    }

    private static func loadRGBA(_ url: URL) -> (w: Int, h: Int, px: [UInt8])? {
        guard let d = try? Data(contentsOf: url),
              let s = CGImageSourceCreateWithData(d as CFData, nil),
              let cg = CGImageSourceCreateImageAtIndex(s, 0, nil) else { return nil }
        let w = cg.width, h = cg.height
        var px = [UInt8](repeating: 0, count: w * h * 4)
        guard let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        return (w, h, px)
    }

    private static func write(_ px: [UInt8], _ w: Int, _ h: Int, to url: URL) -> Bool {
        var buf = px
        guard let ctx = CGContext(data: &buf, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let cg = ctx.makeImage(),
              let dest = CGImageDestinationCreateWithURL(url as CFURL,
                                                         UTType.png.identifier as CFString, 1, nil)
        else { return false }
        CGImageDestinationAddImage(dest, cg, nil)
        return CGImageDestinationFinalize(dest)
    }
}
