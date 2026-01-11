import os.log
import Foundation
import AppKit

/// Manages project CRUD operations and persistence
@MainActor
class ProjectManager: ObservableObject {
    static let shared = ProjectManager()

    @Published private(set) var projects: [Project] = []
    @Published private(set) var isLoading: Bool = false

    private let fileManager = FileManager.default
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    /// Cache example images list (avoid rescanning bundle)
    private var cachedExamples: [(name: String, url: URL)]?

    private init() {
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601
    }

    // MARK: - Project Loading

    /// Load all projects from disk (parallelized for performance)
    func loadProjects() async {
        isLoading = true
        defer { isLoading = false }

        do {
            try PathManager.ensureDirectoryExists(at: PathManager.projectsDirectory)

            let contents = try fileManager.contentsOfDirectory(
                at: PathManager.projectsDirectory,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )

            // Filter to directories with valid UUIDs
            let projectFolders = contents.compactMap { url -> (URL, UUID)? in
                var isDirectory: ObjCBool = false
                guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory),
                      isDirectory.boolValue,
                      let projectId = UUID(uuidString: url.lastPathComponent) else { return nil }
                return (url, projectId)
            }

            // Load projects in parallel for faster startup
            let loadedProjects = await withTaskGroup(of: Project?.self, returning: [Project].self) { group in
                for (_, projectId) in projectFolders {
                    group.addTask { [self] in
                        self.loadProject(id: projectId)
                    }
                }

                var results: [Project] = []
                for await project in group {
                    if let project = project {
                        results.append(project)
                    }
                }
                return results
            }

            // Sort by modification date (most recent first)
            self.projects = loadedProjects.sorted { $0.modifiedAt > $1.modifiedAt }

        } catch {
            print("[ProjectManager] Failed to load projects: \(error)")
        }
    }

    /// Load a single project by ID
    nonisolated func loadProject(id: UUID) -> Project? {
        let manifestPath = PathManager.projectManifestPath(for: id)
        guard let data = try? Data(contentsOf: manifestPath),
              let project = try? decoder.decode(Project.self, from: data) else {
            return nil
        }
        return project
    }

    /// Load project metadata
    nonisolated func loadMetadata(for projectId: UUID) -> ProjectMetadata? {
        let metadataPath = PathManager.projectMetadataPath(for: projectId)
        guard let data = try? Data(contentsOf: metadataPath),
              let metadata = try? decoder.decode(ProjectMetadata.self, from: data) else {
            return nil
        }
        return metadata
    }

    // MARK: - Project Creation

    /// Create a new project from an image
    func createProject(from imageURL: URL, name: String? = nil) async throws -> Project {
        let projectId = UUID()
        let projectDir = PathManager.projectDirectory(for: projectId)

        // Create project directory
        try PathManager.ensureDirectoryExists(at: projectDir)

        // Copy source image
        let sourceImagePath = PathManager.projectSourceImagePath(for: projectId)
        try fileManager.copyItem(at: imageURL, to: sourceImagePath)

        // Generate thumbnail using GPU-accelerated method
        let thumbnailPath = PathManager.projectThumbnailPath(for: projectId)
        let thumbnailSuccess = await ThumbnailCache.shared.generateThumbnail(from: sourceImagePath, to: thumbnailPath)

        // Create project
        let projectName = name ?? imageURL.deletingPathExtension().lastPathComponent
        let project = Project(
            id: projectId,
            name: projectName,
            thumbnailPath: thumbnailSuccess ? "thumbnail.png" : nil,
            sourceImagePath: "source.png",
            workflowStep: 1
        )

        // Save project manifest
        try saveProject(project)

        // Create initial metadata
        let metadata = ProjectMetadata(projectId: projectId)
        try saveMetadata(metadata)

        // Add to list and sort
        projects.append(project)
        projects.sort { $0.modifiedAt > $1.modifiedAt }

        return project
    }

    /// Create a project from bundled example image
    func createProjectFromExample(imageName: String) async throws -> Project {
        guard let imageURL = Bundle.main.url(forResource: imageName, withExtension: "png", subdirectory: "Examples") ??
              Bundle.main.url(forResource: imageName, withExtension: "jpg", subdirectory: "Examples") else {
            throw ProjectError.exampleNotFound(imageName)
        }
        return try await createProject(from: imageURL, name: imageName)
    }

    // MARK: - Project Saving

    /// Save project manifest to disk
    func saveProject(_ project: Project) throws {
        let manifestPath = PathManager.projectManifestPath(for: project.id)
        let data = try encoder.encode(project)
        try data.write(to: manifestPath)

        // Update in-memory list
        if let index = projects.firstIndex(where: { $0.id == project.id }) {
            projects[index] = project
            projects.sort { $0.modifiedAt > $1.modifiedAt }
        }
    }

    /// Save project metadata
    nonisolated func saveMetadata(_ metadata: ProjectMetadata) throws {
        let metadataPath = PathManager.projectMetadataPath(for: metadata.projectId)
        let data = try encoder.encode(metadata)
        try data.write(to: metadataPath)
    }

    /// Update project modification time
    func touchProject(_ projectId: UUID) throws {
        guard var project = loadProject(id: projectId) else { return }
        project.touch()
        try saveProject(project)
    }

    /// Rename a project
    func renameProject(_ projectId: UUID, to newName: String) throws {
        guard var project = loadProject(id: projectId) else { return }
        project.name = newName
        project.touch()
        try saveProject(project)
    }

    /// Duplicate a project
    func duplicateProject(_ projectId: UUID) async throws -> Project {
        guard let original = loadProject(id: projectId) else {
            throw ProjectError.loadFailed(NSError(domain: "ProjectManager", code: -1, userInfo: [NSLocalizedDescriptionKey: "Project not found"]))
        }

        let newId = UUID()
        let originalDir = PathManager.projectDirectory(for: projectId)
        let newDir = PathManager.projectDirectory(for: newId)

        // Copy entire project directory
        try fileManager.copyItem(at: originalDir, to: newDir)

        // Create new project with updated metadata
        let newProject = Project(
            id: newId,
            name: "\(original.name) Copy",
            thumbnailPath: original.thumbnailPath,
            sourceImagePath: original.sourceImagePath,
            workflowStep: original.workflowStep,
            mode: original.mode
        )

        // Save the new project manifest
        try saveProject(newProject)

        // Update metadata with new project ID (file was copied, now update the ID inside)
        if let oldMetadata = loadMetadata(for: newId) {
            var newMetadata = ProjectMetadata(projectId: newId)
            newMetadata.textPrompt = oldMetadata.textPrompt
            newMetadata.selectedMaskIndices = oldMetadata.selectedMaskIndices
            newMetadata.generatedModelPath = oldMetadata.generatedModelPath
            newMetadata.selectedPreset = oldMetadata.selectedPreset
            newMetadata.customSteps = oldMetadata.customSteps
            newMetadata.customResolution = oldMetadata.customResolution
            newMetadata.hasMaskEdits = oldMetadata.hasMaskEdits
            try saveMetadata(newMetadata)
        }

        // Add to list and sort
        projects.append(newProject)
        projects.sort { $0.modifiedAt > $1.modifiedAt }

        return newProject
    }

    // MARK: - Project Deletion

    /// Delete a project and all its files
    func deleteProject(_ projectId: UUID) throws {
        let projectDir = PathManager.projectDirectory(for: projectId)
        try fileManager.removeItem(at: projectDir)

        // Invalidate thumbnail cache
        ThumbnailCache.shared.invalidate(projectId: projectId)

        // Remove from list
        projects.removeAll { $0.id == projectId }
    }

    // MARK: - Helpers

    /// Get recent projects (sorted by modification date)
    func recentProjects(limit: Int = 10) -> [Project] {
        Array(projects.prefix(limit))
    }

    /// Check if any projects exist
    var hasProjects: Bool {
        !projects.isEmpty
    }

    // MARK: - Segmentation Data Persistence

    /// Save segmentation data and masks to project folder
    func saveSegmentationData(
        for projectId: UUID,
        segmentations: [(id: UUID, name: String, textPrompt: String, selectedIndices: [Int], masks: [(image: NSImage, url: URL)])],
        autoDetectedLabel: String?,
        mergedMask: NSImage?
    ) throws {
        let projectDir = PathManager.projectDirectory(for: projectId)
        let masksDir = projectDir.appendingPathComponent("masks", isDirectory: true)

        // Ensure masks directory exists
        try PathManager.ensureDirectoryExists(at: masksDir)

        // Convert and save each segmentation
        var segmentationDataArray: [SegmentationData] = []

        for seg in segmentations {
            var maskPaths: [String] = []

            // Save each mask image
            for (maskIndex, maskData) in seg.masks.enumerated() {
                let maskFilename = "seg_\(seg.id.uuidString)_mask_\(maskIndex).png"
                let maskPath = masksDir.appendingPathComponent(maskFilename)

                // Save mask image
                if let tiffData = maskData.image.tiffRepresentation,
                   let bitmap = NSBitmapImageRep(data: tiffData),
                   let pngData = bitmap.representation(using: .png, properties: [:]) {
                    try pngData.write(to: maskPath)
                    maskPaths.append("masks/\(maskFilename)")
                }
            }

            let segData = SegmentationData(
                id: seg.id,
                name: seg.name,
                textPrompt: seg.textPrompt,
                selectedMaskIndices: seg.selectedIndices,
                maskPaths: maskPaths
            )
            segmentationDataArray.append(segData)
        }

        // Save merged mask if provided
        var mergedMaskPath: String? = nil
        if let mergedMask = mergedMask {
            let mergedFilename = "merged_mask.png"
            let mergedPath = masksDir.appendingPathComponent(mergedFilename)
            if let tiffData = mergedMask.tiffRepresentation,
               let bitmap = NSBitmapImageRep(data: tiffData),
               let pngData = bitmap.representation(using: .png, properties: [:]) {
                try pngData.write(to: mergedPath)
                mergedMaskPath = "masks/\(mergedFilename)"
            }
        }

        // Update metadata
        var metadata = loadMetadata(for: projectId) ?? ProjectMetadata(projectId: projectId)
        metadata.segmentations = segmentationDataArray
        metadata.autoDetectedLabel = autoDetectedLabel
        metadata.mergedMaskPath = mergedMaskPath
        try saveMetadata(metadata)

        print("[ProjectManager] Saved \(segmentationDataArray.count) segmentations for project \(projectId)")
    }

    /// Load saved segmentation masks from project folder
    /// Returns nil if no saved segmentation data exists
    func loadSegmentationData(for projectId: UUID) -> (
        segmentations: [(id: UUID, name: String, textPrompt: String, selectedIndices: Set<Int>, masks: [(image: NSImage, score: Double, url: URL)])],
        autoDetectedLabel: String?,
        mergedMask: NSImage?
    )? {
        guard let metadata = loadMetadata(for: projectId),
              let savedSegmentations = metadata.segmentations,
              !savedSegmentations.isEmpty else {
            return nil
        }

        let projectDir = PathManager.projectDirectory(for: projectId)
        var restoredSegmentations: [(id: UUID, name: String, textPrompt: String, selectedIndices: Set<Int>, masks: [(image: NSImage, score: Double, url: URL)])] = []

        for segData in savedSegmentations {
            guard let maskPaths = segData.maskPaths, !maskPaths.isEmpty else { continue }

            var masks: [(image: NSImage, score: Double, url: URL)] = []

            for (index, relativePath) in maskPaths.enumerated() {
                let fullPath = projectDir.appendingPathComponent(relativePath)
                if let image = NSImage(contentsOf: fullPath) {
                    // Assign decreasing scores based on order (first mask is best)
                    let score = 1.0 - (Double(index) * 0.1)
                    masks.append((image: image, score: score, url: fullPath))
                }
            }

            if !masks.isEmpty {
                restoredSegmentations.append((
                    id: segData.id,
                    name: segData.name,
                    textPrompt: segData.textPrompt,
                    selectedIndices: Set(segData.selectedMaskIndices),
                    masks: masks
                ))
            }
        }

        // Load merged mask
        var mergedMask: NSImage? = nil
        if let mergedPath = metadata.mergedMaskPath {
            let fullPath = projectDir.appendingPathComponent(mergedPath)
            mergedMask = NSImage(contentsOf: fullPath)
        }

        guard !restoredSegmentations.isEmpty else { return nil }

        print("[ProjectManager] Loaded \(restoredSegmentations.count) segmentations for project \(projectId)")

        return (
            segmentations: restoredSegmentations,
            autoDetectedLabel: metadata.autoDetectedLabel,
            mergedMask: mergedMask
        )
    }

    /// Check if a project has saved segmentation data
    func hasSegmentationData(for projectId: UUID) -> Bool {
        guard let metadata = loadMetadata(for: projectId) else { return false }
        return metadata.hasSegmentationData
    }

    // MARK: - Example Images

    /// Get list of bundled example images (cached)
    func getExampleImages() -> [(name: String, url: URL)] {
        // Return cached if available
        if let cached = cachedExamples {
            return cached
        }

        var examples: [(String, URL)] = []

        if let examplesURL = Bundle.main.url(forResource: "Examples", withExtension: nil) {
            let contents = (try? fileManager.contentsOfDirectory(
                at: examplesURL,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )) ?? []

            for url in contents {
                let ext = url.pathExtension.lowercased()
                if ["png", "jpg", "jpeg"].contains(ext) {
                    let name = url.deletingPathExtension().lastPathComponent
                    examples.append((name, url))
                }
            }
        }

        // Cache the results
        cachedExamples = examples
        return examples
    }
}

// MARK: - Errors

enum ProjectError: LocalizedError {
    case exampleNotFound(String)
    case saveFailed(Error)
    case loadFailed(Error)

    var errorDescription: String? {
        switch self {
        case .exampleNotFound(let name):
            return "Example image '\(name)' not found in bundle"
        case .saveFailed(let error):
            return "Failed to save project: \(error.localizedDescription)"
        case .loadFailed(let error):
            return "Failed to load project: \(error.localizedDescription)"
        }
    }
}
