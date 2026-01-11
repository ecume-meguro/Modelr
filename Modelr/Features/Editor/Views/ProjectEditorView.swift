import SwiftUI

/// Wrapper view that loads a project and presents the editor
struct ProjectEditorView: View {
    let projectId: UUID
    let onClose: () -> Void

    @StateObject private var viewModel: SimpleEditorViewModel
    @State private var project: Project?
    @State private var isLoading = true
    @State private var hasAppeared = false

    /// Debounce task for auto-save
    @State private var saveTask: Task<Void, Never>?

    /// Save debounce interval (ms)
    private let saveDebounceMs: UInt64 = 500

    init(projectId: UUID, onClose: @escaping () -> Void) {
        self.projectId = projectId
        self.onClose = onClose

        // Create view model
        let env = ServiceContainer.shared.pythonEnvironment
        _viewModel = StateObject(wrappedValue: SimpleEditorViewModel(env: env, projectId: projectId))
    }

    var body: some View {
        ZStack {
            if isLoading {
                loadingView
                    .transition(.opacity)
            } else if project != nil {
                editorContent
                    .opacity(hasAppeared ? 1 : 0)
                    .scaleEffect(hasAppeared ? 1 : 0.98)
            } else {
                errorView
                    .transition(.opacity)
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: isLoading)
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: hasAppeared)
        .task {
            await loadProject()
            withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                hasAppeared = true
            }
        }
        // Auto-naming: listen for VLM detection at root level (so it fires during loading)
        .onChange(of: viewModel.autoDetectedLabel) { _, newLabel in
            // Step 1: Immediately set project name to VLM/SAM prompt
            if let label = newLabel, !label.isEmpty, var proj = project {
                let formattedName = label.split(separator: " ")
                    .map { $0.prefix(1).uppercased() + $0.dropFirst().lowercased() }
                    .joined(separator: " ")
                proj.name = formattedName
                proj.touch()
                try? ProjectManager.shared.saveProject(proj)
                project = proj

                // Step 2: Async ask VLM for a better descriptive name
                Task {
                    await requestBetterProjectName()
                }
            }
        }
    }

    @ViewBuilder
    private var loadingView: some View {
        VStack(spacing: AppDesign.Spacing.p24) {
            // App icon or loading graphic
            ZStack {
                Circle()
                    .fill(Color.accentColor.opacity(0.1))
                    .frame(width: 100, height: 100)

                ProgressView()
                    .controlSize(.large)
                    .scaleEffect(1.2)
            }

            VStack(spacing: AppDesign.Spacing.p8) {
                Text("Loading Project")
                    .font(.system(size: AppDesign.FontSize.title2, weight: .semibold))

                Text(viewModel.initializationStatus.isEmpty ? "Preparing..." : viewModel.initializationStatus)
                    .font(.system(size: AppDesign.FontSize.body))
                    .foregroundStyle(.secondary)
                    .contentTransition(.numericText())
                    .animation(.easeInOut(duration: 0.2), value: viewModel.initializationStatus)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(NSColor.windowBackgroundColor))
    }

    @ViewBuilder
    private var errorView: some View {
        VStack(spacing: AppDesign.Spacing.p16) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
                .symbolEffect(.pulse)

            Text("Failed to load project")
                .font(.system(size: AppDesign.FontSize.title3, weight: .semibold))

            Button("Go Back") {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                    onClose()
                }
            }
            .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(NSColor.windowBackgroundColor))
    }

    @ViewBuilder
    private var sidebarContent: some View {
        SimpleEditorSidebar(viewModel: viewModel, onClose: handleClose)
            .navigationSplitViewColumnWidth(min: 280, ideal: 360, max: 420)
    }

    @ViewBuilder
    private var canvasContent: some View {
        ImageCanvas(viewModel: viewModel)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(NSColor.windowBackgroundColor))
    }

    private func handleClose() {
        saveTask?.cancel()
        Task {
            await saveProjectState(immediate: true)
            onClose()
        }
    }

    @ViewBuilder
    private var editorContent: some View {
        NavigationSplitView {
            sidebarContent
        } detail: {
            canvasContent
        }
        .navigationSplitViewStyle(.balanced)
        .navigationTitle(project?.name ?? "Project")
        .frame(minWidth: 700, minHeight: 500)
        .background(
            Button("") {
                if viewModel.currentStep == .touchup {
                    viewModel.undo()
                }
            }
            .keyboardShortcut("z", modifiers: .command)
            .hidden()
        )
        .task {
            await viewModel.env.preloadSAMModel()
        }
        // Error alert for user feedback
        .alert("Error", isPresented: $viewModel.showErrorAlert) {
            Button("OK") {
                viewModel.lastError = nil
            }
            if viewModel.lastError?.isRecoverable == true {
                Button("Retry") {
                    viewModel.lastError = nil
                }
            }
        } message: {
            if let error = viewModel.lastError {
                VStack {
                    Text(error.localizedDescription)
                    if let suggestion = error.suggestedAction {
                        Text(suggestion)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .onChange(of: viewModel.currentStep) { _, newStep in
            // Debounced auto-save on step change
            scheduleSave()
        }
        .onChange(of: viewModel.selectedPreset) { _, _ in
            scheduleSave()
        }
        .onDisappear {
            // Ensure save on disappear
            saveTask?.cancel()
            Task {
                await saveProjectState(immediate: true)
            }
        }
    }

    /// Ask VLM for a better descriptive project name (runs in background)
    private func requestBetterProjectName() async {
        guard let imagePath = viewModel.inputImagePath else { return }

        let coordinator = ModelLoadingCoordinator.shared

        // Only proceed if VLM is ready
        guard coordinator.isVLMReady else { return }

        do {
            // Ask VLM for a short descriptive name
            let betterName = try await coordinator.generateProjectName(imagePath: imagePath)

            // Update project name if we got a valid response
            if !betterName.isEmpty, var proj = project {
                // Capitalize nicely
                let formattedName = betterName.split(separator: " ")
                    .map { $0.prefix(1).uppercased() + $0.dropFirst().lowercased() }
                    .joined(separator: " ")

                // Only update if different from current
                if proj.name != formattedName {
                    proj.name = formattedName
                    proj.touch()
                    try? ProjectManager.shared.saveProject(proj)
                    await MainActor.run {
                        project = proj
                    }
                    print("[ProjectEditor] Updated project name to: \(formattedName)")
                }
            }
        } catch {
            print("[ProjectEditor] Failed to get better project name: \(error)")
        }
    }

    /// Schedule a debounced save
    private func scheduleSave() {
        // Cancel any pending save
        saveTask?.cancel()

        // Schedule new save after debounce interval
        saveTask = Task {
            try? await Task.sleep(nanoseconds: saveDebounceMs * 1_000_000)

            // Check if cancelled
            guard !Task.isCancelled else { return }

            await saveProjectState(immediate: false)
        }
    }

    private func loadProject() async {
        // Load project from disk
        guard let loadedProject = ProjectManager.shared.loadProject(id: projectId) else {
            isLoading = false
            return
        }

        project = loadedProject

        // Load saved metadata to check what we need to restore
        let metadata = ProjectManager.shared.loadMetadata(for: projectId)
        let savedPrompt = metadata?.textPrompt
        let savedMaskIndices = metadata?.selectedMaskIndices
        let savedModelPath = metadata?.generatedModelPath
        let targetStep = SimpleEditorViewModel.Step(rawValue: loadedProject.workflowStep) ?? .input

        // Restore generation settings
        if let metadata = metadata {
            if let presetRaw = metadata.selectedPreset {
                // Try new preset format first, then fallback to migrating old format
                if let preset = GenerationPreset(rawValue: presetRaw) {
                    viewModel.selectedPreset = preset
                } else {
                    // Migrate old preset names to new ones
                    let migratedPreset: GenerationPreset = switch presetRaw {
                    case "Draft": .miniDraft
                    case "Normal": .miniNormal
                    case "High": .miniHigh
                    case "Max": .miniMax
                    case "Ultra": .stdNormal
                    default: SettingsManager.shared.defaultPreset
                    }
                    viewModel.selectedPreset = migratedPreset
                }
            }
            if let steps = metadata.customSteps {
                viewModel.customSteps = CGFloat(steps)
            }
            if let resolution = metadata.customResolution {
                viewModel.customResolution = CGFloat(resolution)
            }
        }

        // Load source image into view model
        let sourceImagePath = PathManager.projectSourceImagePath(for: projectId)
        guard FileManager.default.fileExists(atPath: sourceImagePath.path) else {
            isLoading = false
            return
        }

        // Check for saved segmentation data first (skip VLM/SAM if available)
        if let savedSegData = ProjectManager.shared.loadSegmentationData(for: projectId) {
            // Use the fast path - restore from saved masks directly
            print("[ProjectEditor] Found saved segmentation data, using fast restore")
            viewModel.loadImageWithSavedSegmentations(
                from: sourceImagePath,
                savedSegmentations: savedSegData.segmentations,
                autoDetectedLabel: savedSegData.autoDetectedLabel
            )
        } else {
            // No saved segmentation - use normal path (runs VLM/SAM)
            viewModel.loadImageWithSavedState(
                from: sourceImagePath,
                savedPrompt: savedPrompt,
                savedMaskIndices: savedMaskIndices
            )
        }

        // Wait for initialization to complete
        while viewModel.isInitializingProject {
            try? await Task.sleep(nanoseconds: 50_000_000) // 50ms polling
        }

        // Restore editable mask if user had touchup edits
        let maskPath = PathManager.projectMaskPath(for: projectId)
        if FileManager.default.fileExists(atPath: maskPath.path),
           let maskImage = NSImage(contentsOf: maskPath) {
            viewModel.editableMaskImage = maskImage
            viewModel.hasMaskEdits = metadata?.hasMaskEdits ?? false
        }

        // Restore 3D model if it exists (check both .obj and .glb extensions)
        if savedModelPath != nil {
            if let existingModelPath = PathManager.existingProjectModelPath(for: projectId) {
                viewModel.generated3DModelURL = existingModelPath
                // Mark that we have a completed generation
                viewModel.generationStages[.saving] = StageProgress(status: .completed, progress: 1.0, detail: "")
            }
        }

        // Restore workflow step (after all data is loaded)
        // Also mark appropriate steps as visited so navigation works correctly
        if targetStep.rawValue > SimpleEditorViewModel.Step.segment.rawValue {
            // Mark all steps up to target as visited
            for step in SimpleEditorViewModel.Step.allCases {
                if step.rawValue <= targetStep.rawValue {
                    viewModel.visitedSteps.insert(step)
                }
            }
            withAnimation(.easeOut(duration: 0.25)) {
                viewModel.currentStep = targetStep
            }

            // If restoring to postProcess step with a model, trigger mesh analysis
            if targetStep == .postProcess && viewModel.generated3DModelURL != nil {
                Task {
                    await viewModel.analyzeMesh()
                }
            }
        }

        isLoading = false
    }

    private func saveProjectState(immediate: Bool) async {
        // CRITICAL: Don't save during project initialization - it would overwrite the correct state
        guard !isLoading else { return }
        guard !viewModel.isInitializingProject else { return }
        guard var proj = project else { return }

        // Only save workflow step if we're past the segment step (not during initial load)
        // This prevents saving setup/input step when we should be on a later step
        let stepToSave = viewModel.currentStep.rawValue
        proj.workflowStep = stepToSave
        proj.touch()

        do {
            try ProjectManager.shared.saveProject(proj)
            project = proj

            // Save extended metadata
            var metadata = ProjectManager.shared.loadMetadata(for: projectId) ?? ProjectMetadata(projectId: projectId)
            metadata.selectedPreset = viewModel.selectedPreset.rawValue
            metadata.customSteps = Int(viewModel.customSteps)
            metadata.customResolution = Int(viewModel.customResolution)
            metadata.hasMaskEdits = viewModel.hasMaskEdits

            // Save text prompt from active segmentation
            if viewModel.activeSegmentationIndex < viewModel.segmentations.count {
                metadata.textPrompt = viewModel.segmentations[viewModel.activeSegmentationIndex].textPrompt
                metadata.selectedMaskIndices = Array(viewModel.segmentations[viewModel.activeSegmentationIndex].selectedMaskIndices)
            }

            // Save mask whenever we have one (not just on immediate save)
            if viewModel.currentStep.rawValue >= SimpleEditorViewModel.Step.segment.rawValue {
                await saveMaskImage()

                // Save full segmentation data (masks + prompts) for fast restore next time
                viewModel.saveSegmentationDataToProject()
            }

            // Save 3D model reference if generated
            if let modelURL = viewModel.generated3DModelURL {
                // Get the extension from the original model file
                let modelExt = modelURL.pathExtension.isEmpty ? "obj" : modelURL.pathExtension
                let projectModelPath = PathManager.projectModelPath(for: projectId, extension: modelExt)

                // Copy the model file if it doesn't exist OR if the source is different
                if !FileManager.default.fileExists(atPath: projectModelPath.path) ||
                   modelURL.path != projectModelPath.path {
                    // Remove any old model files (both .obj and .glb)
                    try? FileManager.default.removeItem(at: PathManager.projectModelPath(for: projectId, extension: "obj"))
                    try? FileManager.default.removeItem(at: PathManager.projectModelPath(for: projectId, extension: "glb"))
                    try? FileManager.default.copyItem(at: modelURL, to: projectModelPath)
                }
                metadata.generatedModelPath = "model.\(modelExt)"
            } else {
                // Clear model reference if no model exists
                metadata.generatedModelPath = nil
            }

            try ProjectManager.shared.saveMetadata(metadata)
        } catch {
            print("[ProjectEditor] Failed to save project state: \(error)")
        }
    }

    /// Save mask image on background thread
    private func saveMaskImage() async {
        guard let mask = viewModel.editableMaskImage ?? viewModel.activeSegmentation?.selectedMask else { return }

        let maskPath = PathManager.projectMaskPath(for: projectId)

        // Move expensive image processing off main thread
        await Task.detached(priority: .utility) {
            if let tiffData = mask.tiffRepresentation,
               let bitmap = NSBitmapImageRep(data: tiffData),
               let pngData = bitmap.representation(using: .png, properties: [:]) {
                try? pngData.write(to: maskPath)
            }
        }.value
    }
}
