import SwiftUI

/// Settings tab identifiers
enum SettingsTab: String, CaseIterable {
    case models = "Models"
    case performance = "Performance"
    case general = "General"

    var icon: String {
        switch self {
        case .models: return "cube.box"
        case .performance: return "gauge.with.dots.needle.67percent"
        case .general: return "gearshape"
        }
    }
}

/// Main Settings window view
struct SettingsWindow: View {
    @StateObject private var viewModel = SettingsViewModel()
    @State private var selectedTab: SettingsTab = .models

    var body: some View {
        TabView(selection: $selectedTab) {
            ModelsSettingsView()
                .environmentObject(viewModel)
                .tabItem {
                    Label(SettingsTab.models.rawValue, systemImage: SettingsTab.models.icon)
                }
                .tag(SettingsTab.models)

            PerformanceSettingsView()
                .environmentObject(viewModel)
                .tabItem {
                    Label(SettingsTab.performance.rawValue, systemImage: SettingsTab.performance.icon)
                }
                .tag(SettingsTab.performance)

            GeneralSettingsView()
                .environmentObject(viewModel)
                .tabItem {
                    Label(SettingsTab.general.rawValue, systemImage: SettingsTab.general.icon)
                }
                .tag(SettingsTab.general)
        }
        .frame(minWidth: 650, minHeight: 500)
    }
}

// MARK: - Settings View Model

@MainActor
class SettingsViewModel: ObservableObject {
    @Published var settingsManager = SettingsManager.shared
    @Published var storageInfo: StorageInfo?
    @Published var systemInfo: SystemInfo?
    @Published var isLoadingStorage = false

    init() {
        loadSystemInfo()
    }

    func loadSystemInfo() {
        systemInfo = SystemInfo.current()
    }

    func loadStorageInfo() {
        guard !isLoadingStorage else { return }
        isLoadingStorage = true

        Task {
            let info = await StorageInfo.calculate()
            await MainActor.run {
                self.storageInfo = info
                self.isLoadingStorage = false
            }
        }
    }

    func clearCache() async {
        // Clear UV cache
        try? FileManager.default.removeItem(at: PathManager.uvCacheDirectory)
        try? PathManager.ensureDirectoryExists(at: PathManager.uvCacheDirectory)

        // Clear working directory
        try? FileManager.default.removeItem(at: PathManager.workingDirectory)
        try? PathManager.ensureDirectoryExists(at: PathManager.workingDirectory)

        // Reload storage info
        loadStorageInfo()
    }
}

// MARK: - Preview

#Preview {
    SettingsWindow()
}
