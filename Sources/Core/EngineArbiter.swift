import Foundation

/// Exclusive GPU owner (DESIGN.md §4.6). WHO runs next is decided by the reducer
/// (its FIFO queue is the authority, unit-tested there); this actor makes the
/// handoff physically safe: it sequences evict-then-grant so the other engine's
/// weights are deterministically gone before the grantee starts loading — the
/// previous design's fire-and-forget cross-queue evict could overlap a load.
///
/// Shape and paint never run concurrently; a model's weights stay resident
/// between same-kind jobs (cache hit skips LoadingModel work), and are evicted
/// exactly when a grant of the other kind arrives.
actor EngineArbiter {
    /// Waits until the given engine's resident weights are fully dropped.
    typealias Evictor = @Sendable () async -> Void

    private let evictors: [EngineKind: Evictor]
    private var resident: EngineKind?
    private var heldBy: JobKey?

    init(evictors: [EngineKind: Evictor]) {
        self.evictors = evictors
    }

    /// Perform the residency handoff for a job the reducer granted. Returns only
    /// after any other-kind weights have been evicted, so the caller can start
    /// the engine load immediately afterwards.
    func grant(_ job: JobKey) async {
        if let current = resident, current != job.kind {
            await evictors[current]?()
        }
        resident = job.kind
        heldBy = job
    }

    /// Bookkeeping when a job finishes/cancels. Residency intentionally persists
    /// (the next same-kind job reuses the cache); only `heldBy` clears.
    func release(_ job: JobKey) {
        if heldBy == job { heldBy = nil }
    }

    /// Test/introspection hooks.
    var residentKind: EngineKind? { resident }
    var currentHolder: JobKey? { heldBy }
}
