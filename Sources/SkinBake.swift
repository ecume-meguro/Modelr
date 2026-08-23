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
