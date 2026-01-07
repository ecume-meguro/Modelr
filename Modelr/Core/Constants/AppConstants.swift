import Foundation
import SwiftUI

/// Centralized constants for the Modelr application
struct AppConstants {
    
    // MARK: - UI Constants
    
    /// Default display height for images in points
    static let defaultDisplayHeight: CGFloat = 600
    
    /// Default brush size as percentage of image width
    static let defaultBrushSize: CGFloat = 0.03
    
    /// Opacity for mask overlay (0-1)
    static let maskOpacity: Double = 0.6
    
    /// Minimum pixel distance between lasso points to add new point (~0.3% of image)
    static let minPixelDistance: CGFloat = 0.003
    
    /// Minimum distance between paint stroke points (~0.5% of image)
    static let minStrokeDistance: CGFloat = 0.005
    
    // MARK: - Colors
    
    /// SAM2 mask color (blue-ish purple)
    static let sam2MaskColor = Color(red: 50/255, green: 100/255, blue: 200/255)
    
    /// Color for point markers
    static let pointMarkerColor = Color.pink
    
    /// Color for delete/erase operations
    static let deleteColor = Color.red
    
    /// Window background color
    static let windowBackgroundColor = Color(NSColor.windowBackgroundColor)
    
    /// Background color for image area
    static let imageAreaBackgroundColor = Color(NSColor.windowBackgroundColor).opacity(0.5)
    
    // MARK: - Performance Limits
    
    /// Maximum dimension for image processing
    static var maxImageDimension: Int {
        ConfigurationService.shared.maxImageDimension
    }
    
    /// Maximum file size for images (100 MB)
    static var maxImageFileSize: UInt64 {
        UInt64(ConfigurationService.shared.config?.limits.maxImageFileSizeMb ?? 100) * 1024 * 1024
    }
    
    /// Maximum file size for 3D models (2 GB)
    static let maxModelFileSize: UInt64 = 2 * 1024 * 1024 * 1024
    
    // MARK: - Validation Thresholds
    
    /// Minimum bounding box size as percentage of image (1%)
    static let minBoxSize: CGFloat = 0.01
    
    /// Threshold for mask similarity comparison (90%)
    static let maskSimilarityThreshold: Double = 0.90
    
    /// Alpha threshold for determining if a pixel has content
    static let alphaThreshold: CGFloat = 0.1
    
    // MARK: - Timeouts
    
    /// Timeout for worker startup in seconds
    static let workerStartupTimeout: TimeInterval = 30
    
    /// Animation duration for UI transitions
    static let animationDuration: TimeInterval = 0.3
    
    /// Spring response duration for animations
    static let springResponse: TimeInterval = 0.3
    
    /// Duration for short fade animations
    static let shortFadeDuration: TimeInterval = 0.1
    
    // MARK: - Zoom Controls
    
    /// Minimum zoom magnification
    static let minMagnification: CGFloat = 0.1
    
    /// Maximum zoom magnification
    static let maxMagnification: CGFloat = 20.0
    
    /// Zoom factor for zoom in/out
    static let zoomFactor: CGFloat = 1.5
    
    /// Threshold for considering magnification unchanged
    static let magnificationThreshold: CGFloat = 0.01
    
    // MARK: - Brush Settings
    
    /// Minimum brush size as percentage of image width
    static let minBrushSize: CGFloat = 0.01
    
    /// Maximum brush size as percentage of image width
    static let maxBrushSize: CGFloat = 0.15
    
    /// Step size for brush size slider
    static let brushSizeStep: CGFloat = 0.005
    
    // MARK: - Generation Parameters
    
    /// Minimum diffusion steps
    static let minDiffusionSteps: Double = 10
    
    /// Maximum diffusion steps
    static let maxDiffusionSteps: Double = 256
    
    /// Default diffusion steps
    static var defaultDiffusionSteps: Double {
        Double(ConfigurationService.shared.defaultSteps)
    }
    
