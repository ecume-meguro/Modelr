import SwiftUI

/// Sidebar for ContentViewSimple
struct SimpleEditorSidebar: View {
    @ObservedObject var viewModel: SimpleEditorViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            titleArea

            Divider()
                .padding(.horizontal, AppDesign.Spacing.p16)

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    // Setup step (always first, collapses when complete)
                    setupStepRow

                    // Workflow steps - greyed out during setup
                    stepRow(stepNumber: 1, title: "Input", isLast: false, locked: !viewModel.isSetupComplete) {
                        inputContent
                    }
                    stepRow(stepNumber: 2, title: "Segment", isLast: false, locked: !viewModel.isSetupComplete) {
                        segmentContent
                    }
                    stepRow(stepNumber: 3, title: "Touchup", isLast: false, locked: !viewModel.isSetupComplete) {
                        touchupContent
                    }
                    stepRow(stepNumber: 4, title: "Generate 3D", isLast: false, locked: !viewModel.isSetupComplete) {
                        generateContent
                    }
                    stepRow(stepNumber: 5, title: "Post-Process", isLast: true, locked: !viewModel.isSetupComplete) {
                        postProcessContent
                    }
                }
                .padding(AppDesign.Spacing.p16)
                .animation(.easeInOut(duration: 0.3), value: viewModel.currentStep)
                .animation(.easeInOut(duration: 0.3), value: viewModel.currentSetupSubStep)
            }

            Spacer()

            if viewModel.inputImage != nil {
                startOverButton
            }

            if viewModel.env.isProcessing {
                statusFooter
            }
        }
        .background(.ultraThinMaterial)
    }

    // MARK: - Setup Step Row

    @ViewBuilder
    private var setupStepRow: some View {
        let isActive = viewModel.currentStep == .setup
        let isDone = viewModel.isSetupComplete

        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack(spacing: AppDesign.Spacing.p12) {
                ZStack {
                    Circle()
                        .fill(isDone ? AppDesign.success : (isActive ? AppDesign.accent : Color.secondary.opacity(0.2)))
                        .frame(width: 24, height: 24)

                    if isDone {
                        Image(systemName: "checkmark")
                            .font(.system(size: AppDesign.FontSize.caption, weight: .bold))
                            .foregroundStyle(.white)
                    } else {
                        Image(systemName: "gearshape.fill")
                            .font(.system(size: AppDesign.FontSize.caption, weight: .bold))
                            .foregroundStyle(isActive ? .white : .secondary)
                    }
                }

                Text("Setup")
                    .font(.system(size: AppDesign.FontSize.body, weight: isActive ? .semibold : .regular))
                    .foregroundStyle(isActive ? .primary : .secondary)

                Spacer()
            }

            // Subitems (only when active/incomplete)
            if isActive && !isDone {
                HStack(alignment: .top, spacing: AppDesign.Spacing.p12) {
                    // Side connector bar
                    Rectangle()
                        .fill(isDone ? AppDesign.success : Color.secondary.opacity(0.2))
                        .frame(width: 2)
                        .padding(.leading, 11)

                    VStack(alignment: .leading, spacing: AppDesign.Spacing.p12) {
                        ForEach(SimpleEditorViewModel.SetupSubStep.allCases, id: \.self) { subStep in
                            setupSubStepRow(subStep)
                        }
                    }
                    .padding(.top, AppDesign.Spacing.p8)
                    .padding(.bottom, AppDesign.Spacing.p4)
                }
                .fixedSize(horizontal: false, vertical: true)
            } else if !viewModel.isSetupComplete {
                // Collapsed connector when not active but not complete
                Rectangle()
                    .fill(Color.secondary.opacity(0.2))
                    .frame(width: 2, height: 12)
                    .padding(.leading, 11)
            } else {
                // Connector to next step
                Rectangle()
                    .fill(AppDesign.success)
                    .frame(width: 2, height: 8)
                    .padding(.leading, 11)
            }
        }
    }

    @ViewBuilder
    private func setupSubStepRow(_ subStep: SimpleEditorViewModel.SetupSubStep) -> some View {
        let isCompleted = viewModel.setupSubStepCompleted.contains(subStep)
        // For configuringEnvironment, show as active/spinning if it's running in background
        let isActive: Bool = {
            if subStep == .configuringEnvironment && viewModel.isConfiguringEnvironment && !isCompleted {
                return true
            }
            return viewModel.currentSetupSubStep == subStep && !isCompleted
        }()
        let showContent = viewModel.currentSetupSubStep == subStep && !isCompleted

        VStack(alignment: .leading, spacing: AppDesign.Spacing.p4) {
            // Subitem header
            HStack(spacing: AppDesign.Spacing.p8) {
                // Small indicator circle
                ZStack {
                    Circle()
                        .fill(isCompleted ? AppDesign.success : (isActive ? AppDesign.accent.opacity(0.8) : Color.secondary.opacity(0.2)))
                        .frame(width: 16, height: 16)

                    if isCompleted {
                        Image(systemName: "checkmark")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(.white)
                    } else if isActive {
                        ProgressView()
                            .controlSize(.mini)
                            .scaleEffect(0.6)
                    }
                }

                Text(subStep.rawValue)
                    .font(.system(size: AppDesign.FontSize.caption, weight: isActive ? .medium : .regular))
                    .foregroundStyle(isCompleted ? AppDesign.success : (isActive ? .primary : .secondary))
            }

            // Console output and progress (only for active substep)
            if showContent {
                VStack(alignment: .leading, spacing: AppDesign.Spacing.p4) {
                    // Download progress for download steps
                    if (subStep == .downloadingSegmentation || subStep == .downloadingGeneration) && viewModel.downloadTotalBytes > 0 {
                        VStack(alignment: .leading, spacing: AppDesign.Spacing.p4) {
                            ProgressView(value: Double(viewModel.downloadedBytes), total: Double(viewModel.downloadTotalBytes))
                                .progressViewStyle(.linear)
                                .tint(AppDesign.accent)

                            HStack {
                                Text(viewModel.formattedDownloadProgress)
                                    .font(.system(size: AppDesign.FontSize.xs, design: .monospaced))
                                    .foregroundStyle(.secondary)

                                Spacer()

                                Text(viewModel.formattedDownloadSpeed)
                                    .font(.system(size: AppDesign.FontSize.xs, design: .monospaced))
                                    .foregroundStyle(.secondary)

                                Text("•")
                                    .foregroundStyle(.tertiary)

                                Text(viewModel.formattedTimeRemaining)
                                    .font(.system(size: AppDesign.FontSize.xs, design: .monospaced))
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.leading, 24)
                    }

                    // Console output
                    if let consoleLines = viewModel.setupConsoleOutput[subStep], !consoleLines.isEmpty {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(consoleLines.suffix(5), id: \.self) { line in
                                Text(line)
                                    .font(.system(size: AppDesign.FontSize.xs, design: .monospaced))
                                    .foregroundStyle(.tertiary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                        }
                        .padding(.leading, 24)
                        .padding(.top, AppDesign.Spacing.p4)
                    }
                }
            }
        }
    }

    // MARK: - Step Row Layout

    @ViewBuilder
    private func stepRow(
        stepNumber: Int,
        title: String,
        isLast: Bool,
        locked: Bool = false,
        @ViewBuilder content: () -> some View
    ) -> some View {
        let isDone = locked ? false : isStepCompleted(stepNumber)
        let isActive = locked ? false : isStepActive(stepNumber)
        let showContent = !locked && (isActive || isDone)

        VStack(alignment: .leading, spacing: 0) {
            // Top connector (always show for step 1+ since setup is step 0)
            Rectangle()
                .fill(locked ? Color.secondary.opacity(0.1) : (stepNumber == 1 ? (viewModel.isSetupComplete ? AppDesign.success : Color.secondary.opacity(0.2)) : (isStepCompleted(stepNumber - 1) ? AppDesign.success : Color.secondary.opacity(0.2))))
                .frame(width: 2, height: 8)
                .padding(.leading, 11)

            // Header: Circle + Title (always vertically centered together)
            HStack(spacing: AppDesign.Spacing.p12) {
                stepCircle(stepNumber: stepNumber, isDone: isDone, isActive: isActive, locked: locked)

                Text(title)
                    .font(.system(size: AppDesign.FontSize.body, weight: isActive ? .semibold : .regular))
                    .foregroundStyle(locked ? .tertiary : (isActive ? .primary : .secondary))

                if locked {
                    Image(systemName: "lock.fill")
                        .font(.system(size: AppDesign.FontSize.xs))
                        .foregroundStyle(.tertiary)
                }

                Spacer()
            }

            // Content area with side connector
            if showContent {
                HStack(alignment: .top, spacing: AppDesign.Spacing.p12) {
                    // Side connector bar
                    if !isLast {
                        Rectangle()
                            .fill(isStepCompleted(stepNumber) ? AppDesign.success : Color.secondary.opacity(0.2))
                            .frame(width: 2)
                            .padding(.leading, 11)
                    } else {
                        Color.clear
                            .frame(width: 24)
                    }

                    // Content
                    VStack(alignment: .leading, spacing: AppDesign.Spacing.p8) {
                        content()
                    }
                    .padding(.top, AppDesign.Spacing.p8)
                    .padding(.bottom, AppDesign.Spacing.p4)
                }
                .fixedSize(horizontal: false, vertical: true)
            } else if !isLast {
                // Collapsed connector
                Rectangle()
                    .fill(locked ? Color.secondary.opacity(0.1) : (isStepCompleted(stepNumber) ? AppDesign.success : Color.secondary.opacity(0.2)))
                    .frame(width: 2, height: 12)
                    .padding(.leading, 11)
            }
        }
        .opacity(locked ? 0.6 : 1.0)
    }

    @ViewBuilder
    private func stepCircle(stepNumber: Int, isDone: Bool, isActive: Bool, locked: Bool = false) -> some View {
        ZStack {
            Circle()
                .fill(locked ? Color.secondary.opacity(0.1) : (isDone ? AppDesign.success : (isActive ? AppDesign.accent : Color.secondary.opacity(0.2))))
                .frame(width: 24, height: 24)

            if isDone && !locked {
                Image(systemName: "checkmark")
                    .font(.system(size: AppDesign.FontSize.caption, weight: .bold))
                    .foregroundStyle(.white)
            } else {
                Text("\(stepNumber)")
                    .font(.system(size: AppDesign.FontSize.caption, weight: .bold, design: .monospaced))
                    .foregroundStyle(locked ? Color.secondary.opacity(0.5) : (isActive ? Color.white : Color.secondary))
            }
        }
    }

    // MARK: - Step State

    private func isStepCompleted(_ stepNumber: Int) -> Bool {
        switch stepNumber {
        case 1: return viewModel.inputImage != nil
        case 2: return viewModel.currentStep == .touchup || viewModel.currentStep == .generate || viewModel.currentStep == .postProcess
        case 3: return viewModel.currentStep == .generate || viewModel.currentStep == .postProcess
        case 4: return viewModel.currentStep == .postProcess
        case 5: return false
        default: return false
        }
    }

    private func isStepActive(_ stepNumber: Int) -> Bool {
        switch stepNumber {
        case 1: return viewModel.currentStep == .input
        case 2: return viewModel.currentStep == .segment
        case 3: return viewModel.currentStep == .touchup
        case 4: return viewModel.currentStep == .generate
        case 5: return viewModel.currentStep == .postProcess
        default: return false
        }
    }

    // MARK: - Header

    @ViewBuilder
    private var titleArea: some View {
        AppDesign.HeaderText(text: "Modelr", size: AppDesign.FontSize.title2)
            .padding(.horizontal, AppDesign.Spacing.p16)
            .padding(.top, AppDesign.Spacing.p12)
            .padding(.bottom, AppDesign.Spacing.p12)
    }

    // MARK: - Step Content

    @ViewBuilder
    private var inputContent: some View {
        if viewModel.inputImage != nil {
            AppDesign.CompletedRow("Image loaded")
        } else {
            AppDesign.HintText("Drop an image or click 'Select Image' in the center area to begin.")
        }
    }

    @ViewBuilder
    private var segmentContent: some View {
        Group {
            if viewModel.currentStep == .segment {
                SegmentationPanel(viewModel: viewModel)

                sectionFooter {
                    AppDesign.GlassButton("Next: Touchup", icon: "wand.and.stars", disabled: viewModel.totalValidMasks == 0) {
                        viewModel.startTouchup()
                    }
                    AppDesign.InlineButton("Back to Input", icon: "arrow.left") {
                        viewModel.handleBackAction()
                    }
                }
            } else {
                AppDesign.CompletedRow("\(viewModel.totalValidMasks) \(viewModel.totalValidMasks == 1 ? "object" : "objects") selected")
            }
        }
        .alert("Discard Image?", isPresented: $viewModel.showDiscardImageWarning) {
            Button("Cancel", role: .cancel) { }
            Button("Discard", role: .destructive) { viewModel.goBack() }
        } message: {
            Text("This will return to the input screen and you'll need to reload the image.")
        }
    }

    @ViewBuilder
    private var touchupContent: some View {
        Group {
            if viewModel.currentStep == .touchup {
                TouchupPanel(viewModel: viewModel)

                sectionFooter {
                    AppDesign.GlassButton("Next: Generate 3D", icon: "cube.fill") {
                        viewModel.transitionToGenerate()
                    }
                    AppDesign.InlineButton("Back to Segment", icon: "arrow.left") {
                        viewModel.handleBackAction()
                    }
                }
            } else {
                AppDesign.CompletedRow("Mask refined")
            }
        }
        .alert("Lose Touchup Changes?", isPresented: $viewModel.showBackWarning) {
            Button("Cancel", role: .cancel) { }
            Button("Go Back", role: .destructive) { viewModel.goBack() }
        } message: {
            Text("You'll return to segmentation and can select a different region or add more points.")
        }
    }

    @ViewBuilder
    private var generateContent: some View {
        Group {
            if viewModel.currentStep == .generate {
                GenerationPanel(viewModel: viewModel)

                if !viewModel.isGenerating && viewModel.generated3DModelURL == nil {
                    sectionFooter {
                        AppDesign.GlassButton("Generate Model", icon: "sparkles") {
                            viewModel.generate3D()
                        }
                        AppDesign.InlineButton("Back to Touchup", icon: "arrow.left") {
                            viewModel.handleBackAction()
                        }
                    }
                } else if viewModel.isGenerating {
                    sectionFooter {
                        AppDesign.GlassButtonSecondary("Stop Generation", icon: "stop.fill", destructive: true) {
                            viewModel.stopGeneration()
                        }
                    }
                } else if viewModel.generated3DModelURL != nil {
                    sectionFooter {
                        AppDesign.GlassButton("Next: Post-Process", icon: "slider.horizontal.3") {
                            viewModel.transitionToPostProcess()
                        }
                        AppDesign.InlineButton("Back to Touchup", icon: "arrow.left") {
                            viewModel.handleBackAction()
                        }
                    }
                }
            } else if viewModel.currentStep == .postProcess {
                AppDesign.CompletedRow("Model generated")
            }
        }
        .alert("Discard 3D Model?", isPresented: $viewModel.showDiscardModelWarning) {
            Button("Cancel", role: .cancel) { }
            Button("Discard", role: .destructive) { viewModel.goBack() }
        } message: {
            Text("The generated 3D model will be kept on disk, but you'll return to touchup mode.")
        }
    }

    @ViewBuilder
    private var postProcessContent: some View {
        if viewModel.currentStep == .postProcess {
            PostProcessPanel(viewModel: viewModel)

            sectionFooter {
                AppDesign.InlineButton("Back to Generate", icon: "arrow.left") {
                    viewModel.handleBackAction()
                }
            }
        }
    }

    // MARK: - Footer Elements

    @ViewBuilder
    private var startOverButton: some View {
        HStack {
            Spacer()
            AppDesign.InlineDestructiveButton("Start Over", icon: "arrow.counterclockwise") {
                viewModel.showStartOverWarning = true
            }
        }
        .padding(.horizontal, AppDesign.Spacing.p16)
        .padding(.bottom, AppDesign.Spacing.p12)
        .alert("Start Over?", isPresented: $viewModel.showStartOverWarning) {
            Button("Cancel", role: .cancel) { }
            Button("Start Over", role: .destructive) { viewModel.clearAll() }
        } message: {
            Text("This will discard all progress and return to the home screen.")
        }
    }

    @ViewBuilder
    private var statusFooter: some View {
        VStack(spacing: 0) {
            Divider()
            AppDesign.LoadingIndicator(text: viewModel.env.status)
                .padding(AppDesign.Spacing.p16)
        }
        .background(.ultraThinMaterial)
    }

    @ViewBuilder
    private func sectionFooter(@ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: AppDesign.Spacing.p8) {
            content()
        }
        .padding(.top, AppDesign.Spacing.p12)
    }
}
