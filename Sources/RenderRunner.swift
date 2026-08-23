import Foundation
import SceneKit
import AppKit

/// Render a project to a PNG, headlessly, so the result can be looked at without the app.
///
/// Every glass fix so far has been judged from a screenshot someone had to take by hand, which
/// makes each round slow and makes it tempting to trust a number instead. Rendering the same
/// scene the viewer builds — same materials, same glass split — closes that loop.
///
/// `MODELR_RENDER=<project>`, `MODELR_RENDER_OUT=<file.png>`, optional `MODELR_RENDER_VIEW`
/// as `elev,azim,zoom` (default `12,55,0.42`, framed on the side glass).
enum RenderRunner {

    @MainActor static func runIfRequested(store: ProjectStore) {
        guard let which = ProcessInfo.processInfo.environment["MODELR_RENDER"] else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            let out = ProcessInfo.processInfo.environment["MODELR_RENDER_OUT"]
                ?? "/tmp/modelr_render.png"
            run(store: store, which: which, out: URL(fileURLWithPath: out))
            exit(0)
        }
    }

    @MainActor static func run(store: ProjectStore, which: String, out: URL) {
        // A bare mesh path renders untextured, so nothing is drawn over the edge being judged.
        if let path = ProcessInfo.processInfo.environment["MODELR_RENDER_MESH"] {
            // With a texture, render it painted; without, plain grey.
            let content: ViewerContent =
                ProcessInfo.processInfo.environment["MODELR_RENDER_TEX"].map {
                    .texturedMesh(URL(fileURLWithPath: path), URL(fileURLWithPath: $0))
                } ?? .mesh(URL(fileURLWithPath: path))
            guard let loaded = MeshViewer.debugLoad(content) else {
                print("FAIL  cannot load \(path)"); return
            }
            draw(loaded, out: out, label: path)
            return
        }
        guard let project = store.projects.first(where: { $0.name == which }),
              let content = store.currentViewerContent(for: project),
              let loaded = MeshViewer.debugLoad(content) else {
            print("FAIL  no renderable content for \(which)"); return
        }
        draw(loaded, out: out, label: which)
    }

    @MainActor static func draw(_ loaded: (node: SCNNode, center: SCNVector3, radius: CGFloat),
                                out: URL, label: String) {
        var elev: Float = 12, azim: Float = 55, zoom: Float = 0.42
        if let v = ProcessInfo.processInfo.environment["MODELR_RENDER_VIEW"] {
            let p = v.split(separator: ",").compactMap { Float($0) }
            if p.count == 3 { elev = p[0]; azim = p[1]; zoom = p[2] }
        }

        let view = SCNView(frame: CGRect(x: 0, y: 0, width: 1000, height: 1000))
        // A real window: SceneKit renders nothing off a view that was never hosted.
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.contentView = view
        let scene = SCNScene()
        scene.rootNode.addChildNode(loaded.node)
        let ambient = SCNNode()
        ambient.light = SCNLight(); ambient.light?.type = .ambient; ambient.light?.intensity = 280
        scene.rootNode.addChildNode(ambient)
        let key = SCNNode()
        key.light = SCNLight(); key.light?.type = .directional; key.light?.intensity = 700
        key.position = SCNVector3(2, 3, 3); key.look(at: loaded.center)
        scene.rootNode.addChildNode(key)

        let cam = SCNCamera()
        cam.fieldOfView = 40; cam.zNear = 0.001; cam.zFar = 1000
        let camNode = SCNNode(); camNode.camera = cam
        let r = Float(loaded.radius) / max(zoom, 0.05)
        let e = elev * .pi / 180, a = azim * .pi / 180
        camNode.position = SCNVector3(loaded.center.x + CGFloat(r * cos(e) * sin(a)),
                                      loaded.center.y + CGFloat(r * sin(e)),
                                      loaded.center.z + CGFloat(r * cos(e) * cos(a)))
        camNode.look(at: loaded.center)
        scene.rootNode.addChildNode(camNode)
        view.scene = scene
        view.pointOfView = camNode
        view.backgroundColor = .white
        view.antialiasingMode = .multisampling4X

        let image = view.snapshot()
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else {
            print("FAIL  could not encode the render"); return
        }
        try? png.write(to: out)
        print("ok    rendered \(label) -> \(out.path)")
    }
}
