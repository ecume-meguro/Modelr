import Foundation
import Darwin

/// Tracks the PIDs of model worker processes we spawn so they never become
/// orphaned GPU processes:
///  - `register`/`unregister` maintain a small on-disk PID file (race-safe)
///  - `killAll` is the fast path on normal app termination
///  - `sweepStale` runs at launch and kills any worker left behind by a crash,
///    verified to actually be *our* python (resolving symlinks) before signalling
enum JobReaper {
    private static let q = DispatchQueue(label: "com.zimeng.Modelr.jobreaper")

    /// PIDs whose termination was observed *before* their registration landed.
    /// Only ever touched inside `q`.
    private static var reaped = Set<Int>()

    private static var fileURL: URL {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Modelr", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("running-pids.json")
    }

    /// Resolved real paths of BOTH worker interpreters (shape and paint live in
    /// separate venvs). The venv entry is a symlink chain into a uv-managed cpython;
    /// `proc_pidpath` reports the resolved path, so we compare against the resolved set.
    private static let resolvedInterpreters: Set<String> = [
        PipelineConfig.pythonExecutable.resolvingSymlinksInPath().path,
        PaintConfig.pythonExecutable.resolvingSymlinksInPath().path,
    ]

    static func register(_ pid: pid_t) {
        q.sync {
            if reaped.remove(Int(pid)) != nil { return } // already terminated; don't resurrect
            var s = read(); s.insert(Int(pid)); write(s)
        }
    }

    static func unregister(_ pid: pid_t) {
        q.sync {
            var s = read()
            if s.remove(Int(pid)) == nil { reaped.insert(Int(pid)) } // ran before register
            write(s)
        }
    }

    /// Best-effort hard stop of everything we launched (used on quit).
    /// Single shared grace window — never an O(N) per-PID sleep that could
    /// overrun the system's termination deadline.
    static func killAll() {
        q.sync {
            // Only signal pids that still resolve to our interpreter (guards PID reuse).
            let ours = read().map { pid_t($0) }.filter { isOurPython($0) }
            for pid in ours { kill(pid, SIGTERM) }
            if !ours.isEmpty { usleep(250_000) }
            for pid in ours where isOurPython(pid) { kill(pid, SIGKILL) }
            write([])
        }
    }

    /// At launch: kill any worker that survived a previous crash. Only signals
    /// PIDs confirmed to still be our interpreter (guards against PID reuse).
    static func sweepStale() {
        q.sync {
            let ours = read().map { pid_t($0) }.filter { isOurPython($0) }
            for pid in ours { kill(pid, SIGTERM) }
            if !ours.isEmpty { usleep(250_000) }
            for pid in ours where isOurPython(pid) { kill(pid, SIGKILL) }
            // Retain only anything still alive AND still ours, to retry next launch.
            let survivors = Set(read().filter { isOurPython(pid_t($0)) })
            write(survivors)
        }
    }

    // MARK: - identity

    private static func isOurPython(_ pid: pid_t) -> Bool {
        guard pid > 1, kill(pid, 0) == 0 else { return false }
        var buf = [CChar](repeating: 0, count: 4096)
        guard proc_pidpath(pid, &buf, UInt32(buf.count)) > 0 else { return false }
        let running = URL(fileURLWithPath: String(cString: buf)).resolvingSymlinksInPath().path
        return resolvedInterpreters.contains(running)
    }

    // MARK: - persistence

    private static func read() -> Set<Int> {
        guard let d = try? Data(contentsOf: fileURL),
              let a = try? JSONDecoder().decode([Int].self, from: d) else { return [] }
        return Set(a)
    }

    private static func write(_ s: Set<Int>) {
        try? JSONEncoder().encode(Array(s)).write(to: fileURL)
    }
}
