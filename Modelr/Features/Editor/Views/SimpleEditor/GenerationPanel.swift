import SwiftUI

/// Generation panel for ContentViewSimple
struct GenerationPanel: View {
    @ObservedObject var viewModel: SimpleEditorViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: AppDesign.Spacing.p16) {
            if viewModel.isGenerating || viewModel.isInHandoff {
                // Show progress during generation AND handoff
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
        VStack(alignment: .leading, spacing: 0) {
            ForEach(visibleStages, id: \.self) { stage in
                StageProgressRowView(
                    stage: stage,
                    stageData: viewModel.generationStages[stage] ?? StageProgress(),
                    isPreloaded: stage == .loading && ModelLoadingCoordinator.shared.isHunyuanReady,
                    downloadInfo: stage == .downloading ? (
                        progress: viewModel.formattedDownloadProgress,
                        speed: viewModel.formattedDownloadSpeed,
                        remaining: viewModel.formattedTimeRemaining,
                        hasData: viewModel.downloadTotalBytes > 0
                    ) : nil,
                    stageTextColor: viewModel.stageTextColor
                )
            }
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.8), value: viewModel.generationStages.map { "\($0.key):\($0.value.status)" })
    }

    /// Returns stages to display, filtering out downloading if not applicable
    private var visibleStages: [GenerationStage] {
        GenerationStage.allCases.filter { stage in
            if stage == .downloading {
                // Show downloading stage if the needed model isn't downloaded
                let needsLargeModel = viewModel.selectedPreset.usesLargeModel && !viewModel.isLargeModelDownloaded
                let needsSmallModel = viewModel.selectedPreset.usesMiniRepo && !viewModel.isSmallModelDownloaded
                return needsLargeModel || needsSmallModel
            }
            return true
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
        }
    }

    @ViewBuilder
    private var generationSettingsView: some View {
        VStack(alignment: .leading, spacing: AppDesign.Spacing.p12) {
            // Quality Preset Section (unified model + quality dropdown)
            VStack(alignment: .leading, spacing: AppDesign.Spacing.p8) {
                AppDesign.SectionLabel("Quality")

                Menu {
                    // Fast model presets (mini)
                    Section("Fast (Mini)") {
                        ForEach(GenerationPreset.fastPresets, id: \.self) { preset in
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
                    }

                    Divider()

                    // Quality model presets (2.1)
                    Section("Quality (2.1)") {
                        // Info row explaining the download icon
                        if !viewModel.isLargeModelDownloaded {
                            Label("Requires \(SetupModelChoice.quality.downloadSize) download on first use", systemImage: "info.circle")
                                .foregroundStyle(.secondary)
                                .font(.caption)
                        }

                        ForEach(GenerationPreset.qualityPresets, id: \.self) { preset in
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
                        // Show download icon if needed model isn't downloaded
                        if (viewModel.selectedPreset.usesLargeModel && !viewModel.isLargeModelDownloaded) ||
                           (viewModel.selectedPreset.usesMiniRepo && !viewModel.isSmallModelDownloaded) {
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

                // Show download warning when model needs downloading
                if viewModel.selectedPreset.usesLargeModel && !viewModel.isLargeModelDownloaded {
                    HStack(spacing: AppDesign.Spacing.p4) {
                        Image(systemName: "arrow.down.circle")
                            .font(.system(size: AppDesign.FontSize.caption))
                            .foregroundStyle(AppDesign.warning)
                        Text("Will download \(SetupModelChoice.quality.downloadSize) on first use")
                            .font(.system(size: AppDesign.FontSize.caption))
                            .foregroundStyle(AppDesign.warning)
                    }
                } else if viewModel.selectedPreset.usesMiniRepo && !viewModel.isSmallModelDownloaded {
                    HStack(spacing: AppDesign.Spacing.p4) {
                        Image(systemName: "arrow.down.circle")
                            .font(.system(size: AppDesign.FontSize.caption))
                            .foregroundStyle(AppDesign.warning)
                        Text("Will download \(SetupModelChoice.fast.downloadSize) on first use")
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

// MARK: - Stage Progress Row View

private struct StageProgressRowView: View {
    let stage: GenerationStage
    let stageData: StageProgress
    let isPreloaded: Bool
    let downloadInfo: (progress: String, speed: String, remaining: String, hasData: Bool)?
    let stageTextColor: (StageStatus) -> Color

    @State private var progressAnimated: Double = 0

    private var isActive: Bool { stageData.status == .inProgress }
    private var hasSubContent: Bool {
        (isActive && stageData.progress > 0) ||
        (stage == .downloading && isActive && (downloadInfo?.hasData ?? false))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Main row
            HStack(spacing: AppDesign.Spacing.p8) {
                statusIndicator
                    .frame(width: 16, height: 16)

                stageInfoRow
            }
            .padding(.vertical, AppDesign.Spacing.p4)

            // Expandable sub-content (progress bar, download stats)
            if hasSubContent {
                VStack(alignment: .leading, spacing: AppDesign.Spacing.p2) {
                    if stageData.progress > 0 {
                        ProgressView(value: progressAnimated)
                            .progressViewStyle(.linear)
                            .tint(AppDesign.accent)
                    }

                    if stage == .downloading, let info = downloadInfo, info.hasData {
                        downloadStatsRow(info: info)
                    }
                }
                .padding(.leading, 24) // Align with text after icon
                .padding(.bottom, AppDesign.Spacing.p4)
                .transition(.asymmetric(
                    insertion: .opacity.combined(with: .scale(scale: 0.95, anchor: .top)).combined(with: .move(edge: .top)),
                    removal: .opacity.combined(with: .scale(scale: 0.95, anchor: .top))
                ))
                .clipped()
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: hasSubContent)
        .onChange(of: stageData.progress) { _, newValue in
            withAnimation(.easeOut(duration: 0.3)) {
                progressAnimated = newValue
            }
        }
        .onAppear {
            progressAnimated = stageData.progress
        }
    }

    @ViewBuilder
    private var statusIndicator: some View {
        Group {
            switch stageData.status {
            case .completed:
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: AppDesign.FontSize.body))
                    .foregroundColor(AppDesign.success)
                    .transition(.scale.combined(with: .opacity))
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
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: stageData.status)
    }

    @ViewBuilder
    private var stageInfoRow: some View {
        HStack(spacing: AppDesign.Spacing.p4) {
            Text(stage.rawValue)
                .font(.system(size: AppDesign.FontSize.body, weight: isActive ? .semibold : .regular))
                .foregroundColor(stageTextColor(stageData.status))
                .animation(.easeInOut(duration: 0.2), value: isActive)

            // Show "Preloaded!" badge for loading stage if model was preloaded
            if isPreloaded {
                preloadedBadge
            }

            Spacer()

            // Step count badge (e.g., "5/25") - always show for diffusion/volumeDecoding when active
            if isActive && !stageData.detail.isEmpty {
                stepCountBadge
            }

            if stageData.status == .cancelled {
                Text("Stopped")
                    .font(.system(size: AppDesign.FontSize.caption, weight: .bold))
                    .foregroundColor(AppDesign.warning)
            }
        }
    }

    @ViewBuilder
    private var preloadedBadge: some View {
        Text("Preloaded!")
            .font(.system(size: AppDesign.FontSize.xs, weight: .semibold))
            .foregroundColor(AppDesign.success)
            .padding(.horizontal, AppDesign.Spacing.p6)
            .padding(.vertical, 2)
            .background(AppDesign.success.opacity(0.15), in: RoundedRectangle(cornerRadius: 4))
            .transition(.scale.combined(with: .opacity))
    }

    @ViewBuilder
    private var stepCountBadge: some View {
        Text(stageData.detail)
            .font(.system(size: AppDesign.FontSize.caption, weight: .medium, design: .monospaced))
            .foregroundColor(.secondary)
            .padding(.horizontal, AppDesign.Spacing.p6)
            .padding(.vertical, AppDesign.Spacing.p2)
            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 4))
            .contentTransition(.numericText(countsDown: false))
            .animation(.spring(response: 0.25, dampingFraction: 0.8), value: stageData.detail)
    }

    @ViewBuilder
    private func downloadStatsRow(info: (progress: String, speed: String, remaining: String, hasData: Bool)) -> some View {
        HStack {
            Text(info.progress)
                .font(.system(size: AppDesign.FontSize.xs, design: .monospaced))
                .foregroundStyle(.secondary)
                .contentTransition(.numericText())

            Spacer()

            Text(info.speed)
                .font(.system(size: AppDesign.FontSize.xs, design: .monospaced))
                .foregroundStyle(.secondary)
                .contentTransition(.numericText())

            Text("•")
                .foregroundStyle(.tertiary)

            Text(info.remaining)
                .font(.system(size: AppDesign.FontSize.xs, design: .monospaced))
                .foregroundStyle(.secondary)
                .contentTransition(.numericText())
        }
        .animation(.easeInOut(duration: 0.2), value: info.progress)
    }
}
