import Foundation
import MLX
import MLXRandom

/// Weight loading from the original torch safetensors (NCHW conv → NHWC transpose + substring renames).
public enum Weights {
    public static func loadTorch(_ path: String, renames: [(String, String)] = []) throws -> [String: MLXArray] {
        let sd = try loadArrays(url: URL(fileURLWithPath: path))
        var out = [String: MLXArray]()
        for (k0, v0) in sd {
            var k = k0
            for (a, b) in renames { k = k.replacingOccurrences(of: a, with: b) }
            out[k] = (v0.ndim == 4 ? v0.transposed(0, 2, 3, 1) : v0).asType(.float32)
        }
        return out
    }
    public static func splitPBR(_ all: [String: MLXArray]) -> (W, W) {
        var main = [String: MLXArray](), dual = [String: MLXArray]()
        for (k, v) in all {
            if k.hasPrefix("unet_dual.") { dual[String(k.dropFirst(10))] = v }
            else if k.hasPrefix("unet.") { main[String(k.dropFirst(5))] = v }
        }
        return (W(main), W(dual))
    }
}

/// Result geometry + baked texture from a paint run. Format-agnostic — the caller
/// serializes to whatever mesh format it uses (Modelr writes a `.tmesh` + PNG).
public struct PaintResult {
    public let vertices: [Float]   // flat xyz, unwrapped geometry
    public let faces: [UInt32]     // flat triangle indices
    public let uvs: [Float]        // flat uv, viewer convention (v-flipped to top-left)
    public let albedoPNG: Data     // baked base-color texture as PNG bytes
}

/// PBR paint result: same geometry contract as `PaintResult`, plus the second baked map.
/// `metallicRoughnessPNG` uses the glTF channel packing the model produces: G = roughness,
/// B = metallic (R unused). Feed both PNGs to `writeGLB` or the app's own serializer.
public struct PBRPaintResult {
    public let vertices: [Float]            // flat xyz, unwrapped geometry
    public let faces: [UInt32]              // flat triangle indices
    public let uvs: [Float]                 // flat uv, viewer convention (v-flipped to top-left)
    public let albedoPNG: Data              // baked base-color texture as PNG bytes
    public let metallicRoughnessPNG: Data   // baked MR texture as PNG bytes (G=roughness, B=metallic)
    /// The albedo with every texel no view has painted head-on made transparent — exactly the
    /// surfaces a reference photograph is allowed to paint. Shown while aligning, with the photo
    /// behind the model, so those surfaces read as the photo showing through.
    public let coveragePNG: Data?
}

/// Output of the view-generation half of a PBR paint run, before anything is projected into the
/// atlas. The two sheets are horizontal strips of `viewCount` tiles — flat, undistorted renders
/// that can be exported, edited, and handed back to `bakePBR`.
///
/// `uvs` here are RAW (not v-flipped): `bakePBR` feeds them straight to `setUV(_:flipV: true)`.
/// `PBRPaintResult.uvs` by contrast is v-flipped for the viewer. Keep them straight or the bake
/// will land upside down.
/// A reference image registered against a known camera pose, baked alongside the six
/// canonical views. Either a photograph the user aligned by orbiting the model, or a
/// generated completion — the bake cannot tell them apart and does not need to.
public struct ExtraView {
    public let imagePath: String
    public let elev: Float
    public let azim: Float
    public let weight: Float
    /// Horizontal field of view in degrees, or 0 for an orthographic projection like the
    /// canonical views. A photograph taken close to the subject needs this to line up at all.
    public let fovDeg: Float
    /// Win outright wherever this view sees the surface, rather than being damped toward zero
    /// anywhere canonical coverage already exists. See `bakeMulti`'s `overrideViews`.
    public let overrides: Bool
    public init(imagePath: String, elev: Float, azim: Float, weight: Float = 0.5,
                fovDeg: Float = 0, overrides: Bool = false) {
        self.imagePath = imagePath; self.elev = elev; self.azim = azim; self.weight = weight
        self.fovDeg = fovDeg; self.overrides = overrides
    }
}

public struct PaintViewsResult {
    public let vertices: [Float]            // flat xyz, unwrapped geometry
    public let faces: [UInt32]              // flat triangle indices
    public let uvs: [Float]                 // flat uv, RAW (pre v-flip) — for bakePBR
    public let albedoSheetPNG: Data         // [H, W*viewCount, 3] albedo strip
    public let mrSheetPNG: Data             // [H, W*viewCount, 3] metallic-roughness strip
    public let viewCount: Int

    /// The same views still in memory, when this came straight from `paintViewsPBR`. Lets an
    /// immediate bake skip a pointless PNG encode → temp file → decode round-trip; nil when
    /// the result was rebuilt from disk, where the sheets are the only source.
    public let albedoViews: [MLXArray]?
    public let mrViews: [MLXArray]?

    /// Explicit because the compiler-supplied memberwise init is internal — the app rebuilds
    /// this from files on disk to bake a paint run it did not just produce.
    public init(vertices: [Float], faces: [UInt32], uvs: [Float],
                albedoSheetPNG: Data, mrSheetPNG: Data, viewCount: Int,
                albedoViews: [MLXArray]? = nil, mrViews: [MLXArray]? = nil) {
        self.vertices = vertices
        self.faces = faces
        self.uvs = uvs
        self.albedoSheetPNG = albedoSheetPNG
        self.mrSheetPNG = mrSheetPNG
        self.viewCount = viewCount
        self.albedoViews = albedoViews
        self.mrViews = mrViews
    }
}

