import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import simd

/// Repaint the glass in a finished atlas, without re-running the paint model.
///
/// The windscreen picks up the cabin's colour two ways, and both are baked in by the time the
/// atlas exists. A raked windscreen faces the overhead camera well enough to win the bake's
/// cosine-weighted vote, so it is handed a picture of the seats; and the texels no view covered
/// are filled from the nearest covered surface in 3D, which beside a windscreen is the dashboard.
/// Measured on one car: of 105,975 tan texels, 63% were painted by a view and 37% were never
/// covered at all.
///
/// Neither is recoverable by editing what is there — the glass never had a correct colour to
/// restore. But glass is very nearly a flat colour, so it can simply be *reasserted*: find the
/// texels the glass faces own, work out what this car's glass actually looks like from the
/// darkest part of its own range, and write that back across all of them.
enum GlassClean {

    /// The glass's transparency, kept beside the mesh instead of in the atlas.
    ///
    /// Per-texel alpha was the right answer while glass was identified per texel. Now that the
    /// glass is its own set of faces with a cut boundary, alpha in the texture only reintroduces
    /// the problem at a finer scale: the window edge becomes a staircase of *texels* instead of
    /// triangles, which is exactly the fine sawtooth left after the mesh was cut cleanly. One
    /// number on the material has no edge at all — the boundary is the geometry's.
    enum Opacity {
        /// Colour and transparency together — the whole description of the glass.
        struct Glass { let r: Float; let g: Float; let b: Float; let a: Float }

        static func url(forMesh mesh: URL) -> URL {
            mesh.deletingLastPathComponent().appendingPathComponent(
                mesh.deletingPathExtension().lastPathComponent + "_glass.opacity")
        }

        static func load(forMesh mesh: URL) -> Glass? {
            guard let s = try? String(contentsOf: url(forMesh: mesh), encoding: .utf8) else {
                return nil
            }
            let n = s.split(whereSeparator: { " \n\t,".contains($0) }).compactMap { Float($0) }
            if n.count >= 4, n[3] > 0, n[3] <= 1 { return Glass(r: n[0], g: n[1], b: n[2], a: n[3]) }
            // Older files held the alpha alone.
            if n.count == 1, n[0] > 0, n[0] <= 1 {
                return Glass(r: Float(defaultTint.x) / 255, g: Float(defaultTint.y) / 255,
                             b: Float(defaultTint.z) / 255, a: n[0])
            }
            return nil
        }

        static func save(colour: SIMD3<UInt8>, alpha: Float, forMesh mesh: URL) {
            let t = String(format: "%.4f %.4f %.4f %.4f", Float(colour.x) / 255,
                           Float(colour.y) / 255, Float(colour.z) / 255, alpha)
            try? t.write(to: url(forMesh: mesh), atomically: true, encoding: .utf8)
        }

        static func clear(forMesh mesh: URL) {
            try? FileManager.default.removeItem(at: url(forMesh: mesh))
        }
    }

    struct Result {
        let texels: Int
        let atlasTexels: Int
        let colour: SIMD3<UInt8>
        let backup: URL?
    }

    /// Overwrite every texel owned by a glass face with this car's own glass colour.
    ///
    /// - Parameter gutter: how far to spill past the triangles. UV charts are separated by a few
    ///   texels of padding that the renderer still samples at chart edges, so stopping exactly at
    ///   the triangle boundary leaves a rim of the old colour visible around every window.
    /// Near-black, the default glass colour.
    ///
    /// Measuring the colour from the atlas sounds more principled and is worse in practice: it
    /// faithfully reproduces whatever the paint model put on the window, and the paint model
    /// paints windows silver — on one car the measured glass came back rgb(199,197,199), an
    /// off-white pane. A window with nothing lit behind it reads near-black, and the small blue
    /// lift keeps it from looking like a hole.
    ///
    /// Not pure black, because glass is not: a fully black pane loses the shading that makes it
    /// read as a surface at all.
    static let defaultTint = SIMD3<UInt8>(12, 12, 14)

    /// How transparent the glass is, 0...1. Set in the paint settings; 0.45 by default.
    ///
    /// Measuring it from the atlas gave every car a different answer for no good reason — black
    /// came out at 0.078, nearly clear, so its cabin showed through like an open window, while
    /// the red car's 0.451 looked right. That spread is the paint model's noise, not a property
    /// of the cars, so it is one value everywhere: the one that worked on the red car.
    static let defaultOpacity: Float = 0.45

    static var opacity: Float {
        let v = UserDefaults.standard.object(forKey: "glassOpacity") as? Double
        return Float(v ?? Double(defaultOpacity))
    }

