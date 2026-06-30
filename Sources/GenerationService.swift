import Foundation
import Darwin
import os

/// Runs the Hunyuan3D-Shape-MLX pipeline as an out-of-process worker and streams
/// progress back. The python interpreter is exec'd directly (no shell) via a tiny
/// launcher that self-terminates if the app dies — so a crash can't orphan it.
final class GenerationService {

    enum Outcome {
        case success
        case failure(String)
    }

    /// Handle to one running generation. Cancelling escalates SIGTERM → SIGKILL.
    final class Job {
        private let process: Process
        private let interpreter: URL
        private let cancelledFlag = OSAllocatedUnfairLock(initialState: false)

        /// Thread-safe: written from the main actor (cancel), read from the
        /// background termination handler.
        var cancelled: Bool { cancelledFlag.withLock { $0 } }

        init(_ process: Process, interpreter: URL = PipelineConfig.pythonExecutable) {
            self.process = process
            self.interpreter = interpreter
        }

        func cancel() {
            cancelledFlag.withLock { $0 = true }
            guard process.isRunning else { return }
            process.terminate() // SIGTERM
            let p = process
            let expected = interpreter.resolvingSymlinksInPath().path
            DispatchQueue.global().asyncAfter(deadline: .now() + 8) {
                guard p.isRunning, p.processIdentifier > 1 else { return }
                let pid = p.processIdentifier
                // Re-confirm this is still our worker before a raw SIGKILL, so a
                // reaped+reused PID can't make us signal an innocent process.
                var buf = [CChar](repeating: 0, count: 4096)
                guard proc_pidpath(pid, &buf, UInt32(buf.count)) > 0 else { return }
                let running = URL(fileURLWithPath: String(cString: buf)).resolvingSymlinksInPath().path
                guard running == expected else { return }
                kill(pid, SIGKILL)
            }
        }
    }

