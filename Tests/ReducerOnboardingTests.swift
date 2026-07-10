import XCTest

/// §4.2 onboarding — the sheet's step machine and its coupling to the §4.3
/// install machines, including skip at every step and resume-on-retry.
final class ReducerOnboardingTests: XCTestCase {

    private func onboardingState() -> AppState {
        var s = AppState()
        _ = AppReducer.reduce(&s, .bootScanned(legacyLayoutDetected: false, report: BootReport()))
        XCTAssertEqual(s.phase, .onboarding)
        return s
    }

    @discardableResult
    private func reduce(_ state: inout AppState, _ event: AppEvent) -> [AppEffect] {
        AppReducer.reduce(&state, event)
    }

    // MARK: step walk

    func testWelcomeAdvancesToChooseModels() {
        var s = onboardingState()
        reduce(&s, .onboardingAdvanced)
        XCTAssertEqual(s.onboarding.step, .chooseModels)
        // Advancing twice is inert.
        reduce(&s, .onboardingAdvanced)
        XCTAssertEqual(s.onboarding.step, .chooseModels)
    }

    func testStartDownloadQueuesSelectionInCatalogOrder() {
        var s = onboardingState()
        reduce(&s, .onboardingAdvanced)
        let effects = reduce(&s, .onboardingStartDownload(ModelCatalog.everything))
        XCTAssertEqual(s.onboarding.step, .downloading)
        XCTAssertEqual(s.onboarding.selection, ModelCatalog.everything)
        // First (catalog order) claims the slot; the rest queue FIFO.
        XCTAssertEqual(effects.first, .startDownload(.shapeSmall, attempt: 1))
        XCTAssertEqual(s.activeInstall, .shapeSmall)
        XCTAssertEqual(s.installQueue, [.shapeLarge, .paintSmall, .paintLarge])
    }

    func testEmptySelectionDoesNotStart() {
        var s = onboardingState()
        reduce(&s, .onboardingAdvanced)
        XCTAssertEqual(reduce(&s, .onboardingStartDownload([])), [])
        XCTAssertEqual(s.onboarding.step, .chooseModels)
    }

    func testAllSelectedVerifiedReachesDone() {
        var s = onboardingState()
        reduce(&s, .onboardingAdvanced)
        reduce(&s, .onboardingStartDownload(ModelCatalog.fastStart))

        // shape-small completes…
        reduce(&s, .downloadCompleted(.shapeSmall, attempt: 1))
        var effects = reduce(&s, .verifyFinished(.shapeSmall, attempt: 1, error: nil))
        XCTAssertEqual(s.onboarding.step, .downloading)   // paint-small still going
        XCTAssertTrue(effects.contains(.startDownload(.paintSmall, attempt: 2)))

        // …then paint-small: selection complete → Done + marker persisted.
        reduce(&s, .downloadCompleted(.paintSmall, attempt: 2))
        effects = reduce(&s, .verifyFinished(.paintSmall, attempt: 2, error: nil))
        XCTAssertEqual(s.onboarding.step, .done)
        XCTAssertTrue(effects.contains(.persistOnboardingComplete))
        XCTAssertEqual(s.phase, .onboarding)              // Done screen still up

        reduce(&s, .onboardingFinished)
        XCTAssertEqual(s.phase, .ready)
    }

    func testSelectionAlreadyInstalledJumpsStraightToDone() {
        var s = AppState()
        _ = AppReducer.reduce(&s, .bootScanned(legacyLayoutDetected: false, report: BootReport(
            installed: [], resumable: [:], onboardingComplete: false)))
        // Manually mark installed to model "arrived while choosing" (e.g. import).
        s.models[.shapeSmall] = .installed
        s.models[.paintSmall] = .installed
        reduce(&s, .onboardingAdvanced)
        let effects = reduce(&s, .onboardingStartDownload(ModelCatalog.fastStart))
        XCTAssertEqual(s.onboarding.step, .done)
        XCTAssertTrue(effects.contains(.persistOnboardingComplete))
    }

    // MARK: failure / retry (resumes at byte offset via the §4.3 machine)

    func testDownloadFailurePropagatesToTheSheet() {
        var s = onboardingState()
        reduce(&s, .onboardingAdvanced)
        reduce(&s, .onboardingStartDownload(ModelCatalog.fastStart))
        reduce(&s, .downloadFailed(.shapeSmall, attempt: 1, message: "The server returned HTTP 500."))
        XCTAssertEqual(s.onboarding.step, .failed("The server returned HTTP 500."))
        XCTAssertEqual(s.installState(.shapeSmall), .failed("The server returned HTTP 500."))
    }

