import AppKit
import Foundation

/// Headless one-shot: arbitrary input image -> exported 3D file, for driving Modelr as a
/// generation backend (e.g. an HTTP `/model3d` endpoint) rather than interactively.
///
/// Modeled on `SmokeRunner`'s real walk (import -> generate -> paint -> export) minus the
/// onboarding/weight-import machinery and screenshot capture, which only make sense for a
/// human-in-the-loop smoke test. This assumes the needed model weights are already installed;
/// it fails fast rather than downloading, since a network caller shouldn't block on a multi-GB
/// fetch it didn't ask for.
///
/// Always runs the large shape model + the 2.1 PBR paint pipeline (albedo + metallic-roughness)
/// — the small/RGB pair isn't offered here, this entrypoint is for the quality tier callers
/// actually want.
///
/// Environment:
///   MODELR_INPUT=<path>    source image (required)
///   MODELR_OUTPUT=<path>   destination file; extension picks the format unless MODELR_FORMAT
///                          is set (required)
///   MODELR_FORMAT=glb|usdz|obj|stl|ply   overrides the extension-derived format
///   MODELR_QUALITY=fastest|fast|balanced|high|max   shape+paint quality (default: the app's
///                          own default preset, currently "fast"). "fastest" has no paint
///                          equivalent and maps to paint's "fast".
///   MODELR_REMOVE_BG=0     skip background removal (on by default, same as a fresh project)
///   MODELR_WINDOWED=1      keep the normal Dock icon/window instead of running as an
///                          accessory (background) app with no Dock presence
///   MODELR_KEEP_PROJECT=1   skip deleting the scratch project after the run (debugging)
///
/// Exit 0 on success (after printing the destination path), exit 1 on any failure (message on
/// stderr) — a network wrapper should treat nonzero as "return 500", not "run again".
///
/// Progress is printed as `stage <n>/3 <name>[: detail]` on stdout, one line per state change,
/// flushed immediately — parseable the same way a tqdm bar would be.
@MainActor
enum Model3DRunner {
    private static let env = ProcessInfo.processInfo.environment

    static var isRequested: Bool { env["MODELR_INPUT"] != nil || env["MODELR_OUTPUT"] != nil }

    static func runIfRequested(runtime: AppRuntime) {
        guard isRequested else { return }
        // A network endpoint invokes this per-request; a Dock icon grabbing focus (or even
        // bouncing) every time some other machine asks for a model is not something the person
        // sitting at this Mac should have to see. No Dock tile, no menu bar, windows never key.
        if env["MODELR_WINDOWED"] != "1" {
            NSApp.setActivationPolicy(.accessory)
        }
        Task { @MainActor in
            let started = Date()
            do {
                let dest = try await run(runtime: runtime)
                let elapsed = Date().timeIntervalSince(started)
                log("stage 3/3 done: \(dest.path) (\(String(format: "%.1f", elapsed))s total)")
                print(dest.path)
                exit(0)
            } catch {
                FileHandle.standardError.write(Data("[model3d] FAIL: \(error.localizedDescription)\n".utf8))
                exit(1)
            }
        }
    }

