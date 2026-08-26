import Foundation
import simd
import MLX

/// Mesh renderer — Swift port of mesh_render.py (cr-faithful rasterizer, AA off, NHWC).
/// Cameras + normalize in Swift Float; vertex transforms + bake in MLX; rasterize via SwiftRaster.
public final class MeshRender {
    let cameraDistance: Float
    let orthoScale: Float
    let scaleFactor: Float

    public private(set) var vtxPos: MLXArray = MLXArray([Float]())   // [V,3] normalized
    var posIdx: [Int32] = []                                          // [F*3]
    var faceCount = 0
    var vCount = 0
    var vtxUv: MLXArray = MLXArray([Float]())                         // [V,2] (v-flipped)
    var worldVN: MLXArray = MLXArray([Float]())                       // [V,3]
    private var projM: [Float]                                        // 4x4 row-major
    private var faceArr: MLXArray = MLXArray([Int32]())               // [F,3]

    /// Pixels of silhouette erosion applied to each view's coverage before sampling it, to stop
    /// the bilinear fetch straddling the object's edge and pulling in sheet background.
    /// Default 0: swept at 0/2/4/8 against the artifact count and it made no measurable
    /// difference, so it is off rather than costing work. MODELR_SILHOUETTE_ERODE to re-enable.
    static let silhouetteErode: Int =
        Int(ProcessInfo.processInfo.environment["MODELR_SILHOUETTE_ERODE"] ?? "") ?? 0

    public init(cameraDistance: Float = 1.45, orthoScale: Float = 1.2, scaleFactor: Float = 1.15) {
        self.cameraDistance = cameraDistance; self.orthoScale = orthoScale; self.scaleFactor = scaleFactor
        self.projM = MeshRender.orthoProj(scale: orthoScale)
    }

    // ---- camera matrices (computed in Double, cast to Float — matches numpy float64→float32) ----
    static func orthoProj(scale: Float, near: Double = 0, far: Double = 2) -> [Float] {
        let s = Double(scale)
        let l = -s*0.5, r = s*0.5, b = -s*0.5, t = s*0.5
        var m = [Double](repeating: 0, count: 16); m[15] = 1
        m[0] = 2/(r-l); m[5] = 2/(t-b); m[10] = -2/(far-near)
        m[3] = -(r+l)/(r-l); m[7] = -(t+b)/(t-b); m[11] = -(far+near)/(far-near)
        return m.map { Float($0) }
    }
    static func mvMatrix(elev: Float, azim: Float, dist: Float) -> [Float] {
        let e = -Double(elev), a = Double(azim) + 90, d = Double(dist)
        let er = e * .pi/180, ar = a * .pi/180
        let cam = [d*cos(er)*cos(ar), d*cos(er)*sin(ar), d*sin(er)]
        var lookat = [-cam[0], -cam[1], -cam[2]]
        let ln = norm(lookat); lookat = lookat.map { $0/ln }
        var up = [0.0, 0.0, 1.0]
        var right = cross(lookat, up); let rn = norm(right); right = right.map { $0/rn }
        up = cross(right, lookat); let un = norm(up); up = up.map { $0/un }
        let nl = [-lookat[0], -lookat[1], -lookat[2]]
        var w = [Double](repeating: 0, count: 16); w[15] = 1
        let rows = [right, up, nl]
        for i in 0..<3 {
            w[i*4+0] = rows[i][0]; w[i*4+1] = rows[i][1]; w[i*4+2] = rows[i][2]
            w[i*4+3] = -(rows[i][0]*cam[0] + rows[i][1]*cam[1] + rows[i][2]*cam[2])
        }
        return w.map { Float($0) }
    }
    static func cross(_ a: [Double], _ b: [Double]) -> [Double] {
        [a[1]*b[2]-a[2]*b[1], a[2]*b[0]-a[0]*b[2], a[0]*b[1]-a[1]*b[0]]
    }
    static func norm(_ a: [Double]) -> Double { (a[0]*a[0]+a[1]*a[1]+a[2]*a[2]).squareRoot() }

    // ---- mesh setup ----
    public func loadMesh(_ vertices: [Float], _ faces: [UInt32]) {
        vCount = vertices.count / 3; faceCount = faces.count / 3
        var v = vertices
        for i in 0..<vCount {                                   // flip X,Y ; swap Y,Z
            let x = -v[i*3+0], y = -v[i*3+1], z = v[i*3+2]
            v[i*3+0] = x; v[i*3+1] = z; v[i*3+2] = y
        }
        var mn = [Float](repeating: .greatestFiniteMagnitude, count: 3)
        var mx_ = [Float](repeating: -.greatestFiniteMagnitude, count: 3)
        for i in 0..<vCount { for k in 0..<3 { mn[k] = min(mn[k], v[i*3+k]); mx_[k] = max(mx_[k], v[i*3+k]) } }
        let ctr = [(mn[0]+mx_[0])/2, (mn[1]+mx_[1])/2, (mn[2]+mx_[2])/2]
        var maxr: Float = 0
        for i in 0..<vCount {
            let d = ((v[i*3]-ctr[0])*(v[i*3]-ctr[0]) + (v[i*3+1]-ctr[1])*(v[i*3+1]-ctr[1]) + (v[i*3+2]-ctr[2])*(v[i*3+2]-ctr[2])).squareRoot()
            maxr = max(maxr, d)
        }
        let scale = maxr * 2.0, s = scaleFactor / scale
        for i in 0..<vCount { for k in 0..<3 { v[i*3+k] = (v[i*3+k]-ctr[k]) * s } }
        vtxPos = MLXArray(v, [vCount, 3])
        posIdx = faces.map { Int32($0) }
        faceArr = MLXArray(posIdx, [faceCount, 3])
        worldVN = MeshRender.meanVertexNormals(v, posIdx, vCount, faceCount)
    }

    public func setUV(_ uv: [Float], flipV: Bool = true) {
        var u = uv
        if flipV { for i in 0..<(u.count/2) { u[i*2+1] = 1 - u[i*2+1] } }
        vtxUv = MLXArray(u, [u.count/2, 2])
    }

    static func meanVertexNormals(_ v: [Float], _ f: [Int32], _ nv: Int, _ nf: Int) -> MLXArray {
        var vn = [Double](repeating: 0, count: nv*3)
        for t in 0..<nf {
            let a = Int(f[t*3]), b = Int(f[t*3+1]), c = Int(f[t*3+2])
            let e1 = [v[b*3]-v[a*3], v[b*3+1]-v[a*3+1], v[b*3+2]-v[a*3+2]]
            let e2 = [v[c*3]-v[a*3], v[c*3+1]-v[a*3+1], v[c*3+2]-v[a*3+2]]
            var n = [Double(e1[1]*e2[2]-e1[2]*e2[1]), Double(e1[2]*e2[0]-e1[0]*e2[2]), Double(e1[0]*e2[1]-e1[1]*e2[0])]
            let ln = (n[0]*n[0]+n[1]*n[1]+n[2]*n[2]).squareRoot()
            let inv = ln < 1e-12 ? 0 : 1.0/ln; n = n.map { $0*inv }
            for k in 0..<3 { vn[a*3+k]+=n[k]; vn[b*3+k]+=n[k]; vn[c*3+k]+=n[k] }
        }
        var out = [Float](repeating: 0, count: nv*3)
        for i in 0..<nv {
            let ln = (vn[i*3]*vn[i*3]+vn[i*3+1]*vn[i*3+1]+vn[i*3+2]*vn[i*3+2]).squareRoot()
            let inv = ln < 1e-12 ? 0 : 1.0/ln
            for k in 0..<3 { out[i*3+k] = Float(vn[i*3+k]*inv) }
        }
        return MLXArray(out, [nv, 3])
    }

