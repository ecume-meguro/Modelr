import SwiftUI

/// Settings panel for 3D generation (Hunyuan-only)
struct GenerationSettingsPanel: View {
    @ObservedObject var viewModel: SimpleEditorViewModel
    @State private var showAdvanced = false
    @State private var selectedVariant: HunyuanVariant = .mini

    var body: some View {
        VStack(alignment: .leading, spacing: AppDesign.Spacing.p16) {
            // Model & Preset Selection
            modelAndPresetSection

            // Download warning if model needs downloading
            downloadWarningSection

            // Advanced settings (collapsible)
            advancedSection
        }
        .onAppear {
            // Sync variant from current preset
            selectedVariant = viewModel.selectedPreset.variant
            syncSlidersWithPreset()
        }
    }

    // MARK: - Model & Preset Section

    @ViewBuilder
    private var modelAndPresetSection: some View {
        VStack(alignment: .leading, spacing: AppDesign.Spacing.p12) {
            // Model selector - side by side buttons
            modelSelectorButtons

            // Quality preset selector - segmented style
            qualityPresetSelector
        }
    }

    // MARK: - Quality Preset Selector

    @ViewBuilder
    private var qualityPresetSelector: some View {
        VStack(alignment: .leading, spacing: AppDesign.Spacing.p8) {
            // Segmented buttons
            HStack(spacing: 1) {
                ForEach(selectedVariant.presets) { preset in
                    qualityButton(for: preset)
                }
            }
            .background(Color.primary.opacity(AppDesign.Opacity.light))
            .clipShape(RoundedRectangle(cornerRadius: AppDesign.Size.cornerRadius))

            // Time estimate for selected preset
            HStack(spacing: AppDesign.Spacing.p4) {
                Image(systemName: "clock")
                    .font(.system(size: AppDesign.FontSize.xs))
                Text("Estimated: \(viewModel.selectedPreset.estimatedTime)")
                    .font(.system(size: AppDesign.FontSize.xs))
            }
            .foregroundStyle(.tertiary)
        }
    }

