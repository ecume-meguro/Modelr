import Foundation

/// Project creation mode - determines the workflow
enum ProjectMode: String, Codable, CaseIterable {
    case imageToModel  // Existing: Image → Segment → 3D
    case textToModel   // New: Text → Image → 3D

    var displayName: String {
        switch self {
        case .imageToModel: return "Image to Model"
        case .textToModel: return "Text to Model"
        }
    }

    var icon: String {
        switch self {
        case .imageToModel: return "photo"
        case .textToModel: return "text.cursor"
        }
    }

    var description: String {
        switch self {
        case .imageToModel: return "Upload an image and convert it to 3D"
        case .textToModel: return "Describe what you want and generate 3D"
        }
    }
}

/// Represents a Modelr project with its associated state and files
struct Project: Identifiable, Codable, Equatable {
    let id: UUID
    var name: String
    var createdAt: Date
    var modifiedAt: Date
    var thumbnailPath: String?      // Relative path to thumbnail within project folder
    var sourceImagePath: String?    // Relative path to source image
    var workflowStep: Int           // Current step in workflow (for state restore)
    var isExample: Bool             // True if this is a bundled example
    var mode: ProjectMode           // Project creation mode (image-to-model or text-to-model)

    /// Create a new project with default values
    init(
        id: UUID = UUID(),
        name: String = "New Project",
        createdAt: Date = Date(),
        modifiedAt: Date = Date(),
        thumbnailPath: String? = nil,
        sourceImagePath: String? = nil,
        workflowStep: Int = 1,  // Start at input step
        isExample: Bool = false,
        mode: ProjectMode = .imageToModel
    ) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
        self.thumbnailPath = thumbnailPath
        self.sourceImagePath = sourceImagePath
        self.workflowStep = workflowStep
        self.isExample = isExample
        self.mode = mode
    }

    /// Custom decoder to handle existing projects without mode field
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        modifiedAt = try container.decode(Date.self, forKey: .modifiedAt)
        thumbnailPath = try container.decodeIfPresent(String.self, forKey: .thumbnailPath)
        sourceImagePath = try container.decodeIfPresent(String.self, forKey: .sourceImagePath)
        workflowStep = try container.decode(Int.self, forKey: .workflowStep)
        isExample = try container.decode(Bool.self, forKey: .isExample)
        // Default to imageToModel for existing projects
        mode = try container.decodeIfPresent(ProjectMode.self, forKey: .mode) ?? .imageToModel
    }

    /// Update the modification timestamp
    mutating func touch() {
        modifiedAt = Date()
    }
}

/// Extended project metadata saved separately (for larger state)
struct ProjectMetadata: Codable {
    let projectId: UUID

    // Legacy single-segmentation fields (kept for backwards compatibility)
    var textPrompt: String?
    var selectedMaskIndices: [Int]?

    // Multi-segmentation data
    var segmentations: [SegmentationData]?

    // VLM auto-detected label (saved for reference)
    var autoDetectedLabel: String?

    // Generation settings
    var generatedModelPath: String?
    var selectedPreset: String?
    var customSteps: Int?
    var customResolution: Int?
    var hasMaskEdits: Bool?

    // Merged mask path (the combined mask used for generation)
    var mergedMaskPath: String?

    // Text-to-Model specific fields
    var t2iPrompt: String?              // User's text prompt for image generation
    var t2iNegativePrompt: String?      // Negative prompt for T2I
    var t2iGeneratedImagePath: String?  // Path to T2I-generated image (used as Hunyuan input)
    var t2iSeed: Int?                   // Seed used for T2I generation (for reproducibility)
    var t2iSteps: Int?                  // Number of diffusion steps used
    var t2iGuidanceScale: Float?        // CFG scale used

    init(projectId: UUID) {
        self.projectId = projectId
    }

    /// Check if project has valid saved segmentation data
    var hasSegmentationData: Bool {
        guard let segs = segmentations, !segs.isEmpty else { return false }
        return segs.contains { $0.maskPaths != nil && !($0.maskPaths?.isEmpty ?? true) }
    }
}

/// Simplified segmentation data for persistence
struct SegmentationData: Codable {
    let id: UUID
    var name: String
    var textPrompt: String
    var selectedMaskIndices: [Int]

    // Paths to saved mask images (one per mask option)
    var maskPaths: [String]?

    // Legacy single mask path (for backwards compatibility)
    var maskPath: String?

    init(
        id: UUID,
        name: String,
        textPrompt: String,
        selectedMaskIndices: [Int],
        maskPaths: [String]? = nil,
        maskPath: String? = nil
    ) {
        self.id = id
        self.name = name
        self.textPrompt = textPrompt
        self.selectedMaskIndices = selectedMaskIndices
        self.maskPaths = maskPaths
        self.maskPath = maskPath
    }
}
