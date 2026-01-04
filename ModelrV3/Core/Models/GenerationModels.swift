import Foundation

/// Stages of the 3D generation pipeline
enum GenerationStage: String, CaseIterable {
    case downloading = "Downloading Model"
    case extracting = "Extracting"
    case loading = "Loading Model"
    case diffusion = "Diffusion Sampling"
    case volumeDecoding = "Volume Decoding"
    case saving = "Saving"
}

/// Progress information for a generation stage
struct StageProgress {
    var status: StageStatus = .pending
    var progress: Double = 0
    var detail: String = ""
}

/// Status of a generation stage
enum StageStatus {
    case pending
    case inProgress
    case completed
    case cancelled
    case failed
}
