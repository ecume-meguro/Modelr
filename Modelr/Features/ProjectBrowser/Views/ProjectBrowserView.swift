import SwiftUI
import UniformTypeIdentifiers

// MARK: - Sort Options

enum ProjectSortOption: String, CaseIterable {
    case modifiedDate = "Recently Modified"
    case createdDate = "Date Created"
    case name = "Name"

    var icon: String {
        switch self {
        case .modifiedDate: return "clock"
        case .createdDate: return "calendar"
        case .name: return "textformat"
        }
    }
}

// MARK: - Project Browser View

/// Main project browser view - shown on app startup
struct ProjectBrowserView: View {
    @StateObject private var projectManager = ProjectManager.shared
    @StateObject private var preloadManager = PreloadManager.shared

    // UI State
    @State private var showingFileImporter = false
    @State private var isDraggingFile = false
    @State private var hasAppeared = false

    // Search & Sort
    @State private var searchText = ""
    @State private var sortOption: ProjectSortOption = .modifiedDate
    @State private var sortAscending = false

    // Selection
    @State private var selectedProjectId: UUID?

    // Delete confirmation
    @State private var showDeleteConfirmation = false
    @State private var projectToDelete: Project?

    // Rename
    @State private var showRenameSheet = false
    @State private var projectToRename: Project?
    @State private var renameText = ""

    // Examples cache
    @State private var cachedExamples: [(name: String, url: URL)] = []

    // Callback
    let onOpenProject: (UUID) -> Void

    // MARK: - Computed Properties

    private var filteredProjects: [Project] {
        var projects = projectManager.projects

        // Filter by search text
        if !searchText.isEmpty {
            let query = searchText.lowercased()
            projects = projects.filter { $0.name.lowercased().contains(query) }
        }

        // Sort
        projects.sort { a, b in
            let result: Bool
            switch sortOption {
            case .modifiedDate:
                result = a.modifiedAt > b.modifiedAt
            case .createdDate:
                result = a.createdAt > b.createdAt
            case .name:
                result = a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
            }
            return sortAscending ? !result : result
        }

        return projects
    }

    private var hasProjects: Bool {
        !projectManager.projects.isEmpty
    }

    // MARK: - Body

