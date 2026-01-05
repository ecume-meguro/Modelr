import SwiftUI
import AppKit

/// Centralized service for image processing tasks
class ImageService {
    static let shared = ImageService()
    
    private init() {}
    
    /// Checks if an image has a meaningful alpha channel (transparency)
    func checkImageHasAlpha(_ image: NSImage) -> Bool {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return false
        }

        let alphaInfo = cgImage.alphaInfo
        let hasAlphaChannel = alphaInfo == .first || alphaInfo == .last ||
                              alphaInfo == .premultipliedFirst || alphaInfo == .premultipliedLast

        guard hasAlphaChannel else {
            return false
        }

        let width = cgImage.width
        let height = cgImage.height
        let colorSpace = CGColorSpaceCreateDeviceRGB()

        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ), let data = context.data else {
            return false
        }

        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        let pixels = data.bindMemory(to: UInt8.self, capacity: width * height * 4)
        
        // Sample pixels to see if any are actually transparent
        let sampleStep = max(1, (width * height) / 10000)
        for i in stride(from: 0, to: width * height, by: sampleStep) {
            let alpha = pixels[i * 4 + 3]
            if alpha < 250 {
                return true
            }
        }

        return false
    }
    
    /// Converts an NSImage to a PNG file at a temporary path, preserving alpha channel
    func convertToPNG(image: NSImage, originalName: String) -> String? {
        // Use CGImage directly to preserve alpha channel (tiffRepresentation strips alpha)
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return nil
        }

        let bitmap = NSBitmapImageRep(cgImage: cgImage)
        bitmap.hasAlpha = true

        guard let pngData = bitmap.representation(using: .png, properties: [:]) else {
            return nil
        }

        let tempPath = NSTemporaryDirectory() + "\(originalName)_\(UUID().uuidString.prefix(8)).png"
        do {
            try pngData.write(to: URL(fileURLWithPath: tempPath))
            return tempPath
        } catch {
            print("[ImageService] Failed to write PNG: \(error)")
            return nil
        }
    }
    
    /// Creates a composite image by applying a mask to a source image
    func createCompositeImage(source: NSImage, mask: NSImage) -> NSImage? {
        guard let sourceCG = source.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let maskCG = mask.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }

        let width = sourceCG.width
        let height = sourceCG.height
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let totalPixels = width * height

        // Debug: log mask info
        print("[Composite] Source: \(width)x\(height), alphaInfo: \(sourceCG.alphaInfo.rawValue)")
        print("[Composite] Mask: \(maskCG.width)x\(maskCG.height), alphaInfo: \(maskCG.alphaInfo.rawValue)")

        guard let sourceContext = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ), let sourceData = sourceContext.data else { return nil }
        sourceContext.draw(sourceCG, in: CGRect(x: 0, y: 0, width: width, height: height))

        guard let maskContext = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ), let maskData = maskContext.data else { return nil }
        maskContext.draw(maskCG, in: CGRect(x: 0, y: 0, width: width, height: height))

        guard let outputContext = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ), let outputData = outputContext.data else { return nil }

        let sourcePixels = sourceData.bindMemory(to: UInt8.self, capacity: totalPixels * 4)
        let maskPixels = maskData.bindMemory(to: UInt8.self, capacity: totalPixels * 4)
        let outputPixels = outputData.bindMemory(to: UInt8.self, capacity: totalPixels * 4)

        // Debug: sample mask values to understand format
        var maskAlphaSum: Int = 0
        var maskRedSum: Int = 0
        var maskGreenSum: Int = 0
        for i in stride(from: 0, to: min(1000, totalPixels), by: 1) {
            maskRedSum += Int(maskPixels[i * 4])
            maskGreenSum += Int(maskPixels[i * 4 + 1])
            maskAlphaSum += Int(maskPixels[i * 4 + 3])
        }
        print("[Composite] Mask sample (first 1000px): R_avg=\(maskRedSum/1000), G_avg=\(maskGreenSum/1000), A_avg=\(maskAlphaSum/1000)")

        // Count foreground/background pixels
        var foregroundCount = 0
        var backgroundCount = 0

        // Check if mask has a useful alpha channel or is just a grayscale image
        var hasAlphaInfo = false
        for i in 0..<min(totalPixels, 1000) {
            let a = maskPixels[i * 4 + 3]
            if a > 0 && a < 255 {
                hasAlphaInfo = true
                break
            }
        }

        // RGBA format (premultipliedLast): R=0, G=1, B=2, A=3
        for i in 0..<totalPixels {
            let offset = i * 4
            let r = maskPixels[offset]
            let g = maskPixels[offset + 1]
            let b = maskPixels[offset + 2]
            let a = maskPixels[offset + 3]

            let isForeground: Bool
            if hasAlphaInfo {
                isForeground = a > 128
            } else {
                // For grayscale masks, if alpha is not useful, 
                // we rely strictly on luminance.
                let luminance = (UInt32(r) + UInt32(g) + UInt32(b)) / 3
                isForeground = luminance > 128
            }

            if isForeground {
                foregroundCount += 1
                // Keep source RGB, set alpha = 255 (opaque)
                outputPixels[offset] = sourcePixels[offset]         // R
                outputPixels[offset + 1] = sourcePixels[offset + 1] // G
                outputPixels[offset + 2] = sourcePixels[offset + 2] // B
                outputPixels[offset + 3] = 255                      // A = opaque
            } else {
                backgroundCount += 1
                // Clear background (0, 0, 0, 0)
                outputPixels[offset] = 0     // R
                outputPixels[offset + 1] = 0 // G
                outputPixels[offset + 2] = 0 // B
                outputPixels[offset + 3] = 0 // A = transparent
            }
        }

        print("[Composite] Result: \(foregroundCount) foreground, \(backgroundCount) background pixels")

        guard let finalCG = outputContext.makeImage() else { return nil }
        return NSImage(cgImage: finalCG, size: NSSize(width: width, height: height))
    }
}
