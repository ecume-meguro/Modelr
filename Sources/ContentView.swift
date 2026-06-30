import SwiftUI
import AppKit
import ImageIO

struct ContentView: View {
    @Environment(ProjectStore.self) private var store

    var body: some View {
        @Bindable var store = store
        NavigationSplitView {
            List(selection: $store.selection) {
                ForEach(store.projects) { project in
                    ProjectRow(project: project)
                        .tag(project.id)
                        .contextMenu {
                            Button("Delete", role: .destructive) {
                                store.delete(project.id)
                            }
                        }
                }
            }
            .navigationTitle("Projects")
            .navigationSplitViewColumnWidth(min: 180, ideal: 220)
            .toolbar {
                ToolbarItem {
                    Button {
                        store.newProject()
                    } label: {
                        Label("New Project", systemImage: "plus")
                    }
                    .help("New Project")
                }
            }
            .overlay {
                if store.projects.isEmpty {
                    ContentUnavailableView {
                        Label("No Projects", systemImage: "cube")
                    } description: {
                        Text("Click + to start.")
                    }
                }
            }
        } detail: {
            if let id = store.selection,
               let project = store.projects.first(where: { $0.id == id }) {
                ProjectDetailView(project: project)
                    .id(project.id)
            } else {
                ContentUnavailableView {
                    Label("No Project Selected", systemImage: "cube.transparent")
                } description: {
                    Text("Create a project, then drag in an image.")
                }
            }
        }
    }
}

/// A row in the sidebar: a squircle thumbnail of the project's image + name/status.
struct ProjectRow: View {
    @Environment(ProjectStore.self) private var store
    let project: Project
    @State private var thumb: NSImage?

    private var thumbKey: String {
        "\(store.imageURL(for: project)?.path ?? "none")#\(store.inputVersion(project.id))"
    }

    var body: some View {
        HStack(spacing: 10) {
            thumbnail
            VStack(alignment: .leading, spacing: 1) {
                Text(project.name)
                    .lineLimit(1)
                if case .running(let stage, let detail, _) = store.status(for: project.id) {
                    Text(detail.map { "\(stage) \($0)" } ?? stage)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                } else {
                    Text(subtitle)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
        }
        .padding(.vertical, 2)
        .task(id: thumbKey) {
            let key = thumbKey as NSString
            if let cached = Self.cache.object(forKey: key) { thumb = cached; return }
            let url = store.imageURL(for: project)
            let img = await Task.detached(priority: .utility) { Self.loadThumb(url) }.value
            if let img { Self.cache.setObject(img, forKey: key) }
            if !Task.isCancelled { thumb = img }
        }
    }

    /// Shared, auto-evicting thumbnail cache so scrolling never re-decodes.
    private static let cache = NSCache<NSString, NSImage>()

    private var thumbnail: some View {
        ZStack(alignment: .bottomTrailing) {
            Group {
                if let thumb {
                    Image(nsImage: thumb).resizable().scaledToFill()
                } else {
                    Image(systemName: "photo")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 28, height: 28)
            .background(Color.primary.opacity(0.06))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(.white.opacity(0.08))
            )

            if let dot = statusDot {
                Circle()
                    .fill(dot)
                    .frame(width: 8, height: 8)
                    .overlay(Circle().strokeBorder(Color(NSColor.controlBackgroundColor), lineWidth: 1.5))
                    .offset(x: 3, y: 3)
            }
        }
    }

    private var statusDot: Color? {
        switch store.status(for: project.id) {
        case .running: return .accentColor
        case .failed:  return .yellow
        case .done, .idle: return nil
        }
    }

    private var subtitle: String {
        var s = project.model.label
        if project.quantization != .full { s += " · \(project.quantization.label)" }
        return s
    }

    /// Efficient downsampled thumbnail (decodes to ~72px, not the full image).
    /// nonisolated so it can run on the detached decode task without hopping back.
    private nonisolated static func loadThumb(_ url: URL?) -> NSImage? {
        guard let url, FileManager.default.fileExists(atPath: url.path),
              let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: 72,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }
}
