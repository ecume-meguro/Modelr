import XCTest

/// §4.5 paint — the full table, including the narrow cancel edge set (Rendering
/// and Denoising ONLY), the unwrap failure edge, and stale-token drops.
final class ReducerPaintTests: XCTestCase {

    // MARK: happy path

    func testPaintWalksPrepareUnwrapWaitGrant() {
        var w = PaintWalker()
        var effects = w.toPreparing()
        XCTAssertEqual(effects, [.stagePaint(project: w.project, token: w.token)])

        effects = w.send(.paintStaged(project: w.project, token: w.token, error: nil))
        XCTAssertEqual(w.jobState, .unwrapping)
        XCTAssertEqual(effects, [.unwrapPaintMesh(project: w.project, token: w.token)])

        effects = w.send(.paintUnwrapFinished(project: w.project, token: w.token, error: nil))
        XCTAssertEqual(w.jobState, .waitingForEngine)
        XCTAssertEqual(effects, [.grantEngine(w.key)])

        effects = w.send(.engineGranted(w.key))
        XCTAssertEqual(w.jobState, .loadingModel)
        XCTAssertEqual(effects, [.startPaintEngine(project: w.project, token: w.token)])
    }

    func testEngineStageProgression() {
        var w = PaintWalker()
        w.toLoading()
        w.send(.paintEngineStage(project: w.project, token: w.token, stage: .rendering, fraction: 0.1))
        XCTAssertEqual(w.jobState, .rendering)
        w.send(.paintEngineStage(project: w.project, token: w.token, stage: .denoising(step: 2, total: 10), fraction: 0.3))
        XCTAssertEqual(w.jobState, .denoising(step: 2, total: 10))
        w.send(.paintEngineStage(project: w.project, token: w.token, stage: .decoding, fraction: 0.8))
        XCTAssertEqual(w.jobState, .decoding)
        w.send(.paintEngineStage(project: w.project, token: w.token, stage: .upscaling, fraction: 0.88))
        XCTAssertEqual(w.jobState, .upscaling)
        w.send(.paintEngineStage(project: w.project, token: w.token, stage: .baking, fraction: 0.93))
        XCTAssertEqual(w.jobState, .baking)
        w.send(.paintEngineStage(project: w.project, token: w.token, stage: .inpainting, fraction: 0.97))
        XCTAssertEqual(w.jobState, .inpainting)
    }

    func testUpscalingIsPassedThroughWhenSuperResOff() {
        var w = PaintWalker()
        w.to(.decoding)
        // No super-res signal: the next stage event jumps Decoding → Baking along
        // the table edges (Upscaling passed through in zero time).
        w.send(.paintEngineStage(project: w.project, token: w.token, stage: .baking, fraction: 0.9))
        XCTAssertEqual(w.jobState, .baking)
        // Never backward.
        w.send(.paintEngineStage(project: w.project, token: w.token, stage: .rendering, fraction: 0.1))
        XCTAssertEqual(w.jobState, .baking)
    }

    func testSuccessCommitsThenIdles() {
        var w = PaintWalker()
        w.to(.baking)
        var effects = w.send(.paintEngineFinished(project: w.project, token: w.token, result: .success))
        XCTAssertEqual(w.jobState, .committing)
        XCTAssertEqual(effects, [.releaseEngine(w.key), .commitPaint(project: w.project, token: w.token)])

        effects = w.send(.paintCommitFinished(project: w.project, token: w.token, error: nil))
        XCTAssertEqual(w.jobState, .idle)
        XCTAssertEqual(effects, [])
    }

    func testCommitFailure() {
        var w = PaintWalker()
        w.to(.baking)
        w.send(.paintEngineFinished(project: w.project, token: w.token, result: .success))
        let effects = w.send(.paintCommitFinished(project: w.project, token: w.token, error: "no texture"))
        XCTAssertEqual(w.jobState, .failed(stage: "Committing", message: "no texture"))
        XCTAssertEqual(effects, [.discardPaintStaging(project: w.project, token: w.token)])
    }

    // MARK: gates

    func testPaintWithoutWeightsRoutesToModelManager() {
        var w = PaintWalker(installed: [.shapeSmall])   // paint weights absent
        let effects = w.send(.paintRequested(project: w.project, model: .paintSmall))
        XCTAssertEqual(effects, [.openModelManager])
        XCTAssertEqual(w.jobState, .idle)
    }

    func testPaintWhileRunningIsDropped() {
        var w = PaintWalker()
        w.toLoading()
        XCTAssertEqual(w.send(.paintRequested(project: w.project, model: .paintSmall)), [])
        XCTAssertEqual(w.jobState, .loadingModel)
    }

    // MARK: failures

    func testStagingFailure() {
        var w = PaintWalker()
        w.toPreparing()
        let effects = w.send(.paintStaged(project: w.project, token: w.token, error: "no mesh"))
        XCTAssertEqual(w.jobState, .failed(stage: "Preparing", message: "no mesh"))
        XCTAssertEqual(effects, [.discardPaintStaging(project: w.project, token: w.token)])
    }

