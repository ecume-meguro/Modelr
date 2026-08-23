import Foundation
import AppKit

/// Runs the glass clean over the library headlessly, so the result can be looked at without
/// clicking through the editor once per car.
///
/// `MODELR_GLASS_CLEAN=<project name|ALL>` and optionally `MODELR_GLASS_OUT=<dir>` to write a
/// GLB of each cleaned car. Writes go somewhere neutral, not the Desktop, which macOS gates.
enum GlassCleanRunner {

    /// `MODELR_GLASS_FINISH=<project|ALL>` runs the cut and the clean together on an atlas that
    /// already has its alpha — the same sequence the menu's Finish Glass does.
    @MainActor static func finishIfRequested(runtime: AppRuntime, store: ProjectStore) {
        guard let which = ProcessInfo.processInfo.environment["MODELR_GLASS_FINISH"] else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            for project in store.projects where which == "ALL" || project.name == which {
                let note = runtime.finishGlass(project.id) ?? "nothing to do"
                print("\(project.name): \(note)")
            }
            exit(0)
        }
    }

    /// `MODELR_REBAKE_FINISH=<project|ALL>` — split the sheet, re-bake from it, cut, clean.
    @MainActor static func rebakeFinishIfRequested(runtime: AppRuntime, store: ProjectStore) {
        guard let which = ProcessInfo.processInfo.environment["MODELR_REBAKE_FINISH"] else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            let targets = store.projects.filter { which == "ALL" || $0.name == which }
            Task { @MainActor in
                for project in targets {
                    print("\(project.name): baking…")
                    runtime.requestRebakeAndFinish(project.id)
                    // The bake reports through rebakeStates; wait for it rather than guessing.
                    while runtime.rebakeStates[project.id] == .running {
                        try? await Task.sleep(nanoseconds: 500_000_000)
                    }
                    if case .failed(let m)? = runtime.rebakeStates[project.id] {
                        print("\(project.name): FAILED \(m)")
                    } else {
                        print("\(project.name): \(runtime.lastFinishNote[project.id] as? String ?? "done")")
                    }
                }
                exit(0)
            }
        }
    }

    @MainActor static func runIfRequested(store: ProjectStore) {
        guard let which = ProcessInfo.processInfo.environment["MODELR_GLASS_CLEAN"] else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            run(store: store, which: which)
            exit(0)
        }
    }

    @MainActor static func run(store: ProjectStore, which: String) {
        for project in store.projects where which == "ALL" || project.name == which {
            guard let gen = project.generations.last(where: { $0.kind == .paint }),
                  let texName = gen.paintedTextureFileName else {
                print("skip  \(project.name) — no painted generation"); continue
            }
            let dir = store.folder(for: project.id)
            let mesh = dir.appendingPathComponent(gen.paintedMeshFileName ?? gen.meshFileName)
            let tex = dir.appendingPathComponent(texName)
            let mr = gen.paintedMRFileName.map { dir.appendingPathComponent($0) }
            guard FileManager.default.fileExists(atPath: mesh.path) else {
                print("FAIL  \(project.name) — no mesh at \(mesh.lastPathComponent)"); continue
            }
            var mask = GlassSelection.load(forMesh: mesh)?.mask
            if mask == nil, let g = PoseSnap.loadTMeshWithUVs(mesh) {
                mask = GlassSelection.autoSelect(vertices: g.vertices, faces: g.faces,
                                                 texture: tex, uvs: g.uvs).mask
                print("      \(project.name): auto-selected \(mask?.lazy.filter { $0 }.count ?? 0) glass faces")
            }
            guard let mask, mask.contains(true) else {
                print("skip  \(project.name) — no glass found"); continue
            }
            var tint: SIMD3<UInt8>?
            if let t = ProcessInfo.processInfo.environment["MODELR_GLASS_TINT"] {
                let p = t.split(separator: ",").compactMap { UInt8($0.trimmingCharacters(in: .whitespaces)) }
                if p.count == 3 { tint = SIMD3(p[0], p[1], p[2]) }
            }
            if let r = GlassClean.clean(mesh: mesh, texture: tex, mr: mr, glass: mask, tint: tint) {
                print("ok    \(project.name): \(r.texels) texels -> rgb "
                      + "(\(r.colour.x), \(r.colour.y), \(r.colour.z))")
            } else {
                print("FAIL  \(project.name) — clean failed")
            }
        }
        if let out = ProcessInfo.processInfo.environment["MODELR_GLASS_OUT"] {
            BulkExport.run(store: store, outDir: URL(fileURLWithPath: out))
        }
    }
}
