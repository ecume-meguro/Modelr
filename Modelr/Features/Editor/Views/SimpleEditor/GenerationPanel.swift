import SwiftUI

/// Generation panel for ContentViewSimple - shows progress and completion status
struct GenerationPanel: View {
    @ObservedObject var viewModel: SimpleEditorViewModel

    /// Check if generation was stopped (has cancelled stages)
    private var wasGenerationStopped: Bool {
        viewModel.generationStages.values.contains { $0.status == .cancelled }
    }

    /// Check if generation failed (has failed stages)
    private var didGenerationFail: Bool {
        viewModel.generationStages.values.contains { $0.status == .failed }
    }

    /// Check if we're in an idle state (no generation started, no model, not generating)
    private var isIdle: Bool {
        !viewModel.isGenerating &&
        !viewModel.isInHandoff &&
        viewModel.generated3DModelURL == nil &&
        viewModel.generationStages.isEmpty
    }

    /// Check if the model is already preloaded
    private var isModelPreloaded: Bool {
        return ModelLoadingCoordinator.shared.isHunyuanReady
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppDesign.Spacing.p16) {
            if viewModel.isGenerating || viewModel.isInHandoff {
                // Show progress during generation AND handoff
                generationProgressView
            } else if let url = viewModel.generated3DModelURL {
                generationCompletedView(url: url)
            } else if wasGenerationStopped {
                // Show stopped state with option to restart
                generationStoppedView
            } else if didGenerationFail {
                // Show failed state with option to retry
                generationFailedView
            } else if isIdle {
                // Show idle state - ready to generate
                generationIdleView
            }
        }
    }

    @ViewBuilder
    private var generationProgressView: some View {
        VStack(alignment: .leading, spacing: AppDesign.Spacing.p12) {
            // Stage progress list
            VStack(alignment: .leading, spacing: 0) {
                ForEach(visibleStages, id: \.self) { stage in
                    StageProgressRowView(
                        stage: stage,
                        stageData: viewModel.generationStages[stage] ?? StageProgress(),
                        isPreloaded: stage == .loading && isModelPreloaded,
                        downloadInfo: stage == .downloading ? (
                            progress: viewModel.formattedDownloadProgress,
                            speed: viewModel.formattedDownloadSpeed,
                            remaining: viewModel.formattedTimeRemaining,
                            hasData: viewModel.downloadTotalBytes > 0
                        ) : nil,
                        setupLogs: stage == .setup ? viewModel.generationSetupLogs : nil,
                        stageTextColor: viewModel.stageTextColor
                    )
                }
            }
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.8), value: viewModel.generationStages.map { "\($0.key):\($0.value.status)" })
    }

    /// Returns stages to display based on selected model, filtering out downloading if not applicable
    private var visibleStages: [GenerationStage] {
        // Get stages specific to the selected model family
        let modelStages = GenerationStage.stages(for: viewModel.selectedPreset.modelFamily)

        return modelStages.filter { stage in
            if stage == .downloading {
                // Show downloading stage only if the model needs downloading
                return viewModel.selectedPreset.requiresDownload
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
    private var generationStoppedView: some View {
        VStack(alignment: .leading, spacing: AppDesign.Spacing.p12) {
            HStack(spacing: AppDesign.Spacing.p8) {
                Image(systemName: "stop.circle.fill")
                    .font(.system(size: AppDesign.FontSize.headline))
                    .foregroundColor(AppDesign.warning)
                Text("Generation Stopped")
                    .font(.system(size: AppDesign.FontSize.body, weight: .medium))
                    .foregroundColor(.primary)
            }

            Text("The generation was stopped before completing.")
                .font(.system(size: AppDesign.FontSize.caption))
                .foregroundColor(.secondary)

            AppDesign.GlassButton("Try Again", icon: "arrow.clockwise") {
                viewModel.restartGeneration()
            }
        }
    }

    @ViewBuilder
    private var generationFailedView: some View {
        VStack(alignment: .leading, spacing: AppDesign.Spacing.p12) {
            HStack(spacing: AppDesign.Spacing.p8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: AppDesign.FontSize.headline))
                    .foregroundColor(AppDesign.destructive)
                Text("Generation Failed")
                    .font(.system(size: AppDesign.FontSize.body, weight: .medium))
                    .foregroundColor(.primary)
            }

            if let error = viewModel.lastError {
                Text(error.localizedDescription)
                    .font(.system(size: AppDesign.FontSize.caption))
                    .foregroundColor(.secondary)
            }

            AppDesign.GlassButton("Retry", icon: "arrow.clockwise") {
                viewModel.restartGeneration()
            }
        }
    }

    @ViewBuilder
    private var generationIdleView: some View {
        VStack(alignment: .leading, spacing: AppDesign.Spacing.p12) {
            HStack(spacing: AppDesign.Spacing.p8) {
                Image(systemName: "sparkles")
                    .font(.system(size: AppDesign.FontSize.headline))
                    .foregroundColor(AppDesign.accent)
                Text("Ready to Generate")
                    .font(.system(size: AppDesign.FontSize.body, weight: .medium))
                    .foregroundColor(.primary)
            }

            Text("Your image is ready for 3D generation.")
                .font(.system(size: AppDesign.FontSize.caption))
                .foregroundColor(.secondary)

            AppDesign.GlassButton("Start Generation", icon: "sparkles") {
                viewModel.startGeneration()
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
    let setupLogs: [String]?
    let stageTextColor: (StageStatus) -> Color

    @State private var progressAnimated: Double = 0

    private var isActive: Bool { stageData.status == .inProgress }
    private var hasSetupLogs: Bool { stage == .setup && !(setupLogs?.isEmpty ?? true) }
    private var hasSubContent: Bool {
        (isActive && stageData.progress > 0) ||
        (stage == .downloading && isActive && (downloadInfo?.hasData ?? false)) ||
        (hasSetupLogs && isActive)
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

            // Expandable sub-content (progress bar, download stats, setup logs)
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

                    // Setup logs console
                    if hasSetupLogs, let logs = setupLogs {
                        setupLogsSection(logs: logs)
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

            // Step count badge (e.g., "5/25") - show for active stages except setup (which has console logs)
            if isActive && !stageData.detail.isEmpty && stage != .setup {
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

    @ViewBuilder
    private func setupLogsSection(logs: [String]) -> some View {
        // Show last 6 lines, auto-updated
        let tailLogs = Array(logs.suffix(6))

        VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(tailLogs.enumerated()), id: \.offset) { _, line in
                Text(line)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(.easeOut(duration: 0.15), value: logs.count)
    }
}
