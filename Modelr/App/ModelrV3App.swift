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
        if CommandLine.arguments.contains("--force-setup") ||
           ProcessInfo.processInfo.environment["FORCE_SETUP"] == "1" {
            PathManager.clearSetupMarker()
            print("[App] Force setup mode: cleared setup marker")
        }
        // Note: HuggingFace model size queries are only made during setup
        // or when user selects a preset requiring a model they don't have
    }

    var body: some Scene {
        WindowGroup {
            // Setup is now integrated into SimpleEditorView as the first step
            SimpleEditorView()
        }
    }
}
