import Foundation
import Observation
import AppKit

/// Owns all projects, their files on disk, and the live generation jobs.
@MainActor
@Observable
final class ProjectStore {
    private(set) var projects: [Project] = []
    var selection: Project.ID?

    /// Transient, non-persisted status per project.
    private var statuses: [Project.ID: GenerationStatus] = [:]
    /// Latest in-progress preview mesh per project (cleared when the job ends).
    private var previewURLs: [Project.ID: URL] = [:]
    /// Latest streaming point cloud per project (during the grid-query stage).
    private var pointsURLs: [Project.ID: URL] = [:]
    /// Bumped whenever input.png is rewritten, so the preview reloads from disk.
    private var inputVersions: [Project.ID: Int] = [:]

    private let shapeEngine = ShapeEngine()
    private let paintEngine = PaintEngine()
    private let downloader = ModelDownloader()

    /// Non-nil while model weights are downloading (overall fraction + current file).
    var downloadProgress: (fraction: Double, file: String)?
    var downloadError: String?
    /// Bumped when a download completes so availability-dependent UI re-evaluates.
    var modelsVersion = 0
    private var runningJobs: [Project.ID: any CancellableRun] = [:]
    /// Monotonic per-project run token: callbacks from a superseded run are ignored.
    private var runTokens: [Project.ID: UInt64] = [:]
    private var tokenCounter: UInt64 = 0

    /// Files + settings staged for the in-flight run, committed on success and
    /// removed if the run is cancelled or fails.
    private struct PendingGen {
        let id: UUID
        let mesh: URL
        let input: URL
        let source: URL?
        let mask: URL?
        let settings: RunSettings
        let removeBackground: Bool
        let startedAt: Date
    }
    private var pendingGen: [Project.ID: PendingGen] = [:]

    // Paint (texture) state — independent of shape generation.
    private var paintStatuses: [Project.ID: GenerationStatus] = [:]
    private var paintViewsURLs: [Project.ID: URL] = [:]
    private var paintJobs: [Project.ID: any CancellableRun] = [:]
    private var paintTokens: [Project.ID: UInt64] = [:]
    private struct PendingPaint {
        let id: UUID
        let source: Generation
        let mesh: URL
        let texture: URL
        let settings: PaintSettings
        let startedAt: Date
    }
    private var pendingPaint: [Project.ID: PendingPaint] = [:]

    private let rootDir: URL

    init() {
        rootDir = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Modelr", isDirectory: true)
        try? FileManager.default.createDirectory(at: projectsDir, withIntermediateDirectories: true)
        load()
    }

    // MARK: - paths

    private var indexFile: URL { rootDir.appendingPathComponent("projects.json") }
    private var projectsDir: URL { rootDir.appendingPathComponent("projects", isDirectory: true) }
    private func folder(for id: Project.ID) -> URL {
        projectsDir.appendingPathComponent(id.uuidString, isDirectory: true)
    }