    // ---- transforms ----
    private func mvArray(_ elev: Float, _ azim: Float, _ dist: Float? = nil) -> MLXArray {
        MLXArray(MeshRender.mvMatrix(elev: elev, azim: azim, dist: dist ?? cameraDistance), [4, 4])
    }

    /// Binary silhouette of the loaded mesh from a candidate camera: 1 on the object, 0 off it.
    /// Small and cheap on purpose — pose fitting renders hundreds of these.
    public func silhouetteMask(elev: Float, azim: Float, fovDeg: Float, res: Int) -> [Float] {
        let vProj: MLXArray
        let dist: Float?
        if fovDeg > 1 {
            let d = MeshRender.perspDist(fovDeg: fovDeg, orthoScale: orthoScale)
            dist = d
            vProj = MLXArray(MeshRender.perspProj(fovDeg: fovDeg,
                                                  near: max(0.01, Double(d) - 1.5),
                                                  far: Double(d) + 1.5), [4, 4])
        } else {
            dist = nil
            vProj = MLXArray(projM, [4, 4])
        }
        let mv = MLXArray(MeshRender.mvMatrix(elev: elev, azim: azim,
                                              dist: dist ?? cameraDistance), [4, 4])
        let vw = concatenated([vtxPos, ones([vtxPos.dim(0), 1])], axis: 1)
        let clip = matmul(matmul(vw, mv.transposed(1, 0)), vProj.transposed(1, 0))
        let (fi, _) = SwiftRaster.rasterize(clip, faceArr, res)
        return (fi .> 0).asType(.float32).reshaped([res * res]).asArray(Float.self)
    }

    /// Perspective frustum for a reference shot with a real lens.
    ///
    /// The six canonical views are orthographic, and so is everything the bake normally does. A
    /// photograph is not: near parts of the car are larger than far ones, and no amount of
    /// orbit, scale or roll can reconcile that with a parallel projection — you can line up the
    /// front of the car or the back, never both. Distance is derived from the angle so framing
    /// stays put as the lens changes: the object keeps filling the frame exactly as it does
    /// under `orthoScale`, and only the convergence varies. So the control reads as a lens
    /// (long → short), not as a camera move.
    static func perspProj(fovDeg: Float, near: Double, far: Double) -> [Float] {
        let t = tan(Double(fovDeg) * .pi / 360)                 // tan(fov/2)
        var m = [Double](repeating: 0, count: 16)
        m[0] = 1 / t; m[5] = 1 / t
        m[10] = -(far + near) / (far - near)
        m[11] = -2 * far * near / (far - near)
        m[14] = -1
        return m.map { Float($0) }
    }
    /// Distance that keeps a `fovDeg` view framed like the orthographic one.
    static func perspDist(fovDeg: Float, orthoScale: Float) -> Float {
        Float(Double(orthoScale) * 0.5 / tan(Double(fovDeg) * .pi / 360))
    }
    func project(_ pos: MLXArray, _ elev: Float, _ azim: Float) -> (cam: MLXArray, clip: MLXArray) {
        let n = pos.dim(0)
        let posw = concatenated([pos, ones([n, 1])], axis: 1)
        let cam = matmul(posw, mvArray(elev, azim).transposed(1, 0))
        let pc = matmul(cam, MLXArray(projM, [4, 4]).transposed(1, 0))
        return (cam, pc)
    }

    /// normal (abs/world) + position control maps, NHWC [res,res,3] in [0,1].
    public func renderControl(_ elev: Float, _ azim: Float, _ res: Int, bg: Float = 1) -> (MLXArray, MLXArray) {
        let (_, pc) = project(vtxPos, elev, azim)
        let (fi, ba) = SwiftRaster.rasterize(pc, faceArr, res)
        let maskF = (fi .> 0).reshaped([res, res, 1]).asType(.float32)
        let bgv = MLXArray(bg)
        var normal = SwiftRaster.interpolate(worldVN, fi, ba, faceArr)
        normal = clip(((normal * maskF + bgv * (1 - maskF)) + 1) * 0.5, min: 0, max: 1)
        let texPos = (0.5 - vtxPos / scaleFactor).asType(.float32)
        var position = SwiftRaster.interpolate(texPos, fi, ba, faceArr)
        position = clip(position * maskF + bgv * (1 - maskF), min: 0, max: 1)
        return (normal, position)
    }

    /// UV-space rasterize → (tex_pos [T,T,3], tex_nrm [T,T,3], mask [T,T] bool).
    public func uvRasterize(_ texRes: Int) -> (MLXArray, MLXArray, MLXArray) {
        let nv = vtxUv.dim(0)
        let u = vtxUv[0..., 0].reshaped([nv, 1]), v = vtxUv[0..., 1].reshaped([nv, 1])
        let clipv = concatenated([u * 2 - 1, v * 2 - 1, zeros([nv, 1]), ones([nv, 1])], axis: 1)
        let (fi, ba) = SwiftRaster.rasterize(clipv, faceArr, texRes)
        let texPos = SwiftRaster.interpolate(vtxPos, fi, ba, faceArr)
        let texNrm = SwiftRaster.interpolate(worldVN, fi, ba, faceArr)
        return (texPos, texNrm, fi .> 0)
    }

    /// Debug: render a texture onto the mesh at (elev,azim) using vtxUv. → [res,res,3], white bg.
    public func renderTextured(_ elev: Float, _ azim: Float, _ res: Int, _ tex: MLXArray) -> MLXArray {
        let (_, pc) = project(vtxPos, elev, azim)
        let (fi, ba) = SwiftRaster.rasterize(pc, faceArr, res)
        let uvm = SwiftRaster.interpolate(vtxUv, fi, ba, faceArr)             // [res,res,2]
        let T = tex.dim(0)
        let rf = clip(uvm[0..., 0..., 1] * Float(T - 1), min: 0, max: Float(T - 1)).reshaped([res * res])
        let cf = clip(uvm[0..., 0..., 0] * Float(T - 1), min: 0, max: Float(T - 1)).reshaped([res * res])
        let col = MeshRender.bilinear(tex, rf, cf).reshaped([res, res, 3])
        let bgm = (fi .> 0).reshaped([res, res, 1]).asType(.float32)
        return col * bgm + (1 - bgm)
    }

