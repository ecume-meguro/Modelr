import SwiftUI

/// Pick the glass on the model itself.
///
/// The texture cannot answer this reliably at a window's edge — the atlas is thousands of small
/// UV charts whose seams follow exactly those edges, so a boundary triangle's samples land on
/// frame as readily as on glass. Selecting on the mesh sidesteps the question: a window is a
/// smooth surface bounded by a crease, so a flood that refuses to cross creases has the window's
/// real outline, and the result is an exact set of faces rather than a per-texel guess.
struct GlassEditView: View {
    let project: Project
    @Environment(AppRuntime.self) private var runtime
    @Environment(ProjectStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    /// One click, remembered rather than resolved, so the crease and fill sliders keep working
    /// after the fact — the same model the eraser uses.
    struct Stroke { let seed: Int; let add: Bool }
    @State private var strokes: [Stroke] = []
    @State private var selection: [Bool] = []
    /// A selection that did not come from strokes (auto-select), which the sliders cannot
    /// re-derive and so must not overwrite.
    @State private var baseSelection: [Bool] = []
    @State private var geometry: (vertices: [Float], faces: [UInt32])?
    @State private var topology: GlassSelection.Topology?
    @State private var crease: Double = 32
    @State private var fill: Double = 2
    /// Rings of close applied to the boundary — the sawtooth remover.
    @State private var smooth: Double = 2
    @State private var hover: [Int] = []
    /// The face the hover flood was last computed for — mouse moves arrive far faster than a
    /// flood over a few hundred thousand faces, and the answer only changes when the face does.
    @State private var hoverSeed: Int = -1
    /// Ignore anything bigger than this fraction of the model. Floating debris is tiny and the
    /// panel behind it is not, so a cap lets you sweep up the specks without ever catching the
    /// panel — the one thing that makes clicking through a cloud of them practical.
    @State private var maxSize: Double = 1.0
    @State private var meshDiagonal: Float = 1
    @State private var removing = false
    @State private var edits = 0
    @State private var busy = false
    @State private var canRevert = false
    @State private var canRevertCut = false
    @State private var status = ""

    private var meshURL: URL? {
        switch store.currentViewerContent(for: project) {
        case .pbrMesh(let m, _, _)?:   return m
        case .texturedMesh(let m, _)?: return m
        default:                       return nil
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            MeshViewer(content: store.currentViewerContent(for: project),
                       glassHighlight: selection.isEmpty ? nil : selection,
                       tintGlass: true,
                       hoverFaces: hover,
                       variant: edits,
                       onFacePicked: { packed, shift in pick(packed, unselect: shift) },
                       onFaceHovered: { packed in previewHover(packed) })
                .frame(minHeight: 380)
            Divider()
            controls
        }
        .frame(minWidth: 900, minHeight: 620)
        .task { await load() }
        .onDisappear { if topology != nil { save() } }
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Button {
                    Task { await autoSelect() }
                } label: { Label("Auto-select", systemImage: "wand.and.stars") }
                    .disabled(busy || topology == nil)

                Picker("", selection: $removing) {
                    Label("Add", systemImage: "plus").tag(false)
                    Label("Remove", systemImage: "minus").tag(true)
                }
                .pickerStyle(.segmented).fixedSize()

                Spacer()
                if busy { ProgressView().controlSize(.small) }
                Text(status).font(.caption).foregroundStyle(.secondary)
                    .lineLimit(2).frame(maxWidth: 260, alignment: .trailing)
            }

            HStack(spacing: 16) {
                labelled("Crease", "\(Int(crease))°") {
                    Slider(value: $crease, in: 15...75, step: 1)
                        .onChange(of: crease) { _, _ in recompute() }
                        .disabled(strokes.isEmpty)
                }
                labelled("Fill", "\(Int(fill))") {
                    Slider(value: $fill, in: 0...8, step: 1)
                        .onChange(of: fill) { _, _ in recompute() }
                        .disabled(strokes.isEmpty && !baseSelection.contains(true))
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
                .help("Ignore anything wider than this share of the model")
            }

            HStack(spacing: 10) {
                Button {
                    guard let t = topology else { return }
                    baseSelection = MeshEraser.grow(selection, topology: t)
                    strokes.removeAll(); selection = baseSelection; edits += 1
                    status = "\(selection.lazy.filter { $0 }.count) faces selected (grown)"
                } label: { Image(systemName: "plus.magnifyingglass") }
                    .help("Grow the selection by one ring of faces")
                    .disabled(busy || !selection.contains(true))

                Button {
                    guard let t = topology else { return }
                    baseSelection = MeshEraser.shrink(selection, topology: t)
                    strokes.removeAll(); selection = baseSelection; edits += 1
                    status = "\(selection.lazy.filter { $0 }.count) faces selected (shrunk)"
                } label: { Image(systemName: "minus.magnifyingglass") }
                    .help("Shrink the selection by one ring of faces")
                    .disabled(busy || !selection.contains(true))

                Button {
                    refineEdge()
                } label: { Label("Refine Edge", systemImage: "scissors") }
                    .help("Re-cut the mesh so the glass boundary follows the painted window edge "
                          + "as a smooth curve, instead of stepping along triangle edges")
                    .disabled(busy || meshURL == nil)

                Button {
                    cleanGlass()
                } label: { Label("Clean Glass", systemImage: "sparkles") }
                    .help("Repaint the selected glass in the atlas with this car's own glass "
                          + "colour, removing interior colour bled onto the windows")
                    .disabled(busy || !selection.contains(true))

                Menu("Revert") {
                    Button("Undo Clean Glass") { revertGlass() }
                        .disabled(!canRevert)
                    Button("Undo Refine Edge") { revertCut() }
                        .disabled(!canRevertCut)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Put back the atlas, or the mesh, as it was before the last operation")
                .disabled(busy || (!canRevert && !canRevertCut))

                Button("Clear") {
                    selection = [Bool](repeating: false, count: selection.count)
                    baseSelection = selection
                    strokes.removeAll()
                    edits += 1
                    status = "cleared"
                }
                .disabled(busy || selection.isEmpty)

                Spacer()

                Button {
                    save()
                } label: { Label("Apply to Model", systemImage: "checkmark.circle") }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(busy || meshURL == nil)
            }

            Text("Magenta shows what a click would take; click selects it in cyan; shift-click "
                 + "deselects. Crease and Fill re-derive the selection as you move them.")
                .font(.caption2).foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(12)
    }

    /// A slider with its name on the left and its value on the right.
    private func labelled(_ name: String, _ value: String,
                          @ViewBuilder _ slider: () -> some View) -> some View {
        HStack(spacing: 6) {
            Text(name).font(.caption).foregroundStyle(.secondary).fixedSize()
            slider().frame(minWidth: 80)
            Text(value).font(.caption).monospacedDigit().fixedSize()
                .frame(minWidth: 30, alignment: .leading)
        }
    }

    /// What a click would take, shown in magenta before committing to it.
    private func previewHover(_ packed: Int?) {
        guard let packed, let mesh = meshURL, let t = topology else {
            hover = []; hoverSeed = -1; return
        }
        let element = packed >> 24, face = packed & 0xFFFFFF
        guard let f = MeshViewer.meshFace(mesh: mesh, element: element, face: face),
              f < t.faceCount else { hover = []; hoverSeed = -1; return }
        guard f != hoverSeed else { return }
        hoverSeed = f
        let flooded = GlassSelection.flood(from: f, topology: t, creaseDegrees: crease)
        guard let g = geometry,
              let region = MeshEraser.capped(flooded, vertices: g.vertices, faces: g.faces,
                                             meshDiagonal: meshDiagonal, maxFraction: maxSize)
        else { hover = []; return }
        var out = [Int](); out.reserveCapacity(1024)
        for i in 0 ..< region.count where region[i] { out.append(i) }
        hover = out
    }

    private func pick(_ packed: Int, unselect: Bool) {
        guard let mesh = meshURL, let t = topology else { return }
        let element = packed >> 24, face = packed & 0xFFFFFF
        guard let f = MeshViewer.meshFace(mesh: mesh, element: element, face: face),
              f < t.faceCount else { return }
        strokes.append(Stroke(seed: f, add: !(removing || unselect)))
        hoverSeed = -1                    // the crease may have moved since the hover was drawn
        recompute()
        if hover.isEmpty, maxSize < 0.999 {
            status = "that surface is bigger than the size cap — raise Max size to take it"
        }
    }

    /// Re-run every stroke at the current crease, then close the gaps at the current fill.
    private func recompute() {
        guard let t = topology else { return }
        var m = baseSelection.count == t.faceCount
            ? baseSelection : [Bool](repeating: false, count: t.faceCount)
        for st in strokes {
            let flooded = GlassSelection.flood(from: st.seed, topology: t, creaseDegrees: crease)
            guard let g = geometry,
                  let region = MeshEraser.capped(flooded, vertices: g.vertices, faces: g.faces,
                                                 meshDiagonal: meshDiagonal, maxFraction: maxSize)
            else { continue }
            var sel = GlassSelection(mask: m)
            if st.add { sel.add(region) } else { sel.remove(region) }
            m = sel.mask
        }
        if fill >= 1 {
            m = MeshEraser.fillGaps(m, topology: t, rounds: Int(fill))
            if let g = geometry {
                m = MeshEraser.spatialFill(m, vertices: g.vertices, faces: g.faces, strength: fill)
            }
        }
        if smooth >= 1 {
            m = MeshEraser.smoothEdge(m, topology: t, rounds: Int(smooth))
        }
        selection = m
        edits += 1
        let n = m.lazy.filter { $0 }.count
        status = n == 0 ? "nothing selected" : "\(n) faces selected"
    }

    private func load() async {
        guard let mesh = meshURL else { status = "no painted mesh"; return }
        busy = true; defer { busy = false }
        status = "reading mesh…"
        let result: (GlassSelection.Topology, [Float], [UInt32], [Bool])? =
            await Task.detached(priority: .userInitiated) {
                guard let g = PoseSnap.loadTMesh(mesh) else { return nil }
                let t = GlassSelection.topology(vertices: g.vertices, faces: g.faces)
                let existing = GlassSelection.load(forMesh: mesh)?.mask
                return (t, g.vertices, g.faces, existing?.count == t.faceCount
                        ? existing! : [Bool](repeating: false, count: t.faceCount))
            }.value
        guard let (t, v, f, sel) = result else { status = "couldn't read the mesh"; return }
        topology = t
        geometry = (v, f)
        meshDiagonal = MeshEraser.meshDiagonal(vertices: v)
        selection = sel
        baseSelection = sel
        canRevert = textureURL.map { GlassClean.hasBackup(texture: $0) } ?? false
        canRevertCut = MeshCut.hasBackup(forMesh: mesh)
        status = sel.contains(true) ? "\(sel.lazy.filter { $0 }.count) faces selected"
                                    : "nothing selected yet"
    }

    private func autoSelect() async {
        guard let mesh = meshURL, let gen = project.currentGeneration,
              let texName = gen.paintedTextureFileName else { return }
        let texture = store.folder(for: project.id).appendingPathComponent(texName)
        let creaseNow = crease
        busy = true; defer { busy = false }
        status = "finding glass…"
        let mask: [Bool]? = await Task.detached(priority: .userInitiated) {
            guard let g = PoseSnap.loadTMeshWithUVs(mesh) else { return nil }
            return GlassSelection.autoSelect(vertices: g.vertices, faces: g.faces,
                                             texture: texture, uvs: g.uvs,
                                             creaseDegrees: creaseNow).mask
        }.value
        guard let mask else { status = "auto-select failed"; return }
        baseSelection = mask
        strokes.removeAll()
        selection = mask
        edits += 1
        status = "\(mask.lazy.filter { $0 }.count) faces selected"
    }

    private var textureURL: URL? {
        guard let gen = project.currentGeneration, let n = gen.paintedTextureFileName else { return nil }
        return store.folder(for: project.id).appendingPathComponent(n)
    }

    private var mrURL: URL? {
        guard let gen = project.currentGeneration, let n = gen.paintedMRFileName else { return nil }
        return store.folder(for: project.id).appendingPathComponent(n)
    }

    /// Repaint the glass in the finished atlas — no re-bake, no repaint of anything else.
    private func cleanGlass() {
        guard let mesh = meshURL, let tex = textureURL else { return }
        // Save first: the clean works off the stored selection, and it would be a trap for the
        // on-screen selection and the cleaned texels to disagree.
        GlassSelection(mask: selection).save(forMesh: mesh)
        let mask = selection, mr = mrURL
        busy = true
        status = "cleaning glass…"
        Task {
            let r = await Task.detached(priority: .userInitiated) {
                GlassClean.clean(mesh: mesh, texture: tex, mr: mr, glass: mask)
            }.value
            busy = false
            canRevert = GlassClean.hasBackup(texture: tex)
            if let r {
                status = "cleaned \(r.texels) texels to rgb "
                       + "(\(r.colour.x), \(r.colour.y), \(r.colour.z))"
                runtime.rebakeTick += 1
                edits += 1
            } else {
                status = "clean failed"
            }
        }
    }

    /// Re-cut the mesh so the boundary is a curve rather than a staircase.
    ///
    /// This rewrites the painted mesh, which sounds drastic and is not: new vertices get UVs
    /// interpolated along the edge they split, so every existing texel still lands where it did
    /// and the atlas needs no re-bake. The previous mesh is kept beside it.
    private func refineEdge() {
        guard let mesh = meshURL else { return }
        GlassSelection(mask: selection).save(forMesh: mesh)
        let mask = selection
        let tex = textureURL
        busy = true
        status = "re-cutting the boundary…"
        Task {
            let done = await Task.detached(priority: .userInitiated) { () -> (Int, Int)? in
                guard let full = MeshCut.loadFull(mesh) else { return nil }
                // Prefer the atlas's own alpha: it describes the same window edge per texel
                // rather than per triangle, so the cut lands on the boundary the paint actually
                // has. The face selection is the fallback when there is no alpha to read.
                var field: [Float]?
                if let tex {
                    field = MeshCut.alphaField(texture: tex, vertices: full.vertices,
                                               uvs: full.uvs, faces: full.faces,
                                               cut: MeshCut.alphaCut(texture: tex))
                }
                guard let cut = MeshCut.cut(vertices: full.vertices, normals: full.normals,
                                            uvs: full.uvs, faces: full.faces, inside: mask,
                                            smoothing: field == nil ? 12 : 16,
                                            field: field, preserveArea: true)
                else { return nil }
                let backup = mesh.deletingPathExtension().appendingPathExtension("precut.tmesh")
                if !FileManager.default.fileExists(atPath: backup.path) {
                    try? FileManager.default.copyItem(at: mesh, to: backup)
                }
                guard MeshCut.save(vertices: cut.vertices, normals: cut.normals, uvs: cut.uvs,
                                   faces: cut.faces, to: mesh) else { return nil }
                GlassSelection(mask: cut.inside).save(forMesh: mesh)
                // Face indices all changed, so anything else keyed to them has to come along.
                if let old = MeshEraser.load(forMesh: mesh)?.deleted {
                    var remapped = [Bool](repeating: false, count: cut.parent.count)
                    for i in 0 ..< cut.parent.count where cut.parent[i] < old.count {
                        remapped[i] = old[cut.parent[i]]
                    }
                    MeshEraser(deleted: remapped).save(forMesh: mesh)
                }
                return (cut.faces.count / 3, cut.inside.lazy.filter { $0 }.count)
            }.value
            busy = false
            guard let done else { status = "re-cut failed"; return }
            strokes.removeAll()
            await load()
            runtime.rebakeTick += 1
            edits += 1
            canRevertCut = true
            status = "boundary re-cut from the painted alpha — \(done.0) faces, \(done.1) glass"
        }
    }

    private func revertCut() {
        guard let mesh = meshURL else { return }
        guard MeshCut.revert(mesh: mesh) else { status = "nothing to undo"; return }
        strokes.removeAll()
        canRevertCut = false
        Task {
            await load()
            runtime.rebakeTick += 1
            edits += 1
            status = "mesh restored — the glass selection was cleared with it"
        }
    }

    private func revertGlass() {
        guard let tex = textureURL else { return }
        if GlassClean.revert(texture: tex, mr: mrURL) {
            status = "atlas reverted"
            canRevert = false
            runtime.rebakeTick += 1
            edits += 1
        }
    }

    private func save() {
        guard let mesh = meshURL else { return }
        if selection.contains(true) {
            GlassSelection(mask: selection).save(forMesh: mesh)
            // Chosen by a person, so the finishing pass must not re-derive over it.
            try? FileManager.default.removeItem(
                at: mesh.deletingLastPathComponent().appendingPathComponent(
                    mesh.deletingPathExtension().lastPathComponent + "_glass.derived"))
            status = "applied"
        } else {
            GlassSelection.clear(forMesh: mesh)
            status = "selection cleared"
        }
        runtime.rebakeTick += 1          // force the viewers to reload with the new split
    }
}
