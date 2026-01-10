import SwiftUI

/// Welcome step of the setup wizard
struct SetupWelcomeView: View {
    @EnvironmentObject var viewModel: SetupWizardViewModel

    var body: some View {
        VStack(spacing: 32) {
            Spacer()

            // App icon and title
            VStack(spacing: 16) {
                // Animated icon
                ZStack {
                    Circle()
                        .fill(
                            LinearGradient(
                                colors: [.blue, .purple],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 100, height: 100)

                    Image(systemName: "cube.transparent")
                        .font(.system(size: 48, weight: .medium))
                        .foregroundStyle(.white)
                }

                Text("Welcome to Modelr")
                    .font(.largeTitle.bold())

                Text("Transform your images into stunning 3D models")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }

            // Feature highlights
            VStack(alignment: .leading, spacing: 16) {
                featureRow(
                    icon: "photo.stack",
                    title: "Image to 3D",
                    description: "Convert any image into a detailed 3D model using AI"
                )
                featureRow(
                    icon: "wand.and.stars",
                    title: "Smart Segmentation",
                    description: "Automatically detect and isolate objects in your images"
                )
                featureRow(
                    icon: "cube.box",
                    title: "Export Anywhere",
                    description: "Export to OBJ, USDZ, GLB and more"
                )
            }
            .padding(.horizontal, 40)

            Spacer()

            // System requirements check
            systemRequirementsCard
        }
        .padding()
    }

    @ViewBuilder
    private func featureRow(icon: String, title: String, description: String) -> some View {
        HStack(spacing: 16) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(.blue)
                .frame(width: 36)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.headline)
                Text(description)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private var systemRequirementsCard: some View {
        HStack(spacing: 24) {
            systemInfoItem(
                icon: "memorychip",
                label: "RAM",
                value: viewModel.formattedSystemRAM,
                status: viewModel.systemRAM >= 8 * 1024 * 1024 * 1024 ? .good : .warning
            )

            Divider()
                .frame(height: 40)

            systemInfoItem(
                icon: "internaldrive",
                label: "Free Space",
                value: viewModel.formattedAvailableSpace,
                status: viewModel.availableSpace >= 20 * 1024 * 1024 * 1024 ? .good : .warning
            )
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
        .background(Color.primary.opacity(0.03))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal, 40)
    }

    private enum SystemStatus {
        case good, warning, error
    }

    @ViewBuilder
    private func systemInfoItem(icon: String, label: String, value: String, status: SystemStatus) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(statusColor(status))

            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.callout.weight(.medium))
            }

            Image(systemName: statusIcon(status))
                .font(.caption)
                .foregroundStyle(statusColor(status))
        }
    }

    private func statusColor(_ status: SystemStatus) -> Color {
        switch status {
        case .good: return .green
        case .warning: return .orange
        case .error: return .red
        }
    }

    private func statusIcon(_ status: SystemStatus) -> String {
        switch status {
        case .good: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .error: return "xmark.circle.fill"
        }
    }
}

// MARK: - Preview

#Preview {
    SetupWelcomeView()
        .environmentObject(SetupWizardViewModel())
        .frame(width: 700, height: 550)
}