    /// Minimum mesh resolution
    static let minMeshResolution: Double = 128
    
    /// Maximum mesh resolution
    static let maxMeshResolution: Double = 1024
    
    /// Default mesh resolution
    static var defaultMeshResolution: Double {
        Double(ConfigurationService.shared.defaultResolution)
    }
    
    /// Step size for resolution slider
    static let resolutionStep: Double = 64
    
    // MARK: - Dimensions
    
    /// Point marker size
    static let pointMarkerSize: CGFloat = 14
    
    /// Point marker outer ring width
    static let pointMarkerOuterRingWidth: CGFloat = 4
    
    /// Bounding box line width
    static let boundingBoxLineWidth: CGFloat = 2
    
    /// Bounding box dash pattern
    static let boundingBoxDashPattern: [CGFloat] = [6, 4]
    
    /// Lasso line width for current selection
    static let lassoCurrentLineWidth: CGFloat = 2
    
    /// Lasso line width for completed selection
    static let lassoCompletedLineWidth: CGFloat = 1.5
    
    /// Lasso dot size for current selection
    static let lassoCurrentDotSize: CGFloat = 4
    
    /// Lasso dot size for completed selection
    static let lassoCompletedDotSize: CGFloat = 3
    
    /// Crop overlay opacity
    static let cropOverlayOpacity: Double = 0.5
    
    /// Crop border line width
    static let cropBorderLineWidth: CGFloat = 2
    
    /// Crop border dash pattern
    static let cropBorderDashPattern: [CGFloat] = [8, 4]
    
    /// Crop handle size
    static let cropHandleSize: CGFloat = 12
    
    // MARK: - Window Sizes
    
    /// Minimum window width
    static let minWindowWidth: CGFloat = 1000
    
    /// Minimum window height
    static let minWindowHeight: CGFloat = 700
    
    /// Minimum sidebar width
    static let minSidebarWidth: CGFloat = 320

    /// Maximum sidebar width
    static let maxSidebarWidth: CGFloat = 420
    
    /// Minimum image area width
    static let minImageAreaWidth: CGFloat = 500
    
    // MARK: - 3D Viewer
    
    /// 3D model container corner radius
    static let model3DContainerCornerRadius: CGFloat = 12
    
    /// 3D model background color
    static let model3DBackgroundColor = NSColor(calibratedWhite: 0.15, alpha: 1.0)
    
    /// 3D model scaling factor to fit in 2-unit box
    static let model3DScaleFactor: Float = 2.0
    
    /// 3D camera field of view
    static let model3DCameraFOV: CGFloat = 45
    
    /// 3D camera distance from origin
    static let model3DCameraDistance: Float = 5.0
    
    /// 3D camera near z-range
    static let model3DCameraZNear: CGFloat = 0.01
    
    /// 3D camera far z-range
    static let model3DCameraZFar: CGFloat = 1000
    
    /// 3D maximum vertical angle
    static let model3DMaxVerticalAngle: CGFloat = 89
    
    /// 3D minimum vertical angle
    static let model3DMinVerticalAngle: CGFloat = -89
    
    /// 3D camera inertia friction
    static let model3DInertiaFriction: CGFloat = 0.9
    
    // MARK: - Progress Bar
    
    /// Progress bar height
    static let progressBarHeight: CGFloat = 12
    
    /// Progress bar corner radius
    static let progressBarCornerRadius: CGFloat = 6
    
    /// Progress bar animation duration
    static let progressBarAnimationDuration: TimeInterval = 0.3
    
    // MARK: - File Extensions
    
    /// Supported image file extensions
    static let supportedImageExtensions = ["png", "jpg", "jpeg", "bmp", "webp", "tiff"]
    
    // MARK: - Directory Names
    
    /// Name of application support directory
    static let appSupportDirectoryName = "Modelr"

