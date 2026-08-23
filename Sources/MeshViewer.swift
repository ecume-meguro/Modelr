import SwiftUI
import SceneKit
import ImageIO

/// What the viewer is showing right now.
enum ViewerContent: Equatable {
    case mesh(URL)                    // binary .mesh (preview or final shape)
    case texturedMesh(URL, URL)       // .tmesh (with UVs) + texture image
    case pbrMesh(URL, albedo: URL, metallicRoughness: URL)  // .tmesh + albedo + MR (G=rough, B=metal)
    case points(URL)                  // a streaming near-surface point cloud (.bin float32 xyz)
    /// .tmesh + a coverage atlas whose alpha is 0 wherever nothing has painted the surface
    /// head-on. Rendered with those texels punched out, so a reference photo placed behind the
    /// viewer shows through exactly the area a re-bake would hand it.
    case coverageMesh(URL, URL)
}

/// Renders a mesh or point cloud in an orbitable SceneKit view. The scene, lights
/// and camera persist; only the content node is swapped in place, and the camera
/// is re-fit to the content so even a large/messy early preview fills the viewport.
/// Reads the orbit camera's current position back out as the paint pipeline's (elev, azim).
///
/// Aligning a reference photo means orbiting until it matches, then recording where the
/// camera ended up — so the pose has to come *out* of the viewer, not into it. The pipeline's
/// convention is `cam = d*(cos e' cos a', cos e' sin a', sin e')` with `e' = -elev` and
/// `a' = azim + 90`, in a space where the mesh has been mapped (x,y,z) -> (-x, z, -y). This
/// undoes both so the result can be handed to the bake unchanged.
/// Instrumentation for the aligner's orbit, off by default. Writes to ~/Desktop/modelr-orbit.log so a
/// jump can be attributed to a specific cause — a view rebuild, a programmatic pose, or the
/// camera controller itself — instead of being guessed at from a screenshot.
enum OrbitLog {
    // Application Support, not the Desktop: macOS gates Desktop access behind a TCC prompt the
    // app never asked for, so writes there fail silently and the log simply never appears.
    static let url: URL = {
        let dir = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Modelr", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("orbit.log")
    }()
    // Off unless asked for: this exists to diagnose the orbit, not to run all the time.
    // MODELR_ORBIT_LOG=1 turns it back on.
    static var enabled = ProcessInfo.processInfo.environment["MODELR_ORBIT_LOG"] == "1"
    static func write(_ line: String) {
        guard enabled else { return }
        let stamp = String(format: "%.3f", Date().timeIntervalSince1970
                           .truncatingRemainder(dividingBy: 10000))
        let text = "\(stamp) \(line)\n"
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile(); h.write(Data(text.utf8)); try? h.close()
        } else {
            try? Data(text.utf8).write(to: url)
        }
    }
}

@Observable
final class CameraProbe {
    @ObservationIgnored weak var view: SCNView?
    /// Frame the content exactly as the bake will see it.
    ///
    /// The bake never uses this camera — it re-renders through its own fixed orthographic one
    /// (`cameraDistance 1.45`, `orthoScale 1.2`) after normalising the mesh so its bounding
    /// sphere has radius `scaleFactor/2 = 0.575`. So the object fills 0.575/0.6 of the bake's
    /// half-frame, while `fitCamera`'s perspective view with its 1.5 margin shows it at 1/1.5 —
    /// about 1.4x smaller. Aligning a photo against that would look right on screen and land
    /// short in the bake, so in align mode this camera is made to match: orthographic, and
    /// scaled off the same bounding-sphere-about-the-bbox-centre the bake measures (NOT the
    /// largest bbox edge, which is what `fitCamera` uses and is far smaller for a long, low car).
    /// Field of view the aligner is previewing, degrees; 0 = orthographic like the bake default.
    var fovDeg: Double = 0
    /// Bounds are derived from every vertex, so they are cached: the lens slider re-frames on
    /// each tick and a quarter-million-vertex scan per tick stalls the UI.
    @ObservationIgnored private var cachedBounds: (SIMD3<Float>, Double)?
    /// Centre the orbit shares with the framing. `applyBakeFraming` frames about the bounding
    /// box centre, so measuring or setting a pose about the origin instead makes the camera
    /// jump on the first drag and mis-measures the angle that gets captured.
    @ObservationIgnored private var orbitCentre = SIMD3<Float>(0, 0, 0)
    func invalidateBounds() { cachedBounds = nil }

    /// Last pose applied or read, so a rebuilt view can be put back where the user had it.
    private(set) var orbitElev: Double = 20
    private(set) var orbitAzim: Double = 0

    /// Poll the camera and log any jump larger than a drag step could plausibly produce.
    /// Re-assert turntable mode and report when it had been reset.
    ///
    /// Setting it in `makeNSView` and again in `updateNSView` was not enough: the logged camera
    /// still rolled to 30 degrees and swung 20 -> -38 in elevation during a purely horizontal
    /// drag, which a turntable cannot do. Something re-creates the controller's state after we
    /// configure it, so the only reliable place to hold the setting is right before each frame
    /// the user is actually dragging in.
    func enforceTurntable() {
        guard let c = view?.defaultCameraController else { return }
        if c.interactionMode != .orbitTurntable {
            OrbitLog.write("interactionMode had been reset to \(c.interactionMode.rawValue) "
                           + "— forcing turntable")
            c.interactionMode = .orbitTurntable
        }
        let up = c.worldUp
        // Pivot: SceneKit's automatic target hit-tests a point on the car's surface, so it
        // orbits about somewhere on the bodywork while `applyBakeFraming` frames — and
        // `currentPose` measures — about the bounding-box centre. Orbiting about an off-centre
        // pivot swings the camera vertically during a horizontal drag and eventually carries it
        // over the top, which is the flip.
        if c.automaticTarget {
            OrbitLog.write("automaticTarget was on — pinning pivot to the bbox centre")
            c.automaticTarget = false
        }
        c.target = SCNVector3(orbitCentre.x, orbitCentre.y, orbitCentre.z)
        if abs(up.x) > 0.01 || abs(up.y - 1) > 0.01 || abs(up.z) > 0.01 {
            OrbitLog.write(String(format: "worldUp had been reset to (%.2f, %.2f, %.2f) "
                                  + "— forcing +Y", up.x, up.y, up.z))
            c.worldUp = SCNVector3(0, 1, 0)
        }
    }

