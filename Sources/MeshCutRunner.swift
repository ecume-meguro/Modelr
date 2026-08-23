import Foundation

/// Applies the boundary cut to a project's painted mesh, headlessly.
///
/// `MODELR_MESH_CUT=<project name|ALL>`, optional `MODELR_CUT_SMOOTH=<passes>`.
/// Reports the boundary's perimeter before and after: a staircase boundary is measurably longer
/// than the smooth curve through the same region, so the number says whether it worked without
/// anyone having to look at it.
enum MeshCutRunner {

    /// `MODELR_STENCIL_CHECK=<project|ALL>` — does the sheet projection line up with the sheets?
    @MainActor static func checkIfRequested(store: ProjectStore) {
        guard let which = ProcessInfo.processInfo.environment["MODELR_STENCIL_CHECK"] else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            for project in store.projects where which == "ALL" || project.name == which {
                guard let gen = project.generations.last(where: { $0.kind == .paint }) else { continue }
                let dir = store.folder(for: project.id)
                let mesh = dir.appendingPathComponent(gen.paintedMeshFileName ?? gen.meshFileName)
                let stem = (gen.paintedMeshFileName ?? gen.meshFileName)
                    .replacingOccurrences(of: ".tmesh", with: "")
                let sheet = dir.appendingPathComponent("\(stem)_sheet_albedo.png")
                guard let full = MeshCut.loadFull(mesh),
                      FileManager.default.fileExists(atPath: sheet.path) else { continue }
                if ProcessInfo.processInfo.environment["MODELR_STENCIL_SEARCH"] == "1" {
                    let best = SheetStencil.search(sheet: sheet, vertices: full.vertices,
                                                   faces: full.faces).prefix(4)
                    for (c, iou) in best {
                        print(String(format: "  %@: axes %d elev %+.0f azim %+.0f flipX %@ flipY %@ -> IoU %.3f",
                                     project.name, c.axes, c.elevSign, c.azimOffset,
                                     c.flipX ? "y" : "n", c.flipY ? "y" : "n", iou))
                    }
                } else {
                    let r = SheetStencil.silhouetteAgreement(sheet: sheet, vertices: full.vertices,
                                                             faces: full.faces)
                    let text = r.map { String(format: "v%d %.2f", $0.view, $0.iou) }
                        .joined(separator: "  ")
                    print("\(project.name): \(text)")
                }
            }
            exit(0)
        }
    }

    @MainActor static func runIfRequested(store: ProjectStore) {
        guard let which = ProcessInfo.processInfo.environment["MODELR_MESH_CUT"] else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            let passes = Int(ProcessInfo.processInfo.environment["MODELR_CUT_SMOOTH"] ?? "") ?? 12
            run(store: store, which: which, smoothing: passes)
            exit(0)
        }
    }

    @MainActor static func run(store: ProjectStore, which: String, smoothing: Int) {
        for project in store.projects where which == "ALL" || project.name == which {
            guard let gen = project.generations.last(where: { $0.kind == .paint }),
                  let texName = gen.paintedTextureFileName else { continue }
            let dir = store.folder(for: project.id)
            let mesh = dir.appendingPathComponent(gen.paintedMeshFileName ?? gen.meshFileName)
            let tex = dir.appendingPathComponent(texName)
            guard let full = MeshCut.loadFull(mesh) else {
                print("FAIL  \(project.name) — cannot read \(mesh.lastPathComponent)"); continue
            }
            var mask = GlassSelection.load(forMesh: mesh)?.mask
            if mask == nil {
                mask = GlassSelection.autoSelect(vertices: full.vertices, faces: full.faces,
                                                 texture: tex, uvs: full.uvs).mask
            }
            guard let mask, mask.contains(true) else {
                print("skip  \(project.name) — no glass selected"); continue
            }
            let before = perimeter(vertices: full.vertices, faces: full.faces, inside: mask)
            // Alpha is the finer description of the same boundary, so prefer it when the atlas
            // has one; the face selection is the fallback.
            let useAlpha = ProcessInfo.processInfo.environment["MODELR_CUT_SOURCE"] != "selection"
            var field: [Float]?
            if useAlpha {
                let cutLevel = MeshCut.alphaCut(texture: tex)
                field = MeshCut.alphaField(texture: tex, vertices: full.vertices,
                                           uvs: full.uvs, faces: full.faces, cut: cutLevel)
                print(String(format: "      %@: alpha cut %.2f", project.name, cutLevel))
            }
            guard let cut = MeshCut.cut(vertices: full.vertices, normals: full.normals,
                                        uvs: full.uvs, faces: full.faces, inside: mask,
                                        smoothing: smoothing,
                                        field: field, preserveArea: true) else {
                print("FAIL  \(project.name) — cut failed"); continue
            }
            let after = perimeter(vertices: cut.vertices, faces: cut.faces, inside: cut.inside)

            let backup = mesh.deletingPathExtension().appendingPathExtension("precut.tmesh")
            if !FileManager.default.fileExists(atPath: backup.path) {
                try? FileManager.default.copyItem(at: mesh, to: backup)
            }
            guard MeshCut.save(vertices: cut.vertices, normals: cut.normals, uvs: cut.uvs,
                               faces: cut.faces, to: mesh) else {
                print("FAIL  \(project.name) — cannot write mesh"); continue
            }
            GlassSelection(mask: cut.inside).save(forMesh: mesh)
            if let old = MeshEraser.load(forMesh: mesh)?.deleted {
                var remapped = [Bool](repeating: false, count: cut.parent.count)
                for i in 0 ..< cut.parent.count where cut.parent[i] < old.count {
                    remapped[i] = old[cut.parent[i]]
                }
                MeshEraser(deleted: remapped).save(forMesh: mesh)
            }
            print(String(format: "ok    %@: %d -> %d faces, glass %d, perimeter %.3f -> %.3f (%.0f%% shorter)",
                         project.name, full.faces.count / 3, cut.faces.count / 3,
                         cut.inside.lazy.filter { $0 }.count, before, after,
                         before > 0 ? (1 - after / before) * 100 : 0))
        }
    }

    /// Total length of the edges separating inside from outside.
    private static func perimeter(vertices: [Float], faces: [UInt32], inside: [Bool]) -> Double {
        var edgeSide = [UInt64: (Bool, Bool)]()
        let welded = MeshCut.weldMap(vertices: vertices)
        for f in 0 ..< (faces.count / 3) where f < inside.count {
            let v = [welded[Int(faces[f*3])], welded[Int(faces[f*3+1])], welded[Int(faces[f*3+2])]]
            for e in 0 ..< 3 {
                let a = v[e], b = v[(e + 1) % 3]
                let key = a < b ? UInt64(a) << 32 | UInt64(b) : UInt64(b) << 32 | UInt64(a)
                var s = edgeSide[key] ?? (false, false)
                if inside[f] { s.0 = true } else { s.1 = true }
                edgeSide[key] = s
            }
        }
        var total = 0.0
        for (key, s) in edgeSide where s.0 && s.1 {
            let a = Int(key >> 32), b = Int(key & 0xFFFFFFFF)
            let dx = Double(vertices[a*3] - vertices[b*3])
            let dy = Double(vertices[a*3+1] - vertices[b*3+1])
            let dz = Double(vertices[a*3+2] - vertices[b*3+2])
            total += (dx*dx + dy*dy + dz*dz).squareRoot()
        }
        return total
    }
}