    /// Legacy application support directory name (pre-rename)
    static let legacyAppSupportDirectoryName = "ModelrV3"
    
    /// Name of virtual environment directory
    static let venvDirectoryName = ".venv"
    
    /// Name of Hunyuan3D directory
    static let hunyuanDirectoryName = "Hunyuan3D"
    
    /// Name of checkpoints directory
    static let checkpointsDirectoryName = "checkpoints"
    
    /// Name of Python runtimes directory
    static let pythonRuntimesDirectoryName = "python_runtimes"
    
    /// Name of UV cache directory
    static let uvCacheDirectoryName = "uv_cache"
    
    /// Name of Hunyuan cache directory
    static let hunyuanCacheDirectoryName = "hf_cache"
    
    // MARK: - File Names
    
    /// Name of temporary drop file
    static let tempDropFileName = "temp_drop.png"
    
    /// Name of backend working copy file
    static let backendWorkingCopyFileName = "backend_working_copy.png"
    
    /// Name of mask file
    static let maskFileName = "mask.png"
    
    /// Name of SAM wrapper script
    static let samWrapperFileName = "sam_wrapper.py"
    
    /// Name of Hunyuan wrapper script
    static let hunyuanWrapperFileName = "hunyuan_wrapper.py"
    
    /// Name of SAM pyproject file
    static let samPyprojectFileName = "pyproject.toml"
    
    /// Name of Hunyuan pyproject file
    static let hunyuanPyprojectFileName = "pyproject_hunyuan.toml"
    
    /// Prefix for generated 3D models
    static let generatedModelPrefix = "generated_model_"
    
    // MARK: - Model Selection

    /// Default SAM2 model variant
    static let defaultSAMModel = "base_plus"

    /// Python version for SAM2
    static let samPythonVersion = "3.12"

    /// Python version for Hunyuan3D
    static let hunyuanPythonVersion = "3.10"

    // MARK: - Memory Management

    /// Threshold for aggressive model loading (both models loaded simultaneously)
    /// Systems with >= 16GB RAM use aggressive loading, < 16GB use conservative loading
    static let aggressiveLoadingRAMThreshold: UInt64 = 16 * 1024 * 1024 * 1024  // 16GB

    /// Get system physical memory in bytes
    static var systemRAM: UInt64 {
        ProcessInfo.processInfo.physicalMemory
    }

    /// Check if system has enough RAM for aggressive model loading
    static var canUseAggressiveLoading: Bool {
        systemRAM >= aggressiveLoadingRAMThreshold
    }

    /// Formatted system RAM string for display
    static var formattedSystemRAM: String {
        ByteCountFormatter.string(fromByteCount: Int64(systemRAM), countStyle: .memory)
    }

    // MARK: - Image Processing (pixel-level)

    /// Sample step divider for alpha channel checking (controls sampling density)
    static let alphaCheckSampleStepDivider: Int = 10000

    /// Alpha threshold for considering a pixel "nearly opaque" (0-255)
    static let imageAlphaThreshold: UInt8 = 250

    /// Luminance threshold for foreground detection (0-255)
    static let luminanceThreshold: UInt8 = 128

    /// Fully opaque alpha value
    static let opaqueAlpha: UInt8 = 255

    // MARK: - Download Size Estimates

    /// SAM model download size estimate (bytes)
    static var samModelBytes: Int64 {
        Int64(ConfigurationService.shared.samModelSizeGb * 1_000_000_000)
    }

    /// Hunyuan Mini model download size estimate (bytes)
    static var hunyuanMiniModelBytes: Int64 {
        Int64(ConfigurationService.shared.hunyuanMiniModelSizeGb * 1_000_000_000)
    }

    /// Hunyuan Standard model download size estimate (bytes)
    static var hunyuanStandardModelBytes: Int64 {
        Int64(ConfigurationService.shared.hunyuanLargeModelSizeGb * 1_000_000_000)
    }
}
