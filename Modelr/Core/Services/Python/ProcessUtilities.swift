import Foundation

/// Shared utilities for managing Python processes
/// Consolidates process lifecycle management to avoid code duplication
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
                    result.append(contentsOf: findChildProcesses(childPid))
                }
            }
        } catch {
            // Ignore - process may have already exited
        }

        return result
    }

    /// Check if a process is still running
    /// - Parameter pid: The process ID to check
    /// - Returns: true if process exists and is running
    static func isProcessRunning(_ pid: pid_t) -> Bool {
        // kill with signal 0 checks if process exists without sending a signal
        return kill(pid, 0) == 0
    }

    /// Terminate all child processes of a given PID
    /// Sends SIGTERM first, waits, then SIGKILL only if still running
    /// - Parameter pid: The parent process ID
    static func terminateChildren(_ pid: pid_t) {
        let children = findChildProcesses(pid)
        guard !children.isEmpty else { return }

        // SIGTERM first (bottom-up), only if process is running
        for childPid in children.reversed() {
            if isProcessRunning(childPid) {
                kill(childPid, SIGTERM)
            }
        }

        usleep(AppConstants.sigtermGracePeriodMicroseconds)

        // Force kill any remaining (check if still running before SIGKILL)
        for childPid in children.reversed() {
            if isProcessRunning(childPid) {
                kill(childPid, SIGKILL)
            }
        }
    }

    /// Terminate a process group
    /// Checks if process is still running before sending signals
    /// - Parameter pid: A process in the group
    static func terminateProcessGroup(_ pid: pid_t) {
        let pgid = getpgid(pid)
        guard pgid > 0 else { return }

        // Check if any process in the group is running before sending signals
        guard isProcessRunning(pid) else { return }

        kill(-pgid, SIGTERM)
        usleep(AppConstants.processGroupGracePeriodMicroseconds)

        // Only send SIGKILL if process group still has running processes
        if isProcessRunning(pid) {
            kill(-pgid, SIGKILL)
        }
    }

    /// Gracefully terminate a process tree (process + all children + process group)
    /// Consolidates termination logic to avoid duplicate signals by checking if process is still running
    /// - Parameters:
    ///   - pid: The process ID to terminate
    ///   - gracePeriod: Microseconds to wait between SIGTERM and SIGKILL
    static func terminateProcessTree(_ pid: pid_t, gracePeriod: UInt32 = AppConstants.gracefulExitPeriodMicroseconds) {
        guard pid > 0 else { return }

        // 1. Kill children first
        terminateChildren(pid)

        // 2. Try process group (only if main process still running)
        if isProcessRunning(pid) {
            terminateProcessGroup(pid)
        }

        // 3. Terminate the main process (only if still running after group termination)
        guard isProcessRunning(pid) else { return }

        kill(pid, SIGTERM)
        usleep(gracePeriod)

        // Only send SIGKILL if process is still running after grace period
        if isProcessRunning(pid) {
            kill(pid, SIGKILL)
        }
    }

    /// Stop a running Process and all its children
    /// Handles graceful shutdown with exit command, then forced termination
    /// - Parameters:
    ///   - process: The Process to stop
    ///   - stdinPipe: Optional stdin pipe to send exit command
    ///   - exitCommand: JSON exit command to send (default: {"command":"exit"})
    ///   - timeout: Maximum time to wait for process to exit (default: 5 seconds)
    static func stopProcess(_ process: Process, stdinPipe: Pipe?, exitCommand: String = "{\"command\":\"exit\"}\n", timeout: TimeInterval = 5.0) {
        guard process.isRunning else { return }
        let pid = process.processIdentifier

        // Try graceful exit first
        if let stdin = stdinPipe?.fileHandleForWriting {
            try? stdin.write(contentsOf: Data(exitCommand.utf8))
        }

        // Grace period for graceful exit
        usleep(AppConstants.gracefulExitPeriodMicroseconds)

        if process.isRunning {
            terminateChildren(pid)
            terminateProcessGroup(pid)
            process.terminate()
        }

        // Non-blocking wait with timeout to avoid deadlocks
        // Move waitUntilExit to a background thread with timeout protection
        let semaphore = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .utility).async {
            process.waitUntilExit()
            semaphore.signal()
        }

        let result = semaphore.wait(timeout: .now() + timeout)
        if result == .timedOut {
            // Force kill if waitUntilExit times out
            kill(pid, SIGKILL)
        }
    }
}
