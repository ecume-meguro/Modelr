import XCTest

/// §4.6 engine arbiter — FIFO queueing, app-wide exclusivity, and the handoff
/// bookkeeping the reducer owns (the actor's evict sequencing is runtime-side).
final class ReducerArbiterTests: XCTestCase {

    /// Two projects race for the engine: strict FIFO, one owner at a time.
    func testFIFOAcrossShapeAndPaint() {
        var s = AppState.ready()
        let a = UUID(), b = UUID()

        // Shape A reaches the queue first and is granted immediately.
        _ = AppReducer.reduce(&s, .shapeGenerateRequested(project: a, model: .shapeSmall))
        let aTok = s.shape[a]!.token
        let aKey = JobKey(kind: .shape, project: a, token: aTok)
        var effects = AppReducer.reduce(&s, .shapeStaged(project: a, token: aTok, error: nil))
        XCTAssertEqual(effects, [.grantEngine(aKey)])
        XCTAssertEqual(s.engine.owner, .held(aKey))

        // Paint B queues behind A — no second grant while A holds the engine.
        _ = AppReducer.reduce(&s, .paintRequested(project: b, model: .paintSmall))
        let bTok = s.paint[b]!.token
        let bKey = JobKey(kind: .paint, project: b, token: bTok)
        _ = AppReducer.reduce(&s, .paintStaged(project: b, token: bTok, error: nil))
        effects = AppReducer.reduce(&s, .paintUnwrapFinished(project: b, token: bTok, error: nil))
        XCTAssertEqual(effects, [])
        XCTAssertEqual(s.paintState(b), .waitingForEngine)
        XCTAssertEqual(s.engine.queue, [bKey])
        XCTAssertEqual(s.engine.owner, .held(aKey))

        // A runs and finishes → release hands the engine to B in FIFO order.
        _ = AppReducer.reduce(&s, .engineGranted(aKey))
        effects = AppReducer.reduce(&s, .shapeEngineFinished(project: a, token: aTok, result: .success))
        XCTAssertEqual(effects, [.releaseEngine(aKey), .grantEngine(bKey),
                                 .commitShape(project: a, token: aTok)])
        XCTAssertEqual(s.engine.owner, .held(bKey))

        _ = AppReducer.reduce(&s, .engineGranted(bKey))
        XCTAssertEqual(s.paintState(b), .loadingModel)
    }

    func testThreeWayQueueKeepsOrder() {
        var s = AppState.ready()
        let a = UUID(), b = UUID(), c = UUID()
        var keys: [JobKey] = []

        for (project, isShape) in [(a, true), (b, false), (c, true)] {
            if isShape {
                _ = AppReducer.reduce(&s, .shapeGenerateRequested(project: project, model: .shapeSmall))
                let t = s.shape[project]!.token
                _ = AppReducer.reduce(&s, .shapeStaged(project: project, token: t, error: nil))
                keys.append(JobKey(kind: .shape, project: project, token: t))
            } else {
                _ = AppReducer.reduce(&s, .paintRequested(project: project, model: .paintSmall))
                let t = s.paint[project]!.token
                _ = AppReducer.reduce(&s, .paintStaged(project: project, token: t, error: nil))
                _ = AppReducer.reduce(&s, .paintUnwrapFinished(project: project, token: t, error: nil))
                keys.append(JobKey(kind: .paint, project: project, token: t))
            }
        }
        XCTAssertEqual(s.engine.owner, .held(keys[0]))
        XCTAssertEqual(s.engine.queue, [keys[1], keys[2]])

        // a finishes → b granted; b fails → c granted. Strict FIFO throughout.
        _ = AppReducer.reduce(&s, .engineGranted(keys[0]))
        var effects = AppReducer.reduce(&s, .shapeEngineFinished(project: a, token: keys[0].token, result: .success))
        XCTAssertTrue(effects.contains(.grantEngine(keys[1])))

        _ = AppReducer.reduce(&s, .engineGranted(keys[1]))
        effects = AppReducer.reduce(&s, .paintEngineFinished(project: b, token: keys[1].token,
                                                             result: .failure("x")))
        XCTAssertTrue(effects.contains(.grantEngine(keys[2])))
        XCTAssertEqual(s.engine.owner, .held(keys[2]))
    }

    func testCancelledWaiterIsSkippedByTheGrantChain() {
        var s = AppState.ready()
        let a = UUID(), b = UUID(), c = UUID()

        // a holds; b and c wait.
        _ = AppReducer.reduce(&s, .shapeGenerateRequested(project: a, model: .shapeSmall))
        let aTok = s.shape[a]!.token
        _ = AppReducer.reduce(&s, .shapeStaged(project: a, token: aTok, error: nil))
        let aKey = JobKey(kind: .shape, project: a, token: aTok)
        _ = AppReducer.reduce(&s, .engineGranted(aKey))

        for p in [b, c] {
            _ = AppReducer.reduce(&s, .shapeGenerateRequested(project: p, model: .shapeSmall))
            _ = AppReducer.reduce(&s, .shapeStaged(project: p, token: s.shape[p]!.token, error: nil))
        }
        let cKey = JobKey(kind: .shape, project: c, token: s.shape[c]!.token)

        // b cancels while waiting (dequeued immediately, §4.4).
        _ = AppReducer.reduce(&s, .shapeCancelRequested(project: b))
        XCTAssertEqual(s.shapeState(b), .idle)
        XCTAssertEqual(s.engine.queue, [cKey])

        // a finishes → grant goes straight to c.
        let effects = AppReducer.reduce(&s, .shapeEngineFinished(project: a, token: aTok, result: .success))
        XCTAssertTrue(effects.contains(.grantEngine(cKey)))
    }

