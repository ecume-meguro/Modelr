import SwiftUI
import AppKit

/// Download progress step - functional design with dock integration
struct SetupDownloadView: View {
    @EnvironmentObject var viewModel: SetupWizardViewModel
    var onCancel: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            if let error = viewModel.downloadError {
                errorView(error)
            } else {
                progressContent
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onChange(of: progressValue) { _, newValue in
            updateDockProgress(newValue)
        }
        .onDisappear {
            clearDockProgress()
        }
    }

    // MARK: - Progress Content

    private var progressContent: some View {
        VStack(spacing: 0) {
            Spacer()

            // Progress visualization
            VStack(spacing: AppDesign.Spacing.p24) {
                // Circular progress with percentage
                ZStack {
                    // Background track
                    Circle()
                        .stroke(Color.primary.opacity(0.08), lineWidth: 8)
                        .frame(width: 80, height: 80)

                    // Progress arc
                    Circle()
                        .trim(from: 0, to: viewModel.overallProgress)
                        .stroke(
                            Color.accentColor,
                            style: StrokeStyle(lineWidth: 8, lineCap: .round)
                        )
                        .frame(width: 80, height: 80)
                        .rotationEffect(.degrees(-90))
                        .animation(.linear(duration: 0.3), value: viewModel.overallProgress)

                    // Percentage
                    Text("\(Int(viewModel.overallProgress * 100))%")
                        .font(.system(size: 18, weight: .semibold, design: .rounded))
                        .foregroundStyle(.primary)
                        .accessibilityLabel("Setup progress: \(Int(viewModel.overallProgress * 100)) percent")
                }

                // Status section
                VStack(spacing: AppDesign.Spacing.p6) {
                    // Current task name - primary text with more prominence
                    Text(viewModel.environmentSetupStatus)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.primary)

                    // Time remaining - secondary text
                    if !viewModel.overallTimeRemaining.isEmpty {
                        Text("About \(viewModel.overallTimeRemaining) remaining")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    } else {
                        Text("One-time setup")
                            .font(.system(size: 12))
                            .foregroundStyle(.tertiary)
                    }
                }

                // Download stats (when actively downloading)
                if !viewModel.downloadSpeed.isEmpty {
                    downloadStatsView
                }
            }

            Spacer()

            // Bottom section: cancel button
            HStack {
                Spacer()

                Button(role: .destructive) {
                    onCancel()
                } label: {
                    Text("Cancel")
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
            }
            .padding(.horizontal, AppDesign.Spacing.p32)
            .padding(.bottom, AppDesign.Spacing.p24)
        }
    }

    private var progressValue: Double {
        // Progress now comes from filesystem monitoring
        return viewModel.overallProgress
    }

    // MARK: - Download Stats View