    /// Bilinear gather: img [H,W,C] at (rowF,colF) [K] → [K,C].
    static func bilinear(_ img: MLXArray, _ rowF: MLXArray, _ colF: MLXArray) -> MLXArray {
        let H = img.dim(0), W = img.dim(1), C = img.dim(2)
        let r0 = clip(floor(rowF), min: 0, max: Float(H - 2)).asType(.int32)
        let c0 = clip(floor(colF), min: 0, max: Float(W - 2)).asType(.int32)
        let fr = (rowF - r0.asType(.float32)).reshaped([-1, 1])
        let fc = (colF - c0.asType(.float32)).reshaped([-1, 1])
        let imgF = img.reshaped([H * W, C])
        let i00 = r0 * Int32(W) + c0
        let g00 = take(imgF, i00, axis: 0), g01 = take(imgF, i00 + 1, axis: 0)
        let g10 = take(imgF, i00 + Int32(W), axis: 0), g11 = take(imgF, i00 + Int32(W) + 1, axis: 0)
        return g00 * (1 - fr) * (1 - fc) + g01 * (1 - fr) * fc + g10 * fr * (1 - fc) + g11 * fr * fc
    }

    /// Back-sample (gather) bake of several color sets sharing one geometry pass.
    /// viewSets: [set][view] = MLXArray [H,W,3]. Returns ([texture per set], covered mask).
    /// `cosThrDeg` is the incidence angle past which a view's sample is rejected outright.
    /// 75° is right for a normal pass, but concave regions (wheel arches, interiors) are
    /// grazing in every canonical view and end up with no data at all — a relaxed second pass
    /// at ~88° gives them a smeared real colour, which beats an invented one.
    /// `canonicalCount` splits the view list into the six canonical views and any user-supplied
    /// reference photographs that follow them. When set, a reference only acts where the
    /// canonical views produced no paint at all.
    ///
    /// The test is simply the canonical weight sum. It is nonzero exactly when some canonical
    /// view saw the texel inside its silhouette, passed the depth test, AND was within the
    /// cosine cutoff — i.e. when the texel actually received colour. Reference weight is scaled
    /// by `refTau / (refTau + canonicalWeight)`, so an unseen texel (weight 0) takes the
    /// reference at full strength while a flank seen face-on (weight ~0.1) suppresses it by
    /// ~100x. Because the weights are normalised at the end, that suppression is a sub-percent
    /// perturbation there rather than a visible blend.
    ///
    /// Gating on the *magnitude* of the canonical weight cannot work and was tried: a flank seen
    /// face-on by a side view weighted 0.1 and a door card grazing in all six land within a
    /// factor of two, so every threshold inside the nonzero band trades one artifact for the
    /// other. The zero/nonzero boundary is the only one that separates them, and the cosine
    /// cutoff has already quantised the decision onto it.
    ///
    /// `validMasks` marks which pixels of a view are the object rather than its backdrop. A
    /// reference photograph is a third studio background by area, and it is letterboxed onto a
    /// flat canvas to square it — project either onto the mesh and you get flat pale patches
    /// across the very surfaces the reference was added to supply.
    ///
    /// `adequacyDeg` is the angle at which canonical paint counts as good enough to keep a
    /// reference out. It is stricter than the bake's own 75-degree cutoff on purpose: between
    /// roughly 65 and 75 degrees a canonical view does deposit colour, but one screen pixel
    /// smears across many texels, so what it deposits is a streak rather than a reading. Those
    /// texels are the console tops and door cards that come out as flat pale patches, and
    /// gating on the bake's cutoff leaves them to the smear. Two separate angles is the whole
    /// mechanism: paint at 75, defend at 65.
    ///
    /// `refMinWeight` discards reference samples too grazing to be worth anything. This matters
    /// more than it looks: `covered` is true for any nonzero weight, so a reference skimming a
    /// surface at 84 degrees — contributing ~1e-6, which is a single smeared pixel — was enough
    /// to mark the texel covered and lock `surfaceFill` out of it. Those texels used to be
    /// filled smoothly from their 3D neighbourhood, and instead kept the streak, which is the
    /// speckle and triangle noise coming back. Below the floor a reference contributes nothing
    /// and the texel falls through to the relaxed pass and the fill, as before.
    ///
    /// `winnerSets` names view sets that are masks rather than colours: they are reduced with a
    /// minimum over the views that face the surface, never blended. Alpha is a mask, not a colour: averaging it across views lets a grazing
    /// view's window smear its transparency onto the pillar behind it, so the atlas ends up
    /// transparent over door handles, B-pillars and roof — and no amount of edge cleanup or
    /// per-triangle classification can fix a hole that is genuinely in the mask.
    ///
    /// `viewFov` gives a view its own perspective projection instead of the shared orthographic
    /// one — see `perspProj`. Only reference photographs use it; the canonical views are
    /// orthographic by construction.
    ///
    /// `refCosThrDeg` is the angle past which a reference stops contributing, and it is the
    /// same 65 degrees a canonical view has to beat to defend a texel: a photograph is admitted
    /// only where it sees the surface at least as well as we would demand of the bake's own
    /// views. Relaxing it to 85 seemed reasonable — the user aimed that camera into the cabin,
    /// and interiors are steep to any outside-in pose — but it is wrong. A top-down photo grazes
    /// seat backs and footwells, and what it deposits there is its own shadow bands smeared into
    /// hard chunks. `surfaceFill` guessing those surfaces from their 3D neighbourhood beats a
    /// photograph that cannot see them.
    public func bakeMulti(_ viewSets: [[MLXArray]], _ elevs: [Float], _ azims: [Float],
                          textureSize: Int, exp: Float = 6, weights: [Float]? = nil, eps: Float = 0.05,
                          cosThrDeg: Float = 75,
                          canonicalCount: Int? = nil,
                          refTau: Float = 1e-3, refCosThrDeg: Float = 65,
                          adequacyDeg: Float = 65, refMinWeight: Float = 1e-4,
                          viewFov: [Float?]? = nil,
                          winnerSets: Set<Int> = [],
                          validMasks: [MLXArray?]? = nil,
                          overrideViews: Set<Int> = [])
        -> (textures: [MLXArray], covered: MLXArray, adequate: MLXArray, faceOn: MLXArray) {
        let w = weights ?? [Float](repeating: 1, count: elevs.count)
        let T = textureSize
        let (texPos3, texNrm3, _) = uvRasterize(T)
        let K = T * T
        let P = texPos3.reshaped([K, 3]), Nn = texNrm3.reshaped([K, 3])
        let Pw = concatenated([P, ones([K, 1])], axis: 1)            // [K,4]
        let nsets = viewSets.count
        var accs = (0..<nsets).map { _ in MLX.zeros([K, 3]) }
        var wsum = MLX.zeros([K, 1])
        // A correction the user deliberately supplied to override what canonical painted wrong,
        // not just fill what it missed — accumulated separately so it can win outright at the
        // end rather than being diluted into the same blend as everything else.
        var overrideAccs = (0..<nsets).map { _ in MLX.zeros([K, 3]) }
        var overrideWsum = MLX.zeros([K, 1])
        // Mask bookkeeping: the most transparent value any face-on view reports. Taking the
        // single best view loses the mask when that view did not paint it; blending smears it
        // onto whatever is behind. The minimum over views that actually face the surface keeps
        // the window transparent and keeps the pillar behind it solid.
        var bestVal = (0..<nsets).map { _ in MLX.ones([K, 3]) }
        // Colour from the single most face-on view, kept alongside the blended result. Glass
        // needs it: the top view looks down THROUGH a windscreen and paints the dashboard on it
        // while the front view paints sky reflection, and blending two irreconcilable pictures
        // gives the shattered-glass patchwork. Opaque bodywork still blends, which is what makes
        // it smooth.
        var bestWeight = MLX.zeros([K, 1])
        var bestColour = MLX.zeros([K, 3])
        let cosThr = cos(cosThrDeg * Float.pi / 180)
        let proj = MLXArray(projM, [4, 4])
        let vertPosw = concatenated([vtxPos, ones([vtxPos.dim(0), 1])], axis: 1)
        // Canonical weight per texel, snapshotted before the references run; 0 = never painted.
        var canonW = MLX.zeros([K, 1])
        // Accumulated separately from `wsum`: this one decides whether a texel is defended,
        // `wsum` decides its colour, and they use different angles.
        var adeqW = MLX.zeros([K, 1])
        // What the references themselves managed to paint, so the coverage readout shrinks as
        // views are added instead of always showing the original gap.
        var refW = MLX.zeros([K, 1])
        let refCosThr = cos(refCosThrDeg * Float.pi / 180)
        let adeqThr = cos(adequacyDeg * Float.pi / 180)
        func accumulate(_ indices: [Int], _ accs: inout [MLXArray],
                        _ wsum: inout MLXArray, gated: Bool = false, override: Bool = false) {
            for vi in indices {
                let H = viewSets[0][vi].dim(0), Wd = viewSets[0][vi].dim(1)
                // The rasteriser is square (it takes one edge length), so a non-square view would
                // make the reshape below mismatch and trap inside MLX. Canonical sheet tiles are
                // always square; a user-supplied reference might not be, so skip rather than die.
                guard H == Wd else { continue }
                let fov = viewFov?[vi] ?? nil
                let vProj: MLXArray
                let vDist: Float?
                if let fov, fov > 1 {
                    let d = MeshRender.perspDist(fovDeg: fov, orthoScale: orthoScale)
                    vDist = d
                    vProj = MLXArray(MeshRender.perspProj(fovDeg: fov,
                                                          near: max(0.01, Double(d) - 1.5),
                                                          far: Double(d) + 1.5), [4, 4])
                } else {
                    vDist = nil; vProj = proj
                }
                let mv = mvArray(elevs[vi], azims[vi], vDist)
                let posCamAll = matmul(vertPosw, mv.transposed(1, 0))
                let posClipAll = matmul(posCamAll, vProj.transposed(1, 0))
                let (fiD, baD) = SwiftRaster.rasterize(posClipAll, faceArr, H)
                let depthMap = SwiftRaster.interpolate(posCamAll[0..., 2..<3], fiD, baD, faceArr).reshaped([H * Wd])
                // Erode the view's silhouette before accepting samples from it. The colour fetch is
                // bilinear, so a texel projecting within a pixel or two of the object's edge has its
                // 2x2 kernel straddle the silhouette and blends in the sheet's pale background —
                // which surfaces as flat white triangles along window rails, seat tops and other
                // edges. Rejecting those texels here lets another view (or the fill) supply them.
                var covMask = (fiD .> 0).reshaped([H, Wd])
                for _ in 0 ..< max(0, Self.silhouetteErode) {
                    let up = concatenated([covMask[0..<1, 0...], covMask[0..<(H-1), 0...]], axis: 0)
                    let dn = concatenated([covMask[1..<H, 0...], covMask[(H-1)..<H, 0...]], axis: 0)
                    let lf = concatenated([covMask[0..., 0..<1], covMask[0..., 0..<(Wd-1)]], axis: 1)
                    let rt = concatenated([covMask[0..., 1..<Wd], covMask[0..., (Wd-1)..<Wd]], axis: 1)
                    covMask = covMask .&& up .&& dn .&& lf .&& rt
                }
                let covd = covMask.reshaped([H * Wd])
                let pc = matmul(Pw, mv.transposed(1, 0))                 // [K,4]
                let pcp = matmul(pc, vProj.transposed(1, 0))
                let ndc0 = pcp[0..., 0] / pcp[0..., 3], ndc1 = pcp[0..., 1] / pcp[0..., 3]
                let zc = pc[0..., 2]
                let colF = (ndc0 * 0.5 + 0.5) * Float(Wd - 1) + 0.5
                let rowF = (0.5 + 0.5 * ndc1) * Float(H - 1) + 0.5
                let inside = (colF .>= 0) .&& (colF .<= Float(Wd - 1)) .&& (rowF .>= 0) .&& (rowF .<= Float(H - 1))
                let ri = clip(rowF.asType(.int32), min: 0, max: Int32(H - 1))
                let ci = clip(colF.asType(.int32), min: 0, max: Int32(Wd - 1))
                let flat = ri * Int32(Wd) + ci
                let covAt = take(covd, flat, axis: 0)
                let depthAt = take(depthMap, flat, axis: 0)
                let vis = (inside .&& covAt .&& (abs(zc - depthAt) .< eps)).asType(.float32)
                let camN = matmul(Nn, mv[0..<3, 0..<3].transposed(1, 0))
                let nrm = sqrt(sum(camN * camN, axis: 1))
                var cosv = -camN[0..., 2] / clip(nrm, min: 1e-8, max: Float.greatestFiniteMagnitude)
                // MODELR_ABS_COS=1 ignores which way a face is wound. Generated meshes often have
                // inconsistent normals on thin shells like a windscreen: neighbouring triangles
                // face opposite ways, so one is accepted by the front view and the next is
                // rejected and takes its colour from a view behind the glass instead. That is
                // exactly the shattered-glass patchwork, and it is per-triangle because the
                // winding is per-triangle.
                if ProcessInfo.processInfo.environment["MODELR_ABS_COS"] == "1" { cosv = abs(cosv) }
                let thr = gated ? refCosThr : cosThr
                let cosw = MLX.where(cosv .>= thr, pow(clip(cosv, min: 0, max: Float.greatestFiniteMagnitude), exp), MLXArray(Float(0))) * w[vi]
                let rfc = clip(rowF, min: 0, max: Float(H - 1)), cfc = clip(colF, min: 0, max: Float(Wd - 1))
                var wgt = (vis * cosw).reshaped([K, 1])
                // Before wsum: a masked-out sample must not count toward the denominator, or
                // the texel is averaged toward black instead of simply ignoring this view.
                if let vm = validMasks?[vi] {
                    wgt = wgt * MeshRender.bilinear(vm, rfc, cfc)[0..., 0].reshaped([K, 1])
                }
                if override {
                    // No damping against canonical weight — the whole point is to win where
                    // canonical is present but wrong, not just where it is absent. Still counts
                    // toward `refW` so `adequate` reports the texel as defended.
                    refW = refW + wgt
                } else if gated {
                    wgt = wgt * (refTau / (refTau + canonW))
                    wgt = MLX.where(wgt .< refMinWeight, MLXArray(Float(0)), wgt)
                    refW = refW + wgt
                } else {
                    let aw = MLX.where(cosv .>= adeqThr,
                                       pow(clip(cosv, min: 0, max: Float.greatestFiniteMagnitude),
                                           exp), MLXArray(Float(0))) * w[vi]
                    adeqW = adeqW + (vis * aw).reshaped([K, 1])
                }
                wsum = wsum + wgt
                for si in 0..<nsets {
                    let sample = MeshRender.bilinear(viewSets[si][vi], rfc, cfc)
                    accs[si] = accs[si] + sample * wgt
                    // An override's own weight has no relation to the base blend's winner-take-
                    // all/glass bookkeeping — it is combined separately, after the loop.
                    if override { continue }
                    if si == 0 { bestColour = MLX.where(wgt .> bestWeight, sample, bestColour) }
                    if si == nsets - 1 { bestWeight = maximum(bestWeight, wgt) }
                    if winnerSets.contains(si), abs(elevs[vi]) <= 45 {
                        // Elevation views only, and only where they face the surface.
                        //
                        // Windows are vertical, so the four side views see them square-on and
                        // the top and bottom views see them edge-on. A top-down view painting a
                        // window necessarily paints across the roof and pillars behind it, which
                        // is how the mask ended up transparent over the B-pillar and the door
                        // handle. Restricting the mask to the elevation views removes that whole
                        // class of error; cos > 0.5 (about 60 degrees) drops the rest.
                        let faceOn = ((cosv .> 0.5) .&& (vis .> 0.5)).reshaped([K, 1])
                        bestVal[si] = MLX.where(faceOn, minimum(bestVal[si], sample), bestVal[si])
                    }
                }
            }
        }

        let nCanon = min(canonicalCount ?? elevs.count, elevs.count)
        accumulate(Array(0..<nCanon), &accs, &wsum)
        if nCanon < elevs.count {
            canonW = adeqW
            let refIndices = (nCanon..<elevs.count).filter { !overrideViews.contains($0) }
            let overrideIndices = (nCanon..<elevs.count).filter { overrideViews.contains($0) }
            if !refIndices.isEmpty { accumulate(refIndices, &accs, &wsum, gated: true) }
            if !overrideIndices.isEmpty {
                accumulate(overrideIndices, &overrideAccs, &overrideWsum, gated: true, override: true)
            }
        }
        for si in winnerSets where si < nsets {
            accs[si] = bestVal[si] * wsum          // divided back out below
        }
        // Hand the face-on colour back so the caller can use it where the surface is glass.
        let wsafe = clip(wsum, min: 1e-8, max: Float.greatestFiniteMagnitude)
        let overrideCovered = (overrideWsum[0..., 0] .> 1e-8).reshaped([K, 1])
        let overrideSafe = clip(overrideWsum, min: 1e-8, max: Float.greatestFiniteMagnitude)
        let covered = ((wsum[0..., 0] .> 1e-8) .|| overrideCovered[0..., 0]).reshaped([T, T])
        // Wherever an override actually painted, its own blend replaces the base blend outright
        // rather than joining it — two overrides of the same spot still blend with each other,
        // but neither has to out-shout canonical to be seen at all.
        let texs = (0..<nsets).map { si -> MLXArray in
            let base = accs[si] / wsafe
            let overridden = overrideAccs[si] / overrideSafe
            return MLX.where(overrideCovered, overridden, base).reshaped([T, T, 3])
        }
        // `adequate` is the gate itself, surfaced so the UI can show which surfaces a reference
        // is allowed to touch: true where a canonical view painted this texel head-on enough to
        // defend it, false where the paint is a grazing streak or nothing at all.
        let adequate = ((adeqW[0..., 0] .> 1e-8) .|| (refW[0..., 0] .> 1e-8)).reshaped([T, T])
        return (texs, covered, adequate, bestColour.reshaped([T, T, 3]))
    }

