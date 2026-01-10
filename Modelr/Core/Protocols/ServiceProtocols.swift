import Foundation
import AppKit

// MARK: - Service Protocols for Testability

/// Protocol for image processing operations
protocol ImageServiceProtocol {
    func convertToPNG(image: NSImage, originalName: String) -> String?
    func createCompositeImage(source: NSImage, mask: NSImage) -> NSImage?
    func savePNG(_ image: NSImage, to url: URL) throws
    func loadImage(from url: URL) -> NSImage?
}

/// Protocol for path management (for testing file operations)
protocol PathManagerProtocol {
    var appSupportDirectory: URL { get }
    var projectsDirectory: URL { get }
    var modelsDirectory: URL { get }
    var workingDirectory: URL { get }

    func fileExists(at url: URL) -> Bool
    func ensureDirectoryExists(at url: URL) throws
    func copyFile(from source: URL, to destination: URL) throws
}
