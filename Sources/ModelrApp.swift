import SwiftUI

@main
struct ModelrApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var store = ProjectStore()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(store)
                .frame(minWidth: 480, minHeight: 480)
        }
        .defaultSize(width: 1180, height: 760)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Project") { store.newProject() }
                    .keyboardShortcut("n", modifiers: .command)
            }
            CommandMenu("Generate") {
                Button("Generate / Regenerate Shape") {
                    if let id = store.selection { store.generate(id) }
                }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(store.selection == nil)

                Button("Paint Texture") {
                    if let id = store.selection { store.paint(id) }
                }
                .keyboardShortcut("p", modifiers: [.command, .shift])
                .disabled(store.selection == nil || !ModelStore.isPaintAvailable)

                Divider()

                Button("Stop") {
                    if let id = store.selection { store.cancel(id) }   // cancels shape + paint
                }
                .keyboardShortcut(".", modifiers: .command)
                .disabled(store.selection == nil)

                Divider()

                Button(store.downloadProgress == nil
                       ? "Download Missing Model Weights…"
                       : "Downloading… \(Int((store.downloadProgress?.fraction ?? 0) * 100))%") {
                    if let id = store.selection { store.downloadModels(for: id) }
                }
                .disabled(store.selection == nil || store.downloadProgress != nil)
            }
        }
    }
}

/// Generation now runs in-process (vendored MLX), so there are no worker
/// subprocesses to reap — the delegate only governs app lifecycle.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}