    /// Tidy the colour of the glass itself, once its mask is known.
    ///
    /// Two artefacts live here and both are colour, not mask. First, the anti-aliased band at the
    /// window's edge carries the *frame's* dark colour at partial alpha, which draws a dashed
    /// grey seam right along the boundary — the colour there has to come from the glass side and
    /// let alpha do the blending. Second, whichever single view wins a glass texel may have a
    /// blown specular highlight, so a few texels come out far brighter than their neighbours and
    /// read as torn shards. Glass is smooth by nature, so a small median inside the mask removes
    /// them without touching anything real.
    public static func smoothGlassColour(_ albedo: MLXArray, alpha: MLXArray,
                                         cut: Float = 0.995) -> MLXArray {
        let H = albedo.dim(0), W = albedo.dim(1), N = H * W
        var rgb = albedo.asType(.float32).asArray(Float.self)
        let a = alpha[0..., 0..., 0].reshaped([-1]).asType(.float32).asArray(Float.self)
        guard a.count == N else { return albedo }
        // "Solidly glass" excludes the anti-aliased rim, so the rim cannot seed its own colour.
        var solid = [Bool](repeating: false, count: N)
        for k in 0 ..< N { solid[k] = a[k] < cut - 0.05 }

        // 1. Median the glass, 3x3, using only solid-glass neighbours.
        var out = rgb
        for y in 1 ..< H-1 {
            for x in 1 ..< W-1 {
                let k = y * W + x
                guard solid[k] else { continue }
                for c in 0 ..< 3 {
                    var v = [Float]()
                    v.reserveCapacity(9)
                    for dy in -1...1 { for dx in -1...1 {
                        let j = k + dy * W + dx
                        if solid[j] { v.append(rgb[j*3 + c]) }
                    }}
                    if v.count >= 5 { v.sort(); out[k*3 + c] = v[v.count/2] }
                }
            }
        }
        rgb = out

        // 2. Push glass colour outward into the anti-aliased rim.
        for _ in 0 ..< 2 {
            var next = rgb
            var grew = solid
            for y in 1 ..< H-1 {
                for x in 1 ..< W-1 {
                    let k = y * W + x
                    if solid[k] || a[k] >= 0.999 { continue }      // rim only
                    var acc = [Float](repeating: 0, count: 3); var n: Float = 0
                    for dy in -1...1 { for dx in -1...1 {
                        let j = k + dy * W + dx
                        if solid[j] { for c in 0..<3 { acc[c] += rgb[j*3 + c] }; n += 1 }
                    }}
                    if n > 0 { for c in 0..<3 { next[k*3 + c] = acc[c] / n }; grew[k] = true }
                }
            }
            rgb = next; solid = grew
        }
        return MLXArray(rgb, [H, W, 3])
    }