    /// Launch a generation. Callbacks may arrive on a background queue; the caller
    /// is responsible for hopping to the main actor.
    @discardableResult
    func run(image: URL,
             output: URL,
             weights: URL,
             quantize: Int,
             steps: Int,
             guidance: Double,
             octree: Int,
             onProgress: @escaping (String, String?, Double?) -> Void,
             onPreview: @escaping (URL) -> Void,
             onPoints: @escaping (URL) -> Void,
             onFinish: @escaping (Outcome) -> Void) -> Job {

        let worker: URL
        do {
            worker = try Self.ensureWorkerScript()
        } catch {
            onFinish(.failure("Couldn't prepare the worker: \(error.localizedDescription)"))
            return Job(Process())
        }

        let proc = Process()
        proc.executableURL = PipelineConfig.pythonExecutable
        proc.currentDirectoryURL = PipelineConfig.repoRoot
        proc.arguments = [
            "-u", worker.path,
            image.path,
            "--weights", weights.path,
            "--out", output.path,
            "--steps", "\(steps)",
            "--guidance", "\(guidance)",
            "--octree", "\(octree)",
            "--dtype", PipelineConfig.dtype,
            "--quantize", "\(quantize)",
        ]
        var env = ProcessInfo.processInfo.environment
        env["PYTHONUNBUFFERED"] = "1"
        env["PYTHONPATH"] = PipelineConfig.repoRoot.path
        proc.environment = env

        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe

        let job = Job(proc)
        let errLock = NSLock()
        var errTail = ""
        var pending = ""   // carries an incomplete trailing line across reads

        outPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty, let chunk = String(data: data, encoding: .utf8) else { return }
            let combined = pending + chunk
            let trailingNewline = combined.last == "\n" || combined.last == "\r"
            var lines = combined.split(omittingEmptySubsequences: false,
                                       whereSeparator: { $0 == "\n" || $0 == "\r" }).map(String.init)
            pending = trailingNewline ? "" : (lines.popLast() ?? "")
            for raw in lines {
                let l = raw.trimmingCharacters(in: .whitespaces)
                if l.hasPrefix("[preview] ") {
                    let path = String(l.dropFirst("[preview] ".count))
                    if !path.isEmpty { onPreview(URL(fileURLWithPath: path)) }
                } else if l.hasPrefix("[points] ") {
                    let path = String(l.dropFirst("[points] ".count))
                    if !path.isEmpty { onPoints(URL(fileURLWithPath: path)) }
                }
            }
            if let p = Self.humanProgress(from: lines.joined(separator: "\n")) {
                onProgress(p.stage, p.detail, p.fraction)
            }
        }
        errPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty, let s = String(data: data, encoding: .utf8) else { return }
            errLock.lock(); errTail = String((errTail + s).suffix(4000)); errLock.unlock()
        }

        proc.terminationHandler = { p in
            outPipe.fileHandleForReading.readabilityHandler = nil
            errPipe.fileHandleForReading.readabilityHandler = nil
            JobReaper.unregister(p.processIdentifier)

            // Flush a final marker line that arrived without a trailing newline.
            let pendingTail = pending.trimmingCharacters(in: .whitespaces)
            if pendingTail.hasPrefix("[preview] ") {
                let path = String(pendingTail.dropFirst("[preview] ".count))
                if !path.isEmpty { onPreview(URL(fileURLWithPath: path)) }
            } else if pendingTail.hasPrefix("[points] ") {
                let path = String(pendingTail.dropFirst("[points] ".count))
                if !path.isEmpty { onPoints(URL(fileURLWithPath: path)) }
            }

            func closeHandles() {
                try? outPipe.fileHandleForReading.close()
                try? errPipe.fileHandleForReading.close()
            }

            if job.cancelled {
                closeHandles()
                onFinish(.failure("Cancelled"))
                return
            }

            let produced = FileManager.default.fileExists(atPath: output.path)
            if p.terminationStatus == 0 && produced {
                closeHandles()
                onFinish(.success)
                return
            }

            // Failure: drain any stderr the handler hadn't delivered yet (the child
            // has exited, so this returns at EOF without blocking).
            let rest = errPipe.fileHandleForReading.readDataToEndOfFile()
            if let s = String(data: rest, encoding: .utf8), !s.isEmpty {
                errLock.lock(); errTail = String((errTail + s).suffix(4000)); errLock.unlock()
            }
            closeHandles()
            errLock.lock(); let tail = errTail; errLock.unlock()
            let msg = tail.trimmingCharacters(in: .whitespacesAndNewlines)
            onFinish(.failure(msg.isEmpty
                ? "Generation failed (exit \(p.terminationStatus))"
                : Self.lastLine(of: msg)))
        }

        do {
            try proc.run()
            JobReaper.register(proc.processIdentifier)
        } catch {
            onFinish(.failure("Couldn't launch the model: \(error.localizedDescription)"))
        }
        return job
    }

    // MARK: - paint (texture)

    /// Launch the paint pipeline: mesh + image -> textured mesh. Streams a 6-view grid
    /// (`onViews`) as the multiview diffusion refines.
    @discardableResult
    func paint(mesh: URL, image: URL, output: URL, weights: URL,
               res: Int, steps: Int, tex: Int, superres: Bool, faces: Int,
               onProgress: @escaping (String, Double?) -> Void,
               onViews: @escaping (URL) -> Void,
               onFinish: @escaping (Outcome) -> Void) -> Job {
        let worker: URL
        do { worker = try Self.ensurePaintWorkerScript() }
        catch {
            onFinish(.failure("Couldn't prepare the paint worker: \(error.localizedDescription)"))
            return Job(Process(), interpreter: PaintConfig.pythonExecutable)
        }

        let proc = Process()
        proc.executableURL = PaintConfig.pythonExecutable
        proc.currentDirectoryURL = PaintConfig.repoRoot
        proc.arguments = [
            "-u", worker.path, mesh.path, image.path,
            "--out", output.path, "--repo", PaintConfig.repoRoot.path, "--weights", weights.path,
            "--res", "\(res)", "--steps", "\(steps)", "--tex", "\(tex)",
            "--superres", superres ? "1" : "0", "--faces", "\(faces)",
        ]
        var env = ProcessInfo.processInfo.environment
        env["PYTHONUNBUFFERED"] = "1"
        env["PYTHONPATH"] = PaintConfig.repoRoot.path
        proc.environment = env

        let outPipe = Pipe(); let errPipe = Pipe()
        proc.standardOutput = outPipe; proc.standardError = errPipe
        let job = Job(proc, interpreter: PaintConfig.pythonExecutable)
        let errLock = NSLock(); var errTail = ""
        var pending = ""

        outPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty, let chunk = String(data: data, encoding: .utf8) else { return }
            let combined = pending + chunk
            let trailingNewline = combined.last == "\n" || combined.last == "\r"
            var lines = combined.split(omittingEmptySubsequences: false,
                                       whereSeparator: { $0 == "\n" || $0 == "\r" }).map(String.init)
            pending = trailingNewline ? "" : (lines.popLast() ?? "")
            for raw in lines {
                let l = raw.trimmingCharacters(in: .whitespaces)
                if l.hasPrefix("[views] ") {
                    let path = String(l.dropFirst("[views] ".count))
                    if !path.isEmpty { onViews(URL(fileURLWithPath: path)) }
                }
            }
            if let p = Self.paintProgress(from: lines.joined(separator: "\n"), steps: steps) {
                onProgress(p.0, p.1)
            }
        }
        errPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty, let s = String(data: data, encoding: .utf8) else { return }
            errLock.lock(); errTail = String((errTail + s).suffix(4000)); errLock.unlock()
        }

        proc.terminationHandler = { p in
            outPipe.fileHandleForReading.readabilityHandler = nil
            errPipe.fileHandleForReading.readabilityHandler = nil
            JobReaper.unregister(p.processIdentifier)
            // Flush a final [views] line that arrived without a trailing newline.
            let pendingTail = pending.trimmingCharacters(in: .whitespaces)
            if pendingTail.hasPrefix("[views] ") {
                let path = String(pendingTail.dropFirst("[views] ".count))
                if !path.isEmpty { onViews(URL(fileURLWithPath: path)) }
            }
            func closeHandles() {
                try? outPipe.fileHandleForReading.close(); try? errPipe.fileHandleForReading.close()
            }
            if job.cancelled { closeHandles(); onFinish(.failure("Cancelled")); return }
            if p.terminationStatus == 0 && FileManager.default.fileExists(atPath: output.path) {
                closeHandles(); onFinish(.success); return
            }
            let rest = errPipe.fileHandleForReading.readDataToEndOfFile()
            if let s = String(data: rest, encoding: .utf8), !s.isEmpty {
                errLock.lock(); errTail = String((errTail + s).suffix(4000)); errLock.unlock()
            }
            closeHandles()
            errLock.lock(); let tail = errTail; errLock.unlock()
            let msg = tail.trimmingCharacters(in: .whitespacesAndNewlines)
            onFinish(.failure(msg.isEmpty ? "Paint failed (exit \(p.terminationStatus))" : Self.lastLine(of: msg)))
        }

        do { try proc.run(); JobReaper.register(proc.processIdentifier) }
        catch { onFinish(.failure("Couldn't launch paint: \(error.localizedDescription)")) }
        return job
    }

    private static func paintProgress(from chunk: String, steps: Int) -> (String, Double?)? {
        var result: (String, Double?)?
        for raw in chunk.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
            let l = raw.trimmingCharacters(in: .whitespaces)
            if l.hasPrefix("stage: ") {
                switch String(l.dropFirst("stage: ".count)) {
                case "loading models":  result = ("Loading paint model…", nil)
                case "preparing mesh":  result = ("Preparing mesh…", nil)
                case "controls encoded": result = ("Rendering views…", nil)
                case "baking texture":  result = ("Baking texture…", nil)
                default:                result = ("Painting…", nil)
                }
            } else if l.hasPrefix("step "),
                      let i = Int(l.dropFirst("step ".count).split(separator: "/").first ?? "") {
                result = ("Generating views…", Double(i) / Double(max(steps, 1)))
            }
        }
        return result
    }

    /// The paint worker is self-contained (own parent-death watchdog).
    private static func ensurePaintWorkerScript() throws -> URL {
        let dir = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Modelr", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("modelr_paint_worker.py")
        try WorkerScripts.paint.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    // MARK: - worker launcher

    /// Writes (once) a small launcher that runs the pipeline but first installs a
    /// parent-death watchdog. macOS has no PR_SET_PDEATHSIG, so the worker watches
    /// its own parent and exits if it gets reparented to launchd (pid 1) — i.e. the
    /// app died by any cause, including a crash or force-quit. This frees the GPU.
    private static func ensureWorkerScript() throws -> URL {
        let dir = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Modelr", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("modelr_worker.py")

        let script = WorkerScripts.shape

        let existing = try? String(contentsOf: url, encoding: .utf8)
        if existing != script {
            try script.write(to: url, atomically: true, encoding: .utf8)
        }
        return url
    }

    // MARK: - stdout parsing

    /// Turn the pipeline's stdout chunks into a stage label (for the sidebar) and,
    /// when measurable, a 0…1 fraction (for the progress bar). nil = no update.
    private static func humanProgress(from chunk: String) -> (stage: String, detail: String?, fraction: Double?)? {
        let pieces = chunk
            .split(whereSeparator: { $0 == "\r" || $0 == "\n" })
            .map { $0.trimmingCharacters(in: .whitespaces) }
        for piece in pieces.reversed() where !piece.isEmpty {
            if piece.hasPrefix("[denoise]") {
                if piece.contains("steps in") { return ("Building surface…", nil, nil) }
                if let f = stepFraction(in: piece) {
                    return ("Generating shape…", f.label, f.value)
                }
                return ("Generating shape…", nil, nil)
            }
            if piece.hasPrefix("[grid]") { return ("Building surface…", nil, nil) }
            if piece.hasPrefix("[dino]") { return ("Encoding image…", nil, nil) }
            if piece.hasPrefix("[vae]")  { return ("Building surface…", nil, nil) }
            if piece.hasPrefix("[mesh]") { return ("Extracting mesh…", nil, nil) }
            if piece.hasPrefix("wrote")  { return ("Finishing up…", nil, nil) }
        }
        return nil
    }

    /// Extracts an "i/n" token like "12/30" → (label: "12/30", value: 0.4).
    private static func stepFraction(in piece: String) -> (label: String, value: Double)? {
        guard let token = piece.split(separator: " ").first(where: { $0.contains("/") }) else { return nil }
        let parts = token.split(separator: "/")
        guard parts.count == 2, let i = Double(parts[0]), let n = Double(parts[1]), n > 0 else { return nil }
        return (String(token), max(0, min(1, i / n)))
    }

    private static func lastLine(of text: String) -> String {
        text.split(whereSeparator: \.isNewline).last.map(String.init) ?? text
    }

}