    func testStaleGrantIsReturnedAndPassedOn() {
        var s = AppState.ready()
        let a = UUID(), b = UUID()

        _ = AppReducer.reduce(&s, .shapeGenerateRequested(project: a, model: .shapeSmall))
        let aTok = s.shape[a]!.token
        _ = AppReducer.reduce(&s, .shapeStaged(project: a, token: aTok, error: nil))
        let aKey = JobKey(kind: .shape, project: a, token: aTok)

        _ = AppReducer.reduce(&s, .shapeGenerateRequested(project: b, model: .shapeSmall))
        let bTok = s.shape[b]!.token
        _ = AppReducer.reduce(&s, .shapeStaged(project: b, token: bTok, error: nil))
        let bKey = JobKey(kind: .shape, project: b, token: bTok)

        // a cancels while its grant is in flight: ownership moves to b at once…
        _ = AppReducer.reduce(&s, .shapeCancelRequested(project: a))
        XCTAssertEqual(s.engine.owner, .held(bKey))

        // …and a's stale grant, when it lands, is handed back without effect on b.
        let effects = AppReducer.reduce(&s, .engineGranted(aKey))
        XCTAssertEqual(effects, [.releaseEngine(aKey)])
        XCTAssertEqual(s.engine.owner, .held(bKey))

        _ = AppReducer.reduce(&s, .engineGranted(bKey))
        XCTAssertEqual(s.shapeState(b), .loadingModel)
    }

    func testReleaseFromNonOwnerIsInert() {
        var s = AppState.ready()
        let a = UUID()
        _ = AppReducer.reduce(&s, .shapeGenerateRequested(project: a, model: .shapeSmall))
        let tok = s.shape[a]!.token
        _ = AppReducer.reduce(&s, .shapeStaged(project: a, token: tok, error: nil))
        let key = JobKey(kind: .shape, project: a, token: tok)
        _ = AppReducer.reduce(&s, .engineGranted(key))

        // A stale-token finish must not release the engine the live job holds.
        let effects = AppReducer.reduce(&s, .shapeEngineFinished(project: a, token: tok &+ 5,
                                                                 result: .failure("stale")))
        XCTAssertEqual(effects, [])
        XCTAssertEqual(s.engine.owner, .held(key))
    }

    /// The runtime-side arbiter actor: evict-then-grant ordering and residency.
    func testArbiterActorSequencesEvictionBeforeGrant() async {
        actor Log {
            var entries: [String] = []
            func add(_ s: String) { entries.append(s) }
        }
        let log = Log()
        let arbiter = EngineArbiter(evictors: [
            .shape: { await log.add("evict-shape") },
            .paint: { await log.add("evict-paint") },
        ])

        let p = UUID()
        let shapeJob = JobKey(kind: .shape, project: p, token: 1)
        let paintJob = JobKey(kind: .paint, project: p, token: 2)
        let shapeJob2 = JobKey(kind: .shape, project: p, token: 3)

        await arbiter.grant(shapeJob)                     // nothing resident → no evict
        await log.add("granted-shape-1")
        await arbiter.release(shapeJob)

        await arbiter.grant(paintJob)                     // shape resident → evict shape first
        await log.add("granted-paint")
        await arbiter.release(paintJob)

        await arbiter.grant(shapeJob2)                    // paint resident → evict paint
        await log.add("granted-shape-2")

        let entries = await log.entries
        XCTAssertEqual(entries, ["granted-shape-1",
                                 "evict-shape", "granted-paint",
                                 "evict-paint", "granted-shape-2"])
        let resident = await arbiter.residentKind
        XCTAssertEqual(resident, .shape)
    }

    func testArbiterKeepsResidencyAcrossSameKindJobs() async {
        actor Counter {
            var evictions = 0
            func bump() { evictions += 1 }
        }
        let counter = Counter()
        let arbiter = EngineArbiter(evictors: [
            .shape: { await counter.bump() },
            .paint: { await counter.bump() },
        ])
        let p = UUID()
        for token in UInt64(1)...4 {                      // four shape jobs back to back
            let job = JobKey(kind: .shape, project: p, token: token)
            await arbiter.grant(job)
            await arbiter.release(job)
        }
        let evictions = await counter.evictions
        XCTAssertEqual(evictions, 0)                      // cache stays warm
    }
}
