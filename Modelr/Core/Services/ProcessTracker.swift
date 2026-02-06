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

            // Use shared utilities for process tree termination
            ProcessUtilities.terminateProcessTree(pid)
        }

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
}