/// Paint pipeline in Swift: mesh + image → textured geometry. Port of run_paint*.py.
/// A class so loaded model weights stay resident across runs.
public final class PaintPipeline {
    let weightsRoot: String
    public var res: Int, steps: Int, tex: Int    // per-run knobs; do not affect which weights load
    // Audit fix (b): CFG guidance is per-model (RGB/2.0 uses 2.0, PBR/2.1 uses 3.0 — matches
    // scripts/run_paint.py and scripts/run_paint_pbr.py). It was previously hardcoded to 3.0 for
    // both paths; it is now a per-method parameter with the correct default per model.
    let sf: Float = 0.18215
    let superRes: Bool
    let elevs: [Float] = [0, 0, 0, 0, 90, -90]
    let azims: [Float] = [0, 90, 180, 270, 0, 180]
    let vw: [Float] = [1, 0.1, 0.5, 0.1, 0.05, 0.05]

    // Resident RGB (2.0) models, loaded once on first paintRGB.
    private var rgb: (vae: PaintVAE, wrap: Paint20Wrapper, sr: RealESRGAN?, gen: MLXArray)?
    // Resident PBR (2.1) models, loaded once on first paintPBR.
    private var pbr: (vae: PaintVAE, wrap: PBRWrapper, dino: Dinov2, sr: RealESRGAN?)?

    public init(weightsRoot: String, res: Int = 512, steps: Int = 15, tex: Int = 4096, superRes: Bool = true) {
        self.weightsRoot = weightsRoot; self.res = res; self.steps = steps; self.tex = tex; self.superRes = superRes
    }

    private func loadRGB() throws -> (vae: PaintVAE, wrap: Paint20Wrapper, sr: RealESRGAN?, gen: MLXArray) {
        if let r = rgb { return r }
        let vae = PaintVAE(W(try Weights.loadTorch("\(weightsRoot)/hunyuan3d-paint-v2-0/vae/diffusion_pytorch_model.safetensors",
                                               renames: [(".to_out.0.", ".to_out.")])))
        let (mainW, dualW) = Weights.splitPBR(try Weights.loadTorch("\(weightsRoot)/hunyuan3d-paint-v2-0/unet/diffusion_pytorch_model.safetensors",
                                                                renames: [("transformer_blocks.0.transformer.", "transformer_blocks.0.")]))
        let wrap = Paint20Wrapper(main: mainW, dual: dualW)
        // Super-res weights are a converted (non-HF) file; if absent, paint still works
        // without the x4 upscale rather than crashing.
        var sr: RealESRGAN? = nil
        if superRes,
           let arrs = try? loadArrays(url: URL(fileURLWithPath: "\(weightsRoot)/realesrgan/rrdbnet_mlx.safetensors")) {
            sr = RealESRGAN(W(arrs.mapValues { $0.asType(.float32) }))
        }
        let r = (vae, wrap, sr, mainW.a("learned_text_clip_gen"))
        rgb = r
        return r
    }

    private func loadPBR() throws -> (vae: PaintVAE, wrap: PBRWrapper, dino: Dinov2, sr: RealESRGAN?) {
        if let r = pbr { return r }
        let vae = PaintVAE(W(try Weights.loadTorch("\(weightsRoot)/hunyuan3d-paint-v2-0/vae/diffusion_pytorch_model.safetensors",
                                               renames: [(".to_out.0.", ".to_out.")])))
        let (mainW, dualW) = Weights.splitPBR(try Weights.loadTorch("\(weightsRoot)/hunyuan3d-paintpbr-v2-1/unet/diffusion_pytorch_model.safetensors"))
        let wrap = PBRWrapper(main: mainW, dual: dualW, nPbr: 2)
        let dino = Dinov2(W(try Weights.loadTorch("\(weightsRoot)/dinov2-giant/model.safetensors")))
        // Same graceful degrade as loadRGB: absent super-res weights skip the x4 upscale.
        var sr: RealESRGAN? = nil
        if superRes,
           let arrs = try? loadArrays(url: URL(fileURLWithPath: "\(weightsRoot)/realesrgan/rrdbnet_mlx.safetensors")) {
            sr = RealESRGAN(W(arrs.mapValues { $0.asType(.float32) }))
        }
        let r = (vae, wrap, dino, sr)
        pbr = r
        return r
    }

    /// CLI-shaped PBR paint: file paths in, GLB out. Thin shell over `paintPBR` — the pipeline
    /// core is shared with the app entry point; this only loads the mesh, writes the debug
    /// texture PNGs next to the output, and serializes the GLB.
    public func run(meshPath: String, imagePath: String, outGLB: String,
                    guidance: Float = 3.0) throws {
        let t0 = Date()
        func log(_ s: String) { print("[pipeline] \(s)  (\(Int(-t0.timeIntervalSinceNow))s)") }
        let mesh = loadMesh(meshPath)
        guard let r = try paintPBR(mesh: mesh, imagePath: imagePath, guidance: guidance,
                                   debugPathPrefix: outGLB,
                                   onProgress: { s, _ in log(s) }) else { return }
        // debug: the baked textures next to the GLB (same bytes that get embedded)
        try r.albedoPNG.write(to: URL(fileURLWithPath: "\(outGLB).albedo.png"))
        try r.metallicRoughnessPNG.write(to: URL(fileURLWithPath: "\(outGLB).mr.png"))
        try writeGLB(path: outGLB, vertices: r.vertices, faces: r.faces, uvs: r.uvs,
                     baseColorPNG: r.albedoPNG, metallicRoughnessPNG: r.metallicRoughnessPNG)
        log("DONE → \(outGLB)")
    }