    func testVerifyFailurePropagatesToTheSheet() {
        var s = onboardingState()
        reduce(&s, .onboardingAdvanced)
        reduce(&s, .onboardingStartDownload(ModelCatalog.fastStart))
        reduce(&s, .downloadCompleted(.shapeSmall, attempt: 1))
        reduce(&s, .verifyFinished(.shapeSmall, attempt: 1, error: "bad hash"))
        XCTAssertEqual(s.onboarding.step, .failed("bad hash"))
    }

    func testRetryRequeuesOnlyTheUnfinishedModels() {
        var s = onboardingState()
        reduce(&s, .onboardingAdvanced)
        reduce(&s, .onboardingStartDownload(ModelCatalog.fastStart))
        reduce(&s, .downloadCompleted(.shapeSmall, attempt: 1))
        reduce(&s, .verifyFinished(.shapeSmall, attempt: 1, error: nil))    // small installed
        reduce(&s, .downloadFailed(.paintSmall, attempt: 2, message: "offline"))
        XCTAssertEqual(s.onboarding.step, .failed("offline"))

        let effects = reduce(&s, .onboardingRetried)
        XCTAssertEqual(s.onboarding.step, .downloading)
        XCTAssertEqual(s.installState(.shapeSmall), .installed)             // untouched
        XCTAssertTrue(effects.contains(.startDownload(.paintSmall, attempt: 3)))
    }

    func testUnselectedModelFailureDoesNotTouchTheSheet() {
        var s = onboardingState()
        reduce(&s, .onboardingAdvanced)
        reduce(&s, .onboardingStartDownload(ModelCatalog.fastStart))        // small pair only
        reduce(&s, .installRequested(.shapeLarge))          // queued via the model manager
        reduce(&s, .downloadCompleted(.shapeSmall, attempt: 1))
        reduce(&s, .verifyFinished(.shapeSmall, attempt: 1, error: nil))
        reduce(&s, .downloadCompleted(.paintSmall, attempt: 2))
        reduce(&s, .verifyFinished(.paintSmall, attempt: 2, error: nil))
        XCTAssertEqual(s.onboarding.step, .done)            // selection complete

        // The unselected extra model failing later leaves the sheet Done.
        reduce(&s, .downloadFailed(.shapeLarge, attempt: 3, message: "offline"))
        XCTAssertEqual(s.onboarding.step, .done)
        XCTAssertEqual(s.installState(.shapeLarge), .failed("offline"))
    }

    // MARK: skip ("Later" at every step, §4.2 + §4.1 Onboarding → Ready)

    func testSkipFromEveryStep() {
        // Welcome
        var s = onboardingState()
        var effects = reduce(&s, .onboardingSkipped)
        XCTAssertEqual(s.phase, .ready)
        XCTAssertTrue(effects.contains(.persistOnboardingComplete))

        // ChooseModels
        s = onboardingState()
        reduce(&s, .onboardingAdvanced)
        reduce(&s, .onboardingSkipped)
        XCTAssertEqual(s.phase, .ready)

        // Downloading — the install machines keep running in the background.
        s = onboardingState()
        reduce(&s, .onboardingAdvanced)
        reduce(&s, .onboardingStartDownload(ModelCatalog.fastStart))
        effects = reduce(&s, .onboardingSkipped)
        XCTAssertEqual(s.phase, .ready)
        XCTAssertEqual(s.activeInstall, .shapeSmall)      // download not cancelled
        if case .downloading = s.installState(.shapeSmall) {} else { XCTFail("still downloading") }

        // Failed
        s = onboardingState()
        reduce(&s, .onboardingAdvanced)
        reduce(&s, .onboardingStartDownload(ModelCatalog.fastStart))
        reduce(&s, .downloadFailed(.shapeSmall, attempt: 1, message: "x"))
        reduce(&s, .onboardingSkipped)
        XCTAssertEqual(s.phase, .ready)
    }

    func testOnboardingEventsInertOnceReady() {
        var s = AppState.ready()
        XCTAssertEqual(AppReducer.reduce(&s, .onboardingAdvanced), [])
        XCTAssertEqual(AppReducer.reduce(&s, .onboardingSkipped), [])
        XCTAssertEqual(AppReducer.reduce(&s, .onboardingStartDownload(ModelCatalog.fastStart)), [])
        XCTAssertEqual(s.phase, .ready)
    }
}
