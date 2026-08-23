import Foundation
import MLX

/// Recovers the camera a reference photograph was taken from, by matching silhouettes.
///
/// Aligning by hand does not work, and the reason is not a missing control. Every degree of
/// freedom already exists — `mvMatrix` supplies elevation and azimuth, `squared()` bakes an
/// image-space scale and offset, `perspProj` supplies the lens — but they trade off against each
/// other. A few degrees of azimuth error looks exactly like a translation error, so a person
/// moving one slider at a time walks along the wall of a narrow curved valley in seven
/// dimensions and never finds its floor. What was missing is a solver.
///
/// Two things make it cheap. Silhouette rasterisation is milliseconds, so hundreds of candidate
/// poses are affordable. And scale and translation do not need searching at all: for any
/// candidate orientation they follow in closed form from the area ratio and the centroid
/// difference, which drops the search from seven dimensions to three.
///
/// The score is chamfer distance between silhouette *boundaries*, not overlap. Overlap is flat
/// at the pixel level and least sensitive exactly where it matters — near the optimum, where the
/// user is looking at doubled edges. Distance to the nearest boundary pixel measures that
/// doubling directly.
public struct PoseFit {
    public let elev: Float
    public let azim: Float
    public let fovDeg: Float
    public let scale: Float
    public let offsetX: Float
    public let offsetY: Float
    /// Mean distance, in fractions of the frame, from the fitted outline to the photo's outline.
    /// Below ~0.005 is a good fit; a mesh generated from one photo differs from the real car by
    /// a few percent everywhere, so a perfect zero is usually not attainable.
    public let residual: Float
    public let iou: Float
}

public enum PoseFitter {
    /// `photoMask` is the subject cutout, `res × res`, 1 on the object. It must be in the same
    /// aspect-fit square frame the aligner previews and `squared()` writes.
    public static func fit(render: MeshRender, photoMask: [Float], res: Int,
                           seedElev: Float, seedAzim: Float,
                           searchFov: Bool = true,
                           onProgress: ((Double) -> Void)? = nil) -> PoseFit? {
        let photo = Stats(mask: photoMask, res: res)
        guard photo.area > 0 else { return nil }
        let dt = distanceTransform(boundary(photoMask, res: res), res: res)

        // Cost of one orientation, with scale and offset solved rather than searched.
        func evaluate(_ e: Float, _ a: Float, _ f: Float) -> (cost: Float, fit: PoseFit)? {
            let mask = render.silhouetteMask(elev: e, azim: a, fovDeg: f, res: res)
            let r = Stats(mask: mask, res: res)
            guard r.area > 16 else { return nil }
            let s = (r.area / photo.area).squareRoot()
            // squared() scales the photo about the square's centre, then translates it.
            let ox = r.cx - 0.5 - (photo.cx - 0.5) * s
            let oy = r.cy - 0.5 - (photo.cy - 0.5) * s
            // Map the render's outline back into the photo's frame and read its distance field,
            // so the photo is never re-transformed — only a few thousand boundary points move.
            var sum: Float = 0, n: Float = 0
            for i in boundaryIndices(mask, res: res) {
                let qx = Float(i % res) / Float(res - 1), qy = Float(i / res) / Float(res - 1)
                let px = 0.5 + (qx - ox - 0.5) / s, py = 0.5 + (qy - oy - 0.5) / s
                sum += sampleDT(dt, res: res, x: px, y: py); n += 1
            }
            guard n > 0 else { return nil }
            let cost = sum / n
            let fit = PoseFit(elev: e, azim: a, fovDeg: f, scale: s, offsetX: ox, offsetY: oy,
                              residual: cost, iou: overlap(mask, photoMask, res: res,
                                                           scale: s, ox: ox, oy: oy))
            return (cost, fit)
        }

        // Coarse sweep around the user's placement. Seeding matters for more than speed: a car's
        // silhouette from the front three-quarter and the rear three-quarter are similar enough
        // that an unseeded search will happily settle on the wrong end.
        var best: (cost: Float, fit: PoseFit)?
        var evaluated = 0
        let elevs = stride(from: seedElev - 15, through: seedElev + 15, by: 3).map { Float($0) }
        let azims = stride(from: seedAzim - 20, through: seedAzim + 20, by: 2.5).map { Float($0) }
        let total = Double(elevs.count * azims.count)
        for e in elevs {
            for a in azims {
                if let c = evaluate(e, a, 0), best == nil || c.cost < best!.cost { best = c }
                evaluated += 1
                if evaluated % 16 == 0 { onProgress?(Double(evaluated) / total * 0.7) }
            }
        }
        guard var current = best else { return nil }

        // Refine orientation, then the lens, then orientation again: the lens is weakly
        // determined and only becomes meaningful once the angles are close.
        for (i, step) in [Float(1.5), 0.6, 0.25].enumerated() {
            current = descend(current, step: step, evaluate: evaluate)
            onProgress?(0.7 + Double(i) * 0.07)
        }
        if searchFov {
            for f in [Float(15), 25, 35, 45, 55] {
                if let c = evaluate(current.fit.elev, current.fit.azim, f), c.cost < current.cost {
                    current = c
                }
            }
            onProgress?(0.93)
            current = descend(current, step: 0.4, evaluate: evaluate)
        }
        onProgress?(1)
        return current.fit
    }

