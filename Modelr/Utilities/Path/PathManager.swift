import os.log
import Foundation

/// Centralized path management for Modelr application
///
/// Organized into sub-namespaces:
/// - `PathManager.Config` - Configuration files and markers
/// - `PathManager.Models` - ML model files (SAM, Hunyuan, VLM)
/// - `PathManager.Environments` - Python virtual environments
/// - `PathManager.Projects` - User project directories
/// - `PathManager.Outputs` - Generated outputs
struct PathManager {

    // MARK: - Sub-Namespaces (Convenience Aliases)

    /// Configuration-related paths
    enum Config {
        static var directory: URL { PathManager.configDirectory }
        static var projectConfig: URL { PathManager.projectConfigPath }
        static var setupMarker: URL { PathManager.setupCompletionMarkerPath }
        static var resourcesMarker: URL { PathManager.resourcesMarkerPath }
        static var environmentMarker: URL { PathManager.environmentMarkerPath }
    }

    /// Model-related paths
    enum Models {
        static var directory: URL { PathManager.modelsDirectory }
        static var hubDirectory: URL { PathManager.modelsHubDirectory }
        static var checkpoints: URL { PathManager.checkpointsDirectory }

        static func isHunyuanDownloaded(variant: String) -> Bool {
            PathManager.isHunyuanModelDownloaded(variant: variant)
        }
    }

    /// Python environment paths
    enum Environments {
        static var directory: URL { PathManager.environmentsDirectory }
        static var sam: URL { PathManager.samEnvironmentDirectory }
        static var hunyuan: URL { PathManager.hunyuanEnvironmentDirectory }
        static var vlm: URL { PathManager.vlmEnvironmentDirectory }
        static var tools: URL { PathManager.toolsEnvironmentDirectory }
    }

    /// Output-related paths
    enum Outputs {
        static var directory: URL { PathManager.outputsDirectory }
        static var models3D: URL { PathManager.outputs3DDirectory }
        static var images: URL { PathManager.outputsImagesDirectory }
    }

    /// Projects-related paths
    enum Projects {
        static var directory: URL { PathManager.projectsDirectory }
    }

