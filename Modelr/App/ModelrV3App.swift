import SwiftUI

@main
struct ModelrApp: App {
    // Check for debug mode via command line argument or environment variable
    // Launch with: --debug-3d-viewer or set DEBUG_3D_VIEWER=1
    private var isDebug3DViewer: Bool {
        CommandLine.arguments.contains("--debug-3d-viewer") ||
        ProcessInfo.processInfo.environment["DEBUG_3D_VIEWER"] == "1"
    }

    // Check for force setup mode (for testing)
    // This clears the setup completion marker to force re-running setup
    init() {
        let dependencyService = PythonDependencyService()

        if CommandLine.arguments.contains("--force-setup") ||
           ProcessInfo.processInfo.environment["FORCE_SETUP"] == "1" {
            PathManager.clearSetupMarker()
            print("[App] Force setup mode: cleared setup marker")
        }

        // Force refresh resources (useful during development)
        // Launch with: --refresh-resources or set REFRESH_RESOURCES=1
        if CommandLine.arguments.contains("--refresh-resources") ||
           ProcessInfo.processInfo.environment["REFRESH_RESOURCES"] == "1" {
            print("[App] Force refreshing resources...")
            dependencyService.refreshResources()
        } else {
            // Auto-refresh resources if app version changed (preserves models)
            dependencyService.refreshResourcesIfNeeded()
        }
    }

    var body: some Scene {
        WindowGroup {
            // Setup is now integrated into SimpleEditorView as the first step
            SimpleEditorView()
        }
    }
}
