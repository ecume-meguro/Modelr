import XCTest

/// §4.4 shape generation — every edge of the transition table, including cancel
/// from each cancellable state, failure from each active state, and stale-token
/// drops.
final class ReducerShapeTests: XCTestCase {

    // MARK: happy path

    func testGenerateStagesThenWaitsThenRuns() {
        var w = ShapeWalker()
        var effects = w.toPreparing()
        XCTAssertEqual(effects, [.stageShape(project: w.project, token: w.token)])

        effects = w.send(.shapeStaged(project: w.project, token: w.token, error: nil))
        XCTAssertEqual(w.jobState, .waitingForEngine)
        XCTAssertEqual(effects, [.grantEngine(w.key)])
        XCTAssertEqual(w.state.engine.owner, .held(w.key))

        effects = w.send(.engineGranted(w.key))
        XCTAssertEqual(w.jobState, .loadingModel)
        XCTAssertEqual(effects, [.startShapeEngine(project: w.project, token: w.token)])
        XCTAssertTrue(w.state.engine.queue.isEmpty)
    }

    func testEngineStageProgression() {
        var w = ShapeWalker()
        w.toLoading()
        w.send(.shapeEngineStage(project: w.project, token: w.token, stage: .conditioning, fraction: 0.05))
        XCTAssertEqual(w.jobState, .conditioning)
        w.send(.shapeEngineStage(project: w.project, token: w.token, stage: .denoising(step: 1, total: 30), fraction: 0.1))
        XCTAssertEqual(w.jobState, .denoising(step: 1, total: 30))
        w.send(.shapeEngineStage(project: w.project, token: w.token, stage: .denoising(step: 7, total: 30), fraction: 0.3))
        XCTAssertEqual(w.jobState, .denoising(step: 7, total: 30))
        w.send(.shapeEngineStage(project: w.project, token: w.token, stage: .decoding, fraction: 0.72))
        XCTAssertEqual(w.jobState, .decoding)
        w.send(.shapeEngineStage(project: w.project, token: w.token, stage: .meshing, fraction: 0.9))
        XCTAssertEqual(w.jobState, .meshing)
        XCTAssertEqual(w.state.shape[w.project]?.fraction, 0.9)
    }

    func testStageMaySkipForwardButNeverBackward() {
        var w = ShapeWalker()
        w.toLoading()
        // Skip ahead (missed signals pass through intermediate states in zero time).
        w.send(.shapeEngineStage(project: w.project, token: w.token, stage: .decoding, fraction: 0.7))
        XCTAssertEqual(w.jobState, .decoding)
        // Backward is dropped.
        w.send(.shapeEngineStage(project: w.project, token: w.token, stage: .conditioning, fraction: 0.1))
        XCTAssertEqual(w.jobState, .decoding)
    }

    func testSuccessCommitsThenIdles() {
        var w = ShapeWalker()
        w.to(.meshing)
        var effects = w.send(.shapeEngineFinished(project: w.project, token: w.token, result: .success))
        XCTAssertEqual(w.jobState, .committing)
        XCTAssertEqual(effects, [.releaseEngine(w.key), .commitShape(project: w.project, token: w.token)])
        XCTAssertEqual(w.state.engine.owner, .free)

        effects = w.send(.shapeCommitFinished(project: w.project, token: w.token, error: nil))
        XCTAssertEqual(w.jobState, .idle)
        XCTAssertEqual(effects, [])
    }

    func testCommitFailureLandsInFailed() {
        var w = ShapeWalker()
        w.to(.meshing)
        w.send(.shapeEngineFinished(project: w.project, token: w.token, result: .success))
        let effects = w.send(.shapeCommitFinished(project: w.project, token: w.token, error: "no mesh"))
        XCTAssertEqual(w.jobState, .failed(stage: "Committing", message: "no mesh"))
        XCTAssertEqual(effects, [.discardShapeStaging(project: w.project, token: w.token)])
    }

    // MARK: weights gate (§4.9 weightsMissing)

    func testGenerateWithoutWeightsRoutesToModelManager() {
        var w = ShapeWalker(installed: [])
        let effects = w.send(.shapeGenerateRequested(project: w.project, model: .shapeSmall))
        XCTAssertEqual(effects, [.openModelManager])
        XCTAssertEqual(w.jobState, .idle)
    }