    /// - Parameter tint: the colour to paint the glass; `defaultTint` if not given.
    static func clean(mesh: URL, texture: URL, mr: URL?, glass: [Bool],
                      gutter: Int = 3, tint: SIMD3<UInt8>? = nil) -> Result? {
        guard let g = PoseSnap.loadTMeshWithUVs(mesh),
              glass.contains(true),
              var img = load(texture) else { return nil }
        let w = img.width, h = img.height

        var mask = [Bool](repeating: false, count: w * h)
        let faceCount = g.faces.count / 3
        for f in 0 ..< min(faceCount, glass.count) where glass[f] {
            rasterise(face: f, faces: g.faces, uvs: g.uvs, w: w, h: h, into: &mask)
        }
        let core = mask
        // Texels belonging to everything that is *not* glass. The spill below must not touch
        // them.
        //
        // The padding spill is necessary — without it a rim of the old colour shows around every
        // window — but this atlas is thousands of tiny charts, and a glass island is about three
        // texels across. Spilling three texels around each one multiplies the painted area by
        // more than ten: a 6% mask covered 69% of the atlas and turned the whole car black.
        // Spilling only into genuinely unused space keeps the rim and costs nothing.
        var owned = [Bool](repeating: false, count: w * h)
        for f in 0 ..< faceCount where !(f < glass.count && glass[f]) {
            rasterise(face: f, faces: g.faces, uvs: g.uvs, w: w, h: h, into: &owned)
        }

        if gutter > 0 { mask = dilate(mask, w: w, h: h, radius: gutter) }
        for i in 0 ..< (w * h) where owned[i] && !core[i] { mask[i] = false }
        let count = mask.lazy.filter { $0 }.count
        guard count > 0 else { return nil }

        let colour = tint ?? defaultTint

        // Keep it beside the atlas so the change is reversible without a re-bake.
        let backup = texture.deletingPathExtension().appendingPathExtension("preglass.png")
        if !FileManager.default.fileExists(atPath: backup.path) {
            try? FileManager.default.copyItem(at: texture, to: backup)
        }

        for i in 0 ..< (w * h) where mask[i] {
            img.px[i*4] = colour.x; img.px[i*4+1] = colour.y; img.px[i*4+2] = colour.z
        }
        // The transparency goes on the material, and the atlas is made fully opaque.
        // Leaving any alpha in the texture would re-cut the window edge per texel and undo the
        // mesh cut — the fine sawtooth is precisely that.
        Opacity.save(colour: colour, alpha: opacity, forMesh: mesh)
        for i in 0 ..< (w * h) { img.px[i*4+3] = 255 }
        guard write(img, to: texture) else { return nil }

        // Glass is smooth and non-metallic. Whatever the paint model guessed for roughness over
        // a windscreen it guessed from the same contaminated pixels, so it is worth asserting
        // too — a rough windscreen reads as frosted no matter how clean its colour is.
        if let mr, var m = load(mr) {
            // The metallic-roughness map is often a different size from the albedo — 2048 against
            // 8192 on one car — and requiring them to match silently skipped this step, leaving
            // windows as rough as the bodywork. Sampling the mask at the MR's own resolution
            // costs nothing and always applies.
            for y in 0 ..< m.height {
                for x in 0 ..< m.width {
                    let sx = min(w - 1, x * w / max(m.width, 1))
                    let sy = min(h - 1, y * h / max(m.height, 1))
                    guard mask[sy * w + sx] else { continue }
                    let i = y * m.width + x
                    m.px[i*4+1] = 40      // roughness
                    m.px[i*4+2] = 0       // metallic
                }
            }
            _ = write(m, to: mr)
        }
        return Result(texels: count, atlasTexels: w * h, colour: colour, backup: backup)
    }

    /// Put back the atlas as it was before the last clean.
    static func revert(texture: URL, mr: URL?) -> Bool {
        let backup = texture.deletingPathExtension().appendingPathExtension("preglass.png")
        guard FileManager.default.fileExists(atPath: backup.path) else { return false }
        try? FileManager.default.removeItem(at: texture)
        try? FileManager.default.copyItem(at: backup, to: texture)
        return true
    }

    static func hasBackup(texture: URL) -> Bool {
        FileManager.default.fileExists(
            atPath: texture.deletingPathExtension().appendingPathExtension("preglass.png").path)
    }

    // MARK: - raster