    /// Collapse the soft band between glass and bodywork so window frames come out crisp.
    ///
    /// The alpha is baked the same way as colour — cosine-weighted across views, then filled —
    /// which leaves a feathered ramp wherever glass meets a pillar. Downstream that ramp is the
    /// whole problem: any threshold that keeps the glass also catches part of the feather, so
    /// frame triangles get classified as glass and the frame exports with bites out of it.
    ///
    /// The fix is to remove the ramp rather than to keep re-tuning the threshold. The glass
    /// population is found as the low tail of the non-opaque alphas (each model paints its glass
    /// at a different level — 0.62, 0.68, 0.78 across this library), and everything above it is
    /// snapped to fully opaque. Alpha *within* the glass is left alone, so a windscreen at 30%
    /// and side glass at 60% stay different.
    public static func sharpenGlassAlpha(_ alpha: MLXArray,
                                        positions: MLXArray? = nil) -> MLXArray {
        let H = alpha.dim(0), W = alpha.dim(1), N = H * W
        var a = alpha[0..., 0..., 0].reshaped([-1]).asType(.float32).asArray(Float.self)
        guard a.count == N else { return alpha }

        // 1. Find the glass level. Each model's painted glass sits at its own alpha — 0.45 on
        //    one car, 0.62 on another — with the bake's soft ramp running from there up to 1.
        var soft = [Float]()
        soft.reserveCapacity(4096)
        let step = max(1, N / 200_000)
        var i = 0
        while i < N { if a[i] < 0.995 { soft.append(a[i]) }; i += step }
        guard soft.count > 64 else { return alpha }
        soft.sort()
        let p5 = soft[max(0, soft.count * 5 / 100)]
        let cut = min(0.9, max(0.5, p5 + 0.08))
        let level = soft[soft.count / 20 ... soft.count / 2].reduce(0, +)
            / Float(max(1, soft.count / 2 - soft.count / 20 + 1))

        // 2. Reduce to a hard in/out mask, discarding the ramp entirely.
        var inside = [Bool](repeating: false, count: N)
        for k in 0 ..< N { inside[k] = a[k] < cut }

        // 2b. Clean the mask as a mask. Pinholes inside a window are the white flecks in the
        //     glass; stray islands on a door handle or a roof rail are projection leaks. Close
        //     the pinholes, then drop islands, judging connectivity in 3D — a single window is
        //     scattered across many UV charts, so atlas-space connectivity would tear it apart.
        func neighbours(_ k: Int) -> [Int] {
            let y = k / W, x = k % W
            var n = [Int]()
            if x > 0 { n.append(k-1) }; if x < W-1 { n.append(k+1) }
            if y > 0 { n.append(k-W) }; if y < H-1 { n.append(k+W) }
            return n
        }
        // Radius scales with resolution so it closes the same *physical* hole, but is capped:
        // each pass walks the whole atlas, and at 8192 an uncapped radius means 24 dilate plus 24
        // erode passes over 67M texels — billions of neighbour tests, minutes of pure overhead
        // for holes that are already mostly closed by the first few.
        let closeRadius = min(8, max(3, H / 340))
        for _ in 0 ..< closeRadius {                           // dilate
            var next = inside
            for k in 0 ..< N where !inside[k] {
                if neighbours(k).contains(where: { inside[$0] }) { next[k] = true }
            }
            inside = next
        }
        for _ in 0 ..< closeRadius {                           // erode back
            var next = inside
            for k in 0 ..< N where inside[k] {
                if neighbours(k).contains(where: { !inside[$0] }) { next[k] = false }
            }
            inside = next
        }
        if let positions {
            let pos = positions.reshaped([N, 3]).asType(.float32).asArray(Float.self)
            var lo = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
            var hi = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
            for k in 0 ..< N where inside[k] {
                let q = SIMD3(pos[k*3], pos[k*3+1], pos[k*3+2])
                lo = simd_min(lo, q); hi = simd_max(hi, q)
            }
            if lo.x <= hi.x {
                let cell = max(Float(0.01), (hi - lo).max() / 128)
                var buckets = [Int: [Int]]()
                func key(_ q: SIMD3<Float>) -> Int {
                    let a = Int((q.x - lo.x) / cell), b = Int((q.y - lo.y) / cell)
                    let c = Int((q.z - lo.z) / cell)
                    return (a &* 73856093) ^ (b &* 19349663) ^ (c &* 83492791)
                }
                for k in 0 ..< N where inside[k] {
                    buckets[key(SIMD3(pos[k*3], pos[k*3+1], pos[k*3+2])), default: []].append(k)
                }
                var label = [Int](repeating: -1, count: N)
                var sizes = [Int]()
                for k in 0 ..< N where inside[k] && label[k] < 0 {
                    let id = sizes.count
                    var stack = [k]; label[k] = id; var count = 0
                    while let t = stack.popLast() {
                        count += 1
                        let q = SIMD3(pos[t*3], pos[t*3+1], pos[t*3+2])
                        for dx in -1...1 { for dy in -1...1 { for dz in -1...1 {
                            let nq = q + SIMD3(Float(dx), Float(dy), Float(dz)) * cell
                            for u in buckets[key(nq)] ?? [] where label[u] < 0 {
                                let p2 = SIMD3(pos[u*3], pos[u*3+1], pos[u*3+2])
                                if simd_length(p2 - q) <= cell * 1.5 { label[u] = id; stack.append(u) }
                            }
                        }}}
                    }
                    sizes.append(count)
                }
                let biggest = sizes.max() ?? 0
                let floorSize = max(64, biggest / 50)
                for k in 0 ..< N where inside[k] {
                    if label[k] >= 0, sizes[label[k]] < floorSize { inside[k] = false }
                }
            }
        }

        // 3. Signed distance to that boundary, in texels, by two chamfer passes. This is the
        //    step that buys smooth edges: a hard mask alone stair-steps at texel resolution,
        //    and the bake's own ramp is too wide and too dirty to anti-alias with.
        let big: Float = 1e9
        var dIn = [Float](repeating: big, count: N)      // distance from inside to outside
        var dOut = [Float](repeating: big, count: N)     // distance from outside to inside
        for y in 0 ..< H {
            for x in 0 ..< W {
                let k = y * W + x
                var edge = false
                if x > 0, inside[k] != inside[k-1] { edge = true }
                if !edge, x < W-1, inside[k] != inside[k+1] { edge = true }
                if !edge, y > 0, inside[k] != inside[k-W] { edge = true }
                if !edge, y < H-1, inside[k] != inside[k+W] { edge = true }
                if edge { dIn[k] = 0; dOut[k] = 0 }
            }
        }
        func chamfer(_ d: inout [Float]) {
            for y in 0 ..< H {
                for x in 0 ..< W {
                    let k = y * W + x
                    var v = d[k]
                    if x > 0 { v = min(v, d[k-1] + 1) }
                    if y > 0 { v = min(v, d[k-W] + 1) }
                    if x > 0, y > 0 { v = min(v, d[k-W-1] + 1.414) }
                    if x < W-1, y > 0 { v = min(v, d[k-W+1] + 1.414) }
                    d[k] = v
                }
            }
            for y in stride(from: H-1, through: 0, by: -1) {
                for x in stride(from: W-1, through: 0, by: -1) {
                    let k = y * W + x
                    var v = d[k]
                    if x < W-1 { v = min(v, d[k+1] + 1) }
                    if y < H-1 { v = min(v, d[k+W] + 1) }
                    if x < W-1, y < H-1 { v = min(v, d[k+W+1] + 1.414) }
                    if x > 0, y < H-1 { v = min(v, d[k+W-1] + 1.414) }
                    d[k] = v
                }
            }
        }
        chamfer(&dIn)
        dOut = dIn

        // 4. Rebuild alpha from the distance field: one texel of anti-aliasing either side of
        //    the boundary, glass level inside, fully opaque outside. The edge now follows the
        //    painted contour sub-texel instead of the texel grid or the triangulation.
        for k in 0 ..< N {
            let signed = inside[k] ? -dIn[k] : dOut[k]        // negative inside the glass
            let coverage = min(max(0.5 - signed, 0), 1)        // 1 = fully glass, 0 = fully body
            a[k] = 1 - coverage * (1 - level)
        }
        let out = MLXArray(a, [H, W, 1])
        return concatenated([out, out, out], axis: 2)
    }

