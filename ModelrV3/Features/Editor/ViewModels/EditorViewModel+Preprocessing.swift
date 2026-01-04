import SwiftUI

// MARK: - Preprocessing Extension

extension EditorViewModel {
    // MARK: - Crop Actions
    
    func applyCrop() {
        guard let cropBox = cropRect, cropBox.isValid else {
            env.status = "Invalid crop region"
            return
        }
        
        guard let image = inputImage else { return }
        
        // Convert normalized rect to pixel coordinates
        let normalized = cropBox.normalizedRect
        let rect = CGRect(
            x: normalized.minX * image.size.width,
            y: normalized.minY * image.size.height,
            width: normalized.width * image.size.width,
            height: normalized.height * image.size.height
        )
        
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            env.status = "Failed to crop image"
            return
        }
        
        guard let croppedCGImage = cgImage.cropping(to: rect) else {
            env.status = "Failed to crop image"
            return
        }
        
        let croppedNSImage = NSImage(cgImage: croppedCGImage, size: NSSize(width: rect.width, height: rect.height))
        
        undoStack.append(.crop(originalImage: inputImage!, originalPath: nil))
        redoStack.removeAll()
        
        inputImage = croppedNSImage
        cropRect = nil
        imageVersion += 1
        saveImageForBackend(image: croppedNSImage)
        cacheSourceAlpha()
        cachedDisplaySize = .zero
        
        env.status = "Image cropped"
    }
    
    func clearCrop() {
        cropRect = nil
    }
    
    // MARK: - Polygon Crop Actions
    
    func applyPolygonCrop() {
        guard let lasso = preprocessLasso, lasso.isValid else {
            env.status = "Invalid selection"
            return
        }
        
        guard let image = inputImage else { return }
        
        let cropped = cropImageToLasso(image, lasso: lasso)
        
        undoStack.append(.crop(originalImage: inputImage!, originalPath: nil))
        redoStack.removeAll()
        
        inputImage = cropped
        preprocessLasso = nil
        imageVersion += 1
        saveImageForBackend(image: cropped)
        cacheSourceAlpha()
        cachedDisplaySize = .zero
        
        env.status = "Image cropped to selection"
    }
    
    func clearPolygonCrop() {
        preprocessLasso = nil
    }
    
    private func cropImageToLasso(_ image: NSImage, lasso: LassoSelection) -> NSImage {
        let imageSize = image.size
        guard let bbox = lasso.boundingBox else { return image }
        
        // Convert normalized bounding box to pixel coordinates
        let normalized = bbox.normalizedRect
        let boundingBox = CGRect(
            x: normalized.minX * imageSize.width,
            y: normalized.minY * imageSize.height,
            width: normalized.width * imageSize.width,
            height: normalized.height * imageSize.height
        )
        
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let croppedCGImage = cgImage.cropping(to: boundingBox) else {
            return image
        }
        
        let croppedSize = NSSize(width: boundingBox.width, height: boundingBox.height)
        let croppedImage = NSImage(size: croppedSize)
        
        croppedImage.lockFocus()
        
        let path = NSBezierPath()
        let lassoPoints = lasso.points
        path.move(to: CGPoint(
            x: (lassoPoints[0].x * imageSize.width) - boundingBox.minX,
            y: (lassoPoints[0].y * imageSize.height) - boundingBox.minY
        ))
        
        for point in lassoPoints.dropFirst() {
            path.line(to: CGPoint(
                x: (point.x * imageSize.width) - boundingBox.minX,
                y: (point.y * imageSize.height) - boundingBox.minY
            ))
        }
        path.close()
        path.addClip()
        
        NSImage(cgImage: croppedCGImage, size: croppedSize).draw(at: .zero, from: .zero, operation: .copy, fraction: 1.0)
        
        croppedImage.unlockFocus()
        
        return croppedImage
    }
    
    // MARK: - Skip Segmentation
    
    func createFullImageMask() {
        guard let image = inputImage else { return }
        
        let width = Int(image.size.width)
        let height = Int(image.size.height)
        
        guard width > 0 && height > 0 else {
            env.status = "Invalid image dimensions"
            return
        }
        
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            env.status = "Failed to get CGImage"
            return
        }
        
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bytesPerPixel = 4
        let bytesPerRow = bytesPerPixel * width
        var sourcePixels = [UInt8](repeating: 0, count: height * bytesPerRow)
        
        guard let sourceContext = CGContext(
            data: &sourcePixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            env.status = "Failed to create source context"
            return
        }
        
        sourceContext.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        
        var maskPixels = [UInt8](repeating: 0, count: height * bytesPerRow)
        
        let maskR: UInt8 = 50
        let maskG: UInt8 = 100
        let maskB: UInt8 = 200
        
        var opaquePixels = 0
        for y in 0..<height {
            for x in 0..<width {
                let offset = (y * bytesPerRow) + (x * bytesPerPixel)
                let sourceAlpha = sourcePixels[offset + 3]
                
                if sourceAlpha > 2 {
                    maskPixels[offset + 0] = maskR
                    maskPixels[offset + 1] = maskG
                    maskPixels[offset + 2] = maskB
                    maskPixels[offset + 3] = 255
                    opaquePixels += 1
                } else {
                    maskPixels[offset + 0] = 0
                    maskPixels[offset + 1] = 0
                    maskPixels[offset + 2] = 0
                    maskPixels[offset + 3] = 0
                }
            }
        }
        
        guard let maskContext = CGContext(
            data: &maskPixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ),
        let maskCGImage = maskContext.makeImage() else {
            env.status = "Failed to create mask image"
            return
        }
        
        let size = NSSize(width: width, height: height)
        let newMask = NSImage(cgImage: maskCGImage, size: size)
        maskImage = newMask
        
        maskIsDirty = true
        flushMaskToDisk()
        
        let coverage = Double(opaquePixels) / Double(width * height) * 100
        env.status = String(format: "Mask from alpha channel (%.1f%% coverage)", coverage)
    }
}
