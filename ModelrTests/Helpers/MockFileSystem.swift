import Foundation
import AppKit

class MockFileSystem {
    static var testImages: [String: NSImage] = [:]
    static var testMasks: [String: NSImage] = [:]
    
    static func createTestImage(width: Int, height: Int, color: NSColor = .white) -> NSImage {
        let size = NSSize(width: width, height: height)
        let image = NSImage(size: size)
        
        image.lockFocus()
        color.drawSwatch(in: NSRect(origin: .zero, size: size))
        image.unlockFocus()
        
        return image
    }
    
    static func createTestMask(width: Int, height: Int, opaqueRegion: CGRect) -> NSImage {
        let size = NSSize(width: width, height: height)
        let image = NSImage(size: size)
        
        image.lockFocus()
        NSColor.clear.set()
        NSRect(origin: .zero, size: size).fill()
        
        NSColor.black.withAlphaComponent(1.0).set()
        opaqueRegion.fill()
        image.unlockFocus()
        
        return image
    }
    
    static func saveTestImage(_ image: NSImage, to url: URL) throws {
        guard let tiffData = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData),
              let pngData = bitmap.representation(using: .png, properties: [:]) else {
            throw NSError(domain: "MockFileSystem", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to create PNG"])
        }
        try pngData.write(to: url)
    }
    
    static func cleanupTestDirectory(at url: URL) {
        try? FileManager.default.removeItem(at: url)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
}
