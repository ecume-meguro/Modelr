import SwiftUI

/// Card view for displaying a project in the browser grid
struct ProjectCard: View {
    let project: Project
    let action: () -> Void
    var onRename: (() -> Void)?
    var onDuplicate: (() -> Void)?
    var onDelete: (() -> Void)?

    @State private var thumbnailImage: NSImage?
    @State private var isHovered = false
    @State private var loadedProjectId: UUID?

    /// Static date formatter (avoid recreating on every render)
    private static let dateFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }()

    /// Normalized workflow step (clamped to 1-4)
    private var normalizedStep: Int {
        min(max(project.workflowStep, 1), 4)
    }

    private var isComplete: Bool {
        normalizedStep >= 4
    }

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                // Thumbnail
                thumbnailView
                    .frame(height: 160)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay {
                        RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
                    }

                // Info Area
                VStack(alignment: .leading, spacing: 3) {
                    Text(project.name)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                    // Metadata row - minimal
                    HStack(spacing: 6) {
                        Text(formattedDate)
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)

                        Spacer()

                        // Small status indicator
                        statusIndicator
                    }
                }
            }
            .padding(8)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isHovered ? Color.primary.opacity(0.03) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovered = hovering
        }
        .task(id: project.id) {
            await loadThumbnail()
        }
        .onChange(of: project.id) { _, newId in
            // Reset thumbnail when project changes (view reuse)
            if loadedProjectId != newId {
                thumbnailImage = nil
                loadedProjectId = newId
                Task {
                    await loadThumbnail()
                }
            }
        }
    }

    // MARK: - Status Indicator (minimal)

    @ViewBuilder
    private var statusIndicator: some View {
        if isComplete {
            // Just a small checkmark for completed
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 10))
                .foregroundStyle(.secondary.opacity(0.6))
        } else {
            // Show step progress as subtle text
            Text("Step \(normalizedStep)")
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
        }
    }

    @ViewBuilder
    private var thumbnailView: some View {
        ZStack {
            Color(NSColor.controlBackgroundColor)

            if let image = thumbnailImage {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else if project.thumbnailPath == nil {
                Image(systemName: "cube")
                    .font(.system(size: 24))
                    .foregroundStyle(.secondary.opacity(0.2))
            } else {
                ProgressView()
                    .controlSize(.small)
            }
        }
    }

    private var formattedDate: String {
        Self.dateFormatter.localizedString(for: project.modifiedAt, relativeTo: Date())
    }

    private func loadThumbnail() async {
        // Reset thumbnail if this view is being reused for a different project
        if loadedProjectId != project.id {
            thumbnailImage = nil
            loadedProjectId = project.id
        }

        guard project.thumbnailPath != nil || isComplete else { return }

        if let image = await ThumbnailCache.shared.thumbnail(for: project.id, workflowStep: project.workflowStep) {
            // Only update if this is still the same project (view might have been reused)
            if loadedProjectId == project.id {
                self.thumbnailImage = image
            }
        }
    }
}