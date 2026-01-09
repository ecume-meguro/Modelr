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

    /// Kill a process and all its children by recursively finding child PIDs
    private func killProcessTree(_ pid: pid_t) {
        // First, find all child processes recursively using pgrep -P
        // This is crucial because `uv run` spawns Python in a separate process group
        let children = findChildProcesses(pid)

        // Kill children first (bottom-up)
        for childPid in children.reversed() {
            print("[ProcessCleanup] Killing child PID \(childPid)")
            kill(childPid, SIGTERM)
        }

        // Brief grace period for SIGTERM
        if !children.isEmpty {
            usleep(100_000) // 100ms
        }

        // Force kill any remaining children
        for childPid in children.reversed() {
            kill(childPid, SIGKILL)
        }

        // Also try process group (may work for some processes)
        let pgid = getpgid(pid)
        if pgid > 0 && pgid != pid {
            kill(-pgid, SIGTERM)
            usleep(50_000)
            kill(-pgid, SIGKILL)
        }

        // Finally kill the parent process
        print("[ProcessCleanup] Killing PID \(pid)")
        kill(pid, SIGTERM)
        usleep(50_000) // 50ms grace period
        kill(pid, SIGKILL)
    }

    /// Recursively find all child processes of a given PID
    private func findChildProcesses(_ pid: pid_t) -> [pid_t] {
        var result: [pid_t] = []

        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        task.arguments = ["-P", "\(pid)"]

        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice

        do {
            try task.run()
            task.waitUntilExit()

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            if let output = String(data: data, encoding: .utf8) {
                let childPids = output.components(separatedBy: .newlines)
                    .compactMap { Int32($0.trimmingCharacters(in: .whitespaces)) }

                for childPid in childPids {
                    result.append(childPid)
                    // Recursively find grandchildren
                    result.append(contentsOf: findChildProcesses(childPid))
                }
            }
        } catch {
            // Ignore errors - process may have already exited
        }

        return result
    }

    /// Find and kill any orphaned Python processes that belong to us
    private func killOrphanedPythonProcesses() {
        // Multiple patterns to catch all Python processes spawned by our app:
        // 1. Processes with our wrapper scripts in args
        // 2. Python processes with Modelr paths in environment
        // 3. Python 3.10 processes in our managed environments
        let patterns = [
            "sam_wrapper\\.py",
            "hunyuan_wrapper\\.py",
            "mesh_processor\\.py",
            "Modelr.*python",
            "python.*Modelr",
            "Application Support/Modelr"
        ]

        var allPids: Set<pid_t> = []

        for pattern in patterns {
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
            task.arguments = ["-f", pattern]

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
                    allPids.formUnion(pids)
                }
            } catch {
                // Ignore - pattern may not match
            }
        }

        // Don't kill ourselves
        let myPid = getpid()
        allPids.remove(myPid)

        for pid in allPids {
            print("[ProcessCleanup] Killing orphaned Python process \(pid)")
            kill(pid, SIGTERM)
        }

        if !allPids.isEmpty {
            usleep(100_000) // 100ms grace period

            for pid in allPids {
                kill(pid, SIGKILL)
            }
        }
    }
}