    @ViewBuilder
    private func qualityButton(for preset: GenerationPreset) -> some View {
        let isSelected = viewModel.selectedPreset == preset

        Button {
            withAnimation(.easeInOut(duration: 0.15)) {
                viewModel.selectedPreset = preset
                syncSlidersWithPreset()
            }
        } label: {
            Text(preset.shortName)
                .font(.system(size: AppDesign.FontSize.caption, weight: isSelected ? .semibold : .regular))
                .foregroundStyle(isSelected ? .primary : .secondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, AppDesign.Spacing.p6)
                .background(isSelected ? Color.primary.opacity(AppDesign.Opacity.medium) : Color.clear)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Model Selector Buttons

    @ViewBuilder
    private var modelSelectorButtons: some View {
        HStack(spacing: AppDesign.Spacing.p8) {
            ForEach(HunyuanVariant.allCases) { variant in
                modelButton(for: variant)
            }
        }
    }

    @ViewBuilder
    private func modelButton(for variant: HunyuanVariant) -> some View {
        let isSelected = selectedVariant == variant

        Button {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                selectedVariant = variant
                viewModel.selectedPreset = variant.defaultPreset
                syncSlidersWithPreset()
            }
        } label: {
            VStack(alignment: .leading, spacing: AppDesign.Spacing.p4) {
                Text(variant.shortName)
                    .font(.system(size: AppDesign.FontSize.subheadline, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected ? .primary : .secondary)

                Text(variant.description)
                    .font(.system(size: AppDesign.FontSize.xs))
                    .foregroundStyle(.tertiary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(AppDesign.Spacing.p10)
            .background(isSelected ? AppDesign.accent.opacity(AppDesign.Opacity.soft) : Color.primary.opacity(AppDesign.Opacity.subtle))
            .clipShape(RoundedRectangle(cornerRadius: AppDesign.Size.cornerRadius))
            .overlay(
                RoundedRectangle(cornerRadius: AppDesign.Size.cornerRadius)
                    .stroke(isSelected ? AppDesign.accent.opacity(AppDesign.Opacity.high) : Color.primary.opacity(AppDesign.Opacity.soft), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: isSelected)
    }

    // MARK: - Download Warning

    @ViewBuilder
    private var downloadWarningSection: some View {
        if viewModel.selectedPreset.requiresDownload {
            HStack(spacing: AppDesign.Spacing.p8) {
                Image(systemName: "arrow.down.circle.fill")
                    .font(.system(size: 16))
                    .foregroundStyle(AppDesign.warning)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Model will be downloaded")
                        .font(.system(size: AppDesign.FontSize.subheadline, weight: .medium))
                    Text("\(viewModel.selectedPreset.variant.downloadSize) download required before generation")
                        .font(.system(size: AppDesign.FontSize.xs))
                        .foregroundStyle(.secondary)
                }

                Spacer()
            }
            .padding(AppDesign.Spacing.p10)
            .background(AppDesign.warning.opacity(AppDesign.Opacity.medium), in: RoundedRectangle(cornerRadius: AppDesign.Size.cornerRadius))
        }
    }

    // MARK: - Advanced Section

    @ViewBuilder
    private var advancedSection: some View {
        VStack(alignment: .leading, spacing: AppDesign.Spacing.p8) {
            // Collapsible header - entire row is clickable
            Button {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                    showAdvanced.toggle()
                }
            } label: {
                HStack {
                    Text("Advanced")
                        .font(.system(size: AppDesign.FontSize.subheadline, weight: .medium))
                        .foregroundStyle(.secondary)

                    Spacer()

                    Image(systemName: "chevron.right")
                        .font(.system(size: AppDesign.FontSize.xs, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(showAdvanced ? 90 : 0))
                        .animation(.spring(response: 0.25, dampingFraction: 0.7), value: showAdvanced)
                }
                .padding(.vertical, AppDesign.Spacing.p6)
                .padding(.horizontal, AppDesign.Spacing.p8)
                .background(Color.primary.opacity(AppDesign.Opacity.subtle), in: RoundedRectangle(cornerRadius: AppDesign.Size.cornerRadiusSmall))
                .contentShape(Rectangle())  // Makes entire row tappable
            }
            .buttonStyle(.plain)

            // Collapsible content
            if showAdvanced {
                VStack(alignment: .leading, spacing: AppDesign.Spacing.p12) {
                    hunyuanSettings
                }
                .padding(.top, AppDesign.Spacing.p4)
                .transition(.asymmetric(
                    insertion: .opacity
                        .combined(with: .offset(y: -8))
                        .animation(.spring(response: 0.3, dampingFraction: 0.85)),
                    removal: .opacity
                        .animation(.easeOut(duration: 0.15))
                ))
            }
        }
    }

    @ViewBuilder
    private var hunyuanSettings: some View {
        VStack(alignment: .leading, spacing: AppDesign.Spacing.p12) {
            AppDesign.SliderRow(
                label: "Diffusion Steps",
                value: $viewModel.customSteps,
                range: 10...100,
                step: 5
            )
            AppDesign.SliderRow(
                label: "Octree Resolution",
                value: $viewModel.customResolution,
                range: 64...512,
                step: 32
            )
            AppDesign.SliderRow(
                label: "Guidance Scale",
                value: $viewModel.customGuidanceScaleHunyuan,
                range: 1.0...10.0,
                step: 0.5,
                format: "%.1f"
            )
            AppDesign.SliderRow(
                label: "Bounding Box Scale",
                value: $viewModel.customBoxV,
                range: 0.8...1.5,
                step: 0.01,
                format: "%.2f"
            )
            AppDesign.SliderRow(
                label: "Surface Level",
                value: $viewModel.customMcLevel,
                range: -0.5...0.5,
                step: 0.05,
                format: "%.2f"
            )
            AppDesign.SliderRow(
                label: "Mesh Reduction",
                value: $viewModel.customMeshReduction,
                range: 0...90,
                step: 10,
                format: "%.0f%%"
            )

            // Tip for mesh reduction
            HStack(spacing: AppDesign.Spacing.p6) {
                Image(systemName: "info.circle")
                    .font(.system(size: AppDesign.FontSize.caption))
                    .foregroundStyle(.secondary)
                Text("Simplifies mesh geometry using QEM. 50% is balanced, 0% disables.")
                    .font(.system(size: AppDesign.FontSize.xs))
                    .foregroundStyle(.secondary)
            }

            AppDesign.HintText("Steps & resolution affect quality. Guidance controls input adherence. Box scale adjusts model size. Surface level shifts the mesh boundary.")
        }
    }

    // MARK: - Helpers

    private func syncSlidersWithPreset() {
        let preset = viewModel.selectedPreset

        // Hunyuan settings
        viewModel.customSteps = CGFloat(preset.steps)
        viewModel.customResolution = CGFloat(preset.resolution)
        viewModel.customGuidanceScaleHunyuan = 5.0  // Default CFG
        viewModel.customBoxV = 1.01  // Default bounding box
        viewModel.customMcLevel = 0.0  // Default surface level
        viewModel.customMeshReduction = 50.0  // Default QEM reduction
    }
}
