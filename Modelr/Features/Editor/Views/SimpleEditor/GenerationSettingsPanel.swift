import SwiftUI

/// Settings panel for 3D generation (presets, steps, resolution)
struct GenerationSettingsPanel: View {
    @ObservedObject var viewModel: SimpleEditorViewModel

    var body: some View {
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

            // Settings sliders
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
        }
    }
}