    var body: some View {
        ZStack {
            Color(NSColor.windowBackgroundColor)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                headerSection
                    .padding(.horizontal, AppDesign.Spacing.p48)
                    .padding(.top, AppDesign.Spacing.p32)
                    .padding(.bottom, AppDesign.Spacing.p24)
                    .background(Color(NSColor.windowBackgroundColor))
                
                Divider()

                ScrollView {
                    VStack(alignment: .leading, spacing: AppDesign.Spacing.p48) {
                        if preloadManager.isPreloading {
                            preloadStatusIndicator
                                .padding(.top, AppDesign.Spacing.p16)
                        }

                        if hasProjects {
                            projectsSection
                        }

                        if !cachedExamples.isEmpty {
                            examplesSection
                        }

                        if !hasProjects && cachedExamples.isEmpty && !projectManager.isLoading {
                            emptyStateView
                        }

                        Spacer(minLength: AppDesign.Spacing.p48)
                    }
                    .padding(.horizontal, AppDesign.Spacing.p48)
                    .padding(.top, AppDesign.Spacing.p32)
                    .padding(.bottom, AppDesign.Spacing.p32)
                }
            }

            // Loading overlay (first load only)
            if projectManager.isLoading && !hasAppeared {
                loadingOverlay
            }

            // Drop overlay
            if isDraggingFile {
                dropOverlay
            }
        }
        .frame(minWidth: 800, minHeight: 600)
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
        .sheet(isPresented: $showRenameSheet) {
            renameSheet
        }
        .confirmationDialog(
            "Delete Project",
            isPresented: $showDeleteConfirmation,
            presenting: projectToDelete
        ) { project in
            Button("Delete", role: .destructive) {
                deleteProject(project)
            }
            Button("Cancel", role: .cancel) {}
        } message: { project in
            Text("Are you sure you want to delete \"\(project.name)\"? This cannot be undone.")
        }
        .task {
            await projectManager.loadProjects()
            cachedExamples = projectManager.getExampleImages()
            preloadManager.startPreloading()
            hasAppeared = true
        }
        .onKeyPress(.delete) {
            if let id = selectedProjectId,
               let project = projectManager.projects.first(where: { $0.id == id }) {
                confirmDelete(project)
                return .handled
            }
            return .ignored
        }
        .onKeyPress(.return) {
            if let id = selectedProjectId {
                onOpenProject(id)
                return .handled
            }
            return .ignored
        }
    }

    // MARK: - Header

    @ViewBuilder
    private var headerSection: some View {
        VStack(alignment: .leading, spacing: AppDesign.Spacing.p24) {
            // Title row
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: AppDesign.Spacing.p4) {
                    Text("Modelr")
                        .font(.system(size: 36, weight: .black, design: .default))
                        .tracking(-1.5)
                        .foregroundStyle(
                            LinearGradient(
                                colors: [.primary, .primary.opacity(0.8)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                    Text("High-Fidelity 3D Generation")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.secondary)
                }

                Spacer()

                AppDesign.GlassButton("New Project", icon: "plus") {
                    showingFileImporter = true
                }
            }

            // Search and sort row
            HStack(spacing: AppDesign.Spacing.p16) {
                // Search field
                HStack(spacing: AppDesign.Spacing.p10) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.tertiary)
                        .font(.system(size: 14, weight: .bold))

                    TextField("Search your projects...", text: $searchText)
                        .textFieldStyle(.plain)
                        .font(.system(size: 14))

                    if !searchText.isEmpty {
                        Button {
                            searchText = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.tertiary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, AppDesign.Spacing.p12)
                .padding(.vertical, AppDesign.Spacing.p10)
                .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
                .overlay {
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(Color.primary.opacity(0.1), lineWidth: 1)
                }
                .frame(maxWidth: 320)

                Spacer()

                // Sort controls
                Menu {
                    ForEach(ProjectSortOption.allCases, id: \.self) { option in
                        Button {
                            if sortOption == option {
                                sortAscending.toggle()
                            } else {
                                sortOption = option
                                sortAscending = false
                            }
                        } label: {
                            HStack {
                                Label(option.rawValue, systemImage: option.icon)
                                if sortOption == option {
                                    Image(systemName: sortAscending ? "chevron.up" : "chevron.down")
                                }
                            }
                        }
                    }
                } label: {
                    HStack(spacing: AppDesign.Spacing.p8) {
                        Image(systemName: sortOption.icon)
                        Text(sortOption.rawValue)
                        Image(systemName: sortAscending ? "chevron.up" : "chevron.down")
                            .font(.system(size: 10, weight: .bold))
                    }
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, AppDesign.Spacing.p12)
                    .padding(.vertical, AppDesign.Spacing.p8)
                    .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
                }
                .menuStyle(.borderlessButton)
            }
        }
    }

    // MARK: - Preload Status

    @ViewBuilder
    private var preloadStatusIndicator: some View {
        HStack(spacing: AppDesign.Spacing.p12) {
            ProgressView()
                .controlSize(.small)
            Text(preloadManager.statusDescription)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, AppDesign.Spacing.p16)
        .padding(.vertical, AppDesign.Spacing.p8)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay {
            Capsule()
                .strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5)
        }
    }

    // MARK: - Projects Section

    @ViewBuilder
    private var projectsSection: some View {
        VStack(alignment: .leading, spacing: AppDesign.Spacing.p24) {
            HStack(alignment: .firstTextBaseline, spacing: AppDesign.Spacing.p12) {
                AppDesign.SubheaderText(text: "Recent Projects")

                Text("\(filteredProjects.count)")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundStyle(AppDesign.accent)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(AppDesign.accent.opacity(0.1), in: Capsule())
            }

            if filteredProjects.isEmpty && !searchText.isEmpty {
                // No search results
                HStack {
                    Spacer()
                    VStack(spacing: AppDesign.Spacing.p16) {
                        Image(systemName: "doc.text.magnifyingglass")
                            .font(.system(size: 48, weight: .ultraLight))
                            .foregroundStyle(.quaternary)
                        Text("No projects match \"\(searchText)\"")
                            .font(.system(size: 16, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 80)
                    Spacer()
                }
            } else {
                projectGrid
            }
        }
    }

    @ViewBuilder
    private var projectGrid: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 240, maximum: 300), spacing: AppDesign.Spacing.p24)],
            spacing: AppDesign.Spacing.p24
        ) {
            // New Project card
            NewProjectCard {
                showingFileImporter = true
            }

            // Project cards
            ForEach(filteredProjects) { project in
                ProjectCard(
                    project: project,
                    isSelected: selectedProjectId == project.id,
                    action: {
                        onOpenProject(project.id)
                    },
                    onDelete: {
                        confirmDelete(project)
                    },
                    onRename: {
                        startRename(project)
                    },
                    onDuplicate: {
                        duplicateProject(project)
                    }
                )
                .onTapGesture {
                    selectedProjectId = project.id
                }
                .id(project.id)
            }
        }
    }

    // MARK: - Examples Section

    @ViewBuilder
    private var examplesSection: some View {
        VStack(alignment: .leading, spacing: AppDesign.Spacing.p24) {
            VStack(alignment: .leading, spacing: AppDesign.Spacing.p8) {
                AppDesign.SubheaderText(text: "Ready to Try")
                Text("Select an example asset to explore capabilities")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }

            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 240, maximum: 300), spacing: AppDesign.Spacing.p24)],
                spacing: AppDesign.Spacing.p24
            ) {
                ForEach(cachedExamples, id: \.name) { example in
                    ExampleImageCard(name: example.name, url: example.url) {
                        createProjectFromExample(example.name)
                    }
                }
            }
        }
    }

    // MARK: - Empty State

    @ViewBuilder
    private var emptyStateView: some View {
        VStack(spacing: AppDesign.Spacing.p32) {
            ZStack {
                Circle()
                    .fill(Color.primary.opacity(0.03))
                    .frame(width: 120, height: 120)
                Image(systemName: "photo.on.rectangle.angled")
                    .font(.system(size: 56, weight: .ultraLight))
                    .foregroundStyle(.quaternary)
            }

            VStack(spacing: AppDesign.Spacing.p8) {
                Text("Your Creative Space")
                    .font(.system(size: 24, weight: .bold))
                Text("Transform your 2D images into high-quality 3D models.\nDrag an image here to begin your first project.")
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(4)
            }

            AppDesign.GlassButton("Select Image", icon: "photo.badge.plus") {
                showingFileImporter = true
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 100)
    }

    // MARK: - Loading Overlay

    @ViewBuilder
    private var loadingOverlay: some View {
        ZStack {
            Color(NSColor.windowBackgroundColor)

            VStack(spacing: AppDesign.Spacing.p24) {
                ProgressView()
                    .controlSize(.large)
                Text("Initializing Library...")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Drop Overlay

    @ViewBuilder
    private var dropOverlay: some View {
        ZStack {
            Color.black.opacity(0.3)
                .ignoresSafeArea()
            
            VStack(spacing: AppDesign.Spacing.p24) {
                ZStack {
                    Circle()
                        .fill(AppDesign.accent)
                        .frame(width: 80, height: 80)
                        .shadow(color: AppDesign.accent.opacity(0.5), radius: 20)
                    
                    Image(systemName: "arrow.down")
                        .font(.system(size: 32, weight: .bold))
                        .foregroundStyle(.white)
                }

                VStack(spacing: AppDesign.Spacing.p8) {
                    Text("Drop to Create Project")
                        .font(.system(size: 24, weight: .bold))
                        .foregroundStyle(.white)
                    Text("Supported formats: PNG, JPG, WEBP")
                        .font(.system(size: 14))
                        .foregroundStyle(.white.opacity(0.8))
                }
            }
            .padding(AppDesign.Spacing.p64)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 32))
            .overlay {
                RoundedRectangle(cornerRadius: 32)
                    .strokeBorder(Color.white.opacity(0.2), lineWidth: 1)
            }
        }
    }

    // MARK: - Rename Sheet

    @ViewBuilder
    private var renameSheet: some View {
        VStack(spacing: AppDesign.Spacing.p24) {
            VStack(spacing: AppDesign.Spacing.p8) {
                Text("Rename Project")
                    .font(.system(size: 18, weight: .bold))
                Text("Enter a new name for your project")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }

            AppDesign.StyledTextField(placeholder: "Project Name", text: $renameText) {
                performRename()
            }
            .frame(width: 320)

            HStack(spacing: AppDesign.Spacing.p12) {
                AppDesign.GlassButtonSecondary("Cancel") {
                    cancelRename()
                }
                .keyboardShortcut(.escape, modifiers: [])

                AppDesign.GlassButton("Rename") {
                    performRename()
                }
                .keyboardShortcut(.return, modifiers: [])
                .disabled(renameText.isEmpty)
            }
        }
        .padding(AppDesign.Spacing.p32)
        .frame(minWidth: 400)
    }

    // MARK: - Actions

    private func confirmDelete(_ project: Project) {
        projectToDelete = project
        showDeleteConfirmation = true
    }

    private func deleteProject(_ project: Project) {
        withAnimation(.easeOut(duration: 0.2)) {
            try? projectManager.deleteProject(project.id)
        }
        if selectedProjectId == project.id {
            selectedProjectId = nil
        }
        projectToDelete = nil
    }

    private func startRename(_ project: Project) {
        projectToRename = project
        renameText = project.name
        showRenameSheet = true
    }

    private func performRename() {
        if let project = projectToRename, !renameText.isEmpty {
            try? projectManager.renameProject(project.id, to: renameText)
        }
        cancelRename()
    }

    private func cancelRename() {
        showRenameSheet = false
        projectToRename = nil
        renameText = ""
    }

    private func duplicateProject(_ project: Project) {
        Task {
            do {
                _ = try await projectManager.duplicateProject(project.id)
            } catch {
                print("[ProjectBrowser] Failed to duplicate: \(error)")
            }
        }
    }

    private func createProjectFromExample(_ name: String) {
        Task {
            do {
                let project = try await projectManager.createProjectFromExample(imageName: name)
                onOpenProject(project.id)
            } catch {
                print("[ProjectBrowser] Failed to create project from example: \(error)")
            }
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

    // MARK: - Preload Status

    @ViewBuilder
    private var preloadStatusIndicator: some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
            Text(preloadManager.statusDescription)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.ultraThinMaterial, in: Capsule())
    }

    // MARK: - Projects Section

    @ViewBuilder
    private var projectsSection: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("Recent Projects")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                    .tracking(0.5)

                Text("\(filteredProjects.count)")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(Color.primary.opacity(0.06), in: Capsule())
            }

            if filteredProjects.isEmpty && !searchText.isEmpty {
                // No search results
                HStack {
                    Spacer()
                    VStack(spacing: 12) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 36, weight: .light))
                            .foregroundStyle(.quaternary)
                        Text("No projects match \"\(searchText)\"")
                            .font(.system(size: 14))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 60)
                    Spacer()
                }
            } else {
                projectGrid
            }
        }
    }

    @ViewBuilder
    private var projectGrid: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 200, maximum: 260), spacing: 20)],
            spacing: 20
        ) {
            // New Project card
            NewProjectCard {
                showingFileImporter = true
            }

            // Project cards
            ForEach(filteredProjects) { project in
                ProjectCard(
                    project: project,
                    isSelected: selectedProjectId == project.id,
                    action: {
                        onOpenProject(project.id)
                    },
                    onDelete: {
                        confirmDelete(project)
                    },
                    onRename: {
                        startRename(project)
                    },
                    onDuplicate: {
                        duplicateProject(project)
                    }
                )
                .onTapGesture {
                    selectedProjectId = project.id
                }
                .id(project.id)
            }
        }
    }

    // MARK: - Examples Section

    @ViewBuilder
    private var examplesSection: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Examples")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                    .tracking(0.5)
                Text("Click an example to create a new project")
                    .font(.system(size: 13))
                    .foregroundStyle(.tertiary)
            }

            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 200, maximum: 260), spacing: 20)],
                spacing: 20
            ) {
                ForEach(cachedExamples, id: \.name) { example in
                    ExampleImageCard(name: example.name, url: example.url) {
                        createProjectFromExample(example.name)
                    }
                }
            }
        }
    }

    // MARK: - Empty State

    @ViewBuilder
    private var emptyStateView: some View {
        VStack(spacing: 24) {
            Image(systemName: "photo.stack")
                .font(.system(size: 64, weight: .ultraLight))
                .foregroundStyle(.quaternary)

            VStack(spacing: 8) {
                Text("No Projects Yet")
                    .font(.system(size: 20, weight: .semibold))
                Text("Drop an image here or click 'New Project' to get started")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
            }

            Button {
                showingFileImporter = true
            } label: {
                Label("Select Image", systemImage: "photo")
                    .font(.system(size: 14, weight: .medium))
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 80)
    }

    // MARK: - Loading Overlay

    @ViewBuilder
    private var loadingOverlay: some View {
        ZStack {
            Color(NSColor.windowBackgroundColor)

            VStack(spacing: 16) {
                ProgressView()
                    .controlSize(.large)
                Text("Loading projects...")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Drop Overlay

    @ViewBuilder
    private var dropOverlay: some View {
        ZStack {
            Color.black.opacity(0.4)
                .ignoresSafeArea()

            VStack(spacing: 20) {
                Image(systemName: "arrow.down.doc.fill")
                    .font(.system(size: 64, weight: .light))
                    .foregroundStyle(.white)

                Text("Drop Image to Create Project")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .padding(48)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20))
            .overlay {
                RoundedRectangle(cornerRadius: 20)
                    .strokeBorder(Color.white.opacity(0.2), lineWidth: 1)
            }
        }
    }

    // MARK: - Rename Sheet

    @ViewBuilder
    private var renameSheet: some View {
        VStack(spacing: 16) {
            Text("Rename Project")
                .font(.system(size: 16, weight: .semibold))

            TextField("Project Name", text: $renameText)
                .textFieldStyle(.roundedBorder)
                .frame(width: 280)
                .onSubmit {
                    performRename()
                }

            HStack(spacing: 12) {
                Button("Cancel") {
                    cancelRename()
                }
                .keyboardShortcut(.escape, modifiers: [])

                Button("Rename") {
                    performRename()
                }
                .keyboardShortcut(.return, modifiers: [])
                .buttonStyle(.borderedProminent)
                .disabled(renameText.isEmpty)
            }
        }
        .padding(24)
        .frame(minWidth: 320)
    }

    // MARK: - Actions

    private func confirmDelete(_ project: Project) {
        projectToDelete = project
        showDeleteConfirmation = true
    }

    private func deleteProject(_ project: Project) {
        withAnimation(.easeOut(duration: 0.2)) {
            try? projectManager.deleteProject(project.id)
        }
        if selectedProjectId == project.id {
            selectedProjectId = nil
        }
        projectToDelete = nil
    }

    private func startRename(_ project: Project) {
        projectToRename = project
        renameText = project.name
        showRenameSheet = true
    }

    private func performRename() {
        if let project = projectToRename, !renameText.isEmpty {
            try? projectManager.renameProject(project.id, to: renameText)
        }
        cancelRename()
    }

    private func cancelRename() {
        showRenameSheet = false
        projectToRename = nil
        renameText = ""
    }

    private func duplicateProject(_ project: Project) {
        Task {
            do {
                _ = try await projectManager.duplicateProject(project.id)
            } catch {
                print("[ProjectBrowser] Failed to duplicate: \(error)")
            }
        }
    }

    private func createProjectFromExample(_ name: String) {
        Task {
            do {
                let project = try await projectManager.createProjectFromExample(imageName: name)
                onOpenProject(project.id)
            } catch {
                print("[ProjectBrowser] Failed to create project from example: \(error)")
            }
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
