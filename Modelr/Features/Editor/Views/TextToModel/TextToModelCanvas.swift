import SwiftUI

/// Main canvas for Text-to-Model workflow
/// Simplified flow: Prompt → Autonomous Generation → Post-Process
struct TextToModelCanvas: View {
    @ObservedObject var viewModel: SimpleEditorViewModel

    var body: some View {
        VStack(spacing: 0) {
            // Show different content based on T2M step
            switch viewModel.t2mCurrentStep {
            case .prompt:
                promptInputView
            case .generate:
                generatingView
            case .postProcess:
                // Show the 3D model viewer (handled by parent view)
                if let image = viewModel.t2mGeneratedImage {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Color(NSColor.controlBackgroundColor))
                } else {
                    Color(NSColor.controlBackgroundColor)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(NSColor.windowBackgroundColor))
    }

    // MARK: - Prompt Input View

    private var examplePrompts: [String] {
        [
            "A red ceramic coffee mug",
            "A wooden treasure chest",
            "A green cactus in a pot",
            "A blue sports car"
        ]
    }

    @ViewBuilder
    private var promptInputView: some View {
        VStack(spacing: 24) {
            Spacer()

            // Icon
            ZStack {
                Circle()
                    .fill(Color.accentColor.opacity(0.1))
                    .frame(width: 80, height: 80)

                Image(systemName: "cube.fill")
                    .font(.system(size: 32))
                    .foregroundStyle(Color.accentColor)
            }

            // Title
            VStack(spacing: 8) {
                Text("Text to 3D Model")
                    .font(.system(size: 24, weight: .semibold))

                Text("Describe your object and we'll generate it in 3D")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
            }

            // Quick prompt suggestions
            VStack(spacing: 12) {
                Text("Try an example:")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.tertiary)

                HStack(spacing: 8) {
                    ForEach(examplePrompts, id: \.self) { prompt in
                        Button {
                            viewModel.t2mPrompt = prompt
                        } label: {
                            Text(prompt)
                                .font(.system(size: 11))
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .background(Color.primary.opacity(0.05))
                                .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Generating View (Autonomous Pipeline Progress)

    @ViewBuilder
    private var generatingView: some View {
        VStack(spacing: 32) {
            Spacer()

            // Show generated image if available
            if let image = viewModel.t2mGeneratedImage {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: 300, maxHeight: 300)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .shadow(color: .black.opacity(0.2), radius: 10, y: 5)
            } else {
                // Animated icon during T2I generation
                ZStack {
                    Circle()
                        .fill(Color.accentColor.opacity(0.1))
                        .frame(width: 100, height: 100)

                    Image(systemName: "wand.and.stars")
                        .font(.system(size: 40))
                        .foregroundStyle(Color.accentColor)
                        .symbolEffect(.variableColor.iterative)
                }
            }

            // Progress section
            VStack(spacing: 16) {
                // Current stage
                Text(currentStageTitle)
                    .font(.system(size: 18, weight: .semibold))

                // Progress indicators
                VStack(spacing: 12) {
                    // T2I Progress
                    if viewModel.isGeneratingT2I {
                        if viewModel.t2mProgress > 0 {
                            ProgressView(value: Double(viewModel.t2mProgress))
                                .progressViewStyle(.linear)
                                .frame(width: 280)
                                .tint(Color.accentColor)

                            Text(viewModel.t2mProgressDetail)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.secondary)
                        } else {
                            ProgressView()
                                .controlSize(.small)
                        }
                    }

                    // 3D Generation Progress
                    if viewModel.isGenerating {
                        if let diffusionStage = viewModel.generationStages[.diffusion],
                           diffusionStage.status == .inProgress {
                            ProgressView(value: diffusionStage.progress)
                                .progressViewStyle(.linear)
                                .frame(width: 280)
                                .tint(Color.accentColor)

                            if !diffusionStage.detail.isEmpty {
                                Text("Step \(diffusionStage.detail)")
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(.secondary)
                            }
                        } else {
                            ProgressView()
                                .controlSize(.small)
                        }
                    }
                }

                // Pipeline steps checklist
                VStack(alignment: .leading, spacing: 8) {
                    pipelineStepRow("Generate image", isComplete: viewModel.t2mGeneratedImage != nil, isActive: viewModel.isGeneratingT2I)
                    pipelineStepRow("Detect object", isComplete: !viewModel.segmentations.isEmpty, isActive: viewModel.t2mGeneratedImage != nil && viewModel.segmentations.isEmpty && !viewModel.isGeneratingT2I)
                    pipelineStepRow("Segment object", isComplete: viewModel.editableMaskImage != nil, isActive: !viewModel.segmentations.isEmpty && viewModel.editableMaskImage == nil)
                    pipelineStepRow("Generate 3D model", isComplete: viewModel.generated3DModelURL != nil, isActive: viewModel.isGenerating)
                }
                .padding(.top, 8)
            }

            // Prompt being generated
            if !viewModel.t2mPrompt.isEmpty {
                Text("\"\(viewModel.t2mPrompt)\"")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .frame(maxWidth: 350)
            }

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var currentStageTitle: String {
        if viewModel.isGeneratingT2I {
            return "Generating Image..."
        } else if viewModel.t2mGeneratedImage != nil && viewModel.segmentations.isEmpty {
            return "Detecting Object..."
        } else if !viewModel.segmentations.isEmpty && viewModel.editableMaskImage == nil {
            return "Segmenting..."
        } else if viewModel.isGenerating {
            return "Generating 3D Model..."
        } else if viewModel.generated3DModelURL != nil {
            return "Complete!"
        }
        return "Processing..."
    }

    @ViewBuilder
    private func pipelineStepRow(_ title: String, isComplete: Bool, isActive: Bool) -> some View {
        HStack(spacing: 10) {
            ZStack {
                Circle()
                    .fill(isComplete ? Color.green : (isActive ? Color.accentColor : Color.secondary.opacity(0.2)))
                    .frame(width: 20, height: 20)

                if isComplete {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white)
                } else if isActive {
                    ProgressView()
                        .controlSize(.mini)
                        .tint(.white)
                }
            }

            Text(title)
                .font(.system(size: 13))
                .foregroundStyle(isComplete || isActive ? .primary : .secondary)
        }
    }
}
