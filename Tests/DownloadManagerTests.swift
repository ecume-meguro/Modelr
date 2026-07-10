import XCTest
import CryptoKit

/// DownloadManager integration against the in-process loopback HTTP server:
/// full installs, kill/resume mid-file (HTTP Range), hash mismatch, disk-full,
/// Range-ignoring servers, pre-existing-file verification, and folder import.
final class DownloadManagerTests: XCTestCase {
    private var server: TestHTTPServer!
    private var root: URL!
    private var sink: EventSink!

    override func setUpWithError() throws {
        server = try TestHTTPServer()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("modelr-dl-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        sink = EventSink()
    }

    override func tearDownWithError() throws {
        server.stop()
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: fixtures

    /// Deterministic pseudo-random payload (seeded LCG — stable across runs).
    private func payload(_ size: Int, seed: UInt64) -> Data {
        var state = seed
        var data = Data(capacity: size)
        for _ in 0..<size {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            data.append(UInt8(truncatingIfNeeded: state >> 33))
        }
        return data
    }

    private func sha(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Register payloads with the server and build a matching catalog.
    private func catalog(files: [(path: String, data: Data)],
                         corrupt corruptPaths: Set<String> = []) -> CatalogModel {
        var catalogFiles: [CatalogFile] = []
        for (path, data) in files {
            server.serve(path, data)
            // A "corrupt" entry: the server payload doesn't match the pinned hash.
            let digest = corruptPaths.contains(path) ? sha(data + Data([0xFF])) : sha(data)
            catalogFiles.append(CatalogFile(path: path, bytes: Int64(data.count), sha256: digest))
        }
        return CatalogModel(id: .shapeSmall, displayName: "Test", detail: "",
                            repo: "test/test", revision: nil, files: catalogFiles)
    }

    private func makeManager(_ cat: CatalogModel,
                             makeSink: (@Sendable (URL) throws -> DownloadSink)? = nil)
    -> DownloadManager {
        var config = DownloadManager.Configuration(rootDir: root)
        config.catalog = { _ in cat }
        config.remoteURL = { [server] _, file in server!.url(for: file.path) }
        config.progressByteInterval = 1024
        config.session = URLSession(configuration: .ephemeral)
        if let makeSink { config.makeSink = makeSink }
        return DownloadManager(configuration: config) { [sink] event in sink!.append(event) }
    }

    private func fileURL(_ path: String) -> URL {
        root.appendingPathComponent("shape-small").appendingPathComponent(path)
    }

    private func fileSize(_ url: URL) -> Int64? {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? nil
    }

    // MARK: full download + verify

    func testSequentialDownloadThenVerifyInstalls() throws {
        let a = payload(96 * 1024, seed: 1)
        let b = payload(20 * 1024, seed: 2)
        let cat = catalog(files: [("config.yaml", b), ("model.fp16.safetensors", a)])
        let manager = makeManager(cat)

        manager.start(.shapeSmall, attempt: 1)
        XCTAssertTrue(sink.wait { $0.contains(.downloadCompleted(.shapeSmall, attempt: 1)) },
                      "download should complete: \(sink.all)")

        // Both files landed at final names with exact sizes; no partials remain.
        XCTAssertEqual(fileSize(fileURL("config.yaml")), Int64(b.count))
        XCTAssertEqual(fileSize(fileURL("model.fp16.safetensors")), Int64(a.count))
        XCTAssertNil(fileSize(fileURL("config.yaml.partial")))
        XCTAssertNil(fileSize(fileURL("model.fp16.safetensors.partial")))
        XCTAssertTrue(manager.isInstalledOnDisk(.shapeSmall))

        // Progress covered both files in order, with sane byte accounting.
        let progresses: [DownloadProgress] = sink.all.compactMap {
            if case .downloadProgressed(_, 1, let p) = $0 { return p } else { return nil }
        }
        XCTAssertTrue(progresses.contains { $0.fileIndex == 1 })
        XCTAssertTrue(progresses.contains { $0.fileIndex == 2 })
        XCTAssertEqual(progresses.last?.totalBytes, cat.totalBytes)

        manager.verify(.shapeSmall, attempt: 1)
        XCTAssertTrue(sink.wait { $0.contains(.verifyFinished(.shapeSmall, attempt: 1, error: nil)) },
                      "verify should pass: \(sink.all)")
    }

    // MARK: kill / resume mid-file (HTTP Range)

    func testConnectionLossMidFileResumesFromByteOffset() throws {
        let data = payload(200 * 1024, seed: 3)
        let cat = catalog(files: [("model.fp16.safetensors", data)])
        server.truncate("model.fp16.safetensors", afterBodyBytes: 80_000)

        let manager = makeManager(cat)
        manager.start(.shapeSmall, attempt: 1)
        XCTAssertTrue(sink.wait { events in
            events.contains { if case .downloadFailed(.shapeSmall, 1, _) = $0 { return true }; return false }
        }, "truncated body should fail the attempt: \(sink.all)")

        // The partial survives with the bytes that made it through (network
        // buffering can shave the tail, but something real must be on disk).
        let partial = fileURL("model.fp16.safetensors.partial")
        let partialBytes = try XCTUnwrap(fileSize(partial))
        XCTAssertGreaterThan(partialBytes, 0)
        XCTAssertLessThan(partialBytes, Int64(data.count))

        // Retry resumes with a Range header from the partial's byte count and
        // the streamed hash still checks out end-to-end.
        server.clearTruncation("model.fp16.safetensors")
        manager.start(.shapeSmall, attempt: 2)
        XCTAssertTrue(sink.wait { $0.contains(.downloadCompleted(.shapeSmall, attempt: 2)) },
                      "resume should complete: \(sink.all)")
        XCTAssertEqual(server.requests.last,
                       TestHTTPServer.Request(path: "model.fp16.safetensors",
                                              rangeStart: partialBytes))
        XCTAssertEqual(fileSize(fileURL("model.fp16.safetensors")), Int64(data.count))
        XCTAssertNil(fileSize(partial))

        manager.verify(.shapeSmall, attempt: 2)
        XCTAssertTrue(sink.wait { $0.contains(.verifyFinished(.shapeSmall, attempt: 2, error: nil)) })
    }

    func testRelaunchResumesFromPartialWithAFreshManager() throws {
        let data = payload(150 * 1024, seed: 4)
        let cat = catalog(files: [("model.fp16.safetensors", data)])
        server.truncate("model.fp16.safetensors", afterBodyBytes: 60_000)

        // "First launch" dies mid-file.
        let first = makeManager(cat)
        first.start(.shapeSmall, attempt: 1)
        XCTAssertTrue(sink.wait { events in
            events.contains { if case .downloadFailed = $0 { return true }; return false }
        })
        let kept = first.resumableBytes(for: .shapeSmall)
        XCTAssertGreaterThan(kept, 0)
        XCTAssertLessThan(kept, Int64(data.count))

        // "Relaunch": a brand-new manager (empty session state) resumes from the
        // partial — the already-present prefix is re-hashed, then Range continues.
        server.clearTruncation("model.fp16.safetensors")
        let second = makeManager(cat)
        XCTAssertTrue(second.hasPartialData(for: .shapeSmall))
        second.start(.shapeSmall, attempt: 2)
        XCTAssertTrue(sink.wait { $0.contains(.downloadCompleted(.shapeSmall, attempt: 2)) })
        XCTAssertEqual(server.requests.last?.rangeStart, kept)

        second.verify(.shapeSmall, attempt: 2)
        XCTAssertTrue(sink.wait { $0.contains(.verifyFinished(.shapeSmall, attempt: 2, error: nil)) })
    }

    // MARK: pause

    func testPauseSilentlyKeepsThePartial() throws {
        let data = payload(120 * 1024, seed: 5)
        let cat = catalog(files: [("model.fp16.safetensors", data)])
        server.chunkDelay = 1.0                            // window to pause mid-body

        let manager = makeManager(cat)
        manager.start(.shapeSmall, attempt: 1)
        XCTAssertTrue(sink.wait { events in
            events.contains {
                if case .downloadProgressed(_, 1, let p) = $0 { return p.fileBytes > 0 }
                return false
            }
        }, "should see first-chunk progress")
        manager.pause(.shapeSmall)

        Thread.sleep(forTimeInterval: 1.5)                 // let any stray events land
        let terminal = sink.all.filter {
            switch $0 {
            case .downloadCompleted, .downloadFailed: return true
            default: return false
            }
        }
        XCTAssertTrue(terminal.isEmpty, "pause must be silent, got \(terminal)")
        XCTAssertNotNil(fileSize(fileURL("model.fp16.safetensors.partial")),
                        "partial bytes must survive a pause")
    }

    // MARK: hash mismatch (§4.3 Verifying → Failed, partial deleted)

    func testHashMismatchDeletesBytesAndFails() throws {
        let data = payload(64 * 1024, seed: 6)
        let cat = catalog(files: [("model.fp16.safetensors", data)],
                          corrupt: ["model.fp16.safetensors"])
        let manager = makeManager(cat)
        manager.start(.shapeSmall, attempt: 1)

        XCTAssertTrue(sink.wait { events in
            events.contains {
                if case .downloadFailed(.shapeSmall, 1, let message) = $0 {
                    return message.contains("checksum")
                }
                return false
            }
        }, "expected checksum failure: \(sink.all)")
        XCTAssertNil(fileSize(fileURL("model.fp16.safetensors")))
        XCTAssertNil(fileSize(fileURL("model.fp16.safetensors.partial")),
                     "mismatched bytes must be deleted (§4.3)")
    }

    // MARK: disk full

    func testDiskFullSurfacesAsFailureAndKeepsPartial() throws {
        let data = payload(64 * 1024, seed: 7)
        let cat = catalog(files: [("model.fp16.safetensors", data)])
        let quota: Int64 = 8 * 1024
        let manager = makeManager(cat) { url in
            try QuotaSink(url: url, quota: quota)
        }
        manager.start(.shapeSmall, attempt: 1)
        XCTAssertTrue(sink.wait { events in
            events.contains { if case .downloadFailed(.shapeSmall, 1, _) = $0 { return true }; return false }
        }, "quota breach should fail the attempt: \(sink.all)")
        let partialSize = fileSize(fileURL("model.fp16.safetensors.partial")) ?? 0
        XCTAssertLessThanOrEqual(partialSize, quota)
    }

    // MARK: server ignores Range

    func testRangeIgnoringServerRestartsFromZero() throws {
        let data = payload(90 * 1024, seed: 8)
        let cat = catalog(files: [("model.fp16.safetensors", data)])

        // Seed a half-finished partial, then point at a server that always 200s.
        let partial = fileURL("model.fp16.safetensors.partial")
        try FileManager.default.createDirectory(at: partial.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try data.prefix(30_000).write(to: partial)
        server.ignoreRange = true

        let manager = makeManager(cat)
        manager.start(.shapeSmall, attempt: 1)
        XCTAssertTrue(sink.wait { $0.contains(.downloadCompleted(.shapeSmall, attempt: 1)) },
                      "restart-from-zero should still complete: \(sink.all)")
        XCTAssertEqual(server.requests.first?.rangeStart, 30_000, "client asked to resume")
        XCTAssertEqual(fileSize(fileURL("model.fp16.safetensors")), Int64(data.count))

        manager.verify(.shapeSmall, attempt: 1)
        XCTAssertTrue(sink.wait { $0.contains(.verifyFinished(.shapeSmall, attempt: 1, error: nil)) },
                      "hash must be seeded from zero after a 200 restart")
    }

    // MARK: verify of files not downloaded this session

    func testVerifyHashesPreexistingFilesAndDeletesCorruption() throws {
        let good = payload(32 * 1024, seed: 9)
        var bad = payload(32 * 1024, seed: 10)
        let cat = catalog(files: [("config.yaml", good), ("model.fp16.safetensors", bad)])

        // Place both files manually (e.g. migrated) — same sizes, one corrupted.
        bad[100] ^= 0xFF
        for (path, data) in [("config.yaml", good), ("model.fp16.safetensors", bad)] {
            let url = fileURL(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try data.write(to: url)
        }

        let manager = makeManager(cat)
        manager.verify(.shapeSmall, attempt: 1)
        XCTAssertTrue(sink.wait { events in
            events.contains {
                if case .verifyFinished(.shapeSmall, 1, let error) = $0 {
                    return error?.contains("checksum") == true
                }
                return false
            }
        }, "expected checksum verify failure: \(sink.all)")
        XCTAssertNil(fileSize(fileURL("model.fp16.safetensors")), "corrupt file deleted")
        XCTAssertNotNil(fileSize(fileURL("config.yaml")), "good file kept")
    }

    // MARK: import weights folder

    func testImportCopiesAValidFolder() throws {
        let a = payload(24 * 1024, seed: 11)
        let b = payload(4 * 1024, seed: 12)
        let cat = catalog(files: [("config.yaml", b), ("model.fp16.safetensors", a)])

        let source = root.appendingPathComponent("import-src", isDirectory: true)
        for (path, data) in [("config.yaml", b), ("model.fp16.safetensors", a)] {
            let url = source.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try data.write(to: url)
        }

        let manager = makeManager(cat)
        manager.importWeights(for: .shapeSmall, from: source)
        XCTAssertTrue(sink.wait { $0.contains(.importWeightsFinished(.shapeSmall, error: nil)) },
                      "import should succeed: \(sink.all)")
        XCTAssertTrue(manager.isInstalledOnDisk(.shapeSmall))
    }

    func testImportRejectsWrongSizes() throws {
        let a = payload(24 * 1024, seed: 13)
        let cat = catalog(files: [("model.fp16.safetensors", a)])

        let source = root.appendingPathComponent("import-bad", isDirectory: true)
        let url = source.appendingPathComponent("model.fp16.safetensors")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try a.prefix(100).write(to: url)                   // wrong size

        let manager = makeManager(cat)
        manager.importWeights(for: .shapeSmall, from: source)
        XCTAssertTrue(sink.wait { events in
            events.contains {
                if case .importWeightsFinished(.shapeSmall, let error) = $0 {
                    return error?.contains("wrong size") == true
                }
                return false
            }
        }, "expected size rejection: \(sink.all)")
        XCTAssertFalse(manager.isInstalledOnDisk(.shapeSmall))
    }
}

/// Byte sink that simulates ENOSPC after a quota — deterministic disk-full.
private final class QuotaSink: DownloadSink, @unchecked Sendable {
    private let inner: FileSink
    private let quota: Int64
    private var written: Int64 = 0

    init(url: URL, quota: Int64) throws {
        inner = try FileSink(url: url)
        self.quota = quota
    }

    func write(_ data: Data) throws {
        if written + Int64(data.count) > quota {
            throw POSIXError(.ENOSPC)
        }
        try inner.write(data)
        written += Int64(data.count)
    }

    func finalize() throws {
        try inner.finalize()
    }
}
