import SwiftUI

// MARK: - Project Card

/// Optimized card view for displaying a project in the browser grid
struct ProjectCard: View {
    let project: Project
    let isSelected: Bool
    let action: () -> Void
    let onDelete: () -> Void
    let onRename: () -> Void
    let onDuplicate: () -> Void

    @State private var thumbnailImage: NSImage?
    @State private var isHovered = false

    /// Static date formatter (avoid recreating on every render)
    private static let dateFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter
    }()

    init(
        project: Project,
        isSelected: Bool = false,
        action: @escaping () -> Void,
        onDelete: @escaping () -> Void = {},
        onRename: @escaping () -> Void = {},
        onDuplicate: @escaping () -> Void = {}
    ) {
        self.project = project
        self.isSelected = isSelected
        self.action = action
        self.onDelete = onDelete
        self.onRename = onRename
        self.onDuplicate = onDuplicate
    }

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 0) {
                // Thumbnail area - larger and more prominent
                thumbnailView
                    .frame(height: 160)
                    .frame(maxWidth: .infinity)
                    .background(Color(NSColor.controlBackgroundColor))
                    .clipped()

                // Info area - more spacious and organized
                VStack(alignment: .leading, spacing: AppDesign.Spacing.p8) {
                    Text(project.name)
                        .font(.system(size: AppDesign.FontSize.body, weight: .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    HStack(spacing: AppDesign.Spacing.p8) {
                        workflowBadge
                        
                        Text(formattedDate)
                            .font(.system(size: AppDesign.FontSize.caption))
                            .foregroundStyle(.tertiary)

                        Spacer(minLength: 0)
                    }
                }
                .padding(.horizontal, AppDesign.Spacing.p12)
                .padding(.vertical, AppDesign.Spacing.p12)
            }
            .background(cardBackground)
            .clipShape(RoundedRectangle(cornerRadius: AppDesign.Size.cornerRadiusLarge))
            .overlay {
                RoundedRectangle(cornerRadius: AppDesign.Size.cornerRadiusLarge)
                    .strokeBorder(borderColor, lineWidth: isSelected ? 2 : 1)
            }
            .shadow(color: .black.opacity(isHovered ? 0.12 : 0.04), radius: isHovered ? 12 : 4, y: isHovered ? 6 : 2)
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.2)) {
                isHovered = hovering
            }
        }
        .scaleEffect(isHovered ? 1.01 : 1.0)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isHovered)
        .contextMenu { contextMenuContent }
        .task { await loadThumbnail() }
    }

    // MARK: - Subviews

    @ViewBuilder
    private var thumbnailView: some View {
        ZStack {
            if let image = thumbnailImage {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if project.thumbnailPath != nil {
                // Loading placeholder
                ProgressView()
                    .controlSize(.small)
            } else {
                // No thumbnail placeholder with design system checkerboard
                ZStack {
                    AppDesign.Checkerboard()
                    Image(systemName: "cube.transparent")
                        .font(.system(size: 32, weight: .ultraLight))
                        .foregroundStyle(.quaternary)
                }
            }

            // Hover overlay with quick actions
            if isHovered {
                quickActionsOverlay
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
    }

    @ViewBuilder
    private var quickActionsOverlay: some View {
        VStack {
            Spacer()
            HStack {
                Spacer()
                HStack(spacing: AppDesign.Spacing.p4) {
                    quickActionButton(icon: "pencil", action: onRename)
                    quickActionButton(icon: "doc.on.doc", action: onDuplicate)
                    Divider()
                        .frame(height: 16)
                    quickActionButton(icon: "trash", action: onDelete, destructive: true)
                }
                .padding(AppDesign.Spacing.p6)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: AppDesign.Size.cornerRadius))
                .overlay {
                    RoundedRectangle(cornerRadius: AppDesign.Size.cornerRadius)
                        .strokeBorder(Color.white.opacity(0.1), lineWidth: 0.5)
                }
            }
            .padding(AppDesign.Spacing.p8)
        }
    }

    @ViewBuilder
    private func quickActionButton(icon: String, action: @escaping () -> Void, destructive: Bool = false) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: AppDesign.FontSize.subheadline, weight: .medium))
                .foregroundStyle(destructive ? AppDesign.destructive : .primary)
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(Color.primary.opacity(isHovered ? 0.05 : 0))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    @ViewBuilder
    private var workflowBadge: some View {
        let (icon, color, name) = workflowInfo
        HStack(spacing: AppDesign.Spacing.p4) {
            Image(systemName: icon)
                .font(.system(size: 9, weight: .bold))
            Text(name.uppercased())
                .font(.system(size: 9, weight: .bold))
                .tracking(0.5)
        }
        .foregroundStyle(color)
        .padding(.horizontal, AppDesign.Spacing.p8)
        .padding(.vertical, AppDesign.Spacing.p4)
        .background(color.opacity(0.12), in: Capsule())
    }

    @ViewBuilder
    private var contextMenuContent: some View {
        Button { action() } label: {
            Label("Open Project", systemImage: "folder")
        }

        Divider()

        Button { onRename() } label: {
            Label("Rename", systemImage: "pencil")
        }

        Button { onDuplicate() } label: {
            Label("Duplicate", systemImage: "doc.on.doc")
        }

        Divider()

        Button(role: .destructive) { onDelete() } label: {
            Label("Delete", systemImage: "trash")
        }
    }

    // MARK: - Computed Properties

    private var cardBackground: some ShapeStyle {
        isSelected
            ? AnyShapeStyle(AppDesign.accent.opacity(AppDesign.Opacity.soft))
            : AnyShapeStyle(Color(NSColor.controlBackgroundColor))
    }

    private var borderColor: Color {
        if isSelected {
            return AppDesign.accent
        } else if isHovered {
            return Color.primary.opacity(AppDesign.Opacity.moderate)
        } else {
            return Color.primary.opacity(AppDesign.Opacity.medium)
        }
    }

    private var formattedDate: String {
        Self.dateFormatter.localizedString(for: project.modifiedAt, relativeTo: Date())
    }

    private var workflowInfo: (icon: String, color: Color, name: String) {
        switch project.workflowStep {
        case 1: return ("photo", .secondary, "Input")
        case 2: return ("scissors", .orange, "Segment")
        case 3: return ("cube.fill", .blue, "Generate")
        case 4: return ("checkmark.seal.fill", AppDesign.success, "Done")
        default: return ("checkmark.seal.fill", AppDesign.success, "Done")
        }
    }

    // MARK: - Loading

    private func loadThumbnail() async {
        guard project.thumbnailPath != nil else { return }
        if let image = await ThumbnailCache.shared.thumbnail(for: project.id) {
            self.thumbnailImage = image
        }
    }
}

