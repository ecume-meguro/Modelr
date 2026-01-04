import SwiftUI

/// Generation panel for ContentViewSimple
struct GenerationPanel: View {
    @ObservedObject var viewModel: SimpleEditorViewModel
    
    var body: some View {
        VStack(alignment: .leading, spacing: AppDesign.Spacing.p16) {
            if viewModel.isGenerating {
                generationProgressView
            } else if let url = viewModel.generated3DModelURL {
                generationCompletedView(url: url)
            } else {
                generationSettingsView
            }
        }
    }
    
    @ViewBuilder
    private var generationProgressView: some View {
        VStack(alignment: .leading, spacing: AppDesign.Spacing.p8) {
            ForEach(visibleStages, id: \.self) { stage in
                stageProgressRow(stage: stage)
            }
        }
    }

    /// Returns stages to display, filtering out downloading if not applicable
    private var visibleStages: [SimpleEditorViewModel.GenerationStage] {
        SimpleEditorViewModel.GenerationStage.allCases.filter { stage in
            if stage == .downloading {
                // Only show downloading stage if using large model and it's not downloaded
                return viewModel.selectedPreset.usesLargeModel && !viewModel.isLargeModelDownloaded
            }
            return true
        }
    }
    
    @ViewBuilder
    private func stageProgressRow(stage: SimpleEditorViewModel.GenerationStage) -> some View {
        let stageData = viewModel.generationStages[stage] ?? SimpleEditorViewModel.StageProgress()
        
        HStack(spacing: AppDesign.Spacing.p12) {
            // Status indicator
            Group {
                switch stageData.status {
                case .completed:
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: AppDesign.FontSize.body))
                        .foregroundColor(AppDesign.success)
                case .inProgress:
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.6)
                case .pending:
                    Circle()
                        .fill(Color.secondary.opacity(0.2))
                        .frame(width: 12, height: 12)
                case .cancelled:
                    Image(systemName: "minus.circle.fill")
                        .font(.system(size: AppDesign.FontSize.body))
                        .foregroundColor(AppDesign.warning)
                case .failed:
                    Image(systemName: "exclamationmark.circle.fill")
                        .font(.system(size: AppDesign.FontSize.body))
                        .foregroundColor(AppDesign.destructive)
                }
            }
            .frame(width: 16, height: 16)
            
            // Stage info
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: AppDesign.Spacing.p4) {
                    Text(stage.rawValue)
                        .font(.system(size: AppDesign.FontSize.subheadline, weight: stageData.status == .inProgress ? .semibold : .regular))
                        .foregroundColor(viewModel.stageTextColor(stageData.status))
                    
                    if stageData.status == .cancelled {
                        Text("Stopped")
                            .font(.system(size: AppDesign.FontSize.caption, weight: .bold))
                            .foregroundColor(AppDesign.warning)
                    }
                }
                
                if stageData.status == .inProgress && stageData.progress > 0 {
                    ProgressView(value: stageData.progress)
                        .progressViewStyle(.linear)
                        .tint(AppDesign.accent)
                }
                
                if !stageData.detail.isEmpty && stageData.status == .inProgress {
                    Text(stageData.detail)
                        .font(.system(size: AppDesign.FontSize.caption, design: .monospaced))
                        .foregroundColor(.secondary)
                }
            }
            
            Spacer()
        }
    }
    
    @ViewBuilder
    private func generationCompletedView(url: URL) -> some View {
        VStack(alignment: .leading, spacing: AppDesign.Spacing.p12) {
            AppDesign.CompletedRow("Generation Complete")
            
            if let duration = viewModel.generationDuration {
                HStack(spacing: AppDesign.Spacing.p4) {
                    Image(systemName: "clock")
                        .font(.system(size: AppDesign.FontSize.caption))
                        .foregroundColor(.secondary)
                    Text(viewModel.formatDuration(duration))
                        .font(.system(size: AppDesign.FontSize.caption))
                        .foregroundColor(.secondary)
                }
            }
            
            AppDesign.GlassButtonSecondary("Show in Finder", icon: "folder") {
                NSWorkspace.shared.selectFile(url.path, inFileViewerRootedAtPath: url.deletingLastPathComponent().path)
            }
        }
    }
    
    @ViewBuilder
    private var generationSettingsView: some View {
        VStack(alignment: .leading, spacing: AppDesign.Spacing.p12) {
            // Quality Preset Section (unified model + quality dropdown)
            VStack(alignment: .leading, spacing: AppDesign.Spacing.p8) {
                AppDesign.SectionLabel("Quality")

                Menu {
                    // Fast model presets
                    Section {
                        ForEach([GenerationPreset.extraDraft, .draft, .normal, .high, .quality], id: \.self) { preset in
                            Button {
                                viewModel.selectedPreset = preset
                                viewModel.customSteps = CGFloat(preset.steps)
                                viewModel.customResolution = CGFloat(preset.resolution)
                            } label: {
                                HStack {
                                    Text(preset.rawValue)
                                    Spacer()
                                    Text(preset.estimatedTime)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }

                    Divider()

                    // Large model presets (XQuality)
                    Section {
                        ForEach([GenerationPreset.xQuality, .xQualityHigh, .xQualityMax], id: \.self) { preset in
                            Button {
                                viewModel.selectedPreset = preset
                                viewModel.customSteps = CGFloat(preset.steps)
                                viewModel.customResolution = CGFloat(preset.resolution)
                            } label: {
                                HStack {
                                    Text(preset.rawValue)
                                    if !viewModel.isLargeModelDownloaded {
                                        Image(systemName: "arrow.down.circle")
                                            .foregroundStyle(.orange)
                                    }
                                    Spacer()
                                    Text(preset.estimatedTime)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                } label: {
                    HStack {
                        Text(viewModel.selectedPreset.rawValue)
                            .font(.system(size: AppDesign.FontSize.body))
                        if viewModel.selectedPreset.usesLargeModel && !viewModel.isLargeModelDownloaded {
                            Image(systemName: "arrow.down.circle")
                                .font(.system(size: AppDesign.FontSize.caption))
                                .foregroundStyle(.orange)
                        }
                        Spacer()
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: AppDesign.FontSize.caption))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, AppDesign.Spacing.p12)
                    .padding(.vertical, AppDesign.Spacing.p8)
                    .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(Color.primary.opacity(0.15), lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)

                HStack {
                    Text(viewModel.selectedPreset.description)
                        .font(.system(size: AppDesign.FontSize.caption))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(viewModel.selectedPreset.estimatedTime)
                        .font(.system(size: AppDesign.FontSize.caption, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }

                // Show download warning for XQuality presets
                if viewModel.selectedPreset.usesLargeModel && !viewModel.isLargeModelDownloaded {
                    HStack(spacing: AppDesign.Spacing.p4) {
                        Image(systemName: "arrow.down.circle")
                            .font(.system(size: AppDesign.FontSize.caption))
                            .foregroundStyle(AppDesign.warning)
                        Text("Will download \(viewModel.selectedPreset.downloadSize ?? "~7 GB") on first use")
                            .font(.system(size: AppDesign.FontSize.caption))
                            .foregroundStyle(AppDesign.warning)
                    }
                }
            }

            // Advanced Settings Section
            VStack(alignment: .leading, spacing: AppDesign.Spacing.p8) {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        viewModel.showAdvancedSettings.toggle()
                    }
                } label: {
                    HStack(spacing: AppDesign.Spacing.p6) {
                        Image(systemName: viewModel.showAdvancedSettings ? "chevron.down" : "chevron.right")
                            .font(.system(size: AppDesign.FontSize.caption, weight: .semibold))
                            .foregroundStyle(.tertiary)
                            .frame(width: 12)
                        Text("Advanced Settings")
                            .font(.system(size: AppDesign.FontSize.subheadline, weight: .medium))
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                }
                .buttonStyle(.plain)

                if viewModel.showAdvancedSettings {
                    VStack(alignment: .leading, spacing: AppDesign.Spacing.p12) {
                        AppDesign.SliderRow(
                            label: "Steps",
                            value: $viewModel.customSteps,
                            range: 10...100,
                            step: 5
                        )
                        AppDesign.SliderRow(
                            label: "Resolution",
                            value: $viewModel.customResolution,
                            range: 64...512,
                            step: 32
                        )
                        AppDesign.HintText("Higher values produce better detail but take longer.")
                    }
                    .padding(.leading, AppDesign.Spacing.p16)
                    .transition(.opacity)
                }
            }
        }
    }
}
