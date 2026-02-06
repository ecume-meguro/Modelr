import SwiftUI

/// Welcome step - clean, functional design with inline action
struct SetupWelcomeView: View {
    @EnvironmentObject var viewModel: SetupWizardViewModel
    var onContinue: () -> Void

    private var hardwareInfo: WelcomeHardwareInfo { WelcomeHardwareInfo() }

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            // App icon and title
            VStack(spacing: AppDesign.Spacing.p24) {
                let appIcon = NSImage(named: "AppIcon")
                Image(nsImage: appIcon ?? NSImage())
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 96, height: 96)
                    .shadow(color: .black.opacity(0.1), radius: 12, y: 6)
                    .overlay {
                        if appIcon == nil {
                            Image(systemName: "cube.fill")
                                .font(.system(size: 56))
                                .foregroundStyle(.tint)
                        }
                    }

                VStack(spacing: 8) {
                    Text("Modelr")
                        .font(.system(size: 28, weight: .bold))

                    Text("Transform images into 3D models using local AI")
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: 400)
                }
            }

            Spacer()
                .frame(height: 40)

            // System info card
            systemInfoCard
                .padding(.horizontal, AppDesign.Spacing.p48)

            Spacer()

            // Action button
            Button {
                onContinue()
            } label: {
                Text("Get Started")
                    .frame(minWidth: 100)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(!systemReady)
            .opacity(systemReady ? 1.0 : 0.6)
            .padding(.bottom, AppDesign.Spacing.p32)
        }
    }

    private var systemInfoCard: some View {
        HStack(spacing: AppDesign.Spacing.p24) {
            // Hardware
            VStack(alignment: .leading, spacing: 4) {
                Label(hardwareInfo.chipName, systemImage: "cpu")
                    .font(.system(size: 12, weight: .medium))

                Text("\(hardwareInfo.formattedMemory) unified memory")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Divider()
                .frame(height: AppDesign.Spacing.p32)

            // Storage
            VStack(alignment: .leading, spacing: 4) {
                Label(viewModel.formattedAvailableSpace, systemImage: "internaldrive")
                    .font(.system(size: 12, weight: .medium))

                Text("available storage")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Divider()
                .frame(height: AppDesign.Spacing.p32)

            // Status
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Circle()
                        .fill(systemReady ? Color.green : Color.orange)
                        .frame(width: 8, height: 8)
                        .accessibilityLabel(systemReady ? "Status: Ready" : "Status: Requirements not met")

                    Text(systemReady ? "Ready" : "Check requirements")
                        .font(.system(size: 12, weight: .medium))
                }

                Text(systemStatusDetail)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 10))
    }

    private var systemReady: Bool {
        let ramOK = viewModel.systemRAM >= 8 * 1024 * 1024 * 1024
        let spaceOK = viewModel.availableSpace >= 10 * 1024 * 1024 * 1024
        return ramOK && spaceOK
    }

    private var systemStatusDetail: String {
        let ramOK = viewModel.systemRAM >= 8 * 1024 * 1024 * 1024
        let spaceOK = viewModel.availableSpace >= 10 * 1024 * 1024 * 1024

        if !ramOK { return "8GB+ RAM required" }
        if !spaceOK { return "10GB+ storage required" }
        return "System requirements met"
    }
}

// MARK: - Hardware Info

private struct WelcomeHardwareInfo {
    let chipName: String
    let totalMemoryGB: Int

    init() {
        var size: size_t = 0
        sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0)
        var brand = [CChar](repeating: 0, count: size)
        sysctlbyname("machdep.cpu.brand_string", &brand, &size, nil, 0)
        let cpuBrand = String(cString: brand)

        if cpuBrand.contains("Apple") {
            chipName = cpuBrand.replacingOccurrences(of: "Apple ", with: "")
        } else {
            #if arch(arm64)
            chipName = "Apple Silicon"
            #else
            chipName = cpuBrand.isEmpty ? "Intel" : cpuBrand
            #endif
        }

        totalMemoryGB = Int(ProcessInfo.processInfo.physicalMemory / (1024 * 1024 * 1024))
    }

    var formattedMemory: String {
        "\(totalMemoryGB)GB"
    }
}

// MARK: - Preview

#Preview {
    SetupWelcomeView(onContinue: {})
        .environmentObject(SetupWizardViewModel())
        .frame(width: 560, height: 420)
        .background(Color(nsColor: .windowBackgroundColor))
}