    /// Fill un-covered texels from the nearest covered texel **on the mesh surface**, using the
    /// 3D position `uvRasterize` gives every texel.
    ///
    /// This is the fix the 2D fills could not reach. Filling in atlas space asks "what is
    /// nearby in the packing?", which is meaningless — charts land wherever they fit. A seat
    /// pocket that no view could see has nothing usable beside it in UV space whether or not
    /// the search is confined to its chart, so it ends up flat chart-mean grey. Searching in 3D
    /// asks "what is nearby on the car?", so the pocket takes colour from a covered part of the
    /// same seat even though that lives in a different chart entirely.
    ///
    /// Gutter texels (no triangle, hence no position) keep the 2D dilation — they only exist to
    /// give bilinear something to read at chart edges.
    public static func surfaceFill(_ texture: MLXArray, _ mask: MLXArray, positions: MLXArray,
                                   normals: MLXArray? = nil, inside: [Bool],
                                   gutterRadius: Int = 4, minDot: Float = 0.2) -> MLXArray {
        let H = texture.dim(0), W = texture.dim(1), N = H * W
        var tex = texture.asType(.float32).asArray(Float.self)
        var covered = mask.reshaped([N]).asType(.int32).asArray(Int32.self).map { $0 != 0 }
        let pos = positions.reshaped([N, 3]).asType(.float32).asArray(Float.self)
        // Position alone is not enough to say what is "nearby on the car". A dash, a door card
        // or a seat side sits centimetres from the outer body panel, and on a white car the
        // nearest covered texel in 3D is that panel — so an unpainted interior fills with body
        // white. Requiring the donor to face roughly the same way keeps the search on the same
        // side of the sheet metal, which is what "nearby on the surface" was always meant to be.
        let nrm = normals?.reshaped([N, 3]).asType(.float32).asArray(Float.self)

        // Uniform grid over the covered texels so the nearest-surface lookup stays linear.
        var lo = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
        var hi = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
        for i in 0 ..< N where covered[i] && inside[i] {
            let p = SIMD3(pos[i*3], pos[i*3+1], pos[i*3+2])
            lo = SIMD3(min(lo.x, p.x), min(lo.y, p.y), min(lo.z, p.z))
            hi = SIMD3(max(hi.x, p.x), max(hi.y, p.y), max(hi.z, p.z))
        }
        guard lo.x <= hi.x else { return MLXArray(tex, [H, W, 3]) }
        let G = 96
        let span = max(max(hi.x-lo.x, hi.y-lo.y), hi.z-lo.z)
        let cell = max(span / Float(G), 1e-6)
        func gidx(_ p: SIMD3<Float>) -> (Int, Int, Int) {
            (min(G-1, max(0, Int((p.x-lo.x)/cell))),
             min(G-1, max(0, Int((p.y-lo.y)/cell))),
             min(G-1, max(0, Int((p.z-lo.z)/cell))))
        }
        var buckets = [Int: [Int]]()
        for i in 0 ..< N where covered[i] && inside[i] {
            let (a, b, c) = gidx(SIMD3(pos[i*3], pos[i*3+1], pos[i*3+2]))
            buckets[(a*G + b)*G + c, default: []].append(i)
        }

        var writes = [(Int, Float, Float, Float)]()
        for i in 0 ..< N where !covered[i] && inside[i] {
            let p = SIMD3(pos[i*3], pos[i*3+1], pos[i*3+2])
            let (a, b, c) = gidx(p)
            var best = -1
            var bestD = Float.greatestFiniteMagnitude
            // Fallback for a texel with no similarly-oriented donor anywhere: better to take
            // the nearest thing than to leave a hole for the gutter dilation to smear.
            var anyBest = -1
            var anyD = Float.greatestFiniteMagnitude
            let ni: SIMD3<Float> = nrm.map { SIMD3($0[i*3], $0[i*3+1], $0[i*3+2]) }
                ?? SIMD3(0, 0, 1)
            var ring = 0
            // Ring at which *any* donor first appeared. The normal test can otherwise send the
            // search a long way: an interior texel with no similarly-oriented neighbour keeps
            // widening the shell, and at a million uncovered texels that is not a slow fill, it
            // is a hang. Two rings past first contact, take whatever is nearest instead.
            var firstHit = -1
            while true {
                if firstHit >= 0 && ring > firstHit + 1 { break }
                var found = false
                for da in -ring...ring {
                    for db in -ring...ring {
                        for dc in -ring...ring {
                            if max(abs(da), max(abs(db), abs(dc))) != ring { continue }
                            let x = a+da, y = b+db, z = c+dc
                            guard x >= 0, x < G, y >= 0, y < G, z >= 0, z < G,
                                  let list = buckets[(x*G + y)*G + z] else { continue }
                            found = true
                            for j in list {
                                let q = SIMD3(pos[j*3], pos[j*3+1], pos[j*3+2]) - p
                                let d = q.x*q.x + q.y*q.y + q.z*q.z
                                if d < anyD { anyD = d; anyBest = j }
                                if let nrm {
                                    let nj = SIMD3(nrm[j*3], nrm[j*3+1], nrm[j*3+2])
                                    if ni.x*nj.x + ni.y*nj.y + ni.z*nj.z < minDot { continue }
                                }
                                if d < bestD { bestD = d; best = j }
                            }
                        }
                    }
                }
                if firstHit < 0 && anyBest >= 0 { firstHit = ring }
                ring += 1
                if ring > G { break }
                if best >= 0 && !found && ring > 2 { break }
                // One ring past a hit so a nearer candidate just outside the shell can win.
                if best >= 0 && ring > firstHit + 1 { break }
            }
            let pick = best >= 0 ? best : anyBest
            if pick >= 0 {
                writes.append((i, tex[pick*3], tex[pick*3+1], tex[pick*3+2]))
            }
        }
        for (i, r, g, b) in writes {
            tex[i*3] = r; tex[i*3+1] = g; tex[i*3+2] = b
            covered[i] = true
        }

        // Gutter: plain 2D dilation so chart edges have something for bilinear to read.
        for _ in 0 ..< max(0, gutterRadius) {
            var gw = [(Int, Float, Float, Float)]()
            for y in 0 ..< H {
                for x in 0 ..< W {
                    let i = y*W + x
                    if covered[i] { continue }
                    var r: Float = 0, g: Float = 0, b: Float = 0, n: Float = 0
                    for dy in -1...1 {
                        for dx in -1...1 where !(dx == 0 && dy == 0) {
                            let yy = y+dy, xx = x+dx
                            if yy < 0 || yy >= H || xx < 0 || xx >= W { continue }
                            let j = yy*W + xx
                            guard covered[j] else { continue }
                            r += tex[j*3]; g += tex[j*3+1]; b += tex[j*3+2]; n += 1
                        }
                    }
                    if n > 0 { gw.append((i, r/n, g/n, b/n)) }
                }
            }
            if gw.isEmpty { break }
            for (i, r, g, b) in gw { tex[i*3] = r; tex[i*3+1] = g; tex[i*3+2] = b; covered[i] = true }
        }
        return MLXArray(tex, [H, W, 3])
    }

