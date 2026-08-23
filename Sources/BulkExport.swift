import Foundation
import AppKit

/// Exports every painted generation as a GLB, headlessly.
///
/// The app's own export goes through a save panel one file at a time, which is no use for
/// exporting a whole library. This walks the store, picks each project's current painted
/// generation, and writes `<project name>.glb` through the same `MeshExporter` the UI uses.
///
/// `MODELR_EXPORT_ALL=<output directory>`. The directory must be somewhere the app can write —
/// macOS gates Desktop and Documents behind a TCC prompt this app never asks for, so writes there
/// fail silently. Export somewhere neutral and move the files afterwards.
enum BulkExport {

    @MainActor static func runIfRequested(store: ProjectStore) {
        guard let out = ProcessInfo.processInfo.environment["MODELR_EXPORT_ALL"] else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            run(store: store, outDir: URL(fileURLWithPath: out))
            exit(0)
        }
    }

    @MainActor static func run(store: ProjectStore, outDir: URL) {
        try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        var ok = 0, failed = 0, skipped = 0

        for project in store.projects {
            let painted = project.generations.last { $0.kind == .paint }
            guard let gen = painted, let texName = gen.paintedTextureFileName else {
                skipped += 1
                print("skip     \(project.name) — no painted generation")
                continue
            }
            let dir = store.folder(for: project.id)
            let mesh = dir.appendingPathComponent(gen.meshFileName)
            let tex = dir.appendingPathComponent(texName)
            let mr = gen.paintedMRFileName.map { dir.appendingPathComponent($0) }
            guard FileManager.default.fileExists(atPath: mesh.path),
                  FileManager.default.fileExists(atPath: tex.path) else {
                failed += 1
                print("FAIL     \(project.name) — missing mesh or texture")
                continue
            }
            let safe = project.name
                .replacingOccurrences(of: "/", with: "-")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let dest = outDir.appendingPathComponent("\(safe.isEmpty ? "model" : safe).glb")
            do {
                try MeshExporter.export(meshURL: mesh, texture: tex,
                                        metallicRoughness: mr, format: .glb, to: dest)
                let size = (try? FileManager.default.attributesOfItem(atPath: dest.path)[.size])
                    as? Int ?? 0
                ok += 1
                print(String(format: "exported %@  (%.1f MB)", project.name,
                             Double(size) / 1_048_576))
            } catch {
                failed += 1
                print("FAIL     \(project.name) — \(error)")
            }
        }
        print("EXPORTED \(ok), failed \(failed), skipped \(skipped) -> \(outDir.path)")
    }
}
