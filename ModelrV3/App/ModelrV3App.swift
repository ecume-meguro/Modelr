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
    private var forceSetup: Bool {
        CommandLine.arguments.contains("--force-setup") ||
        ProcessInfo.processInfo.environment["FORCE_SETUP"] == "1"
    }

    var body: some Scene {
        WindowGroup {
            RootView(forceSetup: forceSetup)
        }
    }
}

/// Root view that handles first-run setup vs main app
struct RootView: View {
    let forceSetup: Bool

    @State private var isSetupComplete: Bool

    init(forceSetup: Bool) {
        self.forceSetup = forceSetup
        // Check if setup was completed previously
        let wasSetupComplete = UserDefaults.standard.bool(forKey: "SetupComplete")
        _isSetupComplete = State(initialValue: forceSetup ? false : wasSetupComplete)
    }

    var body: some View {
        Group {
            if isSetupComplete {
                ContentViewSimple()
            } else {
                SetupView(isSetupComplete: $isSetupComplete)
            }
        }
    }
}