    /// Fill un-painted texels; matches the Python reference exactly (see `Inpaint`):
    /// clip -> scipy-EDT nearest fill -> uint8 round-trip with OpenCV `INPAINT_NS` on the holes.
    /// Painted texels come back exactly as Python returns them (uint8-quantized by the NS pass).
    public static func inpaint(_ texture: MLXArray, _ mask: MLXArray) -> MLXArray {
        let H = texture.dim(0), W = texture.dim(1)
        let tex = texture.asType(.float32).asArray(Float.self)
        let covered = mask.reshaped([H * W]).asType(.int32).asArray(Int32.self).map { $0 != 0 }
        let filled = Inpaint.fill(texture: tex, covered: covered, H: H, W: W)
        return MLXArray(filled, [H, W, 3])
    }

    /// Fill un-covered texels by growing covered colour outward one texel at a time, rather
    /// than flooding from the nearest covered texel anywhere in the atlas.
    ///
    /// `inpaint` is chart-blind: it works in flat 2D atlas space with no notion of which chart
    /// a texel belongs to, so an un-covered texel is filled from whatever chart happens to be
    /// packed alongside — black tyre, white panel, tan trim. xatlas emits ~5000 charts for one
    /// of these meshes, so a seam network threads every panel, and that is where the speckle
    /// comes from. Within a couple of texels the nearest covered neighbour is reliably the same
    /// surface, so a bounded dilation gets the colour right where an unbounded reach cannot.
    ///
    /// `radius` bounds how far colour may travel. Anything still un-covered after that had no
    /// real data nearby at all (wheel arches, deep interior) and takes the covered median — a
    /// flat plausible colour, which beats invented confetti.
    /// Connected-component label per texel over `inside` (texels belonging to some triangle).
    /// Each component is one UV chart, which is what makes the fill chart-aware.
    static func chartLabels(_ inside: [Bool], H: Int, W: Int) -> [Int32] {
        var lab = [Int32](repeating: -1, count: H * W)
        var next: Int32 = 0
        var stack = [Int]()
        for s in 0 ..< (H * W) where inside[s] && lab[s] < 0 {
            lab[s] = next; stack.append(s)
            while let i = stack.popLast() {
                let y = i / W, x = i % W
                if x > 0     { let j = i - 1; if inside[j] && lab[j] < 0 { lab[j] = next; stack.append(j) } }
                if x < W - 1 { let j = i + 1; if inside[j] && lab[j] < 0 { lab[j] = next; stack.append(j) } }
                if y > 0     { let j = i - W; if inside[j] && lab[j] < 0 { lab[j] = next; stack.append(j) } }
                if y < H - 1 { let j = i + W; if inside[j] && lab[j] < 0 { lab[j] = next; stack.append(j) } }
            }
            next += 1
        }
        return lab
    }

