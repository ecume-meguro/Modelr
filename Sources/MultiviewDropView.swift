import SwiftUI
import UniformTypeIdentifiers

/// The four views the multiview shape model expects, in the order it was trained on.
///
/// The angles are not decoration. Hunyuan3D-2mv tags each view's tokens with a sinusoidal
/// embedding of its *index*, so the model reads slot 1 as "the view 90 degrees round from slot 0".
/// Photographs supplied out of order describe an object that does not exist, and the geometry
/// comes back accordingly — hence naming and illustrating each slot rather than accepting a pile
/// of images.
enum MultiviewSlot: Int, CaseIterable, Identifiable {
    case front = 0, right, back, left

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .front: return "Front"
        case .right: return "Right"
        case .back:  return "Back"
        case .left:  return "Left"
        }
    }

    var angle: String {
        switch self {
        case .front: return "0°"
        case .right: return "90°"
        case .back:  return "180°"
        case .left:  return "270°"
        }
    }

    /// A rough silhouette of the car at this angle, so the required framing is obvious at a
    /// glance rather than something to infer from a label.
    var symbol: String {
        switch self {
        case .front: return "car.front.waves.up.fill"
        case .back:  return "car.rear.fill"
        case .right, .left: return "car.side.fill"
        }
    }

    /// The side views are the same symbol facing opposite ways.
    var mirrored: Bool { self == .left }

    var hint: String {
        switch self {
        case .front: return "Square on to the nose"
        case .right: return "Square on to the passenger side"
        case .back:  return "Square on to the tail"
        case .left:  return "Square on to the driver side"
        }
    }
}

/// Four labelled slots for the multiview shape model.
///
/// The single-image drop target is wrong for this model in a way that is invisible: it accepts
/// one photograph and silently conditions on one view, which is exactly what the single-image
/// models already do. Showing four slots makes both the requirement and the current state legible.
struct MultiviewDropView: View {
    let project: Project
    @Environment(ProjectStore.self) private var store
    @Environment(AppRuntime.self) private var runtime

    var body: some View {
        VStack(spacing: 14) {
            VStack(spacing: 4) {
                Text("Four views of the same object")
                    .font(.callout.weight(.medium))
                Text("Front first, then every 90° clockwise. Missing views are allowed — "
                     + "the model uses what it is given, and more views mean better geometry.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
            }
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 12),
                                GridItem(.flexible(), spacing: 12)], spacing: 12) {
                ForEach(MultiviewSlot.allCases) { slot in
                    SlotTile(project: project, slot: slot)
                }
            }
            .frame(maxWidth: 460)
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct SlotTile: View {
    let project: Project
    let slot: MultiviewSlot
    @Environment(ProjectStore.self) private var store

    @State private var showImporter = false
    @State private var targeted = false
    @State private var thumb: NSImage?

    private var url: URL? { store.multiviewImageURL(project.id, slot: slot.rawValue) }

    var body: some View {
        Button { showImporter = true } label: {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(style: StrokeStyle(lineWidth: 1.5,
                                                     dash: thumb == nil ? [5, 4] : []))
                    .foregroundStyle(targeted ? Color.accentColor
                                     : (thumb == nil ? Color.secondary.opacity(0.4)
                                        : Color.secondary.opacity(0.25)))
                if let thumb {
                    Image(nsImage: thumb).resizable().scaledToFit().padding(8)
                } else {
                    VStack(spacing: 6) {
                        Image(systemName: slot.symbol)
                            .font(.system(size: 30, weight: .light))
                            .scaleEffect(x: slot.mirrored ? -1 : 1)
                            .foregroundStyle(.tertiary)
                        Text(slot.hint)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .multilineTextAlignment(.center)
                    }
                }
                VStack {
                    HStack {
                        Text("\(slot.title) · \(slot.angle)")
                            .font(.caption.weight(.medium))
                            .padding(.horizontal, 7).padding(.vertical, 3)
                            .background(.ultraThinMaterial, in: Capsule())
                        Spacer()
                        if thumb != nil {
                            Button {
                                store.clearMultiviewImage(project.id, slot: slot.rawValue)
                            } label: { Image(systemName: "xmark.circle.fill") }
                                .buttonStyle(.borderless)
                        }
                    }
                    Spacer()
                }
                .padding(8)
            }
            .frame(height: 130)
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .onDrop(of: [.fileURL, .image], isTargeted: $targeted) { providers in
            guard let p = providers.first else { return false }
            _ = p.loadObject(ofClass: URL.self) { u, _ in
                if let u { DispatchQueue.main.async { set(u) } }
            }
            return true
        }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.image]) { result in
            if case .success(let u) = result {
                let scoped = u.startAccessingSecurityScopedResource()
                set(u)
                if scoped { u.stopAccessingSecurityScopedResource() }
            }
        }
        .task(id: url?.path ?? "none") {
            thumb = url.flatMap { (try? Data(contentsOf: $0)).flatMap(NSImage.init(data:)) }
        }
    }

    private func set(_ u: URL) {
        store.setMultiviewImage(fromURL: u, for: project.id, slot: slot.rawValue)
        thumb = (try? Data(contentsOf: u)).flatMap(NSImage.init(data:))
    }
}
