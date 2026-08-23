import SwiftUI
import simd

/// Delete hallucinated geometry by pointing at it.
///
/// Nothing is written to the mesh: the erasure is a mask stored alongside it, so a mistake is one
/// click to undo and every texture already baked against those UVs stays valid.
struct MeshEraserView: View {
    let project: Project
    @Environment(AppRuntime.self) private var runtime
    @Environment(ProjectStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    enum Mode: String, CaseIterable, Identifiable {
        case shell, region, sphere
        var id: String { rawValue }
        var label: String {
            switch self {
            case .shell:  return "Whole piece"
            case .region: return "Smooth patch"
            case .sphere: return "Sphere"
            }
        }
        var hint: String {
            switch self {
            case .shell:  return "Takes everything joined to what you click. Right for a floating "
                               + "blob — but a car body is usually ONE shell, so clicking it takes "
                               + "the whole car."
            case .region: return "Takes the smooth surface you click, stopping at creases."
            case .sphere: return "Takes everything within the radius of the point you click, "
                               + "connected or not."
            }
        }
    }

    /// One click, remembered rather than resolved.
    ///
    /// Keeping the seed and its mode instead of only the resulting faces is what lets the crease
    /// and fill sliders work *after* the fact: moving either re-runs every stroke at the new
    /// setting, so the marked area grows and shrinks live instead of being frozen at whatever the
    /// slider happened to say when you clicked.
    struct Stroke { let seed: Int; let mode: Mode; let add: Bool }
    @State private var strokes: [Stroke] = []
    /// Faces slated for deletion: painted so the choice is visible before it is committed.
    @State private var marked: [Bool] = []
    /// Faces already deleted — hidden from the model and from the export.
    @State private var erased: [Bool] = []
    @State private var undoStack: [(marked: [Bool], erased: [Bool])] = []
    @State private var topology: GlassSelection.Topology?
    @State private var geometry: (vertices: [Float], faces: [UInt32])?
    @State private var mode: Mode = .region
    @State private var radius: Double = 0.08
    @State private var crease: Double = 32
    /// How hard to close the specks a crease flood leaves inside an otherwise solid area.
    @State private var fill: Double = 2
    /// Rings of close applied to the boundary — the sawtooth remover.
    @State private var smooth: Double = 2
    @State private var edits = 0
    /// Faces under the cursor — what a click would take, shown before committing to it.
    @State private var hover: [Int] = []
    /// The face the hover preview was last computed for — mouse moves arrive far faster than a
    /// flood over a few hundred thousand faces, and the answer only changes when the face does.
    @State private var hoverSeed: Int = -1
    /// Ignore anything bigger than this fraction of the model. Floating debris is tiny and the
    /// panel behind it is not, so a cap lets you sweep up the specks without ever catching the
    /// panel — the one thing that makes clicking through a cloud of them practical.
    @State private var maxSize: Double = 1.0
    @State private var lasso = false
    /// Marks that did not come from clicks — a lasso, or Find loose pieces — which the sliders
    /// cannot re-derive and so must not overwrite.
    @State private var baseMarked: [Bool] = []
    @State private var meshDiagonal: Float = 1
    @State private var busy = false
    @State private var status = ""

    private var meshURL: URL? {
        switch store.currentViewerContent(for: project) {
        case .pbrMesh(let m, _, _)?:   return m
        case .texturedMesh(let m, _)?: return m
        case .mesh(let m)?:            return m
        default:                       return nil
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            MeshViewer(content: store.currentViewerContent(for: project),
                       glassHighlight: marked.contains(true) ? marked : nil,
                       markColor: NSColor(red: 1, green: 0.25, blue: 0.2, alpha: 1),
                       hoverFaces: hover,
                       erasePreview: erased.contains(true) ? erased : nil,
                       variant: edits,
                       onFacePicked: { packed, shift in mark(packed, unmark: shift) },
                       onFaceHovered: { packed in previewHover(packed) },
                       lasso: lasso,
                       onLasso: { rect, shift, project in lassoPick(rect, project, remove: shift) })
                .frame(minHeight: 380)
            Divider()
            controls
        }
        .frame(minWidth: 900, minHeight: 620)
        .task { await load() }
        .onDisappear { if topology != nil { apply() } }
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Row 1 — how a click or drag chooses faces.
            HStack(spacing: 10) {
                Text("Select").font(.caption).foregroundStyle(.secondary)
                Picker("", selection: $mode) {
                    ForEach(Mode.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented).fixedSize()

                Toggle(isOn: $lasso) {
                    Label("Lasso", systemImage: "rectangle.dashed")
                }
                .toggleStyle(.button)
                .help("Drag a box to mark everything inside it. Orbiting is paused while it is on.")

                Button {
                    Task { await autoLoose() }
                } label: { Label("Find floating bits", systemImage: "wand.and.stars") }
                    .help("Mark every detached piece smaller than Max size. Anything welded to "
                          + "the body is left alone.")
                    .disabled(busy || topology == nil)

                Spacer()
                if busy { ProgressView().controlSize(.small) }
                Text(status).font(.caption).foregroundStyle(.secondary)
                    .lineLimit(2).frame(maxWidth: 260, alignment: .trailing)
            }

            // Row 2 — how far that choice reaches. Only the sliders that apply to the current
            // mode are shown: a control that does nothing is worse than one that is missing.
            HStack(spacing: 16) {
                if mode == .region {
                    labelled("Crease", "\(Int(crease))°") {
                        Slider(value: $crease, in: 15...75, step: 1)
                            .onChange(of: crease) { _, _ in recompute() }
                            .disabled(strokes.isEmpty)
                    }
                }
                if mode == .sphere {
                    labelled("Radius", String(format: "%.02f", radius)) {
                        Slider(value: $radius, in: 0.01...0.4)
                            .onChange(of: radius) { _, _ in recompute() }
                    }
                }
                labelled("Fill", "\(Int(fill))") {
                    Slider(value: $fill, in: 0...8, step: 1)
                        .onChange(of: fill) { _, _ in recompute() }
                        .disabled(strokes.isEmpty && !baseMarked.contains(true))
                }
                labelled("Smooth", "\(Int(smooth))") {
                    Slider(value: $smooth, in: 0...4, step: 1)
                        .onChange(of: smooth) { _, _ in recompute() }
                }
                .help("Straighten a sawtooth edge left by the triangulation")
                labelled("Max size", maxSize > 0.999 ? "any"
                                                     : String(format: "%.0f%%", maxSize * 100)) {
                    Slider(value: $maxSize, in: 0.02...1.0)
                        .onChange(of: maxSize) { _, _ in hoverSeed = -1; recompute() }
                }
                .help("Ignore anything wider than this share of the model, so specks can be "
                      + "picked without catching the panel behind them")
            }

            // Row 3 — what to do with what is marked.
            HStack(spacing: 10) {
                Button {
                    guard let t = topology else { return }
                    undoStack.append((marked, erased))
                    baseMarked = MeshEraser.grow(marked, topology: t)
                    strokes.removeAll(); marked = baseMarked; edits += 1
                    status = "\(marked.lazy.filter { $0 }.count) faces marked (grown)"
                } label: { Image(systemName: "plus.magnifyingglass") }
                    .help("Grow the marked area by one ring of faces")
                    .disabled(!marked.contains(true))

                Button {
                    guard let t = topology else { return }
                    undoStack.append((marked, erased))
                    baseMarked = MeshEraser.shrink(marked, topology: t)
                    strokes.removeAll(); marked = baseMarked; edits += 1
                    status = "\(marked.lazy.filter { $0 }.count) faces marked (shrunk)"
                } label: { Image(systemName: "minus.magnifyingglass") }
                    .help("Shrink the marked area by one ring of faces")
                    .disabled(!marked.contains(true))

                Button {
                    if let prev = undoStack.popLast() {
                        marked = prev.marked; baseMarked = prev.marked
                        strokes.removeAll()      // the base now carries what the strokes made
                        erased = prev.erased; edits += 1; status = "undone"
                    }
                } label: { Image(systemName: "arrow.uturn.backward") }
                    .help("Undo the last change")
                    .disabled(undoStack.isEmpty)

                Button("Restore all") {
                    undoStack.append((marked, erased))
                    marked = [Bool](repeating: false, count: marked.count)
                    baseMarked = marked
                    erased = [Bool](repeating: false, count: erased.count)
                    strokes.removeAll()
                    edits += 1
                    status = "all faces restored"
                }
                .help("Bring back every deleted face")
                .disabled(!erased.contains(true) && !marked.contains(true))

                Spacer()

                Button(role: .destructive) {
                    deleteMarked()
                } label: { Label("Delete Marked", systemImage: "trash") }
                    .disabled(!marked.contains(true))

                Button {
                    apply()
                } label: { Label("Apply", systemImage: "checkmark.circle") }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(busy || meshURL == nil)
            }

            Text(lasso
                 ? "Drag a box to mark everything inside it; shift-drag unmarks. Turn Lasso off "
                   + "to orbit again."
                 : mode.hint + "  Magenta shows what a click would take; click marks it red; "
                   + "shift-click unmarks.")
                .font(.caption2).foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(12)
    }

    /// A slider with its name on the left and its value on the right, so nothing has to be
    /// guessed at from the knob position.
    private func labelled(_ name: String, _ value: String,
                          @ViewBuilder _ slider: () -> some View) -> some View {
        HStack(spacing: 6) {
            Text(name).font(.caption).foregroundStyle(.secondary).fixedSize()
            slider().frame(minWidth: 80)
            Text(value).font(.caption).monospacedDigit().fixedSize()
                .frame(minWidth: 30, alignment: .leading)
        }
    }

    /// What the current mode would take from the face under the cursor.
    private func previewHover(_ packed: Int?) {
        guard let packed, let mesh = meshURL, let t = topology else {
            hover = []; hoverSeed = -1; return
        }
        let element = packed >> 24, face = packed & 0xFFFFFF
        guard let f = MeshViewer.meshFace(mesh: mesh, element: element, face: face),
              f < t.faceCount else { hover = []; hoverSeed = -1; return }
        guard f != hoverSeed else { return }
        hoverSeed = f
        let raw: [Bool]
        switch mode {
        case .shell:
            raw = MeshEraser.connectedComponent(from: f, topology: t)
        case .region:
            raw = GlassSelection.flood(from: f, topology: t, creaseDegrees: crease)
        case .sphere:
            guard let g = geometry else { hover = []; return }
            let i = Int(g.faces[f * 3])
            let c = SIMD3(g.vertices[i*3], g.vertices[i*3+1], g.vertices[i*3+2])
            raw = MeshEraser.sphere(centre: c, radius: Float(radius),
                                    vertices: g.vertices, faces: g.faces)
        }
        guard let g = geometry,
              let region = MeshEraser.capped(raw, vertices: g.vertices, faces: g.faces,
                                             meshDiagonal: meshDiagonal, maxFraction: maxSize)
        else { hover = []; return }
        var out = [Int]()
        out.reserveCapacity(1024)
        for i in 0 ..< region.count where region[i] { out.append(i) }
        hover = out
    }

    private func mark(_ packed: Int, unmark: Bool) {
        guard let mesh = meshURL, let t = topology else { return }
        let element = packed >> 24, face = packed & 0xFFFFFF
        guard let f = MeshViewer.meshFace(mesh: mesh, element: element, face: face),
              f < t.faceCount else { return }
        undoStack.append((marked, erased))
        hoverSeed = -1                    // settings may have moved since the hover was drawn
        let before = strokes.count
        strokes.append(Stroke(seed: f, mode: mode, add: !unmark))
        recompute()
        if hover.isEmpty, maxSize < 0.999, strokes.count > before {
            status = "that piece is bigger than the size cap — raise Max size to take it"
        }
    }

    /// Re-run every stroke at the current settings, then close the gaps.
    private func recompute() {
        guard let t = topology else { return }
        var m = baseMarked.count == t.faceCount
            ? baseMarked : [Bool](repeating: false, count: t.faceCount)
        for st in strokes {
            let raw: [Bool]
            switch st.mode {
            case .shell:
                raw = MeshEraser.connectedComponent(from: st.seed, topology: t)
            case .region:
                raw = GlassSelection.flood(from: st.seed, topology: t, creaseDegrees: crease)
            case .sphere:
                guard let g = geometry else { continue }
                let i = Int(g.faces[st.seed * 3])
                let c = SIMD3(g.vertices[i*3], g.vertices[i*3+1], g.vertices[i*3+2])
                raw = MeshEraser.sphere(centre: c, radius: Float(radius),
                                        vertices: g.vertices, faces: g.faces)
            }
            guard let g = geometry,
                  let region = MeshEraser.capped(raw, vertices: g.vertices, faces: g.faces,
                                                 meshDiagonal: meshDiagonal, maxFraction: maxSize)
            else { continue }
            var e = MeshEraser(deleted: m)
            if st.add { e.add(region) } else { e.remove(region) }
            m = e.deleted
        }
        if fill >= 1 {
            // Graph fill first — cheap and exact where the mesh is properly connected — then a
            // spatial pass for the isolated triangles that have no neighbours to fill through.
            m = MeshEraser.fillGaps(m, topology: t, rounds: Int(fill))
            if let g = geometry {
                m = MeshEraser.spatialFill(m, vertices: g.vertices, faces: g.faces,
                                           strength: fill)
            }
        }
        if smooth >= 1 {
            m = MeshEraser.smoothEdge(m, topology: t, rounds: Int(smooth))
        }
        marked = m
        edits += 1
        let n = m.lazy.filter { $0 }.count
        status = n == 0 ? "nothing marked" : "\(n) faces marked — Delete Marked to remove"
    }

    /// Everything inside the dragged box, subject to the size cap.
    private func lassoPick(_ rect: CGRect, _ project: (SIMD3<Float>) -> CGPoint?,
                           remove: Bool) {
        guard let t = topology, let g = geometry else { return }
        let hit = MeshEraser.lasso(rect: rect, project: project, topology: t,
                                   vertices: g.vertices, faces: g.faces,
                                   meshDiagonal: meshDiagonal, maxFraction: maxSize)
        guard hit.contains(true) else {
            status = maxSize < 0.999
                ? "nothing in the box under the size cap — raise Max size to take bigger pieces"
                : "nothing in the box"
            return
        }
        undoStack.append((marked, erased))
        var e = MeshEraser(deleted: baseMarked.count == t.faceCount
                           ? baseMarked : [Bool](repeating: false, count: t.faceCount))
        if remove { e.remove(hit) } else { e.add(hit) }
        baseMarked = e.deleted
        recompute()
    }

    private func deleteMarked() {
        undoStack.append((marked, erased))
        var e = MeshEraser(deleted: erased)
        e.add(marked)
        erased = e.deleted
        marked = [Bool](repeating: false, count: marked.count)
        baseMarked = marked
        strokes.removeAll()
        edits += 1
        status = "\(e.count) faces deleted"
    }

    private func load() async {
        guard let mesh = meshURL else { status = "no mesh"; return }
        busy = true; defer { busy = false }
        status = "reading mesh…"
        let result: (GlassSelection.Topology, [Float], [UInt32], [Bool])? =
            await Task.detached(priority: .userInitiated) {
                guard let g = PoseSnap.loadTMesh(mesh) else { return nil }
                let t = GlassSelection.topology(vertices: g.vertices, faces: g.faces)
                let existing = MeshEraser.load(forMesh: mesh)?.deleted
                return (t, g.vertices, g.faces,
                        existing?.count == t.faceCount
                            ? existing! : [Bool](repeating: false, count: t.faceCount))
            }.value
        guard let (t, v, f, e) = result else { status = "couldn't read the mesh"; return }
        topology = t; geometry = (v, f); erased = e
        meshDiagonal = MeshEraser.meshDiagonal(vertices: v)
        marked = [Bool](repeating: false, count: t.faceCount)
        baseMarked = marked
        status = e.contains(true) ? "\(e.lazy.filter { $0 }.count) faces erased"
                                  : "\(t.faceCount) faces, nothing erased"
    }

    private func autoLoose() async {
        guard let t = topology, let g = geometry else { return }
        busy = true; defer { busy = false }
        status = "looking for floating pieces…"
        // With the cap off there is still a ceiling — otherwise a genuinely detached wheel or
        // door mirror counts as debris. 5% of the model is about the size of a wing mirror.
        let ceiling = maxSize > 0.999 ? 0.05 : maxSize
        let d = meshDiagonal
        let found: (mask: [Bool], pieces: Int) = await Task.detached(priority: .userInitiated) {
            MeshEraser.floatingPieces(topology: t, vertices: g.vertices, faces: g.faces,
                                      meshDiagonal: d, maxFraction: ceiling)
        }.value
        undoStack.append((marked, erased))
        strokes.removeAll()          // a found set is not a stroke; sliders do not re-derive it
        var m = MeshEraser(deleted: marked)
        m.add(found.mask)
        baseMarked = m.deleted       // so the Fill and Crease sliders refine it rather than wipe it
        marked = m.deleted
        edits += 1
        status = found.pieces == 0
            ? "no floating pieces under \(Int(ceiling * 100))% of the model"
            : "\(found.pieces) floating piece(s) marked — check, then Delete Marked"
    }

    private func apply() {
        guard let mesh = meshURL else { return }
        if erased.contains(true) {
            MeshEraser(deleted: erased).save(forMesh: mesh)
            status = "applied — \(erased.lazy.filter { $0 }.count) faces hidden"
        } else {
            MeshEraser.clear(forMesh: mesh)
            status = "cleared"
        }
        runtime.rebakeTick += 1
    }
}
