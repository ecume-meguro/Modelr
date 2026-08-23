import CoreGraphics
import ImageIO
import Foundation
import MLX
import HunyuanPaintMLX

// Headless bake: geometry + view sheets -> atlas PNGs. Lets bake parameters be swept from a
// shell loop in seconds instead of rebuilding the app and clicking Re-bake for each trial.
// Usage: mvbake <unbaked.tmesh> <albedo_sheet.png> <mr_sheet.png> <outPrefix> [texSize]

func loadPNGFloats(_ path: String) -> [Float] {
    // atlas PNG -> flat RGB floats, for the debug render
    guard let d = try? Data(contentsOf: URL(fileURLWithPath: path)),
          let src = CGImageSourceCreateWithData(d as CFData, nil),
          let cg = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return [] }
    let w = cg.width, h = cg.height
    var px = [UInt8](repeating: 0, count: w*h*4)
    let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w*4,
                        space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
    var out = [Float](repeating: 0, count: w*h*3)
    for i in 0..<(w*h) { for c in 0..<3 { out[i*3+c] = Float(px[i*4+c])/255 } }
    return out
}

let a = CommandLine.arguments
guard a.count >= 5 else {
    FileHandle.standardError.write("usage: mvbake <tmesh> <albedo.png> <mr.png> <outPrefix> [tex]\n".data(using: .utf8)!)
    exit(2)
}
let texSize = a.count > 5 ? Int(a[5]) ?? 2048 : 2048

// .tmesh = [i32 n][i32 m][f32 verts][f32 normals][f32 uvs][i32 faces], UVs stored v-flipped.
let d = try Data(contentsOf: URL(fileURLWithPath: a[1]))
let n = Int(d.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 0, as: Int32.self) })
let m = Int(d.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 4, as: Int32.self) })
var verts = [Float](repeating: 0, count: n*3)
var uvs = [Float](repeating: 0, count: n*2)
var faces = [UInt32](repeating: 0, count: m*3)
d.withUnsafeBytes { raw in
    for i in 0..<(n*3) { verts[i] = raw.loadUnaligned(fromByteOffset: 8 + i*4, as: Float.self) }
    let uo = 8 + n*12 + n*12
    for i in 0..<(n*2) { uvs[i] = raw.loadUnaligned(fromByteOffset: uo + i*4, as: Float.self) }
    let fo = uo + n*8
    for i in 0..<(m*3) { faces[i] = raw.loadUnaligned(fromByteOffset: fo + i*4, as: UInt32.self) }
}
for i in 0..<n { uvs[i*2+1] = 1 - uvs[i*2+1] }        // back to RAW for bakePBR

// Self-test: synthesise the "photo" by rendering a known pose, seed the fitter somewhere
// wrong, and see whether it walks back. MODELR_POSEFIT_TEST="elev,azim,fov,dElev,dAzim".
if let spec = ProcessInfo.processInfo.environment["MODELR_POSEFIT_TEST"] {
    let f = spec.split(separator: ",").compactMap { Float($0) }
    guard f.count >= 5 else { fatalError("need elev,azim,fov,dElev,dAzim") }
    let RT = MeshRender()
    RT.loadMesh(verts, faces)
    let res = 192
    let truth = RT.silhouetteMask(elev: f[0], azim: f[1], fovDeg: f[2], res: res)
    let t0 = Date()
    let fit = PoseFitter.fit(render: RT, photoMask: truth, res: res,
                             seedElev: f[0] + f[3], seedAzim: f[1] + f[4])
    if let fit {
        print(String(format:
            "truth e=%.1f a=%.1f fov=%.0f | seed e=%+.1f a=%+.1f | got e=%.2f a=%.2f fov=%.0f "
            + "scale=%.3f off=(%.3f,%.3f) residual=%.4f iou=%.3f  [%.1fs]",
            f[0], f[1], f[2], f[3], f[4], fit.elev, fit.azim, fit.fovDeg,
            fit.scale, fit.offsetX, fit.offsetY, fit.residual, fit.iou,
            Date().timeIntervalSince(t0)))
        print(String(format: "  error: elev %+.2f deg, azim %+.2f deg",
                     fit.elev - f[0], fit.azim - f[1]))
    } else { print("fit failed") }
    exit(0)
}