    /// Coordinate descent on elevation and azimuth. The surface is smooth once scale and offset
    /// are solved out, so this converges in a few dozen evaluations without a full simplex.
    private static func descend(_ start: (cost: Float, fit: PoseFit), step: Float,
                                evaluate: (Float, Float, Float) -> (cost: Float, fit: PoseFit)?)
        -> (cost: Float, fit: PoseFit) {
        var current = start
        for _ in 0 ..< 12 {
            var improved = false
            for (de, da) in [(step, 0), (-step, 0), (0, step), (0, -step)] as [(Float, Float)] {
                if let c = evaluate(current.fit.elev + de, current.fit.azim + da,
                                    current.fit.fovDeg), c.cost < current.cost {
                    current = c; improved = true
                }
            }
            if !improved { break }
        }
        return current
    }

    // MARK: - mask arithmetic

    private struct Stats {
        let area: Float, cx: Float, cy: Float
        init(mask: [Float], res: Int) {
            var a: Float = 0, sx: Float = 0, sy: Float = 0
            for i in 0 ..< mask.count where mask[i] > 0.5 {
                a += 1; sx += Float(i % res); sy += Float(i / res)
            }
            area = a
            cx = a > 0 ? sx / a / Float(res - 1) : 0.5
            cy = a > 0 ? sy / a / Float(res - 1) : 0.5
        }
    }

    private static func boundaryIndices(_ mask: [Float], res: Int) -> [Int] {
        var out = [Int]()
        for y in 0 ..< res {
            for x in 0 ..< res {
                let i = y * res + x
                guard mask[i] > 0.5 else { continue }
                if x == 0 || x == res-1 || y == 0 || y == res-1
                    || mask[i-1] < 0.5 || mask[i+1] < 0.5
                    || mask[i-res] < 0.5 || mask[i+res] < 0.5 { out.append(i) }
            }
        }
        return out
    }

    private static func boundary(_ mask: [Float], res: Int) -> [Bool] {
        var b = [Bool](repeating: false, count: res * res)
        for i in boundaryIndices(mask, res: res) { b[i] = true }
        return b
    }

    /// Two-pass chamfer distance transform, in pixels.
    private static func distanceTransform(_ seed: [Bool], res: Int) -> [Float] {
        let big = Float(res * 4)
        var d = seed.map { $0 ? Float(0) : big }
        for y in 0 ..< res {
            for x in 0 ..< res {
                let i = y * res + x
                var v = d[i]
                if x > 0 { v = min(v, d[i-1] + 1) }
                if y > 0 { v = min(v, d[i-res] + 1) }
                if x > 0 && y > 0 { v = min(v, d[i-res-1] + 1.414) }
                if x < res-1 && y > 0 { v = min(v, d[i-res+1] + 1.414) }
                d[i] = v
            }
        }
        for y in stride(from: res-1, through: 0, by: -1) {
            for x in stride(from: res-1, through: 0, by: -1) {
                let i = y * res + x
                var v = d[i]
                if x < res-1 { v = min(v, d[i+1] + 1) }
                if y < res-1 { v = min(v, d[i+res] + 1) }
                if x < res-1 && y < res-1 { v = min(v, d[i+res+1] + 1.414) }
                if x > 0 && y < res-1 { v = min(v, d[i+res-1] + 1.414) }
                d[i] = v
            }
        }
        return d
    }

    /// Distance at a point given in frame fractions, returned in frame fractions.
    private static func sampleDT(_ dt: [Float], res: Int, x: Float, y: Float) -> Float {
        let px = min(max(x * Float(res - 1), 0), Float(res - 1))
        let py = min(max(y * Float(res - 1), 0), Float(res - 1))
        // Outside the frame the nearest boundary is at least as far as the walk to the edge.
        let edge = max(0, max(-x, x - 1)) + max(0, max(-y, y - 1))
        return dt[Int(py) * res + Int(px)] / Float(res - 1) + edge
    }

    private static func overlap(_ render: [Float], _ photo: [Float], res: Int,
                                scale s: Float, ox: Float, oy: Float) -> Float {
        var inter: Float = 0, union: Float = 0
        for y in 0 ..< res {
            for x in 0 ..< res {
                let qx = Float(x) / Float(res - 1), qy = Float(y) / Float(res - 1)
                let px = 0.5 + (qx - ox - 0.5) / s, py = 0.5 + (qy - oy - 0.5) / s
                let r = render[y * res + x] > 0.5
                var p = false
                if px >= 0, px <= 1, py >= 0, py <= 1 {
                    p = photo[Int(py * Float(res - 1)) * res + Int(px * Float(res - 1))] > 0.5
                }
                if r || p { union += 1 }
                if r && p { inter += 1 }
            }
        }
        return union > 0 ? inter / union : 0
    }
}