    func sampleForJump() {
        enforceTurntable()
        ticks += 1
        guard let p = currentPose() else {
            // Worth logging loudly: it means this probe is pointed at a camera that no longer
            // exists, so everything it reports or sets is going to the wrong view.
            if ticks % 10 == 0 { OrbitLog.write("sample: NO CAMERA (probe.view is nil/dead)") }
            return
        }
        // Roll, read off the camera's own up vector. A turntable orbit should hold this at 0;
        // anything else means the camera basis is tumbling, which is what "flip" looks like.
        // Real roll: the signed angle between the camera's up vector and world up projected
        // into the camera's image plane. The earlier metric (atan2(up.x, up.y)) is non-zero for
        // any camera that is both elevated and turned, so it flagged healthy poses as rolled.
        var roll = 0.0
        if let node = view?.pointOfView {
            let m = node.simdWorldTransform
            let fwd = -SIMD3<Float>(m.columns.2.x, m.columns.2.y, m.columns.2.z)
            let up = SIMD3<Float>(m.columns.1.x, m.columns.1.y, m.columns.1.z)
            let worldUp = SIMD3<Float>(0, 1, 0)
            let proj = worldUp - fwd * simd_dot(worldUp, fwd)
            if simd_length(proj) > 1e-4 {
                let want = simd_normalize(proj)
                let s = simd_dot(simd_cross(want, up), fwd)
                roll = Double(atan2(s, simd_dot(want, up))) * 180 / .pi
            }
        }
        if ticks % 20 == 0 {
            OrbitLog.write(String(format: "tick e=%.1f a=%.1f roll=%.1f", p.elev, p.azim, roll))
        }
        defer { lastSample = p }
        guard let last = lastSample else { return }
        var dAz = abs(p.azim - last.azim).truncatingRemainder(dividingBy: 360)
        if dAz > 180 { dAz = 360 - dAz }
        let dEl = abs(p.elev - last.elev)
        if dAz > 8 || dEl > 8 {
            OrbitLog.write(String(format: "JUMP e %.1f->%.1f  a %.1f->%.1f  roll=%.1f",
                                  last.elev, p.elev, last.azim, p.azim, roll))
        }
    }
    @ObservationIgnored private var lastSample: (elev: Double, azim: Double)?
    @ObservationIgnored private var ticks = 0

    /// Re-apply that pose after the view underneath has been rebuilt.
    /// Force the camera controller to re-derive its cached orbit state from the node's current
    /// transform. It keeps its own spherical state and never notices a camera moved in code, so
    /// the first drag after one applies its delta to the stale cache and snaps — losing exactly
    /// the pose we just set. Re-assigning `pointOfView` is what makes it re-read the transform;
    /// it also clears the mode settings, so those are re-applied immediately after.
    private func resyncController() {
        guard let view, let node = view.pointOfView else { return }
        func settings() {
            let c = view.defaultCameraController
            c.interactionMode = .orbitTurntable
            c.worldUp = SCNVector3(0, 1, 0)
            c.automaticTarget = false
            c.target = SCNVector3(orbitCentre.x, orbitCentre.y, orbitCentre.z)
        }
        switch ProcessInfo.processInfo.environment["MODELR_ORBIT_RESYNC"] ?? "D" {
        case "A":                                   // no resync at all
            break
        case "B":                                   // re-assign pointOfView
            view.pointOfView = node
        case "C":
            // Turn camera control off and on again. The controller is rebuilt from the camera's
            // current transform, which is the only way found to make it adopt a pose that was
            // set in code — it caches its own spherical state and otherwise never notices.
            view.allowsCameraControl = false
            view.allowsCameraControl = true
        case "D":
            // Clearing pointOfView and restoring it is the only thing that makes the controller
            // rebuild its cached orbit state from the camera's actual transform. Re-assigning
            // the same node is not enough, nor is toggling allowsCameraControl: both leave the
            // stale spherical state in place, so the first drag afterwards snaps the camera back
            // to whatever pose the controller still believed in — losing the pose just set.
            // Verified by OrbitSelfTest, which fails on every other strategy.
            view.pointOfView = nil
            view.pointOfView = node
        default:
            break
        }
        settings()
    }

    func restorePose() {
        OrbitLog.write(String(format: "restorePose -> e=%.1f a=%.1f", orbitElev, orbitAzim))
        setPose(elev: orbitElev, azim: orbitAzim)
    }

    func applyBakeFraming() {
        OrbitLog.write("applyBakeFraming " + (currentPose().map {
            String(format: "at e=%.1f a=%.1f", $0.elev, $0.azim) } ?? "no camera"))
        guard let view, let node = view.pointOfView, let camera = node.camera,
              let container = view.scene?.rootNode.childNode(withName: "MeshContainer",
                                                             recursively: false),
              let (centre, radius) = cachedBounds ?? Self.boundingSphere(container),
              radius > 1e-6
        else { return }
        cachedBounds = (centre, radius)
        orbitCentre = centre
        // Mirror whatever projection the bake will use for this view, so the silhouette on
        // screen is the silhouette that gets projected.
        let dist: Double
        if fovDeg > 1 {
            camera.usesOrthographicProjection = false
            camera.fieldOfView = fovDeg
            // Same rule as MeshRender.perspDist: distance follows the angle so the framing
            // holds and only the convergence changes.
            dist = (radius / 0.575) * (0.6 / tan(fovDeg * .pi / 360))
        } else {
            camera.usesOrthographicProjection = true
            camera.orthographicScale = radius * (0.6 / 0.575)
            // Distance is irrelevant under an orthographic projection, but it sets the depth
            // range and it is what `setPose` preserves, so put it where the bake's camera sits.
            dist = radius * (1.45 * 2 / 1.15)
        }
        camera.zNear = 0.001
        camera.zFar = (dist + radius) * 4
        let p = node.simdWorldPosition - SIMD3<Float>(centre)
        let len = (p.x*p.x + p.y*p.y + p.z*p.z).squareRoot()
        // Keep whatever direction the user has orbited to; only the distance is normalised.
        var dir = len > 1e-6 ? p / len : SIMD3<Float>(0, 0, 1)
        // Nudge off the pole for the same reason.
        if abs(dir.y) > 0.9998 {
            dir = simd_normalize(SIMD3<Float>(0.02, dir.y > 0 ? 0.9998 : -0.9998, 0))
        }
        node.simdPosition = SIMD3<Float>(centre) + dir * Float(dist)
        // Plain look(at:), and the camera controller left entirely alone — the same two things
        // `fitCamera` does for the main viewer, which orbits correctly. Pinning the target and
        // the up axis here is what desynchronised the controller.
        node.look(at: SCNVector3(centre.x, centre.y, centre.z))
        resyncController()
    }

    /// Max vertex distance from the bounding-box centre — the radius the bake normalises by.
    private static func boundingSphere(_ root: SCNNode) -> (SIMD3<Float>, Double)? {
        var pts: [SIMD3<Float>] = []
        func walk(_ n: SCNNode) {
            if let g = n.geometry, let src = g.sources(for: .vertex).first,
               src.componentsPerVector >= 3, src.bytesPerComponent == 4 {
                let t = n.simdWorldTransform
                src.data.withUnsafeBytes { raw in
                    for i in 0 ..< src.vectorCount {
                        let o = src.dataOffset + i * src.dataStride
                        guard o + 12 <= raw.count else { break }
                        let v = SIMD3<Float>(raw.loadUnaligned(fromByteOffset: o, as: Float.self),
                                             raw.loadUnaligned(fromByteOffset: o + 4, as: Float.self),
                                             raw.loadUnaligned(fromByteOffset: o + 8, as: Float.self))
                        pts.append((t * SIMD4<Float>(v, 1)).xyz)
                    }
                }
            }
            n.childNodes.forEach(walk)
        }
        walk(root)
        guard !pts.isEmpty else { return nil }
        var lo = pts[0], hi = pts[0]
        for p in pts { lo = simd_min(lo, p); hi = simd_max(hi, p) }
        let c = (lo + hi) / 2
        var r: Float = 0
        for p in pts { r = max(r, simd_length(p - c)) }
        return (c, Double(r))
    }

