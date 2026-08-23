import SwiftUI
import UniformTypeIdentifiers

/// Register real photographs against the model so the bake can use them as extra cameras.
///
/// The paint model only ever sees one image, so about a quarter of a car's surface is
/// occluded in all six canonical views and has to be invented. A genuine photograph of those
/// surfaces beats any amount of guessing — but the bake needs to know the camera pose, and a
/// photo doesn't carry one. So the alignment is done by eye: the photo is laid over the live
/// model, you orbit until the silhouettes agree, and the viewer's camera is read back as the
/// pose. That is the whole trick; everything else here is bookkeeping.
struct ReferenceViewsView: View {
    let project: Project
    @Environment(AppRuntime.self) private var runtime
    @Environment(ProjectStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var probe = CameraProbe()
    @State private var overlay: NSImage?
    @State private var overlayURL: URL?
    // Full strength by default. The photo sits behind the model over a magenta backdrop, so at
    // half opacity what shows through a hole is a magenta wash rather than the photograph.
    @State private var opacity: Double = 1
    @State private var scale: Double = 1
    /// 0 = orthographic. Raising it converges the model's edges like a real lens does.
    @State private var fov: Double = 0
    /// Show the coverage atlas instead of the paint, so gaps are obvious while aligning.
    @State private var showCoverage = true
    @State private var snapping = false
    @State private var snapScore: PoseSnap.Result?
    @State private var offset: CGSize = .zero
    @State private var dragStart: CGSize = .zero
    /// Blink the photo off entirely. Displacement between two flashed frames is far easier to
    /// see than in a static blend, so this is the fastest way to judge an alignment.
    @State private var photoHidden = false
    @State private var pendingQueue: [URL] = []
    /// Non-nil while re-aligning an already-registered view; capture then replaces it.
    @State private var editingID: UUID?
    /// Orbit the model, or move the photo? The overlay fills the pane, so a drag can only ever
    /// belong to one of them — with the photo always winning, the model became unreachable.
    @State private var movingPhoto = false

    private var views: [ReferenceView] { runtime.referenceViews(for: project.id) }

    /// The coverage atlas when asked for and available, otherwise the painted model.
    private var viewerContent: ViewerContent? {
        let normal = store.currentViewerContent(for: project)
        guard showCoverage, let cov = runtime.coverageTextureURL(project.id) else { return normal }
        switch normal {
        case .pbrMesh(let mesh, _, _)?:    return .coverageMesh(mesh, cov)
        case .texturedMesh(let mesh, _)?:  return .coverageMesh(mesh, cov)
        default:                           return normal
        }
    }
    private var dir: URL { store.folder(for: project.id) }

    /// True when the model is punched out and the photo belongs behind it rather than on top.
    private var showingThrough: Bool {
        if case .coverageMesh? = viewerContent { return true }
        return false
    }

    private var meshURL: URL? {
        switch store.currentViewerContent(for: project) {
        case .pbrMesh(let m, _, _)?:   return m
        case .texturedMesh(let m, _)?: return m
        case .mesh(let m)?:            return m
        default:                       return nil
        }
    }

    var body: some View {
        HSplitView {
            sidebar.frame(minWidth: 240, idealWidth: 280)
            aligner.frame(minWidth: 420)
        }
        .frame(minWidth: 820, minHeight: 520)
        .onReceive(Timer.publish(every: 0.1, on: .main, in: .common).autoconnect()) { _ in
            probe.sampleForJump()
        }
        .task {
            // The atlas is written by the bake, so a project that has not been re-baked since
            // this feature existed has none. Generate it once, quietly.
            if runtime.coverageTextureURL(project.id) == nil,
               runtime.rebakeStates[project.id] != .running,
               runtime.sheetURLs(for: project.id) != nil {
                runtime.requestRebake(project.id)
            }
        }
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
        }
    }