    func testGenerateWhileRunningIsDropped() {
        var w = ShapeWalker()
        w.toLoading()
        let tokenBefore = w.token
        let effects = w.send(.shapeGenerateRequested(project: w.project, model: .shapeSmall))
        XCTAssertEqual(effects, [])
        XCTAssertEqual(w.token, tokenBefore)
        XCTAssertEqual(w.jobState, .loadingModel)
    }

    // MARK: failure from each active state

    func testStagingFailure() {
        var w = ShapeWalker()
        w.toPreparing()
        let effects = w.send(.shapeStaged(project: w.project, token: w.token, error: "no image"))
        XCTAssertEqual(w.jobState, .failed(stage: "Preparing", message: "no image"))
        XCTAssertEqual(effects, [.discardShapeStaging(project: w.project, token: w.token)])
    }

    func testEngineFailureFromEachActiveStage() {
        let stages: [(ShapeStage?, String)] = [
            (nil, "Loading model"),
            (.conditioning, "Conditioning"),
            (.denoising(step: 3, total: 30), "Denoising"),
            (.decoding, "Decoding"),
            (.meshing, "Meshing"),
        ]
        for (stage, label) in stages {
            var w = ShapeWalker()
            if let stage { w.to(stage) } else { w.toLoading() }
            let effects = w.send(.shapeEngineFinished(project: w.project, token: w.token,
                                                      result: .failure("boom")))
            XCTAssertEqual(w.jobState, .failed(stage: label, message: "boom"), "failing from \(label)")
            XCTAssertEqual(effects, [.discardShapeStaging(project: w.project, token: w.token),
                                     .releaseEngine(w.key)], "effects from \(label)")
            XCTAssertEqual(w.state.engine.owner, .free)
        }
    }

    func testFailureDismissedReturnsToIdleAndAllowsNewRun() {
        var w = ShapeWalker()
        w.toLoading()
        w.send(.shapeEngineFinished(project: w.project, token: w.token, result: .failure("x")))
        w.send(.shapeFailureDismissed(project: w.project))
        XCTAssertEqual(w.jobState, .idle)

        // Failed → Idle also happens implicitly via a new run.
        var w2 = ShapeWalker()
        w2.toLoading()
        w2.send(.shapeEngineFinished(project: w2.project, token: w2.token, result: .failure("x")))
        let effects = w2.send(.shapeGenerateRequested(project: w2.project, model: .shapeSmall))
        XCTAssertEqual(w2.jobState, .preparing)
        XCTAssertEqual(effects, [.stageShape(project: w2.project, token: w2.token)])
    }

    // MARK: cancel from each state (exact §4.4 edge set)

    func testCancelDuringPreparingWaitsForStaging() {
        var w = ShapeWalker()
        w.toPreparing()
        let effects = w.send(.shapeCancelRequested(project: w.project))
        XCTAssertEqual(w.jobState, .cancelling)
        XCTAssertEqual(effects, [])                      // resolution comes with shapeStaged

        let after = w.send(.shapeStaged(project: w.project, token: w.token, error: nil))
        XCTAssertEqual(w.jobState, .idle)
        XCTAssertEqual(after, [.discardShapeStaging(project: w.project, token: w.token)])
    }

    func testCancelWhileWaitingDequeuesImmediately() {
        var w = ShapeWalker()
        w.toWaiting()                                    // owner (grant in flight)
        let key = w.key
        let effects = w.send(.shapeCancelRequested(project: w.project))
        XCTAssertEqual(w.jobState, .idle)
        XCTAssertTrue(w.state.engine.queue.isEmpty)
        XCTAssertEqual(w.state.engine.owner, .free)
        XCTAssertEqual(effects, [.discardShapeStaging(project: w.project, token: key.token),
                                 .releaseEngine(key)])

        // The in-flight grant lands stale → handed straight back.
        let stale = w.send(.engineGranted(key))
        XCTAssertEqual(stale, [.releaseEngine(key)])
        XCTAssertEqual(w.jobState, .idle)
    }

