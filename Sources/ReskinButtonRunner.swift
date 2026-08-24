import Foundation

/// `MODELR_RESKIN_BUTTON=<project|ALL>` — the actual "Reskin and Generate Windows from
/// Alpha" menu action (`reskinAndExport`), headless. Unlike `MODELR_RESKIN` (ReskinRunner,
/// a separate standalone implementation kept for quick bake experiments), this exercises the
/// real production code path. Optionally `MODELR_RESKIN_BUTTON_GLB=<path>` or
/// `MODELR_RESKIN_BUTTON_GLB_DIR=<dir>` to export the result as a GLB afterwards.
enum ReskinButtonRunner {

    @MainActor static func runIfRequested(runtime: AppRuntime, store: ProjectStore) {
        guard let which = ProcessInfo.processInfo.environment["MODELR_RESKIN_BUTTON"] else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            let targets = store.projects.filter { which == "ALL" || $0.name == which }
            Task { @MainActor in
                for project in targets {
                    print("\(project.name): reskinning…")
                    guard let gen = project.generations.last(where: { $0.kind == .paint }) else {
                        print("\(project.name): no painted generation"); continue
                    }
                    let dir = store.folder(for: project.id)
                    let stem = (gen.paintedMeshFileName ?? gen.meshFileName)
                        .replacingOccurrences(of: ".tmesh", with: "")
                    let reskinTex = dir.appendingPathComponent("\(stem)_reskin_texture.png")
                    try? FileManager.default.removeItem(at: reskinTex)

                    runtime.reskinAndExport(project.id)
                    // No single flag covers the whole pipeline (rebake, then reskin) — poll for
                    // the one artifact that only exists once both stages finish.
                    var waited = 0.0
                    while !FileManager.default.fileExists(atPath: reskinTex.path), waited < 300 {
                        try? await Task.sleep(nanoseconds: 500_000_000)
                        waited += 0.5
                    }
                    guard FileManager.default.fileExists(atPath: reskinTex.path) else {
                        print("\(project.name): TIMED OUT waiting for reskin output"); continue
                    }
                    print("\(project.name): reskin done")

                    var glbPath = ProcessInfo.processInfo.environment["MODELR_RESKIN_BUTTON_GLB"]
                    if let dirPath = ProcessInfo.processInfo.environment["MODELR_RESKIN_BUTTON_GLB_DIR"] {
                        let safe = project.name.replacingOccurrences(of: "/", with: "-")
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                        glbPath = URL(fileURLWithPath: dirPath)
                            .appendingPathComponent("\(safe.isEmpty ? "model" : safe).glb").path
                    }
                    guard let glbPath else { continue }
                    let reskinMesh = dir.appendingPathComponent("\(stem)_reskin.tmesh")
                    do {
                        try MeshExporter.export(meshURL: reskinMesh, texture: reskinTex,
                                                metallicRoughness: nil, format: .glb,
                                                to: URL(fileURLWithPath: glbPath))
                        print("  exported -> \(glbPath)")
                    } catch { print("  export FAILED — \(error)") }
                }
                exit(0)
            }
        }
    }
}
