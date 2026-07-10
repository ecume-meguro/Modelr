import XCTest
// The deterministic core (Sources/Core) compiles directly into this test bundle,
// so its types are same-module — no @testable import needed and no app launch.

// MARK: - state fixtures

extension AppState {
    /// A booted, ready state with the given models installed.
    static func ready(installed: Set<ModelID> = Set(ModelID.allCases)) -> AppState {
        var state = AppState()
        _ = AppReducer.reduce(&state, .bootScanned(
            legacyLayoutDetected: false,
            report: BootReport(installed: installed, resumable: [:], onboardingComplete: true)))
        return state
    }
}

// MARK: - shape job walker

/// Drives one project's shape job through the §4.4 machine, asserting the
/// expected state at each hop so call sites stay terse.
struct ShapeWalker {
    var state: AppState
    let project = UUID()

    init(installed: Set<ModelID> = Set(ModelID.allCases)) {
        state = .ready(installed: installed)
    }

    var token: UInt64 { state.shape[project]?.token ?? 0 }
    var key: JobKey { JobKey(kind: .shape, project: project, token: token) }
    var jobState: ShapeJobState { state.shapeState(project) }

    @discardableResult
    mutating func send(_ event: AppEvent) -> [AppEffect] {
        AppReducer.reduce(&state, event)
    }

    @discardableResult
    mutating func toPreparing(model: ModelID = .shapeSmall,
                              file: StaticString = #filePath, line: UInt = #line) -> [AppEffect] {
        let effects = send(.shapeGenerateRequested(project: project, model: model))
        XCTAssertEqual(jobState, .preparing, file: file, line: line)
        return effects
    }

    @discardableResult
    mutating func toWaiting(file: StaticString = #filePath, line: UInt = #line) -> [AppEffect] {
        toPreparing(file: file, line: line)
        let effects = send(.shapeStaged(project: project, token: token, error: nil))
        XCTAssertEqual(jobState, .waitingForEngine, file: file, line: line)
        return effects
    }

    @discardableResult
    mutating func toLoading(file: StaticString = #filePath, line: UInt = #line) -> [AppEffect] {
        toWaiting(file: file, line: line)
        let effects = send(.engineGranted(key))
        XCTAssertEqual(jobState, .loadingModel, file: file, line: line)
        return effects
    }

    mutating func to(_ stage: ShapeStage, file: StaticString = #filePath, line: UInt = #line) {
        toLoading(file: file, line: line)
        send(.shapeEngineStage(project: project, token: token, stage: stage, fraction: 0.5))
    }
}

// MARK: - paint job walker

struct PaintWalker {
    var state: AppState
    let project = UUID()

    init(installed: Set<ModelID> = Set(ModelID.allCases)) {
        state = .ready(installed: installed)
    }

    var token: UInt64 { state.paint[project]?.token ?? 0 }
    var key: JobKey { JobKey(kind: .paint, project: project, token: token) }
    var jobState: PaintJobState { state.paintState(project) }

    @discardableResult
    mutating func send(_ event: AppEvent) -> [AppEffect] {
        AppReducer.reduce(&state, event)
    }

    @discardableResult
    mutating func toPreparing(model: ModelID = .paintSmall,
                              file: StaticString = #filePath, line: UInt = #line) -> [AppEffect] {
        let effects = send(.paintRequested(project: project, model: model))
        XCTAssertEqual(jobState, .preparing, file: file, line: line)
        return effects
    }

    @discardableResult
    mutating func toUnwrapping(file: StaticString = #filePath, line: UInt = #line) -> [AppEffect] {
        toPreparing(file: file, line: line)
        let effects = send(.paintStaged(project: project, token: token, error: nil))
        XCTAssertEqual(jobState, .unwrapping, file: file, line: line)
        return effects
    }

    @discardableResult
    mutating func toWaiting(file: StaticString = #filePath, line: UInt = #line) -> [AppEffect] {
        toUnwrapping(file: file, line: line)
        let effects = send(.paintUnwrapFinished(project: project, token: token, error: nil))
        XCTAssertEqual(jobState, .waitingForEngine, file: file, line: line)
        return effects
    }

    @discardableResult
    mutating func toLoading(file: StaticString = #filePath, line: UInt = #line) -> [AppEffect] {
        toWaiting(file: file, line: line)
        let effects = send(.engineGranted(key))
        XCTAssertEqual(jobState, .loadingModel, file: file, line: line)
        return effects
    }

    mutating func to(_ stage: PaintStage, file: StaticString = #filePath, line: UInt = #line) {
        toLoading(file: file, line: line)
        send(.paintEngineStage(project: project, token: token, stage: stage, fraction: 0.5))
    }
}

// MARK: - async event collection (DownloadManager integration)

/// Thread-safe AppEvent collector with a polling wait, for callback-driven
/// subsystems under test.
final class EventSink: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [AppEvent] = []

    func append(_ event: AppEvent) {
        lock.lock(); storage.append(event); lock.unlock()
    }

    var all: [AppEvent] {
        lock.lock(); defer { lock.unlock() }
        return storage
    }

    /// Poll until the predicate matches (or time out). Returns the final match.
    @discardableResult
    func wait(timeout: TimeInterval = 15,
              _ predicate: @escaping ([AppEvent]) -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if predicate(all) { return true }
            Thread.sleep(forTimeInterval: 0.02)
        }
        return predicate(all)
    }
}
