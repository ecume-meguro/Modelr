import SwiftUI

@main
struct ModelrApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

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
        // In DEBUG builds, always refresh to pick up latest Python code changes
        #if DEBUG
        let shouldForceRefresh = true
        #else
        let shouldForceRefresh = CommandLine.arguments.contains("--refresh-resources") ||
                                 ProcessInfo.processInfo.environment["REFRESH_RESOURCES"] == "1"
        #endif

        if shouldForceRefresh {
            print("[App] Refreshing resources (DEBUG or forced)...")
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

// MARK: - App Delegate for Process Cleanup

class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillTerminate(_ notification: Notification) {
        print("[App] Terminating - cleaning up Python processes...")

        // Kill all Python processes spawned by this app
        ProcessCleanup.shared.killAllPythonProcesses()

        print("[App] Cleanup complete")
    }
}

// MARK: - Process Cleanup Helper

/// Handles cleanup of spawned Python processes on app termination
class ProcessCleanup {
    static let shared = ProcessCleanup()

    /// Track PIDs of processes we've spawned
    private var spawnedPIDs: Set<pid_t> = []
    private let lock = NSLock()

    private init() {}

    /// Register a spawned process PID for cleanup
    func registerProcess(_ pid: pid_t) {
        lock.lock()
        spawnedPIDs.insert(pid)
        lock.unlock()
        print("[ProcessCleanup] Registered PID \(pid)")
    }

    /// Unregister a process that has already exited
    func unregisterProcess(_ pid: pid_t) {
        lock.lock()
        spawnedPIDs.remove(pid)
        lock.unlock()
    }

    /// Kill all registered processes and their children
    func killAllPythonProcesses() {
        lock.lock()
        let pids = spawnedPIDs
        lock.unlock()

        for pid in pids {
            killProcessTree(pid)
        }

        // Also kill any orphaned python3.10 processes that might have been spawned by uv
        killOrphanedPythonProcesses()
    }

    /// Kill a process and all its children using process group
    private func killProcessTree(_ pid: pid_t) {
        // First try to kill the process group (negative PID)
        // This kills the process and all its children
        let pgid = getpgid(pid)
        if pgid > 0 {
            print("[ProcessCleanup] Killing process group \(pgid)")
            kill(-pgid, SIGTERM)
            usleep(100_000) // 100ms grace period
            kill(-pgid, SIGKILL)
        }

        // Also kill the specific process
        print("[ProcessCleanup] Killing PID \(pid)")
        kill(pid, SIGTERM)
        usleep(50_000) // 50ms grace period
        kill(pid, SIGKILL)
    }

    /// Find and kill any orphaned Python processes that belong to us
    private func killOrphanedPythonProcesses() {
        // Use pgrep to find python processes, then filter by our app's parent
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        task.arguments = ["-f", "python.*modelr|sam_wrapper|hunyuan_wrapper|mesh_processor"]

        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice

        do {
            try task.run()
            task.waitUntilExit()

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            if let output = String(data: data, encoding: .utf8) {
                let pids = output.components(separatedBy: .newlines)
                    .compactMap { Int32($0.trimmingCharacters(in: .whitespaces)) }

                for pid in pids {
                    print("[ProcessCleanup] Killing orphaned Python process \(pid)")
                    kill(pid, SIGTERM)
                    usleep(50_000)
                    kill(pid, SIGKILL)
                }
            }
        } catch {
            print("[ProcessCleanup] Failed to find orphaned processes: \(error)")
        }
    }
}