    /// Point the orbit camera at a stored pose, keeping its current distance — so re-opening a
    /// reference view puts you back where you were rather than making you find it again.
    func setPose(elev: Double, azim: Double) {
        guard let node = view?.pointOfView else { return }
        // Stop just short of overhead: directly above, look(at:) has no defined roll.
        let elev = min(max(elev, -89), 89)
        OrbitLog.write(String(format: "setPose e=%.1f a=%.1f (was %@)", elev, azim,
                              currentPose().map { String(format: "e=%.1f a=%.1f", $0.elev, $0.azim) }
                              ?? "none"))
        orbitElev = elev; orbitAzim = azim
        let t = node.simdWorldTransform.columns.3
        let rel = SIMD3<Float>(t.x, t.y, t.z) - orbitCentre
        let d = Double((rel.x*rel.x + rel.y*rel.y + rel.z*rel.z).squareRoot())
        guard d > 1e-6 else { return }
        let e = -elev * .pi / 180, a = (azim + 90) * .pi / 180
        // inverse of currentPose: pipeline frame -> viewer frame is (x,y,z) -> (-x, -z, y)
        let px = d * cos(e) * cos(a), py = d * cos(e) * sin(a), pz = d * sin(e)
        node.simdPosition = orbitCentre + SIMD3<Float>(Float(-px), Float(-pz), Float(py))
        let c = SCNVector3(orbitCentre.x, orbitCentre.y, orbitCentre.z)
        node.look(at: c)
        resyncController()
    }

    func currentPose() -> (elev: Double, azim: Double)? {
        guard let node = view?.pointOfView else { return nil }
        let t = node.simdWorldTransform.columns.3
        // viewer space is the .tmesh frame; convert into the pipeline's frame, measured from
        // the same centre the orbit and the framing use
        let r = SIMD3<Float>(t.x, t.y, t.z) - orbitCentre
        let p = SIMD3<Double>(Double(-r.x), Double(r.z), Double(-r.y))
        let len = (p.x*p.x + p.y*p.y + p.z*p.z).squareRoot()
        guard len > 1e-9 else { return nil }
        let elev = -(asin(max(-1, min(1, p.z / len))) * 180 / .pi)
        let azim = (atan2(p.y, p.x) * 180 / .pi) - 90
        return (elev, (azim.truncatingRemainder(dividingBy: 360) + 360)
            .truncatingRemainder(dividingBy: 360))
    }
}

struct MeshViewer: NSViewRepresentable {
    let content: ViewerContent?
    var onLoading: ((Bool) -> Void)? = nil    // true while async-loading content
    var probe: CameraProbe? = nil             // set to read the orbit camera back out
    /// Match the bake's orthographic camera instead of fitting comfortably — for aligning
    /// reference photos, where on-screen framing has to equal what the bake projects. Also hands
    /// the orbit to `CameraProbe`, which owns it explicitly rather than letting SceneKit's
    /// controller improvise one.
    var bakeFraming: Bool = false
    /// Glass faces to highlight while editing the selection. Non-nil puts the viewer in edit
    /// mode: one element (so a hit test's face index is the mesh's own), plus a tinted overlay.
    var glassHighlight: [Bool]? = nil
    /// Paint the glass element a flat colour so the current selection is obvious while editing.
    var tintGlass: Bool = false
    /// Paint the highlighted faces this flat, opaque colour — used to show what is slated for
    /// deletion before it is deleted, so the choice can be seen rather than guessed at.
    var markColor: NSColor? = nil
    /// Faces under the cursor, drawn as a separate overlay so hovering never rebuilds the model.
    var hoverFaces: [Int] = []
    /// Faces under the cursor, drawn as a separate overlay so hovering never rebuilds the model.

    /// Erased faces to preview live, before applying.
    var erasePreview: [Bool]? = nil
    /// Bump to force a rebuild when something other than `content` changed — an erase or glass
    /// mask, for instance. Without it the viewer caches on content identity alone and an edited
    /// mask never reaches the screen.
    var variant: Int = 0
    /// Face index under a click, in the mesh's own numbering.
    /// (packed element+face, shift held). Shift means "undo this area" everywhere it is used.
    var onFacePicked: ((Int, Bool) -> Void)? = nil
    /// Called with the face under the cursor (or nil when the cursor leaves the model).
    var onFaceHovered: ((Int?) -> Void)? = nil
    /// Drag a box instead of orbiting. Clicking one speck at a time is hopeless when a hundred of
    /// them are scattered over a panel, and a box drawn on screen is the natural way to say
    /// "everything in here" — the size cap is what keeps the panel behind them out of it.
    var lasso: Bool = false
    /// Rect dragged on screen, whether shift was held, and a projector from mesh coordinates to
    /// that same screen space — the caller owns the geometry, the viewer owns the camera, and
    /// this hands over the one thing only the viewer can answer.
    var onLasso: ((CGRect, Bool, (SIMD3<Float>) -> CGPoint?) -> Void)? = nil

    func makeCoordinator() -> Coordinator { Coordinator() }
    /// Receives mouse-moved events for the hover preview.
    final class Tracker: NSResponder {
        var picker: Picker?
        override func mouseMoved(with event: NSEvent) {
            guard let v = picker?.view else { return }
            picker?.hover(at: v.convert(event.locationInWindow, from: nil))
        }
        override func mouseExited(with event: NSEvent) { picker?.lastHover = nil; picker?.onHover?(nil) }
    }

    final class Coordinator {
        let picker = Picker()
        let tracker = Tracker()
        var loaded: ViewerContent?
        var loadedVariant: Int = -1
        weak var lassoGesture: NSPanGestureRecognizer?
        var lassoOn = false
        var lastFitCenter: SCNVector3?
        var lastFitRadius: CGFloat?
    }

    final class Picker: NSObject {
        var onPick: ((Int, Bool) -> Void)?
        var onHover: ((Int?) -> Void)?
        var lastHover: Int?
        weak var view: SCNView?

        func hover(at p: CGPoint) {
            guard let view, let onHover else { return }
            let hits = view.hitTest(p, options: [.categoryBitMask: 1,
                                                 .searchMode: SCNHitTestSearchMode.closest.rawValue])
            let packed = hits.first.map { $0.geometryIndex << 24 | $0.faceIndex }
            // Only report changes: the region under the cursor is recomputed per report, and at
            // mouse-move rate that would be thousands of floods a second.
            if packed != lastHover { lastHover = packed; onHover(packed) }
        }
        var onLasso: ((CGRect, Bool, (SIMD3<Float>) -> CGPoint?) -> Void)?
        private var band: CAShapeLayer?
        private var origin: CGPoint = .zero

