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
                .disabled(store.selection == nil || !PaintConfig.isAvailable)

                Divider()

                Button("Stop") {
                    if let id = store.selection { store.cancel(id) }   // cancels shape + paint
                }
                .keyboardShortcut(".", modifiers: .command)
                .disabled(store.selection == nil)
            }
        }
    }
}

/// Handles process hygiene: sweep crash-orphaned workers at launch, kill live
/// ones on quit.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        JobReaper.sweepStale()
    }

    func applicationWillTerminate(_ notification: Notification) {
        JobReaper.killAll()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}
