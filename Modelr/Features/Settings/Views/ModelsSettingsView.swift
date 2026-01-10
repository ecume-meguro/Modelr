import SwiftUI

/// Models tab in Settings - shows status and selection of Hunyuan models
struct ModelsSettingsView: View {
    @ObservedObject private var settingsManager = SettingsManager.shared
    @State private var modelsSize: Int64 = 0
    @State private var isDownloading = false
    @State private var downloadProgress: Double = 0
    @State private var downloadingVariant: HunyuanVariant?

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Models")
                        .font(.title2.bold())
                    Text("Select and manage 3D generation models")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()

                Button {
                    refreshStatus()
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
            }
            .padding()

            Divider()

            // Model list
            ScrollView {
                VStack(spacing: 16) {
                    // Active model section
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Active Model")
                            .font(.headline)
                            .foregroundStyle(.secondary)

                        Text("Presets will use the selected model for generation")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    // Model cards
                    ForEach(HunyuanVariant.allCases) { variant in
                        ModelSelectionCard(
                            variant: variant,
                            isSelected: settingsManager.selectedVariant == variant,
                            isDownloading: downloadingVariant == variant,
                            downloadProgress: downloadingVariant == variant ? downloadProgress : 0,
                            onSelect: {
                                if variant.isDownloaded {
                                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                                        settingsManager.selectedVariant = variant
                                    }
                                }
                            },
                            onDownload: {
                                startDownload(variant: variant)
                            }
                        )
                    }

                    // Presets info
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Available Presets")
                            .font(.headline)
                            .foregroundStyle(.secondary)
                            .padding(.top, 8)

                        HStack(spacing: 8) {
                            ForEach(settingsManager.availablePresets) { preset in
                                PresetBadge(preset: preset)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding()
            }

            // Storage footer
            Divider()
            HStack {
                Image(systemName: "internaldrive")
                    .foregroundStyle(.secondary)
                Text("Models folder: \(ByteCountFormatter.string(fromByteCount: modelsSize, countStyle: .file))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Open in Finder") {
                    NSWorkspace.shared.open(PathManager.modelsDirectory)
                }
                .font(.caption)
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
            .background(.ultraThinMaterial)
        }
        .onAppear {
            refreshStatus()
        }
    }

    private func refreshStatus() {
        Task {
            modelsSize = await PathManager.getDirectorySize(PathManager.modelsDirectory)
        }
    }

    private func startDownload(variant: HunyuanVariant) {
        guard !isDownloading else { return }

        isDownloading = true
        downloadingVariant = variant
        downloadProgress = 0

        // TODO: Implement actual download via PythonDependencyService
        // For now, show a placeholder
        Task {
            // Simulate progress (replace with actual download)
            for i in 0...100 {
                try? await Task.sleep(nanoseconds: 50_000_000)
                downloadProgress = Double(i) / 100.0
            }

            isDownloading = false
            downloadingVariant = nil

            // After download, select the variant
            if variant.isDownloaded {
                settingsManager.selectedVariant = variant
            }
        }
    }
}

// MARK: - Model Selection Card

private struct ModelSelectionCard: View {
    let variant: HunyuanVariant
    let isSelected: Bool
    let isDownloading: Bool
    let downloadProgress: Double
    let onSelect: () -> Void
    let onDownload: () -> Void

    private var color: Color {
        variant == .mini ? .blue : .purple
    }

    var body: some View {
        Button(action: {
            if variant.isDownloaded {
                onSelect()
            }
        }) {
            HStack(spacing: 12) {
                // Selection indicator
                ZStack {
                    Circle()
                        .stroke(isSelected ? Color.accentColor : Color.primary.opacity(0.2), lineWidth: 2)
                        .frame(width: 24, height: 24)

                    if isSelected {
                        Circle()
                            .fill(Color.accentColor)
                            .frame(width: 14, height: 14)
                            .transition(.scale.combined(with: .opacity))
                    }
                }
                .opacity(variant.isDownloaded ? 1 : 0.3)

                // Model icon
                ZStack {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(color.opacity(0.15))
                        .frame(width: 44, height: 44)

                    Image(systemName: "cube.transparent")
                        .font(.title2)
                        .foregroundStyle(color)
                }

                // Model info
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(variant.displayName)
                            .font(.headline)
                            .foregroundStyle(.primary)

                        if isSelected && variant.isDownloaded {
                            Text("Active")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(Color.green, in: Capsule())
                        }
                    }

                    Text(variant.description)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer()

                // Status / Download
                VStack(alignment: .trailing, spacing: 4) {
                    if isDownloading {
                        VStack(alignment: .trailing, spacing: 4) {
                            ProgressView(value: downloadProgress)
                                .frame(width: 80)
                            Text("\(Int(downloadProgress * 100))%")
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    } else if variant.isDownloaded {
                        HStack(spacing: 4) {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                            Text("Downloaded")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        Button(action: onDownload) {
                            HStack(spacing: 4) {
                                Image(systemName: "arrow.down.circle.fill")
                                Text("Download")
                            }
                            .font(.caption.weight(.medium))
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(color)
                    }

                    Text(variant.downloadSize)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            .padding()
            .background(isSelected && variant.isDownloaded ? Color.accentColor.opacity(0.08) : Color.primary.opacity(0.03))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(isSelected && variant.isDownloaded ? Color.accentColor : Color.primary.opacity(0.08), lineWidth: isSelected && variant.isDownloaded ? 2 : 1)
            )
        }
        .buttonStyle(.plain)
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: isSelected)
        .disabled(!variant.isDownloaded && !isDownloading)
    }
}

// MARK: - Preset Badge

private struct PresetBadge: View {
    let preset: GenerationPreset

    var body: some View {
        VStack(spacing: 2) {
            Text(preset.shortName)
                .font(.caption.weight(.medium))
            Text(preset.estimatedTime)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color.primary.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

// MARK: - Preview

#Preview {
    ModelsSettingsView()
        .frame(width: 650, height: 500)
}
