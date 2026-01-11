import SwiftUI

/// Sidebar for Text-to-Model workflow
/// Simplified flow: Setup → Prompt+Settings → [Autonomous Generation] → Post-Process
struct TextToModelSidebar: View {
    @ObservedObject var viewModel: SimpleEditorViewModel
    var onClose: (() -> Void)? = nil

    @State private var showCancelGenerationAlert = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            titleArea

            Divider()
                .padding(.horizontal, AppDesign.Spacing.p16)

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    // Setup step (same as image-to-model)
                    setupStepRow

                    // Simplified Text-to-Model workflow
                    workflowStepRow(displayNumber: 1, step: .prompt, title: "Create", isLast: false) {
                        promptAndSettingsContent
                    }
                    workflowStepRow(displayNumber: 2, step: .generate, title: "Generate", isLast: false) {
                        generateContent
                    }
                    workflowStepRow(displayNumber: 3, step: .postProcess, title: "Post-Process", isLast: true) {
                        postProcessContent
                    }
                }
                .padding(AppDesign.Spacing.p16)
            }

            Spacer()

            if viewModel.env.isProcessing || viewModel.isGeneratingT2I {
                statusFooter
            }

            logoFooter
        }
        .background(.ultraThinMaterial)
    }

    // MARK: - Logo Footer

    @ViewBuilder
    private var logoFooter: some View {
        HStack {
            AppDesign.HeaderText(text: "Modelr", size: AppDesign.FontSize.subheadline)
                .opacity(0.4)
            Spacer()
        }
        .padding(.horizontal, AppDesign.Spacing.p16)
        .padding(.bottom, AppDesign.Spacing.p12)
    }

    // MARK: - Title Area

    @ViewBuilder
    private var titleArea: some View {
        HStack {
            if let onClose = onClose {
                Button {
                    if viewModel.isGenerating || viewModel.isGeneratingT2I {
                        showCancelGenerationAlert = true
                    } else {
                        onClose()
                    }
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

            // Mode indicator
            HStack(spacing: 4) {
                Image(systemName: "text.cursor")
                    .font(.system(size: 10))
                Text("Text to Model")
                    .font(.system(size: 10, weight: .medium))
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.secondary.opacity(0.1), in: Capsule())
        }
        .padding(.horizontal, AppDesign.Spacing.p16)
        .padding(.top, AppDesign.Spacing.p12)
        .padding(.bottom, AppDesign.Spacing.p12)
        .alert("Cancel Generation?", isPresented: $showCancelGenerationAlert) {
            Button("Continue", role: .cancel) { }
            Button("Cancel & Exit", role: .destructive) {
                viewModel.stopTextToModelPipeline()
                onClose?()
            }
        } message: {
            Text("Generation is in progress. Canceling will lose all progress.")
        }
    }

    // MARK: - Setup Step Row

    @ViewBuilder
    private var setupStepRow: some View {
        let isActive = viewModel.currentStep == .setup
        let isDone = viewModel.isSetupComplete

        VStack(alignment: .leading, spacing: 0) {
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

            if !isDone {
                Rectangle()
                    .fill(Color.secondary.opacity(0.2))
                    .frame(width: 2, height: 12)
                    .padding(.leading, 11)
            } else {
                Rectangle()
                    .fill(AppDesign.success)
                    .frame(width: 2, height: 8)
                    .padding(.leading, 11)
            }
        }
    }

    // MARK: - Workflow Step Row

    @ViewBuilder
    private func workflowStepRow(
        displayNumber: Int,
        step: TextToModelStep,
        title: String,
        isLast: Bool,
        @ViewBuilder content: () -> some View
    ) -> some View {
        let locked = !viewModel.isSetupComplete
        let isDone = isStepDone(step)
        let isActive = locked ? false : (viewModel.t2mCurrentStep == step)
        let showContent = !locked && isActive
        let connectorColor = locked ? Color.secondary.opacity(0.1) : (isDone ? AppDesign.success : Color.secondary.opacity(0.2))

        VStack(alignment: .leading, spacing: 0) {
            // Top connector
            Rectangle()
                .fill(connectorColor)
                .frame(width: 2, height: 8)
                .padding(.leading, 11)

            // Header
            HStack(spacing: AppDesign.Spacing.p12) {
                workflowStepCircle(displayNumber: displayNumber, isDone: isDone, isActive: isActive, locked: locked)

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

            // Content
            if showContent {
                HStack(alignment: .top, spacing: AppDesign.Spacing.p12) {
                    if !isLast {
                        Rectangle()
                            .fill(connectorColor)
                            .frame(width: 2)
                            .padding(.leading, 11)
                    } else {
                        Color.clear
                            .frame(width: 2)
                            .padding(.leading, 11)
                    }

                    VStack(alignment: .leading, spacing: AppDesign.Spacing.p8) {
                        content()
                    }
                    .padding(.top, AppDesign.Spacing.p8)
                    .padding(.bottom, AppDesign.Spacing.p4)
                }
                .fixedSize(horizontal: false, vertical: true)
            } else if !isLast {
                Rectangle()
                    .fill(connectorColor)
                    .frame(width: 2, height: 12)
                    .padding(.leading, 11)
            }
        }
        .opacity(locked ? 0.6 : 1.0)
    }

    @ViewBuilder
    private func workflowStepCircle(displayNumber: Int, isDone: Bool, isActive: Bool, locked: Bool) -> some View {
        ZStack {
            Circle()
                .fill(locked ? Color.secondary.opacity(0.1) : (isDone ? AppDesign.success : (isActive ? AppDesign.accent : Color.secondary.opacity(0.2))))
                .frame(width: 24, height: 24)

            if isDone && !locked {
                Image(systemName: "checkmark")
                    .font(.system(size: AppDesign.FontSize.caption, weight: .bold))
                    .foregroundStyle(.white)
            } else {
                Text("\(displayNumber)")
                    .font(.system(size: AppDesign.FontSize.caption, weight: .bold, design: .monospaced))
                    .foregroundStyle(locked ? Color.secondary.opacity(0.5) : (isActive ? Color.white : Color.secondary))
            }
        }
    }

    private func isStepDone(_ step: TextToModelStep) -> Bool {
        viewModel.t2mCurrentStep.rawValue > step.rawValue
    }

    // MARK: - Combined Prompt + Settings Content

    @ViewBuilder
    private var promptAndSettingsContent: some View {
        VStack(alignment: .leading, spacing: AppDesign.Spacing.p16) {
            // Text prompt input
            VStack(alignment: .leading, spacing: AppDesign.Spacing.p4) {
                Text("Describe your 3D object")
                    .font(.system(size: AppDesign.FontSize.subheadline, weight: .medium))

                TextEditor(text: $viewModel.t2mPrompt)
                    .font(.system(size: AppDesign.FontSize.body))
                    .frame(minHeight: 60, maxHeight: 100)
                    .padding(8)
                    .background(Color.primary.opacity(0.03))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(Color.primary.opacity(0.1), lineWidth: 1)
                    )

                Text("Example: \"A red ceramic coffee mug\"")
                    .font(.system(size: AppDesign.FontSize.xs))
                    .foregroundStyle(.tertiary)
            }

            // Quality preset selection
            VStack(alignment: .leading, spacing: AppDesign.Spacing.p8) {
                Text("Quality")
                    .font(.system(size: AppDesign.FontSize.subheadline, weight: .medium))

                GenerationSettingsPanel(viewModel: viewModel)
            }

            // Advanced settings (collapsible)
            DisclosureGroup("Advanced T2I Settings") {
                VStack(alignment: .leading, spacing: AppDesign.Spacing.p8) {
                    // Negative prompt
                    VStack(alignment: .leading, spacing: AppDesign.Spacing.p4) {
                        Text("Negative prompt")
                            .font(.system(size: AppDesign.FontSize.caption))
                            .foregroundStyle(.secondary)

                        TextField("Extra things to avoid...", text: $viewModel.t2mNegativePrompt)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: AppDesign.FontSize.caption))
                    }

                    // Seed
                    HStack {
                        Text("Seed")
                            .font(.system(size: AppDesign.FontSize.caption))
                            .foregroundStyle(.secondary)
                        Spacer()
                        TextField("Random", value: $viewModel.t2mSeed, format: .number)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 100)
                            .font(.system(size: AppDesign.FontSize.caption))
                    }
                }
                .padding(.top, AppDesign.Spacing.p8)
            }
            .font(.system(size: AppDesign.FontSize.caption, weight: .medium))
            .foregroundStyle(.secondary)

            // Single generate button that triggers entire pipeline
            AppDesign.GlassButton("Generate 3D Model", icon: "cube.fill") {
                viewModel.startTextToModelPipeline()
            }
            .disabled(viewModel.t2mPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .opacity(viewModel.t2mPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0.5 : 1)
        }
    }

    // MARK: - Generate Content (shows progress of autonomous pipeline)

    @ViewBuilder
    private var generateContent: some View {
        VStack(alignment: .leading, spacing: AppDesign.Spacing.p12) {
            // T2I Progress
            if viewModel.isGeneratingT2I {
                VStack(alignment: .leading, spacing: AppDesign.Spacing.p8) {
                    HStack(spacing: AppDesign.Spacing.p8) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Generating image...")
                            .font(.system(size: AppDesign.FontSize.subheadline))
                            .foregroundStyle(.secondary)
                    }

                    if viewModel.t2mProgress > 0 {
                        ProgressView(value: Double(viewModel.t2mProgress))
                            .progressViewStyle(.linear)
                            .tint(AppDesign.accent)

                        Text(viewModel.t2mProgressDetail)
                            .font(.system(size: AppDesign.FontSize.xs, design: .monospaced))
                            .foregroundStyle(.tertiary)
                    }
                }
            } else if viewModel.t2mGeneratedImage != nil && !viewModel.isGenerating {
                // Image generated, now processing
                AppDesign.CompletedRow("Image generated")

                if viewModel.segmentations.isEmpty {
                    HStack(spacing: AppDesign.Spacing.p8) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Detecting object...")
                            .font(.system(size: AppDesign.FontSize.subheadline))
                            .foregroundStyle(.secondary)
                    }
                } else if viewModel.editableMaskImage == nil {
                    AppDesign.CompletedRow("Object detected")
                    HStack(spacing: AppDesign.Spacing.p8) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Segmenting...")
                            .font(.system(size: AppDesign.FontSize.subheadline))
                            .foregroundStyle(.secondary)
                    }
                }
            }

            // 3D Generation Progress
            if viewModel.isGenerating {
                if viewModel.t2mGeneratedImage != nil {
                    AppDesign.CompletedRow("Image generated")
                    AppDesign.CompletedRow("Object segmented")
                }

                GenerationPanel(viewModel: viewModel)

                AppDesign.GlassButtonSecondary("Stop Generation", icon: "stop.fill", destructive: true) {
                    viewModel.stopTextToModelPipeline()
                }
                .padding(.top, AppDesign.Spacing.p8)
            }

            // Generation complete
            if !viewModel.isGenerating && !viewModel.isGeneratingT2I && viewModel.generated3DModelURL != nil {
                AppDesign.CompletedRow("Image generated")
                AppDesign.CompletedRow("Object segmented")
                AppDesign.CompletedRow("3D model generated")

                AppDesign.GlassButton("Continue to Post-Process", icon: "arrow.right") {
                    viewModel.transitionToPostProcess()
                }
                .padding(.top, AppDesign.Spacing.p8)
            }
        }
    }

    @ViewBuilder
    private var postProcessContent: some View {
        PostProcessPanel(viewModel: viewModel)
    }

    // MARK: - Status Footer

    @ViewBuilder
    private var statusFooter: some View {
        VStack(spacing: 0) {
            Divider()
            if viewModel.isGeneratingT2I {
                AppDesign.LoadingIndicator(text: viewModel.t2mProgressDetail.isEmpty ? "Generating image..." : viewModel.t2mProgressDetail)
                    .padding(AppDesign.Spacing.p16)
            } else {
                AppDesign.LoadingIndicator(text: viewModel.env.status)
                    .padding(AppDesign.Spacing.p16)
            }
        }
        .background(.ultraThinMaterial)
    }
}

// MARK: - Text-to-Model Step Enum (Simplified)

enum TextToModelStep: Int, CaseIterable {
    case prompt = 0      // Enter prompt + select settings
    case generate = 1    // Autonomous: T2I → VLM → SAM → Hunyuan
    case postProcess = 2 // Review and export
}
