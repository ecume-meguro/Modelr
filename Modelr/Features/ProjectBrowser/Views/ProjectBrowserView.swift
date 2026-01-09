import SwiftUI
import UniformTypeIdentifiers

/// Main project browser view - shown on app startup
struct ProjectBrowserView: View {
    @StateObject private var projectManager = ProjectManager.shared
    @StateObject private var preloadManager = PreloadManager.shared
    @State private var showingFileImporter = false
    @State private var isDraggingFile = false
    @State private var hasAppeared = false

    /// Cached example images to avoid recomputing
    @State private var cachedExamples: [(name: String, url: URL)] = []

    let onOpenProject: (UUID) -> Void

    private let columns = [
        GridItem(.adaptive(minimum: 180, maximum: 220), spacing: AppDesign.Spacing.p16)
    ]

    var body: some View {
        ZStack {
            // Background
            Color(NSColor.windowBackgroundColor)
                .ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: AppDesign.Spacing.p32) {
                    // Header
                    headerSection

                    // Preload status indicator (subtle)
                    if preloadManager.isPreloading {
                        preloadStatusIndicator
                            .transition(.opacity.combined(with: .move(edge: .top)))
                    }

                    // Recent Projects Section
                    if !projectManager.projects.isEmpty {
                        projectsSection
                            .transition(.opacity.combined(with: .move(edge: .bottom)))
                    }

                    // Example Images Section
                    if !cachedExamples.isEmpty {
                        examplesSection
                            .transition(.opacity.combined(with: .move(edge: .bottom)))
                    }

                    // Empty state
                    if projectManager.projects.isEmpty && cachedExamples.isEmpty && !projectManager.isLoading {
                        emptyStateView
                            .transition(.opacity.combined(with: .scale(scale: 0.95)))
                    }
                }
                .padding(AppDesign.Spacing.p32)
                .animation(.spring(response: 0.4, dampingFraction: 0.85), value: projectManager.projects.count)
                .animation(.spring(response: 0.3, dampingFraction: 0.8), value: preloadManager.isPreloading)
            }

            // Loading overlay (first load only)
            if projectManager.isLoading && !hasAppeared {
                loadingOverlay
                    .transition(.opacity)
            }