        @objc func drag(_ g: NSPanGestureRecognizer) {
            guard let view, let onLasso else { return }
            let p = g.location(in: view)
            switch g.state {
            case .began:
                origin = p
                let l = CAShapeLayer()
                l.fillColor = NSColor.systemBlue.withAlphaComponent(0.15).cgColor
                l.strokeColor = NSColor.systemBlue.cgColor
                l.lineWidth = 1
                view.layer?.addSublayer(l)
                band = l
            case .changed:
                band?.path = CGPath(rect: rect(to: p), transform: nil)
            case .ended, .cancelled, .failed:
                let r = rect(to: p)
                band?.removeFromSuperlayer(); band = nil
                guard r.width > 3, r.height > 3 else { return }
                let container = view.scene?.rootNode.childNode(withName: "MeshContainer",
                                                               recursively: false)
                onLasso(r, NSEvent.modifierFlags.contains(.shift)) { v in
                    let world = container?.convertPosition(SCNVector3(v.x, v.y, v.z), to: nil)
                        ?? SCNVector3(v.x, v.y, v.z)
                    let q = view.projectPoint(world)
                    // Behind the camera projects to nonsense; drop it rather than select it.
                    guard q.z > 0, q.z < 1 else { return nil }
                    return CGPoint(x: CGFloat(q.x), y: CGFloat(q.y))
                }
            default: break
            }
        }

        private func rect(to p: CGPoint) -> CGRect {
            CGRect(x: min(origin.x, p.x), y: min(origin.y, p.y),
                   width: abs(p.x - origin.x), height: abs(p.y - origin.y))
        }

        @objc func click(_ g: NSClickGestureRecognizer) {
            guard let view, let onPick else { return }
            let p = g.location(in: view)
            // Only the base geometry is pickable; the highlight overlay is excluded by mask.
            let hits = view.hitTest(p, options: [.categoryBitMask: 1,
                                                 .searchMode: SCNHitTestSearchMode.closest.rawValue])
            if let h = hits.first {
                // Encode element and face together; the caller maps to a mesh face.
                let shift = NSEvent.modifierFlags.contains(.shift)
                onPick(h.geometryIndex << 24 | h.faceIndex, shift)
            }
        }
    }

