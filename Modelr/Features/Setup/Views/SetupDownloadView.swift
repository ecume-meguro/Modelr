import SwiftUI

/// Download progress step of the setup wizard
struct SetupDownloadView: View {
    @EnvironmentObject var viewModel: SetupWizardViewModel
    @State private var showLogs = false

    var body: some View {
        VStack(spacing: 24) {
            // Header
            VStack(spacing: 8) {
                Text("Setting Up")
                    .font(.title.bold())
                Text("Please wait while we prepare everything")
                    .font(.body)
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 32)

            Spacer()

            // Progress content
            VStack(spacing: 32) {
                // Animated download icon
                downloadAnimation

                // Status text
                VStack(spacing: 8) {
                    Text(viewModel.environmentSetupStatus)
                        .font(.headline)

                    if let progress = viewModel.downloadProgress {
                        progressDetails(progress)
                    } else if viewModel.isSettingUpEnvironment {
                        environmentProgressDetails
                    }
                }

                // Progress bar
                progressBar
            }
            .padding(.horizontal, 80)

            Spacer()

            // Error display
            if let error = viewModel.downloadError {
                errorView(error)
                    .padding(.horizontal, 60)
            }

            // Expandable logs
            logsSection
                .padding(.horizontal, 60)
        }
    }

    // MARK: - Download Animation

    @ViewBuilder
    private var downloadAnimation: some View {
        ZStack {
            // Background circles
            ForEach(0..<3, id: \.self) { index in
                Circle()
                    .stroke(Color.accentColor.opacity(0.1 * Double(3 - index)), lineWidth: 2)
                    .frame(width: CGFloat(80 + index * 30), height: CGFloat(80 + index * 30))
            }

            // Center icon
            ZStack {
                Circle()
                    .fill(Color.accentColor)
                    .frame(width: 60, height: 60)

                if viewModel.isDownloading {
                    Image(systemName: "arrow.down")
                        .font(.title2.bold())
                        .foregroundStyle(.white)
                        .offset(y: downloadIconOffset)
                        .animation(
                            .easeInOut(duration: 1.0)
                            .repeatForever(autoreverses: true),
                            value: downloadIconOffset
                        )
                } else {
                    Image(systemName: "checkmark")
                        .font(.title2.bold())
                        .foregroundStyle(.white)
                }
            }
        }
    }

    @State private var downloadIconOffset: CGFloat = -5

    // MARK: - Progress Details

    @ViewBuilder
    private func progressDetails(_ progress: ModelDownloadProgress) -> some View {
        VStack(spacing: 4) {
            Text(progress.formattedProgress)
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(.secondary)

            HStack(spacing: 12) {
                if !progress.formattedSpeed.isEmpty && progress.formattedSpeed != "—" {
                    Text(progress.formattedSpeed)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.tertiary)
                }

                if !progress.formattedETA.isEmpty {
                    Text(progress.formattedETA)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .animation(.easeInOut(duration: 0.2), value: progress.downloadedBytes)
    }

    @ViewBuilder
    private var environmentProgressDetails: some View {
        Text("\(Int(viewModel.environmentSetupProgress * 100))%")
            .font(.system(.body, design: .monospaced))
            .foregroundStyle(.secondary)
    }

    // MARK: - Progress Bar

    @ViewBuilder
    private var progressBar: some View {
        VStack(spacing: 8) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    // Background
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.primary.opacity(0.1))

                    // Progress fill
                    RoundedRectangle(cornerRadius: 6)
                        .fill(
                            LinearGradient(
                                colors: [.accentColor, .accentColor.opacity(0.8)],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(width: geo.size.width * progressValue)
                        .animation(.easeInOut(duration: 0.3), value: progressValue)
                }
            }
            .frame(height: 12)

            // Stage labels
            HStack {
                Text(viewModel.isSettingUpEnvironment ? "Environment Setup" : "Downloading \(viewModel.selectedModelChoice.modelName)")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                Spacer()
            }
        }
    }

    private var progressValue: Double {
        if viewModel.isSettingUpEnvironment {
            // Environment setup is 0-60% of total
            return viewModel.environmentSetupProgress * 0.6
        } else if let progress = viewModel.downloadProgress {
            // Download is 60-100% of total
            return 0.6 + (progress.progress * 0.4)
        }
        return 0
    }

    // MARK: - Error View

    @ViewBuilder
    private func errorView(_ error: Error) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.title2)
                    .foregroundStyle(.red)

                VStack(alignment: .leading, spacing: 4) {
                    Text("Setup Failed")
                        .font(.headline)
                    Text(error.localizedDescription)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Spacer()
            }

            // Show recovery suggestion if available
            if let nsError = error as NSError?,
               let suggestion = nsError.userInfo[NSLocalizedRecoverySuggestionErrorKey] as? String {
                HStack(spacing: 8) {
                    Image(systemName: "lightbulb.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                    Text(suggestion)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 4)
            }

            // Action buttons
            HStack(spacing: 12) {
                Button {
                    viewModel.startSetup()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.clockwise")
                        Text("Retry")
                    }
                }
                .buttonStyle(.borderedProminent)

                Button {
                    // Open logs for troubleshooting
                    NSWorkspace.shared.open(PathManager.logsDirectory)
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "doc.text")
                        Text("View Logs")
                    }
                }
                .buttonStyle(.bordered)

                // Check connectivity button for network errors
                if error.localizedDescription.contains("connection") ||
                   error.localizedDescription.contains("network") ||
                   error.localizedDescription.contains("internet") {
                    Button {
                        Task {
                            let canReach = await NetworkMonitor.canReachHuggingFace()
                            let message = canReach ? "Connection to HuggingFace successful!" : "Cannot reach HuggingFace. Check your network."
                            let alert = NSAlert()
                            alert.messageText = "Network Check"
                            alert.informativeText = message
                            alert.alertStyle = canReach ? .informational : .warning
                            alert.runModal()
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "network")
                            Text("Test Connection")
                        }
                    }
                    .buttonStyle(.bordered)
                }
            }
            .padding(.top, 8)
        }
        .padding()
        .background(Color.red.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - Logs Section

    @ViewBuilder
    private var logsSection: some View {
        VStack(spacing: 8) {
            Button {
                withAnimation {
                    showLogs.toggle()
                }
            } label: {
                HStack {
                    Text("Show Details")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Image(systemName: showLogs ? "chevron.up" : "chevron.down")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            .buttonStyle(.plain)

            if showLogs {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(Array(viewModel.environmentSetupLogs.enumerated()), id: \.offset) { index, line in
                                Text(line)
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .id(index)
                            }
                        }
                        .padding(8)
                    }
                    .frame(height: 120)
                    .background(Color.black.opacity(0.05))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .onChange(of: viewModel.environmentSetupLogs.count) { _, _ in
                        withAnimation {
                            proxy.scrollTo(viewModel.environmentSetupLogs.count - 1, anchor: .bottom)
                        }
                    }
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.bottom)
    }
}

// MARK: - Preview

#Preview {
    SetupDownloadView()
        .environmentObject(SetupWizardViewModel())
        .frame(width: 700, height: 550)
}
