import Foundation
import SceneKit
import AppKit

/// Drives the aligner's camera through a synthetic drag and reports what came out.
///
/// The orbit bug could only be reproduced by a person dragging and describing what they saw,
/// which is a slow and lossy way to test a thing that is entirely deterministic.
/// `SCNCameraController` exposes the same begin/continue/end interaction calls a mouse drag goes
/// through, so the whole path can be driven from code: place the camera the way the aligner
/// does, synthesise a horizontal drag, and read the pose back out after every step.
///
/// Run with `MODELR_ORBIT_SELFTEST=1`; results go to the orbit log and stdout, and the app exits.
enum OrbitSelfTest {

    static func runIfRequested() {
        guard ProcessInfo.processInfo.environment["MODELR_ORBIT_SELFTEST"] == "1" else { return }
        DispatchQueue.main.async {
            run()
            exit(0)
        }
    }

    private static func log(_ s: String) {
        print(s)
        OrbitLog.write("SELFTEST \(s)")
    }

    static func run() {
        let view = SCNView(frame: CGRect(x: 0, y: 0, width: 800, height: 800))
        view.allowsCameraControl = true
        // A real window: SceneKit's camera control runs off the view's own event handling, and
        // driving SCNCameraController's begin/continue calls directly bypasses it entirely —
        // which is why the first version of this test passed even with the fix disabled.
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.contentView = view

        let scene = SCNScene()
        // Proportioned like the cars this is used on (the .tmesh measures 2.00 long in Z,
        // 0.86 wide in X, 0.63 tall in Y). Only the bounds matter for camera behaviour.
        let body = SCNNode(geometry: SCNBox(width: 0.86, height: 0.63, length: 2.0,
                                            chamferRadius: 0))
        let container = SCNNode()
        container.name = "MeshContainer"
        container.addChildNode(body)
        scene.rootNode.addChildNode(container)

        let camera = SCNCamera()
        camera.fieldOfView = 40
        camera.projectionDirection = .horizontal
        camera.zNear = 0.001
        camera.zFar = 1000
        let cameraNode = SCNNode()
        cameraNode.camera = camera
        cameraNode.position = SCNVector3(0, 0, 3.3)
        cameraNode.look(at: SCNVector3(0, 0, 0))
        scene.rootNode.addChildNode(cameraNode)
        view.scene = scene
        view.pointOfView = cameraNode
        MeshViewer.configureOrbit(view)

        let probe = CameraProbe()
        probe.view = view

        probe.applyBakeFraming()
        probe.setPose(elev: 20, azim: 0)
        log(String(format: "projection ortho=%@ scale=%.3f",
                   camera.usesOrthographicProjection ? "yes" : "no", camera.orthographicScale))
        guard let placed = probe.currentPose() else { log("no camera after setPose"); return }
        log(String(format: "placed   e=%.2f a=%.2f", placed.elev, placed.azim))

        func event(_ type: NSEvent.EventType, _ p: CGPoint) -> NSEvent? {
            NSEvent.mouseEvent(with: type, location: p, modifierFlags: [],
                               timestamp: ProcessInfo.processInfo.systemUptime,
                               windowNumber: window.windowNumber, context: nil,
                               eventNumber: 0, clickCount: 1, pressure: 1)
        }

        // Press, drag horizontally in steps, release — the exact sequence a mouse delivers.
        let y: CGFloat = 400
        if let e = event(.leftMouseDown, CGPoint(x: 200, y: y)) { view.mouseDown(with: e) }
        for step in 1...8 {
            if let e = event(.leftMouseDragged, CGPoint(x: 200 + CGFloat(step) * 25, y: y)) {
                view.mouseDragged(with: e)
            }
            if let p = probe.currentPose() {
                log(String(format: "drag %d   e=%.2f a=%.2f   (delta e %+.2f)",
                           step, p.elev, p.azim, p.elev - placed.elev))
            }
        }
        if let e = event(.leftMouseUp, CGPoint(x: 400, y: y)) { view.mouseUp(with: e) }

        guard let end = probe.currentPose() else { return }
        let drift = abs(end.elev - placed.elev)
        log(String(format: "final    e=%.2f a=%.2f", end.elev, end.azim))
        var failures = 0
        if drift >= 2 {
            failures += 1
            log(String(format: "FAIL  horizontal drag moved elevation by %.2f deg", drift))
        } else {
            log(String(format: "ok    horizontal drag held elevation (drift %.2f deg)", drift))
        }

        // Phase 2: set a pose the way Snap does, mid-session, then drag again. This is the case
        // that bites in practice — the camera has already been driven by the user once, so the
        // controller has a populated cache to be stale.
        probe.setPose(elev: 55, azim: 120)
        guard let placed2 = probe.currentPose() else { return }
        log(String(format: "re-placed e=%.2f a=%.2f", placed2.elev, placed2.azim))
        if let e = event(.leftMouseDown, CGPoint(x: 200, y: y)) { view.mouseDown(with: e) }
        for step in 1...4 {
            if let e = event(.leftMouseDragged, CGPoint(x: 200 + CGFloat(step) * 25, y: y)) {
                view.mouseDragged(with: e)
            }
        }
        if let e = event(.leftMouseUp, CGPoint(x: 300, y: y)) { view.mouseUp(with: e) }
        if let end2 = probe.currentPose() {
            let drift2 = abs(end2.elev - placed2.elev)
            log(String(format: "final2   e=%.2f a=%.2f", end2.elev, end2.azim))
            if drift2 >= 2 {
                failures += 1
                log(String(format: "FAIL  drag after a mid-session pose moved elevation by %.2f",
                           drift2))
            } else {
                log(String(format: "ok    drag after a mid-session pose held elevation (%.2f)",
                           drift2))
            }
        }
        log(failures == 0 ? "PASS  all orbit checks" : "FAIL  \(failures) orbit check(s)")
    }
}
