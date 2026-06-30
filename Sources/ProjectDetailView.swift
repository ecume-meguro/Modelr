import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Image input and 3D output. Side-by-side when there's room, stacked when narrow,
/// so nothing ever gets clipped.
struct ProjectDetailView: View {
    @Environment(ProjectStore.self) private var store
    let project: Project
    @State private var objectLoading = false
    @State private var showSettings = false
    @State private var showHistory = false
    @State private var showPaintSettings = false
    @State private var editorInputs: MaskEditorInputs?

    // Touch-up editor state (controls live in the top toolbar while editing).
    @State private var tool: MaskTool = .brush
    @State private var keepMode = false
    @State private var brushRadius: CGFloat = 22
    @StateObject private var maskHolder = MaskCanvasHolder()
    private var isEditingMask: Bool { editorInputs != nil }

    var body: some View {
        GeometryReader { geo in
            // Prefer side-by-side; stack top/bottom only when the detail area gets
            // narrower than a minimum. The active section (paint) keeps 50%, and the
            // image+model pair stays stacked together in their half.
            let narrow = geo.size.width < 720
            let mainAxis = narrow
                ? AnyLayout(VStackLayout(spacing: 0))
                : AnyLayout(HStackLayout(spacing: 0))

            ZStack {
                if paintMode {
                    mainAxis {
                        VStack(spacing: 0) {
                            imagePane.frame(maxWidth: .infinity, maxHeight: .infinity)
                            Divider()
                            outputPane.frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        Divider()
                        paintPane.frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                } else {
                    mainAxis {
                        imagePane.frame(maxWidth: .infinity, maxHeight: .infinity)
                        Divider()
                        outputPane.frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }

                if let inputs = editorInputs {
                    MaskEditorOverlay(inputs: inputs, holder: maskHolder,
                                      tool: tool, keepMode: keepMode, brushRadius: brushRadius)
                        .transition(.opacity)
                }
            }
            .animation(.easeInOut(duration: 0.2), value: editorInputs?.id)
            .animation(.easeInOut(duration: 0.25), value: paintMode)
        }
        .navigationTitle(project.name)
        .toolbar {
            if isEditingMask { editToolbar } else { normalToolbar }
        }
    }

    /// Show the paint strip while painting, on a paint error, or when viewing a paint
    /// version (so its texture is visible without replacing the shape model).
    private var paintMode: Bool {
        if store.isPainting(project.id) { return true }
        if case .failed = store.paintStatus(for: project.id) { return true }
        return project.currentGeneration?.kind == .paint
    }

    private var imagePane: some View {
        ZStack(alignment: .topTrailing) {
            ImageDropView(imageURL: store.imageURL(for: project),
                          reloadKey: store.inputVersion(project.id)) { dropped in
                switch dropped {
                case .url(let url):   store.setImage(fromURL: url, for: project.id)
                case .image(let img): store.setImage(img, for: project.id)
                }
            }
            if store.imageURL(for: project) != nil {
                if !project.removeBackground {
                    badge("Remove background?", system: "person.crop.rectangle.badge.xmark", prominent: true) {
                        store.setRemoveBackground(true, for: project.id)
                    }
                    .padding(14)
                    .transition(.move(edge: .top).combined(with: .opacity))
                } else {
                    badge("Touch up removal?", system: "paintbrush.pointed", prominent: false) {
                        if let (original, mask) = store.maskEditingInputs(for: project.id) {
                            editorInputs = MaskEditorInputs(original: original, mask: mask)
                        }
                    }
                    .padding(14)
                    .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
        }
        .animation(.snappy(duration: 0.2), value: project.removeBackground)
    }

    /// The paint process: the streaming 6-view grid while generating, then the
    /// interactive textured mesh once baked.
    private var paintPane: some View {
        ZStack {
            if store.isPainting(project.id) {
                if let grid = store.paintViewsURL(for: project.id) {
                    StreamImage(url: grid)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .padding(16)
                } else {
                    PointCloud().frame(width: 130, height: 130)
                }
            } else if let textured = texturedContent {
                MeshViewer(content: textured)
            }
            paintStatusOverlay
            exportOverlay(meshURL: paintExportSource?.0, texture: paintExportSource?.1)
        }
    }

    /// The interactive textured mesh — only when a paint version is selected.
    private var texturedContent: ViewerContent? {
        guard project.currentGeneration?.kind == .paint else { return nil }
        return store.currentViewerContent(for: project)
    }

    /// The textured mesh + texture to export from the paint viewport (nil while painting).
    private var paintExportSource: (URL, URL)? {
        guard !store.isPainting(project.id),
              case .texturedMesh(let mesh, let tex)? = texturedContent else { return nil }
        return (mesh, tex)
    }

    @ViewBuilder
    private var paintStatusOverlay: some View {
        switch store.paintStatus(for: project.id) {
        case .running(let stage, _, let fraction):
            statusPill(stage, hint: fraction == nil, fraction: fraction)
        case .failed(let message):
            VStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                Text("Paint failed").font(.callout.weight(.medium))
                Text(message).font(.caption2).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center).lineLimit(3)
            }
            .padding(16).frame(maxWidth: 240)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
        case .idle, .done:
            EmptyView()
        }
    }

    // The touch-up tools take over the toolbar while editing — run/quality are
    // irrelevant mid-edit, so they're swapped out rather than shown alongside.
    @ToolbarContentBuilder
    private var editToolbar: some ToolbarContent {
        ToolbarItemGroup {
            Picker("", selection: $tool) {
                Image(systemName: "paintbrush.pointed.fill").tag(MaskTool.brush)
                Image(systemName: "lasso").tag(MaskTool.lasso)
            }
            .pickerStyle(.segmented).help("Brush or lasso")

            Picker("", selection: $keepMode) {
                Image(systemName: "minus").tag(false)
                Image(systemName: "plus").tag(true)
            }
            .pickerStyle(.segmented).help("Remove (−) or keep (+)")

            if tool == .brush {
                HStack(spacing: 6) {
                    Image(systemName: "circle.dotted").foregroundStyle(.secondary).imageScale(.small)
                    Slider(value: $brushRadius, in: 3...90).frame(width: 100)
                }
            }

            Button { maskHolder.canvas?.fit() } label: {
                Image(systemName: "arrow.up.left.and.down.right.magnifyingglass")
            }
            .help("Fit")
        }
        ToolbarItemGroup(placement: .primaryAction) {
            Button { editorInputs = nil } label: { Image(systemName: "xmark") }
                .help("Cancel")
            Button {
                if let mask = maskHolder.canvas?.currentMask() {
                    store.applyEditedMask(mask, for: project.id)
                }
                editorInputs = nil
            } label: { Image(systemName: "checkmark") }
                .buttonStyle(.borderedProminent)
                .help("Apply")
        }
    }

    @ToolbarContentBuilder
    private var normalToolbar: some ToolbarContent {
        // Island 1 — version history
        if !project.generations.isEmpty {
            ToolbarItem(placement: .primaryAction) {
                Button { showHistory = true } label: {
                    Image(systemName: "clock.arrow.circlepath")
                }
                .help("Version history")
                .popover(isPresented: $showHistory, arrowEdge: .bottom) {
                    VersionHistoryView(projectID: project.id, onClose: { showHistory = false })
                        .environment(store)
                }
            }
            if #available(macOS 26.0, *) {
                ToolbarSpacer(.fixed, placement: .primaryAction)
            }
        }

        // Island 2 — SHAPE: section icon + setting · | · action
        ToolbarItem(placement: .primaryAction) {
            HStack(spacing: 12) {
                configButton(settingsLabel, icon: "cube", disabled: store.isRunning(project.id)) {
                    showSettings = true
                }
                .help("Shape model & quality")
                .popover(isPresented: $showSettings, arrowEdge: .bottom) {
                    ModelSettingsPopover(projectID: project.id).environment(store)
                }
                Divider().frame(height: 18)
                shapeActionButton
            }
            .padding(.horizontal, 10)
        }

        // Island 3 — PAINT: same template, paint-colored action
        if project.currentGeneration != nil {
            if #available(macOS 26.0, *) {
                ToolbarSpacer(.fixed, placement: .primaryAction)
            }
            ToolbarItem(placement: .primaryAction) {
                HStack(spacing: 12) {
                    configButton(paintLabel, icon: "paintpalette", disabled: store.isPainting(project.id)) {
                        showPaintSettings = true
                    }
                    .help("Paint settings")
                    .popover(isPresented: $showPaintSettings, arrowEdge: .bottom) {
                        PaintSettingsPopover(projectID: project.id).environment(store)
                    }
                    Divider().frame(height: 18)
                    paintActionButton
                }
                .padding(.horizontal, 10)
            }
        }
    }

    /// A section's config control: section icon + the current setting, opens a popover.
    /// Identical shape for Shape and Paint so the two islands read consistently.
    private func configButton(_ text: String, icon: String, disabled: Bool,
                              action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon).font(.callout).foregroundStyle(.secondary)
                Text(text).font(.callout.weight(.medium)).foregroundStyle(.primary)
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .disabled(disabled)
        .opacity(disabled ? 0.5 : 1)
    }