    /// 2.0 RGB paint: geometry + reference image → unwrapped geometry + baked base-color texture.
    /// Polls `isCancelled` (returns nil if it fires); streams decoded view grids via `onViews`.
    public func paintRGB(mesh: LoadedMesh, imagePath: String, guidance: Float = 2.0,
                         seed: UInt64 = 0,
                         onProgress: ((String, Float) -> Void)? = nil,
                         isCancelled: () -> Bool = { false },
                         onViews: ((Data) -> Void)? = nil) throws -> PaintResult? {
        onProgress?("Loading paint model", 0.02)
        let (vae, wrap, srModel, gen) = try loadRGB()
        if isCancelled() { return nil }

        onProgress?("Unwrapping UVs", 0.05)
        guard let uw = xatlasUnwrap(vertices: mesh.vertices, vertexCount: mesh.vertexCount,
                                    faces: mesh.faces, faceCount: mesh.faceCount) else { return nil }
        var V = [Float](repeating: 0, count: uw.vertexCount * 3)
        for i in 0..<uw.vertexCount { let o = Int(uw.vmapping[i]) * 3; V[i*3] = mesh.vertices[o]; V[i*3+1] = mesh.vertices[o+1]; V[i*3+2] = mesh.vertices[o+2] }
        let R = MeshRender(); R.loadMesh(V, uw.indices); R.setUV(uw.uvs, flipV: true)
        if isCancelled() { return nil }

        onProgress?("Rendering control maps", 0.1)
        let ctrl = zip(elevs, azims).map { R.renderControl($0.0, $0.1, res) }
        let normals = ctrl.map { $0.0 }, positions = ctrl.map { $0.1 }
        func enc(_ imgs: [MLXArray]) -> MLXArray { vae.encodeMean(stacked(imgs) * 2 - 1) * sf }
        let normalLat = enc(normals).expandedDimensions(axis: 0)
        let positionLat = enc(positions).expandedDimensions(axis: 0)
        let refLat = enc([prepRGB(imagePath, res)]).expandedDimensions(axis: 0)   // [1,1,h,w,4]
        let N = elevs.count, h = res / 8
        if isCancelled() { return nil }

        let (sig, ts) = uniPCSchedule(steps)
        let sched = UniPCScheduler(sigmas: sig, timesteps: ts)
        MLXRandom.seed(seed)
        var latents = MLXRandom.normal([1, N, h, h, 4])
        let ced = wrap.prepare(refLat: refLat)
        let neg = zeros(gen.shape)
        let camGen = (0..<N).map { Int32($0) }
        for (i, t) in ts.enumerated() {
            if isCancelled() { return nil }
            let tArr = MLXArray(Array(repeating: Float(t), count: N))
            let vc = wrap.predict(latents, tArr, text: gen, normalLat: normalLat, positionLat: positionLat, camGen: camGen, ced: ced, mvaScale: 1, refScale: 1)
            let vu = wrap.predict(latents, tArr, text: neg, normalLat: normalLat, positionLat: positionLat, camGen: camGen, ced: nil, mvaScale: 1, refScale: 0)
            latents = sched.step(vu + guidance * (vc - vu), t, latents); eval(latents)
            onProgress?("Painting (\(i+1)/\(steps))", 0.15 + 0.6 * Float(i + 1) / Float(steps))
            if let onViews, i % 3 == 2 || i == steps - 1 {
                let prev = clip((vae.decode(latents[0] / sf) + 1) / 2, min: 0, max: 1)   // [N,H,W,3]
                let grid = concatenated((0..<N).map { prev[$0] }, axis: 1)
                if let d = pngData(grid) { onViews(d) }
            }
            MLX.Memory.clearCache()                    // release per-step UNet/decode buffers
        }
        if isCancelled() { return nil }

        onProgress?("Decoding views", 0.8)
        let dd = clip((vae.decode(latents[0] / sf) + 1) / 2, min: 0, max: 1)       // [N,H,W,3]
        var views = (0..<N).map { dd[$0] }
        if let sr = srModel {
            onProgress?("Super-resolving", 0.88)
            views = views.map { clip(sr($0.expandedDimensions(axis: 0))[0], min: 0, max: 1) }; eval(views[0])
        }
        if isCancelled() { return nil }

        onProgress?("Baking texture", 0.93)
        let (texs, covered, _, _) = R.bakeMulti([views], elevs, azims, textureSize: tex, weights: vw)
        let texC = MeshRender.inpaint(texs[0], covered); eval(texC)
        guard let albedoPNG = pngData(texC) else { return nil }
        var uvOut = uw.uvs
        for i in 0..<(uvOut.count / 2) { uvOut[i*2+1] = 1 - uvOut[i*2+1] }          // v-flip → viewer top-left
        onProgress?("Done", 1.0)
        return PaintResult(vertices: V, faces: uw.indices, uvs: uvOut, albedoPNG: albedoPNG)
    }

    /// 2.1 PBR paint: geometry + reference image → unwrapped geometry + baked albedo and
    /// metallic-roughness textures. Same contract as `paintRGB`: polls `isCancelled` (returns
    /// nil if it fires), streams decoded albedo view grids via `onViews`, reports stages via
    /// `onProgress`. Debug artifacts are written only when `debugPathPrefix` is set (the CLI
    /// passes the output GLB path): `<prefix>.views.png` and `<prefix>.rendercheck.png`.
    ///
    /// This is now `paintViewsPBR` followed by `bakePBR`; split so the sheets can be exported
    /// and edited in between. Behaviour when called end-to-end is unchanged.
    public func paintPBR(mesh: LoadedMesh, imagePath: String, guidance: Float = 3.0,
                         seed: UInt64 = 0,
                         debugPathPrefix: String? = nil,
                         onProgress: ((String, Float) -> Void)? = nil,
                         isCancelled: () -> Bool = { false },
                         onViews: ((Data) -> Void)? = nil) throws -> PBRPaintResult? {
        guard let v = try paintViewsPBR(mesh: mesh, imagePath: imagePath, guidance: guidance,
                                        seed: seed, debugPathPrefix: debugPathPrefix,
                                        onProgress: onProgress, isCancelled: isCancelled,
                                        onViews: onViews) else { return nil }
        if isCancelled() { return nil }
        return bakePBR(views: v, albedoSheetPath: nil, mrSheetPath: nil,
                       weights: nil, debugPathPrefix: debugPathPrefix, onProgress: onProgress)
    }

