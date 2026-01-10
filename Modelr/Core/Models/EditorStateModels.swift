import SwiftUI

// MARK: - Editor State Models
// These structs group related state to reduce @Published property count
// and improve code organization in SimpleEditorViewModel

// MARK: - Shared Enums

/// Display mode for 3D mesh viewer
enum MeshDisplayMode: String, CaseIterable {
    case solid = "Solid"
    case wireframe = "Wireframe"
}

/// Export format for 3D models
enum ModelExportFormat: String, CaseIterable, Identifiable {
    case obj = "OBJ"
    case glb = "GLB"

    var id: String { rawValue }

    var fileExtension: String {
        switch self {
        case .obj: return "obj"
        case .glb: return "glb"
        }
    }
}

/// State for download progress tracking
struct DownloadProgressState: Equatable {
    var downloadedBytes: Int64 = 0
    var totalBytes: Int64 = 0
    var speed: Double = 0  // bytes per second
    var timeRemaining: TimeInterval = 0

    /// Prefer HF/tqdm-reported totals when available
    var isUsingHuggingFaceProgress: Bool = false
    /// Pinned total to avoid re-querying
    var pinnedTotalBytes: Int64? = nil
    /// Avoid re-querying HF repeatedly
    var didQueryCurrentTotal: Bool = false

    var formattedProgress: String {
        let downloaded = ByteCountFormatter.string(fromByteCount: downloadedBytes, countStyle: .file)
        let total = ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file)
        return "\(downloaded) / \(total)"
    }

    var formattedSpeed: String {
        guard speed > 1024 else { return "—" }
        return ByteCountFormatter.string(fromByteCount: Int64(speed), countStyle: .file) + "/s"
    }

    var formattedTimeRemaining: String {
        guard timeRemaining > 0 && timeRemaining < 86400 else { return "" }
        let minutes = Int(timeRemaining) / 60
        let seconds = Int(timeRemaining) % 60
        return minutes > 0 ? "\(minutes)m \(seconds)s remaining" : "\(seconds)s remaining"
    }

    mutating func reset() {
        downloadedBytes = 0
        totalBytes = 0
        speed = 0
        timeRemaining = 0
        isUsingHuggingFaceProgress = false
        pinnedTotalBytes = nil
        didQueryCurrentTotal = false
    }
}

/// State for project initialization
struct InitializationState: Equatable {
    var isInitializing: Bool = false
    var status: String = ""
    var isImageInitializedWithSAM: Bool = false

    mutating func reset() {
        isInitializing = false
        status = ""
        isImageInitializedWithSAM = false
    }
}

/// State for VLM auto-detection
struct VLMDetectionState: Equatable {
    var isDetecting: Bool = false
    var detectedLabel: String?

    mutating func reset() {
        isDetecting = false
        detectedLabel = nil
    }
}

/// State for touchup/mask editing
struct TouchupState: Equatable {
    enum BrushMode: Equatable { case add, remove }

    var brushMode: BrushMode = .add
    var brushSize: CGFloat = 30
    var brushPreviewPosition: CGPoint? = nil
    var isStrokeInProgress: Bool = false
    var hasMaskEdits: Bool = false

    mutating func reset() {
        brushMode = .add
        brushSize = 30
        brushPreviewPosition = nil
        isStrokeInProgress = false
        hasMaskEdits = false
    }
}

/// State for generation process
struct GenerationProgressState {
    var status: String = ""
    var duration: TimeInterval?
    var stages: [GenerationStage: StageProgress] = [:]
    var setupLogs: [String] = []
    var isSmallModelDownloaded: Bool = false

    mutating func reset() {
        status = ""
        duration = nil
        stages = [:]
        setupLogs = []
    }
}

/// State for post-processing
struct PostProcessState {
    var keepIndices: Set<Int> = []
    var deleteIndices: Set<Int> = []
    var highlightedComponentIndex: Int? = nil
    var hoveredComponentIndex: Int? = nil
    var isolatedComponentIndex: Int? = nil
    var isAnalyzingMesh: Bool = false
    var isExtractingComponents: Bool = false
    var isProcessingMesh: Bool = false
    var selectedExportFormat: ModelExportFormat = .obj

    mutating func reset() {
        keepIndices = []
        deleteIndices = []
        highlightedComponentIndex = nil
        hoveredComponentIndex = nil
        isolatedComponentIndex = nil
        isAnalyzingMesh = false
        isExtractingComponents = false
        isProcessingMesh = false
        selectedExportFormat = .obj
    }
}

/// State for UI/viewport
struct ViewportState: Equatable {
    var zoomScale: CGFloat = 1.0
    var panOffset: CGSize = .zero
    var panBase: CGSize = .zero
    var showingOriginal: Bool = false

    mutating func resetZoom() {
        zoomScale = 1.0
        panOffset = .zero
        panBase = .zero
    }

    mutating func reset() {
        resetZoom()
        showingOriginal = false
    }
}

/// State for warning dialogs
struct WarningDialogState: Equatable {
    var showBackWarning: Bool = false
    var showDiscardModelWarning: Bool = false
    var showDiscardImageWarning: Bool = false
    var showStartOverWarning: Bool = false
    var showApplyChangesConfirmation: Bool = false

    mutating func reset() {
        showBackWarning = false
        showDiscardModelWarning = false
        showDiscardImageWarning = false
        showStartOverWarning = false
        showApplyChangesConfirmation = false
    }
}

/// State for environment configuration
struct EnvironmentState: Equatable {
    var isConfiguring: Bool = false
    var isRefreshing: Bool = false
    var refreshStatus: String = ""

    mutating func reset() {
        isConfiguring = false
        isRefreshing = false
        refreshStatus = ""
    }
}
