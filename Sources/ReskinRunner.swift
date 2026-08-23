import Foundation
import simd

/// `MODELR_RESKIN=<project>` — wrap a new skin, cut the windows out of it, write it beside the
/// original as `<stem>_reskin.tmesh` so it can be rendered and judged.
enum ReskinRunner {

    @MainActor static func runIfRequested(runtime: AppRuntime, store: ProjectStore) {
        guard let which = ProcessInfo.processInfo.environment["MODELR_RESKIN"] else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            for project in store.projects where which == "ALL" || project.name == which {
                run(project: project, store: store)
            }
            exit(0)
        }
    }

    /// int32 vertex count, int32 face count, then positions, normals, indices.
    static func saveMesh(vertices: [Float], normals: [Float], faces: [UInt32], to url: URL) {
        var d = Data()
        var n = Int32(vertices.count / 3), m = Int32(faces.count / 3)
        withUnsafeBytes(of: &n) { d.append(contentsOf: $0) }
        withUnsafeBytes(of: &m) { d.append(contentsOf: $0) }
        vertices.withUnsafeBufferPointer { d.append(contentsOf: UnsafeRawBufferPointer($0)) }
        normals.withUnsafeBufferPointer { d.append(contentsOf: UnsafeRawBufferPointer($0)) }
        faces.withUnsafeBufferPointer { d.append(contentsOf: UnsafeRawBufferPointer($0)) }
        try? d.write(to: url)
    }

    @MainActor static func run(project: Project, store: ProjectStore) {
        guard let gen = project.generations.last(where: { $0.kind == .paint }) else { return }
        let dir = store.folder(for: project.id)
        let mesh = dir.appendingPathComponent(gen.paintedMeshFileName ?? gen.meshFileName)
        let stem = (gen.paintedMeshFileName ?? gen.meshFileName)
            .replacingOccurrences(of: ".tmesh", with: "")
        guard let src = MeshCut.loadFull(mesh) else { print("FAIL no mesh"); return }

        // Re-extract the stencil from the user's sheet every run.
        //
        // The derived files are only ever a cache of someone's drawing, and that drawing changes
        // while work is in progress. Reusing yesterday's extraction means cutting to a stencil
        // that no longer exists — and the person looking at the result has no way to tell.
        let sheetURL = dir.appendingPathComponent("\(stem)_sheet_albedo.png")
        if FileManager.default.fileExists(atPath: sheetURL.path) {
            if let r = GlassSheet.prepare(sheet: sheetURL) {
                print(String(format: "  stencil re-read from your sheet: %.2f%% marked",
                             r.coverage * 100))
            }
        }

        let res = Int(ProcessInfo.processInfo.environment["MODELR_RESKIN_RES"] ?? "") ?? 512
        print("\(project.name): wrapping at \(res)…")
        guard let skinRaw = Reskin.wrap(vertices: src.vertices, faces: src.faces, resolution: res)
        else { print("FAIL wrap"); return }
        // Put the skin back on the original's scale before anything is projected.
        //
        // The wrap is built 1.2 cells *outside* the original surface, so it is slightly the
        // larger object. Everything downstream normalises a mesh by its own bounding sphere,
        // which silently shrinks the skin relative to the sheets — about a percent, which is a
        // few texels at this resolution. That is enough for a door handle sitting just below the
        // window to project just inside it, and be cut out as glass. Both side views agreed it
        // was four texels inside; they were reading a mesh that had drifted, not a drawing that
        // was wrong.
        var skin = skinRaw
        do {
            func sphere(_ v: [Float]) -> (SIMD3<Float>, Float) {
                var lo = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
                var hi = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
                for i in 0 ..< (v.count / 3) {
                    let p = SIMD3(v[i*3], v[i*3+1], v[i*3+2])
                    lo = simd_min(lo, p); hi = simd_max(hi, p)
                }
                let c = (lo + hi) / 2
                var r: Float = 0
                for i in 0 ..< (v.count / 3) {
                    r = max(r, simd_length(SIMD3(v[i*3], v[i*3+1], v[i*3+2]) - c))
                }
                return (c, r)
            }
            let (oc, orr) = sphere(src.vertices)
            let (sc, sr) = sphere(skin.vertices)
            let k = sr > 1e-9 ? orr / sr : 1
            for i in 0 ..< (skin.vertices.count / 3) {
                let px = skin.vertices[i*3], py = skin.vertices[i*3+1], pz = skin.vertices[i*3+2]
                let q = oc + (SIMD3(px, py, pz) - sc) * k
                skin.vertices[i*3] = q.x
                skin.vertices[i*3+1] = q.y
                skin.vertices[i*3+2] = q.z
            }
            print(String(format: "  rescaled skin to the original's sphere (x%.4f)", k))
        }
        print(String(format: "  skin: %d verts, %d faces (original %d / %d)",
                     skin.vertices.count / 3, skin.faces.count / 3,
                     src.vertices.count / 3, src.faces.count / 3))

        // Cut the windows out of the new skin, using the same painted stencil.
        var out = skin
        var glass = [Bool](repeating: false, count: skin.faces.count / 3)
        let uvs = [Float](repeating: 0, count: skin.vertices.count * 2 / 3)
        if let sheets = store.project(project.id).flatMap({ _ in
                dir.appendingPathComponent("\(stem)_sheet_albedo_glass.png") }),
           FileManager.default.fileExists(atPath: sheets.path),
           let field = SheetStencil.field(stencil: sheets, vertices: skin.vertices,
                                          normals: skin.normals, faces: skin.faces),
           let cut = MeshCut.cut(vertices: skin.vertices, normals: skin.normals, uvs: uvs,
                                 faces: skin.faces,
                                 inside: [Bool](repeating: false, count: skin.faces.count / 3),
                                 smoothing: 0, field: field, preserveArea: false) {
            out = Reskin.Mesh(vertices: cut.vertices, normals: cut.normals, faces: cut.faces)
            glass = cut.inside
            print("  cut: \(cut.faces.count / 3) faces, \(cut.inside.filter { $0 }.count) glass")
        } else {
            print("  no stencil — skin only")
        }

        // Which view claimed each isolated patch of glass, and what the stencil actually says
        // there. Guessing at this has been wrong twice; the projection can simply be asked.
        if ProcessInfo.processInfo.environment["MODELR_RESKIN_WHY"] == "1",
           let (tile, sdfs) = GlassSheet.viewFields(
               stencil: GlassSheet.stencilURL(forSheet: sheetURL)) {
            let fc = out.faces.count / 3
            var seen = [Bool](repeating: false, count: fc)
            var edgeFaces = [UInt64: [Int]]()
            for t in 0 ..< fc {
                let i = [out.faces[t*3], out.faces[t*3+1], out.faces[t*3+2]]
                for e in 0 ..< 3 {
                    let a = i[e], b = i[(e + 1) % 3]
                    edgeFaces[UInt64(min(a, b)) << 32 | UInt64(max(a, b)), default: []].append(t)
                }
            }
            var adj = [[Int]](repeating: [], count: fc)
            for (_, ts) in edgeFaces where ts.count == 2 {
                adj[ts[0]].append(ts[1]); adj[ts[1]].append(ts[0])
            }
            let pos = SheetStencil.normalised(out.vertices)
            let vn = SheetStencil.viewNormals(out.normals)
            for t in 0 ..< fc where glass[t] && !seen[t] {
                var stack = [t], members = [Int]()
                seen[t] = true
                while let x = stack.popLast() {
                    members.append(x)
                    for y in adj[x] where glass[y] && !seen[y] { seen[y] = true; stack.append(y) }
                }
                guard members.count < 400 else { continue }        // the windows themselves
                var c = SIMD3<Float>.zero, n = SIMD3<Float>.zero
                for m in members {
                    for k in 0 ..< 3 {
                        c += pos[Int(out.faces[m*3 + k])]
                        n += vn[Int(out.faces[m*3 + k])]
                    }
                }
                c /= Float(members.count * 3); n = simd_normalize(n)
                var line = String(format: "  patch %4d faces at (%.2f, %.2f, %.2f):",
                                  members.count, c.x, c.y, c.z)
                for v in SheetStencil.stencilViews where v < sdfs.count && !sdfs[v].isEmpty {
                    let (right, up, fwd, eye) = SheetStencil.basis(
                        elev: SheetStencil.elevs[v], azim: SheetStencil.azims[v], dist: 1.45)
                    let d = c - eye
                    let x = Int(((simd_dot(d, right) / 0.6 * 0.5 + 0.5) * Float(tile - 1)).rounded())
                    let y = Int(((simd_dot(d, up) / 0.6 * 0.5 + 0.5) * Float(tile - 1)).rounded())
                    let inside = x >= 0 && x < tile && y >= 0 && y < tile
                    let sdf = inside ? sdfs[v][y * tile + x] : -999
                    line += String(format: "  v%d[face %+.2f, sdf %+.0f @ px(%d,%d) of %d]", v,
                                   simd_dot(n, fwd), sdf, x, y, tile)
                }
                print(line)
            }
        }

        // Written outside the project folder: these are named off the painted mesh and carry
        // sweepable extensions, so the next launch's orphan sweep deletes them before anything
        // can look at them.
        let outDir = URL(fileURLWithPath: ProcessInfo.processInfo.environment["MODELR_RESKIN_OUT"]
                         ?? NSTemporaryDirectory())

        // Assemble: the original with its windows removed, plus our panes dropped in.
        if ProcessInfo.processInfo.environment["MODELR_PATCH"] == "1",
           FileManager.default.fileExists(atPath: sheetURL.path),
           let field = SheetStencil.field(stencil: GlassSheet.stencilURL(forSheet: sheetURL),
                                          vertices: src.vertices, normals: src.normals,
                                          faces: src.faces) {
            // Which of the ORIGINAL faces are window.
            var origGlass = [Bool](repeating: false, count: src.faces.count / 3)
            for f in 0 ..< origGlass.count {
                let a = field[Int(src.faces[f*3])], b = field[Int(src.faces[f*3+1])]
                let c = field[Int(src.faces[f*3+2])]
                origGlass[f] = (a + b + c) / 3 > 0
            }
            let diag = MeshEraser.meshDiagonal(vertices: src.vertices)
            if let r = GlassPatch.build(original: (src.vertices, src.normals, src.uvs, src.faces),
                                        panel: (out.vertices, out.normals, out.faces),
                                        panelGlass: glass, originalGlass: origGlass,
                                        inset: diag * 0.004) {
                print(String(format: "  patch: removed %d original faces, added %d pane faces, "
                                     + "%d boundary edges", r.apertureFaces, r.panelFaces, r.loops))
                _ = MeshCut.save(vertices: r.vertices, normals: r.normals, uvs: r.uvs,
                                 faces: r.faces, to: outDir.appendingPathComponent("patched.tmesh"))
                saveMesh(vertices: r.vertices, normals: r.normals, faces: r.faces,
                         to: outDir.appendingPathComponent("patched.mesh"))
                var bodyOnly = [UInt32]()
                for f in 0 ..< (r.faces.count / 3) where !r.glass[f] {
                    bodyOnly.append(r.faces[f*3]); bodyOnly.append(r.faces[f*3+1])
                    bodyOnly.append(r.faces[f*3+2])
                }
                saveMesh(vertices: r.vertices, normals: r.normals, faces: bodyOnly,
                         to: outDir.appendingPathComponent("patched_hole.mesh"))

                // Everything the exporter needs, beside the mesh: which faces are glass, and
                // what colour and opacity that glass is. The patch's UVs came from the original
                // surface, so the original atlas textures it unchanged.
                let patched = outDir.appendingPathComponent("patched.tmesh")
                GlassSelection(mask: r.glass).save(forMesh: patched)
                GlassClean.Opacity.save(colour: GlassClean.defaultTint,
                                        alpha: GlassClean.opacity, forMesh: patched)
                if let texName = gen.paintedTextureFileName {
                    let tex = dir.appendingPathComponent(texName)
                    let mr = gen.paintedMRFileName.map { dir.appendingPathComponent($0) }
                    let dest = URL(fileURLWithPath:
                        ProcessInfo.processInfo.environment["MODELR_PATCH_GLB"]
                        ?? outDir.appendingPathComponent("patched.glb").path)
                    do {
                        try MeshExporter.export(meshURL: patched, texture: tex,
                                                metallicRoughness: mr, format: .glb, to: dest)
                        let size = (try? FileManager.default
                            .attributesOfItem(atPath: dest.path)[.size]) as? Int ?? 0
                        print(String(format: "  exported %@ (%.1f MB)", dest.lastPathComponent,
                                     Double(size) / 1_048_576))
                    } catch {
                        print("  export FAILED — \(error)")
                    }
                }
            }
        }

        // Texture the re-wrapped car from the original's own atlas.
        //
        // The skin has no UVs of its own, but every vertex of it lies on the original surface —
        // so each one takes the UV of the closest point on that surface, and the existing paint
        // maps onto the new mesh unchanged. No re-bake, no re-projection from the sheets.
        // A directory means one GLB per car, named after it; a file means just this one.
        var glbPath = ProcessInfo.processInfo.environment["MODELR_RESKIN_GLB"]
        if let dirPath = ProcessInfo.processInfo.environment["MODELR_RESKIN_GLB_DIR"] {
            let safe = project.name.replacingOccurrences(of: "/", with: "-")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            glbPath = URL(fileURLWithPath: dirPath)
                .appendingPathComponent("\(safe.isEmpty ? "model" : safe).glb").path
        }
        if let glbPath, let texName = gen.paintedTextureFileName {
            let flat = GlassSheet.flatURL(forSheet: sheetURL)
            let flatSheet = flat
            let atlasSize = Int(ProcessInfo.processInfo.environment["MODELR_SKIN_ATLAS"] ?? "")
                ?? 8192

            // Chart-based UV unwrap: large connected charts with shared texels.
            // This is the default path when sheets exist — no shimmer, proper mip filtering.
            let useCharts = ProcessInfo.processInfo.environment["MODELR_SKIN_BAKE"] != "1"
            if useCharts, let texName = gen.paintedTextureFileName {
                print("  chart unwrap at \(atlasSize)px…")
                if let unwrapped = ChartUnwrap.unwrap(vertices: out.vertices, normals: out.normals,
                                                      faces: out.faces, atlas: atlasSize) {
                    print(String(format: "  %d charts, %d faces -> %d verts",
                                 unwrapped.charts, unwrapped.faces.count / 3,
                                 unwrapped.vertices.count / 3))
                    let atlasURL = outDir.appendingPathComponent("skin_chart_atlas.png")
                    let baked: URL? = SkinBake.bakeChartsFromOriginal(
                            vertices: unwrapped.vertices, normals: unwrapped.normals,
                            uvs: unwrapped.uvs, faces: unwrapped.faces,
                            original: (src.vertices, src.normals, src.uvs, src.faces),
                            originalTexture: dir.appendingPathComponent(texName),
                            atlas: atlasSize, to: atlasURL)
                    if let baked {
                        var cglass = [Bool](repeating: false, count: unwrapped.faces.count / 3)
                        for f in 0 ..< cglass.count {
                            let orig = unwrapped.parent[f]
                            if orig < glass.count { cglass[f] = glass[orig] }
                        }
                        let url = outDir.appendingPathComponent("skin_chart.tmesh")
                        _ = MeshCut.save(vertices: unwrapped.vertices, normals: unwrapped.normals,
                                         uvs: unwrapped.uvs, faces: unwrapped.faces, to: url)
                        GlassSelection(mask: cglass).save(forMesh: url)
                        GlassClean.Opacity.save(colour: GlassClean.defaultTint,
                                                alpha: GlassClean.opacity, forMesh: url)
                        do {
                            try MeshExporter.export(meshURL: url, texture: baked,
                                                    metallicRoughness: nil, format: .glb,
                                                    to: URL(fileURLWithPath: glbPath))
                            let size = (try? FileManager.default
                                .attributesOfItem(atPath: glbPath)[.size]) as? Int ?? 0
                            print(String(format: "  chart-baked %dx%d atlas, %d charts, "
                                                 + "exported %.1f MB -> %@",
                                         atlasSize, atlasSize, unwrapped.charts,
                                         Double(size) / 1_048_576, glbPath))
                        } catch { print("  chart export FAILED — \(error)") }
                        return
                    } else { print("  chart bake failed, falling through…") }
                } else { print("  chart unwrap failed (atlas too small?), falling through…") }
            }

            // Legacy per-triangle bake path (MODELR_SKIN_BAKE=1).
            let sheetTex = ProcessInfo.processInfo.environment["MODELR_SHEET_PAINT"] == "1"
                && FileManager.default.fileExists(atPath: flat.path)
                ? flat : dir.appendingPathComponent(texName)
            if ProcessInfo.processInfo.environment["MODELR_SKIN_BAKE"] == "1" {
                // Split vertices per face first: each triangle owns its own cell in the atlas,
                // so it cannot share a vertex — and therefore a UV — with its neighbours.
                var sv = [Float](), sn = [Float](), sf = [UInt32]()
                var sglass = [Bool]()
                for f in 0 ..< (out.faces.count / 3) {
                    for k in 0 ..< 3 {
                        let i = Int(out.faces[f*3 + k])
                        sv.append(out.vertices[i*3]); sv.append(out.vertices[i*3+1])
                        sv.append(out.vertices[i*3+2])
                        sn.append(out.normals[i*3]); sn.append(out.normals[i*3+1])
                        sn.append(out.normals[i*3+2])
                        sf.append(UInt32(sf.count))
                    }
                    sglass.append(f < glass.count && glass[f])
                }
                let atlasURL = outDir.appendingPathComponent("skin_atlas.png")
                let cellSize = Int(ProcessInfo.processInfo.environment["MODELR_SKIN_CELL"] ?? "")
                    ?? 8
                let fromSheets = ProcessInfo.processInfo.environment["MODELR_BAKE_SHEETS"] == "1"
                if fromSheets, FileManager.default.fileExists(atPath: flatSheet.path),
                   let baked = SkinBake.bakeFromSheets(vertices: sv, normals: sn, faces: sf,
                                                       sheet: flatSheet, to: atlasURL,
                                                       atlas: atlasSize, cell: cellSize) {
                    let url = outDir.appendingPathComponent("skin_baked.tmesh")
                    _ = MeshCut.save(vertices: sv, normals: sn, uvs: baked.uvs, faces: sf, to: url)
                    GlassSelection(mask: sglass).save(forMesh: url)
                    GlassClean.Opacity.save(colour: GlassClean.defaultTint,
                                            alpha: GlassClean.opacity, forMesh: url)
                    do {
                        try MeshExporter.export(meshURL: url, texture: baked.texture,
                                                metallicRoughness: nil, format: .glb,
                                                to: URL(fileURLWithPath: glbPath))
                        let size = (try? FileManager.default
                            .attributesOfItem(atPath: glbPath)[.size]) as? Int ?? 0
                        print(String(format: "  baked from sheets: %dx%d atlas (%d px/tri), "
                                             + "%.1f MB -> %@", baked.size, baked.size,
                                     baked.cell * baked.cell, Double(size) / 1_048_576, glbPath))
                    } catch { print("  export FAILED — \(error)") }
                    return
                }
                if let baked = SkinBake.bake(vertices: sv, faces: sf,
                                             original: (src.vertices, src.normals, src.uvs, src.faces),
                                             originalTexture: dir.appendingPathComponent(texName),
                                             to: atlasURL, atlas: atlasSize, cell: cellSize) {
                    let url = outDir.appendingPathComponent("skin_baked.tmesh")
                    _ = MeshCut.save(vertices: sv, normals: sn, uvs: baked.uvs, faces: sf, to: url)
                    GlassSelection(mask: sglass).save(forMesh: url)
                    GlassClean.Opacity.save(colour: GlassClean.defaultTint,
                                            alpha: GlassClean.opacity, forMesh: url)
                    do {
                        try MeshExporter.export(meshURL: url, texture: baked.texture,
                                                metallicRoughness: nil, format: .glb,
                                                to: URL(fileURLWithPath: glbPath))
                        let size = (try? FileManager.default
                            .attributesOfItem(atPath: glbPath)[.size]) as? Int ?? 0
                        print(String(format: "  baked %dx%d atlas (%d px per triangle), "
                                             + "exported %.1f MB -> %@",
                                     baked.size, baked.size, baked.cell * baked.cell,
                                     Double(size) / 1_048_576, glbPath))
                    } catch { print("  export FAILED — \(error)") }
                } else {
                    print("  skin bake FAILED (too many faces for the atlas?)")
                }
                return
            }

            let r = ProcessInfo.processInfo.environment["MODELR_SHEET_PAINT"] == "1"
                ? Reskin.sheetUVs(vertices: out.vertices, normals: out.normals,
                                  faces: out.faces, tiles: 6)
                : { let t = GlassPatch.retexture(vertices: out.vertices, normals: out.normals,
                                                 faces: out.faces,
                                                 from: (src.vertices, src.normals, src.uvs,
                                                        src.faces))
                    return (t.vertices, t.normals, t.uvs, t.faces, t.remap) }()
            var splitGlass = [Bool](repeating: false, count: r.faces.count / 3)
            for f in 0 ..< splitGlass.count where f < glass.count { splitGlass[f] = glass[f] }
            let skinURL = outDir.appendingPathComponent("reskin_textured.tmesh")
            _ = MeshCut.save(vertices: r.vertices, normals: r.normals, uvs: r.uvs,
                             faces: r.faces, to: skinURL)
            GlassSelection(mask: splitGlass).save(forMesh: skinURL)
            GlassClean.Opacity.save(colour: GlassClean.defaultTint, alpha: GlassClean.opacity,
                                    forMesh: skinURL)
            do {
                let mr = ProcessInfo.processInfo.environment["MODELR_SHEET_PAINT"] == "1"
                    ? nil : gen.paintedMRFileName.map { dir.appendingPathComponent($0) }
                try MeshExporter.export(meshURL: skinURL, texture: sheetTex,
                                        metallicRoughness: mr,
                                        format: .glb, to: URL(fileURLWithPath: glbPath))
                let size = (try? FileManager.default
                    .attributesOfItem(atPath: glbPath)[.size]) as? Int ?? 0
                print(String(format: "  textured skin exported (%.1f MB) -> %@",
                             Double(size) / 1_048_576, glbPath))
            } catch {
                print("  skin export FAILED — \(error)")
            }
        }

        // Two files: the skin with the window still in it, and the skin with the window removed,
        // so the hole's edge can be looked at directly with nothing drawn over it.
        let uv2 = [Float](repeating: 0, count: out.vertices.count * 2 / 3)
        _ = MeshCut.save(vertices: out.vertices, normals: out.normals, uvs: uv2,
                         faces: out.faces, to: outDir.appendingPathComponent("reskin.tmesh"))
        var holed = [UInt32]()
        for f in 0 ..< (out.faces.count / 3) where !(f < glass.count && glass[f]) {
            holed.append(out.faces[f*3]); holed.append(out.faces[f*3+1]); holed.append(out.faces[f*3+2])
        }
        _ = MeshCut.save(vertices: out.vertices, normals: out.normals, uvs: uv2,
                         faces: holed, to: outDir.appendingPathComponent("reskin_hole.tmesh"))
        // Also in the viewer's plain mesh format, so the hole can be rendered untextured with
        // nothing drawn over the edge under examination.
        saveMesh(vertices: out.vertices, normals: out.normals, faces: holed,
                 to: outDir.appendingPathComponent("reskin_hole.mesh"))
        saveMesh(vertices: out.vertices, normals: out.normals, faces: out.faces,
                 to: outDir.appendingPathComponent("reskin.mesh"))
        print("  wrote reskin{,_hole}.{tmesh,mesh} in \(outDir.path)")
    }
}