    /// Bake half of a PBR run: project view sheets onto the atlas and inpaint the gaps. Needs no
    /// model weights — just the rasterizer — so it runs in seconds and can be repeated cheaply.
    ///
    /// Pass `albedoSheetPath` / `mrSheetPath` to bake *edited* sheets instead of the ones the
    /// model produced; each must be a horizontal strip of `views.viewCount` tiles (any
    /// resolution, as long as the tiles are square-ish and equal width). Nil falls back to the
    /// sheets carried in `views`. `weights` overrides the per-view blend weights — the defaults
    /// weight top and bottom at 0.05 against the reference view's 1.0, so raise them here if
    /// hand-painted roof or underside detail is getting washed out by `inpaint`.
    public func bakePBR(views: PaintViewsResult,
                        albedoSheetPath: String? = nil,
                        mrSheetPath: String? = nil,
                        weights: [Float]? = nil,
                        extraViews: [ExtraView] = [],
                        debugPathPrefix: String? = nil,
                        onProgress: ((String, Float) -> Void)? = nil) -> PBRPaintResult? {
        let n = views.viewCount
        // Alpha is kept only for the albedo sheet: paint it transparent there and the glass
        // comes through. The MR sheet is composited as before — roughness has no alpha.
        func sheetRGBA(_ path: String?, _ fallback: Data) -> (rgb: [MLXArray], alpha: [MLXArray])? {
            if let path, let edited = loadViewSheetAlpha(path, count: n) { return edited }
            guard let tmp = try? writeTempPNG(fallback) else { return nil }
            defer { try? FileManager.default.removeItem(at: tmp) }
            return loadViewSheetAlpha(tmp.path, count: n)
        }
        func sheet(_ path: String?, _ fallback: Data) -> [MLXArray]? {
            if let path, let edited = loadViewSheet(path, count: n) { return edited }
            guard let tmp = try? writeTempPNG(fallback) else { return nil }
            defer { try? FileManager.default.removeItem(at: tmp) }
            return loadViewSheet(tmp.path, count: n)
        }
        // Straight from paintViewsPBR with no edited sheet to honour: use the arrays we
        // already hold. Model output has no alpha, so the alpha pass is skipped outright.
        let alb: [MLXArray], alpha: [MLXArray]?
        let mrViews: [MLXArray]
        if albedoSheetPath == nil, mrSheetPath == nil,
           let a = views.albedoViews, let m = views.mrViews, a.count == n, m.count == n {
            alb = a; mrViews = m; alpha = nil
        } else {
            guard let albRGBA = sheetRGBA(albedoSheetPath, views.albedoSheetPNG),
                  let m = sheet(mrSheetPath, views.mrSheetPNG),
                  albRGBA.rgb.count == n, m.count == n else { return nil }
            alb = albRGBA.rgb; mrViews = m
            // Only pay for the alpha pass when the sheet actually carries transparency.
            alpha = albRGBA.alpha.contains { $0.min().item(Float.self) < 0.999 }
                ? albRGBA.alpha : nil
        }
        let mr = mrViews
        // MODELR_BAKE_ALPHA=0 bakes the windows opaque, ignoring any transparency painted into
        // the view sheets. Carrying that alpha through splits the mesh into body and glass, and
        // where the painted alpha region does not line up with the frame geometry the split
        // tears the window surrounds apart — clean bodywork, shredded pillars. Opaque glass is
        // the safe default for an asset that has no modelled interior behind the windows.
        let hasAlpha = (alpha != nil)
            && ProcessInfo.processInfo.environment["MODELR_BAKE_ALPHA"] != "0"

        let R = MeshRender()
        R.loadMesh(views.vertices, views.faces)
        R.setUV(views.uvs, flipV: true)

        onProgress?("Baking textures", 0.93)
        let envB = ProcessInfo.processInfo.environment
        // cos^6 is brutally peaky — a face 45° off-camera contributes ~0.09 — so anything not
        // near-normal to a canonical axis is effectively unbaked and handed to the fill. cos^4
        // still hides seams across six views while keeping far more of the sheet's real data.
        let falloff = Float(envB["MODELR_BAKE_EXP"] ?? "") ?? 4
        // The stock weights front-load heavily (side views 0.1 against the front's 1.0). That
        // suits a convex blob whose best-conditioned view is the reference, but a car's doors,
        // sills and wheels are seen almost only side-on, so grazing front/rear samples can win
        // over good side ones. MODELR_VIEW_WEIGHTS="1,0.7,0.7,0.7,0.3,0.3" to rebalance.
        let envWeights = envB["MODELR_VIEW_WEIGHTS"]?
            .split(separator: ",").compactMap { Float($0.trimmingCharacters(in: .whitespaces)) }
        let useWeights = weights ?? (envWeights?.count == elevs.count ? envWeights! : vw)
        // Depth tolerance for "is this texel the surface the view actually saw". The stock
        // 0.05 is loose against a model roughly one unit across, so an interior texel can
        // match the body behind it and take its colour — dark flecks on lit surfaces.
        let depthEps = Float(envB["MODELR_DEPTH_EPS"] ?? "") ?? 0.05
        var albV = alb, mrV = mr
        var poseElevs = elevs, poseAzims = azims

        // An extra, non-canonical view: a render of the model from an angle that sees into
        // occluded geometry (a cabin interior), completed by an image model. The six canonical
        // views physically cannot reach those surfaces — they are occluded, not merely
        // foreshortened — so this is the only way to give the bake real pixels there rather
        // than a fill heuristic. Format: "<png>,<elev>,<azim>,<weight>".
        // Several may be given, separated by ";" — one imagined view only reaches surfaces its
        // own camera can see, so obliques from different azimuths each recover a different
        // slice of the occluded geometry.
        var extraWeights: [Float] = []
        var extraFovs: [Float] = []
        // Passed-in views first, then any from the environment (the CLI harness uses env).
        var extras = extraViews
        for spec in (envB["MODELR_EXTRA_VIEW"]?.split(separator: ";").map(String.init) ?? []) {
            let f = spec.split(separator: ",").map(String.init)
            if f.count >= 4, let e = Float(f[1]), let az = Float(f[2]), let w = Float(f[3]) {
                extras.append(ExtraView(imagePath: f[0], elev: e, azim: az, weight: w,
                                        fovDeg: f.count > 4 ? (Float(f[4]) ?? 0) : 0,
                                        overrides: f.count > 5 && f[5] == "1"))
            }
        }
        var refMasks: [MLXArray?] = Array(repeating: nil, count: elevs.count)
        // Indices into the combined (canonical + extra) pose arrays that should win outright
        // rather than be gated/damped against canonical coverage — see `bakeMulti`.
        var overrideIndices: Set<Int> = []
        for ev in extras {
            guard let img = loadViewSheet(ev.imagePath, count: 1)?.first else {
                onProgress?("Reference view unreadable: \(ev.imagePath)", 0.93); continue
            }
            refMasks.append(PaintPipeline.backdropMask(img))
            let e = ev.elev, az = ev.azim, w = ev.weight
            albV.append(img)
            // No MR for a generated view: a luminance-neutral stand-in so the extra camera
            // cannot distort roughness/metallic.
            mrV.append(MLX.zeros(img.shape) + 0.5)
            poseElevs.append(e); poseAzims.append(az); extraWeights.append(w)
            extraFovs.append(ev.fovDeg)
            if ev.overrides { overrideIndices.insert(poseElevs.count - 1) }
        }
        let extraWeight: Float? = extraWeights.isEmpty ? nil : extraWeights[0]
        var alphaSet = alpha
        if !extraWeights.isEmpty, var av = alphaSet {
            while av.count < albV.count { av.append(MLX.ones(albV[0].shape)) }  // generated = opaque
            alphaSet = av
        }
        let sets = alphaSet.map { [albV, mrV, $0] } ?? [albV, mrV]
        let bakeWeights = useWeights + extraWeights
        // Gate references to where the canonical views fall short. `MODELR_REF_GATE=0` restores
        // the old behaviour of averaging them in everywhere, for comparison.
        let gateOff = envB["MODELR_REF_GATE"] == "0"
        let nCanon: Int? = (extraWeights.isEmpty || gateOff) ? nil : useWeights.count
        // Canonical weight at which a reference is half suppressed. Everything the canonical
        // pass actually painted sits orders of magnitude above it; everything it skipped is 0.
        let rTau = Float(envB["MODELR_REF_TAU"] ?? "") ?? 1e-3
        let rDeg = Float(envB["MODELR_REF_COS_DEG"] ?? "") ?? 65
        let aDeg = Float(envB["MODELR_REF_ADEQ_DEG"] ?? "") ?? 65
        let rMin = Float(envB["MODELR_REF_MIN_W"] ?? "") ?? 1e-4
        let fovs: [Float?]? = extraFovs.contains(where: { $0 > 1 })
            ? Array(repeating: nil, count: useWeights.count) + extraFovs.map { $0 > 1 ? $0 : nil }
            : nil
        var (texs, covered, adequate, faceOn) = R.bakeMulti(sets, poseElevs, poseAzims, textureSize: tex,
                                          exp: falloff, weights: bakeWeights, eps: depthEps,
                                          canonicalCount: nCanon, refTau: rTau, refCosThrDeg: rDeg,
                                          adequacyDeg: aDeg, refMinWeight: rMin, viewFov: fovs,
                                          // Set 2 is alpha — a mask, taken from the best view
                                          // rather than blended across views.
                                          winnerSets: alphaSet != nil ? [2] : [],
                                          validMasks: nCanon == nil ? nil : refMasks,
                                          overrideViews: overrideIndices)

        // Second pass for texels the strict cutoff left empty — wheel arches and interiors are
        // grazing in every canonical view, so they otherwise get no real data at all. Used only
        // where the first pass found nothing, so it never dilutes a good sample.
        if envB["MODELR_NO_RELAXED_PASS"] != "1" {
            let anyEmpty = (covered.asType(.int32).sum().item(Int32.self)) < Int32(tex * tex)
            if anyEmpty {
                let relaxDeg = Float(envB["MODELR_RELAXED_DEG"] ?? "") ?? 88
                // Canonical views only. The references already had their turn in the strict
                // pass, and this pass exists to manufacture something for texels nothing saw —
                // it must never end up competing with an actual photograph.
                let nc = useWeights.count
                let (rTexs, rCov, _, _) = R.bakeMulti(sets.map { Array($0.prefix(nc)) },
                                                Array(poseElevs.prefix(nc)),
                                                Array(poseAzims.prefix(nc)), textureSize: tex,
                                                exp: falloff, weights: useWeights, eps: depthEps,
                                                cosThrDeg: relaxDeg)
                let use = rCov .&& (covered .!= true)                  // only where strict failed
                let use3 = use.expandedDimensions(axis: -1)
                for i in 0 ..< texs.count { texs[i] = MLX.where(use3, rTexs[i], texs[i]) }
                covered = covered .|| use
            }
        }
        // Un-covered texels are filled by a bounded dilation rather than the stock EDT flood,
        // which is chart-blind and drags colour across the atlas from unrelated charts (see
        // MeshRender.dilateFill). MODELR_FILL_LEGACY=1 restores the old behaviour for A/B;
        // MODELR_FILL_DEBUG=1 paints the gaps magenta to show what the fill is inventing.
        let env = ProcessInfo.processInfo.environment
        let fillRadius = Int(env["MODELR_FILL_RADIUS"] ?? "") ?? 4
        // One connected component per UV chart. Confines the fill so an interior pocket cannot
        // take colour from the bodywork chart packed a couple of texels away.
        let uvr = R.uvRasterize(tex)
        let texPositions = uvr.0
        let inside = uvr.2.reshaped([tex * tex]).asType(.int32).asArray(Int32.self).map { $0 != 0 }
        let chartIDs: [Int32]? = env["MODELR_FILL_NO_CHARTS"] == "1"
            ? nil : MeshRender.chartLabels(inside, H: tex, W: tex)
        func fill(_ t: MLXArray) -> MLXArray {
            if env["MODELR_FILL_DEBUG"] == "1" {
                let mask = covered.expandedDimensions(axis: -1)              // [T,T,1]
                let one = MLX.ones(t[0..., 0..., 0..<1].shape)
                let magenta = concatenated([one, MLX.zeros(one.shape), one], axis: -1)
                return MLX.where(mask, t, magenta)
            }
            if env["MODELR_FILL_LEGACY"] == "1" { return MeshRender.inpaint(t, covered) }
            if env["MODELR_FILL_2D"] == "1" {
                return MeshRender.dilateFill(t, covered, radius: fillRadius, charts: chartIDs)
            }
            // Default: nearest covered texel on the SURFACE, not in the atlas packing.
            return MeshRender.surfaceFill(t, covered, positions: texPositions,
                                          normals: env["MODELR_FILL_IGNORE_NORMALS"] == "1"
                                                   ? nil : uvr.1,
                                          inside: inside, gutterRadius: fillRadius,
                                          minDot: Float(env["MODELR_FILL_MIN_DOT"] ?? "") ?? 0.2)
        }
        var texA = fill(texs[0]); let texM = fill(texs[1])
        // Un-covered texels inpaint to *opaque*: a gap in coverage is missing data, not glass.
        // Glass takes its colour from the single most face-on view instead of the blend. Two
        // views of the same window disagree completely — one sees sky on the outside, the other
        // sees the dashboard through it — and averaging them produces the shattered patchwork.
        // Bodywork keeps the blend, which is what keeps it smooth.
        if ProcessInfo.processInfo.environment["MODELR_ALPHA_DEBUG"] == "1" {
            FileHandle.standardError.write("MODELR_ALPHA_DEBUG hasAlpha=\(hasAlpha)\n".data(using: .utf8)!)
            if hasAlpha {
                let rawMin = texs[2].min().item(Float.self)
                let rawMean = texs[2].mean().item(Float.self)
                let inpainted = MeshRender.inpaint(texs[2], covered)
                let inMin = inpainted.min().item(Float.self)
                let inMean = inpainted.mean().item(Float.self)
                FileHandle.standardError.write(
                    "MODELR_ALPHA_DEBUG texs[2] raw min=\(rawMin) mean=\(rawMean) | after inpaint min=\(inMin) mean=\(inMean)\n"
                        .data(using: .utf8)!)
            }
        }
        let texAlpha = hasAlpha ? MeshRender.sharpenGlassAlpha(
            MeshRender.inpaint(texs[2], covered), positions: texPositions) : nil
        if ProcessInfo.processInfo.environment["MODELR_ALPHA_DEBUG"] == "1", let texAlpha {
            let outMin = texAlpha.min().item(Float.self)
            let outMean = texAlpha.mean().item(Float.self)
            FileHandle.standardError.write(
                "MODELR_ALPHA_DEBUG texAlpha (post-sharpen) min=\(outMin) mean=\(outMean)\n"
                    .data(using: .utf8)!)
        }
        if let texAlpha {
            // Order matters and cost a round: these have to be applied to the FILLED atlas, not
            // to the pre-fill buffer, which nothing downstream reads any more.
            //
            // Glass takes its colour from the single most face-on view rather than the blend —
            // two views of one window disagree completely, one seeing sky on the outside and the
            // other the dashboard through it, and averaging them is the shattered patchwork.
            let glass = (texAlpha[0..., 0..., 0] .< 0.995).expandedDimensions(axis: -1)
            texA = MLX.where(glass, faceOn, texA)
            texA = MeshRender.smoothGlassColour(texA, alpha: texAlpha)
        }
        eval(texA, texM)
        if let p = debugPathPrefix {
            // debug: render the texture back onto the mesh (bypasses GLB) at 3 angles
            let dbg = [R.renderTextured(0, 20, 420, texA), R.renderTextured(0, 140, 420, texA), R.renderTextured(0, 260, 420, texA)]
            saveRGB(concatenated(dbg, axis: 1), "\(p).rendercheck.png")
        }
        let albedoData = texAlpha.map { pngDataRGBA(texA, $0) } ?? pngData(texA)
        guard let albedoPNG = albedoData, let mrPNG = pngData(texM) else { return nil }
        // Holes, not paint: texels nothing has painted head-on are made fully transparent, so
        // the aligner can show the reference photograph *through* the model. The user sees the
        // photo occupying exactly the surfaces the re-bake will hand it, which is a preview of
        // the result rather than a diagram of the gap.
        // pngDataRGBA reads alpha from a [H,W,3] array (it uses channel 0), so match that.
        let covA1 = adequate.expandedDimensions(axis: -1).asType(.float32)
        // Blown-out texels count as unpainted even when a view did reach them. The paint model
        // leaves flat near-white patches — wheel arches, sills, cabin edges — that carry no
        // information; treating them as painted hides exactly the surfaces a reference is needed
        // for. Only genuinely blown out values qualify (luma above 0.93, almost no saturation),
        // Thresholds picked by measurement rather than taste: at luma 0.84 / saturation 0.12 the
        // holes catch 88% of the flat white paint while the total hole area moves 40.7% -> 41.2%
        // of the model, so the bodywork itself is not being eaten.
        let cR: MLXArray = texA[0..., 0..., 0] * 0.2126
        let cG: MLXArray = texA[0..., 0..., 1] * 0.7152
        let cB: MLXArray = texA[0..., 0..., 2] * 0.0722
        let cLum: MLXArray = cR + cG + cB
        let cMax = texA.max(axis: 2), cMin = texA.min(axis: 2)
        let cSat = (cMax - cMin) / clip(cMax, min: 1e-6, max: Float.greatestFiniteMagnitude)
        let blown = (cLum .> (Float(envB["MODELR_COV_WHITE"] ?? "") ?? 0.84))
            .&& (cSat .< (Float(envB["MODELR_COV_SAT"] ?? "") ?? 0.12))
        var covA1b = MLX.where(blown.expandedDimensions(axis: -1),
                               MLX.zeros(covA1.shape), covA1)
        // Gutter texels belong to no triangle, so nothing ever "paints" them and they would all
        // read as holes. Bilinear filtering samples them at every chart edge, which outlined all
        // ~5,400 charts in magenta — every panel gap and wheel arch traced in colour. They are
        // not surface, so they are opaque here.
        let insideMask = uvr.2.reshaped([tex, tex, 1]).asType(.float32)
        covA1b = MLX.where(insideMask .> 0.5, covA1b, MLX.ones(covA1b.shape))
        let covAlpha = concatenated([covA1b, covA1b, covA1b], axis: -1)
        // Holes are marked in the COLOUR channels, not only in alpha. SceneKit would not honour
        // this atlas's alpha by any route tried — diffuse alpha, a `transparent` map, a texture
        // bound to a shader argument, premultiplied or straight — so relying on it left the
        // cabin rendering solid. Magenta is unmistakable and needs no transparency to survive.
        let magenta = concatenated([MLX.ones(covA1b.shape), MLX.zeros(covA1b.shape),
                                    MLX.ones(covA1b.shape)], axis: -1)
        let covRGB = MLX.where(covAlpha .> 0.5, texA, magenta)
        // Written opaque. pngDataRGBA premultiplies, so magenta in a zero-alpha texel would be
        // multiplied straight back to black — the mask has to live in the colour alone.
        let coveragePNG = pngData(covRGB)
        var uvOut = views.uvs
        for i in 0..<(uvOut.count / 2) { uvOut[i*2+1] = 1 - uvOut[i*2+1] }          // v-flip → viewer top-left
        onProgress?("Done", 1.0)
        return PBRPaintResult(vertices: views.vertices, faces: views.faces, uvs: uvOut,
                              albedoPNG: albedoPNG, metallicRoughnessPNG: mrPNG,
                              coveragePNG: coveragePNG)
    }

