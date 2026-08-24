import Foundation
import simd
import Observation
import AppKit
import HunyuanPaintMLX

/// The impure shell around the pure core: owns AppState, feeds every event
/// through AppReducer, and executes the returned effects against the real world
/// (ProjectStore files, DownloadManager network, EngineArbiter + engines).
/// Views observe this object; all UI intents come through `dispatch` or the
/// convenience methods below.
@MainActor
@Observable
final class AppRuntime {
    private(set) var state = AppState()
    let store: ProjectStore

    /// Latest streamed preview mesh per project (shape denoise). Transient view
    /// data, token-guarded against stale engine callbacks.
    private(set) var shapePreviews: [Project.ID: URL] = [:]
    /// Latest streamed multiview grid per project (paint denoise).
    private(set) var paintViewPreviews: [Project.ID: URL] = [:]
    /// Bumped when generation is requested without weights — the UI routes to
    /// Settings → Models (§4.9 weightsMissing: never a bare error).
    private(set) var modelManagerSignal = 0

    /// What the most recent run per project was configured with (recorded at staging,
    /// kept after failure) — feeds the failure-details popover (§4.9 engineFailed).
    struct RunDetails: Equatable {
        var model: String
        var seed: UInt64?
    }
    private(set) var lastShapeRunDetails: [Project.ID: RunDetails] = [:]
    private(set) var lastPaintRunDetails: [Project.ID: RunDetails] = [:]

    @ObservationIgnored private let shapeEngine = ShapeEngine()
    @ObservationIgnored private let paintEngine = PaintEngine()
    @ObservationIgnored private let arbiter: EngineArbiter
    @ObservationIgnored private var downloads: DownloadManager!
    @ObservationIgnored private let bridge = EventBridge()

    @ObservationIgnored private var stagedShapes: [Project.ID: (token: UInt64, run: ProjectStore.StagedShapeRun)] = [:]
    @ObservationIgnored private var stagedPaints: [Project.ID: (token: UInt64, run: ProjectStore.StagedPaintRun)] = [:]
    @ObservationIgnored private var engineRuns: [JobKey: any CancellableRun] = [:]

    @ObservationIgnored private var eventQueue: [AppEvent] = []
    @ObservationIgnored private var draining = false
    @ObservationIgnored private var booted = false

    private static let onboardingKey = "onboardingComplete"
    private static let intentsKey = "installIntents"

    init(store: ProjectStore? = nil) {
        self.store = store ?? ProjectStore()
        let shape = shapeEngine
        let paint = paintEngine
        arbiter = EngineArbiter(evictors: [
            .shape: { await shape.evictAndWait() },
            .paint: { await paint.evictAndWait() },
        ])
        downloads = DownloadManager(
            configuration: .init(rootDir: ModelStore.modelsRoot),
            emit: { [bridge] event in bridge.send(event) })
        bridge.runtime = self
    }

    /// Forwards events from background subsystems onto the main actor without
    /// retaining the runtime before it finishes initializing.
    final class EventBridge: @unchecked Sendable {
        weak var runtime: AppRuntime?
        func send(_ event: AppEvent) {
            Task { @MainActor in self.runtime?.dispatch(event) }
        }
    }

    // MARK: - boot (§4.1)

    func bootIfNeeded() {
        guard !booted else { return }
        booted = true
        let downloads = downloads!
        Task.detached(priority: .userInitiated) { [bridge] in
            let legacy = ModelStore.legacyLayoutExists
            let report = Self.scanBootReport(downloads: downloads)
            bridge.send(.bootScanned(legacyLayoutDetected: legacy, report: report))
        }
    }

    private nonisolated static func scanBootReport(downloads: DownloadManager) -> BootReport {
        var report = BootReport()
        report.onboardingComplete = UserDefaults.standard.bool(forKey: onboardingKey)
        let intents = Set((UserDefaults.standard.stringArray(forKey: intentsKey) ?? [])
            .compactMap(ModelID.init(rawValue:)))
        for model in ModelID.allCases {
            if downloads.isInstalledOnDisk(model) {
                report.installed.insert(model)
            } else if intents.contains(model) || downloads.hasPartialData(for: model) {
                report.resumable[model] = downloads.resumableBytes(for: model)
            }
        }
        return report
    }

    // MARK: - dispatch loop

    /// FIFO event processing: effects may synchronously produce follow-up events
    /// (e.g. staging), which queue behind the current reduction instead of
    /// recursing — keeps ordering deterministic.
    func dispatch(_ event: AppEvent) {
        eventQueue.append(event)
        guard !draining else { return }
        draining = true
        while !eventQueue.isEmpty {
            let next = eventQueue.removeFirst()
            let effects = AppReducer.reduce(&state, next)
            for effect in effects { perform(effect) }
        }
        draining = false
    }

    // MARK: - UI conveniences

    func requestGenerate(_ id: Project.ID) {
        guard let project = store.project(id) else { return }
        dispatch(.shapeGenerateRequested(project: id, model: project.resolvedSettings.model.modelID))
    }

    func requestPaint(_ id: Project.ID) {
        guard let project = store.project(id) else { return }
        dispatch(.paintRequested(project: id, model: project.resolvedPaintSettings.model.modelID))
    }

    // MARK: - Re-bake from edited view sheets

    enum RebakeState: Equatable { case idle, running, failed(String) }

    /// Re-bake status per project. Deliberately outside the reducer: a bake loads no model
    /// weights and takes seconds, so it needs neither the arbiter nor a cancellable job.
    private(set) var rebakeStates: [Project.ID: RebakeState] = [:]
    /// Bumped after a successful re-bake. The viewer keys off this to reload textures that
    /// were overwritten in place (the file URLs don't change, so SwiftUI can't see it).
    var rebakeTick = 0

    /// The editable view sheets for the selected paint generation, if it was produced by a
    /// build that persists them. Nil for Color runs and for anything painted before that.
    func sheetURLs(for id: Project.ID) -> (albedo: URL, mr: URL, unbaked: URL)? {
        guard let project = store.project(id),
              let gen = project.currentGeneration, gen.kind == .paint else { return nil }
        let dir = store.folder(for: id)
        let stem = (gen.meshFileName as NSString).deletingPathExtension
        let a = dir.appendingPathComponent("\(stem)_sheet_albedo.png")
        let m = dir.appendingPathComponent("\(stem)_sheet_mr.png")
        let u = dir.appendingPathComponent("\(stem)_unbaked.tmesh")
        let fm = FileManager.default
        guard [a, m, u].allSatisfy({ fm.fileExists(atPath: $0.path) }) else { return nil }
        return (a, m, u)
    }

    /// Re-project the (possibly hand-edited) sheets onto the atlas, overwriting this
    /// generation's textures in place. `weights` overrides the per-view blend weights —
    /// the defaults weight top and bottom at 0.05 against the reference view's 1.0.
    /// Reference images registered against the selected generation.
    /// Atlas showing which surfaces a reference may paint (magenta = nothing head-on yet).
    /// Written by the bake; absent until a generation has been baked by a build that emits it.
    func coverageTextureURL(_ id: Project.ID) -> URL? {
        guard let gen = store.project(id)?.currentGeneration,
              let texName = gen.paintedTextureFileName else { return nil }
        let u = store.folder(for: id).appendingPathComponent(
            (texName as NSString).deletingPathExtension + "_coverage.png")
        return FileManager.default.fileExists(atPath: u.path) ? u : nil
    }

    /// Photographs to condition the multiview shape model on: the project's own input first,
    /// then any reference views the user has aligned, which are already photographs of the same
    /// object from other angles. Capped at the four views the checkpoint was trained with.
    func multiviewImageURLs(_ id: Project.ID) -> [URL] {
        guard let project = store.project(id) else { return [] }
        var urls = [URL]()
        // The four explicit slots come first and in order: the model reads slot 1 as "90 degrees
        // round from slot 0", so order is meaning, not convenience.
        for slot in 0 ..< 4 {
            if let u = store.multiviewImageURL(id, slot: slot) { urls.append(u) }
        }
        if !urls.isEmpty { return Array(urls.prefix(4)) }
        if let input = store.imageURL(for: project) { urls.append(input) }
        let dir = store.folder(for: id)
        for v in referenceViews(for: id) {
            let original = v.originalFileName.map { dir.appendingPathComponent($0) }
            let candidate = original.flatMap {
                FileManager.default.fileExists(atPath: $0.path) ? $0 : nil
            } ?? dir.appendingPathComponent(v.fileName)
            if FileManager.default.fileExists(atPath: candidate.path) { urls.append(candidate) }
        }
        return Array(urls.prefix(4))
    }

