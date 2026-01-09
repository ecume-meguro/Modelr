import SwiftUI

/// Card view for displaying a project in the browser grid
struct ProjectCard: View {
    let project: Project
    let action: () -> Void

    @State private var thumbnailImage: NSImage?
    @State private var isHovered = false
    @State private var isLoaded = false

    /// Static date formatter (avoid recreating on every render)
    private static let dateFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }()

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: AppDesign.Spacing.p8) {
                // Thumbnail
                thumbnailView
                    .frame(height: 140)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .overlay {
                        RoundedRectangle(cornerRadius: 12)
                            .strokeBorder(Color.white.opacity(isHovered ? 0.2 : 0), lineWidth: 2)
                    }
                    .shadow(color: .black.opacity(isHovered ? 0.15 : 0.05), radius: isHovered ? 12 : 4, y: isHovered ? 6 : 2)

                // Info
                VStack(alignment: .leading, spacing: AppDesign.Spacing.p2) {
                    Text(project.name)
                        .font(.system(size: AppDesign.FontSize.subheadline, weight: .medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                    Text(formattedDate)
                        .font(.system(size: AppDesign.FontSize.caption))
                        .foregroundStyle(.tertiary)
                }
            }
            .opacity(isLoaded ? 1 : 0)
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.spring(response: 0.2, dampingFraction: 0.8)) {
                isHovered = hovering
            }
        }
        .scaleEffect(isHovered ? 1.03 : 1.0)
        .animation(.spring(response: 0.25, dampingFraction: 0.8), value: isHovered)
        .task {
            await loadThumbnail()
            withAnimation(.easeOut(duration: 0.2)) {
                isLoaded = true
            }
        }
    }

    @ViewBuilder
    private var thumbnailView: some View {
        if let image = thumbnailImage {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .transition(.opacity)
        } else {
            // Skeleton loading state with shimmer
            ZStack {
                Rectangle()
                    .fill(Color.secondary.opacity(0.1))

                if project.thumbnailPath == nil {
                    Image(systemName: "cube.fill")
                        .font(.system(size: 32))
                        .foregroundStyle(.tertiary)
                } else {
                    ShimmerView()
                }
            }
        }
    }

    private var formattedDate: String {
        Self.dateFormatter.localizedString(for: project.modifiedAt, relativeTo: Date())
    }

    private func loadThumbnail() async {
        guard project.thumbnailPath != nil else { return }

        // Use ThumbnailCache for efficient loading
        if let image = await ThumbnailCache.shared.thumbnail(for: project.id) {
            self.thumbnailImage = image
        }
    }
}

// MARK: - Shimmer Loading Effect

struct ShimmerView: View {
    @State private var phase: CGFloat = 0

    var body: some View {
        GeometryReader { geometry in
            Rectangle()
                .fill(
                    LinearGradient(
                        gradient: Gradient(colors: [
                            Color.secondary.opacity(0.1),
                            Color.secondary.opacity(0.2),
                            Color.secondary.opacity(0.1)
                        ]),
                        startPoint: .init(x: phase - 0.5, y: 0),
                        endPoint: .init(x: phase + 0.5, y: 0)
                    )
                )
                .onAppear {
                    withAnimation(.linear(duration: 1.5).repeatForever(autoreverses: false)) {
                        phase = 2
                    }
                }
        }
    }
}
