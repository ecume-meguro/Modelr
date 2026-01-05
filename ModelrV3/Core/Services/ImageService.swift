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
                let luminance = (UInt32(r) + UInt32(g) + UInt32(b)) / 3
                isForeground = luminance > 128
            }

            if isForeground {
                outputPixels[offset] = sourcePixels[offset]
                outputPixels[offset + 1] = sourcePixels[offset + 1]
                outputPixels[offset + 2] = sourcePixels[offset + 2]
                outputPixels[offset + 3] = 255
            } else {
                outputPixels[offset] = 0
                outputPixels[offset + 1] = 0
                outputPixels[offset + 2] = 0
                outputPixels[offset + 3] = 0
            }
        }

        guard let finalCG = outputContext.makeImage() else { return nil }
        return NSImage(cgImage: finalCG, size: NSSize(width: width, height: height))
    }

    /// Merge multiple masks using OR operation (luminance or alpha > 128)
    func mergeMasks(_ masks: [NSImage]) -> NSImage? {
        guard !masks.isEmpty else { return nil }
        guard let firstCG = masks.first?.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }

        let width = firstCG.width
        let height = firstCG.height
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let totalPixels = width * height

        guard let outputContext = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ), let outputData = outputContext.data else { return nil }

        let outputPixels = outputData.bindMemory(to: UInt8.self, capacity: totalPixels * 4)
        memset(outputPixels, 0, totalPixels * 4)

        for mask in masks {
            guard let cgMask = mask.cgImage(forProposedRect: nil, context: nil, hints: nil) else { continue }

            guard let maskContext = CGContext(
                data: nil, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ), let maskData = maskContext.data else { continue }

            maskContext.draw(cgMask, in: CGRect(x: 0, y: 0, width: width, height: height))
            let maskPixels = maskData.bindMemory(to: UInt8.self, capacity: totalPixels * 4)

            for i in 0..<totalPixels {
                let offset = i * 4
                let r = maskPixels[offset]
                let g = maskPixels[offset + 1]
                let b = maskPixels[offset + 2]
                let a = maskPixels[offset + 3]

                let luminance = (UInt16(r) + UInt16(g) + UInt16(b)) / 3
                let isMaskPixel = a > 128 || luminance > 128

                if isMaskPixel {
                    outputPixels[offset + 0] = 255
                    outputPixels[offset + 1] = 255
                    outputPixels[offset + 2] = 255
                    outputPixels[offset + 3] = 255
                }
            }
        }

        guard let mergedCG = outputContext.makeImage() else { return nil }
        return NSImage(cgImage: mergedCG, size: NSSize(width: width, height: height))
    }

    /// Apply a brush stroke to a mask image
    func applyBrush(to maskImage: NSImage, at normalized: CGPoint, size: CGFloat, isErasing: Bool) -> NSImage? {
        return applyStroke(to: maskImage, points: [normalized], size: size, isErasing: isErasing)
    }

    /// Apply a brush stroke (multiple points) to a mask image
    func applyStroke(to maskImage: NSImage, points: [CGPoint], size: CGFloat, isErasing: Bool) -> NSImage? {
        guard !points.isEmpty else { return maskImage }
        guard let cgImage = maskImage.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }

        let width = cgImage.width
        let height = cgImage.height
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        
        guard let context = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ), let data = context.data else { return maskImage }

        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        let pixels = data.bindMemory(to: UInt8.self, capacity: width * height * 4)

        let brushRadius = max(1, Int(size * CGFloat(width)))
        let radiusSquared = brushRadius * brushRadius
        let value: UInt8 = isErasing ? 0 : 255
        let pixelValue = UInt32(value) | (UInt32(value) << 8) | (UInt32(value) << 16) | (UInt32(value) << 24)

        for point in points {
            let pixelX = Int(point.x * CGFloat(width))
            let pixelY = Int(point.y * CGFloat(height))

            guard pixelX >= 0, pixelX < width, pixelY >= 0, pixelY < height else { continue }

            let minY = max(0, pixelY - brushRadius)
            let maxY = min(height - 1, pixelY + brushRadius)
            let minX = max(0, pixelX - brushRadius)
            let maxX = min(width - 1, pixelX + brushRadius)

            for py in minY...maxY {
                let dySquared = (py - pixelY) * (py - pixelY)
                let rowOffset = py * width
                for px in minX...maxX {
                    let dxSquared = (px - pixelX) * (px - pixelX)
                    if dxSquared + dySquared <= radiusSquared {
                        let offset = (rowOffset + px) * 4
                        pixels.advanced(by: offset).withMemoryRebound(to: UInt32.self, capacity: 1) { ptr in
                            ptr.pointee = pixelValue
                        }
                    }
                }
            }
        }

        guard let newCGImage = context.makeImage() else { return maskImage }
        return NSImage(cgImage: newCGImage, size: NSSize(width: width, height: height))
    }
}