    /// A section's primary action: a filled, color-coded capsule. The fill stays on the
    /// capsule, never flooding the toolbar island. Same shape for both sections.
    private func actionPill(_ title: String, _ icon: String, fill: Color,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .labelStyle(.titleAndIcon)
                .font(.callout.weight(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .background(fill, in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    /// Paint config summary for the toolbar (the chosen texture quality).
    private var paintLabel: String {
        project.paintAdvanced ? "Custom" : project.paintQuality.label
    }

    private var paintPink: Color { Color(red: 0.90, green: 0.25, blue: 0.85) }
    private var shapeBlue: Color { Color(red: 0.20, green: 0.50, blue: 0.95) }

    @ViewBuilder
    private var shapeActionButton: some View {
        if store.imageURL(for: project) != nil {
            if store.isRunning(project.id) {
                actionPill("Stop", "stop.fill", fill: .red) { store.cancel(project.id) }
            } else if project.generations.isEmpty {
                actionPill("Generate", "play.fill", fill: shapeBlue) { store.generate(project.id) }
            } else {
                actionPill("Regenerate", "arrow.clockwise", fill: shapeBlue) { store.generate(project.id) }
            }
        }
    }

    @ViewBuilder
    private var paintActionButton: some View {
        if store.isPainting(project.id) {
            actionPill("Stop", "stop.fill", fill: .red) { store.cancelPaint(project.id) }
        } else {
            let off = !PaintConfig.isAvailable || store.isRunning(project.id)
            actionPill("Paint", "paintbrush.fill", fill: paintPink) { store.paint(project.id) }
                .disabled(off)
                .opacity(off ? 0.45 : 1)
                .help(PaintConfig.isAvailable ? "Generate a texture" : "Paint model not found")
        }
    }

    /// App-styled corner badge (rounded, material/accent, padded) for the image pane.
    private func badge(_ title: String, system: String, prominent: Bool,
                       action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: system)
                .font(.callout.weight(.medium))
                .padding(.horizontal, 15)
                .padding(.vertical, 10)
                .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .foregroundStyle(prominent ? Color.white : Color.primary)
        .background(
            prominent ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.ultraThinMaterial),
            in: RoundedRectangle(cornerRadius: 14, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(.white.opacity(prominent ? 0.0 : 0.10))
        )
        .shadow(color: .black.opacity(0.22), radius: 9, y: 3)
    }

    private var outputPane: some View {
        ZStack {
            if let content = displayedContent {
                MeshViewer(content: content, onLoading: { objectLoading = $0 })
            } else if store.isRunning(project.id) {
                PointCloud()                     // animation while loading (no content yet)
                    .frame(width: 150, height: 150)
            }
            statusOverlay
            exportOverlay(meshURL: store.isRunning(project.id) ? nil : store.shapeMeshURL(for: project),
                          texture: nil)
        }
    }

    // MARK: - Export

    /// A floating export menu in the top-right of a viewport. Renders only when there's
    /// a finished mesh to export. `texture` non-nil ⇒ GLB/OBJ embed the painted texture.
    @ViewBuilder
    private func exportOverlay(meshURL: URL?, texture: URL?) -> some View {
        if let meshURL {
            VStack {
                HStack {
                    Spacer()
                    Menu {
                        ForEach(MeshExportFormat.allCases) { fmt in
                            Button {
                                startExport(meshURL: meshURL, texture: texture, format: fmt)
                            } label: {
                                Label(fmt.menuTitle, systemImage: fmt.icon)
                            }
                        }
                    } label: {
                        Image(systemName: "square.and.arrow.up")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.primary)
                            .frame(width: 28, height: 28)
                            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
                                .strokeBorder(.white.opacity(0.12)))
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help("Export model (STL, GLB, OBJ, PLY)")
                }
                Spacer()
            }
            .padding(10)
        }
    }

    private func startExport(meshURL: URL, texture: URL?, format: MeshExportFormat) {
        let panel = NSSavePanel()
        let safe = project.name
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        panel.nameFieldStringValue = "\(safe.isEmpty ? "model" : safe).\(format.ext)"
        if let ut = UTType(filenameExtension: format.ext) { panel.allowedContentTypes = [ut] }
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.title = "Export \(format.ext.uppercased())"
        panel.begin { response in
            guard response == .OK, let dest = panel.url else { return }
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    try MeshExporter.export(meshURL: meshURL, texture: texture, format: format, to: dest)
                    DispatchQueue.main.async { NSWorkspace.shared.activateFileViewerSelecting([dest]) }
                } catch {
                    DispatchQueue.main.async {
                        let alert = NSAlert()
                        alert.messageText = "Export failed"
                        alert.informativeText = "\(error)"
                        alert.runModal()
                    }
                }
            }
        }
    }