    private struct RunError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }
    private static func fail(_ message: String) -> RunError { RunError(message: message) }

    private static func log(_ message: String) {
        print("[model3d] \(message)")
        fflush(stdout)
    }

    private static func run(runtime: AppRuntime) async throws -> URL {
        guard let inputPath = env["MODELR_INPUT"], !inputPath.isEmpty else {
            throw fail("MODELR_INPUT is required")
        }
        guard let outputPath = env["MODELR_OUTPUT"], !outputPath.isEmpty else {
            throw fail("MODELR_OUTPUT is required")
        }
        let dest = URL(fileURLWithPath: outputPath)
        let ext = (env["MODELR_FORMAT"] ?? dest.pathExtension).lowercased()
        guard let format = MeshExportFormat(rawValue: ext) else {
            throw fail("unrecognised format '\(ext)' (want one of: \(MeshExportFormat.allCases.map(\.rawValue).joined(separator: ", ")))")
        }
        let shapeModel: ShapeModel = .large
        let paintModel: PaintModel = .large
        var shapeQuality: QualityPreset?
        var paintQuality: PaintQuality?
        if let raw = env["MODELR_QUALITY"] {
            guard let q = QualityPreset(rawValue: raw) else {
                throw fail("MODELR_QUALITY must be one of: \(QualityPreset.ordered.map(\.rawValue).joined(separator: ", ")) (got \(raw))")
            }
            shapeQuality = q
            // PaintQuality has no "fastest" tier; every other name matches QualityPreset's.
            paintQuality = raw == QualityPreset.fastest.rawValue ? .fast : PaintQuality(rawValue: raw)
        }

        try await waitUntil("boot", 30) {
            runtime.state.phase == .onboarding || runtime.state.phase == .ready
        }
        guard runtime.state.phase != .onboarding else {
            throw fail("no models installed — run the app interactively once to install \(shapeModel.modelID.rawValue)/\(paintModel.modelID.rawValue) first")
        }
        for model in [shapeModel.modelID, paintModel.modelID]
            where !runtime.state.installState(model).isInstalled {
            throw fail("\(model.rawValue) is not installed")
        }

        let store = runtime.store
        let project = store.newProject()
        store.rename(project.id, to: "model3d-\(project.id.uuidString.prefix(8))")
        var cleanedUp = false
        func cleanup() {
            guard !cleanedUp, env["MODELR_KEEP_PROJECT"] != "1" else { return }
            cleanedUp = true
            store.delete(project.id)
        }

        do {
            store.setShapeModel(shapeModel, for: project.id)
            store.setPaintModel(paintModel, for: project.id)
            if let shapeQuality { store.setQuality(shapeQuality, for: project.id) }
            if let paintQuality { store.setPaintQuality(paintQuality, for: project.id) }
            if env["MODELR_REMOVE_BG"] == "0" { store.setRemoveBackground(false, for: project.id) }
            store.setImage(fromURL: URL(fileURLWithPath: inputPath), for: project.id)
            if let importError = store.importErrors[project.id] {
                throw fail("image import failed: \(importError)")
            }
            guard store.project(project.id)?.inputImageName != nil else {
                throw fail("image import produced no input.png — check MODELR_INPUT is a readable image")
            }

            // 1. Shape.
            log("stage 1/3 shape: starting")
            runtime.requestGenerate(project.id)
            var lastShapeLine = ""
            try await waitUntil("shape run", 1800) {
                let state = runtime.state.shapeState(project.id)
                if case .failed(let stage, let message) = state {
                    lastFailure = "shape failed at \(stage): \(message)"
                    return true
                }
                let line = "stage 1/3 shape: \(describeJobState(state))"
                if line != lastShapeLine { log(line); lastShapeLine = line }
                return state == .idle && store.project(project.id)?.currentGeneration?.kind == .shape
            }
            if let failure = lastFailure { throw fail(failure) }
            guard let shapeGen = store.project(project.id)?.currentGeneration, shapeGen.kind == .shape else {
                throw fail("no shape generation was committed")
            }
            log("stage 1/3 shape: committed in \(String(format: "%.1f", shapeGen.durationSeconds ?? -1))s")

            // 2. Paint.
            log("stage 2/3 paint: starting")
            runtime.requestPaint(project.id)
            var lastPaintLine = ""
            try await waitUntil("paint run", 3600) {
                let state = runtime.state.paintState(project.id)
                if case .failed(let stage, let message) = state {
                    lastFailure = "paint failed at \(stage): \(message)"
                    return true
                }
                let line = "stage 2/3 paint: \(describeJobState(state))"
                if line != lastPaintLine { log(line); lastPaintLine = line }
                return state == .idle && store.project(project.id)?.currentGeneration?.kind == .paint
            }
            if let failure = lastFailure { throw fail(failure) }
            guard let paintGen = store.project(project.id)?.currentGeneration, paintGen.kind == .paint else {
                throw fail("no paint generation was committed")
            }
            log("stage 2/3 paint: committed in \(String(format: "%.1f", paintGen.durationSeconds ?? -1))s")
            // The commit flips paintState to .idle a beat before its own trailing writes (stream
            // file cleanup, project index save) land — SmokeRunner settles the same way after a
            // commit. Exporting or deleting the project before that lands raced once and left an
            // orphaned index entry with no folder behind it.
            await settle()

            // 3. Export.
            log("stage 3/3 export: \(format.rawValue)")
            guard let projectNow = store.project(project.id),
                  let content = store.currentViewerContent(for: projectNow) else {
                throw fail("no viewer content to export")
            }
            try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(),
                                                     withIntermediateDirectories: true)
            switch content {
            case .pbrMesh(let mesh, let albedo, let mr):
                try MeshExporter.export(meshURL: mesh, texture: albedo, metallicRoughness: mr,
                                        format: format, to: dest)
            case .texturedMesh(let mesh, let tex):
                try MeshExporter.export(meshURL: mesh, texture: tex, format: format, to: dest)
            case .mesh, .points, .coverageMesh:
                throw fail("viewer content is untextured after paint — expected a textured mesh")
            }
            let bytes = (try? dest.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            guard bytes > 8 else { throw fail("exported file is empty") }

            cleanup()
            return dest
        } catch {
            cleanup()
            throw error
        }
    }

    private static func describeJobState(_ state: ShapeJobState) -> String {
        switch state {
        case .denoising(let k, let n): return n > 0 ? "denoising \(k)/\(n)" : "denoising"
        case .failed(let stage, let message): return "failed at \(stage): \(message)"
        default: return String(describing: state)
        }
    }
    private static func describeJobState(_ state: PaintJobState) -> String {
        switch state {
        case .denoising(let k, let n): return n > 0 ? "denoising \(k)/\(n)" : "denoising"
        case .failed(let stage, let message): return "failed at \(stage): \(message)"
        default: return String(describing: state)
        }
    }

    private static var lastFailure: String?

    /// Give the reducer a couple of runloop turns after a commit so any trailing async work
    /// (stream-file cleanup, the project index save) actually lands before we act on it.
    private static func settle() async {
        for _ in 0..<3 { try? await Task.sleep(nanoseconds: 150_000_000) }
    }

    private static func waitUntil(_ what: String, _ timeout: TimeInterval,
                                  _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else { throw fail("timed out waiting for \(what) (\(Int(timeout))s)") }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
    }
}
