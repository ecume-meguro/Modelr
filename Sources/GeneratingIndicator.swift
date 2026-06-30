import SwiftUI

/// The "working" visual for the 3D output pane: a smoothly rotating point cloud
/// (points orbiting a forming shape) over a progress bar that is determinate when
/// we have a real fraction (denoise steps) and indeterminate during the other
/// long stages. No step-count text here — that lives in the sidebar.
/// A glowing point sphere rotating in 3D, drawn with Canvas + TimelineView.
struct PointCloud: View {
    private let points: [(x: Double, y: Double, z: Double)]

    init(count: Int = 140) {
        var pts: [(Double, Double, Double)] = []
        let golden = Double.pi * (3.0 - (5.0).squareRoot())   // golden angle
        let denom = Double(max(count - 1, 1))
        for i in 0..<count {
            let y = 1.0 - (Double(i) / denom) * 2.0            // 1 … -1
            let r = max(0, 1.0 - y * y).squareRoot()
            let theta = golden * Double(i)
            pts.append((cos(theta) * r, y, sin(theta) * r))
        }
        points = pts
    }

    var body: some View {
        TimelineView(.animation) { timeline in
            Canvas { context, size in
                let t = timeline.date.timeIntervalSinceReferenceDate
                let yaw = t * 0.5
                let tilt = 0.42
                let cy = cos(yaw), sy = sin(yaw)
                let cx = cos(tilt), sx = sin(tilt)
                let centerX = size.width / 2
                let centerY = size.height / 2
                let breathe = 1.0 + 0.05 * sin(t * 1.6)
                let radius = min(size.width, size.height) * 0.40 * breathe
                let focal = 3.2

                var projected: [(p: CGPoint, depth: Double, scale: Double)] = []
                projected.reserveCapacity(points.count)
                for pt in points {
                    let x1 = pt.x * cy + pt.z * sy            // rotate around Y
                    let z1 = -pt.x * sy + pt.z * cy
                    let y2 = pt.y * cx - z1 * sx              // rotate around X
                    let z2 = pt.y * sx + z1 * cx
                    let persp = focal / (focal - z2)
                    let px = centerX + x1 * radius * persp
                    let py = centerY - y2 * radius * persp
                    projected.append((CGPoint(x: px, y: py), z2, persp))
                }
                projected.sort { $0.depth < $1.depth }       // far first

                for item in projected {
                    let near = (item.depth + 1) / 2           // 0 far … 1 near
                    let dot = (0.7 + near * 1.7) * item.scale
                    let opacity = 0.16 + near * 0.64
                    let rect = CGRect(x: item.p.x - dot, y: item.p.y - dot,
                                      width: dot * 2, height: dot * 2)
                    context.fill(Path(ellipseIn: rect),
                                 with: .color(Color.accentColor.opacity(opacity)))
                }
            }
        }
    }
}

/// Determinate when `fraction` is set, otherwise a smoothly sliding segment.
struct SmoothProgressBar: View {
    let fraction: Double?

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.10))

                if let f = fraction {
                    Capsule()
                        .fill(Color.accentColor)
                        .frame(width: max(4, w * min(max(f, 0), 1)))
                        .animation(.easeOut(duration: 0.3), value: f)
                } else {
                    TimelineView(.animation) { timeline in
                        let period = 1.25
                        let t = timeline.date.timeIntervalSinceReferenceDate
                        let phase = t.truncatingRemainder(dividingBy: period) / period
                        let seg = w * 0.35
                        let xpos = -seg + (w + seg) * phase
                        Capsule()
                            .fill(Color.accentColor)
                            .frame(width: seg)
                            .offset(x: xpos)
                    }
                }
            }
            .clipShape(Capsule())
        }
    }
}