    private func writeTempPNG(_ data: Data) throws -> URL {
        let u = FileManager.default.temporaryDirectory
            .appendingPathComponent("mvsheet-\(UUID().uuidString).png")
        try data.write(to: u)
        return u
    }

    /// View-generation half of a PBR run: everything up to and including super-resolution.
    /// Stops before the atlas bake and hands back the flat view sheets plus the unwrapped
    /// geometry they belong to. Feed the result to `bakePBR`, optionally swapping in edited
    /// sheets. Splitting here is what makes a Shape → Paint → Bake flow possible: the expensive
    /// diffusion happens once, and re-baking an edited sheet costs seconds.
    public func paintViewsPBR(mesh: LoadedMesh, imagePath: String, guidance: Float = 3.0,
                              seed: UInt64 = 0,
                              debugPathPrefix: String? = nil,
                              onProgress: ((String, Float) -> Void)? = nil,
                              isCancelled: () -> Bool = { false },
                              onViews: ((Data) -> Void)? = nil) throws -> PaintViewsResult? {
        onProgress?("Loading paint model", 0.02)
        let (vae, wrap, dino, srModel) = try loadPBR()
        if isCancelled() { return nil }

        onProgress?("Unwrapping UVs", 0.05)
        guard let uw = xatlasUnwrap(vertices: mesh.vertices, vertexCount: mesh.vertexCount,
                                    faces: mesh.faces, faceCount: mesh.faceCount) else { return nil }
        var V = [Float](repeating: 0, count: uw.vertexCount * 3)               // original geometry gathered by vmapping
        for i in 0..<uw.vertexCount { let o = Int(uw.vmapping[i]) * 3; V[i*3] = mesh.vertices[o]; V[i*3+1] = mesh.vertices[o+1]; V[i*3+2] = mesh.vertices[o+2] }
        let R = MeshRender(); R.loadMesh(V, uw.indices); R.setUV(uw.uvs, flipV: true)
        if isCancelled() { return nil }

        onProgress?("Rendering control maps", 0.1)
        let ctrl = zip(elevs, azims).map { R.renderControl($0.0, $0.1, res) }
        let normals = ctrl.map { $0.0 }, positions = ctrl.map { $0.1 }
        func enc(_ imgs: [MLXArray]) -> MLXArray { vae.encodeMean(stacked(imgs) * 2 - 1) * sf }
        let normalLat = enc(normals).expandedDimensions(axis: 0)               // [1,N,h,w,4]
        let positionLat = enc(positions).expandedDimensions(axis: 0)
        let refLat = enc([prepRGB(imagePath, res)]).expandedDimensions(axis: 0) // [1,1,h,w,4]
        let di = imagenetNorm(prepRGB(imagePath, 518)).expandedDimensions(axis: 0)
        let dinoHS = dino(di)                                                   // [1,1370,1536]
        let posmap = stacked(positions).expandedDimensions(axis: 0)            // [1,N,res,res,3]
        let N = elevs.count, h = res / 8
        eval(normalLat, positionLat, refLat, dinoHS)
        if isCancelled() { return nil }

        let (sig, ts) = uniPCSchedule(steps)
        let sched = UniPCScheduler(sigmas: sig, timesteps: ts)
        MLXRandom.seed(seed)
        var latents = MLXRandom.normal([1, 2, N, h, h, 4])                     // dim 1: [albedo, mr]
        let (ced, dinoTok, rope) = wrap.prepare(refLat: refLat, dinoHidden: dinoHS, posmap: posmap, H: h, nGen: N)
        let dinoZero = zeros(dinoTok.shape)
        let nb = 1 * 2 * N
        for (i, t) in ts.enumerated() {
            if isCancelled() { return nil }
            let tArr = MLXArray(Array(repeating: Float(t), count: nb))
            let vc = wrap.predict(latents, tArr, normalLat: normalLat, positionLat: positionLat, ced: ced, dino: dinoTok, rope: rope, mvaScale: 1, refScale: 1)
            let vu = wrap.predict(latents, tArr, normalLat: normalLat, positionLat: positionLat, ced: nil, dino: dinoZero, rope: rope, mvaScale: 1, refScale: 0)
            latents = sched.step(vu + guidance * (vc - vu), t, latents); eval(latents)
            onProgress?("Painting (\(i+1)/\(steps))", 0.15 + 0.6 * Float(i + 1) / Float(steps))
            if let onViews, i % 3 == 2 || i == steps - 1 {
                let prev = clip((vae.decode(latents[0, 0] / sf) + 1) / 2, min: 0, max: 1)   // albedo [N,H,W,3]
                let grid = concatenated((0..<N).map { prev[$0] }, axis: 1)
                if let d = pngData(grid) { onViews(d) }
            }
            MLX.Memory.clearCache()                    // release per-step UNet/decode buffers
        }
        if isCancelled() { return nil }

        onProgress?("Decoding views", 0.8)
        func decode(_ lat: MLXArray) -> [MLXArray] {
            let d = clip((vae.decode(lat / sf) + 1) / 2, min: 0, max: 1)        // [N,H,W,3]
            return (0..<N).map { d[$0] }
        }
        var alb = decode(latents[0, 0]), mr = decode(latents[0, 1])
        if let p = debugPathPrefix { saveRGB(concatenated(alb, axis: 1), "\(p).views.png") }  // debug: albedo views grid
        if let sr = srModel {
            onProgress?("Super-resolving", 0.88)
            func up(_ v: MLXArray) -> MLXArray { clip(sr(v.expandedDimensions(axis: 0))[0], min: 0, max: 1) }
            alb = alb.map(up); mr = mr.map(up)
            eval(alb[0])
        }
        if isCancelled() { return nil }

        onProgress?("Encoding views", 0.92)
        guard let albSheet = pngData(concatenated(alb, axis: 1)),
              let mrSheet = pngData(concatenated(mr, axis: 1)) else { return nil }
        return PaintViewsResult(vertices: V, faces: uw.indices, uvs: uw.uvs,
                                albedoSheetPNG: albSheet, mrSheetPNG: mrSheet, viewCount: N,
                                albedoViews: alb, mrViews: mr)
    }
}