    func referenceViews(for id: Project.ID) -> [ReferenceView] {
        store.project(id)?.currentGeneration?.referenceViewsRaw ?? []
    }

    /// `scale`/`offset` are the fit the user dialled in while aligning, in units of the square
    /// viewport. They are baked into the stored image rather than kept alongside it: the bake's
    /// camera is fixed (orthoScale 1.2 at a fixed distance, mesh normalised to a set size), so
    /// the model always fills the same fraction of frame. A photograph frames the subject
    /// however the photographer chose, and orbiting only fixes rotation — without matching
    /// scale and position too, the view projects its pixels onto the wrong geometry.
    func addReferenceView(_ id: Project.ID, imageURL: URL, elev: Double, azim: Double,
                          scale: Double = 1, offset: CGSize = .zero, roll: Double = 0,
                          fovDeg: Double = 0, replacing existing: UUID? = nil) {
        guard let project = store.project(id), let gen = project.currentGeneration else { return }
        let dir = store.folder(for: id)
        let name = "ref_\(UUID().uuidString).png"
        let originalName = "reforig_\(UUID().uuidString).png"
        // Copy into the project so the reference survives the original being moved or deleted,
        // and letterbox it square: the bake's camera is an orthographic square, and its
        // rasteriser takes a single edge length, so a non-square view cannot be projected.
        guard let img = NSImage(contentsOf: imageURL),
              let square = Self.squared(img, scale: scale, offset: offset, roll: roll),
              let tiff = square.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: dir.appendingPathComponent(name))
        // Keep the import untouched so the fit stays editable; the baked square is what the
        // bake reads, but it cannot be un-fitted once written.
        if let odata = try? Data(contentsOf: imageURL),
           let orep = NSBitmapImageRep(data: odata) ?? NSImage(data: odata).flatMap({
               $0.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)) }),
           let opng = orep.representation(using: .png, properties: [:]) {
            try? opng.write(to: dir.appendingPathComponent(originalName))
        }
        var views = gen.referenceViewsRaw ?? []
        let entry = ReferenceView(fileName: name, originalFileName: originalName,
                                  elev: elev, azim: azim,
                                  weight: existing.flatMap { eid in
                                      views.first { $0.id == eid }?.weight } ?? 0.5,
                                  scale: scale,
                                  offsetX: Double(offset.width), offsetY: Double(offset.height),
                                  roll: roll, fovDeg: fovDeg)
        if let eid = existing, let i = views.firstIndex(where: { $0.id == eid }) {
            // Replace in place so the list order and weight survive an edit.
            for f in [views[i].fileName, views[i].originalFileName].compactMap({ $0 }) {
                try? FileManager.default.removeItem(at: dir.appendingPathComponent(f))
            }
            var e = entry; e.id = eid
            views[i] = e
        } else {
            views.append(entry)
        }
        store.setReferenceViews(views, for: id)
        rebakeTick += 1
    }

    /// Letterbox onto a square canvas, centred, on the neutral grey the view sheets use — so
    /// the padding reads as background rather than as surface if it ever gets sampled.
    private static func squared(_ img: NSImage, scale: Double, offset: CGSize,
                                roll: Double = 0) -> NSImage? {
        let w = img.size.width, h = img.size.height
        guard w > 0, h > 0 else { return nil }
        let side = max(w, h)
        let out = NSImage(size: NSSize(width: side, height: side))
        out.lockFocus()
        NSColor(calibratedWhite: 0.502, alpha: 1).setFill()
        NSRect(x: 0, y: 0, width: side, height: side).fill()
        // Reproduce the aligner exactly: aspect-fit into the square, then the user's scale
        // about the centre, then their drag. Offsets arrive in viewport fractions; y is
        // flipped because AppKit draws bottom-up while the viewport is top-down.
        let fit = min(side / w, side / h) * scale
        let dw = w * fit, dh = h * fit
        let x = (side - dw) / 2 + offset.width * side
        let y = (side - dh) / 2 - offset.height * side
        if roll != 0, let ctx = NSGraphicsContext.current {
            // Rotate about the drawn image's own centre, matching the aligner's rotationEffect.
            ctx.saveGraphicsState()
            let t = NSAffineTransform()
            t.translateX(by: x + dw / 2, yBy: y + dh / 2)
            t.rotate(byDegrees: CGFloat(-roll))
            t.translateX(by: -(x + dw / 2), yBy: -(y + dh / 2))
            t.concat()
            img.draw(in: NSRect(x: x, y: y, width: dw, height: dh))
            ctx.restoreGraphicsState()
        } else {
            img.draw(in: NSRect(x: x, y: y, width: dw, height: dh))
        }
        out.unlockFocus()
        return out
    }

    func removeReferenceView(_ id: Project.ID, viewID: UUID) {
        var views = referenceViews(for: id)
        views.removeAll { $0.id == viewID }
        store.setReferenceViews(views, for: id)
        rebakeTick += 1
    }

    func setReferenceWeight(_ id: Project.ID, viewID: UUID, weight: Double) {
        var views = referenceViews(for: id)
        guard let i = views.firstIndex(where: { $0.id == viewID }) else { return }
        views[i].weight = weight
        store.setReferenceViews(views, for: id)
    }

    /// The painted atlas as the diffusion model left it, before any re-bake overwrote it.
    /// Nil until the first re-bake takes the snapshot.
    func originalPaintURLs(_ id: Project.ID) -> (texture: URL, mr: URL)? {
        guard let gen = store.project(id)?.currentGeneration,
              let texName = gen.paintedTextureFileName, let mrName = gen.paintedMRFileName
        else { return nil }
        let dir = store.folder(for: id)
        let t = dir.appendingPathComponent(Self.origName(texName))
        let m = dir.appendingPathComponent(Self.origName(mrName))
        let fm = FileManager.default
        guard fm.fileExists(atPath: t.path), fm.fileExists(atPath: m.path) else { return nil }
        return (t, m)
    }

    private static func origName(_ name: String) -> String {
        let ns = name as NSString
        return "\(ns.deletingPathExtension)_orig.\(ns.pathExtension.isEmpty ? "png" : ns.pathExtension)"
    }

    /// Put the original paint back. References and their alignments are left alone, so the next
    /// re-bake reapplies them — this undoes the bake, not the setup.
    func resetToOriginalPaint(_ id: Project.ID) {
        guard rebakeStates[id] != .running,
              let orig = originalPaintURLs(id),
              let gen = store.project(id)?.currentGeneration,
              let texName = gen.paintedTextureFileName, let mrName = gen.paintedMRFileName
        else { return }
        let dir = store.folder(for: id)
        let fm = FileManager.default
        for (src, dst) in [(orig.texture, dir.appendingPathComponent(texName)),
                           (orig.mr, dir.appendingPathComponent(mrName))] {
            try? fm.removeItem(at: dst)
            try? fm.copyItem(at: src, to: dst)
        }
        rebakeTick += 1
    }

    /// Re-bake, then cut the glass and clean it — the whole finishing sequence, in the order it
    /// has to happen.
    ///
    /// The order is not a preference. The bake writes the mesh back from the uncut original and
    /// puts its own per-texel alpha in the atlas; the cut needs that alpha as its stencil; and
    /// the clean destroys the alpha once the boundary has been moved into the geometry. Done by
    /// hand, one wrong order silently produces a car with either ragged windows or none.
    func requestRebakeAndFinish(_ id: Project.ID, weights: [Float]? = nil) {
        // Split the sheet before baking: keep the person's alpha as the stencil, and hand the
        // bake a sheet with the windows filled flat dark and nothing transparent left in it. A
        // bake that cannot see through a window cannot paint a seat onto one.
        if let sheets = sheetURLs(for: id) {
            if let r = GlassSheet.prepare(sheet: sheets.albedo) {
                finishAfterRebake.insert(id)
                requestRebake(id, weights: weights, albedoOverride: r.flat)
                return
            }
            lastFinishNote[id] = "the sheet has no alpha — nothing marked as glass"
        }
        finishAfterRebake.insert(id)
        requestRebake(id, weights: weights)
    }

    private(set) var reskinStates: [Project.ID: RebakeState] = [:]

    private var reskinAfterRebake: Set<Project.ID> = []

    func reskinAndExport(_ id: Project.ID) {
        guard reskinStates[id] != .running else { return }
        guard let project = store.project(id),
              let gen = project.generations.last(where: { $0.kind == .paint }) else { return }
        let dir = store.folder(for: id)
        let meshFile = gen.paintedMeshFileName ?? gen.meshFileName
        let stem = meshFile.replacingOccurrences(of: ".tmesh", with: "")
        let fm = FileManager.default
        for ext in ["_reskin.tmesh", "_reskin_texture.png", "_reskin_glass.bin", "_reskin_glass.opacity"] {
            try? fm.removeItem(at: dir.appendingPathComponent(stem + ext))
        }
        rebakeTick += 1
        guard let sheets = sheetURLs(for: id) else {
            reskinStates[id] = .idle
            return
        }
        if let r = GlassSheet.prepare(sheet: sheets.albedo) {
            reskinAfterRebake.insert(id)
            requestRebake(id, albedoOverride: r.flat)
        } else {
            reskinAfterRebake.insert(id)
            requestRebake(id)
        }
    }

    func continueReskin(_ id: Project.ID) {
        guard let project = store.project(id),
              let gen = project.generations.last(where: { $0.kind == .paint }),
              let texName = gen.paintedTextureFileName else {
            reskinStates[id] = .idle
            return
        }
        let dir = store.folder(for: id)
        let meshFile = gen.paintedMeshFileName ?? gen.meshFileName
        let meshURL = dir.appendingPathComponent(meshFile)
        let stem = meshFile.replacingOccurrences(of: ".tmesh", with: "")
        let sheetURL = dir.appendingPathComponent("\(stem)_sheet_albedo.png")
        let origTex = dir.appendingPathComponent(texName)
        let reskinMesh = dir.appendingPathComponent("\(stem)_reskin.tmesh")
        let reskinTex = dir.appendingPathComponent("\(stem)_reskin_texture.png")
        Task.detached {
            let result = Self.runReskin(meshURL: meshURL, sheetURL: sheetURL,
                                       origTex: origTex)
            await MainActor.run { [weak self] in
                guard let self else { return }
                if let (mesh, tex) = result {
                    let fm = FileManager.default
                    try? fm.removeItem(at: reskinMesh)
                    try? fm.copyItem(at: mesh, to: reskinMesh)
                    try? fm.removeItem(at: reskinTex)
                    try? fm.copyItem(at: tex, to: reskinTex)
                    let srcGlass = GlassSelection.url(forMesh: mesh)
                    let dstGlass = GlassSelection.url(forMesh: reskinMesh)
                    try? fm.removeItem(at: dstGlass)
                    try? fm.copyItem(at: srcGlass, to: dstGlass)
                    let srcOpacity = GlassClean.Opacity.url(forMesh: mesh)
                    let dstOpacity = GlassClean.Opacity.url(forMesh: reskinMesh)
                    try? fm.removeItem(at: dstOpacity)
                    try? fm.copyItem(at: srcOpacity, to: dstOpacity)
                }
                self.reskinStates[id] = .idle
                self.rebakeTick += 1
            }
        }
    }

    private nonisolated static func runReskin(meshURL: URL, sheetURL: URL,
                                              origTex: URL) -> (mesh: URL, texture: URL)? {
        let fm = FileManager.default
        let debugDir = meshURL.deletingLastPathComponent()
            .appendingPathComponent("reskin_debug", isDirectory: true)
        try? fm.removeItem(at: debugDir)
        try? fm.createDirectory(at: debugDir, withIntermediateDirectories: true)
        func debugCopy(_ src: URL, as name: String) {
            try? fm.copyItem(at: src, to: debugDir.appendingPathComponent(name))
        }
        func debugLog(_ msg: String) {
            let line = "\(msg)\n"
            let logURL = debugDir.appendingPathComponent("log.txt")
            if let h = try? FileHandle(forWritingTo: logURL) {
                h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close()
            } else {
                try? Data(line.utf8).write(to: logURL)
            }
            print("[reskin] \(msg)")
        }

        debugLog("meshURL: \(meshURL.path)")
        debugLog("sheetURL: \(sheetURL.path)")
        debugLog("origTex: \(origTex.path)")
        debugCopy(meshURL, as: "01_input_mesh.tmesh")
        debugCopy(origTex, as: "02_input_texture.png")
        debugCopy(sheetURL, as: "03_input_sheet.png")

        guard let src = MeshCut.loadFull(meshURL) else {
            debugLog("FAIL: could not load mesh")
            return nil
        }
        debugLog("src mesh: \(src.vertices.count/3) verts, \(src.faces.count/3) faces, \(src.uvs.count/2) uvs")

        if fm.fileExists(atPath: sheetURL.path) {
            _ = GlassSheet.prepare(sheet: sheetURL)
        }
        let stencilPath = GlassSheet.stencilURL(forSheet: sheetURL)
        debugLog("stencil: \(stencilPath.path) exists=\(fm.fileExists(atPath: stencilPath.path))")
        if fm.fileExists(atPath: stencilPath.path) {
            debugCopy(stencilPath, as: "04_stencil.png")
        }

        let res = 512
        guard let skinRaw = Reskin.wrap(vertices: src.vertices, faces: src.faces,
                                        resolution: res) else {
            debugLog("FAIL: wrap failed")
            return nil
        }
        debugLog("wrap: \(skinRaw.vertices.count/3) verts, \(skinRaw.faces.count/3) faces")
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
            debugLog("rescale: orig center=\(oc) r=\(orr), skin center=\(sc) r=\(sr), k=\(k)")
            for i in 0 ..< (skin.vertices.count / 3) {
                let q = oc + (SIMD3(skin.vertices[i*3], skin.vertices[i*3+1],
                                    skin.vertices[i*3+2]) - sc) * k
                skin.vertices[i*3] = q.x; skin.vertices[i*3+1] = q.y; skin.vertices[i*3+2] = q.z
            }
        }

        var out = skin
        var glass = [Bool](repeating: false, count: skin.faces.count / 3)
        let uvs = [Float](repeating: 0, count: skin.vertices.count * 2 / 3)
        if fm.fileExists(atPath: stencilPath.path),
           let field = SheetStencil.field(stencil: stencilPath, vertices: skin.vertices,
                                          normals: skin.normals, faces: skin.faces),
           let cut = MeshCut.cut(vertices: skin.vertices, normals: skin.normals, uvs: uvs,
                                 faces: skin.faces,
                                 inside: [Bool](repeating: false, count: skin.faces.count / 3),
                                 smoothing: 0, field: field, preserveArea: false) {
            out = Reskin.Mesh(vertices: cut.vertices, normals: cut.normals, faces: cut.faces)
            glass = cut.inside
            let nGlass = glass.filter { $0 }.count
            debugLog("glass cut: \(cut.vertices.count/3) verts, \(cut.faces.count/3) faces, \(nGlass) glass faces")
        } else {
            debugLog("glass cut: SKIPPED (no stencil or field failed)")
        }

        let atlasSize = 8192
        guard let unwrapped = ChartUnwrap.unwrap(vertices: out.vertices, normals: out.normals,
                                                  faces: out.faces, atlas: atlasSize) else {
            debugLog("FAIL: chart unwrap failed")
            return nil
        }
        debugLog("chart unwrap: \(unwrapped.vertices.count/3) verts, \(unwrapped.faces.count/3) faces, \(unwrapped.charts) charts")

        let tmp = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        let atlasURL = tmp.appendingPathComponent("atlas.png")

        debugCopy(origTex, as: "04b_original_atlas_for_reference.png")
        debugLog("baking from the sheet directly onto the wrapper mesh's own chart UVs")
        // All six views, unlike this function's other caller: a reskin's chart atlas covers
        // the whole body, including the roof and rear deck, which the front/side/rear/bottom
        // ring cannot see face-on at all (their cameras are all near-horizontal). Sorting
        // picks the most face-on view regardless of list order, so adding the top view back
        // only wins on genuinely up-facing texels — it does not reintroduce the window-border
        // speckle the ring-only default exists to avoid.
        guard let baked = SkinBake.bakeChartsFromSheetOwner(
            vertices: unwrapped.vertices, normals: unwrapped.normals,
            uvs: unwrapped.uvs, faces: unwrapped.faces,
            sheet: sheetURL, atlas: atlasSize, to: atlasURL, views: [0, 1, 2, 3, 4, 5]) else {
            debugLog("FAIL: bakeChartsFromSheetOwner failed")
            return nil
        }
        debugLog("baked atlas: \(baked.path)")
        debugCopy(baked, as: "05_baked_atlas.png")

        var cglass = [Bool](repeating: false, count: unwrapped.faces.count / 3)
        for f in 0 ..< cglass.count {
            let orig = unwrapped.parent[f]
            if orig < glass.count { cglass[f] = glass[orig] }
        }
        let nCGlass = cglass.filter { $0 }.count
        debugLog("chart glass: \(nCGlass) of \(cglass.count) faces")

        let outMesh = tmp.appendingPathComponent("reskin.tmesh")
        _ = MeshCut.save(vertices: unwrapped.vertices, normals: unwrapped.normals,
                         uvs: unwrapped.uvs, faces: unwrapped.faces, to: outMesh)
        GlassSelection(mask: cglass).save(forMesh: outMesh)
        GlassClean.Opacity.save(colour: GlassClean.defaultTint,
                                alpha: GlassClean.opacity, forMesh: outMesh)
        debugCopy(outMesh, as: "06_reskin_mesh.tmesh")
        debugCopy(GlassSelection.url(forMesh: outMesh), as: "07_glass_selection.bin")

        debugLog("DONE")
        return (outMesh, baked)
    }

    /// Projects whose re-bake should be followed by the cut and the clean.
    private var finishAfterRebake: Set<Project.ID> = []

    /// Cut the glass to the painted alpha, then flatten it. Safe to call on its own.
    @discardableResult
    func finishGlass(_ id: Project.ID) -> String? {
        guard let project = store.project(id),
              let gen = project.currentGeneration,
              let texName = gen.paintedTextureFileName else { return nil }
        let dir = store.folder(for: id)
        let mesh = dir.appendingPathComponent(gen.paintedMeshFileName ?? gen.meshFileName)
        let tex = dir.appendingPathComponent(texName)
        let mr = gen.paintedMRFileName.map { dir.appendingPathComponent($0) }
        // Always cut the *uncut* mesh.
        //
        // Finishing twice otherwise cuts a cut mesh: the second pass adds another ring of
        // vertices along a boundary that was already exact, and the face count creeps up with
        // every run (124k -> 131k on one car) for no gain. Restoring first makes the operation
        // idempotent — run it as often as you like and the answer is the same.
        let precut = MeshCut.backupURL(forMesh: mesh)
        if FileManager.default.fileExists(atPath: precut.path) {
            try? FileManager.default.removeItem(at: mesh)
            try? FileManager.default.copyItem(at: precut, to: mesh)
            try? FileManager.default.removeItem(at: precut)
            GlassSelection.clear(forMesh: mesh)
            MeshEraser.clear(forMesh: mesh)
            try? FileManager.default.removeItem(at: derivedMarker(mesh))
        }
        guard let full = MeshCut.loadFull(mesh) else { return "no mesh to cut" }

        // A selection made by hand wins outright. Where the paint's stencil is a torn blob —
        // and on some cars it is — clicking the windows is the only thing that gets a clean
        // answer, and it must not be thrown away by re-deriving from alpha.
        // A hand selection wins — but only a real one. The previous run's own output is stored
        // the same way, and treating that as a hand selection meant every subsequent finish
        // re-used the last answer and silently ignored the sheets, which is precisely the
        // complaint that "it did not use my sheet". A marker file tells them apart.
        if !FileManager.default.fileExists(atPath: derivedMarker(mesh).path),
           let hand = GlassSelection.load(forMesh: mesh)?.mask,
           hand.count == full.faces.count / 3, hand.contains(true) {
            guard let cut = MeshCut.cut(vertices: full.vertices, normals: full.normals,
                                        uvs: full.uvs, faces: full.faces, inside: hand,
                                        smoothing: 12), cut.inside.contains(true) else {
                return "could not cut to the stored selection"
            }
            return applyCut(cut, mesh: mesh, texture: tex, mr: mr, note: "hand selection")
        }

        // First choice: the stencil in the sheets, before the atlas speckles it.
        //
        // The projection into the bake's six views is verified rather than assumed — see
        // `SheetStencil.silhouetteAgreement`, which scores this orientation at 0.96 against the
        // sheets themselves. Set MODELR_SHEET_STENCIL=0 to fall back to the atlas.
        // Cut along the painted curve itself: trace the stencil's contour in 2D at sub-texel
        // precision and split each triangle where that curve crosses it. The boundary is then a
        // property of the drawing, not of the mesh, which is the one thing every previous
        // attempt got wrong.
        // Off by default. The curve tracing and the cut itself are right; what is not right is
        // deciding which faces the curve is entitled to cut, and shipping it on would hand back
        // a car with a sixth of its surface turned to glass.
        if ProcessInfo.processInfo.environment["MODELR_CLIP"] == "1",
           let sheets = sheetURLs(for: id),
           let (tile, sdfs) = GlassSheet.viewFields(
               stencil: GlassSheet.stencilURL(forSheet: sheets.albedo)) {
            var v = full.vertices, nm = full.normals, uv = full.uvs, f = full.faces
            var glass = [Bool](repeating: false, count: f.count / 3)
            // Which faces the curve itself decided. They are the trustworthy ones and nothing
            // downstream may overrule them.
            var decidedByCut = [Bool](repeating: false, count: f.count / 3)
            var onCurve = [Bool](repeating: false, count: v.count / 3)
            for view in SheetStencil.stencilViews where view < sdfs.count {
                guard !sdfs[view].isEmpty else { continue }
                let contours = MeshClip.trace(sdfs[view], w: tile, h: tile)
                guard !contours.isEmpty else { continue }
                let index = MeshClip.Index(contours)
                let (right, up, fwd, eye) = SheetStencil.basis(elev: SheetStencil.elevs[view],
                                                               azim: SheetStencil.azims[view],
                                                               dist: 1.45)
                // Refine, conformingly, anywhere the curve does something a single split cannot
                // express, until the cut only ever meets the simple case.
                for _ in 0 ..< 3 {
                    let complex = MeshClip.complexFaces(vertices: v, faces: f,
                                                        right: right, up: up, eye: eye,
                                                        tile: tile, index: index,
                                                        position: SheetStencil.normalised(v))
                    guard complex.contains(true) else { break }
                    let ref = MeshCut.refine(vertices: v, normals: nm, uvs: uv, faces: f,
                                             band: complex, onCurve: onCurve)
                    var carried = [Bool](repeating: false, count: ref.faces.count / 3)
                    var carriedCut = carried
                    for i in 0 ..< carried.count where ref.parent[i] < glass.count {
                        carried[i] = glass[ref.parent[i]]
                        carriedCut[i] = decidedByCut[ref.parent[i]]
                    }
                    v = ref.vertices; nm = ref.normals; uv = ref.uvs; f = ref.faces
                    glass = carried; decidedByCut = carriedCut; onCurve = ref.onCurve
                }
                let r = MeshClip.cut(vertices: v, normals: nm, uvs: uv, faces: f,
                                     right: right, up: up, fwd: fwd, eye: eye,
                                     tile: tile, index: index, sdf: sdfs[view],
                                     position: SheetStencil.normalised(v),
                                     facing: SheetStencil.viewNormals(nm))
                var next = [Bool](repeating: false, count: r.faces.count / 3)
                var nextCut = next
                for i in 0 ..< next.count {
                    next[i] = r.inside[i] || (r.parent[i] < glass.count && glass[r.parent[i]])
                    nextCut[i] = r.inside[i]
                        || (r.parent[i] < decidedByCut.count && decidedByCut[r.parent[i]])
                }
                v = r.vertices; nm = r.normals; uv = r.uvs; f = r.faces
                glass = next; decidedByCut = nextCut
                // Curve marks accumulate across views: a window cut from one view must not be
                // filled back in by growth that started somewhere else.
                var merged = r.onCurve
                for i in 0 ..< min(onCurve.count, merged.count) where onCurve[i] { merged[i] = true }
                onCurve = merged
            }

            // Grow the glass outward from the cut, never crossing it.
            //
            // The faces the curve actually split are the only ones whose classification can be
            // trusted — they were decided at the boundary, where the stencil is unambiguous.
            // Everything else inherits its answer by being reachable from one of them without
            // stepping over the curve. A window is then exactly the patch the curve encloses,
            // and no amount of geometry standing behind that window in some view can join it.
            do {
                var edgeFaces = [UInt64: [Int]]()
                let count = f.count / 3
                edgeFaces.reserveCapacity(count * 3)
                for t in 0 ..< count {
                    let idx = [f[t*3], f[t*3+1], f[t*3+2]]
                    for e in 0 ..< 3 {
                        let a = idx[e], b = idx[(e + 1) % 3]
                        let key = UInt64(min(a, b)) << 32 | UInt64(max(a, b))
                        edgeFaces[key, default: []].append(t)
                    }
                }
                var adjacency = [[Int]](repeating: [], count: count)
                func isWall(_ key: UInt64) -> Bool {
                    let a = Int(key >> 32), b = Int(key & 0xFFFFFFFF)
                    return a < onCurve.count && b < onCurve.count && onCurve[a] && onCurve[b]
                }
                for (key, ts) in edgeFaces where ts.count == 2 && !isWall(key) {
                    adjacency[ts[0]].append(ts[1]); adjacency[ts[1]].append(ts[0])
                }
                // The curve is not a closed fence: it only exists where a view could see it, so
                // a flood that respects nothing else escapes around the back of the car and
                // swallows it — 72% of the mesh, measured. Growth is therefore also confined to
                // faces that the stencil itself calls glass, seen by the view that owns them.
                // Neither test is sufficient alone: the stencil sweeps in whatever stands behind
                // a window, and the cut cannot enclose a region by itself. Together they are
                // exactly the painted patch.
                let pos = SheetStencil.normalised(v)
                let vn = SheetStencil.viewNormals(nm)
                var bases = [(SIMD3<Float>, SIMD3<Float>, SIMD3<Float>, SIMD3<Float>)]()
                for view in 0 ..< sdfs.count {
                    bases.append(SheetStencil.basis(elev: SheetStencil.elevs[view],
                                                    azim: SheetStencil.azims[view], dist: 1.45))
                }
                var candidate = [Bool](repeating: false, count: count)
                for t in 0 ..< count {
                    let i0 = Int(f[t*3]), i1 = Int(f[t*3+1]), i2 = Int(f[t*3+2])
                    var nrm = vn[i0] + vn[i1] + vn[i2]
                    guard simd_length(nrm) > 1e-12 else { continue }
                    nrm = simd_normalize(nrm)
                    var owner = SheetStencil.stencilViews[0], best = -Float.greatestFiniteMagnitude
                    for view in SheetStencil.stencilViews where view < sdfs.count {
                        let d = -simd_dot(nrm, bases[view].2)
                        if d > best { best = d; owner = view }
                    }
                    guard best > 0.1 else { continue }
                    let centre = (pos[i0] + pos[i1] + pos[i2]) / 3
                    let (right, up, _, eye) = bases[owner]
                    let d = centre - eye
                    let x = (simd_dot(d, right) / 0.6 * 0.5 + 0.5) * Float(tile - 1)
                    let y = (simd_dot(d, up) / 0.6 * 0.5 + 0.5) * Float(tile - 1)
                    // Bilinear, and with room to spare.
                    //
                    // Nearest-texel sampling of the stencil alternates in and out at exactly one
                    // texel pitch along a diagonal edge, and a face that lands in an "outside"
                    // texel is refused entry — so the growth stopped a triangle short in a
                    // regular rhythm, which is the sawtooth. Sampling smoothly and allowing a
                    // couple of texels of slack lets it reach the cut. It cannot overshoot: the
                    // curve itself is a wall the flood may not cross.
                    let cx = min(max(x, 0), Float(tile - 1)), cy = min(max(y, 0), Float(tile - 1))
                    let x0 = Int(cx), y0 = Int(cy)
                    let x1 = min(x0 + 1, tile - 1), y1 = min(y0 + 1, tile - 1)
                    let fx = cx - Float(x0), fy = cy - Float(y0)
                    let top = sdfs[owner][y0 * tile + x0] * (1 - fx)
                            + sdfs[owner][y0 * tile + x1] * fx
                    let bot = sdfs[owner][y1 * tile + x0] * (1 - fx)
                            + sdfs[owner][y1 * tile + x1] * fx
                    // One texel of slack, and no more.
                    //
                    // With the fence closed, growth is contained by the curve itself for a texel
                    // either side, which is where asking the stencil gives a coin-toss answer and
                    // produced the sawtooth. Past that the stencil rules again. Zero slack brings
                    // the teeth back; four lets the glass creep up the pillar.
                    let slack = Float(ProcessInfo.processInfo.environment["MODELR_CLIP_SLACK"] ?? "") ?? 1
                    candidate[t] = top * (1 - fy) + bot * fy > -slack
                }
                // Demote only faces the curve never touched.
                //
                // `candidate` is a nearest-texel lookup of the stencil at a face's centre. For a
                // sliver hugging the curve, that centre is a fraction of a texel from the zero
                // level, so along a diagonal edge the sampled texel alternates in and out at
                // exactly one texel pitch — and demoting on it re-quantised the boundary back to
                // the texel grid. That is the uniform sawtooth, and it is precisely the aliasing
                // the whole trace-and-cut design exists to avoid. `candidate` keeps its real job,
                // which is stopping the flood escaping into territory the curve never described.
                for t in 0 ..< count where glass[t] && !candidate[t] && !decidedByCut[t] {
                    glass[t] = false
                }
                // Growth takes one free step off every cut face, then must satisfy the stencil.
                //
                // A face touching the cut sits astride the painted edge, so asking the stencil
                // about its centre is a coin toss that lands differently every texel along a
                // diagonal — the sawtooth. It needs no such permission: the curve it touches is
                // a wall, so stepping across it is impossible. Beyond that first ring the stencil
                // rules again, which is what keeps the growth inside the window.
                var stack = ProcessInfo.processInfo.environment["MODELR_CLIP_NOFLOOD"] == "1"
                    ? [] : (0 ..< count).filter { glass[$0] }
                for t in stack where decidedByCut[t] {
                    for u in adjacency[t] where !glass[u] { glass[u] = true; stack.append(u) }
                }
                while let t = stack.popLast() {
                    for u in adjacency[t] where !glass[u] && candidate[u] {
                        glass[u] = true; stack.append(u)
                    }
                }
            }

            if glass.contains(true) {
                let cut = MeshCut.Mesh(vertices: v, normals: nm, uvs: uv, faces: f,
                                       inside: glass, parent: Array(0 ..< (f.count / 3)))
                return applyCut(cut, mesh: mesh, texture: tex, mr: mr, note: "curve clip")
            }
        }

        // Off by default until the stencil-to-mesh mapping is right. It currently classifies a
        // fifth of a car as glass — pillars, sills and interior that happen to project inside a
        // window outline — so shipping it as the default would hand back a worse car than doing
        // nothing. MODELR_SHEET_STENCIL=1 to work on it.
        if ProcessInfo.processInfo.environment["MODELR_SHEET_STENCIL"] == "1",
           let sheets = sheetURLs(for: id) {
            let stencil = GlassSheet.stencilURL(forSheet: sheets.albedo)
            var v = full.vertices, nm = full.normals, uv = full.uvs, f = full.faces
            var field = SheetStencil.field(stencil: stencil, vertices: v, normals: nm, faces: f)

            // Two rounds of refinement where the contour will land. Each round re-reads the
            // stencil at the new vertices, so the extra detail is real detail and not
            // interpolation of the old, coarse answer.
            if field != nil {
                for _ in 0 ..< 2 {
                    guard let current = field else { break }
                    var band = [Bool](repeating: false, count: f.count / 3)
                    var any = false
                    for t in 0 ..< (f.count / 3) {
                        let a = current[Int(f[t*3])], b = current[Int(f[t*3+1])], c = current[Int(f[t*3+2])]
                        let lo = min(a, min(b, c)), hi = max(a, max(b, c))
                        if lo < 0.6 && hi > -0.6 { band[t] = true; any = true }
                    }
                    guard any else { break }
                    let r = MeshCut.refine(vertices: v, normals: nm, uvs: uv, faces: f, band: band)
                    v = r.vertices; nm = r.normals; uv = r.uvs; f = r.faces
                    field = SheetStencil.field(stencil: stencil, vertices: v, normals: nm, faces: f)
                }
            }
            if let field,
               let cut = MeshCut.cut(vertices: v, normals: nm, uvs: uv, faces: f,
                                     inside: [Bool](repeating: false, count: f.count / 3),
                                     smoothing: 0, field: field, preserveArea: false),
               cut.inside.contains(true) {
                return applyCut(cut, mesh: mesh, texture: tex, mr: mr, note: "sheet stencil")
            }
        }

        // The alpha says *which* panels are glass. The mesh says *where* they end.
        //
        // Trusting alpha for the boundary is what kept producing torn windows: on the black car
        // the painted stencil is not a clean window outline at all, it is a blob with holes in
        // it, and cutting to it faithfully reproduces the blob. Cleaning and distance-fielding
        // the stencil made the tear smoother without making it a window.
        //
        // A window, though, is a smooth surface bounded by a hard crease where it meets its
        // frame — geometry that is exactly right and needs no guessing. So the alpha only picks
        // the seeds, and a crease-bounded flood supplies the outline.
        let level = MeshCut.alphaCut(texture: tex)
        guard let sdf = MeshCut.alphaField(texture: tex, vertices: full.vertices,
                                           uvs: full.uvs, faces: full.faces, cut: level) else {
            return "no alpha in the atlas — nothing to cut to"
        }
        let topology = GlassSelection.topology(vertices: full.vertices, faces: full.faces)
        let welded = MeshCut.weldMap(vertices: full.vertices)
        // Seeds: faces solidly inside the painted region, not merely touching its edge.
        var seed = [Bool](repeating: false, count: topology.faceCount)
        var seedCount = 0
        for f in 0 ..< topology.faceCount {
            let v = (sdf[welded[Int(full.faces[f*3])]] + sdf[welded[Int(full.faces[f*3+1])]]
                   + sdf[welded[Int(full.faces[f*3+2])]]) / 3
            if v > 0.5 { seed[f] = true; seedCount += 1 }
        }
        guard seedCount > 0 else { return "the atlas has no glass to cut out" }

        var mask = [Bool](repeating: false, count: topology.faceCount)
        for f in 0 ..< topology.faceCount where seed[f] && !mask[f] {
            let region = GlassSelection.flood(from: f, topology: topology, creaseDegrees: 32)
            // Only accept a patch the paint agrees is mostly glass. A flood from a stray seed
            // can otherwise run the length of a door.
            var total = 0, agreeing = 0
            for k in 0 ..< topology.faceCount where region[k] {
                total += 1
                if seed[k] { agreeing += 1 }
            }
            if total > 0, Double(agreeing) / Double(total) > 0.35 {
                for k in 0 ..< topology.faceCount where region[k] { mask[k] = true }
            } else {
                mask[f] = true
            }
        }
        guard mask.contains(true) else { return "the atlas has no glass to cut out" }

        guard let cut = MeshCut.cut(vertices: full.vertices, normals: full.normals,
                                    uvs: full.uvs, faces: full.faces, inside: mask,
                                    smoothing: 12),
              cut.inside.contains(true) else {
            return "the atlas has no glass to cut out"
        }
        return applyCut(cut, mesh: mesh, texture: tex, mr: mr, note: "painted alpha")
    }

    /// Marks a glass selection as this tool's own output rather than a person's choice.
    private func derivedMarker(_ mesh: URL) -> URL {
        mesh.deletingLastPathComponent().appendingPathComponent(
            mesh.deletingPathExtension().lastPathComponent + "_glass.derived")
    }

    private func applyCut(_ cut: MeshCut.Mesh, mesh: URL, texture tex: URL, mr: URL?,
                          note: String) -> String? {
        let backup = MeshCut.backupURL(forMesh: mesh)
        // A re-bake has already restored the uncut mesh, so the previous backup is stale.
        try? FileManager.default.removeItem(at: backup)
        try? FileManager.default.copyItem(at: mesh, to: backup)
        guard MeshCut.save(vertices: cut.vertices, normals: cut.normals, uvs: cut.uvs,
                           faces: cut.faces, to: mesh) else { return "could not write the mesh" }
        GlassSelection(mask: cut.inside).save(forMesh: mesh)
        try? Data().write(to: derivedMarker(mesh))
        MeshEraser.clear(forMesh: mesh)      // face indices moved; a stale mask is worse than none
        guard let r = GlassClean.clean(mesh: mesh, texture: tex, mr: mr, glass: cut.inside) else {
            return "the cut worked but the clean did not"
        }
        rebakeTick += 1
        // Dimensions included on purpose: "2,805,425 texels" read as a disaster against an
        // assumed 2048 atlas and is unremarkable against the 8192 one it actually was.
        return "\(cut.faces.count / 3) faces, \(cut.inside.lazy.filter { $0 }.count) glass, "
             + String(format: "%d texels cleaned (%.1f%% of atlas) (%@)",
                      r.texels, 100 * Double(r.texels) / Double(max(r.atlasTexels, 1)), note)
    }

    func requestRebake(_ id: Project.ID, weights: [Float]? = nil,
                       albedoOverride: URL? = nil) {
        guard rebakeStates[id] != .running,
              let project = store.project(id),
              let gen = project.currentGeneration,
              let sheets = sheetURLs(for: id),
              let texName = gen.paintedTextureFileName,
              let mrName = gen.paintedMRFileName else { return }
        let dir = store.folder(for: id)
        // Snapshot the atlas the diffusion model produced, once, before the first re-bake
        // overwrites it in place. Without this there is no way back to it.
        if originalPaintURLs(id) == nil {
            for name in [texName, mrName] {
                try? FileManager.default.copyItem(at: dir.appendingPathComponent(name),
                                                  to: dir.appendingPathComponent(Self.origName(name)))
            }
        }
        // Unused by the bake — `bakePBR` never calls `loadPBR` — but the initialiser wants it.
        let weightsRoot = ModelStore.paintWeightsRoot(for: gen.paintModel) ?? dir
        rebakeStates[id] = .running
        paintEngine.bakePBR(
            unbakedMesh: sheets.unbaked, albSheet: albedoOverride ?? sheets.albedo,
            mrSheet: sheets.mr,
            output: dir.appendingPathComponent(gen.meshFileName),
            texture: dir.appendingPathComponent(texName),
            mrTexture: dir.appendingPathComponent(mrName),
            weightsRoot: weightsRoot,
            // MODELR_BAKE_TEX overrides the atlas size for a re-bake. At ~9 texels per
            // face a triangle owns no texel centre and renders another triangle's colour;
            // baking bigger is the falsification test for that vs. silhouette bleed.
            tex: Int(ProcessInfo.processInfo.environment["MODELR_BAKE_TEX"] ?? "")
                 ?? (gen.paintTexRaw ?? 2048),
            weights: weights,
            extraViews: (gen.referenceViewsRaw ?? []).map {
                ExtraView(imagePath: dir.appendingPathComponent($0.fileName).path,
                          elev: Float($0.elev), azim: Float($0.azim), weight: Float($0.weight),
                          fovDeg: Float($0.fovDeg))
            },
            onProgress: { _, _ in },
            onFinish: { [weak self] outcome in
                Task { @MainActor in
                    guard let self else { return }
                    switch outcome {
                    case .success:
                        let stem = (gen.paintedMeshFileName ?? gen.meshFileName)
                            .replacingOccurrences(of: ".tmesh", with: "")
                        let fm = FileManager.default
                        // A cut/tint from a *previous* finish-glass still matches this mesh's
                        // face count — rebaking the atlas never changes topology — so it would
                        // otherwise keep overriding fresh auto-detection with a stale window
                        // outline and a stale opacity, no matter how the sheet was just edited.
                        // finishGlass (below) overwrites both with correct ones when it runs
                        // right after; clearing first is harmless either way.
                        for ext in ["_glass.bin", "_glass.opacity"] {
                            try? fm.removeItem(at: dir.appendingPathComponent(stem + ext))
                        }
                        if self.finishAfterRebake.remove(id) != nil {
                            self.finishStates[id] = .running
                            let note = self.finishGlass(id)
                            self.finishStates[id] = .idle
                            self.lastFinishNote[id] = note
                        }
                        if self.reskinAfterRebake.remove(id) != nil {
                            self.continueReskin(id)
                        } else {
                            // Not on the way to a fresh reskin: any reskin already sitting next
                            // to this mesh was built from the atlas this bake just overwrote, so
                            // it's stale now. currentViewerContent prefers a reskin unconditionally
                            // over the plain mesh — leaving the old one in place would make this
                            // rebake invisible, the mesh updated but the viewer still showing
                            // yesterday's reskin.
                            for ext in ["_reskin.tmesh", "_reskin_texture.png",
                                       "_reskin_glass.bin", "_reskin_glass.opacity"] {
                                try? fm.removeItem(at: dir.appendingPathComponent(stem + ext))
                            }
                        }
                        self.rebakeStates[id] = .idle
                        self.rebakeTick += 1
                    case .failure(let message):
                        self.rebakeStates[id] = .failed(message)
                    }
                }
            })
    }

    /// Progress of the finishing pass, for the button that starts it.
    var finishStates: [Project.ID: RebakeState] = [:]
    var lastFinishNote: [Project.ID: String?] = [:]

    func cancelShape(_ id: Project.ID) { dispatch(.shapeCancelRequested(project: id)) }
    func cancelPaint(_ id: Project.ID) { dispatch(.paintCancelRequested(project: id)) }

    /// Cancel whatever is legal to cancel, then remove the project + its files.
    func deleteProject(_ id: Project.ID) {
        dispatch(.shapeCancelRequested(project: id))
        dispatch(.paintCancelRequested(project: id))
        shapePreviews[id] = nil
        paintViewPreviews[id] = nil
        lastShapeRunDetails[id] = nil
        lastPaintRunDetails[id] = nil
        store.delete(id)
    }

    func install(_ model: ModelID) { dispatch(.installRequested(model)) }
    func pauseInstall(_ model: ModelID) { dispatch(.installPauseRequested(model)) }
    func resumeInstall(_ model: ModelID) { dispatch(.installResumeRequested(model)) }
    func removeInstall(_ model: ModelID) { dispatch(.installRemoveRequested(model)) }
    func retryInstall(_ model: ModelID) { dispatch(.installRetryRequested(model)) }
    func importWeights(_ model: ModelID, from folder: URL) {
        dispatch(.importWeightsRequested(model, folder: folder))
    }

    func showModelManager() { modelManagerSignal += 1 }

    var shapeJobs: [Project.ID: ShapeJob] { state.shape }
    var paintJobs: [Project.ID: PaintJob] { state.paint }

    // MARK: - effect execution

    private func perform(_ effect: AppEffect) {
        switch effect {
        // boot / persistence
        case .performMigration:
            let downloads = downloads!
            Task.detached(priority: .userInitiated) { [bridge] in
                ModelStore.performLegacyMigration()
                let report = Self.scanBootReport(downloads: downloads)
                bridge.send(.migrationFinished(report: report))
            }

        case .persistOnboardingComplete:
            UserDefaults.standard.set(true, forKey: Self.onboardingKey)

        case .persistInstallIntents(let intents):
            UserDefaults.standard.set(intents.map(\.rawValue).sorted(), forKey: Self.intentsKey)

        // model install
        case .startDownload(let model, let attempt):
            downloads.start(model, attempt: attempt)

        case .pauseDownload(let model):
            downloads.pause(model)

        case .verifyFiles(let model, let attempt):
            downloads.verify(model, attempt: attempt)

        case .removeModelFiles(let model):
            downloads.removeFiles(for: model)

        case .importWeights(let model, let folder):
            downloads.importWeights(for: model, from: folder)

        // shape job
        case .stageShape(let project, let token):
            do {
                let staged = try store.stageShapeRun(for: project)
                stagedShapes[project] = (token, staged)
                shapePreviews[project] = nil
                lastShapeRunDetails[project] = RunDetails(model: staged.settings.model.label,
                                                          seed: staged.seed)
                dispatch(.shapeStaged(project: project, token: token, error: nil))
            } catch {
                dispatch(.shapeStaged(project: project, token: token,
                                      error: error.localizedDescription))
            }

        case .startShapeEngine(let project, let token):
            startShapeEngine(project: project, token: token)

        case .commitShape(let project, let token):
            guard let (stagedToken, staged) = stagedShapes[project], stagedToken == token else {
                dispatch(.shapeCommitFinished(project: project, token: token,
                                              error: "The run's staged files were lost."))
                break
            }
            stagedShapes[project] = nil
            let error = store.commitShapeRun(staged)
            shapePreviews[project] = nil
            store.clearStreamFiles(for: project)
            dispatch(.shapeCommitFinished(project: project, token: token, error: error))

        case .discardShapeStaging(let project, let token):
            if let (stagedToken, staged) = stagedShapes[project], stagedToken == token {
                stagedShapes[project] = nil
                store.discardShapeRun(staged)
            }
            shapePreviews[project] = nil
            store.clearStreamFiles(for: project)

        // paint job
        case .stagePaint(let project, let token):
            do {
                let staged = try store.stagePaintRun(for: project)
                stagedPaints[project] = (token, staged)
                paintViewPreviews[project] = nil
                // The resolved paint seed (the initial-noise seed the pipeline runs
                // with) — recorded on the version and shown in the failure details.
                lastPaintRunDetails[project] = RunDetails(model: staged.settings.model.label,
                                                          seed: staged.seed)
                dispatch(.paintStaged(project: project, token: token, error: nil))
            } catch {
                dispatch(.paintStaged(project: project, token: token,
                                      error: error.localizedDescription))
            }

        case .unwrapPaintMesh(let project, let token):
            // §4.5 prep: QEM-decimate the shape mesh to the run's face budget before
            // the engine, whose internal xatlas unwrap + rasterizer cost scales with
            // triangle count (the known #1 perf issue — ~238 s to paint a 240k-vert
            // mesh, dominated by unwrap+raster). On decimation failure the original
            // mesh is painted instead — slow but correct. The pipeline still unwraps
            // internally; this stage owns the face budget + early mesh validation.
            guard let (stagedToken, staged) = stagedPaints[project], stagedToken == token else {
                dispatch(.paintUnwrapFinished(project: project, token: token,
                                              error: "The run's staged files were lost."))
                break
            }
            let src = staged.shapeMesh
            let dst = staged.prepMesh
            let budget = staged.settings.faces
            Task.detached(priority: .userInitiated) { [bridge] in
                let outcome = MeshDecimator.decimateMeshFile(at: src, faceBudget: budget, to: dst)
                let error: String?
                switch outcome {
                case .decimated, .unchanged:
                    error = nil
                case .fallback:
                    // Undecimated fallback (§4.5): scrub any partial prep file so
                    // the engine picks up the original mesh.
                    try? FileManager.default.removeItem(at: dst)
                    error = nil
                case .unreadable(let message):
                    error = message                      // genuinely bad mesh → Failed
                }
                bridge.send(.paintUnwrapFinished(project: project, token: token, error: error))
            }

        case .startPaintEngine(let project, let token):
            startPaintEngine(project: project, token: token)

        case .commitPaint(let project, let token):
            guard let (stagedToken, staged) = stagedPaints[project], stagedToken == token else {
                dispatch(.paintCommitFinished(project: project, token: token,
                                              error: "The run's staged files were lost."))
                break
            }
            stagedPaints[project] = nil
            let error = store.commitPaintRun(staged)
            paintViewPreviews[project] = nil
            store.clearPaintStreamFiles(for: project)
            dispatch(.paintCommitFinished(project: project, token: token, error: error))

        case .discardPaintStaging(let project, let token):
            if let (stagedToken, staged) = stagedPaints[project], stagedToken == token {
                stagedPaints[project] = nil
                store.discardPaintRun(staged)
            }
            paintViewPreviews[project] = nil
            store.clearPaintStreamFiles(for: project)

        // engine arbiter
        case .grantEngine(let key):
            Task { [arbiter, bridge] in
                await arbiter.grant(key)                   // evict-then-grant, sequenced
                bridge.send(.engineGranted(key))
            }

        case .cancelEngine(let key):
            engineRuns[key]?.cancel()

        case .releaseEngine(let key):
            engineRuns[key] = nil
            Task { [arbiter] in await arbiter.release(key) }

        // UX routing
        case .openModelManager:
            modelManagerSignal += 1
        }
    }

    // MARK: - engine adapters (callbacks → token-carrying events)

    private func startShapeEngine(project: Project.ID, token: UInt64) {
        let key = JobKey(kind: .shape, project: project, token: token)
        guard let (stagedToken, staged) = stagedShapes[project], stagedToken == token else {
            dispatch(.shapeEngineFinished(project: project, token: token,
                                          result: .failure("The run's staged files were lost.")))
            return
        }
        guard let weights = ModelStore.shapeWeightsFile(for: staged.settings.model) else {
            dispatch(.shapeEngineFinished(project: project, token: token,
                                          result: .failure("\(staged.settings.model.label) weights are no longer installed.")))
            return
        }
        let bridge = bridge
        var run: ShapeEngine.Run!
        // Multiview conditions on several photographs of the same object; the others take one.
        let extraViews = staged.settings.model == .multiview
            ? multiviewImageURLs(project).dropFirst().map { $0 }
            : []
        run = shapeEngine.generate(
            imageURL: staged.input,
            extraImageURLs: extraViews,
            output: staged.mesh,
            weightsURL: weights,
            quantize: staged.settings.quant.flag,
            steps: staged.settings.steps,
            guidance: Float(staged.settings.guidance),
            resolution: staged.settings.octree,
            seed: staged.seed,
            onProgress: { stage, _, fraction in
                if let mapped = Self.mapShapeStage(stage) {
                    bridge.send(.shapeEngineStage(project: project, token: token,
                                                  stage: mapped, fraction: fraction))
                }
            },
            onPreview: { url in
                Task { @MainActor in
                    guard let self = bridge.runtime,
                          self.state.shape[project]?.token == token else { return }
                    self.shapePreviews[project] = url
                }
            },
            onFinish: { outcome in
                let result: EngineResult
                switch outcome {
                case .success: result = .success
                case .failure(let message):
                    result = run.cancelled ? .cancelled : .failure(message)
                }
                bridge.send(.shapeEngineFinished(project: project, token: token, result: result))
            })
        engineRuns[key] = run
    }

    private func startPaintEngine(project: Project.ID, token: UInt64) {
        let key = JobKey(kind: .paint, project: project, token: token)
        guard let (stagedToken, staged) = stagedPaints[project], stagedToken == token else {
            dispatch(.paintEngineFinished(project: project, token: token,
                                          result: .failure("The run's staged files were lost.")))
            return
        }
        guard let weightsRoot = ModelStore.paintWeightsRoot(for: staged.settings.model) else {
            dispatch(.paintEngineFinished(project: project, token: token,
                                          result: .failure("Paint weights are no longer installed.")))
            return
        }
        let bridge = bridge
        let viewsDir = staged.outMesh.deletingLastPathComponent()
        let onProgress: (String, Double?) -> Void = { stage, fraction in
            if let mapped = Self.mapPaintStage(stage) {
                bridge.send(.paintEngineStage(project: project, token: token,
                                              stage: mapped, fraction: fraction))
            }
        }
        let onViews: (URL) -> Void = { url in
            Task { @MainActor in
                guard let self = bridge.runtime,
                      self.state.paint[project]?.token == token else { return }
                self.paintViewPreviews[project] = url
            }
        }
        var run: PaintEngine.Run!
        let onFinish: (GenerationOutcome) -> Void = { outcome in
            let result: EngineResult
            switch outcome {
            case .success: result = .success
            case .failure(let message):
                result = run.cancelled ? .cancelled : .failure(message)
            }
            bridge.send(.paintEngineFinished(project: project, token: token, result: result))
        }
        // Large → 2.1 PBR (albedo + metallic-roughness); Small → 2.0 Color (RGB).
        if staged.settings.model == .large {
            // Same one-job contract as paintPBR, but the flat view sheets and the un-baked
            // geometry survive the run, so they can be edited and re-baked without paying for
            // diffusion again. Named off the output mesh so they sort next to it.
            let stem = staged.outMesh.deletingPathExtension().lastPathComponent
            run = paintEngine.paintAndBakePBR(
                meshURL: staged.engineMesh, imageURL: staged.image,
                output: staged.outMesh, texture: staged.outTexture, mrTexture: staged.outMR,
                albSheet: viewsDir.appendingPathComponent("\(stem)_sheet_albedo.png"),
                mrSheet: viewsDir.appendingPathComponent("\(stem)_sheet_mr.png"),
                unbakedMesh: viewsDir.appendingPathComponent("\(stem)_unbaked.tmesh"),
                weightsRoot: weightsRoot,
                res: staged.settings.res, steps: staged.settings.steps, tex: staged.settings.tex,
                superres: staged.settings.superres, seed: staged.seed, viewsDir: viewsDir,
                onProgress: onProgress, onViews: onViews, onFinish: onFinish)
        } else {
            run = paintEngine.paint(
                meshURL: staged.engineMesh,      // decimated prep mesh when present (§4.5)
                imageURL: staged.image,
                output: staged.outMesh, texture: staged.outTexture,
                weightsRoot: weightsRoot,
                res: staged.settings.res, steps: staged.settings.steps, tex: staged.settings.tex,
                superres: staged.settings.superres, seed: staged.seed, viewsDir: viewsDir,
                onProgress: onProgress, onViews: onViews, onFinish: onFinish)
        }
        engineRuns[key] = run
    }

    // MARK: - engine progress → §4.4/§4.5 stages

    /// Hy3DMLX emits: "Conditioning image", "Denoising (k/N)", "Decoding shape",
    /// "Building mesh", "Done" (+ "Loading model…" on cache miss).
    static func mapShapeStage(_ stage: String) -> ShapeStage? {
        if stage.hasPrefix("Conditioning") { return .conditioning }
        if stage.hasPrefix("Denoising") {
            let (step, total) = parseProgress(stage)
            return .denoising(step: step, total: total)
        }
        if stage.hasPrefix("Decoding") { return .decoding }
        if stage.hasPrefix("Building mesh") { return .meshing }
        return nil                              // Loading model… / Done
    }

    /// HunyuanPaintMLX emits: "Loading paint model", "Unwrapping UVs", "Rendering
    /// control maps", "Painting (k/N)", "Decoding views", "Super-resolving",
    /// "Baking texture", "Done". "Unwrapping UVs" arrives with weights already
    /// resident, so it marks the Rendering stage boundary (§4.5 LoadingModel →
    /// Rendering: weights resident); inpainting has no separate engine signal and
    /// is passed through on completion.
    static func mapPaintStage(_ stage: String) -> PaintStage? {
        if stage.hasPrefix("Unwrapping") || stage.hasPrefix("Rendering") { return .rendering }
        if stage.hasPrefix("Painting") {
            let (step, total) = parseProgress(stage)
            return .denoising(step: step, total: total)
        }
        if stage.hasPrefix("Decoding") { return .decoding }
        if stage.hasPrefix("Super-resolving") { return .upscaling }
        if stage.hasPrefix("Baking") { return .baking }
        return nil                              // Loading paint model / Done
    }

    /// Extract "(k/N)" from an engine stage string; (0, 0) when absent.
    private static func parseProgress(_ stage: String) -> (Int, Int) {
        guard let open = stage.firstIndex(of: "("), let close = stage.firstIndex(of: ")"),
              open < close else { return (0, 0) }
        let parts = stage[stage.index(after: open)..<close].split(separator: "/")
        guard parts.count == 2, let k = Int(parts[0]), let n = Int(parts[1]) else { return (0, 0) }
        return (k, n)
    }
}