    func testCancelDuringEngineStagesGoesThroughCancelling() {
        let stages: [ShapeStage?] = [nil, .conditioning, .denoising(step: 2, total: 8), .decoding]
        for stage in stages {
            var w = ShapeWalker()
            if let stage { w.to(stage) } else { w.toLoading() }
            let effects = w.send(.shapeCancelRequested(project: w.project))
            XCTAssertEqual(w.jobState, .cancelling, "from \(String(describing: stage))")
            XCTAssertEqual(effects, [.cancelEngine(w.key)])

            // Engine acknowledges (flag checked after load returns / next step).
            let done = w.send(.shapeEngineFinished(project: w.project, token: w.token, result: .cancelled))
            XCTAssertEqual(w.jobState, .idle)
            XCTAssertEqual(done, [.discardShapeStaging(project: w.project, token: w.token),
                                  .releaseEngine(w.key)])
        }
    }

    func testCancelHasNoEdgeFromMeshingOrCommitting() {
        var w = ShapeWalker()
        w.to(.meshing)
        XCTAssertEqual(w.send(.shapeCancelRequested(project: w.project)), [])
        XCTAssertEqual(w.jobState, .meshing)

        w.send(.shapeEngineFinished(project: w.project, token: w.token, result: .success))
        XCTAssertEqual(w.jobState, .committing)
        XCTAssertEqual(w.send(.shapeCancelRequested(project: w.project)), [])
        XCTAssertEqual(w.jobState, .committing)
    }

    func testStageEventsDroppedWhileCancelling() {
        var w = ShapeWalker()
        w.to(.denoising(step: 1, total: 8))
        w.send(.shapeCancelRequested(project: w.project))
        XCTAssertEqual(w.jobState, .cancelling)
        w.send(.shapeEngineStage(project: w.project, token: w.token,
                                 stage: .denoising(step: 2, total: 8), fraction: 0.4))
        XCTAssertEqual(w.jobState, .cancelling)
    }

    // MARK: stale tokens

    func testStaleTokenEventsAreDropped() {
        var w = ShapeWalker()
        w.toLoading()
        let stale = w.token &+ 40

        XCTAssertEqual(w.send(.shapeStaged(project: w.project, token: stale, error: nil)), [])
        XCTAssertEqual(w.send(.shapeEngineStage(project: w.project, token: stale,
                                                stage: .decoding, fraction: 0.5)), [])
        XCTAssertEqual(w.jobState, .loadingModel)
        XCTAssertEqual(w.send(.shapeEngineFinished(project: w.project, token: stale,
                                                   result: .failure("old run"))), [])
        XCTAssertEqual(w.jobState, .loadingModel)
        XCTAssertEqual(w.send(.shapeCommitFinished(project: w.project, token: stale, error: nil)), [])
        XCTAssertEqual(w.jobState, .loadingModel)
    }

    func testCancelledOldRunEventsDoNotTouchTheNewRun() {
        var w = ShapeWalker()
        w.to(.denoising(step: 1, total: 8))
        let oldToken = w.token
        w.send(.shapeCancelRequested(project: w.project))
        w.send(.shapeEngineFinished(project: w.project, token: oldToken, result: .cancelled))
        XCTAssertEqual(w.jobState, .idle)

        // New run gets a fresh token; a late event from the old run must be inert.
        w.send(.shapeGenerateRequested(project: w.project, model: .shapeSmall))
        XCTAssertNotEqual(w.token, oldToken)
        XCTAssertEqual(w.send(.shapeEngineFinished(project: w.project, token: oldToken,
                                                   result: .failure("late"))), [])
        XCTAssertEqual(w.jobState, .preparing)
    }

    // MARK: cancelled result outside Cancelling (defensive)

    func testUnsolicitedCancelledResultCleansUp() {
        var w = ShapeWalker()
        w.to(.decoding)
        let effects = w.send(.shapeEngineFinished(project: w.project, token: w.token, result: .cancelled))
        XCTAssertEqual(w.jobState, .idle)
        XCTAssertEqual(effects, [.discardShapeStaging(project: w.project, token: w.token),
                                 .releaseEngine(w.key)])
    }
}
