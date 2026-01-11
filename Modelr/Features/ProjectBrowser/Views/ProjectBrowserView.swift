import SwiftUI
import UniformTypeIdentifiers

// MARK: - Filter & Sort Options

enum ProjectFilter: String, CaseIterable {
    case all = "All"
    case inProgress = "In Progress"
    case completed = "Completed"

    var icon: String {
        switch self {
        case .all: return "square.grid.2x2"
        case .inProgress: return "clock.arrow.circlepath"
        case .completed: return "checkmark.circle"
        }
    }
}

enum ProjectSort: String, CaseIterable {
    case recent = "Recent"
    case name = "Name"
    case progress = "Progress"

    var icon: String {
        switch self {
        case .recent: return "clock"
        case .name: return "textformat"
        case .progress: return "chart.bar"
        }
    }
}

/// Main project browser view - shown on app startup
struct ProjectBrowserView: View {
    @StateObject private var projectManager = ProjectManager.shared
    @StateObject private var preloadManager = PreloadManager.shared
    @State private var showingFileImporter = false
    @State private var isDraggingFile = false
    @State private var hasAppeared = false

    /// Search & Filter state
    @State private var searchText = ""
    @State private var selectedFilter: ProjectFilter = .all
    @State private var selectedSort: ProjectSort = .recent

    /// Rename sheet state
    @State private var showRenameSheet = false
    @State private var projectToRename: Project?
    @State private var renameText = ""

    /// Selection state
    @State private var selectedProjectIds: Set<UUID> = []
    @State private var isSelectionMode = false
    @State private var showDeleteConfirmation = false

    /// Cached example images to avoid recomputing
    @State private var cachedExamples: [(name: String, url: URL)] = []

    /// New project mode selection
    @State private var showingModeSelection = false

    let onOpenProject: (UUID) -> Void

    /// Check if all filtered projects are selected
    private var allSelected: Bool {
        !filteredProjects.isEmpty && filteredProjects.allSatisfy { selectedProjectIds.contains($0.id) }
    }

    /// Number of selected projects
    private var selectionCount: Int {
        selectedProjectIds.count
    }

    private let columns = [
        GridItem(.adaptive(minimum: 200, maximum: 260), spacing: 24)
    ]

    // MARK: - Filtered & Sorted Projects

    private var filteredProjects: [Project] {
        var projects = projectManager.projects

        // Apply search filter
        if !searchText.isEmpty {
            projects = projects.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
        }

        // Apply status filter
        switch selectedFilter {
        case .all:
            break
        case .inProgress:
            projects = projects.filter { $0.workflowStep < 4 }
        case .completed:
            projects = projects.filter { $0.workflowStep >= 4 }
        }

        // Apply sort
        switch selectedSort {
        case .recent:
            projects.sort { $0.modifiedAt > $1.modifiedAt }
        case .name:
            projects.sort { $0.name.localizedCompare($1.name) == .orderedAscending }
        case .progress:
            projects.sort { $0.workflowStep > $1.workflowStep }
        }

        return projects
    }

    // MARK: - Stats

    private var completedCount: Int {
        projectManager.projects.filter { $0.workflowStep >= 4 }.count
    }

    private var inProgressCount: Int {
        projectManager.projects.filter { $0.workflowStep < 4 }.count
    }

