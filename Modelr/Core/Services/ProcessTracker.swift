import os.log
import Foundation

/// Tracks spawned processes during setup and ensures proper cleanup
class ProcessTracker {
    private var trackedProcesses: [(process: Process, description: String)] = []
    private let lock = NSLock()

    /// Register a process for tracking and automatic cleanup
    func track(_ process: Process, description: String) {
        lock.lock()
        defer { lock.unlock() }

        trackedProcesses.append((process, description))
        print("[ProcessTracker] Tracking process: \(description) (PID: \(process.processIdentifier))")
    }

    /// Kill all tracked processes and their children
    func killAll() {
        lock.lock()
        let processes = trackedProcesses
        lock.unlock()

        print("[ProcessTracker] Killing \(processes.count) tracked processes...")

        for (process, description) in processes {
            guard process.isRunning else { continue }

            let pid = process.processIdentifier
            print("[ProcessTracker] Terminating \(description) (PID: \(pid))")

            // Kill child processes first
            killProcessTree(pid)

            // Then terminate the main process
            process.terminate()

            // Force kill if still running after grace period
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) {
                if process.isRunning {
                    kill(pid, SIGKILL)
                }
            }
        }

        // Clear tracked processes
        lock.lock()
        trackedProcesses.removeAll()
        lock.unlock()
    }

    /// Remove completed processes from tracking
    func cleanup() {
        lock.lock()
        defer { lock.unlock() }

        trackedProcesses.removeAll { !$0.process.isRunning }
    }

    /// Kill a process tree (process and all descendants)
    private func killProcessTree(_ pid: pid_t) {
        let children = findChildProcesses(pid)

        // Kill children first (bottom-up)
        for childPid in children.reversed() {
            print("[ProcessTracker] Killing child PID \(childPid)")
            kill(childPid, SIGTERM)
        }

        // Brief grace period
        if !children.isEmpty {
            usleep(100_000) // 100ms
        }

        // Force kill any remaining children
        for childPid in children.reversed() {
            kill(childPid, SIGKILL)
        }

        // Try to kill the process group as well
        let pgid = getpgid(pid)
        if pgid > 0 && pgid != pid {
            kill(-pgid, SIGTERM)
            usleep(50_000)
            kill(-pgid, SIGKILL)
        }
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
}
