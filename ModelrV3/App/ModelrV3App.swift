import SwiftUI

@main
struct ModelrV3App: App {
    // Check for debug mode via command line argument or environment variable
    // Launch with: --debug-3d-viewer or set DEBUG_3D_VIEWER=1
    private var isDebug3DViewer: Bool {
        CommandLine.arguments.contains("--debug-3d-viewer") ||
        ProcessInfo.processInfo.environment["DEBUG_3D_VIEWER"] == "1"
    }

    var body: some Scene {
        WindowGroup {
            ContentView(autoLoadLatest3DModel: isDebug3DViewer)
        }
    }
}