    // MARK: - list of registered views

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Reference Views").font(.headline)
                Spacer()
                Button {
                    pickImages()
                } label: { Image(systemName: "plus") }
                    .help("Add one or more photographs of this object")
            }
            .padding(12)

            if views.isEmpty && pendingQueue.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("No reference views").foregroundStyle(.secondary)
                    Text("Add photos taken from angles the original image didn't show — "
                         + "interiors, the far side, underneath.")
                        .font(.caption).foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 12)
            }

            List {
                ForEach(views) { v in
                    HStack(spacing: 8) {
                        thumbnail(for: v)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(String(format: "elev %.0f°  azim %.0f°", v.elev, v.azim))
                                .font(.caption).monospacedDigit()
                            // Low by default: a reference should win where nothing else
                            // reaches, without overriding views that already agree.
                            Slider(value: Binding(
                                get: { v.weight },
                                set: { runtime.setReferenceWeight(project.id, viewID: v.id, weight: $0) }
                            ), in: 0.05...1.0)
                            Text(String(format: "weight %.2f", v.weight))
                                .font(.caption2).foregroundStyle(.tertiary).monospacedDigit()
                        }
                        Button {
                            runtime.removeReferenceView(project.id, viewID: v.id)
                        } label: { Image(systemName: "trash") }
                            .buttonStyle(.borderless)
                    }
                    .padding(.vertical, 2)
                    .contentShape(Rectangle())
                    .onTapGesture { beginEdit(v) }
                    .listRowBackground(editingID == v.id
                                       ? Color.accentColor.opacity(0.15) : Color.clear)
                }
            }

            Divider()
            Button {
                runtime.requestRebake(project.id)
            } label: {
                Label(views.isEmpty ? "Re-bake" : "Re-bake with References",
                      systemImage: "arrow.triangle.2.circlepath")
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            .disabled(runtime.rebakeStates[project.id] == .running)
            .padding(.horizontal, 12).padding(.top, 12)
            Button {
                runtime.resetToOriginalPaint(project.id)
            } label: {
                Label("Reset to Original Paint", systemImage: "arrow.uturn.backward")
                    .frame(maxWidth: .infinity)
            }
            .disabled(runtime.originalPaintURLs(project.id) == nil
                      || runtime.rebakeStates[project.id] == .running)
            .help("Discard every re-bake and restore the texture the paint run produced. "
                  + "Reference views are kept.")
            .padding(.horizontal, 12).padding(.bottom, 12)
        }
    }

    @ViewBuilder
    private func thumbnail(for v: ReferenceView) -> some View {
        if let img = NSImage(contentsOf: dir.appendingPathComponent(v.fileName)) {
            Image(nsImage: img).resizable().aspectRatio(contentMode: .fill)
                .frame(width: 44, height: 44).clipped()
                .clipShape(RoundedRectangle(cornerRadius: 4))
        } else {
            RoundedRectangle(cornerRadius: 4).fill(.quaternary).frame(width: 44, height: 44)
        }
    }

    // MARK: - align: photo over the live model

    private var aligner: some View {
        VStack(spacing: 0) {
            // Square on purpose: the bake projects through an orthographic square camera, so
            // aligning in a wider viewport would agree on screen and disagree in the bake.
            ZStack {
                if showingThrough {
                    // Magenta only when there is nothing better to show. With a photo loaded the
                    // holes should reveal the photo, and a magenta layer under a partly
                    // transparent photo just tints it.
                    if overlay == nil || photoHidden {
                        Color(red: 1, green: 0, blue: 1)
                    } else {
                        Color.white
                        photoLayer(overlay!)
                    }
                }
                MeshViewer(content: viewerContent, probe: probe, bakeFraming: true)
                    .id(runtime.rebakeTick)
                if !showingThrough, let overlay { photoLayer(overlay).allowsHitTesting(false) }
                // One transparent layer takes every drag and routes it, instead of relying on
                // hit-testing to decide. The photo can sit in front of the model or behind it
                // depending on the coverage toggle, so "whatever is on top" is not a reliable
                // way to know what the user meant to move.
                dragCatcher
                if overlay == nil {
                    Text("Add a photo, or click a view to re-align it")
                        .foregroundStyle(.secondary)
                }
            }
            .aspectRatio(1, contentMode: .fit)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            VStack(spacing: 8) {
            HStack(spacing: 12) {
                // Outside the "has a photo" gate: this decides how the model itself is drawn, so
                // hiding it until a photo is loaded left no way to turn it off — and no way to
                // tell whether an artefact belongs to the model or to the coverage rendering.
                Toggle(isOn: $showCoverage) {
                    Image(systemName: "square.dashed")
                }
                .toggleStyle(.button)
                .disabled(runtime.coverageTextureURL(project.id) == nil)
                .help("Show which surfaces no view has painted head-on — the only places a "
                      + "reference is allowed to paint")
                if overlay != nil {
                    Picker("", selection: $movingPhoto) {
                        Image(systemName: "rotate.3d").tag(false)
                        Image(systemName: "hand.draw").tag(true)
                    }
                    .pickerStyle(.segmented).fixedSize()
                    .help("Drag to orbit the model, or to move the photo")
                    // The sliders yield first: a narrow window should cost slider travel, not
                    // the button labels, which is what fixed widths here used to do.
                    Button {
                        photoHidden.toggle()
                    } label: {
                        Image(systemName: photoHidden ? "eye.slash" : "eye")
                    }
                    .help("Blink the photo off and on to compare (B)")
                    .keyboardShortcut("b", modifiers: [])
                    Image(systemName: "circle.lefthalf.filled")
                    Slider(value: $opacity, in: 0...1)
                        .frame(minWidth: 44, idealWidth: 110, maxWidth: 110)
                        .help("Overlay opacity")
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                    Slider(value: $scale, in: 0.3...3)
                        .frame(minWidth: 44, idealWidth: 110, maxWidth: 110)
                        .help("Scale the photo to match the model")
                    Button {
                        scale = 1; offset = .zero; dragStart = .zero
                        // Also re-assert the bake framing: orbiting with a scroll wheel changes
                        // the orthographic scale, which silently breaks the match.
                        fov = 0
                        probe.fovDeg = 0
                        probe.applyBakeFraming()
                    } label: { Image(systemName: "arrow.counterclockwise") }
                        .help("Reset fit and framing")
                    Spacer(minLength: 0)
                    if !pendingQueue.isEmpty {
                        Text("\(pendingQueue.count) more to align")
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize()
                    }
                    if let s = snapScore {
                        // Residual is the mean gap between the outlines, as a fraction of the
                        // frame. Shown because a generated mesh differs from the real car by a
                        // few percent, so a perfect fit often does not exist and the user needs
                        // to see whether what they got is as good as it gets.
                        Text(String(format: "%.0f%%", s.iou * 100))
                            .font(.caption).monospacedDigit()
                            .foregroundStyle(s.iou > 0.9 ? .green : (s.iou > 0.75 ? .orange : .red))
                            .help(String(format: "Silhouette overlap %.1f%%, mean edge gap %.2f%% "
                                         + "of frame", s.iou * 100, s.residual * 100))
                            .fixedSize()
                    }
                    Button {
                        snap()
                    } label: {
                        if snapping { ProgressView().controlSize(.small) }
                        else { Image(systemName: "wand.and.stars") }
                    }
                    .disabled(snapping || meshURL == nil)
                    .help("Snap — solve this photo's camera by matching silhouettes, starting "
                          + "from where you have placed it")
                    .fixedSize()
                } else {
                    Spacer()
                }
            }
            HStack(spacing: 12) {
                if overlay != nil {
                    Spacer()
                    Button(editingID == nil ? "Skip" : "Cancel") { nextPending() }
                        .fixedSize()
                    Button {
                        capture()
                    } label: {
                        // Icon only: the bar has to survive a narrow window, and this button's
                        // label was long enough to push everything else off the edge.
                        Image(systemName: "camera.viewfinder")
                    }
                        .keyboardShortcut(.defaultAction)
                        .help(editingID == nil
                              ? "Capture Pose — record this camera angle and fit"
                              : "Update View — replace this reference with the current fit")
                        .fixedSize()
                } else {
                    Spacer()
                }
            }
            }
            .padding(10)
        }
    }

    /// Solve from the user's rough placement. Seeding is not just a speed trick: a car's
    /// silhouette from the front three-quarter and the rear three-quarter are alike enough that
    /// an unseeded search settles on the wrong end of the car.
    private func snap() {
        guard let url = overlayURL, let mesh = meshURL,
              let pose = probe.currentPose() else { return }
        snapping = true
        PoseSnap.fit(meshURL: mesh, imageURL: url, seedElev: pose.elev, seedAzim: pose.azim) { r in
            snapping = false
            guard let r else { snapScore = nil; return }
            snapScore = r
            scale = r.scale
            offset = r.offset
            dragStart = r.offset
            fov = r.fovDeg
            probe.fovDeg = r.fovDeg
            probe.applyBakeFraming()
            probe.setPose(elev: r.elev, azim: r.azim)
        }
    }

    /// Only ever moves the photo. Orbiting belongs to SceneKit, so this takes no hits at all
    /// unless the user has asked to move the photo — intercepting drags to run a hand-written
    /// orbit is what made rotation feel wrong here while the main viewer felt fine.
    private var dragCatcher: some View {
        Color.clear
            .contentShape(Rectangle())
            .allowsHitTesting(movingPhoto)
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { g in
                    // A new gesture starts at ~zero translation; a cancelled one never delivers
                    // onEnded, so detect the start here rather than trusting the reset.
                    if abs(g.translation.width) < 0.5, abs(g.translation.height) < 0.5 {
                        dragStart = offset
                    }
                    offset = CGSize(width: dragStart.width + g.translation.width / 400,
                                    height: dragStart.height + g.translation.height / 400)
                }
                .onEnded { _ in dragStart = offset })
    }

    @ViewBuilder
    private func photoLayer(_ image: NSImage) -> some View {
        GeometryReader { geo in
            Image(nsImage: image)
                .resizable().aspectRatio(contentMode: .fit)
                .scaleEffect(scale)
                .offset(x: offset.width * geo.size.width,
                        y: offset.height * geo.size.height)
                // No clamping. Being able to take the photo to zero and back is the whole way
                // you check a fit — a floor on the opacity made the slider look broken.
                .opacity(photoHidden ? 0 : opacity)
                .frame(width: geo.size.width, height: geo.size.height)
        }
    }

    private func capture() {
        guard let url = overlayURL, let pose = probe.currentPose() else { return }
        runtime.addReferenceView(project.id, imageURL: url, elev: pose.elev, azim: pose.azim,
                                 scale: scale, offset: offset, fovDeg: fov,
                                 replacing: editingID)
        nextPending()
    }

    /// Re-open a registered view: its own image, its stored fit, and the camera put back where
    /// it was when the view was captured. Views added before the original was retained fall back
    /// to their fitted square — re-aligning one refits an already-fitted image, so treat its
    /// scale and offset as a fresh baseline rather than the numbers it was captured with.
    private func beginEdit(_ v: ReferenceView) {
        let original = v.originalFileName.map { dir.appendingPathComponent($0) }
        let url = (original.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil })
            ?? dir.appendingPathComponent(v.fileName)
        guard let img = NSImage(contentsOf: url) else { return }
        let hasOriginal = url != dir.appendingPathComponent(v.fileName)
        editingID = v.id
        snapScore = nil
        overlayURL = url
        overlay = img
        scale = hasOriginal ? v.scale : 1
        fov = hasOriginal ? v.fovDeg : 0
        probe.fovDeg = fov
        offset = hasOriginal ? CGSize(width: v.offsetX, height: v.offsetY) : .zero
        dragStart = offset
        probe.applyBakeFraming()
        probe.setPose(elev: v.elev, azim: v.azim)
    }

    private func nextPending() {
        overlay = nil; overlayURL = nil; editingID = nil; snapScore = nil; photoHidden = false
        scale = 1; offset = .zero; dragStart = .zero
        fov = 0; probe.fovDeg = 0; probe.applyBakeFraming()
        guard !pendingQueue.isEmpty else { return }
        let next = pendingQueue.removeFirst()
        overlayURL = next
        overlay = NSImage(contentsOf: next)
    }

    private func pickImages() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.png, .jpeg, .heic, .tiff]
        panel.message = "Photographs of this object from other angles"
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        pendingQueue = panel.urls
        nextPending()
    }
}
