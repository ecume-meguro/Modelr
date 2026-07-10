import Foundation

// The deterministic core: every state in DESIGN.md §4 as plain value types.
// Nothing in this file performs I/O — the reducer owns transitions, the runtime
// owns side effects. All types are Equatable so tests can assert whole states.

// MARK: - §4.1 App lifecycle

enum AppPhase: Equatable {
    case boot
    case migrating
    case onboarding
    case ready
}

// MARK: - §4.2 Onboarding

enum OnboardingStep: Equatable {
    case welcome
    case chooseModels
    case downloading
    case failed(String)
    case done
}

struct OnboardingState: Equatable {
    var step: OnboardingStep = .welcome
    /// The models the user picked on the ChooseModels card (empty until then).
    var selection: Set<ModelID> = []
}

// MARK: - §4.3 Model install (per model)

/// Byte-level progress of the one in-flight model download.
struct DownloadProgress: Equatable {
    /// 1-based index of the file currently downloading.
    var fileIndex: Int = 1
    var fileCount: Int = 1
    var currentFileName: String = ""
    /// Bytes on disk for the current file (includes resumed partial bytes).
    var fileBytes: Int64 = 0
    var fileTotal: Int64 = 0
    /// Bytes on disk across the whole model (completed files + current partial).
    var totalBytes: Int64 = 0
    var totalExpected: Int64 = 0

    var fraction: Double {
        totalExpected > 0 ? Double(totalBytes) / Double(totalExpected) : 0
    }
}

enum ModelInstallState: Equatable {
    case notInstalled
    /// Install requested; waiting for the single download slot.
    case queued
    case downloading(DownloadProgress)
    /// User pause or app quit mid-download; `.partial` files remain on disk.
    case paused(resumeBytes: Int64)
    /// All files fetched; confirming every file's size + sha256.
    case verifying
    case installed
    case failed(String)

    var isInstalled: Bool { self == .installed }
    /// States that occupy (or want) the download slot.
    var isActive: Bool {
        switch self {
        case .queued, .downloading, .verifying: return true
        default: return false
        }
    }
}

// MARK: - §4.4 Shape generation (per project)

enum ShapeJobState: Equatable {
    case idle
    case preparing
    case waitingForEngine
    case loadingModel
    case conditioning
    case denoising(step: Int, total: Int)
    case decoding
    case meshing
    case committing
    case cancelling
    case failed(stage: String, message: String)

    /// States from which Cancel is accepted, exactly per the §4.4 table.
    var isCancellable: Bool {
        switch self {
        case .preparing, .waitingForEngine, .loadingModel, .conditioning, .denoising, .decoding:
            return true
        default:
            return false
        }
    }

    var isRunning: Bool {
        switch self {
        case .idle, .failed: return false
        default: return true
        }
    }
}

/// Engine progress checkpoints for a shape run, mapped from the Hy3DMLX callbacks.
enum ShapeStage: Equatable {
    case conditioning
    case denoising(step: Int, total: Int)
    case decoding
    case meshing
}

// MARK: - §4.5 Paint (per project)

enum PaintJobState: Equatable {
    case idle
    case preparing
    case unwrapping
    case waitingForEngine
    case loadingModel
    case rendering
    case denoising(step: Int, total: Int)
    case decoding
    case upscaling
    case baking
    case inpainting
    case committing
    case cancelling
    case failed(stage: String, message: String)

    /// Cancel edges exist only from Rendering and Denoising in the §4.5 table.
    var isCancellable: Bool {
        switch self {
        case .rendering, .denoising: return true
        default: return false
        }
    }

    var isRunning: Bool {
        switch self {
        case .idle, .failed: return false
        default: return true
        }
    }
}

enum PaintStage: Equatable {
    case rendering
    case denoising(step: Int, total: Int)
    case decoding
    case upscaling
    case baking
    case inpainting
}

// MARK: - §4.6 Engine arbiter

enum EngineKind: String, Equatable, Sendable {
    case shape, paint
}

/// Identifies one engine job. The token makes stale callbacks detectable: events
/// carrying a token ≠ the project's current token are dropped by the reducer.
struct JobKey: Hashable, Sendable {
    let kind: EngineKind
    let project: UUID
    let token: UInt64
}

enum EngineOwner: Equatable {
    case free
    case held(JobKey)
}

struct EngineState: Equatable {
    var owner: EngineOwner = .free
    /// FIFO wait queue — jobs in `waitingForEngine`, in request order.
    var queue: [JobKey] = []
}

// MARK: - Per-project job records

struct ShapeJob: Equatable {
    var token: UInt64
    var state: ShapeJobState = .idle
    /// Whole-run progress fraction from the engine (nil = indeterminate).
    var fraction: Double?
}

struct PaintJob: Equatable {
    var token: UInt64
    var state: PaintJobState = .idle
    var fraction: Double?
}

// MARK: - Whole-app state

struct AppState: Equatable {
    var phase: AppPhase = .boot
    var onboarding = OnboardingState()

    /// §4.3 machine per model. Every ModelID always has an entry.
    var models: [ModelID: ModelInstallState]
    /// FIFO of queued installs (one download at a time app-wide).
    var installQueue: [ModelID] = []
    /// The model currently downloading or verifying, if any.
    var activeInstall: ModelID?
    /// Monotonic token for install attempts; stale download events are dropped.
    var installAttempt: UInt64 = 0

    var shape: [UUID: ShapeJob] = [:]
    var paint: [UUID: PaintJob] = [:]
    var engine = EngineState()

    /// Monotonic job-token source (shared by shape and paint).
    var nextToken: UInt64 = 0

    init() {
        models = Dictionary(uniqueKeysWithValues: ModelID.allCases.map { ($0, .notInstalled) })
    }

    // MARK: convenience accessors

    func shapeState(_ project: UUID) -> ShapeJobState { shape[project]?.state ?? .idle }
    func paintState(_ project: UUID) -> PaintJobState { paint[project]?.state ?? .idle }
    func installState(_ model: ModelID) -> ModelInstallState { models[model] ?? .notInstalled }

    mutating func mintToken() -> UInt64 {
        nextToken += 1
        return nextToken
    }
}
