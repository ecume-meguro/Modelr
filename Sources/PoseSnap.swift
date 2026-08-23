import Foundation
import CoreGraphics
import ImageIO
import AppKit
import HunyuanPaintMLX

/// Solves a reference photograph's camera pose by matching its silhouette to the mesh.
/// See `PoseFitter` for why this is a solver rather than another slider.
enum PoseSnap {

    struct Result {
        let elev: Double
        let azim: Double
        let fovDeg: Double
        let scale: Double
        let offset: CGSize
        let residual: Double
        let iou: Double
    }

    /// Runs off the main thread; the fit itself takes a fraction of a second, but the subject
    /// cutout and mesh load are worth keeping off the UI as well.
    static func fit(meshURL: URL, imageURL: URL, seedElev: Double, seedAzim: Double,
                    completion: @escaping (Result?) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let res = 192
            guard let mesh = loadTMesh(meshURL), let photo = subjectMask(imageURL, res: res) else {
                DispatchQueue.main.async { completion(nil) }; return
            }
            let render = MeshRender()
            render.loadMesh(mesh.vertices, mesh.faces)
            let fit = PoseFitter.fit(render: render, photoMask: photo, res: res,
                                     seedElev: Float(seedElev), seedAzim: Float(seedAzim))
            DispatchQueue.main.async {
                guard let fit else { completion(nil); return }
                completion(Result(elev: Double(fit.elev),
                                  azim: Double(fit.azim),
                                  fovDeg: Double(fit.fovDeg),
                                  scale: Double(fit.scale),
                                  // The fit works in the rasteriser's y-up frame; the overlay
                                  // and the stored transform are y-down.
                                  offset: CGSize(width: Double(fit.offsetX),
                                                 height: -Double(fit.offsetY)),
                                  residual: Double(fit.residual), iou: Double(fit.iou)))
            }
        }
    }

    /// The subject as a binary mask, aspect-fitted into a square exactly the way `squared()` and
    /// the aligner's overlay do it — the fit's scale and offset are relative to that framing, so
    /// any disagreement here would show up as a constant error the solver cannot see.
    static func subjectMask(_ url: URL, res: Int) -> [Float]? {
        guard let cg = BackgroundRemover.loadCGImage(url) else { return nil }
        // Vision's subject cutout copes with a real photograph; the flood-fill in the bake
        // assumes a clean uniform backdrop and would fail on anything shot outdoors.
        let maskImage = BackgroundRemover.visionMask(for: cg)
        var px = [UInt8](repeating: 0, count: res * res)
        guard let ctx = CGContext(data: &px, width: res, height: res, bitsPerComponent: 8,
                                  bytesPerRow: res, space: CGColorSpaceCreateDeviceGray(),
                                  bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        ctx.setFillColor(gray: 0, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: res, height: res))
        let w = CGFloat(cg.width), h = CGFloat(cg.height)
        let fit = min(CGFloat(res) / w, CGFloat(res) / h)
        let dw = w * fit, dh = h * fit
        let rect = CGRect(x: (CGFloat(res) - dw) / 2, y: (CGFloat(res) - dh) / 2,
                          width: dw, height: dh)
        if let maskImage {
            ctx.draw(maskImage, in: rect)
        } else {
            // No subject found — fall back to "anything that is not the border colour", which is
            // right for the studio-style renders these projects often use.
            guard let flat = flatBackdropMask(cg) else { return nil }
            ctx.draw(flat, in: rect)
        }
        // Row order is left exactly as CoreGraphics produced it. Both this and the rasteriser
        // put row 0 at the bottom (SwiftRaster maps increasing NDC y to increasing row), so no
        // flip belongs here — adding one mirrors the photo against the render and the solver
        // then "fits" a pose that is wrong in elevation while still scoring well.
        let out = px.map { $0 > 127 ? Float(1) : Float(0) }
        return out.contains(1) ? out : nil
    }

    /// White on the subject, black on the backdrop, for images Vision declines to segment.
    ///
    /// "Differs from the border colour" is not enough: a stored reference is letterboxed onto a
    /// grey canvas, so the photo's own white background differs from that grey and gets kept —
    /// the mask becomes the whole photo rectangle and the solver dutifully fits the car to a
    /// box. The backdrop is therefore what is *both* backdrop-coloured (border colour, or
    /// near-white studio paper) *and* reachable from the image border.
    private static func flatBackdropMask(_ cg: CGImage) -> CGImage? {
        let w = cg.width, h = cg.height
        var px = [UInt8](repeating: 0, count: w * h * 4)
        guard let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        var edge = [[Int]](repeating: [], count: 3)
        for x in stride(from: 0, to: w, by: 4) {
            for y in [0, h - 1] { for c in 0..<3 { edge[c].append(Int(px[(y*w + x)*4 + c])) } }
        }
        for y in stride(from: 0, to: h, by: 4) {
            for x in [0, w - 1] { for c in 0..<3 { edge[c].append(Int(px[(y*w + x)*4 + c])) } }
        }
        let med = (0..<3).map { c -> Int in let v = edge[c].sorted(); return v[v.count / 2] }
        func isBackdropColour(_ i: Int) -> Bool {
            let r = Int(px[i*4]), g = Int(px[i*4+1]), b = Int(px[i*4+2])
            if abs(r - med[0]) <= 16 && abs(g - med[1]) <= 16 && abs(b - med[2]) <= 16 {
                return true
            }
            let mx = max(r, max(g, b)), mn = min(r, min(g, b))
            return mx > 229 && (mx - mn) * 100 / max(mx, 1) < 8
        }
        var bg = [Bool](repeating: false, count: w * h)
        var queue = [Int](); queue.reserveCapacity(w * h / 4)
        func seed(_ i: Int) { if !bg[i], isBackdropColour(i) { bg[i] = true; queue.append(i) } }
        for x in 0..<w { seed(x); seed((h - 1) * w + x) }
        for y in 0..<h { seed(y * w); seed(y * w + w - 1) }
        var qi = 0
        while qi < queue.count {
            let i = queue[qi]; qi += 1
            let y = i / w, x = i % w
            for (dy, dx) in [(-1, 0), (1, 0), (0, -1), (0, 1)] {
                let ny = y + dy, nx = x + dx
                guard ny >= 0, ny < h, nx >= 0, nx < w else { continue }
                let j = ny * w + nx
                if !bg[j], isBackdropColour(j) { bg[j] = true; queue.append(j) }
            }
        }
        var out = bg.map { $0 ? UInt8(0) : UInt8(255) }
        return CGContext(data: &out, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                         space: CGColorSpaceCreateDeviceGray(),
                         bitmapInfo: CGImageAlphaInfo.none.rawValue)?.makeImage()
    }

    /// .tmesh = [i32 n][i32 m][f32 verts][f32 normals][f32 uvs][i32 faces]. Only geometry is
    /// needed for a silhouette.
    /// Same reader, keeping the UVs — glass auto-select needs them to seed from the texture.
    static func loadTMeshWithUVs(_ url: URL) -> (vertices: [Float], uvs: [Float], faces: [UInt32])? {
        guard let d = try? Data(contentsOf: url), d.count > 8 else { return nil }
        let n = Int(d.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 0, as: Int32.self) })
        let m = Int(d.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 4, as: Int32.self) })
        guard n > 0, m > 0, d.count >= 8 + n*12 + n*12 + n*8 + m*12 else { return nil }
        var verts = [Float](repeating: 0, count: n * 3)
        var uvs = [Float](repeating: 0, count: n * 2)
        var faces = [UInt32](repeating: 0, count: m * 3)
        d.withUnsafeBytes { raw in
            for i in 0 ..< (n * 3) {
                verts[i] = raw.loadUnaligned(fromByteOffset: 8 + i*4, as: Float.self)
            }
            let uo = 8 + n*12 + n*12
            for i in 0 ..< (n * 2) {
                uvs[i] = raw.loadUnaligned(fromByteOffset: uo + i*4, as: Float.self)
            }
            let fo = uo + n*8
            for i in 0 ..< (m * 3) {
                faces[i] = raw.loadUnaligned(fromByteOffset: fo + i*4, as: UInt32.self)
            }
        }
        return (verts, uvs, faces)
    }

    static func loadTMesh(_ url: URL) -> (vertices: [Float], faces: [UInt32])? {
        guard let d = try? Data(contentsOf: url), d.count > 8 else { return nil }
        let n = Int(d.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 0, as: Int32.self) })
        let m = Int(d.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 4, as: Int32.self) })
        guard n > 0, m > 0, d.count >= 8 + n*12 + n*12 + n*8 + m*12 else { return nil }
        var verts = [Float](repeating: 0, count: n * 3)
        var faces = [UInt32](repeating: 0, count: m * 3)
        d.withUnsafeBytes { raw in
            for i in 0 ..< (n * 3) {
                verts[i] = raw.loadUnaligned(fromByteOffset: 8 + i*4, as: Float.self)
            }
            let fo = 8 + n*12 + n*12 + n*8
            for i in 0 ..< (m * 3) {
                faces[i] = raw.loadUnaligned(fromByteOffset: fo + i*4, as: UInt32.self)
            }
        }
        return (verts, faces)
    }
}