    func makeNSView(context: Context) -> SCNView {
        let view = SCNView()
        view.allowsCameraControl = true
        view.autoenablesDefaultLighting = true
        view.backgroundColor = .clear
        view.antialiasingMode = .multisampling4X

        let scene = SCNScene()

        let container = SCNNode()
        container.name = "MeshContainer"
        scene.rootNode.addChildNode(container)

        let ambient = SCNNode()
        ambient.light = SCNLight()
        ambient.light?.type = .ambient
        ambient.light?.intensity = 280
        scene.rootNode.addChildNode(ambient)

        let camera = SCNCamera()
        camera.fieldOfView = 40
        camera.projectionDirection = .horizontal
        camera.zNear = 0.001
        camera.zFar = 1000
        let cameraNode = SCNNode()
        cameraNode.name = "ModelrCamera"
        cameraNode.camera = camera
        cameraNode.position = SCNVector3(0, 0, 3.3)
        cameraNode.look(at: SCNVector3(0, 0, 0))
        scene.rootNode.addChildNode(cameraNode)

        view.scene = scene
        view.pointOfView = cameraNode
        if onFaceHovered != nil {
            context.coordinator.picker.onHover = onFaceHovered
            let area = NSTrackingArea(rect: .zero,
                                      options: [.mouseMoved, .mouseEnteredAndExited,
                                                .activeInKeyWindow, .inVisibleRect],
                                      owner: context.coordinator.tracker, userInfo: nil)
            context.coordinator.tracker.picker = context.coordinator.picker
            view.addTrackingArea(area)
        }
        if onFacePicked != nil {
            context.coordinator.picker.view = view
            context.coordinator.picker.onPick = onFacePicked
            let g = NSClickGestureRecognizer(target: context.coordinator.picker,
                                             action: #selector(Picker.click(_:)))
            view.addGestureRecognizer(g)
        }
        if onLasso != nil {
            context.coordinator.picker.view = view
            context.coordinator.picker.onLasso = onLasso
            let pan = NSPanGestureRecognizer(target: context.coordinator.picker,
                                             action: #selector(Picker.drag(_:)))
            pan.isEnabled = lasso
            context.coordinator.lassoGesture = pan
            view.addGestureRecognizer(pan)
        }
        // AFTER pointOfView: assigning it rebuilds the controller's state and discards whatever
        // was configured before, which is why setting this at the top of the function silently
        // did nothing. Turntable spins about the model's up axis (+Y — the .tmesh is 2.00 long
        // in Z, 0.86 wide in X, 0.63 tall in Y). The default free orbit rotates about the screen
        // axis instead: logging the camera's own up vector during a purely horizontal drag
        // showed roll swinging to 20 degrees and elevation sliding 20 -> -20, so the basis
        // tumbled and eventually passed vertical. That is the flip.
        Self.configureOrbit(view)
        probe?.view = view
        return view
    }

    static func configureOrbit(_ view: SCNView) {
        view.defaultCameraController.interactionMode = .orbitTurntable
        view.defaultCameraController.worldUp = SCNVector3(0, 1, 0)
    }

    func updateNSView(_ view: SCNView, context: Context) {
        probe?.view = view
        context.coordinator.picker.onLasso = onLasso
        if context.coordinator.lassoOn != lasso {
            context.coordinator.lassoOn = lasso
            context.coordinator.lassoGesture?.isEnabled = lasso
            // The orbit controller and a drag gesture cannot both own the drag, so the camera
            // stands still while a box is being drawn — and has to be reconfigured afterwards,
            // since assigning this rebuilds the controller's state.
            view.allowsCameraControl = !lasso
            if !lasso { Self.configureOrbit(view) }
        }
        updateHoverOverlay(view)
        // Re-assert every update: any later pointOfView assignment resets it again.
        Self.configureOrbit(view)
        if context.coordinator.loaded == content, context.coordinator.loadedVariant == variant {
            return
        }
        context.coordinator.loadedVariant = variant
        if bakeFraming { OrbitLog.write("content reload -> SCNView rebuilt / content swapped") }
        context.coordinator.loaded = content

        guard let content else {
            container(in: view)?.childNodes.forEach { $0.removeFromParentNode() }
            context.coordinator.lastFitCenter = nil
            context.coordinator.lastFitRadius = nil
            if let onLoading { DispatchQueue.main.async { onLoading(false) } }
            return
        }

        if let onLoading { DispatchQueue.main.async { onLoading(true) } }
        let tint = tintGlass
        let mark = markColor
        let override = glassHighlight
        let erase = erasePreview
        DispatchQueue.global(qos: .userInitiated).async {
            Self.tintGlassNow = tint
            Self.markColorNow = mark
            Self.glassOverride = override
            Self.eraseOverride = erase
            let result = Self.load(content)
            Self.tintGlassNow = false
            Self.markColorNow = nil
            Self.glassOverride = nil
            Self.eraseOverride = nil
            DispatchQueue.main.async {
                // Ignore a load whose content was already superseded — both applying it
                // and clearing the loading flag would be wrong for the current content.
                guard context.coordinator.loaded == content,
                      context.coordinator.loadedVariant == variant else { return }
                if let container = container(in: view), let result {
                    container.childNodes.forEach { $0.removeFromParentNode() }
                    container.addChildNode(result.node)
                    // Re-fit only when the content's bounds change meaningfully (>~3%),
                    // so streaming frames don't yank the camera while the user orbits.
                    if Self.boundsChanged(center: result.center, radius: result.radius,
                                          lastCenter: context.coordinator.lastFitCenter,
                                          lastRadius: context.coordinator.lastFitRadius) {
                        if bakeFraming {
                            probe?.view = view
                            probe?.invalidateBounds()
                            probe?.applyBakeFraming()
                            // The SCNView is rebuilt whenever a bake lands, and the new camera
                            // starts at the default. Push the orbit we own into it — reading
                            // the camera back instead would silently adopt that default and
                            // throw away the alignment in progress.
                            probe?.restorePose()
                        } else {
                            Self.fitCamera(view, center: result.center, radius: result.radius)
                        }
                        context.coordinator.lastFitCenter = result.center
                        context.coordinator.lastFitRadius = result.radius
                    }
                }
                onLoading?(false)
            }
        }
    }

    private static func boundsChanged(center: SCNVector3, radius: CGFloat,
                                      lastCenter: SCNVector3?, lastRadius: CGFloat?) -> Bool {
        guard let lc = lastCenter, let lr = lastRadius, lr > 0 else { return true }
        if abs(radius - lr) / lr > 0.03 { return true }
        let dx = center.x - lc.x
        let dy = center.y - lc.y
        let dz = center.z - lc.z
        return (dx * dx + dy * dy + dz * dz).squareRoot() / lr > 0.03
    }

    /// Draw the hovered region in magenta as a child node sharing the model's vertex data. Only
    /// the index list differs, so this costs a small buffer rather than a reload.
    private func updateHoverOverlay(_ view: SCNView) {
        guard let container = container(in: view) else { return }
        let existing = container.childNode(withName: "HoverHighlight", recursively: false)
        guard !hoverFaces.isEmpty,
              let base = container.childNodes.first(where: { $0.geometry != nil })?.geometry,
              let meshURL: URL = {
                  switch content {
                  case .pbrMesh(let m, _, _)?:   return m
                  case .texturedMesh(let m, _)?: return m
                  case .mesh(let m)?:            return m
                  case .coverageMesh(let m, _)?: return m
                  default:                       return nil
                  }
              }(),
              let all = Self.indexCache[meshURL] else {
            existing?.removeFromParentNode(); return
        }
        var idx = [UInt32](); idx.reserveCapacity(hoverFaces.count * 3)
        for f in hoverFaces where f * 3 + 2 < all.count {
            idx.append(all[f*3]); idx.append(all[f*3+1]); idx.append(all[f*3+2])
        }
        guard !idx.isEmpty else { existing?.removeFromParentNode(); return }
        let element = idx.withUnsafeBufferPointer {
            SCNGeometryElement(data: Data(buffer: $0), primitiveType: .triangles,
                               primitiveCount: idx.count / 3, bytesPerIndex: 4)
        }
        let geo = SCNGeometry(sources: base.sources, elements: [element])
        let mat = SCNMaterial()
        mat.lightingModel = .constant
        mat.diffuse.contents = NSColor(red: 1, green: 0, blue: 0.9, alpha: 1)
        mat.isDoubleSided = true
        // Sits a hair in front so it wins the depth test against the surface it is tracing.
        mat.readsFromDepthBuffer = false
        geo.materials = [mat]
        existing?.removeFromParentNode()
        let node = SCNNode(geometry: geo)
        node.name = "HoverHighlight"
        node.categoryBitMask = 2                     // never picked or hovered itself
        container.addChildNode(node)
    }

    private func container(in view: SCNView) -> SCNNode? {
        view.scene?.rootNode.childNode(withName: "MeshContainer", recursively: false)
    }

    // MARK: - loading

    /// element-local face index -> mesh face index, per loaded mesh.
    static var splitIndex: [URL: ([Int], [Int])] = [:]
    /// The mesh's index buffer, kept so a hover overlay can be built without reloading anything.
    static var indexCache: [URL: [UInt32]] = [:]
    /// Set for the duration of a load when the glass should be flat-tinted for editing.
    static var tintGlassNow = false
    static var markColorNow: NSColor? = nil
    /// Selection to render instead of the stored one, while it is being edited.
    static var glassOverride: [Bool]? = nil
    /// Erased faces to preview before they are applied.
    static var eraseOverride: [Bool]? = nil

    /// Map a hit test back to the mesh's own face numbering.
    static func meshFace(mesh: URL, element: Int, face: Int) -> Int? {
        guard let (body, glass) = splitIndex[mesh] else { return face }
        let list = element == 0 ? body : glass
        return face >= 0 && face < list.count ? list[face] : nil
    }

    /// Exposed so a headless test can render exactly what the viewer renders.
    static func debugLoad(_ content: ViewerContent)
        -> (node: SCNNode, center: SCNVector3, radius: CGFloat)? { load(content) }

    private static func load(_ content: ViewerContent) -> (node: SCNNode, center: SCNVector3, radius: CGFloat)? {
        switch content {
        case .mesh(let url):                      return loadMesh(url)
        case .texturedMesh(let mesh, let tex):    return loadTexturedMesh(mesh, texture: tex)
        case .pbrMesh(let mesh, let albedo, let mr):
            return loadTexturedMesh(mesh, texture: albedo, metallicRoughness: mr)
        case .points(let url):                    return loadPoints(url)
        case .coverageMesh(let mesh, let cov):
            return loadTexturedMesh(mesh, texture: cov, coverage: true)
        }
    }

    /// Loads the textured .tmesh (verts f32, normals f32, UVs f32, faces i32) and
    /// applies the baked texture. With `metallicRoughness` set (PBR/Large), switches
    /// to physically-based lighting: albedo → diffuse, and the MR map is split into
    /// its glTF channels — G → roughness, B → metalness — as grayscale images.
    private static func loadTexturedMesh(_ url: URL, texture: URL,
                                         metallicRoughness: URL? = nil,
                                         coverage: Bool = false) -> (SCNNode, SCNVector3, CGFloat)? {
        guard let data = try? Data(contentsOf: url), data.count >= 8 else { return nil }
        let n = Int(data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 0, as: Int32.self) })
        let m = Int(data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 4, as: Int32.self) })
        guard n > 0, m > 0 else { return nil }
        let vBytes = n * 12, nBytes = n * 12, uvBytes = n * 8, fBytes = m * 12
        guard data.count >= 8 + vBytes + nBytes + uvBytes + fBytes else { return nil }

        var off = 8
        let vData = data.subdata(in: off ..< off + vBytes); off += vBytes
        let nData = data.subdata(in: off ..< off + nBytes); off += nBytes
        let uvData = data.subdata(in: off ..< off + uvBytes); off += uvBytes
        let fData = data.subdata(in: off ..< off + fBytes)

        let vSource = SCNGeometrySource(data: vData, semantic: .vertex, vectorCount: n,
                                        usesFloatComponents: true, componentsPerVector: 3,
                                        bytesPerComponent: 4, dataOffset: 0, dataStride: 12)
        let nSource = SCNGeometrySource(data: nData, semantic: .normal, vectorCount: n,
                                        usesFloatComponents: true, componentsPerVector: 3,
                                        bytesPerComponent: 4, dataOffset: 0, dataStride: 12)
        let uvSource = SCNGeometrySource(data: uvData, semantic: .texcoord, vectorCount: n,
                                         usesFloatComponents: true, componentsPerVector: 2,
                                         bytesPerComponent: 4, dataOffset: 0, dataStride: 8)
        // Glass gets its own element so it can stop writing depth. With one material for the
        // whole car every transparent texel still occludes what is behind it, so the near
        // glass hides the far glass and transparency appears to switch off as you rotate past
        // the midpoint — but turning depth writes off globally would make the body
        // see-through too.
        // MODELR_NO_GLASS_SPLIT=1 renders one material with per-pixel alpha instead of two
        // primitives, to test whether the split itself is what ragged-edges the windows.
        let noSplit = ProcessInfo.processInfo.environment["MODELR_NO_GLASS_SPLIT"] == "1"
        // A stored selection wins: it was made on the mesh, where a window's edge is a crease
        // rather than a guess about which chart a texel belongs to.
        // Faces the user erased are simply not built. The mesh file is untouched, so the
        // decision stays reversible and every texture baked against it stays valid.
        var erased = Self.eraseOverride ?? MeshEraser.load(forMesh: url)?.deleted
        if let e = erased, e.count != m { erased = nil }   // stale: the mesh was rebuilt
        let stored = Self.glassOverride ?? GlassSelection.load(forMesh: url)?.mask
        let glassMask = (coverage || noSplit) ? nil
            : (stored?.count == m ? stored
               : Self.glassFaces(indexData: fData, uvData: uvData,
                                 faceCount: m, textureURL: texture))
        var elements: [SCNGeometryElement] = []
        if let glassMask {
            var body = [UInt32](), glass = [UInt32]()
            fData.withUnsafeBytes { raw in
                for f in 0 ..< m where !(erased?[f] ?? false) {
                    let tri = (0..<3).map { raw.loadUnaligned(fromByteOffset: (f * 3 + $0) * 4,
                                                              as: UInt32.self) }
                    if glassMask[f] { glass.append(contentsOf: tri) } else { body.append(contentsOf: tri) }
                }
            }
            func el(_ idx: [UInt32]) -> SCNGeometryElement {
                idx.withUnsafeBufferPointer {
                    SCNGeometryElement(data: Data(buffer: $0), primitiveType: .triangles,
                                       primitiveCount: idx.count / 3, bytesPerIndex: 4)
                }
            }
            elements = [el(body), el(glass)]
            // A hit test reports a face index *within its element*, so keep the mapping back to
            // the mesh's own numbering — element 0 is body, element 1 is glass.
            var bodyIDs = [Int](), glassIDs = [Int]()
            for f in 0 ..< m where !(erased?[f] ?? false) {
                if glassMask[f] { glassIDs.append(f) } else { bodyIDs.append(f) }
            }
            Self.splitIndex[url] = (bodyIDs, glassIDs)
        } else if let erased, erased.count == m, erased.contains(true) {
            var kept = [UInt32](); kept.reserveCapacity(m * 3)
            var ids = [Int]()
            fData.withUnsafeBytes { raw in
                for f in 0 ..< m where !erased[f] {
                    for k in 0 ..< 3 {
                        kept.append(raw.loadUnaligned(fromByteOffset: (f * 3 + k) * 4,
                                                      as: UInt32.self))
                    }
                    ids.append(f)
                }
            }
            elements = [kept.withUnsafeBufferPointer {
                SCNGeometryElement(data: Data(buffer: $0), primitiveType: .triangles,
                                   primitiveCount: kept.count / 3, bytesPerIndex: 4)
            }]
            Self.splitIndex[url] = (ids, [])
        } else {
            elements = [SCNGeometryElement(data: fData, primitiveType: .triangles,
                                           primitiveCount: m, bytesPerIndex: 4)]
            Self.splitIndex[url] = nil
        }
        if Self.indexCache[url] == nil {
            var all = [UInt32](repeating: 0, count: m * 3)
            fData.withUnsafeBytes { raw in
                for i in 0 ..< (m * 3) {
                    all[i] = raw.loadUnaligned(fromByteOffset: i * 4, as: UInt32.self)
                }
            }
            Self.indexCache[url] = all
        }
        let geometry = SCNGeometry(sources: [vSource, nSource, uvSource], elements: elements)

        let material = SCNMaterial()
        material.diffuse.contents = NSImage(contentsOf: texture) ?? NSColor(white: 0.82, alpha: 1)
        material.diffuse.wrapS = .repeat
        material.diffuse.wrapT = .repeat
        material.isDoubleSided = true
        if noSplit, glassMask == nil, Self.textureHasAlpha(texture) {
            material.blendMode = .alpha
            material.transparencyMode = .aOne
            material.writesToDepthBuffer = true
            material.isDoubleSided = false
        }
        if coverage {
            // Flat and unlit: this is a readout of what is painted, and shading would be read
            // as paint. Alpha in the diffuse map punches the holes.
            material.lightingModel = .constant
            // Depth writes stay ON. With them off, faces composite in draw order instead of by
            // distance, so rotating the car paints far panels over near ones and it appears to
            // turn inside out — which reads as the model flipping. Depth writing costs nothing
            // here: the holes are transparent against the SwiftUI layer behind the whole view,
            // not against other geometry.
            material.writesToDepthBuffer = true
            material.readsFromDepthBuffer = true
            // Nearest sampling, no mips. The alpha here is a yes/no mask, and bilinear plus
            // mipmapping averages it across chart edges and thin features — a texel that is 30%
            // transparent still shows the backdrop, which is why the model came back speckled in
            // magenta even after the atlas itself was clean.
            material.diffuse.mipFilter = .none
            material.diffuse.minificationFilter = .nearest
            material.diffuse.magnificationFilter = .nearest
            material.diffuse.maxAnisotropy = 1
            // Unpainted texels are magenta in the atlas itself — alpha was unusable, SceneKit
            // ignored it through every route. Discarding on COLOUR gives back the see-through
            // behaviour: the fragment is dropped, so whatever sits behind the view (the magenta
            // backdrop, or the reference photo) shows through the hole. Colour reaches the
            // shader intact even though alpha does not.
            // Single-sided here only. Discarding a front face on a double-sided material just
            // reveals the inside of the far bodywork, so the hole showed the car's inner shell
            // instead of the backdrop behind the view.
            material.isDoubleSided = false
            material.blendMode = .alpha
            material.shaderModifiers = [.surface: """
            #pragma body
            float3 c = float3(_surface.diffuse.rgb);
            if (c.r > 0.8 && c.g < 0.3 && c.b > 0.8) { discard_fragment(); }
            """]

        }
        if let mrURL = metallicRoughness, let mr = loadCGImage(mrURL) {
            // glTF metallic-roughness packing: G = roughness, B = metallic. SceneKit's
            // physicallyBased model wants separate single-channel maps, so pull each out.
            material.lightingModel = .physicallyBased
            if let rough = channelImage(mr, channel: 1) { material.roughness.contents = rough }
            if let metal = channelImage(mr, channel: 2) { material.metalness.contents = metal }
            for prop in [material.roughness, material.metalness] {
                prop.wrapS = .repeat; prop.wrapT = .repeat
            }
        } else {
            material.lightingModel = .blinn
        }

        if glassMask != nil {
            // Body: opaque, so the atlas's alpha can't make bodywork see-through. Stays
            // double-sided — these shells have inconsistent winding and culling opens holes.
            material.blendMode = .replace

            let glassMat = SCNMaterial()
            glassMat.name = "Glass"
            glassMat.lightingModel = material.lightingModel
            // Opacity comes from the RGBA diffuse atlas, the same alpha the single-material
            // path used. Do NOT set transparencyMode/.transparent: under .physicallyBased that
            // redirects SceneKit away from the diffuse alpha and the glass renders solid.
            glassMat.diffuse.contents = Self.markColorNow
                ?? (Self.tintGlassNow ? NSColor(red: 0.1, green: 0.75, blue: 0.95, alpha: 1)
                                      : material.diffuse.contents)
            glassMat.diffuse.wrapS = .repeat
            glassMat.diffuse.wrapT = .repeat
            glassMat.roughness.contents = material.roughness.contents
            glassMat.metalness.contents = material.metalness.contents
            // The fix for the one-sided look: transparent surfaces must not occlude what is
            // drawn behind them. They still test against the opaque body.
            // Depth writes ON. A triangle on the window boundary is part frame, part glass;
            // with depth writes off its opaque half stops occluding and the frame reads as a
            // hole. Per-texel alpha already handles the transparency — the geometry does not
            // need to stop writing depth for that.
            if Self.markColorNow != nil {
                glassMat.blendMode = .replace
                glassMat.transparency = 1
                glassMat.lightingModel = .constant
            }
            // A stored opacity means the glass boundary lives in the geometry, so the material
            // carries the transparency whole rather than reading it per texel.
            //
            // Applied in the shader rather than through `transparency`: under .physicallyBased
            // SceneKit takes its alpha from the diffuse texture, and the atlas is now fully
            // opaque by design, so the property alone left the glass solid. Scaling the whole
            // output colour is the premultiplied form of the same thing.
            if Self.markColorNow == nil, Self.glassOverride == nil, !Self.tintGlassNow,
               let glass = GlassClean.Opacity.load(forMesh: url) {
                // A flat colour, not the atlas. The glass is one colour everywhere by now, so
                // sampling the texture can only go wrong — and it did: glass faces whose UVs sit
                // near a chart edge picked up streaks of bodywork. A colour with alpha is also
                // the one transparency route SceneKit honours under .physicallyBased without
                // argument, where `transparency` over an opaque texture is simply ignored.
                glassMat.diffuse.contents = NSColor(red: CGFloat(glass.r), green: CGFloat(glass.g),
                                                    blue: CGFloat(glass.b), alpha: CGFloat(glass.a))
                glassMat.blendMode = .alpha
                glassMat.writesToDepthBuffer = false
                glassMat.metalness.contents = 0.0
                glassMat.roughness.contents = 0.05
            }
            glassMat.writesToDepthBuffer = true
            glassMat.readsFromDepthBuffer = true
            // Single-sided. Double-sided glass draws the *back* face of every boundary triangle as
        // well, and along the window's rim that back face faces away from the light and renders
        // as a dark dotted outline — the seam that survived four times the texel density,
        // because it was never in the texture.
        glassMat.isDoubleSided = ProcessInfo.processInfo.environment["MODELR_GLASS_2SIDED"] == "1"
            geometry.materials = [material, glassMat]
        } else {
            geometry.materials = [material]
        }

        let node = SCNNode(geometry: geometry)
        let (lo, hi) = node.boundingBox
        let center = SCNVector3((lo.x + hi.x) / 2, (lo.y + hi.y) / 2, (lo.z + hi.z) / 2)
        let extent = max(hi.x - lo.x, max(hi.y - lo.y, hi.z - lo.z))
        return (node, center, max(extent / 2, 0.05))
    }

    /// Loads the worker's compact binary mesh (int32 nVerts, int32 nFaces, then
    /// verts f32, normals f32, faces i32) straight into SceneKit geometry — no text
    /// parsing or normal computation, so even a huge mesh loads in milliseconds.
    private static func loadMesh(_ url: URL) -> (SCNNode, SCNVector3, CGFloat)? {
        guard let data = try? Data(contentsOf: url), data.count >= 8 else { return nil }
        let n = Int(data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 0, as: Int32.self) })
        let m = Int(data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 4, as: Int32.self) })
        guard n > 0, m > 0 else { return nil }
        let vBytes = n * 12, nBytes = n * 12, fBytes = m * 12
        guard data.count >= 8 + vBytes + nBytes + fBytes else { return nil }

        let vData = data.subdata(in: 8 ..< 8 + vBytes)
        let nData = data.subdata(in: 8 + vBytes ..< 8 + vBytes + nBytes)
        let fData = data.subdata(in: 8 + vBytes + nBytes ..< 8 + vBytes + nBytes + fBytes)

        let vSource = SCNGeometrySource(data: vData, semantic: .vertex,
                                        vectorCount: n, usesFloatComponents: true,
                                        componentsPerVector: 3, bytesPerComponent: 4,
                                        dataOffset: 0, dataStride: 12)
        let nSource = SCNGeometrySource(data: nData, semantic: .normal,
                                        vectorCount: n, usesFloatComponents: true,
                                        componentsPerVector: 3, bytesPerComponent: 4,
                                        dataOffset: 0, dataStride: 12)
        let element = SCNGeometryElement(data: fData, primitiveType: .triangles,
                                         primitiveCount: m, bytesPerIndex: 4)
        let geometry = SCNGeometry(sources: [vSource, nSource], elements: [element])

        let material = SCNMaterial()
        material.lightingModel = .blinn
        material.diffuse.contents = NSColor(white: 0.82, alpha: 1)
        material.specular.contents = NSColor(white: 0.25, alpha: 1)
        material.isDoubleSided = true
        geometry.materials = [material]

        let node = SCNNode(geometry: geometry)
        let (lo, hi) = node.boundingBox
        let center = SCNVector3((lo.x + hi.x) / 2, (lo.y + hi.y) / 2, (lo.z + hi.z) / 2)
        let extent = max(hi.x - lo.x, max(hi.y - lo.y, hi.z - lo.z))
        return (node, center, max(extent / 2, 0.05))
    }

    /// Faces whose UV centroid lands on a texel painted transparent in the view sheet, so the
    /// viewer shows the same body/glass split the GLB export writes. Nil when the atlas has no
    /// transparency and one material is enough.
    /// Which faces are glass, decided per triangle from the texture's alpha.
    ///
    /// This is deliberately INCLUSIVE at the boundary: a triangle with any transparent sample
    /// joins the glass. Per-texel alpha then renders its frame half opaque and its glass half
    /// clear, so the window edge follows the painted alpha rather than the triangulation.
    /// Excluding boundary triangles instead forces them fully opaque, which shows up as a pale
    /// ragged fringe around every window — the artefact this went through several rounds of.
    ///
    /// Older note, kept because it explains the shape of the code: sampling a single texel at
    /// the face centroid and calling
    /// anything under 0.95 alpha "glass" misclassifies the window frames: a pillar triangle
    /// whose centre lands on one soft texel becomes a hole, and the frame ends up with jagged
    /// bites taken out of it — visibly triangular, because that is exactly what they are. A face
    /// now has to be transparent at all three corners AND its centre to count, and it has to be
    /// clearly transparent. The cut sits at 0.75 because the alpha
    /// histogram is three populations, not two: true glass around 0.6-0.7, a feathered edge at
    /// 0.7-0.9 left by the bake's fill and filtering, and frames at 0.9-1.0. Cutting at 0.9
    /// swallows the feather and tears the frames; cutting at 0.6 excludes the glass itself.
    private static func glassFaces(indexData: Data, uvData: Data, faceCount: Int,
                                   textureURL: URL, threshold: Float? = nil) -> [Bool]? {
        guard let cg = loadCGImage(textureURL), cg.alphaInfo != .none,
              cg.alphaInfo != .noneSkipLast, cg.alphaInfo != .noneSkipFirst else { return nil }
        let w = cg.width, h = cg.height
        var px = [UInt8](repeating: 0, count: w * h * 4)
        guard let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))

        // Same measurement the exporter makes, so the preview and the GLB agree.
        let threshold = threshold ?? MeshExporter.glassAlphaCut(px, count: w * h)
        var mask = [Bool](repeating: false, count: faceCount)
        var any = false
        indexData.withUnsafeBytes { idx in
            uvData.withUnsafeBytes { uv in
                // .tmesh UVs are already v-flipped to the viewer's top-left convention, so
                // sample straight down. Flipping again mirrors the lookup and selects roof
                // texels instead of windows.
                func alphaAt(_ u: Float, _ v: Float) -> Float {
                    let x = min(max(Int(u * Float(w - 1)), 0), w - 1)
                    let y = min(max(Int(v * Float(h - 1)), 0), h - 1)
                    return Float(px[(y * w + x) * 4 + 3]) / 255
                }
                for f in 0 ..< faceCount {
                    var us = [Float](repeating: 0, count: 3), vs = us
                    for k in 0 ..< 3 {
                        let i = Int(idx.loadUnaligned(fromByteOffset: (f * 3 + k) * 4, as: UInt32.self))
                        us[k] = uv.loadUnaligned(fromByteOffset: i * 8, as: Float.self)
                        vs[k] = uv.loadUnaligned(fromByteOffset: i * 8 + 4, as: Float.self)
                    }
                    let cu = (us[0] + us[1] + us[2]) / 3, cv = (vs[0] + vs[1] + vs[2]) / 3
                    // Pull the corners in towards the centre so a corner sitting exactly on the
                    // glass/frame boundary does not decide the whole triangle.
                    var best = alphaAt(cu, cv)
                    for k in 0 ..< 3 {
                        best = min(best, alphaAt(us[k] * 0.25 + cu * 0.75,
                                                 vs[k] * 0.25 + cv * 0.75))
                    }
                    if best < threshold { mask[f] = true; any = true }
                }
            }
        }
        return any ? mask : nil
    }

    static func textureHasAlpha(_ url: URL) -> Bool {
        guard let cg = loadCGImage(url) else { return false }
        return cg.alphaInfo != .none && cg.alphaInfo != .noneSkipLast
            && cg.alphaInfo != .noneSkipFirst
    }

    /// Decode a PNG to a CGImage for channel extraction.
    private static func loadCGImage(_ url: URL) -> CGImage? {
        guard let data = try? Data(contentsOf: url),
              let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(src, 0, nil)
    }

    /// Extract one 8-bit channel (0=R, 1=G, 2=B) of an RGBA image into a grayscale
    /// image — SceneKit reads a single-channel map's luminance for roughness/metalness.
    private static func channelImage(_ image: CGImage, channel: Int) -> NSImage? {
        let w = image.width, h = image.height
        guard w > 0, h > 0 else { return nil }
        var rgba = [UInt8](repeating: 0, count: w * h * 4)
        guard let ctx = CGContext(data: &rgba, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: w * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        var gray = [UInt8](repeating: 0, count: w * h)
        for i in 0..<(w * h) { gray[i] = rgba[i * 4 + channel] }
        guard let grayCtx = CGContext(data: &gray, width: w, height: h, bitsPerComponent: 8,
                                      bytesPerRow: w,
                                      space: CGColorSpaceCreateDeviceGray(),
                                      bitmapInfo: CGImageAlphaInfo.none.rawValue),
              let out = grayCtx.makeImage() else { return nil }
        return NSImage(cgImage: out, size: NSSize(width: w, height: h))
    }

    private static func loadPoints(_ url: URL) -> (SCNNode, SCNVector3, CGFloat)? {
        guard let data = try? Data(contentsOf: url), data.count >= 12 else { return nil }
        let count = data.count / 12     // 3 × float32 per point
        var verts = [SCNVector3]()
        verts.reserveCapacity(count)
        let big = CGFloat.greatestFiniteMagnitude
        var lo = SCNVector3(big, big, big)
        var hi = SCNVector3(-big, -big, -big)
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            for i in 0..<count {
                let x = CGFloat(raw.loadUnaligned(fromByteOffset: i * 12, as: Float32.self))
                let y = CGFloat(raw.loadUnaligned(fromByteOffset: i * 12 + 4, as: Float32.self))
                let z = CGFloat(raw.loadUnaligned(fromByteOffset: i * 12 + 8, as: Float32.self))
                verts.append(SCNVector3(x, y, z))
                if x < lo.x { lo.x = x }; if y < lo.y { lo.y = y }; if z < lo.z { lo.z = z }
                if x > hi.x { hi.x = x }; if y > hi.y { hi.y = y }; if z > hi.z { hi.z = z }
            }
        }
        guard !verts.isEmpty else { return nil }

        let source = SCNGeometrySource(vertices: verts)
        let element = SCNGeometryElement(indices: Array(0..<count), primitiveType: .point)
        element.pointSize = 4
        element.minimumPointScreenSpaceRadius = 1.0
        element.maximumPointScreenSpaceRadius = 3
        let geometry = SCNGeometry(sources: [source], elements: [element])
        let material = SCNMaterial()
        material.lightingModel = .constant
        material.diffuse.contents = NSColor.controlAccentColor
        geometry.materials = [material]

        let cx: CGFloat = (lo.x + hi.x) / 2
        let cy: CGFloat = (lo.y + hi.y) / 2
        let cz: CGFloat = (lo.z + hi.z) / 2
        let extent: CGFloat = max(hi.x - lo.x, max(hi.y - lo.y, hi.z - lo.z))
        return (SCNNode(geometry: geometry), SCNVector3(cx, cy, cz), max(extent / 2, 0.05))
    }

    // MARK: - framing

    private static func fitCamera(_ view: SCNView, center: SCNVector3, radius: CGFloat) {
        guard let cameraNode = view.pointOfView, let camera = cameraNode.camera else { return }
        // Fit the object to the *limiting* field of view so it never overflows a
        // non-square pane; generous margin so it sits comfortably inside.
        let size = view.bounds.size
        let aspect = (size.width > 1 && size.height > 1) ? Double(size.width / size.height) : 1.0
        let hFov = camera.fieldOfView * .pi / 180          // horizontal (projectionDirection = .horizontal)
        let vFov = 2 * atan(tan(hFov / 2) / max(aspect, 0.001))
        let limitFov = min(hFov, vFov)
        let distance = Double(radius) / tan(limitFov / 2) * 1.5
        cameraNode.position = SCNVector3(center.x, center.y, center.z + CGFloat(distance))
        cameraNode.look(at: center)
        camera.zNear = max(distance * 0.01, 0.001)
        camera.zFar = distance * 10 + 100
    }
}

private extension SIMD4 where Scalar == Float {
    var xyz: SIMD3<Float> { SIMD3(x, y, z) }
}