// Fit against a REAL image: MODELR_POSEFIT_IMAGE="png,seedElev,seedAzim". Masks it the way
// PoseSnap's fallback does (differs from the border colour), so the frame conventions get
// exercised for real rather than cancelling out against another render.
if let spec = ProcessInfo.processInfo.environment["MODELR_POSEFIT_IMAGE"] {
    let f = spec.split(separator: ",").map(String.init)
    guard f.count >= 3, let se = Float(f[1]), let sa = Float(f[2]) else { fatalError("bad spec") }
    let res = 192
    guard let d = try? Data(contentsOf: URL(fileURLWithPath: f[0])),
          let src = CGImageSourceCreateWithData(d as CFData, nil),
          let cg = CGImageSourceCreateImageAtIndex(src, 0, nil) else { fatalError("no image") }
    var px = [UInt8](repeating: 0, count: res*res*4)
    let ctx = CGContext(data: &px, width: res, height: res, bitsPerComponent: 8,
                        bytesPerRow: res*4, space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let w = CGFloat(cg.width), h = CGFloat(cg.height)
    let fitS = min(CGFloat(res)/w, CGFloat(res)/h)
    ctx.draw(cg, in: CGRect(x: (CGFloat(res)-w*fitS)/2, y: (CGFloat(res)-h*fitS)/2,
                            width: w*fitS, height: h*fitS))
    var edge = [[Int]](repeating: [], count: 3)
    for x in 0..<res { for y in [0, res-1] { for c in 0..<3 { edge[c].append(Int(px[(y*res+x)*4+c])) } } }
    let med = (0..<3).map { c -> Int in let v = edge[c].sorted(); return v[v.count/2] }
    let mask = (0..<(res*res)).map { i -> Float in
        ((0..<3).map { abs(Int(px[i*4+$0]) - med[$0]) }.max() ?? 0) > 16 ? 1 : 0
    }
    let RT = MeshRender(); RT.loadMesh(verts, faces)
    let t0 = Date()
    if let fit = PoseFitter.fit(render: RT, photoMask: mask, res: res, seedElev: se, seedAzim: sa) {
        print(String(format: "seed e=%.1f a=%.1f -> got e=%.2f a=%.2f fov=%.0f scale=%.3f "
                     + "off=(%.3f,%.3f) residual=%.4f iou=%.3f [%.1fs]",
                     se, sa, fit.elev, fit.azim, fit.fovDeg, fit.scale, fit.offsetX, fit.offsetY,
                     fit.residual, fit.iou, Date().timeIntervalSince(t0)))
    } else { print("fit failed") }
    exit(0)
}

let albData = try Data(contentsOf: URL(fileURLWithPath: a[2]))
let mrData  = try Data(contentsOf: URL(fileURLWithPath: a[3]))
let views = PaintViewsResult(vertices: verts, faces: faces, uvs: uvs,
                             albedoSheetPNG: albData, mrSheetPNG: mrData, viewCount: 6)

let pipe = PaintPipeline(weightsRoot: "/nonexistent", tex: texSize)   // bake loads no weights
pipe.tex = texSize
let t0 = Date()
guard let r = pipe.bakePBR(views: views, albedoSheetPath: a[2], mrSheetPath: a[3]) else {
    FileHandle.standardError.write("bake failed\n".data(using: .utf8)!); exit(1)
}
try r.albedoPNG.write(to: URL(fileURLWithPath: a[4] + "_texture.png"))

// Render the baked atlas back onto the mesh so results can be compared by eye rather than
// by proxy metrics. Three-quarter views into the cabin are where the artifacts show.
let RR = MeshRender()
RR.loadMesh(r.vertices, r.faces)
var uvBack = r.uvs
for i in 0..<(uvBack.count/2) { uvBack[i*2+1] = 1 - uvBack[i*2+1] }
RR.setUV(uvBack, flipV: true)
if let img = try? MLXArray(loadPNGFloats(a[4] + "_texture.png"), [texSize, texSize, 3]) {
    // MODELR_RENDER_VIEW="elev,azim,res,out.png" writes one high-res view at a known camera
// pose — the image handed to an editor to complete, then fed back via MODELR_EXTRA_VIEW.
// Several specs may be given, separated by ";" — scoring candidate camera poses needs many
// renders of the same bake, and re-baking for each would dominate the cost.
for spec in (ProcessInfo.processInfo.environment["MODELR_RENDER_VIEW"]?
                .split(separator: ";").map(String.init) ?? []) {
    let f = spec.split(separator: ",").map(String.init)
    if f.count == 4, let e = Float(f[1]), let az = Float(f[2]), let res = Int(f[3].isEmpty ? "1024" : f[3]) {
        saveRGB(RR.renderTextured(e, az, res, img), f[0])
        print("rendered view elev=\(e) azim=\(az) res=\(res) -> \(f[0])")
    }
}
    let shots = [RR.renderTextured(35, 20, 512, img),
                 RR.renderTextured(35, 200, 512, img),
                 RR.renderTextured(70, 90, 512, img)]
    saveRGB(concatenated(shots, axis: 1), a[4] + "_render.png")
}
try r.metallicRoughnessPNG.write(to: URL(fileURLWithPath: a[4] + "_mr.png"))
if let cov = r.coveragePNG {
    try cov.write(to: URL(fileURLWithPath: a[4] + "_coverage.png"))
    if let cimg = try? MLXArray(loadPNGFloats(a[4] + "_coverage.png"), [texSize, texSize, 3]) {
        for spec in (ProcessInfo.processInfo.environment["MODELR_RENDER_COVERAGE"]?
                        .split(separator: ";").map(String.init) ?? []) {
            let f = spec.split(separator: ",").map(String.init)
            if f.count == 4, let e = Float(f[1]), let az = Float(f[2]), let res = Int(f[3]) {
                saveRGB(RR.renderTextured(e, az, res, cimg), f[0])
            }
        }
    }
}
print(String(format: "baked %d faces at %d in %.1fs -> %@_texture.png", m, texSize, Date().timeIntervalSince(t0), a[4]))
