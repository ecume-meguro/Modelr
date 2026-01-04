import SwiftUI

@main
struct ModelrV3App: App {
    // Check for debug mode via command line argument or environment variable
    // Launch with: --debug-3d-viewer or set DEBUG_3D_VIEWER=1
    private var isDebug3DViewer: Bool {
        CommandLine.arguments.contains("--debug-3d-viewer") ||
        ProcessInfo.processInfo.environment["DEBUG_3D_VIEWER"] == "1"
    }

    // Check for force setup mode (for testing)
    // This now resets the SetupComplete flag to force re-running setup
    init() {
        if CommandLine.arguments.contains("--force-setup") ||
           ProcessInfo.processInfo.environment["FORCE_SETUP"] == "1" {
            UserDefaults.standard.set(false, forKey: "SetupComplete")
        }
    }

    var body: some Scene {
        WindowGroup {
            // Setup is now integrated into SimpleEditorView as the first step
            SimpleEditorView()
        }
    }
}
