import Foundation

/// `MODELR_REBAKE=<project|ALL>` — the plain "Re-bake from Sheets" menu action, headless.
/// Optionally `MODELR_REBAKE_GLB=<path>` or `MODELR_REBAKE_GLB_DIR=<dir>` to export a GLB
/// of the result afterwards, for comparing against other pipelines.
enum RebakeRunner {

    @MainActor static func runIfRequested(runtime: AppRuntime, store: ProjectStore) {
        guard let which = ProcessInfo.processInfo.environment["MODELR_REBAKE"] else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            let targets = store.projects.filter { which == "ALL" || $0.name == which }
            Task { @MainActor in
                for project in targets {
                    print("\(project.name): baking…")
                    runtime.requestRebake(project.id)
                    while runtime.rebakeStates[project.id] == .running {
                        try? await Task.sleep(nanoseconds: 500_000_000)
                    }
                    if case .failed(let m)? = runtime.rebakeStates[project.id] {
                        print("\(project.name): FAILED \(m)")
                        continue
                    }
                    print("\(project.name): rebake done")
                    guard let gen = project.generations.last(where: { $0.kind == .paint }),
                          let texName = gen.paintedTextureFileName else { continue }
                    var glbPath = ProcessInfo.processInfo.environment["MODELR_REBAKE_GLB"]
                    if let dirPath = ProcessInfo.processInfo.environment["MODELR_REBAKE_GLB_DIR"] {
                        let safe = project.name.replacingOccurrences(of: "/", with: "-")
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                        glbPath = URL(fileURLWithPath: dirPath)
                            .appendingPathComponent("\(safe.isEmpty ? "model" : safe).glb").path
                    }
                    guard let glbPath else { continue }
                    let dir = store.folder(for: project.id)
                    let mesh = dir.appendingPathComponent(gen.meshFileName)
                    let tex = dir.appendingPathComponent(texName)
                    let mr = gen.paintedMRFileName.map { dir.appendingPathComponent($0) }
                    do {
                        try MeshExporter.export(meshURL: mesh, texture: tex,
                                                metallicRoughness: mr, format: .glb,
                                                to: URL(fileURLWithPath: glbPath))
                        print("  exported -> \(glbPath)")
                    } catch { print("  export FAILED — \(error)") }
                }
                exit(0)
            }
        }
    }
}