            // Drop overlay
            if isDraggingFile {
                dropOverlay
                    .transition(.opacity.combined(with: .scale(scale: 0.98)))
            }
        }
        .frame(minWidth: 600, minHeight: 500)
        .onDrop(of: [.image, .fileURL], isTargeted: $isDraggingFile) { providers in
            handleDrop(providers: providers)
        }
        .fileImporter(
            isPresented: $showingFileImporter,
            allowedContentTypes: [.image],
            allowsMultipleSelection: false
        ) { result in
            handleFileImport(result)
        }
        .task {
            // Load projects
            await projectManager.loadProjects()

            // Cache examples (avoid recomputing in view body)
            cachedExamples = projectManager.getExampleImages()

            // Start preloading ML models and thumbnails
            preloadManager.startPreloading()

            withAnimation(.easeOut(duration: 0.3)) {
                hasAppeared = true
            }
        }
        .animation(.spring(response: 0.25, dampingFraction: 0.9), value: isDraggingFile)
    }

    // MARK: - Header

    @ViewBuilder
    private var headerSection: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: AppDesign.Spacing.p4) {
                Text("Modelr")
                    .font(.system(size: AppDesign.FontSize.largeTitle, weight: .bold))
                    .tracking(-0.5)
                Text("3D from Images")
                    .font(.system(size: AppDesign.FontSize.headline))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            // New Project button
            Button {
                showingFileImporter = true
            } label: {
                Label("New Project", systemImage: "plus")
                    .font(.system(size: AppDesign.FontSize.body, weight: .semibold))
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
    }

    // MARK: - Preload Status

    @ViewBuilder
    private var preloadStatusIndicator: some View {
        HStack(spacing: AppDesign.Spacing.p8) {
            ProgressView()
                .controlSize(.small)
            Text(preloadManager.statusDescription)
                .font(.system(size: AppDesign.FontSize.caption))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, AppDesign.Spacing.p12)
        .padding(.vertical, AppDesign.Spacing.p6)
        .background(.ultraThinMaterial, in: Capsule())
    }

    // MARK: - Projects Section

    @ViewBuilder
    private var projectsSection: some View {
        VStack(alignment: .leading, spacing: AppDesign.Spacing.p16) {
            Text("Recent Projects")
                .font(.system(size: AppDesign.FontSize.title3, weight: .semibold))
                .foregroundStyle(.primary)

            LazyVGrid(columns: columns, spacing: AppDesign.Spacing.p16) {
                // New Project card
                NewProjectCard {
                    showingFileImporter = true
                }

                // Project cards with staggered animation
                ForEach(Array(projectManager.projects.enumerated()), id: \.element.id) { index, project in
                    ProjectCard(project: project) {
                        onOpenProject(project.id)
                    }
                    .contextMenu {
                        projectContextMenu(for: project)
                    }
                    .transition(.asymmetric(
                        insertion: .opacity.combined(with: .scale(scale: 0.9)).combined(with: .offset(y: 20)),
                        removal: .opacity.combined(with: .scale(scale: 0.95))
                    ))
                    .animation(.spring(response: 0.4, dampingFraction: 0.8).delay(Double(index) * 0.03), value: hasAppeared)
                }
            }
        }
    }

    // MARK: - Examples Section

    @ViewBuilder
    private var examplesSection: some View {
        VStack(alignment: .leading, spacing: AppDesign.Spacing.p16) {
            Text("Example Images")
                .font(.system(size: AppDesign.FontSize.title3, weight: .semibold))
                .foregroundStyle(.primary)

            Text("Click an example to create a new project from it")
                .font(.system(size: AppDesign.FontSize.caption))
                .foregroundStyle(.secondary)

            LazyVGrid(columns: columns, spacing: AppDesign.Spacing.p16) {
                ForEach(Array(cachedExamples.enumerated()), id: \.element.name) { index, example in
                    ExampleImageCard(name: example.name, url: example.url) {
                        Task {
                            do {
                                let project = try await projectManager.createProjectFromExample(imageName: example.name)
                                onOpenProject(project.id)
                            } catch {
                                print("[ProjectBrowser] Failed to create project from example: \(error)")
                            }
                        }
                    }
                    .transition(.asymmetric(
                        insertion: .opacity.combined(with: .scale(scale: 0.9)),
                        removal: .opacity
                    ))
                    .animation(.spring(response: 0.4, dampingFraction: 0.8).delay(Double(index) * 0.05), value: hasAppeared)
                }
            }
        }
    }

    // MARK: - Empty State

    @ViewBuilder
    private var emptyStateView: some View {
        VStack(spacing: AppDesign.Spacing.p24) {
            Image(systemName: "photo.stack")
                .font(.system(size: 64))
                .foregroundStyle(.tertiary)
                .symbolEffect(.pulse, options: .repeating)

            VStack(spacing: AppDesign.Spacing.p8) {
                Text("No Projects Yet")
                    .font(.system(size: AppDesign.FontSize.title3, weight: .semibold))
                Text("Drop an image here or click 'New Project' to get started")
                    .font(.system(size: AppDesign.FontSize.body))
                    .foregroundStyle(.secondary)
            }

            Button {
                showingFileImporter = true
            } label: {
                Label("Select Image", systemImage: "photo")
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, AppDesign.Spacing.p64)
    }

    // MARK: - Loading Overlay

    @ViewBuilder
    private var loadingOverlay: some View {
        ZStack {
            Color(NSColor.windowBackgroundColor)

            VStack(spacing: AppDesign.Spacing.p16) {
                ProgressView()
                    .controlSize(.large)
                Text("Loading projects...")
                    .font(.system(size: AppDesign.FontSize.body))
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Drop Overlay

    @ViewBuilder
    private var dropOverlay: some View {
        ZStack {
            Color.black.opacity(0.5)
                .ignoresSafeArea()

            VStack(spacing: AppDesign.Spacing.p16) {
                Image(systemName: "arrow.down.doc.fill")
                    .font(.system(size: 64))
                    .foregroundStyle(.white)
                    .symbolEffect(.bounce, options: .repeating.speed(0.5))

                Text("Drop Image to Create Project")
                    .font(.system(size: AppDesign.FontSize.title2, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .padding(AppDesign.Spacing.p48)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20))
            .scaleEffect(isDraggingFile ? 1.02 : 1.0)
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isDraggingFile)
        }
    }

    // MARK: - Context Menu

    @ViewBuilder
    private func projectContextMenu(for project: Project) -> some View {
        Button {
            onOpenProject(project.id)
        } label: {
            Label("Open", systemImage: "folder")
        }

        Divider()

        Button {
            // TODO: Implement rename
        } label: {
            Label("Rename", systemImage: "pencil")
        }

        Button {
            // TODO: Implement duplicate
        } label: {
            Label("Duplicate", systemImage: "doc.on.doc")
        }

        Divider()

        Button(role: .destructive) {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                try? projectManager.deleteProject(project.id)
            }
        } label: {
            Label("Delete", systemImage: "trash")
        }
    }

    // MARK: - Drop Handling

    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }

        if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
            provider.loadItem(forTypeIdentifier: UTType.image.identifier, options: nil) { item, error in
                if let url = item as? URL {
                    createProjectFromURL(url)
                } else if let data = item as? Data, let image = NSImage(data: data) {
                    createProjectFromImage(image)
                }
            }
            return true
        } else if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, error in
                if let data = item as? Data, let url = URL(dataRepresentation: data, relativeTo: nil) {
                    createProjectFromURL(url)
                }
            }
            return true
        }
        return false
    }

    private func handleFileImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            if let url = urls.first {
                createProjectFromURL(url)
            }
        case .failure(let error):
            print("[ProjectBrowser] File import failed: \(error)")
        }
    }

    private func createProjectFromURL(_ url: URL) {
        Task { @MainActor in
            do {
                let project = try await projectManager.createProject(from: url)
                onOpenProject(project.id)
            } catch {
                print("[ProjectBrowser] Failed to create project: \(error)")
            }
        }
    }

    private func createProjectFromImage(_ image: NSImage) {
        Task { @MainActor in
            do {
                let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".png")
                guard let tiffData = image.tiffRepresentation,
                      let bitmap = NSBitmapImageRep(data: tiffData),
                      let pngData = bitmap.representation(using: .png, properties: [:]) else { return }
                try pngData.write(to: tempURL)

                let project = try await projectManager.createProject(from: tempURL, name: "Dropped Image")
                try? FileManager.default.removeItem(at: tempURL)
                onOpenProject(project.id)
            } catch {
                print("[ProjectBrowser] Failed to create project from dropped image: \(error)")
            }
        }
    }
}

