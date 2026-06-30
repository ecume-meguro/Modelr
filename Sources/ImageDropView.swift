import SwiftUI
import UniformTypeIdentifiers

enum DroppedImage {
    case url(URL)
    case image(NSImage)
}

/// Minimal image input: a clean preview when set, a subtle dashed target when empty.
struct ImageDropView: View {
    let imageURL: URL?
    var reloadKey: Int = 0
    let onDrop: (DroppedImage) -> Void

    @State private var targeted = false
    @State private var showImporter = false
    @State private var loaded: NSImage?

    /// Re-loads only when the file path or its version changes — not on every render.
    private var cacheKey: String { "\(imageURL?.path ?? "none")#\(reloadKey)" }

    var body: some View {
        ZStack {
            if let image = loaded {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .padding(24)
            } else if imageURL == nil {
                VStack(spacing: 16) {
                    Image(systemName: "photo")
                        .font(.system(size: 34, weight: .light))
                        .foregroundStyle(.secondary)
                    Text("Drag an image, or")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Button { showImporter = true } label: {
                        Label("Choose Image…", systemImage: "photo.badge.plus")
                            .font(.callout.weight(.medium))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)
                            .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .shadow(color: .black.opacity(0.25), radius: 8, y: 3)
                }
            }
        }
        .task(id: cacheKey) {
            loaded = imageURL.flatMap { url in
                (try? Data(contentsOf: url)).flatMap(NSImage.init(data:))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.image]) { result in
            if case .success(let url) = result {
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                onDrop(.url(url))
            }
        }
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(
                    targeted ? Color.accentColor
                             : (imageURL == nil ? Color.secondary.opacity(0.22) : Color.clear),
                    style: StrokeStyle(lineWidth: targeted ? 2 : 1.5,
                                       dash: (imageURL == nil && !targeted) ? [6] : [])
                )
                .padding(18)
                .allowsHitTesting(false)
        }
        .animation(.easeInOut(duration: 0.15), value: targeted)
        .onDrop(of: [.fileURL, .image], isTargeted: $targeted) { providers in
            handleDrop(providers)
        }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }

        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier) { item, _ in
                var url: URL?
                if let data = item as? Data {
                    url = URL(dataRepresentation: data, relativeTo: nil)
                } else if let u = item as? URL {
                    url = u
                }
                if let url, Self.isImageFile(url) {
                    DispatchQueue.main.async { onDrop(.url(url)) }
                }
            }
            return true
        }

        if provider.canLoadObject(ofClass: NSImage.self) {
            _ = provider.loadObject(ofClass: NSImage.self) { object, _ in
                if let image = object as? NSImage {
                    DispatchQueue.main.async { onDrop(.image(image)) }
                }
            }
            return true
        }
        return false
    }

    private static func isImageFile(_ url: URL) -> Bool {
        guard let type = UTType(filenameExtension: url.pathExtension) else { return false }
        return type.conforms(to: .image)
    }
}