// MARK: - New Project Card

struct NewProjectCard: View {
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 0) {
                ZStack {
                    AppDesign.Checkerboard()
                        .opacity(0.3)
                    
                    VStack(spacing: AppDesign.Spacing.p16) {
                        ZStack {
                            Circle()
                                .fill(AppDesign.accent.opacity(isHovered ? 0.2 : 0.1))
                                .frame(width: 56, height: 56)
                            
                            Image(systemName: "plus")
                                .font(.system(size: 24, weight: .semibold))
                                .foregroundStyle(AppDesign.accent)
                        }
                        .scaleEffect(isHovered ? 1.1 : 1.0)

                        VStack(spacing: AppDesign.Spacing.p4) {
                            Text("New Project")
                                .font(.system(size: AppDesign.FontSize.headline, weight: .bold))
                            Text("Import image to start")
                                .font(.system(size: AppDesign.FontSize.caption))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .frame(height: 160)
            }
            .background(Color(NSColor.controlBackgroundColor).opacity(0.5))
            .clipShape(RoundedRectangle(cornerRadius: AppDesign.Size.cornerRadiusLarge))
            .overlay {
                RoundedRectangle(cornerRadius: AppDesign.Size.cornerRadiusLarge)
                    .strokeBorder(
                        AppDesign.accent.opacity(isHovered ? 0.4 : 0.2),
                        style: StrokeStyle(lineWidth: 1.5, dash: [6, 4])
                    )
            }
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.2)) {
                isHovered = hovering
            }
        }
        .scaleEffect(isHovered ? 1.01 : 1.0)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isHovered)
    }
}

// MARK: - Example Image Card

struct ExampleImageCard: View {
    let name: String
    let url: URL
    let action: () -> Void

    @State private var isHovered = false
    @State private var loadedImage: NSImage?

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 0) {
                ZStack {
                    if let image = loadedImage {
                        Image(nsImage: image)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        AppDesign.LoadingIndicator(text: "Loading...")
                    }
                }
                .frame(height: 160)
                .background(Color(NSColor.controlBackgroundColor))
                .clipped()

                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(name)
                            .font(.system(size: AppDesign.FontSize.body, weight: .semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        
                        Text("Example Asset")
                            .font(.system(size: AppDesign.FontSize.caption))
                            .foregroundStyle(.tertiary)
                    }

                    Spacer(minLength: 0)

                    Image(systemName: "play.circle.fill")
                        .font(.system(size: 18))
                        .foregroundStyle(AppDesign.accent)
                        .opacity(isHovered ? 1 : 0.5)
                }
                .padding(.horizontal, AppDesign.Spacing.p12)
                .padding(.vertical, AppDesign.Spacing.p12)
            }
            .background(Color(NSColor.controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: AppDesign.Size.cornerRadiusLarge))
            .overlay {
                RoundedRectangle(cornerRadius: AppDesign.Size.cornerRadiusLarge)
                    .strokeBorder(Color.primary.opacity(isHovered ? 0.15 : 0.1), lineWidth: 1)
            }
            .shadow(color: .black.opacity(isHovered ? 0.12 : 0.04), radius: isHovered ? 12 : 4, y: isHovered ? 6 : 2)
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.2)) {
                isHovered = hovering
            }
        }
        .scaleEffect(isHovered ? 1.01 : 1.0)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isHovered)
        .task {
            loadedImage = await ThumbnailCache.shared.exampleImage(named: name, url: url)
        }
    }
}
