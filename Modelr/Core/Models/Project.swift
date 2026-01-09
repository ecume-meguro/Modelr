import Foundation

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

    /// Create a new project with default values
    init(
        id: UUID = UUID(),
        name: String = "New Project",
        createdAt: Date = Date(),
        modifiedAt: Date = Date(),
        thumbnailPath: String? = nil,
        sourceImagePath: String? = nil,
        workflowStep: Int = 1,  // Start at input step
        isExample: Bool = false
    ) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
        self.thumbnailPath = thumbnailPath
        self.sourceImagePath = sourceImagePath
        self.workflowStep = workflowStep
        self.isExample = isExample
    }

    /// Update the modification timestamp
    mutating func touch() {
        modifiedAt = Date()
    }
}

/// Extended project metadata saved separately (for larger state)
struct ProjectMetadata: Codable {
    let projectId: UUID
    var textPrompt: String?
    var selectedMaskIndices: [Int]?
    var generatedModelPath: String?
    var selectedPreset: String?
    var customSteps: Int?
    var customResolution: Int?
    var hasMaskEdits: Bool?

    init(projectId: UUID) {
        self.projectId = projectId
    }
}

/// Simplified segmentation data for persistence
struct SegmentationData: Codable {
    let id: UUID
    var name: String
    var textPrompt: String
    var selectedMaskIndices: [Int]
    var maskPath: String?  // Relative path to saved mask image

    init(
        id: UUID,
        name: String,
        textPrompt: String,
        selectedMaskIndices: [Int],
        maskPath: String? = nil
    ) {
        self.id = id
        self.name = name
        self.textPrompt = textPrompt
        self.selectedMaskIndices = selectedMaskIndices
        self.maskPath = maskPath
    }
}
