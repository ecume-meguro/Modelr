import SwiftUI

/// General tab in Settings - storage, cache, and about
struct GeneralSettingsView: View {
    @EnvironmentObject var viewModel: SettingsViewModel
    @State private var showClearCacheConfirmation = false
    @State private var showResetConfirmation = false
    @State private var isClearing = false

    @AppStorage("vlmIdleTimeoutOverride") private var vlmTimeout: String = "auto"

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                // Header
                VStack(alignment: .leading, spacing: 4) {
                    Text("General")
                        .font(.title2.bold())
                    Text("Storage management and application settings")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Divider()

                // Storage
                storageSection

                Divider()

                // Data Locations
                dataLocationsSection

                Divider()

                // Performance
                performanceSection

                Divider()

                // Reset
                resetSection

                Divider()

                // About
                aboutSection

                Spacer()
            }
            .padding()
        }
        .onAppear {
            viewModel.loadStorageInfo()
        }
        .alert("Clear Cache?", isPresented: $showClearCacheConfirmation) {
            Button("Cancel", role: .cancel) { }
            Button("Clear", role: .destructive) {
                isClearing = true
                Task {
                    await viewModel.clearCache()
                    isClearing = false
                }
            }
        } message: {
            Text("This will remove temporary files and cached data. Downloaded models will not be affected.")
        }
        .alert("Reset Settings?", isPresented: $showResetConfirmation) {
            Button("Cancel", role: .cancel) { }
            Button("Reset", role: .destructive) {
                viewModel.settingsManager.resetToDefaults()
            }
        } message: {
            Text("This will reset all settings to their default values. Your downloaded models and projects will not be affected.")
        }
    }

    // MARK: - Sections

    @ViewBuilder
    private var storageSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Storage", systemImage: "internaldrive")
                    .font(.headline)

                Spacer()

                if viewModel.isLoadingStorage {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Button {
                        viewModel.loadStorageInfo()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                }
            }

            if let storageInfo = viewModel.storageInfo {
                VStack(spacing: 8) {
                    storageRow(label: "Downloaded Models", value: storageInfo.formattedModelsSize, icon: "cube.box.fill", color: .blue)
                    storageRow(label: "Cache", value: storageInfo.formattedCacheSize, icon: "folder.fill", color: .orange)
                    storageRow(label: "Projects", value: storageInfo.formattedProjectsSize, icon: "doc.fill", color: .purple)

                    Divider()

                    HStack {
                        Text("Total Used")
                            .font(.callout.weight(.semibold))
                        Spacer()
                        Text(storageInfo.formattedTotalSize)
                            .font(.callout.weight(.semibold))
                    }

                    HStack {
                        Text("Available")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(storageInfo.formattedAvailableSpace)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding()
                .background(Color.primary.opacity(0.03))
                .clipShape(RoundedRectangle(cornerRadius: 8))

                Button {
                    showClearCacheConfirmation = true
                } label: {
                    HStack {
                        if isClearing {
                            ProgressView()
                                .controlSize(.small)
                        }
                        Label("Clear Cache", systemImage: "trash")
                    }
                }
                .buttonStyle(.bordered)
                .disabled(isClearing)
            } else {
                HStack {
                    ProgressView()
                    Text("Calculating storage...")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding()
            }
        }
    }

    @ViewBuilder
    private var dataLocationsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Data Locations", systemImage: "folder")
                .font(.headline)

            VStack(spacing: 8) {
                locationRow(label: "Models", path: PathManager.modelsDirectory.path)
                locationRow(label: "Projects", path: PathManager.projectsDirectory.path)
                locationRow(label: "Cache", path: PathManager.cacheDirectory.path)
            }
            .padding()
            .background(Color.primary.opacity(0.03))
            .clipShape(RoundedRectangle(cornerRadius: 8))

            Button {
                NSWorkspace.shared.open(PathManager.appSupportDirectory)
            } label: {
                Label("Open in Finder", systemImage: "folder")
            }
            .buttonStyle(.bordered)
        }
    }

    @ViewBuilder
    private var performanceSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Performance", systemImage: "gauge")
                .font(.headline)

            VStack(alignment: .leading, spacing: 16) {
                // VLM Idle Timeout setting
                VStack(alignment: .leading, spacing: 8) {
                    Text("Vision Model Idle Timeout")
                        .font(.subheadline.weight(.medium))

                    Text("Controls how long the vision model stays loaded in memory when not in use")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Picker("VLM Timeout", selection: $vlmTimeout) {
                        Text("Auto (memory-based)").tag("auto")
                        Text("Always keep warm").tag("always_warm")
                        Text("5 minutes").tag("5min")
                        Text("10 minutes").tag("10min")
                    }
                    .pickerStyle(.radioGroup)
                    .labelsHidden()

                    // Show current behavior based on selection and system memory
                    let coordinator = ModelLoadingCoordinator.shared
                    let ramGB = coordinator.systemRAM / (1024 * 1024 * 1024)
                    let effectiveBehavior: String = {
                        switch vlmTimeout {
                        case "auto":
                            return ramGB >= 24 ? "System has \(ramGB)GB RAM - keeping warm" : "System has \(ramGB)GB RAM - 5 minute timeout"
                        case "always_warm":
                            return "Always keeping warm"
                        case "5min":
                            return "5 minute timeout"
                        case "10min":
                            return "10 minute timeout"
                        default:
                            return ""
                        }
                    }()

                    Text(effectiveBehavior)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .padding(.top, 4)
                }
                .padding()
                .background(Color.primary.opacity(0.03))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    @ViewBuilder
    private var resetSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Reset", systemImage: "arrow.counterclockwise")
                .font(.headline)

            Text("Reset all settings to their default values")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Button(role: .destructive) {
                showResetConfirmation = true
            } label: {
                Label("Reset Settings", systemImage: "arrow.counterclockwise")
            }
            .buttonStyle(.bordered)
        }
    }

    @ViewBuilder
    private var aboutSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("About", systemImage: "info.circle")
                .font(.headline)

            HStack(spacing: 16) {
                // App icon placeholder
                RoundedRectangle(cornerRadius: 12)
                    .fill(LinearGradient(colors: [.blue, .purple], startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 64, height: 64)
                    .overlay {
                        Image(systemName: "cube.transparent")
                            .font(.largeTitle)
                            .foregroundStyle(.white)
                    }

                VStack(alignment: .leading, spacing: 4) {
                    Text("Modelr")
                        .font(.title3.bold())

                    if let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String,
                       let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String {
                        Text("Version \(version) (\(build))")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }

                    Text("3D model generation from images")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            .padding()
            .background(Color.primary.opacity(0.03))
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }

    // MARK: - Helpers

    @ViewBuilder
    private func storageRow(label: String, value: String, icon: String, color: Color) -> some View {
        HStack {
            Image(systemName: icon)
                .foregroundStyle(color)
                .frame(width: 20)
            Text(label)
                .font(.callout)
            Spacer()
            Text(value)
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func locationRow(label: String, path: String) -> some View {
        HStack {
            Text(label)
                .font(.callout)
                .frame(width: 80, alignment: .leading)
            Text(path)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(path, forType: .string)
            } label: {
                Image(systemName: "doc.on.doc")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Preview

#Preview {
    GeneralSettingsView()
        .environmentObject(SettingsViewModel())
        .frame(width: 650, height: 600)
}
