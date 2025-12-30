import Foundation

/// Centralized path management for ModelrV3 application
struct PathManager {
    
    /// File manager instance
    private static let fileManager = FileManager.default
    
    /// Get the application support directory for ModelrV3
    static var appSupportDirectory: URL {
        guard let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            fatalError("Unable to access Application Support directory")
        }
        return appSupport.appendingPathComponent(AppConstants.appSupportDirectoryName, isDirectory: true)
    }
    
    /// Ensure application support directory exists
    static func ensureAppSupportDirectoryExists() throws {
        try fileManager.createDirectory(at: appSupportDirectory, withIntermediateDirectories: true)
    }
    
    /// Get path for virtual environment directory
    static var venvDirectory: URL {
        appSupportDirectory.appendingPathComponent(AppConstants.venvDirectoryName, isDirectory: true)
    }
    
    /// Get path for Hunyuan3D directory
    static var hunyuanDirectory: URL {
        appSupportDirectory.appendingPathComponent(AppConstants.hunyuanDirectoryName, isDirectory: true)
    }
    
    /// Get path for Hunyuan3D virtual environment
    static var hunyuanVenvDirectory: URL {
        hunyuanDirectory.appendingPathComponent(AppConstants.venvDirectoryName, isDirectory: true)
    }
    
    /// Get path for checkpoints directory
    static var checkpointsDirectory: URL {
        appSupportDirectory.appendingPathComponent(AppConstants.checkpointsDirectoryName, isDirectory: true)
    }
    
    /// Get path for Python runtimes directory
    static var pythonRuntimesDirectory: URL {
        appSupportDirectory.appendingPathComponent(AppConstants.pythonRuntimesDirectoryName, isDirectory: true)
    }
    
    /// Get path for UV cache directory
    static var uvCacheDirectory: URL {
        appSupportDirectory.appendingPathComponent(AppConstants.uvCacheDirectoryName, isDirectory: true)
    }
    
    /// Get path for Hunyuan cache directory
    static var hunyuanCacheDirectory: URL {
        hunyuanDirectory.appendingPathComponent(AppConstants.hunyuanCacheDirectoryName, isDirectory: true)
    }
    
    /// Get path for SAM wrapper script
    static var samWrapperPath: URL {
        appSupportDirectory.appendingPathComponent(AppConstants.samWrapperFileName)
    }
    
    /// Get path for Hunyuan wrapper script
    static var hunyuanWrapperPath: URL {
        hunyuanDirectory.appendingPathComponent(AppConstants.hunyuanWrapperFileName)
    }
    
    /// Get path for SAM pyproject file
    static var samPyprojectPath: URL {
        appSupportDirectory.appendingPathComponent(AppConstants.samPyprojectFileName)
    }
    
    /// Get path for Hunyuan pyproject file in Hunyuan directory
    static var hunyuanPyprojectPath: URL {
        hunyuanDirectory.appendingPathComponent(AppConstants.hunyuanPyprojectFileName)
    }
    
    /// Get path for self-test image
    static var selfTestImagePath: URL {
        appSupportDirectory.appendingPathComponent(AppConstants.selfTestImageFileName)
    }
    
    /// Get path for correct self-test mask
    static var correctSelfTestMaskPath: URL {
        appSupportDirectory.appendingPathComponent(AppConstants.correctSelfTestMaskFileName)
    }
    
    /// Get path for self-test 3D model
    static var selfTestModelPath: URL {
        hunyuanDirectory.appendingPathComponent(AppConstants.selfTestModelFileName)
    }
    
    /// Get path for mask file
    static var maskFilePath: URL {
        appSupportDirectory.appendingPathComponent(AppConstants.maskFileName)
    }
    
    /// Get path for temporary drop file
    static var tempDropFilePath: URL {
        appSupportDirectory.appendingPathComponent(AppConstants.tempDropFileName)
    }
    
    /// Get path for backend working copy file
    static var backendWorkingCopyFilePath: URL {
        appSupportDirectory.appendingPathComponent(AppConstants.backendWorkingCopyFileName)
    }
    
    /// Get path for generated 3D model with timestamp
    static func generatedModelPath() -> URL {
        let timestamp = Int(Date().timeIntervalSince1970)
        return hunyuanDirectory.appendingPathComponent("\(AppConstants.generatedModelPrefix)\(timestamp).obj")
    }
    
    /// Get path for a specific generated 3D model
    static func generatedModelPath(timestamp: Int) -> URL {
        return hunyuanDirectory.appendingPathComponent("\(AppConstants.generatedModelPrefix)\(timestamp).obj")
    }
    
    /// Check if a file exists at the given path
    static func fileExists(at url: URL) -> Bool {
        return fileManager.fileExists(atPath: url.path)
    }
    
    /// Ensure a directory exists at the given path
    static func ensureDirectoryExists(at url: URL) throws {
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
    }
    
    /// Remove a file or directory if it exists
    static func removeIfExists(at url: URL) throws {
        if fileManager.fileExists(atPath: url.path) {
            try fileManager.removeItem(at: url)
        }
    }
    
    /// Copy a file from source to destination, removing destination first if it exists
    static func copyFile(from source: URL, to destination: URL) throws {
        try removeIfExists(at: destination)
        try fileManager.copyItem(at: source, to: destination)
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
    
    /// Check if self-test setup is complete
    static func isSelfTestSetupComplete() -> Bool {
        return fileExists(at: samWrapperPath) &&
               fileExists(at: hunyuanWrapperPath) &&
               fileExists(at: venvDirectory.appendingPathComponent("bin/python")) &&
               fileExists(at: hunyuanVenvDirectory.appendingPathComponent("bin/python"))
    }
}
