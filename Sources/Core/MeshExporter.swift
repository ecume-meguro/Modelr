import Foundation
import ImageIO          // decoding the atlas to find the glass faces
import CoreGraphics

/// A user-pickable export format for the generated mesh.
enum MeshExportFormat: String, CaseIterable, Identifiable {
    case usdz, glb, obj, stl, ply

    var id: String { rawValue }
    var ext: String { rawValue }

    /// Menu label. Hints stay true whether or not the source has a texture
    /// (the shape mesh has none; the painted mesh does).
    var menuTitle: String {
        switch self {
        case .usdz: return "USDZ · RealityKit / AR (single file)"
        case .glb: return "GLB · 3D / AR / web (single file)"
        case .obj: return "OBJ · mesh + material"
        case .stl: return "STL · geometry (3D printing)"
        case .ply: return "PLY · geometry data"
        }
    }

    var icon: String {
        switch self {
        case .usdz: return "arkit"
        case .glb: return "shippingbox"
        case .obj: return "cube"
        case .stl: return "printer"
        case .ply: return "point.3.connected.trianglepath.dotted"
        }
    }
}

/// Converts Modelr's compact binary meshes into standard interchange formats.
///
/// Pure-Foundation (no AppKit / SceneKit) so it can be unit-tested standalone and
/// run off the main thread. Source layouts:
///   `.mesh`  = [i32 n][i32 m][f32 verts n*3][f32 normals n*3][i32 faces m*3]
///   `.tmesh` = [i32 n][i32 m][f32 verts n*3][f32 normals n*3][f32 uvs n*2][i32 faces m*3] + separate PNG
enum MeshExporter {
    enum ExportError: Error { case unreadable, empty, truncated }

    struct MeshData {
        /// Where the mesh came from, so a per-mesh glass selection can be found beside it.
        var sourceURL: URL? = nil
        let vertCount: Int
        let faceCount: Int
        let verts: [Float]        // 3 * vertCount
        let normals: [Float]      // 3 * vertCount
        let uvs: [Float]?         // 2 * vertCount, or nil (untextured)
        let indices: [UInt32]     // 3 * faceCount
        // Raw little-endian source slices (same byte layout glTF wants) for fast GLB packing.
        let rawVerts: Data
        let rawNormals: Data
        let rawUVs: Data?
        let rawFaces: Data
        let texturePNG: Data?     // raw PNG bytes (textured export: baseColor/albedo)
        /// Optional metallic-roughness PNG (glTF 2.0 convention: G = roughness,
        /// B = metallic). Provided by the PBR paint path; GLB embeds it alongside
        /// the base color.
        let metallicRoughnessPNG: Data?
    }

    // MARK: - Public entry point

    /// Read `meshURL` (+ optional `texture` and `metallicRoughness`) and write
    /// `format` to `dest`. OBJ additionally writes a companion `.mtl` and `.png`
    /// next to `dest`. `metallicRoughness` affects GLB only (§4.8: PBR GLB carries
    /// albedo + metallic-roughness); the other formats have no standard slot for it.
    static func export(meshURL: URL, texture: URL?, metallicRoughness: URL? = nil,
                       format: MeshExportFormat, to dest: URL) throws {
        let mesh = try read(meshURL: meshURL, textureURL: texture,
                            metallicRoughnessURL: metallicRoughness)
        switch format {
        case .stl: try encodeSTL(mesh).write(to: dest)
        case .ply: try encodePLY(mesh).write(to: dest)
        case .glb: try encodeGLB(mesh).write(to: dest)
        case .usdz: try USDZWriter.write(mesh, to: dest)
        case .obj:
            let dir = dest.deletingLastPathComponent()
            let base = dest.deletingPathExtension().lastPathComponent
            var textureName: String? = nil
            if let png = mesh.texturePNG, mesh.uvs != nil {
                textureName = base + ".png"
                try png.write(to: dir.appendingPathComponent(textureName!))
            }
            let mtlName = textureName != nil ? base + ".mtl" : nil
            let (objData, mtlData) = encodeOBJ(mesh, mtlName: mtlName, textureName: textureName)
            try objData.write(to: dest)
            if let mtlData, let mtlName {
                try mtlData.write(to: dir.appendingPathComponent(mtlName))
            }
        }
    }

