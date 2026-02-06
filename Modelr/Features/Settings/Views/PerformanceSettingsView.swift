import SwiftUI

/// Performance tab in Settings - memory and loading preferences
struct PerformanceSettingsView: View {
    @EnvironmentObject var viewModel: SettingsViewModel
    @State private var memoryStrategy: MemoryStrategyPreference = .auto
    @State private var preloadOnStartup: Bool = true
    @State private var enableAutoDetection: Bool = true

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                // Header
                VStack(alignment: .leading, spacing: 4) {
                    Text("Performance")
                        .font(.title2.bold())
                    Text("Configure memory usage and model loading behavior")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Divider()

                // System Info
                systemInfoSection

                Divider()

                // Memory Strategy
                memoryStrategySection

                Divider()

                // Preloading
                preloadingSection

                Divider()

                // Auto Detection
                autoDetectionSection

                Spacer()
            }
            .padding()
        }
        .onAppear {
            loadSettings()
        }
    }

    // MARK: - Sections

    @ViewBuilder
    private var systemInfoSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("System Information", systemImage: "cpu")
                .font(.headline)

            if let systemInfo = viewModel.systemInfo {
                HStack(spacing: 24) {
                    infoItem(icon: "memorychip", label: "System RAM", value: systemInfo.formattedTotalRAM)
                    infoItem(icon: "cpu", label: "Processor", value: systemInfo.processorName)
                    infoItem(icon: "gauge.with.dots.needle.67percent", label: "Recommended", value: systemInfo.recommendedStrategy.description)
                }
                .padding()
                .background(Color.primary.opacity(0.03))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            } else {
                ProgressView()
            }
        }
    }

    @ViewBuilder
    private var memoryStrategySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Memory Strategy", systemImage: "slider.horizontal.3")
                .font(.headline)

            Text("Controls how models are loaded and managed in memory")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Picker("Strategy", selection: $memoryStrategy) {
                ForEach(MemoryStrategyPreference.allCases, id: \.self) { strategy in
                    VStack(alignment: .leading, spacing: AppDesign.Spacing.p2) {
                        Text(strategy.displayName)
                        Text(strategy.description)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .tag(strategy)
                }
            }
            .pickerStyle(.radioGroup)
            .onChange(of: memoryStrategy) { _, newValue in
                viewModel.settingsManager.memoryStrategy = newValue
            }

            // Current strategy description
            HStack(spacing: AppDesign.Spacing.sm) {
                Image(systemName: "info.circle")
                    .foregroundStyle(.secondary)
                Text(memoryStrategy.description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(AppDesign.Spacing.p10)
            .background(Color.blue.opacity(AppDesign.Opacity.soft))
            .clipShape(RoundedRectangle(cornerRadius: AppDesign.Size.cornerRadiusSmall))
        }
    }

    @ViewBuilder
    private var preloadingSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Model Preloading", systemImage: "arrow.down.to.line")
                .font(.headline)

            Toggle(isOn: $preloadOnStartup) {
                VStack(alignment: .leading, spacing: AppDesign.Spacing.p2) {
                    Text("Preload models on startup")
                        .font(.body)
                    Text("Load frequently-used models when the app starts for faster generation")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.switch)
            .onChange(of: preloadOnStartup) { _, newValue in
                viewModel.settingsManager.preloadModelsOnStartup = newValue
            }
        }
    }

    @ViewBuilder
    private var autoDetectionSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Auto Detection", systemImage: "wand.and.stars")
                .font(.headline)

            Toggle(isOn: $enableAutoDetection) {
                VStack(alignment: .leading, spacing: AppDesign.Spacing.p2) {
                    Text("Enable automatic object detection")
                        .font(.body)
                    Text("Use VLM to automatically identify objects in images for segmentation")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.switch)
            .onChange(of: enableAutoDetection) { _, newValue in
                viewModel.settingsManager.enableAutoDetection = newValue
            }

            if !enableAutoDetection {
                HStack(spacing: AppDesign.Spacing.sm) {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(AppDesign.warning)
                    Text("You'll need to manually enter object names for segmentation")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(AppDesign.Spacing.p10)
                .background(AppDesign.warning.opacity(AppDesign.Opacity.soft))
                .clipShape(RoundedRectangle(cornerRadius: AppDesign.Size.cornerRadiusSmall))
            }
        }
    }

    // MARK: - Helpers

    @ViewBuilder
    private func infoItem(icon: String, label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                Text(label)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            Text(value)
                .font(.callout.weight(.medium))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .frame(minWidth: 150, maxWidth: .infinity, alignment: .leading)
    }

    private func loadSettings() {
        memoryStrategy = viewModel.settingsManager.memoryStrategy
        preloadOnStartup = viewModel.settingsManager.preloadModelsOnStartup
        enableAutoDetection = viewModel.settingsManager.enableAutoDetection
    }
}

// MARK: - Preview

#Preview {
    PerformanceSettingsView()
        .environmentObject(SettingsViewModel())
        .frame(width: 650, height: 500)
}
