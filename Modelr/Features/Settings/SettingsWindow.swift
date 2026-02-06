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
    @SceneStorage("settingsSelectedTab") private var selectedTab: String = SettingsTab.models.rawValue

    private var selectedTabBinding: Binding<SettingsTab> {
        Binding(
            get: { SettingsTab(rawValue: selectedTab) ?? .models },
            set: { selectedTab = $0.rawValue }
        )
    }

    var body: some View {
        TabView(selection: selectedTabBinding) {
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
        .animation(.easeInOut(duration: 0.2), value: selectedTab)
        .frame(minWidth: 700, minHeight: 500)
    }
}

// MARK: - Settings View Model

@MainActor
class SettingsViewModel: ObservableObject {
    @Published var settingsManager = SettingsManager.shared
    @Published var storageInfo: StorageInfo?
    @Published var systemInfo: SystemInfo?
    @Published var isLoadingStorage = false
    @Published var loadingError: Error?

    init() {
        loadSystemInfo()
    }

    func loadSystemInfo() {
        systemInfo = SystemInfo.current()
    }

    func loadStorageInfo() {
        guard !isLoadingStorage else { return }
        isLoadingStorage = true
        loadingError = nil

        Task {
            do {
                let info = await StorageInfo.calculate()
                await MainActor.run {
                    self.storageInfo = info
                    self.isLoadingStorage = false
                }
            } catch {
                await MainActor.run {
                    self.loadingError = error
                    self.isLoadingStorage = false
                }
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
