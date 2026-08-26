import SwiftUI
import UniformTypeIdentifiers
import ImageIO
import SceneKit

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
    /// `capture()` used to fail silently on a bad pose read — nothing written, nothing said, so
    /// "I clicked Capture and nothing happened" was indistinguishable from "I never clicked it."
    @State private var captureError: String?
    /// True when the loaded overlay's filename carried a pose tag that was actually applied —
    /// otherwise there's no visible difference between "this auto-aligned" and "the parser
    /// silently gave up," which is exactly the class of bug that shipped once already.
    @State private var autoAligned = false

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

    var body: some View {
        HSplitView {
            sidebar.frame(minWidth: 240, idealWidth: 280)
            aligner.frame(minWidth: 420)
        }
        .frame(minWidth: 820, minHeight: 520)
        .alert("Couldn't capture this view", isPresented: Binding(
            get: { captureError != nil }, set: { if !$0 { captureError = nil } }
        )) {
            Button("OK") { captureError = nil }
        } message: {
            Text(captureError ?? "")
        }
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
                            // reaches, without overriding views that already agree. Ignored
                            // entirely once Override is on — see the toggle below.
                            Slider(value: Binding(
                                get: { v.weight },
                                set: { runtime.setReferenceWeight(project.id, viewID: v.id, weight: $0) }
                            ), in: 0.05...1.0)
                            .disabled(v.overrides)
                            Text(v.overrides ? "overrides canonical"
                                             : String(format: "weight %.2f", v.weight))
                                .font(.caption2).foregroundStyle(.tertiary).monospacedDigit()
                        }
                        Button {
                            runtime.setReferenceOverride(project.id, viewID: v.id, overrides: !v.overrides)
                        } label: { Image(systemName: v.overrides ? "checkmark.seal.fill" : "checkmark.seal") }
                            .buttonStyle(.borderless)
                            .foregroundStyle(v.overrides ? Color.accentColor : .secondary)
                            .help(v.overrides
                                  ? "Overriding — wins outright wherever it sees the surface, "
                                    + "even over canonical paint. Click to go back to filling "
                                    + "gaps only."
                                  : "Fills gaps only, at low priority. Click to make this view "
                                    + "override canonical paint wherever it disagrees.")
                        Button {
                            jumpToPose(v)
                        } label: { Image(systemName: "camera.viewfinder") }
                            .buttonStyle(.borderless)
                            .help("Move the viewer's camera to exactly this view's pose, without "
                                  + "loading it for editing — for a fresh take of the same angle, "
                                  + "e.g. to export and touch up something else visible from here.")
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
            .padding(.horizontal, 12).padding(.bottom, 4)
            Divider().padding(.horizontal, 12)
            HStack(spacing: 8) {
                Button {
                    exportTexture()
                } label: {
                    Label("Export Texture", systemImage: "square.and.arrow.up")
                        .frame(maxWidth: .infinity)
                }
                .disabled(albedoTextureURL == nil)
                .help("Save the raw albedo texture exactly as the model uses it — no camera, "
                      + "no lighting, no reprojection. Edit it directly in its own UV layout.")
                Button {
                    importTexture()
                } label: {
                    Label("Import Texture", systemImage: "square.and.arrow.down")
                        .frame(maxWidth: .infinity)
                }
                .disabled(albedoTextureURL == nil)
                .help("Replace the model's texture with an edited version of the same file. "
                      + "Must be the same pixel dimensions as the export.")
            }
            .padding(.horizontal, 12).padding(.bottom, 12)
        }
    }

    /// The exact file the viewer is currently reading colour from — same for the aligner, the
    /// export, and a direct-edit round trip, so there's never a question of which texture "the
    /// model" means.
    private var albedoTextureURL: URL? {
        switch store.currentViewerContent(for: project) {
        case .pbrMesh(_, let albedo, _)?: return albedo
        case .texturedMesh(_, let tex)?:  return tex
        default:                          return nil
        }
    }

    /// A straight copy of the texture file on disk — not a render of it. Whatever's wrong in the
    /// texture (the ghost eye, the hair-bleed patches) is wrong in exactly these pixels, at
    /// exactly this UV layout; no camera pose, no lighting, no reprojection to go wrong.
    private func exportTexture() {
        guard let src = albedoTextureURL else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(project.name) texture.\(src.pathExtension)"
        panel.allowedContentTypes = [.png]
        panel.message = "Save the model's actual texture — edit it directly, then Import Texture "
            + "to put it back"
        guard panel.runModal() == .OK, let dest = panel.url else { return }
        try? FileManager.default.removeItem(at: dest)
        try? FileManager.default.copyItem(at: src, to: dest)
    }

    /// NSImage.size is point-based (and can differ from the file's real pixel grid); the atlas
    /// mapping cares about actual pixels, so read those straight from the file like
    /// BackgroundRemover does rather than trust NSImage's notion of size.
    private static func pixelDimensions(_ url: URL) -> (w: Int, h: Int)? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int,
              let h = props[kCGImagePropertyPixelHeight] as? Int
        else { return nil }
        return (w, h)
    }

    private static func loadCGImage(_ url: URL) -> CGImage? {
        guard let data = try? Data(contentsOf: url),
              let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(src, 0, nil)
    }

    /// Straight (un-premultiplied) RGBA read from the image's own provider bytes — never
    /// `CGContext.draw()`, which silently flattens alpha to 255 for some PNG encodings this app
    /// writes. Same technique as `MeshViewer.rawRGBA`, duplicated locally since that one's
    /// private to its own file.
    private static func rawRGBA(_ url: URL) -> (w: Int, h: Int, bytes: [UInt8])? {
        guard let cg = loadCGImage(url), cg.bitsPerComponent == 8, cg.bitsPerPixel == 32,
              let provider = cg.dataProvider, let data = provider.data,
              let base = CFDataGetBytePtr(data)
        else { return nil }
        let alphaInfo = cg.alphaInfo
        guard alphaInfo != .none, alphaInfo != .noneSkipLast, alphaInfo != .noneSkipFirst
        else { return nil }
        let alphaFirst = alphaInfo == .premultipliedFirst || alphaInfo == .first
        let premultiplied = alphaInfo == .premultipliedFirst || alphaInfo == .premultipliedLast
        let w = cg.width, h = cg.height, bytesPerRow = cg.bytesPerRow
        var out = [UInt8](repeating: 0, count: w * h * 4)
        let dataLen = CFDataGetLength(data)
        for y in 0 ..< h {
            let rowOffset = y * bytesPerRow
            guard rowOffset + w * 4 <= dataLen else { break }
            let row = base.advanced(by: rowOffset)
            for x in 0 ..< w {
                let s = x * 4, d = (y * w + x) * 4
                let a = row[s + (alphaFirst ? 0 : 3)]
                if premultiplied, a > 0, a < 255 {
                    let inv = 255.0 / Double(a)
                    for c in 0 ..< 3 {
                        let v = Double(row[s + (alphaFirst ? c + 1 : c)]) * inv
                        out[d + c] = UInt8(min(max(v, 0), 255))
                    }
                } else {
                    for c in 0 ..< 3 { out[d + c] = row[s + (alphaFirst ? c + 1 : c)] }
                }
                out[d + 3] = a
            }
        }
        return (w, h, out)
    }

    private static func writeRGBA(_ px: [UInt8], _ w: Int, _ h: Int, to url: URL) -> Bool {
        guard let provider = CGDataProvider(data: Data(px) as CFData),
              let cg = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32,
                               bytesPerRow: w * 4,
                               space: CGColorSpaceCreateDeviceRGB(),
                               bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                               provider: provider, decode: nil, shouldInterpolate: false,
                               intent: .defaultIntent)
        else { return false }
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
        else { return false }
        CGImageDestinationAddImage(dest, cg, nil)
        return CGImageDestinationFinalize(dest)
    }

    /// Composite the edited file over the existing texture using its own alpha as the mask —
    /// alpha 0 keeps canonical exactly as it was, alpha 255 is a full replacement, values between
    /// blend. A straight file swap (what this used to do) would have made every alpha-0 pixel the
    /// edited file's garbage/black instead of "leave this alone," which defeats the entire point
    /// of only touching the specific area that was wrong.
    private func importTexture() {
        guard let dst = albedoTextureURL, let original = Self.pixelDimensions(dst) else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.png]
        panel.message = "Pick the edited texture — must match the original's pixel dimensions. "
            + "Alpha 0 keeps the existing texture there; only opaque pixels replace it."
        guard panel.runModal() == .OK, let picked = panel.urls.first else { return }
        guard let new = Self.pixelDimensions(picked), new.w == original.w, new.h == original.h else {
            captureError = "That image doesn't match the texture's pixel dimensions "
                + "(\(original.w)×\(original.h)) — it has to be an edited copy of the exported "
                + "file, not a different size."
            return
        }
        guard let base = Self.rawRGBA(dst), let edit = Self.rawRGBA(picked) else {
            captureError = "Couldn't read one of those images."
            return
        }
        var out = base.bytes
        for i in stride(from: 0, to: out.count, by: 4) {
            let a = Float(edit.bytes[i + 3]) / 255
            guard a > 0 else { continue }
            for c in 0 ..< 3 {
                out[i + c] = UInt8(Float(edit.bytes[i + c]) * a + Float(base.bytes[i + c]) * (1 - a))
            }
            out[i + 3] = 255   // the texture itself has no meaningful alpha channel of its own
        }
        guard Self.writeRGBA(out, base.w, base.h, to: dst) else {
            captureError = "Couldn't write the composited texture back."
            return
        }
        runtime.rebakeTick += 1
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
                } else if autoAligned {
                    // Otherwise there is no way to tell "this matched its exported pose exactly"
                    // from "the filename tag failed to parse and it's sitting at the default" —
                    // both look identical: a photo, loaded, camera somewhere.
                    VStack {
                        Spacer()
                        Text("Auto-aligned from its exported pose — capture to keep it")
                            .font(.caption).foregroundStyle(.secondary)
                            .padding(6)
                            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 6))
                            .padding(.bottom, 8)
                    }
                    .allowsHitTesting(false)
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
                Button {
                    exportCurrentView()
                } label: { Image(systemName: "square.and.arrow.up") }
                    .help("Export this exact view as an image — rotate to a gap, save it, touch "
                          + "it up in an image editor, then add it back with + as a reference")
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
        guard let url = overlayURL else {
            captureError = "No photo loaded to capture."
            return
        }
        guard let pose = probe.currentPose() else {
            captureError = "Couldn't read the camera's current pose — try nudging the model "
                + "(drag to orbit it slightly) and capture again."
            return
        }
        captureError = nil
        runtime.addReferenceView(project.id, imageURL: url, elev: pose.elev, azim: pose.azim,
                                 scale: scale, offset: offset, fovDeg: fov,
                                 replacing: editingID)
        if pendingQueue.isEmpty {
            // Nothing queued next: stay exactly where the user just aligned things. Only
            // "Skip"/"Cancel" (which call nextPending() directly) should clear the overlay and
            // reframe the camera — capturing successfully is not the same as abandoning this view.
            editingID = nil
        } else {
            nextPending()
        }
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
        autoAligned = false
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

    /// Move the camera to a registered view's exact pose, without loading its photo for editing
    /// — for exporting a fresh take of the same angle rather than replacing that view.
    private func jumpToPose(_ v: ReferenceView) {
        overlay = nil; overlayURL = nil; editingID = nil; autoAligned = false
        scale = 1; offset = .zero; dragStart = .zero
        fov = v.fovDeg
        probe.fovDeg = v.fovDeg
        probe.applyBakeFraming()
        probe.setPose(elev: v.elev, azim: v.azim)
    }

    private func nextPending() {
        overlay = nil; overlayURL = nil; editingID = nil; photoHidden = false
        scale = 1; offset = .zero; dragStart = .zero
        fov = 0; probe.fovDeg = 0; probe.applyBakeFraming(); autoAligned = false
        guard !pendingQueue.isEmpty else { return }
        let next = pendingQueue.removeFirst()
        overlayURL = next
        overlay = NSImage(contentsOf: next)
        // A touched-up re-import of an exported view carries its exact camera in the filename —
        // it was rendered pixel-for-pixel at that pose, so scale/offset need no adjustment, only
        // the camera has to go back where it was.
        if let pose = Self.exportedPose(from: next) {
            fov = pose.fov
            probe.fovDeg = pose.fov
            probe.applyBakeFraming()
            probe.setPose(elev: pose.elev, azim: pose.azim)
            autoAligned = true
        }
        // An ordinary photo, not a pose-tagged re-import, leaves the orbit exactly where it
        // was — the user's own manual control over the camera, not a guessed default.
    }

    private static let poseTag = "__pose_"

    private static func poseFilenameSuffix(elev: Double, azim: Double, fov: Double) -> String {
        String(format: "\(poseTag)e%.2f_a%.2f_f%.2f", elev, azim, fov)
    }

    /// Recover the pose `exportCurrentView` stamped into a filename, if this is a re-import of
    /// one of its exports rather than an unrelated photo.
    private static func exportedPose(from url: URL) -> (elev: Double, azim: Double, fov: Double)? {
        let name = url.deletingPathExtension().lastPathComponent
        guard let r = name.range(of: poseTag) else { return nil }
        // At least 3 tokens, not exactly 3: an image editor's "don't overwrite" save appends its
        // own suffix after the tag ("..._f0.00_2.png", "..._f0.00 copy.png") — the pose is still
        // the first three, whatever trails it is the editor's, not ours.
        let tokens = name[r.upperBound...].split(separator: "_")
        guard tokens.count >= 3,
              tokens[0].hasPrefix("e"), tokens[1].hasPrefix("a"), tokens[2].hasPrefix("f"),
              let elev = Double(tokens[0].dropFirst()),
              let azim = Double(tokens[1].dropFirst()),
              // The fov token itself can carry a glued-on, space-separated suffix ("f0.00 copy")
              // when the editor didn't use an underscore — take only its leading number.
              let fov = Double(tokens[2].dropFirst().prefix { $0.isNumber || $0 == "." || $0 == "-" })
        else { return nil }
        return (elev, azim, fov)
    }

    /// Save exactly what the aligner is showing right now — the live model at whatever angle
    /// it's been rotated to, magenta gaps included when coverage is on. The magenta itself is a
    /// SwiftUI layer behind the model, not part of the scene, so `SCNView.snapshot()` alone
    /// would come back with transparent holes instead — composited back in here so the exported
    /// file matches the screen, ready to touch up externally and re-add as a reference.
    private func exportCurrentView() {
        guard let scnView = probe.view, let pose = probe.currentPose() else { return }
        // Snapshot with flat, unlit shading. `.snapshot()` otherwise captures the live PBR
        // render — ambient light plus SceneKit's automatic headlight — which bakes shading,
        // shadow and specular into the file. Anything exported here is meant to come back as
        // raw paint data (a reference view, or the texture itself); lit pixels reimported as
        // paint come back visibly darker/brighter than the real albedo wherever the live camera
        // angle happened to be shaded, which is not a color correction, it's a lighting one.
        var savedMaterials: [(SCNMaterial, SCNMaterial.LightingModel)] = []
        func collectMaterials(_ node: SCNNode) {
            for m in node.geometry?.materials ?? [] { savedMaterials.append((m, m.lightingModel)) }
            for child in node.childNodes { collectMaterials(child) }
        }
        if let root = scnView.scene?.rootNode { collectMaterials(root) }
        for (m, _) in savedMaterials { m.lightingModel = .constant }
        let shot = scnView.snapshot()
        for (m, original) in savedMaterials { m.lightingModel = original }
        let size = shot.size
        let composited = NSImage(size: size)
        composited.lockFocus()
        if showingThrough {
            NSColor(red: 1, green: 0, blue: 1, alpha: 1).setFill()
            NSRect(origin: .zero, size: size).fill()
        }
        shot.draw(in: NSRect(origin: .zero, size: size))
        composited.unlockFocus()
        guard let tiff = composited.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return }
        let panel = NSSavePanel()
        let suffix = Self.poseFilenameSuffix(elev: pose.elev, azim: pose.azim, fov: fov)
        panel.nameFieldStringValue = "\(project.name) view \(suffix).png"
        panel.allowedContentTypes = [.png]
        panel.message = "Save this view — touch it up and add it back with + to re-align at "
            + "this exact angle automatically (keep the \"\(suffix)\" part of the name)"
        guard panel.runModal() == .OK, let dest = panel.url else { return }
        try? png.write(to: dest)
        NSWorkspace.shared.activateFileViewerSelecting([dest])
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
