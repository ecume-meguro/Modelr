import SwiftUI

// MARK: - Touchup
extension SimpleEditorViewModel {

    func startTouchup() {
        let mergedMask = mergeAllSelectedMasks()
        guard mergedMask != nil else { return }

        editableMaskImage = mergedMask
        maskHistory.removeAll()

        withAnimation(.easeOut(duration: 0.25)) {
            currentStep = .touchup
        }
    }

    /// Merge all selected masks from all segmentations using OR operation
    func mergeAllSelectedMasks() -> NSImage? {
        let validSegmentations = segmentations.filter { $0.hasValidMask }
        guard !validSegmentations.isEmpty else { return nil }

        guard let firstMask = validSegmentations.first?.selectedMask,
              let firstCG = firstMask.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }

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

        for segmentation in validSegmentations {
            for mask in segmentation.selectedMasks {
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
        }

        guard let mergedCG = outputContext.makeImage() else { return nil }
        return NSImage(cgImage: mergedCG, size: NSSize(width: width, height: height))
    }

    func saveUndoState() {
        guard let currentMask = editableMaskImage else { return }
        maskHistory.append(currentMask)
        if maskHistory.count > 20 {
            maskHistory.removeFirst()
        }
    }

    func undo() {
        guard !maskHistory.isEmpty else { return }
        editableMaskImage = maskHistory.removeLast()
    }

    func paintOnMask(at normalized: CGPoint) {
        guard let maskImage = editableMaskImage,
              let cgImage = maskImage.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }

        let width = cgImage.width
        let height = cgImage.height
        let pixelX = Int(normalized.x * CGFloat(width))
        let pixelY = Int(normalized.y * CGFloat(height))

        guard pixelX >= 0, pixelX < width, pixelY >= 0, pixelY < height else { return }

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ), let data = context.data else { return }

        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        let pixels = data.bindMemory(to: UInt8.self, capacity: width * height * 4)

        let brushRadius = max(1, Int(brushSize * CGFloat(width) / 1000.0))
        let radiusSquared = brushRadius * brushRadius
        let value: UInt8 = brushMode == .add ? 255 : 0
        let pixelValue = UInt32(value) | (UInt32(value) << 8) | (UInt32(value) << 16) | (UInt32(value) << 24)

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

        guard let newCGImage = context.makeImage() else { return }
        editableMaskImage = NSImage(cgImage: newCGImage, size: NSSize(width: width, height: height))
    }
}