    /// Get the application support directory for Modelr
    static var appSupportDirectory: URL {
        guard let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            fatalError("Unable to access Application Support directory")
        }
        return appSupport.appendingPathComponent(AppConstants.appSupportDirectoryName, isDirectory: true)
    }

    /// Legacy app support directory (pre-rename)
    static var legacyAppSupportDirectory: URL {
        guard let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            fatalError("Unable to access Application Support directory")
        }
        return appSupport.appendingPathComponent(AppConstants.legacyAppSupportDirectoryName, isDirectory: true)
    }

    /// Ensure application support directory exists
    static func ensureAppSupportDirectoryExists() throws {
        try migrateLegacyRootDirectoryIfNeeded()
        try SecureFileManager.shared.ensureDirectoryExists(at: appSupportDirectory)

        try SecureFileManager.shared.ensureDirectoryExists(at: binDirectory)
        try SecureFileManager.shared.ensureDirectoryExists(at: pythonRuntimesDirectory)

        try SecureFileManager.shared.ensureDirectoryExists(at: libDirectory)
        try SecureFileManager.shared.ensureDirectoryExists(at: libPythonDirectory)
        try SecureFileManager.shared.ensureDirectoryExists(at: libScriptsDirectory)

        try SecureFileManager.shared.ensureDirectoryExists(at: environmentsDirectory)
        try SecureFileManager.shared.ensureDirectoryExists(at: inferenceEnvironmentDirectory)
        try SecureFileManager.shared.ensureDirectoryExists(at: hunyuanEnvironmentDirectory)
        // Legacy directories (kept for migration)
        try SecureFileManager.shared.ensureDirectoryExists(at: samEnvironmentDirectory)
        try SecureFileManager.shared.ensureDirectoryExists(at: toolsEnvironmentDirectory)
        try SecureFileManager.shared.ensureDirectoryExists(at: vlmEnvironmentDirectory)

        try SecureFileManager.shared.ensureDirectoryExists(at: modelsDirectory)
        try SecureFileManager.shared.ensureDirectoryExists(at: modelsHubDirectory)
        try SecureFileManager.shared.ensureDirectoryExists(at: checkpointsDirectory)

        try SecureFileManager.shared.ensureDirectoryExists(at: outputsDirectory)
        try SecureFileManager.shared.ensureDirectoryExists(at: outputs3DDirectory)
        try SecureFileManager.shared.ensureDirectoryExists(at: outputsImagesDirectory)

        try SecureFileManager.shared.ensureDirectoryExists(at: projectsDirectory)

        try SecureFileManager.shared.ensureDirectoryExists(at: configDirectory)
        try SecureFileManager.shared.ensureDirectoryExists(at: cacheDirectory)
        try SecureFileManager.shared.ensureDirectoryExists(at: uvCacheDirectory)
        try SecureFileManager.shared.ensureDirectoryExists(at: workingDirectory)
        try SecureFileManager.shared.ensureDirectoryExists(at: logsDirectory)
    }

    /// If the legacy root directory exists and the new one doesn't, move it wholesale.
    /// This preserves user data across app renames.
    static func migrateLegacyRootDirectoryIfNeeded() throws {
        let fileManager = FileManager.default
        let legacyRoot = legacyAppSupportDirectory
        let newRoot = appSupportDirectory

        if fileManager.fileExists(atPath: legacyRoot.path), !fileManager.fileExists(atPath: newRoot.path) {
            try fileManager.moveItem(at: legacyRoot, to: newRoot)
        }
    }

    /// App Support subfolder for configuration files
    static var configDirectory: URL {
        appSupportDirectory.appendingPathComponent("Config", isDirectory: true)
    }

    /// Path to the shared project_config.json used by Swift + Python
    static var projectConfigPath: URL {
        configDirectory.appendingPathComponent("project_config.json")
    }

    /// Path to setup completion marker file
    static var setupCompletionMarkerPath: URL {
        configDirectory.appendingPathComponent("setup_complete.json")
    }

    /// Path to bundled-resources marker file.
    ///
    /// This is intentionally separate from setup completion so we can refresh
    /// Python scripts/config on app updates without requiring re-setup.
    static var resourcesMarkerPath: URL {
        configDirectory.appendingPathComponent("resources_version.json")
    }

    /// Path to environment version marker file.
    ///
    /// Tracks the build number when Python environments were last synced.
    /// When build changes, environments need re-syncing but models don't need re-downloading.
    static var environmentMarkerPath: URL {
        configDirectory.appendingPathComponent("environment_version.json")
    }

    /// Check if setup has been completed successfully
    static var isSetupComplete: Bool {
        guard FileManager.default.fileExists(atPath: setupCompletionMarkerPath.path) else {
            return false
        }
        // Verify marker file is valid JSON with expected content
        do {
            let data = try Data(contentsOf: setupCompletionMarkerPath)
            if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
               let complete = json["setup_complete"] as? Bool {
                return complete
            }
        } catch {
            return false
        }
        return false
    }

    /// Mark setup as complete by writing marker file
    static func markSetupComplete(modelVariant: String) throws {
        try ensureDirectoryExists(at: configDirectory)
        let marker: [String: Any] = [
            "setup_complete": true,
            "completed_at": ISO8601DateFormatter().string(from: Date()),
            "model_variant": modelVariant,
            "app_version": currentAppVersion,
            "build_number": currentBuildNumber
        ]
        let data = try JSONSerialization.data(withJSONObject: marker, options: .prettyPrinted)
        try data.write(to: setupCompletionMarkerPath)

        // Also update environment marker to sync with setup completion
        try updateEnvironmentMarker()
    }

    /// Mark setup as complete (default variant)
    static func markSetupComplete() {
        do {
            try markSetupComplete(modelVariant: "mini")
        } catch {
            print("[PathManager] Failed to mark setup complete: \(error)")
        }
    }

    /// Current app version from bundle
    static var currentAppVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
    }

    /// Current build number from bundle
    static var currentBuildNumber: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0"
    }

    /// Check if resources need refreshing (app version changed since setup)
    static var needsResourceRefresh: Bool {
        guard FileManager.default.fileExists(atPath: setupCompletionMarkerPath.path) else {
            return false // No setup done yet
        }
        do {
            let data = try Data(contentsOf: setupCompletionMarkerPath)
            if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
                let storedVersion = json["app_version"] as? String ?? "0.0.0"
                let storedBuild = json["build_number"] as? String ?? "0"
                // Refresh if version or build changed
                return storedVersion != currentAppVersion || storedBuild != currentBuildNumber
            }
        } catch {
            return true // Can't read marker, refresh to be safe
        }
        return false
    }

    /// Check if bundled resources need refreshing (based on app version/build).
    ///
    /// Returns true when the marker is missing (first run) or when version/build changed.
    static var needsBundledResourcesRefresh: Bool {
        guard FileManager.default.fileExists(atPath: resourcesMarkerPath.path) else {
            return true
        }
        do {
            let data = try Data(contentsOf: resourcesMarkerPath)
            if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
                let storedVersion = json["app_version"] as? String ?? "0.0.0"
                let storedBuild = json["build_number"] as? String ?? "0"
                return storedVersion != currentAppVersion || storedBuild != currentBuildNumber
            }
        } catch {
            return true
        }
        return true
    }

    /// Check if Python environments need re-syncing (based on build number).
    ///
    /// Returns true when the marker is missing or when build number changed.
    /// This triggers environment sync without model re-download.
    static var needsEnvironmentRefresh: Bool {
        // Only check if initial setup is complete - don't trigger env refresh before first setup
        guard isSetupComplete else { return false }

        guard FileManager.default.fileExists(atPath: environmentMarkerPath.path) else {
            return true
        }
        do {
            let data = try Data(contentsOf: environmentMarkerPath)
            if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
                let storedBuild = json["build_number"] as? String ?? "0"
                return storedBuild != currentBuildNumber
            }
        } catch {
            return true
        }
        return true
    }

    /// Update bundled-resources marker to current app version/build.
    static func updateResourcesMarker() throws {
        try ensureDirectoryExists(at: configDirectory)
        let marker: [String: Any] = [
            "app_version": currentAppVersion,
            "build_number": currentBuildNumber,
            "resources_updated_at": ISO8601DateFormatter().string(from: Date())
        ]
        let data = try JSONSerialization.data(withJSONObject: marker, options: .prettyPrinted)
        try data.write(to: resourcesMarkerPath)
    }

    /// Update environment marker to current build number.
    static func updateEnvironmentMarker() throws {
        try ensureDirectoryExists(at: configDirectory)
        let marker: [String: Any] = [
            "app_version": currentAppVersion,
            "build_number": currentBuildNumber,
            "environments_synced_at": ISO8601DateFormatter().string(from: Date())
        ]
        let data = try JSONSerialization.data(withJSONObject: marker, options: .prettyPrinted)
        try data.write(to: environmentMarkerPath)
    }

    /// Update the version in setup marker without requiring full re-setup
    static func updateSetupMarkerVersion() throws {
        guard FileManager.default.fileExists(atPath: setupCompletionMarkerPath.path) else { return }
        do {
            let data = try Data(contentsOf: setupCompletionMarkerPath)
            if var json = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
                json["app_version"] = currentAppVersion
                json["build_number"] = currentBuildNumber
                json["resources_updated_at"] = ISO8601DateFormatter().string(from: Date())
                let updatedData = try JSONSerialization.data(withJSONObject: json, options: .prettyPrinted)
                try updatedData.write(to: setupCompletionMarkerPath)
            }
        }
    }

    /// Clear setup completion marker (for re-running setup)
    static func clearSetupMarker() {
        try? FileManager.default.removeItem(at: setupCompletionMarkerPath)
    }

    /// App Support subfolder for binaries and managed runtimes
    static var binDirectory: URL {
        appSupportDirectory.appendingPathComponent("Bin", isDirectory: true)
    }

    /// App Support subfolder for application logic (Python packages + scripts)
    static var libDirectory: URL {
        appSupportDirectory.appendingPathComponent("Lib", isDirectory: true)
    }

    /// Shared Python packages (core, mlx-sam3)
    static var libPythonDirectory: URL {
        libDirectory.appendingPathComponent("python", isDirectory: true)
    }

    /// Wrapper scripts + per-tool pyprojects
    static var libScriptsDirectory: URL {
        libDirectory.appendingPathComponent("scripts", isDirectory: true)
    }

    /// Back-compat alias (old name used in some code)
    static var sharedDirectory: URL {
        libPythonDirectory
    }

    /// App Support subfolder for pure virtual environments
    static var environmentsDirectory: URL {
        appSupportDirectory.appendingPathComponent("Environments", isDirectory: true)
    }

    /// App Support subfolder for pure system caches
    static var cacheDirectory: URL {
        appSupportDirectory.appendingPathComponent("Cache", isDirectory: true)
    }

    /// App Support subfolder for persistent model weights
    static var modelsDirectory: URL {
        appSupportDirectory.appendingPathComponent("Models", isDirectory: true)
    }

    /// Unified HuggingFace/transformers hub cache
    static var modelsHubDirectory: URL {
        modelsDirectory.appendingPathComponent("hub", isDirectory: true)
    }

    /// Persistent checkpoints directory (heavy)
    static var checkpointsDirectory: URL {
        modelsDirectory.appendingPathComponent("checkpoints", isDirectory: true)
    }

    /// App Support subfolder for generated outputs (persistent)
    static var outputsDirectory: URL {
        appSupportDirectory.appendingPathComponent("Outputs", isDirectory: true)
    }

    static var outputs3DDirectory: URL {
        outputsDirectory.appendingPathComponent("3d", isDirectory: true)
    }

    static var outputsImagesDirectory: URL {
        outputsDirectory.appendingPathComponent("images", isDirectory: true)
    }

    /// App Support subfolder for user projects
    static var projectsDirectory: URL {
        appSupportDirectory.appendingPathComponent("Projects", isDirectory: true)
    }

    /// Get the directory for a specific project
    static func projectDirectory(for projectId: UUID) -> URL {
        projectsDirectory.appendingPathComponent(projectId.uuidString, isDirectory: true)
    }

    /// Get the path to a project's manifest file
    static func projectManifestPath(for projectId: UUID) -> URL {
        projectDirectory(for: projectId).appendingPathComponent("project.json")
    }

    /// Get the path to a project's metadata file
    static func projectMetadataPath(for projectId: UUID) -> URL {
        projectDirectory(for: projectId).appendingPathComponent("metadata.json")
    }

    /// Get the path to a project's source image
    static func projectSourceImagePath(for projectId: UUID) -> URL {
        projectDirectory(for: projectId).appendingPathComponent("source.png")
    }

    /// Get the path to a project's thumbnail
    static func projectThumbnailPath(for projectId: UUID) -> URL {
        projectDirectory(for: projectId).appendingPathComponent("thumbnail.png")
    }

    /// Get the path to a project's mask image
    static func projectMaskPath(for projectId: UUID) -> URL {
        projectDirectory(for: projectId).appendingPathComponent("mask.png")
    }

    /// Get the path to a project's generated 3D model (with specific extension)
    static func projectModelPath(for projectId: UUID, extension ext: String = "obj") -> URL {
        projectDirectory(for: projectId).appendingPathComponent("model.\(ext)")
    }

    /// Find existing model file in project (checks for both .obj and .glb)
    static func existingProjectModelPath(for projectId: UUID) -> URL? {
        let objPath = projectModelPath(for: projectId, extension: "obj")
        let glbPath = projectModelPath(for: projectId, extension: "glb")

        if FileManager.default.fileExists(atPath: glbPath.path) {
            return glbPath
        } else if FileManager.default.fileExists(atPath: objPath.path) {
            return objPath
        }
        return nil
    }

    /// App Support subfolder for logs
    static var logsDirectory: URL {
        appSupportDirectory.appendingPathComponent("Logs", isDirectory: true)
    }

    /// App Support subfolder for transient working files
    static var workingDirectory: URL {
        appSupportDirectory.appendingPathComponent("Working", isDirectory: true)
    }

    /// Per-environment directory for SAM worker (venv only)
    static var samEnvironmentDirectory: URL {
        environmentsDirectory.appendingPathComponent("sam", isDirectory: true)
    }

    /// Per-environment directory for mesh tools (venv only)
    static var toolsEnvironmentDirectory: URL {
        environmentsDirectory.appendingPathComponent("tools", isDirectory: true)
    }

    /// Per-environment directory for Hunyuan3D generation (venv only)
    static var hunyuanEnvironmentDirectory: URL {
        environmentsDirectory.appendingPathComponent("hunyuan", isDirectory: true)
    }

    /// Per-environment directory for VLM (venv only)
    /// @deprecated Use inferenceEnvironmentDirectory instead
    static var vlmEnvironmentDirectory: URL {
        environmentsDirectory.appendingPathComponent("vlm", isDirectory: true)
    }

    /// Unified inference environment directory (SAM + VLM + Tools)
    static var inferenceEnvironmentDirectory: URL {
        environmentsDirectory.appendingPathComponent("inference", isDirectory: true)
    }

    /// Get path for unified inference virtual environment
    static var inferenceVenvDirectory: URL {
        inferenceEnvironmentDirectory.appendingPathComponent(AppConstants.venvDirectoryName, isDirectory: true)
    }

    /// Legacy venvDirectory (no longer used)
    static var venvDirectory: URL {
        appSupportDirectory.appendingPathComponent(AppConstants.venvDirectoryName, isDirectory: true)
    }

    /// Project directory for SAM (scripts + pyproject)
    static var samProjectDirectory: URL {
        libScriptsDirectory.appendingPathComponent("sam", isDirectory: true)
    }

    /// Project directory for Hunyuan (scripts + pyproject)
    static var hunyuanProjectDirectory: URL {
        libScriptsDirectory.appendingPathComponent("hunyuan", isDirectory: true)
    }

    /// Project directory for Tools (scripts + pyproject)
    static var toolsProjectDirectory: URL {
        libScriptsDirectory.appendingPathComponent("tools", isDirectory: true)
    }

    /// Project directory for VLM (scripts + pyproject)
    /// @deprecated Use inferenceProjectDirectory instead
    static var vlmProjectDirectory: URL {
        libScriptsDirectory.appendingPathComponent("vlm", isDirectory: true)
    }

    /// Unified inference project directory (SAM + VLM + Tools scripts + pyproject)
    static var inferenceProjectDirectory: URL {
        libScriptsDirectory.appendingPathComponent("inference", isDirectory: true)
    }

    /// Get path for inference pyproject file
    static var inferencePyprojectPath: URL {
        inferenceProjectDirectory.appendingPathComponent("pyproject.toml")
    }

    /// Back-compat: treat hunyuanDirectory as the *project* dir (where uv runs)
    static var hunyuanDirectory: URL {
        hunyuanProjectDirectory
    }

    /// Get path for Hunyuan3D virtual environment
    static var hunyuanVenvDirectory: URL {
        hunyuanEnvironmentDirectory.appendingPathComponent(AppConstants.venvDirectoryName, isDirectory: true)
    }

    /// Get path for Python runtimes directory
    static var pythonRuntimesDirectory: URL {
        binDirectory.appendingPathComponent("python", isDirectory: true)
    }

    /// Get path for UV cache directory
    static var uvCacheDirectory: URL {
        cacheDirectory.appendingPathComponent("uv", isDirectory: true)
    }

    /// Get path for SAM wrapper script
    static var samWrapperPath: URL {
        samProjectDirectory.appendingPathComponent(AppConstants.samWrapperFileName)
    }

    /// Get path for Hunyuan wrapper script
    static var hunyuanWrapperPath: URL {
        hunyuanProjectDirectory.appendingPathComponent(AppConstants.hunyuanWrapperFileName)
    }

    /// Get path for VLM wrapper script
    static var vlmWrapperPath: URL {
        vlmProjectDirectory.appendingPathComponent(AppConstants.vlmWrapperFileName)
    }

    /// Get path for T2I wrapper script
    static var t2iWrapperPath: URL {
        inferenceProjectDirectory.appendingPathComponent("t2i_wrapper.py")
    }

    /// Get path for SAM pyproject file
    static var samPyprojectPath: URL {
        samProjectDirectory.appendingPathComponent(AppConstants.samPyprojectFileName)
    }

    /// Get path for Hunyuan pyproject file in Hunyuan directory
    static var hunyuanPyprojectPath: URL {
        hunyuanProjectDirectory.appendingPathComponent(AppConstants.hunyuanPyprojectFileName)
    }

    /// Get path for VLM pyproject file
    static var vlmPyprojectPath: URL {
        vlmProjectDirectory.appendingPathComponent(AppConstants.vlmPyprojectFileName)
    }

    /// Get path for VLM virtual environment
    static var vlmVenvDirectory: URL {
        vlmEnvironmentDirectory.appendingPathComponent(AppConstants.venvDirectoryName, isDirectory: true)
    }

    /// Get path for mask file
    static var maskFilePath: URL {
        workingDirectory.appendingPathComponent(AppConstants.maskFileName)
    }

    /// Get path for temporary drop file
    static var tempDropFilePath: URL {
        workingDirectory.appendingPathComponent(AppConstants.tempDropFileName)
    }

    /// Get path for backend working copy file
    static var backendWorkingCopyFilePath: URL {
        workingDirectory.appendingPathComponent(AppConstants.backendWorkingCopyFileName)
    }

    /// Get path for generated 3D model with descriptive filename
    /// - Parameters:
    ///   - variant: Model variant ("mini" or "std")
    ///   - steps: Number of diffusion steps
    ///   - resolution: Octree resolution
    ///   - guidanceScale: Guidance scale (optional, included if non-default)
    ///   - boxV: Bounding box scale (optional, included if non-default)
    ///   - mcLevel: Surface level (optional, included if non-default)
    static func generatedModelPath(
        variant: String = "mini",
        steps: Int = 35,
        resolution: Int = 256,
        guidanceScale: Double? = nil,
        boxV: Double? = nil,
        mcLevel: Double? = nil
    ) -> URL {
        let timestamp = Int(Date().timeIntervalSince1970)
        let variantName = variant == "std" ? "Standard" : "Mini"

        // Build filename parts
        var parts = [AppConstants.generatedModelPrefix.trimmingCharacters(in: CharacterSet(charactersIn: "_"))]
        parts.append(variantName)
        parts.append("\(steps)s")
        parts.append("\(resolution)px")

        // Add non-default advanced settings
        if let cfg = guidanceScale, cfg != 5.0 {
            parts.append("cfg\(String(format: "%.1f", cfg))")
        }
        if let box = boxV, box != 1.01 {
            parts.append("box\(String(format: "%.2f", box))")
        }
        if let mc = mcLevel, mc != 0.0 {
            parts.append("mc\(String(format: "%.2f", mc))")
        }

        parts.append("\(timestamp)")

        let filename = parts.joined(separator: "_") + ".obj"
        return outputs3DDirectory.appendingPathComponent(filename)
    }

    /// Get path for a specific generated 3D model (legacy)
    static func generatedModelPath(timestamp: Int) -> URL {
        return outputs3DDirectory.appendingPathComponent("\(AppConstants.generatedModelPrefix)\(timestamp).obj")
    }

    /// Best-effort migration from older flat layout into the newer organized layout.
    /// This intentionally only moves well-known items; unknown files are left untouched.
    static func migrateLegacyLayoutIfNeeded() throws {
        let fileManager = FileManager.default
        try migrateLegacyRootDirectoryIfNeeded()
        try ensureAppSupportDirectoryExists()

        func mergeMoveContents(from sourceDir: URL, to destinationDir: URL) throws {
            var isDir: ObjCBool = false
            guard fileManager.fileExists(atPath: sourceDir.path, isDirectory: &isDir), isDir.boolValue else {
                return
            }
            try? SecureFileManager.shared.ensureDirectoryExists(at: destinationDir)

            let items = try fileManager.contentsOfDirectory(at: sourceDir, includingPropertiesForKeys: nil)
            for item in items {
                let dst = destinationDir.appendingPathComponent(item.lastPathComponent)
                if fileManager.fileExists(atPath: dst.path) {
                    continue
                }
                try fileManager.moveItem(at: item, to: dst)
            }

            // Clean up empty legacy directories.
            let remaining = (try? fileManager.contentsOfDirectory(atPath: sourceDir.path)) ?? []
            if remaining.isEmpty {
                try? fileManager.removeItem(at: sourceDir)
            }
        }

        // Shared -> Lib/python
        let legacyShared = appSupportDirectory.appendingPathComponent("Shared", isDirectory: true)
        try? mergeMoveContents(from: legacyShared, to: libPythonDirectory)

        // Cache/python_runtimes -> Bin/python
        let legacyRuntimes = appSupportDirectory
            .appendingPathComponent("Cache", isDirectory: true)
            .appendingPathComponent(AppConstants.pythonRuntimesDirectoryName, isDirectory: true)
        try? mergeMoveContents(from: legacyRuntimes, to: pythonRuntimesDirectory)

        // Cache/uv_cache -> Cache/uv
        let legacyUvCache = appSupportDirectory
            .appendingPathComponent("Cache", isDirectory: true)
            .appendingPathComponent(AppConstants.uvCacheDirectoryName, isDirectory: true)
        try? mergeMoveContents(from: legacyUvCache, to: uvCacheDirectory)

        // Root checkpoints -> Models/checkpoints
        let legacyCheckpoints = appSupportDirectory.appendingPathComponent(AppConstants.checkpointsDirectoryName, isDirectory: true)
        try? mergeMoveContents(from: legacyCheckpoints, to: checkpointsDirectory)

        // Consolidate legacy HF caches under Models/hub (best-effort, non-destructive)
        let legacyCacheRoot = appSupportDirectory.appendingPathComponent("Cache", isDirectory: true)
        let legacySamCache = legacyCacheRoot.appendingPathComponent("sam_cache", isDirectory: true)
        let legacyHfCache = legacyCacheRoot.appendingPathComponent(AppConstants.hunyuanCacheDirectoryName, isDirectory: true)
        if fileManager.fileExists(atPath: legacySamCache.path) {
            let dst = modelsHubDirectory.appendingPathComponent("legacy_sam_cache", isDirectory: true)
            if !fileManager.fileExists(atPath: dst.path) {
                try? fileManager.moveItem(at: legacySamCache, to: dst)
            }
        }
        if fileManager.fileExists(atPath: legacyHfCache.path) {
            let dst = modelsHubDirectory.appendingPathComponent("legacy_hf_cache", isDirectory: true)
            if !fileManager.fileExists(atPath: dst.path) {
                try? fileManager.moveItem(at: legacyHfCache, to: dst)
            }
        }

        // Move legacy project_config.json into Config/
        let legacyConfig = appSupportDirectory.appendingPathComponent("project_config.json")
        if fileManager.fileExists(atPath: legacyConfig.path), !fileManager.fileExists(atPath: projectConfigPath.path) {
            try fileManager.moveItem(at: legacyConfig, to: projectConfigPath)
        }

        // Quarantine common legacy clutter into Legacy/ to keep the root clean.
        let legacyDir = appSupportDirectory.appendingPathComponent("Legacy", isDirectory: true)
        try? SecureFileManager.shared.ensureDirectoryExists(at: legacyDir)
        let quarantineNames: [String] = [
            "device_utils.py",
            "logging_config.py",
            "model_downloader.py",
            "test_e2e_sam.py",
            "test_sam_wrapper.py",
            "__pycache__",
            "modelr_backend.egg-info",
            "modelr_sam.egg-info",
            "uv"
        ]
        for name in quarantineNames {
            let source = appSupportDirectory.appendingPathComponent(name)
            let dest = legacyDir.appendingPathComponent(name)
            if fileManager.fileExists(atPath: source.path), !fileManager.fileExists(atPath: dest.path) {
                try? fileManager.moveItem(at: source, to: dest)
            }
        }
    }

    /// Check if a file exists at the given path
    static func fileExists(at url: URL) -> Bool {
        return SecureFileManager.shared.fileExists(at: url)
    }

    /// Ensure a directory exists at the given path
    static func ensureDirectoryExists(at url: URL) throws {
        try SecureFileManager.shared.ensureDirectoryExists(at: url)
    }

    /// Remove a file or directory if it exists
    static func removeIfExists(at url: URL) throws {
        try SecureFileManager.shared.removeIfExists(at: url)
    }

    /// Copy a file from source to destination, removing destination first if it exists
    static func copyFile(from source: URL, to destination: URL) throws {
        try SecureFileManager.shared.copyFile(from: source, to: destination)
    }

    /// Get UV binary path from bundle
    static func uvBinaryPath(resourcePathOverride: String? = nil) -> String? {
        if let override = resourcePathOverride {
            return (override as NSString).appendingPathComponent("uv")
        }

        var uvPath = Bundle.main.path(forResource: "uv", ofType: nil)
        if uvPath == nil {
            uvPath = Bundle.main.path(forResource: "uv", ofType: nil, inDirectory: "Resources")
        }
        return uvPath
    }

    /// Calculate the size of a directory asynchronously using 'du'
    static func getDirectorySize(_ url: URL) async -> Int64 {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let process = Process()
                let pipe = Pipe()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/du")
                process.arguments = ["-sk", url.path]
                process.standardOutput = pipe
                process.standardError = nil

                do {
                    try process.run()
                    process.waitUntilExit()
                    let data = pipe.fileHandleForReading.readDataToEndOfFile()
                    if let output = String(data: data, encoding: .utf8),
                       let sizeStr = output.split(separator: "\t").first,
                       let sizeKB = Int64(sizeStr) {
                        continuation.resume(returning: sizeKB * 1024)
                    } else {
                        continuation.resume(returning: 0)
                    }
                } catch {
                    continuation.resume(returning: 0)
                }
            }
        }
    }

    /// Check if a Hunyuan3D model variant is downloaded
    /// - Parameter variant: "mini" for Hunyuan3D-2mini, "std" for Hunyuan3D-2.1
    static func isHunyuanModelDownloaded(variant: String) -> Bool {
        let modelDirName: String
        switch variant {
        case "std":
            modelDirName = "models--tencent--Hunyuan3D-2.1"
        default:
            modelDirName = "models--tencent--Hunyuan3D-2mini"
        }

        // When Swift sets HUGGINGFACE_HUB_CACHE to Models/hub, the models--... dirs are created directly under that folder.
        // Also allow the HF_HOME default layout (Models/hub/hub) and legacy locations.
        let directHub = modelsHubDirectory
        let hfHomeStyleHub = modelsHubDirectory.appendingPathComponent("hub", isDirectory: true)
        let legacyHub1 = appSupportDirectory.appendingPathComponent("Cache", isDirectory: true).appendingPathComponent("legacy_hf_cache", isDirectory: true)
        let legacyHub2 = appSupportDirectory.appendingPathComponent("Cache", isDirectory: true).appendingPathComponent(AppConstants.hunyuanCacheDirectoryName, isDirectory: true)

        return checkModelExists(dirName: modelDirName, in: directHub)
            || checkModelExists(dirName: modelDirName, in: hfHomeStyleHub)
            || checkModelExists(dirName: modelDirName, in: legacyHub1)
            || checkModelExists(dirName: modelDirName, in: legacyHub2)
    }

    /// Check if Hunyuan 2.1 (standard/larger) model is downloaded
    static var isHunyuan21Downloaded: Bool {
        isHunyuanModelDownloaded(variant: "std")
    }

    /// Check if Stable Diffusion 1.5 model is downloaded (for T2I)
    static var isT2IModelDownloaded: Bool {
        // SD 1.5 model ID: stable-diffusion-v1-5/stable-diffusion-v1-5
        let modelDirName = "models--stable-diffusion-v1-5--stable-diffusion-v1-5"
        let directHub = modelsHubDirectory
        let hfHomeStyleHub = modelsHubDirectory.appendingPathComponent("hub", isDirectory: true)

        return checkModelExists(dirName: modelDirName, in: directHub)
            || checkModelExists(dirName: modelDirName, in: hfHomeStyleHub)
    }

    private static func checkModelExists(dirName: String, in parentDir: URL) -> Bool {
        let fileManager = FileManager.default
        let modelPath = parentDir.appendingPathComponent(dirName)

        guard fileManager.fileExists(atPath: modelPath.path) else {
            return false
        }

        // Check for snapshots directory with actual model weight files
        // Mini models use .safetensors, Standard (2.1) uses .ckpt files
        let snapshotsDir = modelPath.appendingPathComponent("snapshots")
        if fileManager.fileExists(atPath: snapshotsDir.path) {
            // Look for any snapshot hash directory containing model weight files
            if let snapshots = try? fileManager.contentsOfDirectory(atPath: snapshotsDir.path) {
                for snapshot in snapshots {
                    let snapshotPath = snapshotsDir.appendingPathComponent(snapshot)
                    if let files = try? fileManager.contentsOfDirectory(atPath: snapshotPath.path) {
                        // Check for model weights in root or subdirectories
                        for file in files {
                            // Check for .safetensors (Mini) or .ckpt (Standard 2.1)
                            if file.hasSuffix(".safetensors") || file.hasSuffix(".ckpt") {
                                return true
                            }
                            // Check subdirectories (like hunyuan3d-dit-v2-1)
                            let subPath = snapshotPath.appendingPathComponent(file)
                            var isDir: ObjCBool = false
                            if fileManager.fileExists(atPath: subPath.path, isDirectory: &isDir), isDir.boolValue {
                                if let subFiles = try? fileManager.contentsOfDirectory(atPath: subPath.path) {
                                    if subFiles.contains(where: { $0.hasSuffix(".safetensors") || $0.hasSuffix(".ckpt") }) {
                                        return true
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }

        return false
    }
}