    private var downloadStatsView: some View {
        VStack(spacing: AppDesign.Spacing.p8) {
            // Speed and time remaining
            HStack(spacing: AppDesign.Spacing.p12) {
                // Download speed
                HStack(spacing: AppDesign.Spacing.p4) {
                    Image(systemName: "arrow.down.circle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Download speed")
                    Text(viewModel.downloadSpeed)
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(.primary)
                }

                Spacer()

                // Time remaining
                if !viewModel.currentTaskTimeRemaining.isEmpty {
                    Text(viewModel.currentTaskTimeRemaining)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: 280)

            // Linear progress bar
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    // Background track
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.primary.opacity(0.08))

                    // Progress fill
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.accentColor)
                        .frame(width: geometry.size.width * viewModel.currentTaskProgress)
                        .animation(.linear(duration: 0.3), value: viewModel.currentTaskProgress)
                }
            }
            .frame(maxWidth: 280, maxHeight: 4)
        }
        .padding(.top, AppDesign.Spacing.p8)
    }

    // MARK: - Error View

    @ViewBuilder
    private func errorView(_ error: Error) -> some View {
        let errorInfo = categorizeError(error)

        VStack(spacing: 0) {
            Spacer()

            VStack(spacing: AppDesign.Spacing.p24) {
                Image(systemName: errorInfo.icon)
                    .font(.system(size: 40, weight: .light))
                    .foregroundStyle(errorInfo.color)

                VStack(spacing: AppDesign.Spacing.p6) {
                    Text(errorInfo.title)
                        .font(.system(size: 20, weight: .semibold))

                    Text(errorInfo.message)
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .lineLimit(nil)
                        .frame(maxWidth: 300)

                    if !errorInfo.suggestion.isEmpty {
                        Text(errorInfo.suggestion)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.primary.opacity(0.7))
                            .multilineTextAlignment(.center)
                            .lineLimit(nil)
                            .frame(maxWidth: 300)
                            .padding(.top, AppDesign.Spacing.p4)
                    }
                }

                HStack(spacing: AppDesign.Spacing.p12) {
                    Button("Try Again") {
                        viewModel.startSetup()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.regular)

                    Button("View Logs") {
                        NSWorkspace.shared.open(PathManager.logsDirectory)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.regular)
                }
            }

            Spacer()

            // Back button
            HStack {
                Button("Back") {
                    onCancel()
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)

                Spacer()
            }
            .padding(.horizontal, AppDesign.Spacing.p32)
            .padding(.bottom, AppDesign.Spacing.p24)
        }
    }

    // MARK: - Error Categorization

    private struct ErrorInfo {
        let title: String
        let message: String
        let suggestion: String
        let icon: String
        let color: Color
    }

    private func categorizeError(_ error: Error) -> ErrorInfo {
        let nsError = error as NSError
        let errorMessage = error.localizedDescription.lowercased()

        // Network errors
        if nsError.domain == NSURLErrorDomain ||
           errorMessage.contains("network") ||
           errorMessage.contains("internet") ||
           errorMessage.contains("connection") ||
           errorMessage.contains("offline") ||
           errorMessage.contains("timed out") ||
           errorMessage.contains("could not connect") {
            return ErrorInfo(
                title: "Network Error",
                message: "Unable to download required files. Please check your internet connection.",
                suggestion: "Try connecting to a different network or disable VPN if active.",
                icon: "wifi.exclamationmark",
                color: .orange
            )
        }

        // Timeout errors
        if errorMessage.contains("timeout") ||
           errorMessage.contains("timed out") ||
           nsError.code == NSURLErrorTimedOut {
            return ErrorInfo(
                title: "Download Timed Out",
                message: "The download took too long to complete.",
                suggestion: "This may be due to slow network. Try again when you have a faster connection.",
                icon: "clock.badge.exclamationmark",
                color: .orange
            )
        }

        // Storage/disk errors
        if errorMessage.contains("disk") ||
           errorMessage.contains("space") ||
           errorMessage.contains("storage") ||
           errorMessage.contains("no space left") ||
           errorMessage.contains("quota") ||
           nsError.code == NSFileWriteOutOfSpaceError {
            return ErrorInfo(
                title: "Insufficient Storage",
                message: "Not enough disk space to complete the download.",
                suggestion: "Free up at least 20GB of disk space and try again.",
                icon: "externaldrive.badge.exclamationmark",
                color: .red
            )
        }

        // Permission errors
        if errorMessage.contains("permission") ||
           errorMessage.contains("access denied") ||
           errorMessage.contains("not permitted") ||
           errorMessage.contains("operation not allowed") ||
           nsError.code == NSFileWriteNoPermissionError ||
           nsError.code == NSFileReadNoPermissionError {
            return ErrorInfo(
                title: "Permission Denied",
                message: "Unable to write files to the application directory.",
                suggestion: "Check that Modelr has permission to access the Application Support folder in System Settings > Privacy & Security.",
                icon: "lock.shield",
                color: .red
            )
        }

        // Process/execution errors
        if errorMessage.contains("process") ||
           errorMessage.contains("exit code") ||
           errorMessage.contains("terminated") {
            return ErrorInfo(
                title: "Setup Process Failed",
                message: "A required setup process encountered an error.",
                suggestion: "View logs for technical details. Retry usually resolves temporary issues.",
                icon: "gearshape.2",
                color: .orange
            )
        }

        // Default/unknown error
        return ErrorInfo(
            title: "Setup Failed",
            message: error.localizedDescription,
            suggestion: "If this persists, try restarting the app or check the logs for details.",
            icon: "exclamationmark.triangle",
            color: .orange
        )
    }

    // MARK: - Dock Progress

    private func updateDockProgress(_ progress: Double) {
        let dockTile = NSApp.dockTile

        if dockTile.contentView == nil {
            let progressView = DockProgressView()
            dockTile.contentView = progressView
        }

        if let progressView = dockTile.contentView as? DockProgressView {
            progressView.progress = progress
        }

        dockTile.display()
    }

    private func clearDockProgress() {
        let dockTile = NSApp.dockTile
        dockTile.contentView = nil
        dockTile.display()
    }
}

// MARK: - Dock Progress View

private class DockProgressView: NSView {
    var progress: Double = 0 {
        didSet { needsDisplay = true }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        // Draw app icon
        if let appIcon = NSApp.applicationIconImage {
            appIcon.draw(in: bounds)
        }

        // Draw progress bar at bottom
        let barHeight: CGFloat = 8
        let barInset: CGFloat = 8
        let barY: CGFloat = 4

        let barRect = NSRect(
            x: barInset,
            y: barY,
            width: bounds.width - (barInset * 2),
            height: barHeight
        )

        // Background
        NSColor.black.withAlphaComponent(0.5).setFill()
        let bgPath = NSBezierPath(roundedRect: barRect, xRadius: barHeight / 2, yRadius: barHeight / 2)
        bgPath.fill()

        // Progress
        let progressWidth = barRect.width * CGFloat(progress)
        let progressRect = NSRect(
            x: barRect.origin.x,
            y: barRect.origin.y,
            width: progressWidth,
            height: barHeight
        )

        NSColor.systemBlue.setFill()
        let progressPath = NSBezierPath(roundedRect: progressRect, xRadius: barHeight / 2, yRadius: barHeight / 2)
        progressPath.fill()
    }
}

// MARK: - Preview

#Preview {
    SetupDownloadView(onCancel: {})
        .environmentObject(SetupWizardViewModel())
        .frame(width: 560, height: 420)
        .background(Color(nsColor: .windowBackgroundColor))
}