    // MARK: - Reading

    static func read(meshURL: URL, textureURL: URL?,
                     metallicRoughnessURL: URL? = nil) throws -> MeshData {
        guard let data = try? Data(contentsOf: meshURL), data.count >= 8 else { throw ExportError.unreadable }
        let n = Int(data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 0, as: Int32.self) })
        let m = Int(data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 4, as: Int32.self) })
        guard n > 0, m > 0 else { throw ExportError.empty }

        let textured = textureURL != nil
        let vBytes = n * 12, nBytes = n * 12, uvBytes = textured ? n * 8 : 0, fBytes = m * 12
        guard data.count >= 8 + vBytes + nBytes + uvBytes + fBytes else { throw ExportError.truncated }

        var off = 8
        let rawVerts = data.subdata(in: off ..< off + vBytes); off += vBytes
        let rawNormals = data.subdata(in: off ..< off + nBytes); off += nBytes
        var rawUVs: Data? = nil
        if textured { rawUVs = data.subdata(in: off ..< off + uvBytes); off += uvBytes }
        let rawFaces = data.subdata(in: off ..< off + fBytes)

        let verts = floats(rawVerts, count: n * 3)
        let normals = floats(rawNormals, count: n * 3)
        let uvs = rawUVs.map { floats($0, count: n * 2) }
        let indices = uints(rawFaces, count: m * 3)

        var png: Data? = nil
        if let textureURL { png = try? Data(contentsOf: textureURL) }
        var mrPNG: Data? = nil
        if let metallicRoughnessURL { mrPNG = try? Data(contentsOf: metallicRoughnessURL) }

        var out = MeshData(vertCount: n, faceCount: m, verts: verts, normals: normals, uvs: uvs,
                        indices: indices, rawVerts: rawVerts, rawNormals: rawNormals,
                        rawUVs: rawUVs, rawFaces: rawFaces, texturePNG: png,
                        metallicRoughnessPNG: mrPNG)
        out.sourceURL = meshURL
        return out
    }

    private static func floats(_ d: Data, count: Int) -> [Float] {
        var out = [Float](repeating: 0, count: count)
        d.withUnsafeBytes { raw in
            for i in 0..<count { out[i] = raw.loadUnaligned(fromByteOffset: i * 4, as: Float32.self) }
        }
        return out
    }

    private static func uints(_ d: Data, count: Int) -> [UInt32] {
        var out = [UInt32](repeating: 0, count: count)
        d.withUnsafeBytes { raw in
            for i in 0..<count { out[i] = raw.loadUnaligned(fromByteOffset: i * 4, as: UInt32.self) }
        }
        return out
    }

    // MARK: - STL (binary, little-endian)

    static func encodeSTL(_ mesh: MeshData) -> Data {
        var out = Data(capacity: 84 + mesh.faceCount * 50)
        out.append(Data(count: 80))                 // header
        out.appendLE(UInt32(mesh.faceCount))
        let v = mesh.verts
        for f in 0..<mesh.faceCount {
            let i0 = Int(mesh.indices[f * 3]) * 3
            let i1 = Int(mesh.indices[f * 3 + 1]) * 3
            let i2 = Int(mesh.indices[f * 3 + 2]) * 3
            let ax = v[i0], ay = v[i0 + 1], az = v[i0 + 2]
            let bx = v[i1], by = v[i1 + 1], bz = v[i1 + 2]
            let cx = v[i2], cy = v[i2 + 1], cz = v[i2 + 2]
            // geometric normal = (b-a) × (c-a), normalized
            let ux = bx - ax, uy = by - ay, uz = bz - az
            let wx = cx - ax, wy = cy - ay, wz = cz - az
            var nx = uy * wz - uz * wy
            var ny = uz * wx - ux * wz
            var nz = ux * wy - uy * wx
            let len = (nx * nx + ny * ny + nz * nz).squareRoot()
            if len > 0 { nx /= len; ny /= len; nz /= len } else { nx = 0; ny = 0; nz = 0 }
            out.appendLE(nx); out.appendLE(ny); out.appendLE(nz)
            out.appendLE(ax); out.appendLE(ay); out.appendLE(az)
            out.appendLE(bx); out.appendLE(by); out.appendLE(bz)
            out.appendLE(cx); out.appendLE(cy); out.appendLE(cz)
            out.appendLE(UInt16(0))                 // attribute byte count
        }
        return out
    }

    // MARK: - OBJ (+ MTL)

    static func encodeOBJ(_ mesh: MeshData, mtlName: String?, textureName: String?) -> (obj: Data, mtl: Data?) {
        let hasUV = mesh.uvs != nil && textureName != nil
        var s = "# Modelr export\n"
        s.reserveCapacity(mesh.vertCount * 64 + mesh.faceCount * 40)
        if hasUV, let mtlName { s += "mtllib \(mtlName)\nusemtl material0\n" }

        let v = mesh.verts, nrm = mesh.normals
        for i in 0..<mesh.vertCount {
            s += "v \(v[i*3]) \(v[i*3+1]) \(v[i*3+2])\n"
        }
        for i in 0..<mesh.vertCount {
            s += "vn \(nrm[i*3]) \(nrm[i*3+1]) \(nrm[i*3+2])\n"
        }
        if hasUV, let uv = mesh.uvs {
            // Our UVs use a top-left origin (SceneKit); OBJ's vt origin is bottom-left → flip V.
            for i in 0..<mesh.vertCount {
                s += "vt \(uv[i*2]) \(1 - uv[i*2+1])\n"
            }
        }
        for f in 0..<mesh.faceCount {
            let a = Int(mesh.indices[f*3]) + 1
            let b = Int(mesh.indices[f*3+1]) + 1
            let c = Int(mesh.indices[f*3+2]) + 1
            if hasUV {
                s += "f \(a)/\(a)/\(a) \(b)/\(b)/\(b) \(c)/\(c)/\(c)\n"
            } else {
                s += "f \(a)//\(a) \(b)//\(b) \(c)//\(c)\n"
            }
        }

        var mtl: Data? = nil
        if hasUV, let textureName {
            // OBJ/MTL has no standard metallic-roughness slot, so a PBR export carries
            // the albedo (base color) only — note it so the dropped map isn't a surprise.
            let pbrNote = mesh.metallicRoughnessPNG != nil
                ? "# albedo (base color) only — OBJ/MTL has no metallic-roughness slot; use GLB for full PBR\n"
                : ""
            let m = """
            # Modelr material
            \(pbrNote)newmtl material0
            Ka 1.000 1.000 1.000
            Kd 1.000 1.000 1.000
            Ks 0.000 0.000 0.000
            d 1.0
            illum 2
            map_Kd \(textureName)
            """
            mtl = Data(m.utf8)
        }
        return (Data(s.utf8), mtl)
    }

    // MARK: - PLY (binary little-endian)

    static func encodePLY(_ mesh: MeshData) -> Data {
        let hasUV = mesh.uvs != nil
        var header = """
        ply
        format binary_little_endian 1.0
        comment Modelr export
        element vertex \(mesh.vertCount)
        property float x
        property float y
        property float z
        property float nx
        property float ny
        property float nz

        """
        if hasUV { header += "property float s\nproperty float t\n" }
        header += """
        element face \(mesh.faceCount)
        property list uchar uint vertex_indices
        end_header

        """
        var out = Data(header.utf8)
        out.reserveCapacity(header.count + mesh.vertCount * 32 + mesh.faceCount * 13)
        let v = mesh.verts, nrm = mesh.normals
        for i in 0..<mesh.vertCount {
            out.appendLE(v[i*3]); out.appendLE(v[i*3+1]); out.appendLE(v[i*3+2])
            out.appendLE(nrm[i*3]); out.appendLE(nrm[i*3+1]); out.appendLE(nrm[i*3+2])
            if hasUV, let uv = mesh.uvs { out.appendLE(uv[i*2]); out.appendLE(uv[i*2+1]) }
        }
        for f in 0..<mesh.faceCount {
            out.append(UInt8(3))
            out.appendLE(mesh.indices[f*3]); out.appendLE(mesh.indices[f*3+1]); out.appendLE(mesh.indices[f*3+2])
        }
        return out
    }

    // MARK: - GLB (glTF 2.0 binary, single file with embedded PNG)

    /// Does this PNG carry alpha? Read straight from the IHDR colour-type byte (offset 25:
    /// 4 = grey+alpha, 6 = RGBA) rather than decoding the whole image.
    /// Whether the texture is actually transparent anywhere — not merely whether it carries an
    /// alpha channel.
    ///
    /// The distinction matters at export. A fully opaque RGBA texture used to be enough to mark
    /// the material `alphaMode: BLEND` and `doubleSided`, which drops the whole car into a game
    /// engine's transparent queue: sorted every frame, no early-z, and prone to depth artifacts —
    /// all for an alpha channel that is 255 everywhere.
    static func pngHasAlpha(_ png: Data) -> Bool {
        guard png.count > 25 else { return false }
        let colorType = png[png.startIndex + 25]
        guard colorType == 4 || colorType == 6 else { return false }
        guard let src = CGImageSourceCreateWithData(png as CFData, nil),
              let cg = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return false }
        let w = cg.width, h = cg.height
        guard w > 0, h > 0 else { return false }
        // Zero-filled, not 255-filled: drawing is source-over, so an opaque destination makes
        // every result alpha 255 and the whole texture reads as opaque.
        var px = [UInt8](repeating: 0, count: w * h * 4)
        guard let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return false }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        // Sample rather than scan: an 8192 atlas is 67M texels, and glass is never a handful of
        // stray pixels — anything worth splitting covers percent of the sheet.
        let step = max(1, (w * h) / 200_000)
        var i = 0
        while i < w * h {
            if px[i * 4 + 3] < 250 { return true }
            i += step
        }
        return false
    }

    /// Faces whose UV centroid lands on a texel you painted transparent in the view sheet.
    /// Used to give glass its own glTF material rather than alpha-blending the whole car:
    /// USDZ preserves material assignments but cannot split one material into two afterwards,
    /// so the separation has to exist in the GLB. Returns nil when there is nothing to split.
    /// Inclusive at the boundary, matching `MeshViewer.glassFaces`: a triangle with any
    /// transparent sample joins the glass primitive, where per-pixel alpha renders its frame
    /// half opaque and its glass half clear. Assigning it to the opaque body instead forces the
    /// whole triangle opaque and fringes every window.
    ///
    /// Older note on the sampling: one texel at the face centroid,
    /// with anything under 0.95 alpha counted as glass, misclassifies the window frames: a
    /// pillar triangle whose centre lands on a single soft texel becomes a hole, and the frame
    /// exports with triangular bites out of it. A face must be transparent at its centre and at
    /// all three corners, and properly transparent rather than merely not-quite-opaque.

    /// Where to cut between glass and bodywork, measured from the texture itself.
    ///
    /// A fixed threshold cannot work: the paint model gives each car's glass a different alpha —
    /// 0.62 on one, 0.68 on another, 0.78 on a third — while the feathered edge left by the
    /// bake's fill and filtering always runs from just above that up to 1.0. Cutting too high
    /// swallows the feather and tears the window frames; too low and the glass is not detected
    /// at all. So find the glass population (the low tail of the non-opaque alphas) and cut just
    /// above it.
    static func glassAlphaCut(_ px: [UInt8], count: Int, fallback: Float = 0.75) -> Float {
        var soft = [Float]()
        soft.reserveCapacity(4096)
        let step = max(1, count / 200_000)
        var i = 0
        while i < count {
            let a = Float(px[i * 4 + 3]) / 255
            if a < 0.995 { soft.append(a) }
            i += step
        }
        guard soft.count > 64 else { return fallback }
        soft.sort()
        let p5 = soft[max(0, soft.count * 5 / 100)]
        return min(0.9, max(0.5, p5 + 0.08))
    }

    /// A selection made on the mesh, if one exists, in preference to sampling the atlas.
    static func storedGlassMask(_ mesh: MeshData, meshURL: URL?) -> [Bool]? {
        guard let meshURL, let sel = GlassSelection.load(forMesh: meshURL),
              sel.mask.count == mesh.faceCount, !sel.isEmpty else { return nil }
        return sel.mask
    }

    static func glassFaceMask(_ mesh: MeshData, threshold: Float? = nil)
        -> (mask: [Bool], meanAlpha: Float, tint: [Float])? {
        // A stored selection is enough on its own. Requiring alpha in the atlas made sense
        // while alpha was what identified glass; now that the mesh is cut to the window and the
        // opacity lives on the material, the atlas is deliberately opaque and that guard would
        // silently export a car with no glass primitive at all.
        guard let png = mesh.texturePNG, let uvs = mesh.uvs,
              pngHasAlpha(png) || storedGlassMask(mesh, meshURL: mesh.sourceURL) != nil,
              let src = CGImageSourceCreateWithData(png as CFData, nil),
              let cg = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
        let w = cg.width, h = cg.height
        var px = [UInt8](repeating: 0, count: w * h * 4)
        guard let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))

        let threshold = threshold ?? Self.glassAlphaCut(px, count: w * h)
        // A selection made on the mesh replaces the sampling entirely; the sampling below then
        // only supplies the glass tint and mean alpha for the material.
        let stored = storedGlassMask(mesh, meshURL: mesh.sourceURL)
        var mask = stored ?? [Bool](repeating: false, count: mesh.faceCount)
        var alphaSum: Float = 0, rSum: Float = 0, gSum: Float = 0, bSum: Float = 0
        var hits = 0
        // .tmesh UVs are already v-flipped to the viewer's top-left convention, so sample
        // straight down. Flipping again mirrors the lookup vertically and selects roof texels
        // instead of windows — confirmed by tinting the glass material and seeing the roof
        // light up.
        func offsetAt(_ u: Float, _ v: Float) -> Int {
            let x = min(max(Int(u * Float(w - 1)), 0), w - 1)
            let y = min(max(Int(v * Float(h - 1)), 0), h - 1)
            return (y * w + x) * 4
        }
        for f in 0 ..< mesh.faceCount {
            var us = [Float](repeating: 0, count: 3), vs = us
            for k in 0 ..< 3 {
                let i = Int(mesh.indices[f * 3 + k])
                us[k] = uvs[i * 2]; vs[k] = uvs[i * 2 + 1]
            }
            let u = (us[0] + us[1] + us[2]) / 3, v = (vs[0] + vs[1] + vs[2]) / 3
            let o = offsetAt(u, v)
            // Corners pulled 75% toward the centre, so a vertex sitting exactly on the
            // glass/frame boundary cannot decide the whole triangle.
            var best = Float(px[o + 3]) / 255
            for k in 0 ..< 3 {
                let oc = offsetAt(us[k] * 0.25 + u * 0.75, vs[k] * 0.25 + v * 0.75)
                best = min(best, Float(px[oc + 3]) / 255)
            }
            let a = Float(px[o + 3]) / 255
            if best < threshold || stored?[f] == true {
                if stored == nil { mask[f] = true }
                alphaSum += a
                // Un-premultiply so the tint is the glass colour, not the colour times alpha.
                let s = a > 0.004 ? a : 1
                rSum += Float(px[o]) / 255 / s
                gSum += Float(px[o + 1]) / 255 / s
                bSum += Float(px[o + 2]) / 255 / s
                hits += 1
            }
        }
        guard hits > 0 else { return nil }
        let k = Float(hits)
        return (mask, alphaSum / k, [rSum / k, gSum / k, bSum / k])
    }

    static func encodeGLB(_ mesh: MeshData) -> Data {
        let n = mesh.vertCount
        let m3 = mesh.faceCount * 3
        let hasUV = mesh.rawUVs != nil && mesh.texturePNG != nil
        // PBR: a metallic-roughness map rides along only when the base color does
        // (both sample the same TEXCOORD_0 per glTF 2.0 pbrMetallicRoughness).
        let hasMR = hasUV && mesh.metallicRoughnessPNG != nil

        // Index count of the body half when the glass split applies; nil = single primitive.
        var glassIdxSplit: Int?

        // BIN buffer — concatenate the raw LE slices (already in glTF's expected byte layout),
        // 4-byte aligned by construction (12n, 12n, 8n, 12m are all multiples of 4).
        var bin = Data()
        bin.reserveCapacity(mesh.rawVerts.count + mesh.rawNormals.count
                            + (mesh.rawUVs?.count ?? 0) + mesh.rawFaces.count
                            + (mesh.texturePNG?.count ?? 0) + 4)
        let posOffset = 0
        bin.append(mesh.rawVerts)
        let norOffset = bin.count
        bin.append(mesh.rawNormals)
        var uvOffset = 0
        if hasUV, let uv = mesh.rawUVs { uvOffset = bin.count; bin.append(uv) }
        // Glass gets its own material, which means its own primitive. Positions, normals and
        // UVs stay shared — only the index buffer is partitioned, body faces first, so both
        // primitives are plain subranges of one accessor's worth of data.
        // Erased faces never reach the file.
        let erased = mesh.sourceURL.flatMap { MeshEraser.load(forMesh: $0)?.deleted }
            .flatMap { $0.count == mesh.faceCount ? $0 : nil }
        let alive: (Int) -> Bool = { f in !(erased?.count == mesh.faceCount && erased![f]) }
        let glass = hasUV ? glassFaceMask(mesh) : nil
        let idxOffset = bin.count
        // Erasing faces means fewer indices than the mesh's face count implies; the accessors
        // must describe what was written, not what the mesh started with.
        var writtenIdx = m3
        if let glass {
            var ordered = [UInt32](); ordered.reserveCapacity(m3)
            for f in 0 ..< mesh.faceCount where !glass.mask[f] && alive(f) {
                ordered.append(contentsOf: mesh.indices[f * 3 ..< f * 3 + 3])
            }
            let bodyCount = ordered.count
            for f in 0 ..< mesh.faceCount where glass.mask[f] && alive(f) {
                ordered.append(contentsOf: mesh.indices[f * 3 ..< f * 3 + 3])
            }
            glassIdxSplit = bodyCount
            writtenIdx = ordered.count
            ordered.withUnsafeBufferPointer { bin.append(Data(buffer: $0)) }
        } else if erased?.count == mesh.faceCount, erased!.contains(true) {
            var kept = [UInt32](); kept.reserveCapacity(m3)
            for f in 0 ..< mesh.faceCount where alive(f) {
                kept.append(contentsOf: mesh.indices[f * 3 ..< f * 3 + 3])
            }
            writtenIdx = kept.count
            kept.withUnsafeBufferPointer { bin.append(Data(buffer: $0)) }
        } else {
            bin.append(mesh.rawFaces)
        }
        var imgOffset = 0, imgLen = 0
        if hasUV, let png = mesh.texturePNG {
            imgOffset = bin.count       // already 4-aligned (follows 12m indices)
            imgLen = png.count
            bin.append(png)
        }
        var mrOffset = 0, mrLen = 0
        if hasMR, let mr = mesh.metallicRoughnessPNG {
            while bin.count % 4 != 0 { bin.append(0) }  // PNG lengths aren't 4-aligned
            mrOffset = bin.count
            mrLen = mr.count
            bin.append(mr)
        }
        let bufferLen = bin.count       // logical buffer length (unpadded)
        while bin.count % 4 != 0 { bin.append(0) }     // pad chunk to 4 bytes

        // POSITION accessor requires min/max.
        var mn = [Double](repeating: .greatestFiniteMagnitude, count: 3)
        var mx = [Double](repeating: -.greatestFiniteMagnitude, count: 3)
        let v = mesh.verts
        for i in 0..<n {
            for k in 0..<3 {
                let val = Double(v[i*3 + k])
                if val < mn[k] { mn[k] = val }
                if val > mx[k] { mx[k] = val }
            }
        }

        var accessors: [[String: Any]] = [
            ["bufferView": 0, "componentType": 5126, "count": n, "type": "VEC3",
             "min": mn, "max": mx],
            ["bufferView": 1, "componentType": 5126, "count": n, "type": "VEC3"],
        ]
        var bufferViews: [[String: Any]] = [
            ["buffer": 0, "byteOffset": posOffset, "byteLength": n * 12, "target": 34962],
            ["buffer": 0, "byteOffset": norOffset, "byteLength": n * 12, "target": 34962],
        ]
        var attributes: [String: Any] = ["POSITION": 0, "NORMAL": 1]
        var nextAccessor = 2, nextBV = 2

        if hasUV {
            attributes["TEXCOORD_0"] = nextAccessor
            accessors.append(["bufferView": nextBV, "componentType": 5126, "count": n, "type": "VEC2"])
            bufferViews.append(["buffer": 0, "byteOffset": uvOffset, "byteLength": n * 8, "target": 34962])
            nextAccessor += 1; nextBV += 1
        }
        // One bufferView over the whole index range; the two primitives take subranges of it
        // via accessor byteOffset, so nothing is duplicated in the BIN.
        let idxBV = nextBV
        bufferViews.append(["buffer": 0, "byteOffset": idxOffset,
                            "byteLength": writtenIdx * 4, "target": 34963])
        nextBV += 1
        let idxAccessor = nextAccessor
        let bodyIdxCount = glassIdxSplit ?? writtenIdx
        accessors.append(["bufferView": idxBV, "componentType": 5125,
                          "count": bodyIdxCount, "type": "SCALAR"])
        nextAccessor += 1
        var glassAccessor: Int?
        if let split = glassIdxSplit, split < writtenIdx {
            glassAccessor = nextAccessor
            accessors.append(["bufferView": idxBV, "byteOffset": split * 4, "componentType": 5125,
                              "count": writtenIdx - split, "type": "SCALAR"])
            nextAccessor += 1
        }

        var primitive: [String: Any] = ["attributes": attributes, "indices": idxAccessor]
        var json: [String: Any] = [
            "asset": ["version": "2.0", "generator": "Modelr"],
            "scene": 0,
            "scenes": [["nodes": [0]]],
            "nodes": [["mesh": 0]],
            "buffers": [["byteLength": bufferLen]],
        ]

        if hasUV {
            let imgBV = nextBV
            bufferViews.append(["buffer": 0, "byteOffset": imgOffset, "byteLength": imgLen])
            nextBV += 1
            var textures: [[String: Any]] = [["sampler": 0, "source": 0]]
            var images: [[String: Any]] = [["bufferView": imgBV, "mimeType": "image/png"]]
            var pbr: [String: Any] = ["baseColorTexture": ["index": 0]]
            if hasMR {
                // glTF 2.0 pbrMetallicRoughness: the map's G channel is roughness,
                // B is metallic; factors are multipliers, so both stay 1.0.
                let mrBV = nextBV
                bufferViews.append(["buffer": 0, "byteOffset": mrOffset, "byteLength": mrLen])
                nextBV += 1
                images.append(["bufferView": mrBV, "mimeType": "image/png"])
                textures.append(["sampler": 0, "source": 1])
                pbr["metallicRoughnessTexture"] = ["index": 1]
                pbr["metallicFactor"] = 1.0
                pbr["roughnessFactor"] = 1.0
            } else {
                // RGB-only texture: matte fallback (no metals without an MR map).
                pbr["metallicFactor"] = 0.0
                pbr["roughnessFactor"] = 1.0
            }
            primitive["material"] = 0
            var materials: [[String: Any]] = [["name": "painted", "pbrMetallicRoughness": pbr]]

            if glassAccessor != nil {
                // Glass as its own material, so the body stays genuinely opaque (no whole-car
                // alpha blending or depth sorting) and the glass stays addressable by name
                // after USDZ conversion, which preserves assignments but can't split a
                // material afterwards.
                //
                // It samples the SAME texture index as the body — glTF allows that, so the
                // atlas is still embedded once — which keeps the alpha *per texel*: a
                // windscreen painted at 30% and side glass at 60% stay different, where a
                // single baseColorFactor would average them into one flat value. The body
                // ignores that alpha because OPAQUE discards it per spec. baseColorFactor
                // stays 1 and multiplies the texture, so the game can still fade the whole
                // material at runtime.
                // Opacity comes from the material when the mesh has been cut to the window
                // outline, and from the texture's own alpha otherwise. A cut mesh carries the
                // boundary in its geometry, so a per-texel alpha can only add a staircase back.
                let stored = mesh.sourceURL.flatMap { GlassClean.Opacity.load(forMesh: $0) }
                var glassPBR: [String: Any] = [
                    "metallicFactor": 0.0,
                    // Transparent *and* matte reads as plastic; glass wants low roughness.
                    "roughnessFactor": 0.05,
                ]
                if let stored {
                    // Cut glass is a flat colour and a single opacity, so it needs no texture at
                    // all — and sampling the atlas here reintroduced bodywork streaks along the
                    // window edge.
                    glassPBR["baseColorFactor"] = [Double(stored.r), Double(stored.g),
                                                   Double(stored.b), Double(stored.a)]
                } else {
                    glassPBR["baseColorTexture"] = ["index": 0]
                    glassPBR["baseColorFactor"] = [1.0, 1.0, 1.0, 1.0]
                    if hasMR { glassPBR["metallicRoughnessTexture"] = ["index": 1] }
                }
                // Single-sided by default, matching the live viewer (MeshViewer.swift):
                // double-sided glass draws the *back* face of every boundary triangle too, and
                // along the window's rim that back face faces away from the light and renders as
                // a dark, torn-looking patch — worse, and far more visible, than the occasional
                // hole a hollow shell shows single-sided from an unusual angle.
                // MODELR_GLASS_2SIDED=1 restores the old always-double-sided export.
                materials.append([
                    "name": "Glass",
                    "doubleSided": ProcessInfo.processInfo.environment["MODELR_GLASS_2SIDED"] == "1",
                    "alphaMode": "BLEND",
                    "pbrMetallicRoughness": glassPBR,
                ])
            } else if let png = mesh.texturePNG, Self.pngHasAlpha(png) {
                // Alpha present but nothing to split out — blend the single material instead.
                materials[0]["alphaMode"] = "BLEND"
                materials[0]["doubleSided"] = true
            }
            json["materials"] = materials
            json["textures"] = textures
            json["images"] = images
            // Mip filtering is wrong for a per-triangle atlas.
            //
            // With one small cell per triangle, every mip level past the first averages across
            // cell borders — a red cell bleeds into the black glass cell beside it and back —
            // and the whole car is drawn over with a lattice of its own texel grid. Such an
            // atlas has to be sampled without mips.
            let minFilter = ProcessInfo.processInfo.environment["MODELR_NO_MIPS"] == "1"
                ? 9729 : 9987
            json["samplers"] = [["magFilter": 9729, "minFilter": minFilter,
                                 "wrapS": 10497, "wrapT": 10497]]
        }

        json["accessors"] = accessors
        json["bufferViews"] = bufferViews
        var primitives = [primitive]
        if let ga = glassAccessor {
            var glassPrim: [String: Any] = ["attributes": attributes, "indices": ga]
            glassPrim["material"] = 1
            primitives.append(glassPrim)
        }
        json["meshes"] = [["primitives": primitives]]

        let jsonData = (try? JSONSerialization.data(withJSONObject: json, options: [])) ?? Data()
        var jsonChunk = jsonData
        while jsonChunk.count % 4 != 0 { jsonChunk.append(0x20) }   // pad with spaces

        var glb = Data()
        glb.reserveCapacity(12 + 8 + jsonChunk.count + 8 + bin.count)
        let total = 12 + 8 + jsonChunk.count + 8 + bin.count
        glb.appendLE(UInt32(0x4654_6C67))           // magic 'glTF'
        glb.appendLE(UInt32(2))                      // version
        glb.appendLE(UInt32(total))
        glb.appendLE(UInt32(jsonChunk.count)); glb.appendLE(UInt32(0x4E4F_534A)); glb.append(jsonChunk)  // 'JSON'
        glb.appendLE(UInt32(bin.count)); glb.appendLE(UInt32(0x004E_4942)); glb.append(bin)              // 'BIN\0'
        return glb
    }
}

private extension Data {
    mutating func appendLE(_ value: Float) {
        var x = value.bitPattern.littleEndian
        Swift.withUnsafeBytes(of: &x) { append(contentsOf: $0) }
    }
    mutating func appendLE(_ value: UInt32) {
        var x = value.littleEndian
        Swift.withUnsafeBytes(of: &x) { append(contentsOf: $0) }
    }
    mutating func appendLE(_ value: UInt16) {
        var x = value.littleEndian
        Swift.withUnsafeBytes(of: &x) { append(contentsOf: $0) }
    }
}
