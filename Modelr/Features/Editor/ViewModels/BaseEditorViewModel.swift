import SwiftUI
import Foundation

/// Base class for Editor ViewModels to share common state and logic
@MainActor
class BaseEditorViewModel: ObservableObject {
    // MARK: - Dependencies
    let env: PythonEnvironment
    
    // MARK: - Common Image State
    @Published var inputImage: NSImage?
    @Published var inputImagePath: String?
    @Published var imagePixelSize: CGSize = .zero
    
    // MARK: - Common Workflow State
    @Published var isGenerating = false
    @Published var generated3DModelURL: URL?
    @Published var generationStartTime: Date?
    
    // MARK: - UI State
    @Published var isDragging = false
    
    init(env: PythonEnvironment = PythonEnvironment()) {
        self.env = env
    }
    
    // MARK: - Shared Logic
    
    /// Clear current generation state
    func clearGenerationState() {
        generated3DModelURL = nil
        isGenerating = false
        generationStartTime = nil
    }
    
    /// Load image from URL with standardized processing
    func loadInputImage(from url: URL) async throws -> NSImage {
        // Validate and load using ImageFileService (handles security, size limits, etc.)
        let image = try ImageFileService.shared.validateAndProcessImage(url)
        
        // Always convert to PNG for backend consistency and to ensure we have a valid path on disk
        // that the Python backend can access (even if original was from a weird location)
        let originalName = url.deletingPathExtension().lastPathComponent
        guard let pngPath = ImageService.shared.convertToPNG(image: image, originalName: originalName) else {
            throw AppError.validation(field: "image", message: "Failed to process image for backend")
        }
        
        // Get actual pixel size from metadata or image representation
        let pixelSize = getActualPixelSize(for: image, at: url)
        
        await MainActor.run {
            self.inputImage = image
            self.inputImagePath = pngPath
            self.imagePixelSize = pixelSize
        }
        
        return image
    }
    
    /// Helper to get actual pixel dimensions, ignoring backing scale/DPI
    private func getActualPixelSize(for image: NSImage, at url: URL) -> CGSize {
        // Try CGImageSource first (most accurate for files)
        if let source = CGImageSourceCreateWithURL(url as CFURL, nil),
           let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
           let pW = props[kCGImagePropertyPixelWidth] as? CGFloat,
           let pH = props[kCGImagePropertyPixelHeight] as? CGFloat {
            
            // Handle EXIF orientation if needed
            let orientation = props[kCGImagePropertyOrientation] as? Int ?? 1
            if orientation >= 5 && orientation <= 8 {
                return CGSize(width: pH, height: pW)
            }
            return CGSize(width: pW, height: pH)
        }
        
        // Fallback to image representations
        if let rep = image.representations.first {
             return CGSize(width: CGFloat(rep.pixelsWide), height: CGFloat(rep.pixelsHigh))
        }
        
        // Final fallback to logical size
        return image.size
    }
}
