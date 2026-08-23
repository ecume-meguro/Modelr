import Foundation
import SceneKit
import AppKit
import ImageIO

/// Renders the coverage view through the real SceneKit path and writes a PNG.
///
/// Checking the atlas, or rendering it with `MeshRender.renderTextured`, says nothing about what
/// the viewer draws: the atlas can be a clean yes/no mask and still come out speckled once
/// SceneKit samples it. This drives the same loader, material and camera the aligner uses, over a
/// magenta backdrop, so the output is the thing the user is looking at.
///
/// `MODELR_COVERAGE_SELFTEST=<path to .tmesh>`, `MODELR_COVERAGE_OUT=<path to .png>`,
/// optionally `MODELR_COVERAGE_POSE=elev,azim`.
enum CoverageSelfTest {

    static func runIfRequested() {
        let env = ProcessInfo.processInfo.environment
        guard let mesh = env["MODELR_COVERAGE_SELFTEST"] else { return }
        DispatchQueue.main.async {
            let out = env["MODELR_COVERAGE_OUT"] ?? "/tmp/coverage.png"
            let pose = (env["MODELR_COVERAGE_POSE"] ?? "28,215")
                .split(separator: ",").compactMap { Double($0) }
            render(meshPath: mesh, outPath: out,
                   elev: pose.first ?? 28, azim: pose.count > 1 ? pose[1] : 215)
            exit(0)
        }
    }

    static func render(meshPath: String, outPath: String, elev: Double, azim: Double) {
        let mesh = URL(fileURLWithPath: meshPath)
        let coverage = mesh.deletingLastPathComponent()
            .appendingPathComponent(mesh.deletingPathExtension().lastPathComponent
                                    + "_texture_coverage.png")
        // Only the coverage mode needs the atlas; shape and paint modes do not.
        let mode = ProcessInfo.processInfo.environment["MODELR_VIEW_MODE"] ?? "coverage"
        if mode == "coverage", !FileManager.default.fileExists(atPath: coverage.path) {
            print("no coverage atlas at \(coverage.path)"); return
        }

        let view = SCNView(frame: CGRect(x: 0, y: 0, width: 900, height: 900))
        // The aligner puts a magenta layer behind the SCNView; here the view's own background
        // stands in for it, so anything transparent in the model shows up as magenta.
        // A contrasting backdrop when asked for, so "the hole is see-through" can be told
        // apart from "the hole is painted magenta".
        switch ProcessInfo.processInfo.environment["MODELR_COVERAGE_BG"] {
        case "green": view.backgroundColor = NSColor(red: 0, green: 1, blue: 0, alpha: 1)
        case "clear":
            // What the aligner actually uses. A hole only reveals the photo underneath if the
            // SCNView renders transparent there, which an opaque backdrop inside the scene can
            // never test.
            view.backgroundColor = .clear
        default: view.backgroundColor = NSColor(red: 1, green: 0, blue: 1, alpha: 1)
        }
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.contentView = view

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
        cameraNode.camera = camera
        cameraNode.position = SCNVector3(0, 0, 3.3)
        cameraNode.look(at: SCNVector3(0, 0, 0))
        scene.rootNode.addChildNode(cameraNode)
        view.scene = scene
        view.pointOfView = cameraNode
        view.autoenablesDefaultLighting = true

        // What actually reaches the material matters more than what is in the file.
        if let img = NSImage(contentsOf: coverage) {
            let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil)
            print("NSImage load: alphaInfo=\(String(describing: cg?.alphaInfo.rawValue)) "
                  + "bitsPerPixel=\(String(describing: cg?.bitsPerPixel))")
        }
        if let src = CGImageSourceCreateWithURL(coverage as CFURL, nil),
           let cg = CGImageSourceCreateImageAtIndex(src, 0, nil) {
            print("CGImage load: alphaInfo=\(cg.alphaInfo.rawValue) bitsPerPixel=\(cg.bitsPerPixel)")
        }
        // MODELR_VIEW_MODE=paint renders the ordinary painted material instead of the coverage
        // one, so artefacts can be attributed to the viewer rather than to the atlas.
        let content: ViewerContent
        if ProcessInfo.processInfo.environment["MODELR_VIEW_MODE"] == "shape" {
            // Geometry only, so a fault in the mesh can be told apart from a fault in the paint.
            content = .mesh(mesh)
        } else if ProcessInfo.processInfo.environment["MODELR_VIEW_MODE"] == "paint" {
            let stem = mesh.deletingPathExtension().lastPathComponent
            let dir = mesh.deletingLastPathComponent()
            content = .pbrMesh(mesh,
                               albedo: dir.appendingPathComponent("\(stem)_texture.png"),
                               metallicRoughness: dir.appendingPathComponent("\(stem)_mr.png"))
        } else {
            content = .coverageMesh(mesh, coverage)
        }
        guard let loaded = MeshViewer.debugLoad(content) else {
            print("failed to load \(mesh.lastPathComponent)"); return
        }
        container.addChildNode(loaded.node)

        let probe = CameraProbe()
        probe.view = view
        probe.applyBakeFraming()
        probe.setPose(elev: elev, azim: azim)

        guard let image = view.snapshot().tiffRepresentation,
              let rep = NSBitmapImageRep(data: image),
              let png = rep.representation(using: .png, properties: [:]) else {
            print("snapshot failed"); return
        }
        try? png.write(to: URL(fileURLWithPath: outPath))
        print("wrote \(outPath)  (elev \(elev), azim \(azim))")
    }
}
