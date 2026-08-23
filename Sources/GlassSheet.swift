import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// Prepares the view sheets for a bake that treats the windows as opaque dark panels.
///
/// The order matters and is fixed: take the alpha the person painted and keep it as the stencil;
/// fill those same areas with a flat dark grey and make the sheet fully opaque; bake that. The
/// bake then has nothing transparent to reason about — no view can see through a window, so no
/// view can paint a seat or a patch of sky onto one — and the glass comes out as a plain dark
/// panel. The stencil, saved before anything was changed, is what the mesh is later cut to.
enum GlassSheet {

    /// Where the extracted stencil lives: white where the person marked glass, black elsewhere.
    static func stencilURL(forSheet sheet: URL) -> URL {
        sheet.deletingLastPathComponent().appendingPathComponent(
            sheet.deletingPathExtension().lastPathComponent + "_glass.png")
    }

    /// The opaque sheet the bake actually reads.
    static func flatURL(forSheet sheet: URL) -> URL {
        sheet.deletingLastPathComponent().appendingPathComponent(
            sheet.deletingPathExtension().lastPathComponent + "_flat.png")
    }

    /// Split the sheet into a stencil and an opaque sheet. Returns both, or nil if there is no
    /// alpha to work with.
    ///
    /// - Parameter tint: the dark grey painted into the window areas.
    @discardableResult
    static func prepare(sheet: URL, tint: (UInt8, UInt8, UInt8) = (34, 34, 38))
        -> (stencil: URL, flat: URL, coverage: Double)? {
        guard var img = load(sheet) else { return nil }
        let n = img.width * img.height

        // Only what the person cut out. The paint model's own transparency is ignored.
        //
        // A sheet carries two quite different things in its alpha, and they are cleanly
        // separable. Measured on one car's side view: 1,322 pixels at alpha 0 — the windows
        // someone deliberately erased — and 5,050 at alpha 115, which is the paint model's
        // leftover guess. That second layer traces the car's silhouette, fills the wheel arches,
        // and leaves a dot squarely on the door handle. Treating anything below opaque as glass
        // imported all of it, and the door handle became a hole in the door that appeared in
        // nobody's drawing.
        let handDrawn: UInt8 = 32
        var mask = [Bool](repeating: false, count: n)
        var count = 0
        for i in 0 ..< n where img.px[i*4 + 3] < handDrawn { mask[i] = true; count += 1 }
        guard count > 0 else { return nil }

        var stencil = [UInt8](repeating: 0, count: n * 4)
        for i in 0 ..< n {
            let v: UInt8 = mask[i] ? 255 : 0
            stencil[i*4] = v; stencil[i*4+1] = v; stencil[i*4+2] = v; stencil[i*4+3] = 255
        }
        let sURL = stencilURL(forSheet: sheet)
        guard write(Bitmap(px: stencil, width: img.width, height: img.height), to: sURL)
        else { return nil }

        for i in 0 ..< n {
            if mask[i] {
                img.px[i*4] = tint.0; img.px[i*4+1] = tint.1; img.px[i*4+2] = tint.2
            }
            img.px[i*4 + 3] = 255           // nothing transparent survives into the bake
        }
        let fURL = flatURL(forSheet: sheet)
        guard write(img, to: fURL) else { return nil }
        return (sURL, fURL, Double(count) / Double(n))
    }

    /// The stencil split into one signed distance field per view.
    static func viewFields(stencil: URL) -> (tile: Int, fields: [[Float]])? {
        guard let (w, h, mask) = stencilMask(stencil), w >= h, h > 0 else { return nil }
        let views = w / h
        guard views >= 4 else { return nil }
        var out = [[Float]]()
        // Side views only — see `SheetStencil.stencilViews`. The overhead views are still in the
        // sheet and still colour the bake; they simply do not get a vote on where glass is.
        for v in 0 ..< min(views, SheetStencil.elevs.count) {
            guard SheetStencil.stencilViews.contains(v) else { out.append([]); continue }
            var tile = [Bool](repeating: false, count: h * h)
            for y in 0 ..< h {
                for x in 0 ..< h { tile[y * h + x] = mask[y * w + v * h + x] }
            }
            out.append(SheetStencil.signedDistance(tile, w: h, h: h))
        }
        return (h, out)
    }

    /// The stencil as a per-pixel mask, for the cut.
    static func stencilMask(_ url: URL) -> (width: Int, height: Int, inside: [Bool])? {
        guard let img = load(url) else { return nil }
        var m = [Bool](repeating: false, count: img.width * img.height)
        for i in 0 ..< m.count { m[i] = img.px[i*4] > 127 }
        return (img.width, img.height, m)
    }

    // MARK: - image io

    struct Bitmap { var px: [UInt8]; let width: Int; let height: Int }

    static func load(_ url: URL) -> Bitmap? {
        guard let d = try? Data(contentsOf: url),
              let src = CGImageSourceCreateWithData(d as CFData, nil),
              let cg = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
        let w = cg.width, h = cg.height
        var px = [UInt8](repeating: 0, count: w * h * 4)
        guard let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        // Straight colour, so a window at alpha 0 keeps whatever colour it had rather than
        // reading as black.
        for i in stride(from: 0, to: px.count, by: 4) {
            let a = Int(px[i+3])
            guard a > 0, a < 255 else { continue }
            for k in 0 ..< 3 { px[i+k] = UInt8(min(255, Int(px[i+k]) * 255 / a)) }
        }
        return Bitmap(px: px, width: w, height: h)
    }

    static func write(_ b: Bitmap, to url: URL) -> Bool {
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
              let dest = CGImageDestinationCreateWithURL(url as CFURL,
                                                         UTType.png.identifier as CFString, 1, nil)
        else { return false }
        CGImageDestinationAddImage(dest, cg, nil)
        return CGImageDestinationFinalize(dest)
    }
}
