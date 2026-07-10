import Foundation

/// Side effects the reducer requests. The runtime executes them (network, disk,
/// engines, arbiter) and feeds the results back in as events. The reducer itself
/// never performs I/O.
enum AppEffect: Equatable {
    // MARK: boot / persistence

    /// Move size-matching legacy files into the new slots, delete the rest (§2.3).
    case performMigration
    /// Write the onboarding-complete marker.
    case persistOnboardingComplete
    /// Persist which models have an unfinished install (drives Paused-on-relaunch).
    case persistInstallIntents(Set<ModelID>)

    // MARK: model install (§4.3)

    /// Begin (or resume from `.partial`) downloading a model's files, sequentially.
    case startDownload(ModelID, attempt: UInt64)
    /// Cancel the in-flight transfer, keep `.partial` bytes.
    case pauseDownload(ModelID)
    /// Confirm every file's size + recorded sha256 after the last file completes.
    case verifyFiles(ModelID, attempt: UInt64)
    /// Delete the model's install folder (+ any partials).
    case removeModelFiles(ModelID)
    /// Size-validate then copy a user-picked weights folder into the slot.
    case importWeights(ModelID, folder: URL)

    // MARK: shape job (§4.4)

    /// Snapshot input/mask/source into per-run files (ProjectStore).
    case stageShape(project: UUID, token: UInt64)
    /// Start the engine run (only ever emitted after `engineGranted`).
    case startShapeEngine(project: UUID, token: UInt64)
    case commitShape(project: UUID, token: UInt64)
    case discardShapeStaging(project: UUID, token: UInt64)

    // MARK: paint job (§4.5)

    case stagePaint(project: UUID, token: UInt64)
    /// Pre-engine mesh prep (QEM decimate + xatlas). Today this is a pass-through
    /// that reports success immediately — the vendored pipeline still unwraps
    /// inside the engine run; wave 2b moves the real work here.
    case unwrapPaintMesh(project: UUID, token: UInt64)
    case startPaintEngine(project: UUID, token: UInt64)
    case commitPaint(project: UUID, token: UInt64)
    case discardPaintStaging(project: UUID, token: UInt64)

    // MARK: engine arbiter (§4.6)

    /// Perform the residency handoff: evict the other engine's weights, then
    /// report `engineGranted`. Sequenced inside the arbiter actor so eviction
    /// deterministically precedes the grantee's model load.
    case grantEngine(JobKey)
    /// Set the cooperative cancel flag on the running job.
    case cancelEngine(JobKey)
    /// Bookkeeping when a job leaves the engine (weights may stay resident for reuse).
    case releaseEngine(JobKey)

    // MARK: UX routing

    /// Generation was requested while weights are missing — route to the model
    /// manager, never a bare error (§4.9 weightsMissing).
    case openModelManager
}
