import Foundation

/// Shared utilities for managing Python processes
enum ProcessUtilities {
    /// Recursively find all child processes of a given PID
    /// Uses `pgrep` to find children and recursively finds their children
    /// - Parameter pid: The parent process ID
    /// - Returns: Array of all child PIDs (direct and transitive)
    static func findChildProcesses(_ pid: pid_t) -> [pid_t] {
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
                    // Recursively find children of this child
                    result.append(contentsOf: findChildProcesses(childPid))
                }
            }
        } catch {
            // Ignore - process may have already exited
        }

        return result
    }

    /// Gracefully terminate a process tree (process + all children)
    /// First tries SIGTERM with grace period, then SIGKILL
    /// Also attempts process group termination
    /// - Parameters:
    ///   - pid: The process ID to terminate
    ///   - gracePeriod: Microseconds to wait between SIGTERM and SIGKILL (default: 200ms)
    static func terminateProcessTree(_ pid: pid_t, gracePeriod: UInt32 = 200_000) {
        guard pid > 0 else { return }

        // Find and kill all child processes first (uv spawns Python in separate group)
        let children = findChildProcesses(pid)
        for childPid in children.reversed() {
            print("[ProcessUtilities] Killing child PID \(childPid)")
            kill(childPid, SIGTERM)
        }

        if !children.isEmpty {
            usleep(100_000) // 100ms for SIGTERM to take effect
            for childPid in children.reversed() {
                kill(childPid, SIGKILL)
            }
        }

        // Also try process group (may work for some processes)
        let pgid = getpgid(pid)
        if pgid > 0 {
            kill(-pgid, SIGTERM)
            usleep(50_000) // 50ms
            kill(-pgid, SIGKILL)
        }

        // Finally terminate the main process
        kill(pid, SIGTERM)
        usleep(gracePeriod)
        kill(pid, SIGKILL)
    }
}
