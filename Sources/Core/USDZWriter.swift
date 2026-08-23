import Foundation
import SceneKit
import ImageIO
import CoreGraphics
import AppKit

/// Writes a painted mesh straight to USDZ, keeping the body/glass material split.
///
/// Kept apart from `MeshExporter`, which is deliberately pure-Foundation so it can be
/// unit-tested off the main thread; this needs SceneKit. USDZ is the end of the line for
/// RealityKit, and it cannot be produced by converting our GLB — SceneKit has no glTF
/// importer, so the geometry is handed to SceneKit directly instead of round-tripping.
///
/// USDZ materials are `UsdPreviewSurface`, which has opacity and ior but no transmission,
/// so painted alpha (opacity) is as close to real glass as the format can express.
enum USDZWriter {

    static func write(_ mesh: MeshExporter.MeshData, to dest: URL) throws {
        let scene = SCNScene()
        let node = SCNNode(geometry: try geometry(mesh))
        scene.rootNode.addChildNode(node)
        guard scene.write(to: dest, options: nil, delegate: nil, progressHandler: nil) else {
            throw MeshExporter.ExportError.unreadable
        }
    }

    private static func geometry(_ mesh: MeshExporter.MeshData) throws -> SCNGeometry {
        let verts = (0 ..< mesh.vertCount).map {
            SCNVector3(CGFloat(mesh.verts[$0*3]), CGFloat(mesh.verts[$0*3+1]), CGFloat(mesh.verts[$0*3+2]))
        }
        let norms = (0 ..< mesh.vertCount).map {
            SCNVector3(CGFloat(mesh.normals[$0*3]), CGFloat(mesh.normals[$0*3+1]), CGFloat(mesh.normals[$0*3+2]))
        }
        var sources = [SCNGeometrySource(vertices: verts), SCNGeometrySource(normals: norms)]
        if let uvs = mesh.uvs {
            let pts = (0 ..< mesh.vertCount).map { CGPoint(x: CGFloat(uvs[$0*2]), y: CGFloat(uvs[$0*2+1])) }
            sources.append(SCNGeometrySource(textureCoordinates: pts))
        }

        // One element per material. Splitting glass out here — rather than letting the whole
        // car blend — keeps the body opaque and leaves "Glass" addressable by name in
        // RealityKit for runtime tinting.
        let split = mesh.uvs != nil ? MeshExporter.glassFaceMask(mesh) : nil
        var elements: [SCNGeometryElement] = []
        var materials: [SCNMaterial] = []

        let albedo = mesh.texturePNG.flatMap { NSImage(data: $0) }
        let mr = mesh.metallicRoughnessPNG.flatMap { splitMetallicRoughness($0) }

        func element(_ faces: [Int]) -> SCNGeometryElement {
            var idx = [Int32](); idx.reserveCapacity(faces.count * 3)
            for f in faces { for k in 0..<3 { idx.append(Int32(mesh.indices[f*3 + k])) } }
            return SCNGeometryElement(indices: idx, primitiveType: .triangles)
        }

        if let split {
            let bodyFaces = (0 ..< mesh.faceCount).filter { !split.mask[$0] }
            let glassFaces = (0 ..< mesh.faceCount).filter { split.mask[$0] }
            elements = [element(bodyFaces), element(glassFaces)]
            materials = [bodyMaterial(albedo: albedo, mr: mr, opaque: true),
                         glassMaterial(albedo: albedo, alphaPNG: mesh.texturePNG)]
        } else {
            elements = [element(Array(0 ..< mesh.faceCount))]
            materials = [bodyMaterial(albedo: albedo, mr: mr,
                                      opaque: !(mesh.texturePNG.map(MeshExporter.pngHasAlpha) ?? false))]
        }

        let geo = SCNGeometry(sources: sources, elements: elements)
        geo.materials = materials
        return geo
    }

    private static func bodyMaterial(albedo: NSImage?, mr: (metal: NSImage, rough: NSImage)?,
                                     opaque: Bool) -> SCNMaterial {
        let m = SCNMaterial()
        m.name = "painted"
        m.lightingModel = .physicallyBased
        m.diffuse.contents = albedo
        if let mr {
            m.metalness.contents = mr.metal
            m.roughness.contents = mr.rough
        } else {
            m.metalness.contents = 0.0
            m.roughness.contents = 1.0
        }
        m.isDoubleSided = false
        if !opaque { m.blendMode = .alpha; m.transparencyMode = .aOne }
        return m
    }

    private static func glassMaterial(albedo: NSImage?, alphaPNG: Data?) -> SCNMaterial {
        let m = SCNMaterial()
        m.name = "Glass"
        m.lightingModel = .physicallyBased
        m.diffuse.contents = albedo
        // Per-texel opacity straight from the alpha painted into the view sheet: a windscreen
        // at 30% and side glass at 60% stay distinct, where one scalar would average them.
        if let alphaPNG, let img = NSImage(data: alphaPNG) {
            m.transparent.contents = img
            m.transparencyMode = .aOne
        }
        m.blendMode = .alpha
        m.metalness.contents = 0.0
        // Transparent *and* matte reads as plastic; glass wants a low roughness.
        m.roughness.contents = 0.05
        // Hollow shell: single-sided glass shows the empty cabin as a hole.
        m.isDoubleSided = true
        return m
    }

    /// glTF packs roughness in G and metallic in B; SceneKit wants them as separate maps.
    private static func splitMetallicRoughness(_ png: Data) -> (metal: NSImage, rough: NSImage)? {
        guard let src = CGImageSourceCreateWithData(png as CFData, nil),
              let cg = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
        let w = cg.width, h = cg.height
        var px = [UInt8](repeating: 0, count: w * h * 4)
        guard let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))

        func channel(_ offset: Int) -> NSImage? {
            var grey = [UInt8](repeating: 0, count: w * h)
            for i in 0 ..< (w * h) { grey[i] = px[i * 4 + offset] }
            guard let provider = CGDataProvider(data: Data(grey) as CFData),
                  let out = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 8,
                                    bytesPerRow: w, space: CGColorSpaceCreateDeviceGray(),
                                    bitmapInfo: CGBitmapInfo(rawValue: 0), provider: provider,
                                    decode: nil, shouldInterpolate: false, intent: .defaultIntent)
            else { return nil }
            return NSImage(cgImage: out, size: NSSize(width: w, height: h))
        }
        guard let rough = channel(1), let metal = channel(2) else { return nil }
        return (metal, rough)
    }
}
