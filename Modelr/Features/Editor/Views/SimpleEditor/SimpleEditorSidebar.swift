import SwiftUI

/// Sidebar for ContentViewSimple
struct SimpleEditorSidebar: View {
    @ObservedObject var viewModel: SimpleEditorViewModel
    var onClose: (() -> Void)? = nil  // Optional callback to return to project browser

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
                    // Display numbers (1-6) map to workflow steps
                    // Optional steps (Touchup, Settings) can be skipped
                    workflowStepRow(displayNumber: 1, step: .input, title: "Input", isLast: false, isOptional: false) {
                        inputContent
                    }
                    workflowStepRow(displayNumber: 2, step: .segment, title: "Segment", isLast: false, isOptional: false) {
                        segmentContent
                    }
                    workflowStepRow(displayNumber: 3, step: .touchup, title: "Touchup", isLast: false, isOptional: true) {
                        touchupContent
                    }
                    workflowStepRow(displayNumber: 4, step: .generateSettings, title: "Settings", isLast: false, isOptional: true) {
                        generateSettingsContent
                    }
                    workflowStepRow(displayNumber: 5, step: .generate, title: "Generate 3D", isLast: false, isOptional: false) {
                        generateContent
                    }
                    workflowStepRow(displayNumber: 6, step: .postProcess, title: "Post-Process", isLast: true, isOptional: false) {
                        postProcessContent
                    }
                }
                .padding(AppDesign.Spacing.p16)
                .animation(.spring(response: 0.28, dampingFraction: 0.82), value: viewModel.currentSetupSubStep)
                .animation(.spring(response: 0.25, dampingFraction: 0.85), value: viewModel.currentStep)
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
        let isActive = !isCompleted && viewModel.currentSetupSubStep == subStep
        let showContent = isActive || (subStep == .downloadingSegmentation && isActive) || (subStep == .downloadingGeneration && isActive)

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
                    // Download progress for download steps (Two-line format)
                    if (subStep == .downloadingSegmentation || subStep == .downloadingGeneration) && viewModel.downloadTotalBytes > 0 {
                        VStack(alignment: .leading, spacing: 2) {
                            ProgressView(value: Double(viewModel.downloadedBytes), total: Double(viewModel.downloadTotalBytes))
                                .progressViewStyle(.linear)
                                .tint(AppDesign.accent)
                                .padding(.bottom, 2)

                            // Line 1: Downloaded / Total • Speed
                            Text(viewModel.formattedDownloadProgress)
                                .font(.system(size: AppDesign.FontSize.xs, design: .monospaced))
                                .foregroundStyle(.secondary)

                            // Line 2: Time remaining
                            if !viewModel.formattedTimeRemaining.isEmpty {
                                Text(viewModel.formattedTimeRemaining)
                                    .font(.system(size: AppDesign.FontSize.xs, design: .monospaced))
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        .padding(.leading, 24)
                    }

                    // Console output
                    if let consoleLines = viewModel.setupConsoleOutput[subStep], !consoleLines.isEmpty {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(consoleLines.suffix(3), id: \.self) { line in
                                Text(line)
                                    .font(.system(size: AppDesign.FontSize.xs, design: .monospaced))
                                    .foregroundStyle(.tertiary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                        }
                        .padding(.leading, 24)
                        .padding(.top, AppDesign.Spacing.p2)
                    }
                }
            }
        }
    }

    // MARK: - Workflow Step Row Layout

    /// Workflow step row using Step enum for state logic with separate display number
    @ViewBuilder
    private func workflowStepRow(
        displayNumber: Int,
        step: SimpleEditorViewModel.Step,
        title: String,
        isLast: Bool,
        isOptional: Bool,
        @ViewBuilder content: () -> some View
    ) -> some View {
        let locked = !viewModel.isSetupComplete
        let isDone = locked ? false : isStepDone(step)
        let isActive = locked ? false : (viewModel.currentStep == step)
        let wasVisited = viewModel.visitedSteps.contains(step)
        // Optional steps only show content when active, not when done (they collapse immediately)
        let showContent = !locked && (isActive || (!isOptional && isDone))
        // An optional step is "skipped" if it's done (passed) but was never visited
        let isSkippedOptional = isOptional && isDone && !isActive && !wasVisited
        // Connector shows green if this step is done
        let connectorColor = locked ? Color.secondary.opacity(0.1) : (isDone ? AppDesign.success : Color.secondary.opacity(0.2))
        // Previous connector: for first step (Input), check setup complete; otherwise check if we're past the input step
        let prevConnectorColor = locked ? Color.secondary.opacity(0.1) : (displayNumber == 1 ? (viewModel.isSetupComplete ? AppDesign.success : Color.secondary.opacity(0.2)) : (isStepDone(previousStep(for: step)) ? AppDesign.success : Color.secondary.opacity(0.2)))

        VStack(alignment: .leading, spacing: 0) {
            if isSkippedOptional {
                // Skipped optional step - show circle with bypass arc around it
                // Alternate sides: odd steps go left, even steps go right
                let goesRight = displayNumber % 2 == 0

                // Top connector
                Rectangle()
                    .fill(prevConnectorColor)
                    .frame(width: 2, height: 8)
                    .padding(.leading, 11)

                HStack(spacing: AppDesign.Spacing.p12) {
                    // Circle with bypass arc overlay
                    workflowStepCircle(displayNumber: displayNumber, isDone: isDone, isActive: isActive, locked: locked, isOptional: isOptional, wasVisited: false)
                        .overlay(
                            // Bypass arc tightly around the circle (26x26 arc around 24x24 circle = 1px gap)
                            BypassArc(goesRight: goesRight)
                                .stroke(connectorColor, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                                .frame(width: 26, height: 26)
                        )

                    HStack(spacing: AppDesign.Spacing.p4) {
                        Text(title)
                            .font(.system(size: AppDesign.FontSize.body, weight: .regular))
                            .foregroundStyle(.tertiary)

                        Text("(skipped)")
                            .font(.system(size: AppDesign.FontSize.xs))
                            .foregroundStyle(.quaternary)
                    }

                    Spacer()
                }

                // Bottom connector
                if !isLast {
                    Rectangle()
                        .fill(connectorColor)
                        .frame(width: 2, height: 8)
                        .padding(.leading, 11)
                }
            } else {
                // Normal step layout
                // Top connector (always show for step 1+ since setup is step 0)
                Rectangle()
                    .fill(prevConnectorColor)
                    .frame(width: 2, height: 8)
                    .padding(.leading, 11)

                // Header: Circle + Title (always vertically centered together)
                HStack(spacing: AppDesign.Spacing.p12) {
                    workflowStepCircle(displayNumber: displayNumber, isDone: isDone, isActive: isActive, locked: locked, isOptional: isOptional, wasVisited: wasVisited)

                    HStack(spacing: AppDesign.Spacing.p4) {
                        Text(title)
                            .font(.system(size: AppDesign.FontSize.body, weight: isActive ? .semibold : .regular))
                            .foregroundStyle(locked ? .tertiary : (isActive ? .primary : (isOptional ? .tertiary : .secondary)))
                            .animation(.easeInOut(duration: 0.2), value: isActive)

                        if isOptional && !isActive && !isDone {
                            Text("(optional)")
                                .font(.system(size: AppDesign.FontSize.xs))
                                .foregroundStyle(.quaternary)
                        }
                    }

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
                        // Side connector bar (or matching spacer for last item)
                        if !isLast {
                            Rectangle()
                                .fill(connectorColor)
                                .frame(width: 2)
                                .padding(.leading, 11)
                                .animation(.easeInOut(duration: 0.25), value: isDone)
                        } else {
                            // Match connector bar width (2px + 11px padding = 13px)
                            Color.clear
                                .frame(width: 2)
                                .padding(.leading, 11)
                        }

                        // Content
                        VStack(alignment: .leading, spacing: AppDesign.Spacing.p8) {
                            content()
                        }
                        .padding(.top, AppDesign.Spacing.p8)
                        .padding(.bottom, AppDesign.Spacing.p4)
                    }
                    .fixedSize(horizontal: false, vertical: true)
                    .transition(.asymmetric(
                        insertion: .opacity.combined(with: .scale(scale: 0.98, anchor: .top)).animation(.spring(response: 0.25, dampingFraction: 0.85)),
                        removal: .opacity.animation(.easeOut(duration: 0.12))
                    ))
                } else if !isLast {
                    // Collapsed connector
                    Rectangle()
                        .fill(connectorColor)
                        .frame(width: 2, height: 12)
                        .padding(.leading, 11)
                }
            }
        }
        .opacity(locked ? 0.6 : 1.0)
        .animation(.spring(response: 0.25, dampingFraction: 0.8), value: showContent)
        .animation(.spring(response: 0.22, dampingFraction: 0.78), value: isDone)
    }

    /// Shape for bypass arc around skipped optional steps - semicircle on one side
    private struct BypassArc: Shape {
        var goesRight: Bool = false

        func path(in rect: CGRect) -> Path {
            var path = Path()
            let center = CGPoint(x: rect.midX, y: rect.midY)
            let radius = rect.width / 2

            if goesRight {
                // Arc on the right side (from top to bottom, going right)
                path.addArc(center: center, radius: radius, startAngle: .degrees(-90), endAngle: .degrees(90), clockwise: false)
            } else {
                // Arc on the left side (from top to bottom, going left)
                path.addArc(center: center, radius: radius, startAngle: .degrees(-90), endAngle: .degrees(90), clockwise: true)
            }
            return path
        }
    }

    @ViewBuilder
    private func workflowStepCircle(displayNumber: Int, isDone: Bool, isActive: Bool, locked: Bool = false, isOptional: Bool = false, wasVisited: Bool = true) -> some View {
        // For optional steps: only show as "skipped" (grayed) if done but NOT visited
        let isSkipped = isOptional && isDone && !wasVisited

        ZStack {
            Circle()
                // Skipped optional steps show grayed circle; visited steps (optional or not) show green when done
                .fill(locked ? Color.secondary.opacity(0.1) : (isDone ? (isSkipped ? Color.secondary.opacity(0.15) : AppDesign.success) : (isActive ? AppDesign.accent : Color.secondary.opacity(0.2))))
                .frame(width: 24, height: 24)

            if isDone && !locked && !isSkipped {
                // Completed steps (including visited optional steps) get checkmark
                Image(systemName: "checkmark")
                    .font(.system(size: AppDesign.FontSize.caption, weight: .bold))
                    .foregroundStyle(.white)
                    .transition(.scale.combined(with: .opacity))
            } else {
                Text("\(displayNumber)")
                    .font(.system(size: AppDesign.FontSize.caption, weight: .bold, design: .monospaced))
                    .foregroundStyle(locked ? Color.secondary.opacity(0.5) : (isActive ? Color.white : Color.secondary.opacity(isSkipped ? 0.4 : 1)))
            }
        }
        .animation(.spring(response: 0.22, dampingFraction: 0.72), value: isDone)
        .animation(.spring(response: 0.2, dampingFraction: 0.75), value: isActive)
    }

    // MARK: - Step State Helpers

    /// Check if a step is done (current step is past this step)
    private func isStepDone(_ step: SimpleEditorViewModel.Step) -> Bool {
        switch step {
        case .setup: return viewModel.isSetupComplete
        case .input: return viewModel.inputImage != nil
        case .segment: return viewModel.currentStep.rawValue > step.rawValue
        case .touchup: return viewModel.currentStep.rawValue > step.rawValue
        case .generateSettings: return viewModel.currentStep.rawValue > step.rawValue
        case .generate: return viewModel.currentStep == .postProcess
        case .postProcess: return false // Final step is never "done" in this sense
        }
    }

    /// Get the previous step in the workflow for connector color logic
    private func previousStep(for step: SimpleEditorViewModel.Step) -> SimpleEditorViewModel.Step {
        switch step {
        case .setup: return .setup
        case .input: return .setup
        case .segment: return .input
        case .touchup: return .segment
        case .generateSettings: return .touchup
        case .generate: return .generateSettings
        case .postProcess: return .generate
        }
    }

    // MARK: - Header

    @ViewBuilder
    private var titleArea: some View {
        HStack {
            if let onClose = onClose {
                Button {
                    onClose()
                } label: {
                    HStack(spacing: AppDesign.Spacing.p4) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: AppDesign.FontSize.caption, weight: .semibold))
                        Text("Projects")
                            .font(.system(size: AppDesign.FontSize.subheadline, weight: .medium))
                    }
                    .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }

            Spacer()

            AppDesign.HeaderText(text: "Modelr", size: AppDesign.FontSize.title2)

            if onClose != nil {
                Spacer()
            }
        }
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
                VStack(alignment: .leading, spacing: AppDesign.Spacing.p12) {
                    SegmentationPanel(viewModel: viewModel)

                    sectionFooter {
                        // Decision prompt
                        VStack(alignment: .leading, spacing: AppDesign.Spacing.p6) {
                            Text("Does the mask look accurate?")
                                .font(.system(size: AppDesign.FontSize.subheadline, weight: .medium))
                                .foregroundStyle(.primary)
                            Text("Check if your object is fully masked")
                                .font(.system(size: AppDesign.FontSize.caption))
                                .foregroundStyle(.secondary)
                        }
                        .padding(.bottom, AppDesign.Spacing.p4)

                        // Generate with preset row
                        generateWithPresetRow

                        // Secondary option
                        AppDesign.InlineButton("Refine Mask", icon: "wand.and.stars") {
                            viewModel.startTouchup()
                        }
                        .opacity(viewModel.totalValidMasks == 0 ? 0.5 : 1)
                        .disabled(viewModel.totalValidMasks == 0)

                        AppDesign.InlineButton(viewModel.backButtonLabel, icon: "arrow.left") {
                            viewModel.handleBackAction()
                        }

                        // Restore cached generation option
                        if viewModel.hasCachedGeneration {
                            Divider()
                                .padding(.vertical, AppDesign.Spacing.p4)

                            restoreCachedModelButton
                        }
                    }
                }
                .transition(.asymmetric(
                    insertion: .opacity.animation(.easeOut(duration: 0.18)),
                    removal: .opacity.animation(.easeOut(duration: 0.1))
                ))
            } else {
                AppDesign.CompletedRow("\(viewModel.totalValidMasks) \(viewModel.totalValidMasks == 1 ? "object" : "objects") selected")
                    .transition(.opacity.animation(.easeOut(duration: 0.15)))
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
                VStack(alignment: .leading, spacing: AppDesign.Spacing.p12) {
                    TouchupPanel(viewModel: viewModel)

                    sectionFooter {
                        // Generate with preset row (same as segment tab)
                        generateWithPresetRow

                        AppDesign.InlineButton(viewModel.backButtonLabel, icon: "arrow.left") {
                            viewModel.handleBackAction()
                        }

                        // Restore cached generation option
                        if viewModel.hasCachedGeneration {
                            Divider()
                                .padding(.vertical, AppDesign.Spacing.p4)

                            restoreCachedModelButton
                        }
                    }
                }
                .transition(.asymmetric(
                    insertion: .opacity.animation(.easeOut(duration: 0.18)),
                    removal: .opacity.animation(.easeOut(duration: 0.1))
                ))
            }
            // Optional step - no completed row shown when done
        }
        .alert("Lose Touchup Changes?", isPresented: $viewModel.showBackWarning) {
            Button("Cancel", role: .cancel) { }
            Button("Go Back", role: .destructive) { viewModel.goBack() }
        } message: {
            Text("Your mask edits will be lost. You'll return to the previous step.")
        }
    }

    @ViewBuilder
    private var generateSettingsContent: some View {
        Group {
            if viewModel.currentStep == .generateSettings {
                GenerationSettingsPanel(viewModel: viewModel)

                sectionFooter {
                    AppDesign.GlassButton("Generate Model", icon: "sparkles") {
                        viewModel.startGeneration()
                    }
                    AppDesign.InlineButton(viewModel.backButtonLabel, icon: "arrow.left") {
                        viewModel.handleBackAction()
                    }
                }
            }
            // Optional step - no completed row shown when done
        }
    }

    @ViewBuilder
    private var generateContent: some View {
        Group {
            if viewModel.currentStep == .generate {
                GenerationPanel(viewModel: viewModel)

                sectionFooter {
                    if viewModel.isGenerating {
                        // During generation - show stop button
                        AppDesign.GlassButtonSecondary("Stop Generation", icon: "stop.fill", destructive: true) {
                            viewModel.stopGeneration()
                        }
                    } else if viewModel.isInHandoff {
                        // During handoff - show brief message (GenerationPanel shows detailed progress)
                        HStack(spacing: AppDesign.Spacing.p6) {
                            ProgressView()
                                .controlSize(.small)
                                .scaleEffect(0.7)
                            Text("Preparing model...")
                                .font(.system(size: AppDesign.FontSize.caption))
                                .foregroundStyle(.secondary)
                        }
                    } else if let _ = viewModel.generated3DModelURL {
                        // Has model (came back from PostProcess or generation complete)
                        AppDesign.GlassButton("Continue to Post-Process", icon: "arrow.right") {
                            viewModel.transitionToPostProcess()
                        }
                        AppDesign.InlineButton(viewModel.backButtonLabel, icon: "arrow.left") {
                            viewModel.handleBackAction()
                        }
                    } else {
                        // No model, not generating - show back option (stopped/failed/idle state)
                        AppDesign.InlineButton(viewModel.backButtonLabel, icon: "arrow.left") {
                            viewModel.handleBackAction()
                        }
                    }
                }
            } else if viewModel.currentStep == .postProcess {
                AppDesign.CompletedRow("Model generated")
            }
        }
        .alert("Go Back?", isPresented: $viewModel.showDiscardModelWarning) {
            Button("Cancel", role: .cancel) { }
            Button("Go Back", role: .destructive) { viewModel.goBack() }
        } message: {
            Text("Your 3D model will be saved and can be restored later from the Segment step.")
        }
    }

    @ViewBuilder
    private var postProcessContent: some View {
        if viewModel.currentStep == .postProcess {
            PostProcessPanel(viewModel: viewModel)

            sectionFooter {
                AppDesign.InlineButton(viewModel.backButtonLabel, icon: "arrow.left") {
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

    // MARK: - Restore Cached Model Button

    @ViewBuilder
    private var restoreCachedModelButton: some View {
        HStack(spacing: AppDesign.Spacing.p8) {
            Image(systemName: "arrow.uturn.forward")
                .font(.system(size: AppDesign.FontSize.caption))
                .foregroundStyle(AppDesign.accent)
            VStack(alignment: .leading, spacing: 2) {
                Text("Restore Previous Model")
                    .font(.system(size: AppDesign.FontSize.subheadline, weight: .medium))
                    .foregroundStyle(AppDesign.accent)
                Text("Return to your generated 3D model")
                    .font(.system(size: AppDesign.FontSize.xs))
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(AppDesign.Spacing.p8)
        .background(AppDesign.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        .contentShape(Rectangle())
        .onTapGesture {
            withStandardSpring {
                viewModel.restoreCachedGeneration()
            }
        }
    }

    // MARK: - Generate with Preset Row

    @ViewBuilder
    private var generateWithPresetRow: some View {
        VStack(alignment: .leading, spacing: AppDesign.Spacing.p6) {
            // Split button: Generate action + Preset dropdown
            HStack(spacing: 0) {
                // Main generate button
                Button {
                    viewModel.generateImmediately(with: viewModel.selectedPreset)
                } label: {
                    HStack(spacing: AppDesign.Spacing.p6) {
                        Image(systemName: "sparkles")
                            .font(.system(size: 11))
                        Text("Generate with")
                            .font(.system(size: AppDesign.FontSize.subheadline, weight: .semibold))
                    }
                    .foregroundStyle(.white)
                    .padding(.leading, AppDesign.Spacing.p10)
                    .padding(.trailing, AppDesign.Spacing.p6)
                    .padding(.vertical, AppDesign.Spacing.p6)
                }
                .buttonStyle(.plain)

                // Separator
                Rectangle()
                    .fill(Color.white.opacity(0.3))
                    .frame(width: 1)
                    .padding(.vertical, 4)

                // Preset dropdown menu
                Menu {
                    // Standard presets (use mini model)
                    ForEach(GenerationPreset.allCases.filter { !$0.usesHunyuan21 }, id: \.self) { preset in
                        Button {
                            viewModel.selectedPreset = preset
                            viewModel.customSteps = CGFloat(preset.steps)
                            viewModel.customResolution = CGFloat(preset.resolution)
                        } label: {
                            HStack {
                                Text(preset.rawValue)
                                if !viewModel.isSmallModelDownloaded {
                                    Image(systemName: "arrow.down.circle")
                                        .foregroundStyle(.orange)
                                }
                                Spacer()
                                Text(preset.estimatedTime)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }

                    Divider()

                    // Hunyuan 2.1 presets (larger model)
                    Section {
                        ForEach(GenerationPreset.allCases.filter { $0.usesHunyuan21 }, id: \.self) { preset in
                            Button {
                                viewModel.selectedPreset = preset
                                viewModel.customSteps = CGFloat(preset.steps)
                                viewModel.customResolution = CGFloat(preset.resolution)
                            } label: {
                                HStack {
                                    Text(preset.rawValue)
                                    if !PathManager.isHunyuan21Downloaded {
                                        Image(systemName: "arrow.down.circle.fill")
                                            .foregroundStyle(.orange)
                                    }
                                    Spacer()
                                    Text(preset.estimatedTime)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    } header: {
                        Label("Hunyuan 2.1", systemImage: "sparkles")
                    }

                    Divider()

                    // Custom settings option - goes to settings step
                    Button {
                        viewModel.transitionToGenerateSettings()
                    } label: {
                        Label("Custom Settings", systemImage: "slider.horizontal.3")
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(viewModel.selectedPreset.rawValue)
                            .font(.system(size: AppDesign.FontSize.caption, weight: .medium))
                        Image(systemName: "chevron.down")
                            .font(.system(size: 9, weight: .semibold))
                    }
                    .foregroundStyle(.white)
                    .padding(.leading, AppDesign.Spacing.p6)
                    .padding(.vertical, AppDesign.Spacing.p6)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)

                // Explicit trailing space (Menu ignores label padding)
                Spacer().frame(width: AppDesign.Spacing.p10)
            }
            .background(AppDesign.accent, in: RoundedRectangle(cornerRadius: 6))
            .opacity(viewModel.totalValidMasks == 0 ? 0.5 : 1)
            .allowsHitTesting(viewModel.totalValidMasks > 0)

            // Download warning if needed
            if !viewModel.isSmallModelDownloaded {
                HStack(spacing: AppDesign.Spacing.p4) {
                    Image(systemName: "arrow.down.circle")
                        .font(.system(size: AppDesign.FontSize.xs))
                        .foregroundStyle(AppDesign.warning)
                    Text("Will download \(SetupModelChoice.fast.downloadSize) on first use")
                        .font(.system(size: AppDesign.FontSize.xs))
                        .foregroundStyle(AppDesign.warning)
                }
            }

            // Hunyuan 2.1 download warning
            if viewModel.selectedPreset.usesHunyuan21 && !PathManager.isHunyuan21Downloaded {
                HStack(spacing: AppDesign.Spacing.p4) {
                    Image(systemName: "arrow.down.circle.fill")
                        .font(.system(size: AppDesign.FontSize.xs))
                        .foregroundStyle(AppDesign.warning)
                    Text("Hunyuan 2.1 (\(viewModel.selectedPreset.modelDownloadSize)) will download on first use")
                        .font(.system(size: AppDesign.FontSize.xs))
                        .foregroundStyle(AppDesign.warning)
                }
            }
        }
    }
}