    func imageURL(for project: Project) -> URL? {
        guard let name = project.inputImageName else { return nil }
        let url = folder(for: project.id).appendingPathComponent(name)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    func inputVersion(_ id: Project.ID) -> Int { inputVersions[id] ?? 0 }

    private func clearInputFiles(in folderURL: URL) {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(atPath: folderURL.path) else { return }
        for item in items where item.hasPrefix("input.") || item.hasPrefix("source.") || item.hasPrefix("mask.") {
            try? fm.removeItem(at: folderURL.appendingPathComponent(item))
        }
    }

    private func clearStreamFiles(in folderURL: URL) {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(atPath: folderURL.path) else { return }
        for item in items where (item.hasPrefix("preview_") && item.hasSuffix(".mesh"))
            || (item.hasPrefix("points_") && item.hasSuffix(".bin")) {
            try? fm.removeItem(at: folderURL.appendingPathComponent(item))
        }
    }

    func meshURL(for project: Project) -> URL? {
        if let gen = project.currentGeneration {
            let url = folder(for: project.id).appendingPathComponent(gen.meshFileName)
            return FileManager.default.fileExists(atPath: url.path) ? url : nil
        }
        // legacy fallback (pre-migration)
        guard let name = project.outputMeshName else { return nil }
        let url = folder(for: project.id).appendingPathComponent(name)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// The input-image snapshot for a saved generation (for history thumbnails).
    func inputURL(for generation: Generation, in id: Project.ID) -> URL? {
        guard !generation.inputFileName.isEmpty else { return nil }
        let url = folder(for: id).appendingPathComponent(generation.inputFileName)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    // MARK: paint accessors

    func paintStatus(for id: Project.ID) -> GenerationStatus { paintStatuses[id] ?? .idle }
    func isPainting(_ id: Project.ID) -> Bool {
        if case .running = paintStatus(for: id) { return true }
        return false
    }
    func paintViewsURL(for id: Project.ID) -> URL? {
        guard let url = paintViewsURLs[id] else { return nil }
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }
    /// The untextured shape geometry for the current selection — for a paint version,
    /// the shape it was textured from. Always the "model".
    func shapeMeshURL(for project: Project) -> URL? {
        guard let gen = project.currentGeneration else { return nil }
        let shapeName: String
        if gen.kind == .shape {
            shapeName = gen.meshFileName
        } else if let sid = gen.sourceShapeID,
                  let s = project.generations.first(where: { $0.id == sid }) {
            shapeName = s.meshFileName
        } else {
            return nil
        }
        let url = folder(for: project.id).appendingPathComponent(shapeName)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// Viewer content for the selected version: textured for a paint version, the
    /// plain shape mesh otherwise.
    func currentViewerContent(for project: Project) -> ViewerContent? {
        guard let gen = project.currentGeneration else { return nil }
        let dir = folder(for: project.id)
        let mesh = dir.appendingPathComponent(gen.meshFileName)
        guard FileManager.default.fileExists(atPath: mesh.path) else { return nil }
        if gen.kind == .paint, let texName = gen.paintedTextureFileName {
            let tex = dir.appendingPathComponent(texName)
            if FileManager.default.fileExists(atPath: tex.path) { return .texturedMesh(mesh, tex) }
        }
        return .mesh(mesh)
    }

    private func clearPaintStreamFiles(in folderURL: URL) {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(atPath: folderURL.path) else { return }
        for item in items where item.hasPrefix("paint_views_") && item.hasSuffix(".png") {
            try? fm.removeItem(at: folderURL.appendingPathComponent(item))
        }
    }

    func selectGeneration(_ genID: UUID, for id: Project.ID) {
        guard let i = projects.firstIndex(where: { $0.id == id }) else { return }
        projects[i].selectedGenerationID = genID
        // Drop a stale paint error so it doesn't linger over a different version.
        if case .failed = paintStatus(for: id) { paintStatuses[id] = .idle }
        save()
    }

    func deleteGeneration(_ genID: UUID, for id: Project.ID) {
        guard let i = projects.firstIndex(where: { $0.id == id }),
              projects[i].generations.contains(where: { $0.id == genID }) else { return }
        let dir = folder(for: id)
        // Cascade: deleting a shape also removes the paint versions that textured it,
        // so no paint version is left pointing at a missing source.
        let toRemove = projects[i].generations.filter { $0.id == genID || $0.sourceShapeID == genID }
        for gen in toRemove {
            for name in [gen.meshFileName, gen.inputFileName, gen.sourceFileName, gen.maskFileName,
                         gen.paintedMeshFileName, gen.paintedTextureFileName]
                .compactMap({ $0 }).filter({ !$0.isEmpty }) {
                try? FileManager.default.removeItem(at: dir.appendingPathComponent(name))
            }
        }
        let removed = Set(toRemove.map { $0.id })
        projects[i].generations.removeAll { removed.contains($0.id) }
        if let sel = projects[i].selectedGenerationID, removed.contains(sel) {
            projects[i].selectedGenerationID = projects[i].generations.last?.id
        }
        save()
    }

    /// Load a saved version's image (source + mask + cutout) back into the project's
    /// working files, so it can be edited and regenerated into a new version.
    func restoreGeneration(_ genID: UUID, for id: Project.ID) {
        guard let i = projects.firstIndex(where: { $0.id == id }),
              let gen = projects[i].generations.first(where: { $0.id == genID }) else { return }
        let dir = folder(for: id)
        let fm = FileManager.default
        clearInputFiles(in: dir)   // clears working input/source/mask, not the gen_* snapshots

        if let srcName = gen.sourceFileName, fm.fileExists(atPath: dir.appendingPathComponent(srcName).path) {
            let ext = (srcName as NSString).pathExtension.isEmpty ? "png" : (srcName as NSString).pathExtension
            let dest = dir.appendingPathComponent("source.\(ext)")
            try? fm.copyItem(at: dir.appendingPathComponent(srcName), to: dest)
            projects[i].sourceImageName = dest.lastPathComponent
        } else {
            projects[i].sourceImageName = nil   // old version without a source snapshot
        }
        if let maskName = gen.maskFileName, fm.fileExists(atPath: dir.appendingPathComponent(maskName).path) {
            try? fm.copyItem(at: dir.appendingPathComponent(maskName), to: dir.appendingPathComponent("mask.png"))
            projects[i].removeBackground = true
        } else {
            projects[i].removeBackground = false
        }
        let inputSnap = dir.appendingPathComponent(gen.inputFileName)
        if fm.fileExists(atPath: inputSnap.path) {
            try? fm.copyItem(at: inputSnap, to: dir.appendingPathComponent("input.png"))
            projects[i].inputImageName = "input.png"
        } else {
            projects[i].inputImageName = nil   // snapshot missing → no working input
        }
        inputVersions[id, default: 0] += 1
        save()
    }

    func project(_ id: Project.ID) -> Project? { projects.first { $0.id == id } }

    func status(for id: Project.ID) -> GenerationStatus { statuses[id] ?? .idle }

    /// The mesh to show right now while running: the latest preview if any.
    func previewURL(for id: Project.ID) -> URL? {
        guard let url = previewURLs[id] else { return nil }
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// The latest streaming point cloud (grid-query stage), if any.
    func pointsURL(for id: Project.ID) -> URL? {
        guard let url = pointsURLs[id] else { return nil }
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    // MARK: - CRUD

    @discardableResult
    func newProject() -> Project {
        let project = Project(name: nextUntitledName())
        try? FileManager.default.createDirectory(at: folder(for: project.id), withIntermediateDirectories: true)
        projects.insert(project, at: 0)
        selection = project.id
        save()
        return project
    }

    func delete(_ id: Project.ID) {
        cancel(id)
        cancelPaint(id)
        try? FileManager.default.removeItem(at: folder(for: id))
        projects.removeAll { $0.id == id }
        statuses[id] = nil
        runTokens[id] = nil
        if selection == id { selection = projects.first?.id }
        save()
    }

    func rename(_ id: Project.ID, to name: String) {
        guard let i = projects.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        projects[i].name = trimmed
        save()
    }

    func setModel(_ model: ModelChoice, for id: Project.ID) {
        guard let i = projects.firstIndex(where: { $0.id == id }) else { return }
        projects[i].model = model
        save()
    }

    func setQuantization(_ quant: Quantization, for id: Project.ID) {
        guard let i = projects.firstIndex(where: { $0.id == id }) else { return }
        projects[i].quantization = quant
        save()
    }

    func setAdvancedMode(_ on: Bool, for id: Project.ID) {
        guard let i = projects.firstIndex(where: { $0.id == id }) else { return }
        // Entering advanced: seed the fields from the current normal preset so the
        // configuration carries over instead of jumping to unrelated defaults.
        if on && !projects[i].advancedMode {
            let s = projects[i].resolvedSettings   // normal preset (advancedMode still false)
            projects[i].model = s.model
            projects[i].quantization = s.quant
            projects[i].steps = s.steps
            projects[i].guidance = s.guidance
            projects[i].octree = s.octree
        }
        projects[i].advancedMode = on
        save()
    }
    func setQuality(_ q: QualityPreset, for id: Project.ID) {
        guard let i = projects.firstIndex(where: { $0.id == id }) else { return }
        projects[i].quality = q
        save()
    }
    func setSteps(_ n: Int, for id: Project.ID) {
        guard let i = projects.firstIndex(where: { $0.id == id }) else { return }
        projects[i].steps = n
        save()
    }
    func setGuidance(_ g: Double, for id: Project.ID) {
        guard let i = projects.firstIndex(where: { $0.id == id }) else { return }
        projects[i].guidance = g
        save()
    }
    func setOctree(_ o: Int, for id: Project.ID) {
        guard let i = projects.firstIndex(where: { $0.id == id }) else { return }
        projects[i].octree = o
        save()
    }

    func setPaintAdvanced(_ on: Bool, for id: Project.ID) {
        guard let i = projects.firstIndex(where: { $0.id == id }) else { return }
        if on && !projects[i].paintAdvanced {
            let s = projects[i].resolvedPaintSettings   // seed from the normal preset
            projects[i].paintRes = s.res; projects[i].paintSteps = s.steps
            projects[i].paintTex = s.tex; projects[i].paintSuperres = s.superres
            projects[i].paintFaces = s.faces
        }
        projects[i].paintAdvanced = on
        save()
    }
    func setPaintQuality(_ q: PaintQuality, for id: Project.ID) {
        guard let i = projects.firstIndex(where: { $0.id == id }) else { return }
        projects[i].paintQuality = q; save()
    }
    func setPaintSteps(_ n: Int, for id: Project.ID) {
        guard let i = projects.firstIndex(where: { $0.id == id }) else { return }
        projects[i].paintSteps = n; save()
    }
    func setPaintRes(_ n: Int, for id: Project.ID) {
        guard let i = projects.firstIndex(where: { $0.id == id }) else { return }
        projects[i].paintRes = n; save()
    }
    func setPaintTex(_ n: Int, for id: Project.ID) {
        guard let i = projects.firstIndex(where: { $0.id == id }) else { return }
        projects[i].paintTex = n; save()
    }
    func setPaintSuperres(_ on: Bool, for id: Project.ID) {
        guard let i = projects.firstIndex(where: { $0.id == id }) else { return }
        projects[i].paintSuperres = on; save()
    }
    func setPaintFaces(_ n: Int, for id: Project.ID) {
        guard let i = projects.firstIndex(where: { $0.id == id }) else { return }
        projects[i].paintFaces = n; save()
    }

    // MARK: - image input

    func setImage(fromURL src: URL, for id: Project.ID) {
        guard let i = projects.firstIndex(where: { $0.id == id }) else { return }
        let ext = src.pathExtension.isEmpty ? "png" : src.pathExtension
        let dest = folder(for: id).appendingPathComponent("source.\(ext)")
        do {
            try FileManager.default.createDirectory(at: folder(for: id), withIntermediateDirectories: true)
            clearInputFiles(in: folder(for: id))
            try FileManager.default.copyItem(at: src, to: dest)
            projects[i].sourceImageName = dest.lastPathComponent
            applyImage(id)
        } catch {
            statuses[id] = .failed("Couldn't import image: \(error.localizedDescription)")
        }
    }

    func setImage(_ image: NSImage, for id: Project.ID) {
        guard let i = projects.firstIndex(where: { $0.id == id }) else { return }
        guard let png = image.pngData() else {
            statuses[id] = .failed("Unsupported image."); return
        }
        let dest = folder(for: id).appendingPathComponent("source.png")
        do {
            try FileManager.default.createDirectory(at: folder(for: id), withIntermediateDirectories: true)
            clearInputFiles(in: folder(for: id))
            try png.write(to: dest)
            projects[i].sourceImageName = dest.lastPathComponent
            applyImage(id)
        } catch {
            statuses[id] = .failed("Couldn't import image: \(error.localizedDescription)")
        }
    }

    func setRemoveBackground(_ on: Bool, for id: Project.ID) {
        guard let i = projects.firstIndex(where: { $0.id == id }) else { return }
        projects[i].removeBackground = on
        save()
        if projects[i].sourceImageName != nil { applyImage(id) }   // re-process + regenerate
    }

    /// Produce the model input from the source image (optionally background-removed
    /// via an editable mask), then kick off generation.
    private func applyImage(_ id: Project.ID) {
        guard let i = projects.firstIndex(where: { $0.id == id }),
              let srcName = projects[i].sourceImageName else { return }
        let dir = folder(for: id)
        let source = dir.appendingPathComponent(srcName)
        let input = dir.appendingPathComponent("input.png")
        let maskFile = dir.appendingPathComponent("mask.png")
        try? FileManager.default.removeItem(at: input)

        var wrote = false
        if projects[i].removeBackground, let original = BackgroundRemover.loadCGImage(source) {
            // an edited mask if present, else compute (and cache) the Vision mask
            var mask = BackgroundRemover.loadCGImage(maskFile)
            if mask == nil {
                mask = BackgroundRemover.visionMask(for: original)
                if let m = mask, let data = BackgroundRemover.pngData(m) { try? data.write(to: maskFile) }
            }
            if let mask, let cutout = BackgroundRemover.cutoutPNG(original: original, mask: mask) {
                wrote = (try? cutout.write(to: input)) != nil
            }
        }
        if !wrote {
            try? FileManager.default.removeItem(at: maskFile)
            if let cg = BackgroundRemover.loadCGImage(source), let png = BackgroundRemover.pngData(cg) {
                wrote = (try? png.write(to: input)) != nil   // upright (bakes EXIF orientation)
            } else if let img = NSImage(contentsOf: source), let png = img.pngData() {
                wrote = (try? png.write(to: input)) != nil
            }
        }
        guard wrote else {
            projects[i].inputImageName = nil   // input.png was removed above; don't leave a dangling ref
            inputVersions[id, default: 0] += 1
            save()
            statuses[id] = .failed("Couldn't process the image.")
            return
        }
        projects[i].inputImageName = "input.png"
        projects[i].outputMeshName = nil
        inputVersions[id, default: 0] += 1   // force the left preview to reload from disk
        save()
        // Generation is started explicitly by the user (Start button), so they can
        // adjust background removal / model first.
    }

    /// Save a hand-edited mask and recomposite + regenerate.
    func applyEditedMask(_ mask: CGImage, for id: Project.ID) {
        guard let i = projects.firstIndex(where: { $0.id == id }) else { return }
        if let data = BackgroundRemover.pngData(mask) {
            try? data.write(to: folder(for: id).appendingPathComponent("mask.png"))
        }
        projects[i].removeBackground = true
        save()
        applyImage(id)
    }

    /// The original image + current mask for the touch-up editor.
    func maskEditingInputs(for id: Project.ID) -> (original: CGImage, mask: CGImage)? {
        guard let project = projects.first(where: { $0.id == id }),
              let srcName = project.sourceImageName,
              let original = BackgroundRemover.loadCGImage(folder(for: id).appendingPathComponent(srcName))
        else { return nil }
        let maskFile = folder(for: id).appendingPathComponent("mask.png")
        guard let mask = BackgroundRemover.loadCGImage(maskFile) ?? BackgroundRemover.visionMask(for: original)
        else { return nil }
        return (original, mask)
    }

    // MARK: - generation

    func generate(_ id: Project.ID) {
        guard let project = projects.first(where: { $0.id == id }),
              let image = imageURL(for: project) else { return }
        let settings = project.resolvedSettings

        guard let weightsURL = ModelStore.shapeWeightsFile(for: settings.model) else {
            statuses[id] = .failed("\(settings.model.label) weights aren't available yet — download the model first.")
            return
        }

        cancel(id)
        tokenCounter += 1
        let token = tokenCounter
        runTokens[id] = token

        // Each run gets its own saved files + a snapshot of the exact input used
        // (taken now, so a mid-run input change can't corrupt this version).
        let genID = UUID()
        let dir = folder(for: id)
        let output = dir.appendingPathComponent("gen_\(genID.uuidString).mesh")
        let genInput = dir.appendingPathComponent("gen_\(genID.uuidString)_input.png")
        try? FileManager.default.removeItem(at: output)
        try? FileManager.default.removeItem(at: genInput)
        try? FileManager.default.copyItem(at: image, to: genInput)

        // Snapshot the source + mask too, so this version's image can be re-edited.
        var genSource: URL?
        if let srcName = project.sourceImageName {
            let ext = (srcName as NSString).pathExtension.isEmpty ? "png" : (srcName as NSString).pathExtension
            let snap = dir.appendingPathComponent("gen_\(genID.uuidString)_source.\(ext)")
            if (try? FileManager.default.copyItem(at: dir.appendingPathComponent(srcName), to: snap)) != nil {
                genSource = snap
            }
        }
        var genMask: URL?
        let maskFile = dir.appendingPathComponent("mask.png")
        if FileManager.default.fileExists(atPath: maskFile.path) {
            let snap = dir.appendingPathComponent("gen_\(genID.uuidString)_mask.png")
            if (try? FileManager.default.copyItem(at: maskFile, to: snap)) != nil { genMask = snap }
        }

        pendingGen[id] = PendingGen(id: genID, mesh: output, input: genInput,
                                    source: genSource, mask: genMask,
                                    settings: settings, removeBackground: project.removeBackground,
                                    startedAt: Date())

        clearStreamFiles(in: dir)
        previewURLs[id] = nil
        pointsURLs[id] = nil
        statuses[id] = .running(stage: "Loading model…", detail: nil, fraction: nil)

        paintEngine.evict()            // free the paint model — shape & paint run sequentially
        let run = shapeEngine.generate(
            imageURL: genInput,        // the immutable per-run snapshot, not the live input.png
            output: output,
            weightsURL: weightsURL,
            quantize: settings.quant.flag,
            steps: settings.steps,
            guidance: Float(settings.guidance),
            resolution: settings.octree,
            seed: 0,
            onProgress: { [weak self] stage, detail, fraction in
                Task { @MainActor in
                    guard let self, self.runTokens[id] == token else { return }
                    self.statuses[id] = .running(stage: stage, detail: detail, fraction: fraction)
                }
            },
            onFinish: { [weak self] outcome in
                Task { @MainActor in
                    guard let self, self.runTokens[id] == token else { return }
                    self.runningJobs[id] = nil
                    switch outcome {
                    case .success:
                        if self.commitGeneration(for: id) {
                            self.statuses[id] = .done
                        } else {
                            self.statuses[id] = .failed("The model didn't produce a valid mesh.")
                        }
                        self.previewURLs[id] = nil
                        self.pointsURLs[id] = nil
                        self.clearStreamFiles(in: self.folder(for: id))
                    case .failure(let message):
                        self.discardPendingGen(for: id)
                        self.previewURLs[id] = nil
                        self.pointsURLs[id] = nil
                        self.clearStreamFiles(in: self.folder(for: id))
                        self.statuses[id] = .failed(message)
                    }
                }
            })
        runningJobs[id] = run
    }

    /// Download any missing weights for the project's shape model (+ the paint model)
    /// into the app container from HuggingFace, reporting progress for the UI.
    func downloadModels(for id: Project.ID) {
        guard downloadProgress == nil,
              let project = projects.first(where: { $0.id == id }) else { return }
        let model = project.resolvedSettings.model
        var files = ModelStore.isShapeAvailable(model) ? [] : downloader.shapeFiles(for: model)
        if !ModelStore.isPaintAvailable { files += downloader.paintFiles() }
        guard !files.isEmpty else { return }
        downloadError = nil
        downloadProgress = (0, "Starting…")
        Task { @MainActor in
            do {
                try await downloader.download(files) { frac, file in
                    Task { @MainActor in self.downloadProgress = (frac, file) }
                }
                self.downloadProgress = nil
                self.modelsVersion += 1            // nudge availability-dependent UI
            } catch {
                self.downloadProgress = nil
                self.downloadError = error.localizedDescription
            }
        }
    }

    /// Turn the just-finished run into a saved generation, selected for viewing.
    /// Returns false (and cleans up) if the worker produced no usable mesh.
    @discardableResult
    private func commitGeneration(for id: Project.ID) -> Bool {
        guard let pg = pendingGen[id], let i = projects.firstIndex(where: { $0.id == id }) else { return false }
        pendingGen[id] = nil
        // A 0-byte (or sub-header) file means a crash mid-write — discard it.
        let size = (try? pg.mesh.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard FileManager.default.fileExists(atPath: pg.mesh.path), size > 8 else {
            removePendingFiles(pg)
            return false
        }
        let s = pg.settings
        let gen = Generation(id: pg.id, createdAt: pg.startedAt,
                             modelRaw: s.model.rawValue, quantRaw: s.quant.rawValue,
                             steps: s.steps, removeBackground: pg.removeBackground,
                             meshFileName: pg.mesh.lastPathComponent,
                             inputFileName: pg.input.lastPathComponent,
                             durationSeconds: Date().timeIntervalSince(pg.startedAt),
                             guidanceRaw: s.guidance, octreeRaw: s.octree,
                             sourceFileName: pg.source?.lastPathComponent,
                             maskFileName: pg.mask?.lastPathComponent)
        projects[i].generations.append(gen)
        projects[i].selectedGenerationID = gen.id
        projects[i].outputMeshName = nil
        save()
        return true
    }

    /// Drop a staged run's files (cancelled / failed) so they don't accumulate.
    private func discardPendingGen(for id: Project.ID) {
        guard let pg = pendingGen[id] else { return }
        pendingGen[id] = nil
        removePendingFiles(pg)
    }

    private func removePendingFiles(_ pg: PendingGen) {
        for url in [pg.mesh, pg.input, pg.source, pg.mask].compactMap({ $0 }) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    func cancel(_ id: Project.ID) {
        cancelPaint(id)                   // a fresh/cancelled shape invalidates any in-flight paint
        runningJobs[id]?.cancel()
        runningJobs[id] = nil
        tokenCounter += 1                 // invalidate any in-flight callbacks
        runTokens[id] = tokenCounter
        discardPendingGen(for: id)
        previewURLs[id] = nil
        pointsURLs[id] = nil
        clearStreamFiles(in: folder(for: id))
        if case .running = status(for: id) { statuses[id] = .idle }
    }

    func isRunning(_ id: Project.ID) -> Bool {
        if case .running = status(for: id) { return true }
        return false
    }

    // MARK: - paint (texture)

    func paint(_ id: Project.ID) {
        guard let project = projects.first(where: { $0.id == id }),
              let current = project.currentGeneration else { return }
        // Texture the underlying shape; re-painting a paint version uses its source.
        let shape: Generation
        if current.kind == .shape { shape = current }
        else if let sid = current.sourceShapeID,
                let s = project.generations.first(where: { $0.id == sid }) { shape = s }
        else { return }
        guard let paintWeightsRoot = ModelStore.paintWeightsRoot else {
            paintStatuses[id] = .failed("Paint weights aren't available yet — download the paint model first."); return
        }
        let dir = folder(for: id)
        let meshURL = dir.appendingPathComponent(shape.meshFileName)
        guard FileManager.default.fileExists(atPath: meshURL.path),
              let image = inputURL(for: shape, in: id) ?? imageURL(for: project) else { return }

        cancelPaint(id)
        tokenCounter += 1; let token = tokenCounter; paintTokens[id] = token

        let paintID = UUID()
        let outMesh = dir.appendingPathComponent("painted_\(paintID.uuidString).tmesh")
        let outTex = dir.appendingPathComponent("painted_\(paintID.uuidString)_texture.png")
        try? FileManager.default.removeItem(at: outMesh)
        clearPaintStreamFiles(in: dir)
        paintViewsURLs[id] = nil
        let settings = project.resolvedPaintSettings
        pendingPaint[id] = PendingPaint(id: paintID, source: shape, mesh: outMesh, texture: outTex,
                                        settings: settings, startedAt: Date())
        paintStatuses[id] = .running(stage: "Loading paint model…", detail: nil, fraction: nil)

        // Prefer the shape's immutable input snapshot; if it's missing, snapshot the
        // live image so a mid-paint input change can't corrupt this run.
        var paintInput = image
        if inputURL(for: shape, in: id) == nil {
            let copy = FileManager.default.temporaryDirectory
                .appendingPathComponent("paint_input_\(paintID.uuidString).png")
            if (try? FileManager.default.copyItem(at: image, to: copy)) != nil { paintInput = copy }
        }
        shapeEngine.evict()            // free the shape model — paint runs after shape
        let job = paintEngine.paint(
            meshURL: meshURL, imageURL: paintInput, output: outMesh, texture: outTex,
            weightsRoot: paintWeightsRoot,
            res: settings.res, steps: settings.steps, tex: settings.tex,
            superres: settings.superres, viewsDir: dir,
            onProgress: { [weak self] stage, fraction in
                Task { @MainActor in
                    guard let self, self.paintTokens[id] == token else { return }
                    self.paintStatuses[id] = .running(stage: stage, detail: nil, fraction: fraction)
                }
            },
            onViews: { [weak self] url in
                Task { @MainActor in
                    guard let self, self.paintTokens[id] == token else { return }
                    self.paintViewsURLs[id] = url
                }
            },
            onFinish: { [weak self] outcome in
                Task { @MainActor in
                    guard let self, self.paintTokens[id] == token else { return }
                    self.paintJobs[id] = nil
                    switch outcome {
                    case .success:
                        if self.commitPaint(for: id) {
                            self.paintStatuses[id] = .done
                        }   // else commitPaint set .failed (missing/zero-byte output)
                        self.clearPaintStreamFiles(in: self.folder(for: id))
                        self.paintViewsURLs[id] = nil
                    case .failure(let message):
                        if let p = self.pendingPaint[id] {
                            try? FileManager.default.removeItem(at: p.mesh)
                            try? FileManager.default.removeItem(at: p.texture)
                            self.pendingPaint[id] = nil
                        }
                        self.clearPaintStreamFiles(in: self.folder(for: id))
                        self.paintViewsURLs[id] = nil
                        self.paintStatuses[id] = .failed(message)
                    }
                }
            })
        paintJobs[id] = job
    }

    @discardableResult
    private func commitPaint(for id: Project.ID) -> Bool {
        guard let pend = pendingPaint[id], let i = projects.firstIndex(where: { $0.id == id }) else { return false }
        pendingPaint[id] = nil
        // Require BOTH the mesh and the texture, each non-trivially sized (a crash mid-
        // write leaves a 0-byte file) before recording the version.
        func sized(_ url: URL) -> Bool {
            ((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) > 8
        }
        guard sized(pend.mesh), sized(pend.texture) else {
            try? FileManager.default.removeItem(at: pend.mesh)
            try? FileManager.default.removeItem(at: pend.texture)
            paintStatuses[id] = .failed("Paint didn't produce a usable texture.")
            return false
        }
        let src = pend.source
        let s = pend.settings
        let gen = Generation(
            id: pend.id, createdAt: pend.startedAt,
            modelRaw: src.modelRaw, quantRaw: src.quantRaw, steps: src.steps,
            removeBackground: src.removeBackground,
            meshFileName: pend.mesh.lastPathComponent,
            inputFileName: src.inputFileName,
            durationSeconds: Date().timeIntervalSince(pend.startedAt),
            guidanceRaw: src.guidanceRaw, octreeRaw: src.octreeRaw,
            paintedTextureFileName: pend.texture.lastPathComponent,
            kindRaw: "paint", sourceShapeID: src.id,
            paintResRaw: s.res, paintStepsRaw: s.steps,
            paintTexRaw: s.tex, paintFacesRaw: s.faces, paintSuperresRaw: s.superres)
        projects[i].generations.append(gen)
        projects[i].selectedGenerationID = gen.id
        save()
        return true
    }

    func cancelPaint(_ id: Project.ID) {
        paintJobs[id]?.cancel()
        paintJobs[id] = nil
        tokenCounter += 1; paintTokens[id] = tokenCounter
        if let p = pendingPaint[id] {
            try? FileManager.default.removeItem(at: p.mesh)
            try? FileManager.default.removeItem(at: p.texture)
            pendingPaint[id] = nil
        }
        clearPaintStreamFiles(in: folder(for: id))
        paintViewsURLs[id] = nil
        if case .running = paintStatus(for: id) { paintStatuses[id] = .idle }
    }

    // MARK: - persistence

    private func load() {
        guard let data = try? Data(contentsOf: indexFile) else { return }   // first launch, no file
        guard let decoded = try? JSONDecoder().decode([Project].self, from: data) else {
            // Don't silently wipe everything on a malformed file: preserve it for recovery
            // before the next save() overwrites projects.json.
            let backup = indexFile.deletingPathExtension()
                .appendingPathExtension("corrupt-\(Int(Date().timeIntervalSince1970)).json")
            try? FileManager.default.copyItem(at: indexFile, to: backup)
            return
        }
        projects = decoded.sorted { $0.createdAt > $1.createdAt }
        selection = projects.first?.id

        // Self-heal: a worker may have written output.mesh before the success
        // callback persisted outputMeshName (app quit/crash in that window).
        // Recover those from disk so a finished mesh isn't silently lost.
        var healed = false
        for i in projects.indices {
            // Migrate a legacy single output.mesh into the generations list, so an
            // existing project's result becomes its first saved version.
            if projects[i].generations.isEmpty {
                let dir = folder(for: projects[i].id)
                let legacy = dir.appendingPathComponent("output.mesh")
                if FileManager.default.fileExists(atPath: legacy.path) {
                    func snapshot(_ name: String?, as base: String) -> String? {
                        guard let name, !name.isEmpty else { return nil }
                        let src = dir.appendingPathComponent(name)
                        guard FileManager.default.fileExists(atPath: src.path) else { return nil }
                        let ext = (name as NSString).pathExtension.isEmpty ? "png" : (name as NSString).pathExtension
                        let snap = dir.appendingPathComponent("\(base).\(ext)")
                        try? FileManager.default.removeItem(at: snap)
                        return (try? FileManager.default.copyItem(at: src, to: snap)) != nil ? snap.lastPathComponent : nil
                    }
                    let inputName = snapshot(projects[i].inputImageName, as: "gen_legacy_input") ?? ""
                    let sourceName = snapshot(projects[i].sourceImageName, as: "gen_legacy_source")
                    let maskName = FileManager.default.fileExists(atPath: dir.appendingPathComponent("mask.png").path)
                        ? snapshot("mask.png", as: "gen_legacy_mask") : nil
                    let gen = Generation(id: UUID(), createdAt: projects[i].createdAt,
                                         modelRaw: projects[i].model.rawValue,
                                         quantRaw: projects[i].quantization.rawValue,
                                         steps: projects[i].model.steps,
                                         removeBackground: projects[i].removeBackground,
                                         meshFileName: "output.mesh",
                                         inputFileName: inputName,
                                         durationSeconds: nil,
                                         sourceFileName: sourceName,
                                         maskFileName: maskName)
                    projects[i].generations = [gen]
                    projects[i].selectedGenerationID = gen.id
                    projects[i].outputMeshName = nil
                    healed = true
                }
            }
            if meshURL(for: projects[i]) != nil {
                statuses[projects[i].id] = .done
            }
        }
        if healed { save() }
        sweepOrphanGenFiles()
    }

    /// Delete gen_*.mesh / gen_*_input.png files no Generation references — orphans
    /// left by a crash or a cancelled run whose worker wrote after cleanup.
    private func sweepOrphanGenFiles() {
        let fm = FileManager.default
        for project in projects {
            let dir = folder(for: project.id)
            guard let items = try? fm.contentsOfDirectory(atPath: dir.path) else { continue }
            var referenced = Set<String>()
            for gen in project.generations {
                for name in [gen.meshFileName, gen.inputFileName, gen.sourceFileName, gen.maskFileName,
                             gen.paintedMeshFileName, gen.paintedTextureFileName]
                    .compactMap({ $0 }).filter({ !$0.isEmpty }) {
                    referenced.insert(name)
                }
            }
            for item in items where (item.hasPrefix("gen_") || item.hasPrefix("painted_"))
                && !referenced.contains(item) {
                try? fm.removeItem(at: dir.appendingPathComponent(item))
            }
        }
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(projects) {
            try? data.write(to: indexFile)
        }
    }

    private func nextUntitledName() -> String {
        let base = "Untitled"
        let used = Set(projects.map(\.name))
        if !used.contains(base) { return base }
        var n = 2
        while used.contains("\(base) \(n)") { n += 1 }
        return "\(base) \(n)"
    }
}