    /// `charts` (from `chartLabels`) confines the growth: a texel only takes colour from
    /// neighbours in its own chart. Without it, bounding the radius is not enough — charts sit
    /// 1-12 texels apart, so the growth hops the gutter and an interior pocket fills with the
    /// white bodywork packed next to it. That is the flat white triangle artifact.
    public static func dilateFill(_ texture: MLXArray, _ mask: MLXArray, radius: Int = 4,
                                  charts: [Int32]? = nil) -> MLXArray {
        let H = texture.dim(0), W = texture.dim(1)
        var tex = texture.asType(.float32).asArray(Float.self)          // H*W*3
        var covered = mask.reshaped([H * W]).asType(.int32).asArray(Int32.self).map { $0 != 0 }

        for _ in 0 ..< max(0, radius) {
            var writes: [(Int, Float, Float, Float)] = []
            for y in 0 ..< H {
                for x in 0 ..< W {
                    let i = y * W + x
                    if covered[i] { continue }
                    var r: Float = 0, g: Float = 0, b: Float = 0, n: Float = 0
                    for dy in -1 ... 1 {
                        for dx in -1 ... 1 {
                            if dx == 0 && dy == 0 { continue }
                            let yy = y + dy, xx = x + dx
                            if yy < 0 || yy >= H || xx < 0 || xx >= W { continue }
                            let j = yy * W + xx
                            guard covered[j] else { continue }
                            // Texels INSIDE a chart may only take colour from their own chart,
                            // so an interior pocket can't grab the bodywork packed alongside.
                            // Gutter texels (label < 0) are exempt and fill from any neighbour:
                            // that is what a gutter is for, and starving it leaves black specks
                            // that bilinear sampling drags onto every chart edge.
                            if let charts, charts[i] >= 0, charts[i] != charts[j] { continue }
                            r += tex[j*3]; g += tex[j*3+1]; b += tex[j*3+2]; n += 1
                        }
                    }
                    if n > 0 { writes.append((i, r/n, g/n, b/n)) }
                }
            }
            if writes.isEmpty { break }                                 // nothing further to reach
            // Applied after the sweep so a ring fills from real data, not from itself.
            for (i, r, g, b) in writes {
                tex[i*3] = r; tex[i*3+1] = g; tex[i*3+2] = b
                covered[i] = true
            }
        }

        // Whatever the dilation never reached takes its OWN chart's mean where possible — a
        // seat pocket should go seat-coloured, not car-coloured. Only texels with no chart at
        // all (pure gutter) fall back to the global mean.
        var sum = [Float](repeating: 0, count: 3), cnt: Float = 0
        var chartSum = [Int32: (Float, Float, Float, Float)]()
        for i in 0 ..< (H * W) where covered[i] {
            sum[0] += tex[i*3]; sum[1] += tex[i*3+1]; sum[2] += tex[i*3+2]; cnt += 1
            if let charts {
                let c = charts[i]
                if c >= 0 {
                    var e = chartSum[c] ?? (0, 0, 0, 0)
                    e.0 += tex[i*3]; e.1 += tex[i*3+1]; e.2 += tex[i*3+2]; e.3 += 1
                    chartSum[c] = e
                }
            }
        }
        if cnt > 0 {
            let gm = (sum[0]/cnt, sum[1]/cnt, sum[2]/cnt)
            for i in 0 ..< (H * W) where !covered[i] {
                var col = gm
                if let charts, charts[i] >= 0, let e = chartSum[charts[i]], e.3 > 0 {
                    col = (e.0/e.3, e.1/e.3, e.2/e.3)
                }
                tex[i*3] = col.0; tex[i*3+1] = col.1; tex[i*3+2] = col.2
            }
        }
        return MLXArray(tex, [H, W, 3])
    }

    /// Exact scipy `distance_transform_edt(..., return_indices=True)` nearest-covered indices
    /// (exposed for the parity gate, which asserts index-exact tie-breaking).
    public static func edtIndices(_ mask: MLXArray) -> (rows: MLXArray, cols: MLXArray) {
        let H = mask.dim(0), W = mask.dim(1)
        let covered = mask.reshaped([H * W]).asType(.int32).asArray(Int32.self).map { $0 != 0 }
        let (r, c) = Inpaint.edtIndices(covered: covered, H: H, W: W)
        return (MLXArray(r, [H, W]), MLXArray(c, [H, W]))
    }
}