extension PaintPipeline {
    /// 1 on the object, 0 on the backdrop, for a reference photograph.
    ///
    /// The backdrop is what is both border-coloured (or studio white) and connected to the
    /// image border. That covers both things that must go — the photo's own
    /// studio background and the flat canvas the import is letterboxed onto to square it —
    /// without keying a colour. Keying mid grey by value, which is what this did first, deletes
    /// the door cards, console and grey trim: exactly the surfaces a reference is added to
    /// supply. Flooding from the border cannot, because those are not connected to it.
    ///
    /// Eroded slightly at the end: the object's edge pixels are anti-aliased against the
    /// backdrop and carry its colour.
    static func backdropMask(_ img: MLXArray, tol: Float = 0.06, erode: Int = 3) -> MLXArray {
        let h = img.dim(0), w = img.dim(1)
        let px = img.asType(.float32).asArray(Float.self)

        // Median colour around the border: whatever the image is matted onto.
        var edge = [[Float]](repeating: [], count: 3)
        for x in stride(from: 0, to: w, by: 4) {
            for y in [0, h - 1] { for c in 0..<3 { edge[c].append(px[(y*w + x)*3 + c]) } }
        }
        for y in stride(from: 0, to: h, by: 4) {
            for x in [0, w - 1] { for c in 0..<3 { edge[c].append(px[(y*w + x)*3 + c]) } }
        }
        let med = (0..<3).map { c -> Float in
            let v = edge[c].sorted(); return v.isEmpty ? 1 : v[v.count / 2]
        }

        // A pixel may be backdrop if it matches that colour, or is near-white and unsaturated
        // (a studio background). Both tests are against fixed values, never against the
        // neighbour that reached them: a relative test walks up a gradient and consumes the
        // whole car, which is what a first attempt at this did — it kept 0.7% of one photo.
        func candidate(_ i: Int) -> Bool {
            let r = px[i*3], g = px[i*3+1], b = px[i*3+2]
            if abs(r - med[0]) <= tol && abs(g - med[1]) <= tol && abs(b - med[2]) <= tol {
                return true
            }
            let luma = r * 0.2126 + g * 0.7152 + b * 0.0722
            let mx = max(r, max(g, b)), mn = min(r, min(g, b))
            return luma > 0.90 && (mx - mn) / max(mx, 1e-6) < 0.08
        }

        // Backdrop is what is BOTH a candidate and reachable from the border. Interior trim that
        // happens to sit in the same colour range survives, because it is walled off by the car.
        var bg = [Bool](repeating: false, count: h * w)
        var queue = [Int](); queue.reserveCapacity(h * w / 4)
        func seed(_ i: Int) { if !bg[i], candidate(i) { bg[i] = true; queue.append(i) } }
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
                if !bg[j], candidate(j) { bg[j] = true; queue.append(j) }
            }
        }

        var keep = bg.map { $0 ? Float(0) : Float(1) }
        for _ in 0 ..< max(0, erode) {
            var next = keep
            for y in 0..<h {
                for x in 0..<w where keep[y*w + x] > 0 {
                    if (y > 0 && keep[(y-1)*w + x] == 0) || (y < h-1 && keep[(y+1)*w + x] == 0)
                        || (x > 0 && keep[y*w + x-1] == 0) || (x < w-1 && keep[y*w + x+1] == 0) {
                        next[y*w + x] = 0
                    }
                }
            }
            keep = next
        }
        let m = MLXArray(keep, [h, w, 1])
        return concatenated([m, m, m], axis: 2)
    }
}