// MARK: - New Project Card

struct NewProjectCard: View {
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: AppDesign.Spacing.p12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color.accentColor.opacity(isHovered ? 0.15 : 0.1))
                        .frame(height: 140)

                    Image(systemName: "plus")
                        .font(.system(size: 32, weight: .medium))
                        .foregroundStyle(Color.accentColor)
                        .scaleEffect(isHovered ? 1.1 : 1.0)
                }

                Text("New Project")
                    .font(.system(size: AppDesign.FontSize.subheadline, weight: .medium))
                    .foregroundStyle(.primary)
            }
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.spring(response: 0.2, dampingFraction: 0.8)) {
                isHovered = hovering
            }
        }
        .scaleEffect(isHovered ? 1.02 : 1.0)
        .animation(.spring(response: 0.2, dampingFraction: 0.8), value: isHovered)
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

                // Name
                Text(name)
                    .font(.system(size: AppDesign.FontSize.subheadline, weight: .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
            }
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
            // Load image from cache
            loadedImage = await ThumbnailCache.shared.exampleImage(named: name, url: url)
        }
    }

    @ViewBuilder
    private var thumbnailView: some View {
        if let image = loadedImage {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
        } else {
            // Skeleton loading state
            Rectangle()
                .fill(Color.secondary.opacity(0.15))
                .overlay {
                    ProgressView()
                        .controlSize(.small)
                }
        }
    }
}