    var body: some View {
        ZStack {
            // Background
            Color(NSColor.windowBackgroundColor)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                // Pinned Header
                headerSection
                    .padding(.horizontal, AppDesign.Spacing.p32)
                    .padding(.top, AppDesign.Spacing.p24)
                    .padding(.bottom, AppDesign.Spacing.p16)
                    .background(Color(NSColor.windowBackgroundColor))

                Divider()
                    .opacity(AppDesign.Opacity.high)

                // Scrollable Content
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: AppDesign.Spacing.p24) {
                        // Projects Section
                        if !projectManager.projects.isEmpty {
                            projectsSection
                        }

                        // Example Images Section
                        if !cachedExamples.isEmpty {
                            examplesSection
                        }

                        // Empty state
                        if projectManager.projects.isEmpty && cachedExamples.isEmpty && !projectManager.isLoading {
                            emptyStateView
                                .frame(maxWidth: .infinity, minHeight: 300)
                        }
                    }
                    .padding(.horizontal, AppDesign.Spacing.p32)
                    .padding(.top, AppDesign.Spacing.p16)
                    .padding(.bottom, AppDesign.Spacing.p32)
                }
            }

            // Status Bar Overlay (Top)
            if preloadManager.isPreloading {
                VStack {
                    preloadStatusIndicator
                        .padding(.top, AppDesign.Spacing.p16)
                    Spacer()
                }
            }

            // Floating Selection Action Bar (Bottom)
            VStack {
                Spacer()
                if isSelectionMode {
                    floatingSelectionBar
                        .padding(.bottom, AppDesign.Spacing.p24)
                        .transition(.asymmetric(
                            insertion: .move(edge: .bottom).combined(with: .opacity),
                            removal: .move(edge: .bottom).combined(with: .opacity)
                        ))
                }
            }
            .animation(.spring(response: 0.35, dampingFraction: 0.8), value: isSelectionMode)

            // Loading overlay (first load only)
            if projectManager.isLoading && !hasAppeared {
                loadingOverlay
            }

            // Drop overlay
            if isDraggingFile {
                dropOverlay
            }
        }
        .focusable()
        .focusEffectDisabled()
        .onKeyPress(.escape) {
            if isSelectionMode {
                withAnimation(.easeInOut(duration: 0.2)) {
                    isSelectionMode = false
                    selectedProjectIds.removeAll()
                }
                return .handled
            }
            return .ignored
        }
        .onKeyPress(.delete) {
            if isSelectionMode && selectionCount > 0 {
                showDeleteConfirmation = true
                return .handled
            }
            return .ignored
        }
        .onKeyPress(characters: CharacterSet(charactersIn: "a")) { press in
            if press.modifiers.contains(.command) && isSelectionMode {
                if allSelected {
                    selectedProjectIds.removeAll()
                } else {
                    selectedProjectIds = Set(filteredProjects.map { $0.id })
                }
                return .handled
            }
            return .ignored
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
        .alert("Delete \(selectionCount) Project\(selectionCount == 1 ? "" : "s")?", isPresented: $showDeleteConfirmation) {
            Button("Cancel", role: .cancel) { }
            Button("Delete", role: .destructive) {
                deleteSelectedProjects()
            }
        } message: {
            Text("This action cannot be undone.")
        }
        .task {
            // Load projects
            await projectManager.loadProjects()

            // Cache examples
            cachedExamples = projectManager.getExampleImages()

            // Start preloading
            preloadManager.startPreloading()

            hasAppeared = true
        }
    }

    // MARK: - Header

    @ViewBuilder
    private var headerSection: some View {
        VStack(alignment: .leading, spacing: AppDesign.Spacing.p12) {
            // Title row
            HStack(alignment: .center, spacing: AppDesign.Spacing.p12) {
                if isSelectionMode {
                    // Selection mode header - minimal, since floating bar has the controls
                    HStack(spacing: AppDesign.Spacing.p8) {
                        Circle()
                            .fill(Color.accentColor)
                            .frame(width: AppDesign.Spacing.p8, height: AppDesign.Spacing.p8)
                        Text("Selecting Projects")
                            .font(.system(size: AppDesign.FontSize.headline, weight: .medium))
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    // Quick exit via header too (accessibility)
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            isSelectionMode = false
                            selectedProjectIds.removeAll()
                        }
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: AppDesign.FontSize.title3))
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                    .help("Exit selection mode (Esc)")
                } else {
                    // Normal header - App branding
                    HStack(spacing: AppDesign.Spacing.p8) {
                        Image(systemName: "cube.fill")
                            .font(.system(size: AppDesign.FontSize.title3))
                            .foregroundStyle(AppDesign.accent)
                        Text("Modelr")
                            .font(.system(size: AppDesign.FontSize.title2, weight: .semibold, design: .rounded))
                    }

                    Spacer()

                    // Select button (only show if there are projects)
                    if !projectManager.projects.isEmpty {
                        Button {
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                                isSelectionMode = true
                            }
                        } label: {
                            Label("Select", systemImage: "checkmark.circle")
                        }
                        .buttonStyle(.bordered)
                    }

                    Button {
                        showingFileImporter = true
                    } label: {
                        Label("New Project", systemImage: "plus")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.regular)
                }
            }

            // Search and filter bar
            if !projectManager.projects.isEmpty {
                HStack(spacing: AppDesign.Spacing.p10) {
                    // Search field
                    HStack(spacing: AppDesign.Spacing.p6) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: AppDesign.FontSize.subheadline))
                            .foregroundStyle(.tertiary)
                        TextField("Search...", text: $searchText)
                            .textFieldStyle(.plain)
                            .font(.system(size: AppDesign.FontSize.body))
                        if !searchText.isEmpty {
                            Button {
                                searchText = ""
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.system(size: AppDesign.FontSize.caption))
                                    .foregroundStyle(.tertiary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, AppDesign.Spacing.p8)
                    .padding(.vertical, AppDesign.Spacing.p6)
                    .background(Color.primary.opacity(AppDesign.Opacity.light), in: RoundedRectangle(cornerRadius: AppDesign.Size.cornerRadiusSmall))
                    .frame(maxWidth: 200)

                    // Filter tabs
                    filterTabs

                    Spacer()

                    // Sort dropdown
                    sortMenu
                }
            }
        }
    }

    // MARK: - Floating Selection Bar

    @ViewBuilder
    private var floatingSelectionBar: some View {
        HStack(spacing: AppDesign.Spacing.p16) {
            // Selection count
            Text("\(selectionCount) selected")
                .font(.system(size: AppDesign.FontSize.body, weight: .medium))
                .foregroundStyle(.primary)

            Divider()
                .frame(height: AppDesign.Spacing.p16)

            // Select All / Deselect All
            Button {
                withAnimation(.easeInOut(duration: 0.15)) {
                    if allSelected {
                        selectedProjectIds.removeAll()
                    } else {
                        selectedProjectIds = Set(filteredProjects.map { $0.id })
                    }
                }
            } label: {
                HStack(spacing: AppDesign.Spacing.p4) {
                    Image(systemName: allSelected ? "checkmark.circle" : "checkmark.circle.fill")
                        .font(.system(size: AppDesign.FontSize.body))
                    Text(allSelected ? "Deselect All" : "Select All")
                        .font(.system(size: AppDesign.FontSize.body, weight: .medium))
                }
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)

            // Delete - only show if something is selected
            if selectionCount > 0 {
                Divider()
                    .frame(height: AppDesign.Spacing.p16)

                Button {
                    showDeleteConfirmation = true
                } label: {
                    HStack(spacing: AppDesign.Spacing.p4) {
                        Image(systemName: "trash")
                            .font(.system(size: AppDesign.FontSize.body))
                        Text("Delete")
                            .font(.system(size: AppDesign.FontSize.body, weight: .medium))
                    }
                }
                .buttonStyle(.plain)
                .foregroundStyle(.red)
            }

            Divider()
                .frame(height: AppDesign.Spacing.p16)

            // Done button
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    isSelectionMode = false
                    selectedProjectIds.removeAll()
                }
            } label: {
                Text("Done")
                    .font(.system(size: AppDesign.FontSize.body, weight: .semibold))
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        }
        .padding(.horizontal, AppDesign.Spacing.p16)
        .padding(.vertical, AppDesign.Spacing.p12)
        .background {
            Capsule()
                .fill(.ultraThickMaterial)
                .shadow(color: .black.opacity(AppDesign.Opacity.semi), radius: 12, y: 4)
        }
        .overlay {
            Capsule()
                .strokeBorder(Color.primary.opacity(AppDesign.Opacity.soft), lineWidth: 0.5)
        }
    }

    // MARK: - Filter Tabs

    @ViewBuilder
    private var filterTabs: some View {
        HStack(spacing: 0) {
            ForEach(ProjectFilter.allCases, id: \.self) { filter in
                Button {
                    selectedFilter = filter
                } label: {
                    Text(filter.rawValue)
                        .font(.system(size: AppDesign.FontSize.subheadline))
                        .padding(.horizontal, AppDesign.Spacing.p10)
                        .padding(.vertical, AppDesign.Spacing.p6)
                        .foregroundStyle(selectedFilter == filter ? .primary : .tertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .background(Color.primary.opacity(AppDesign.Opacity.subtle), in: RoundedRectangle(cornerRadius: AppDesign.Size.cornerRadiusSmall))
    }

    // MARK: - Sort Menu

    @ViewBuilder
    private var sortMenu: some View {
        Menu {
            ForEach(ProjectSort.allCases, id: \.self) { sort in
                Button {
                    selectedSort = sort
                } label: {
                    Label(sort.rawValue, systemImage: sort.icon)
                }
            }
        } label: {
            HStack(spacing: AppDesign.Spacing.p4) {
                Image(systemName: "arrow.up.arrow.down")
                    .font(.system(size: AppDesign.FontSize.xs))
                Text(selectedSort.rawValue)
                    .font(.system(size: AppDesign.FontSize.subheadline))
            }
            .foregroundStyle(.tertiary)
        }
        .menuStyle(.borderlessButton)
    }

    // MARK: - Selection Helpers

    private func toggleSelection(_ id: UUID) {
        if selectedProjectIds.contains(id) {
            selectedProjectIds.remove(id)
        } else {
            selectedProjectIds.insert(id)
        }
    }

    @ViewBuilder
    private func selectionCheckbox(for id: UUID) -> some View {
        let isSelected = selectedProjectIds.contains(id)
        ZStack {
            // Background circle with animation
            Circle()
                .fill(isSelected ? Color.accentColor : Color.black.opacity(AppDesign.Opacity.high))
                .frame(width: AppDesign.Size.stepCircle, height: AppDesign.Size.stepCircle)
                .shadow(color: .black.opacity(AppDesign.Opacity.moderate), radius: 2, y: 1)

            if isSelected {
                Image(systemName: "checkmark")
                    .font(.system(size: AppDesign.FontSize.body, weight: .bold))
                    .foregroundStyle(.white)
                    .transition(.scale.combined(with: .opacity))
            } else {
                Circle()
                    .strokeBorder(Color.white.opacity(0.9), lineWidth: 2)
                    .frame(width: AppDesign.Spacing.p16, height: AppDesign.Spacing.p16)
            }
        }
        .scaleEffect(isSelected ? 1.0 : 0.9)
        .animation(.spring(response: 0.25, dampingFraction: 0.7), value: isSelected)
    }

    private func deleteSelectedProjects() {
        for id in selectedProjectIds {
            try? projectManager.deleteProject(id)
        }
        selectedProjectIds.removeAll()
        isSelectionMode = false
    }

    // MARK: - Preload Status

    @ViewBuilder
    private var preloadStatusIndicator: some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
            Text(preloadManager.statusDescription)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay {
            Capsule()
                .strokeBorder(Color.white.opacity(0.1), lineWidth: 0.5)
        }
    }

    // MARK: - Projects Section

    @ViewBuilder
    private var projectsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Section header - minimal
            if filteredProjects.isEmpty && (!searchText.isEmpty || selectedFilter != .all) {
                Text("No matching projects")
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 40)
            }

            if !filteredProjects.isEmpty {
                LazyVGrid(columns: columns, spacing: 16) {
                    ForEach(filteredProjects) { project in
                        let isSelected = selectedProjectIds.contains(project.id)
                        ZStack(alignment: .topLeading) {
                            ProjectCard(
                                project: project,
                                action: {
                                    if isSelectionMode {
                                        withAnimation(.spring(response: 0.25, dampingFraction: 0.7)) {
                                            toggleSelection(project.id)
                                        }
                                    } else {
                                        onOpenProject(project.id)
                                    }
                                }
                            )
                            .overlay {
                                if isSelectionMode {
                                    // Selection overlay with gradient border for selected items
                                    ZStack {
                                        RoundedRectangle(cornerRadius: 8)
                                            .strokeBorder(
                                                isSelected ? Color.accentColor : Color.white.opacity(0.15),
                                                lineWidth: isSelected ? 2.5 : 1
                                            )

                                        // Subtle highlight overlay when selected
                                        if isSelected {
                                            RoundedRectangle(cornerRadius: 8)
                                                .fill(Color.accentColor.opacity(0.08))
                                        }
                                    }
                                    .allowsHitTesting(false)  // Don't block taps on the card
                                }
                            }
                            .scaleEffect(isSelectionMode && isSelected ? 0.98 : 1.0)
                            .animation(.spring(response: 0.2, dampingFraction: 0.8), value: isSelected)

                            // Selection checkbox - positioned on top but allows tap to pass through to card
                            if isSelectionMode {
                                selectionCheckbox(for: project.id)
                                    .padding(8)
                                    .allowsHitTesting(false)  // Tap passes through to ProjectCard button
                                    .transition(.scale.combined(with: .opacity))
                            }
                        }
                        .animation(.easeInOut(duration: 0.2), value: isSelectionMode)
                        .contextMenu {
                            if !isSelectionMode {
                                projectContextMenu(for: project)
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: - Examples Section

    @ViewBuilder
    private var examplesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Examples")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.tertiary)

            LazyVGrid(columns: columns, spacing: 16) {
                ForEach(cachedExamples, id: \.name) { example in
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
                }
            }
        }
    }

    // MARK: - Empty State

    @ViewBuilder
    private var emptyStateView: some View {
        VStack(spacing: 24) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 64))
                .foregroundStyle(.tertiary)
            
            VStack(spacing: 8) {
                Text("No Projects Yet")
                    .font(.title2.bold())
                Text("Create a new project or drop an image to get started.")
                    .font(.body)
                    .foregroundStyle(.secondary)
            }

            Button {
                showingFileImporter = true
            } label: {
                Text("Create New Project")
                    .padding(.horizontal, 12)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .padding(.top, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.vertical, 64)
    }

    // MARK: - Loading Overlay

    @ViewBuilder
    private var loadingOverlay: some View {
        ZStack {
            Color(NSColor.windowBackgroundColor)

            VStack(spacing: 16) {
                ProgressView()
                    .controlSize(.large)
                Text("Loading...")
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Drop Overlay

    @ViewBuilder
    private var dropOverlay: some View {
        ZStack {
            Color.black.opacity(0.4)
                .background(.ultraThinMaterial)
                .ignoresSafeArea()

            VStack(spacing: 24) {
                Image(systemName: "plus.circle.fill")
                    .font(.system(size: 64))
                    .foregroundStyle(.white)

                Text("Drop to Create Project")
                    .font(.title.bold())
                    .foregroundStyle(.white)
            }
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
            projectToRename = project
            renameText = project.name
            showRenameSheet = true
        } label: {
            Label("Rename", systemImage: "pencil")
        }

        Button {
            Task {
                do {
                    _ = try await projectManager.duplicateProject(project.id)
                } catch {
                    print("[ProjectBrowser] Failed to duplicate: \(error)")
                }
            }
        } label: {
            Label("Duplicate", systemImage: "doc.on.doc")
        }

        Divider()

        Button(role: .destructive) {
            withAnimation(.spring(response: 0.2, dampingFraction: 0.8)) {
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

    // MARK: - Rename Sheet

    @ViewBuilder
    private var renameSheet: some View {
        VStack(spacing: 20) {
            Text("Rename Project")
                .font(.headline)
            
            TextField("Project Name", text: $renameText)
                .textFieldStyle(.roundedBorder)
                .frame(width: 250)
                .onSubmit {
                    if !renameText.isEmpty {
                        if let project = projectToRename {
                            try? projectManager.renameProject(project.id, to: renameText)
                        }
                        showRenameSheet = false
                    }
                }

            HStack(spacing: 12) {
                Button("Cancel") {
                    showRenameSheet = false
                    projectToRename = nil
                    renameText = ""
                }
                .keyboardShortcut(.cancelAction)

                Button("Rename") {
                    if let project = projectToRename, !renameText.isEmpty {
                        try? projectManager.renameProject(project.id, to: renameText)
                    }
                    showRenameSheet = false
                    projectToRename = nil
                    renameText = ""
                }
                .keyboardShortcut(.defaultAction)
                .disabled(renameText.isEmpty)
            }
        }
        .padding(24)
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
            VStack(alignment: .leading, spacing: 8) {
                // Thumbnail
                thumbnailView
                    .frame(height: 120)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay {
                        RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
                    }

                // Info
                VStack(alignment: .leading, spacing: 3) {
                    Text(name)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                    Text("Sample")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
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
        .task {
            loadedImage = await ThumbnailCache.shared.exampleImage(named: name, url: url)
        }
    }

    @ViewBuilder
    private var thumbnailView: some View {
        ZStack {
            Color(NSColor.controlBackgroundColor)
            if let image = loadedImage {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                ProgressView().controlSize(.small)
            }
        }
    }
}