    func testUnwrapRejection() {
        var w = PaintWalker()
        w.toUnwrapping()
        let effects = w.send(.paintUnwrapFinished(project: w.project, token: w.token,
                                                  error: "xatlas rejected the mesh"))
        XCTAssertEqual(w.jobState, .failed(stage: "Unwrapping", message: "xatlas rejected the mesh"))
        XCTAssertEqual(effects, [.discardPaintStaging(project: w.project, token: w.token)])
    }

    func testEngineFailureFromEachActiveStage() {
        let stages: [(PaintStage?, String)] = [
            (nil, "Loading model"),
            (.rendering, "Rendering"),
            (.denoising(step: 1, total: 10), "Denoising"),
            (.decoding, "Decoding"),
            (.upscaling, "Upscaling"),
            (.baking, "Baking"),
            (.inpainting, "Inpainting"),
        ]
        for (stage, label) in stages {
            var w = PaintWalker()
            if let stage { w.to(stage) } else { w.toLoading() }
            let effects = w.send(.paintEngineFinished(project: w.project, token: w.token,
                                                      result: .failure("boom")))
            XCTAssertEqual(w.jobState, .failed(stage: label, message: "boom"), "failing from \(label)")
            XCTAssertEqual(effects, [.discardPaintStaging(project: w.project, token: w.token),
                                     .releaseEngine(w.key)])
        }
    }

    func testFailureDismissed() {
        var w = PaintWalker()
        w.toLoading()
        w.send(.paintEngineFinished(project: w.project, token: w.token, result: .failure("x")))
        w.send(.paintFailureDismissed(project: w.project))
        XCTAssertEqual(w.jobState, .idle)
    }

    // MARK: cancel — ONLY Rendering and Denoising have edges (§4.5)

    func testCancelFromRenderingAndDenoising() {
        for stage in [PaintStage.rendering, .denoising(step: 3, total: 10)] {
            var w = PaintWalker()
            w.to(stage)
            let effects = w.send(.paintCancelRequested(project: w.project))
            XCTAssertEqual(w.jobState, .cancelling)
            XCTAssertEqual(effects, [.cancelEngine(w.key)])

            let done = w.send(.paintEngineFinished(project: w.project, token: w.token, result: .cancelled))
            XCTAssertEqual(w.jobState, .idle)
            XCTAssertEqual(done, [.discardPaintStaging(project: w.project, token: w.token),
                                  .releaseEngine(w.key)])
        }
    }

    func testCancelHasNoEdgeAnywhereElse() {
        // Preparing
        var w = PaintWalker()
        w.toPreparing()
        XCTAssertEqual(w.send(.paintCancelRequested(project: w.project)), [])
        XCTAssertEqual(w.jobState, .preparing)

        // Unwrapping
        w = PaintWalker(); w.toUnwrapping()
        XCTAssertEqual(w.send(.paintCancelRequested(project: w.project)), [])
        XCTAssertEqual(w.jobState, .unwrapping)

        // WaitingForEngine
        w = PaintWalker(); w.toWaiting()
        XCTAssertEqual(w.send(.paintCancelRequested(project: w.project)), [])
        XCTAssertEqual(w.jobState, .waitingForEngine)

        // LoadingModel
        w = PaintWalker(); w.toLoading()
        XCTAssertEqual(w.send(.paintCancelRequested(project: w.project)), [])
        XCTAssertEqual(w.jobState, .loadingModel)

        // Post-denoise stages
        for stage in [PaintStage.decoding, .upscaling, .baking, .inpainting] {
            w = PaintWalker(); w.to(stage)
            XCTAssertEqual(w.send(.paintCancelRequested(project: w.project)), [])
        }

        // Committing
        w = PaintWalker(); w.to(.baking)
        w.send(.paintEngineFinished(project: w.project, token: w.token, result: .success))
        XCTAssertEqual(w.send(.paintCancelRequested(project: w.project)), [])
        XCTAssertEqual(w.jobState, .committing)
    }

    // MARK: stale tokens

    func testStaleTokenEventsAreDropped() {
        var w = PaintWalker()
        w.toLoading()
        let stale = w.token &+ 9
        XCTAssertEqual(w.send(.paintStaged(project: w.project, token: stale, error: nil)), [])
        XCTAssertEqual(w.send(.paintUnwrapFinished(project: w.project, token: stale, error: nil)), [])
        XCTAssertEqual(w.send(.paintEngineStage(project: w.project, token: stale,
                                                stage: .baking, fraction: 0.9)), [])
        XCTAssertEqual(w.send(.paintEngineFinished(project: w.project, token: stale,
                                                   result: .success)), [])
        XCTAssertEqual(w.jobState, .loadingModel)
    }
}
