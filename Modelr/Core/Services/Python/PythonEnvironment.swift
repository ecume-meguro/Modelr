import Foundation

/// Centralized Python environment variable configuration
/// Eliminates duplicate environment variable setup across process managers
enum PythonEnvConfig {

    /// Base environment variables common to all Python processes
    static func baseEnvironment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment

        // UV configuration
        env["UV_PYTHON_INSTALL_DIR"] = PathManager.pythonRuntimesDirectory.path
        env["UV_CACHE_DIR"] = PathManager.uvCacheDirectory.path
        env["UV_PYTHON_PREFERENCE"] = "only-managed"
        env["UV_LINK_MODE"] = "copy"

        // Python settings
        env["PYTHONUNBUFFERED"] = "1"

        // HuggingFace configuration
        env["HF_HOME"] = PathManager.modelsDirectory.path
        env["HUGGINGFACE_HUB_CACHE"] = PathManager.modelsHubDirectory.path
        env["TRANSFORMERS_CACHE"] = PathManager.modelsHubDirectory.path

        // Modelr directories
        env["MODELR_CONFIG_PATH"] = PathManager.projectConfigPath.path
        env["MODELR_OUTPUTS_DIR"] = PathManager.outputsDirectory.path
        env["MODELR_WORKING_DIR"] = PathManager.workingDirectory.path
        env["MODELR_LOGS_DIR"] = PathManager.logsDirectory.path
        env["MODELR_CHECKPOINTS_DIR"] = PathManager.checkpointsDirectory.path
        env["MODELR_MODELS_DIR"] = PathManager.modelsDirectory.path

        return env
    }

    /// Environment for inference processes (SAM, VLM)
    /// - Parameter venvPath: Path to the inference virtual environment
    static func inferenceEnvironment(venvPath: URL) -> [String: String] {
        var env = baseEnvironment()
        env["UV_PROJECT_ENVIRONMENT"] = venvPath.path

        // PYTHONPATH for inference
        let pythonPathEntries = [
            PathManager.inferenceProjectDirectory.path,
            PathManager.libPythonDirectory.path
        ]
        env["PYTHONPATH"] = pythonPathEntries.joined(separator: ":")

        return env
    }

    /// Environment for Hunyuan generation processes
    /// - Parameter venvPath: Path to the Hunyuan virtual environment
    static func hunyuanEnvironment(venvPath: URL) -> [String: String] {
        var env = baseEnvironment()
        env["UV_PROJECT_ENVIRONMENT"] = venvPath.path

        // PYTHONPATH for Hunyuan
        let pythonPathEntries = [
            PathManager.hunyuanProjectDirectory.path,
            PathManager.libPythonDirectory.path
        ]
        env["PYTHONPATH"] = pythonPathEntries.joined(separator: ":")

        return env
    }

    /// Environment for mesh tools processes
    /// - Parameter venvPath: Path to the tools virtual environment
    static func toolsEnvironment(venvPath: URL) -> [String: String] {
        var env = baseEnvironment()
        env["UV_PROJECT_ENVIRONMENT"] = venvPath.path

        let pythonPathEntries = [
            PathManager.toolsProjectDirectory.path,
            PathManager.libPythonDirectory.path
        ]
        env["PYTHONPATH"] = pythonPathEntries.joined(separator: ":")

        return env
    }

    /// Environment for setup/dependency operations (adds HF transfer optimization)
    /// - Parameters:
    ///   - venvPath: Path to the virtual environment being set up
    ///   - modelsHubDir: Override for the models hub directory
    static func setupEnvironment(venvPath: URL, modelsHubDir: URL? = nil) -> [String: String] {
        var env = baseEnvironment()
        env["UV_PROJECT_ENVIRONMENT"] = venvPath.path
        env["HF_HUB_ENABLE_HF_TRANSFER"] = "1"  // High-speed downloads
        env["MODELR_APP_SUPPORT_DIR"] = PathManager.appSupportDirectory.path
        env["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin"

        if let hubDir = modelsHubDir {
            env["HUGGINGFACE_HUB_CACHE"] = hubDir.path
            env["TRANSFORMERS_CACHE"] = hubDir.path
        }

        let pythonPathEntries = [
            venvPath.deletingLastPathComponent().path,
            PathManager.libPythonDirectory.path
        ]
        env["PYTHONPATH"] = pythonPathEntries.joined(separator: ":")

        return env
    }
}