    /// The currently-selected shape config (what the next Start/Regenerate will use),
    /// so it updates immediately when you change quality. Full quant is omitted.
    private var settingsLabel: String {
        let s = project.resolvedSettings
        return s.quant == .full ? s.model.label : "\(s.model.label) · \(s.quant.label)"
    }

    /// What to show in the viewer: the streaming point cloud (held briefly after the
    /// run so it's seen complete), else the latest preview mesh, else the final mesh
    /// once the point cloud has been cleared.
    private var displayedContent: ViewerContent? {
        if let points = store.pointsURL(for: project.id) { return .points(points) }
        if let preview = store.previewURL(for: project.id) { return .mesh(preview) }
        // The model pane is always the (untextured) shape geometry.
        if let shape = store.shapeMeshURL(for: project) { return .mesh(shape) }
        return nil
    }

    @ViewBuilder
    private var statusOverlay: some View {
        switch store.status(for: project.id) {
        case .running(let stage, _, let fraction):
            statusPill(stage, hint: fraction == nil, fraction: fraction)

        case .idle, .done:
            // Not generating, but the (large) mesh may still be loading into the view —
            // right after a run finishes, or when switching to another project.
            if objectLoading {
                statusPill("Loading object…", hint: true, fraction: nil)
            }

        case .failed(let message):
            VStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                Text("Couldn't generate")
                    .font(.callout.weight(.medium))
                Text(message)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
            }
            .padding(16)
            .frame(maxWidth: 240)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
        }
    }

    private func statusPill(_ label: String, hint: Bool, fraction: Double?) -> some View {
        VStack {
            Spacer()
            VStack(spacing: 8) {
                Text(label)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                if hint {
                    Text("This can take a few seconds")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                SmoothProgressBar(fraction: fraction)
                    .frame(width: 200, height: 4)
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 14)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
            .padding(.bottom, 22)
        }
    }
}

/// Loads an image from a (changing) URL, decoding only when the path changes — used
/// for the streaming paint view-grid so frequent status re-renders don't re-decode.
private struct StreamImage: View {
    let url: URL
    @State private var image: NSImage?

    var body: some View {
        ZStack {
            if let image {
                Image(nsImage: image).resizable().scaledToFit()
            } else {
                ProgressView()
            }
        }
        .task(id: url.path) {
            image = (try? Data(contentsOf: url)).flatMap(NSImage.init(data:))
        }
    }
}
