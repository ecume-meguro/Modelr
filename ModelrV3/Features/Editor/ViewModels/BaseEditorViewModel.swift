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
    
    /// Load image from URL
    func loadInputImage(from url: URL) async throws -> NSImage {
        // Validate and load using ImageFileService (formerly SafeFileService)
        let image = try ImageFileService.shared.validateAndProcessImage(url)
        
        // Convert to PNG for backend consistency if it's not already a safe temp file
        let pngPath = ImageService.shared.convertToPNG(image: image, originalName: url.deletingPathExtension().lastPathComponent)
        
        await MainActor.run {
            self.inputImage = image
            self.inputImagePath = pngPath ?? url.path
            self.imagePixelSize = NSSizeToCGSize(image.size)
        }
        
        return image
    }
}