    /// Mark every texel whose centre falls inside a triangle's UV footprint.
    private static func rasterise(face f: Int, faces: [UInt32], uvs: [Float],
                                  w: Int, h: Int, into mask: inout [Bool]) {
        let i0 = Int(faces[f*3]), i1 = Int(faces[f*3+1]), i2 = Int(faces[f*3+2])
        // Same convention the rest of the app samples with: v is not re-flipped here.
        let a = SIMD2(uvs[i0*2] * Float(w - 1), uvs[i0*2+1] * Float(h - 1))
        let b = SIMD2(uvs[i1*2] * Float(w - 1), uvs[i1*2+1] * Float(h - 1))
        let c = SIMD2(uvs[i2*2] * Float(w - 1), uvs[i2*2+1] * Float(h - 1))
        let minX = max(Int(floor(min(a.x, b.x, c.x))), 0)
        let maxX = min(Int(ceil(max(a.x, b.x, c.x))), w - 1)
        let minY = max(Int(floor(min(a.y, b.y, c.y))), 0)
        let maxY = min(Int(ceil(max(a.y, b.y, c.y))), h - 1)
        guard minX <= maxX, minY <= maxY else { return }
        let area = (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x)
        // A triangle thinner than a texel covers no centre at all; mark its vertices so that
        // slivers — of which a fragmented atlas has many — are not silently skipped.
        if abs(area) < 1e-6 {
            for p in [a, b, c] {
                let x = min(max(Int(p.x.rounded()), 0), w - 1)
                let y = min(max(Int(p.y.rounded()), 0), h - 1)
                mask[y * w + x] = true
            }
            return
        }
        for y in minY ... maxY {
            for x in minX ... maxX {
                let p = SIMD2(Float(x), Float(y))
                let w0 = ((b.x - a.x) * (p.y - a.y) - (b.y - a.y) * (p.x - a.x)) / area
                let w1 = ((c.x - b.x) * (p.y - b.y) - (c.y - b.y) * (p.x - b.x)) / area
                let w2 = ((a.x - c.x) * (p.y - c.y) - (a.y - c.y) * (p.x - c.x)) / area
                if (w0 >= -0.001 && w1 >= -0.001 && w2 >= -0.001)
                    || (w0 <= 0.001 && w1 <= 0.001 && w2 <= 0.001) {
                    mask[y * w + x] = true
                }
            }
        }
    }

    private static func dilate(_ m: [Bool], w: Int, h: Int, radius: Int) -> [Bool] {
        var out = m
        for _ in 0 ..< radius {
            var next = out
            for y in 0 ..< h {
                for x in 0 ..< w where !out[y*w + x] {
                    if (x > 0 && out[y*w + x-1]) || (x < w-1 && out[y*w + x+1])
                        || (y > 0 && out[(y-1)*w + x]) || (y < h-1 && out[(y+1)*w + x]) {
                        next[y*w + x] = true
                    }
                }
            }
            out = next
        }
        return out
    }

    // MARK: - image io

    private struct Bitmap { var px: [UInt8]; let width: Int; let height: Int }

    private static func load(_ url: URL) -> Bitmap? {
        guard let d = try? Data(contentsOf: url),
              let src = CGImageSourceCreateWithData(d as CFData, nil),
              let cg = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
        let w = cg.width, h = cg.height
        // Zero-filled, and drawn with .last rather than .premultipliedLast: compositing onto a
        // filled buffer is what silently forced alpha to 255 here once before.
        var px = [UInt8](repeating: 0, count: w * h * 4)
        guard let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        // CGBitmapContext only offers premultiplied alpha, so undo it here and work in straight
        // colour. Left premultiplied, every fully transparent texel reads as pure black and drags
        // any statistic over the glass — which is exactly how the first run came back with a
        // glass colour of (0, 0, 0).
        for i in stride(from: 0, to: px.count, by: 4) {
            let a = Int(px[i+3])
            guard a > 0, a < 255 else { continue }
            for k in 0 ..< 3 { px[i+k] = UInt8(min(255, Int(px[i+k]) * 255 / a)) }
        }
        return Bitmap(px: px, width: w, height: h)
    }

    private static func write(_ b: Bitmap, to url: URL) -> Bool {
        var px = b.px
        for i in stride(from: 0, to: px.count, by: 4) {
            let a = Int(px[i+3])
            guard a > 0, a < 255 else { continue }
            for k in 0 ..< 3 { px[i+k] = UInt8(Int(px[i+k]) * a / 255) }
        }
        guard let ctx = CGContext(data: &px, width: b.width, height: b.height, bitsPerComponent: 8,
                                  bytesPerRow: b.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let cg = ctx.makeImage(),
              let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString,
                                                         1, nil) else { return false }
        CGImageDestinationAddImage(dest, cg, nil)
        return CGImageDestinationFinalize(dest)
    }
}
