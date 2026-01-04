import SwiftUI

// MARK: - Multi-Segmentation Management
extension SimpleEditorViewModel {

    /// Add a new segmentation entry and make it active
    func addSegmentation() {
        // Collapse all existing segmentations
        for i in segmentations.indices {
            segmentations[i].isExpanded = false
        }

        let newEntry = SegmentationEntry(name: "Object \(segmentations.count + 1)")
        segmentations.append(newEntry)
        activeSegmentationIndex = segmentations.count - 1
    }

    /// Remove a segmentation entry by index
    func removeSegmentation(at index: Int) {
        guard index < segmentations.count else { return }
        segmentations.remove(at: index)

        // Adjust active index
        if segmentations.isEmpty {
            addSegmentation()
        } else if activeSegmentationIndex >= segmentations.count {
            activeSegmentationIndex = segmentations.count - 1
        }
    }

    /// Expand a segmentation and collapse others
    func expandSegmentation(at index: Int) {
        guard index < segmentations.count else { return }

        for i in segmentations.indices {
            segmentations[i].isExpanded = (i == index)
        }
        activeSegmentationIndex = index
    }

    /// Run text prediction for active segmentation
    func runTextPrediction() {
        guard activeSegmentationIndex < segmentations.count else { return }
        guard !segmentations[activeSegmentationIndex].textPrompt.isEmpty else { return }

        segmentations[activeSegmentationIndex].isSearchPerformed = true
        segmentations[activeSegmentationIndex].isProcessing = true

        let index = activeSegmentationIndex
        let text = segmentations[index].textPrompt

        Task {
            await performTextSearch(for: index, text: text)
            await MainActor.run {
                if index < segmentations.count {
                    segmentations[index].isProcessing = false
                }
            }
        }
    }

    func performTextSearch(for index: Int, text: String) async {
        do {
            let (maskURLs, _, scores, _) = try await env.predict(
                points: [],
                box: nil,
                text: text,
                imageSize: imagePixelSize
            )

            var masks: [(image: NSImage, score: Double, url: URL)] = []
            for (url, score) in zip(maskURLs, scores) {
                if let image = NSImage(contentsOf: url) {
                    masks.append((image: image, score: score, url: url))
                }
            }

            await MainActor.run {
                if index < segmentations.count {
                    segmentations[index].allMasks = masks
                    segmentations[index].selectedMaskIndices = [0]
                    segmentations[index].name = text.capitalized
                }
            }
        } catch {
            print("[Text] Error: \(error)")
        }
    }

    /// Add a point to active segmentation and run prediction
    func addPoint(at normalized: CGPoint) {
        guard activeSegmentationIndex < segmentations.count else { return }

        let point = SAMPoint(normalizedCoords: normalized.clamped, label: 1)
        segmentations[activeSegmentationIndex].points.append(point)
        segmentations[activeSegmentationIndex].isProcessing = true

        let index = activeSegmentationIndex
        let points = segmentations[index].points

        Task {
            await runPointPrediction(for: index, points: points)
            await MainActor.run {
                if index < segmentations.count {
                    segmentations[index].isProcessing = false
                }
            }
        }
    }

    func runPointPrediction(for index: Int, points: [SAMPoint]) async {
        guard !points.isEmpty else { return }
        do {
            let (maskURLs, _, scores, _) = try await env.predict(
                points: points,
                box: nil,
                text: nil,
                imageSize: imagePixelSize
            )

            var masks: [(image: NSImage, score: Double, url: URL)] = []
            for (url, score) in zip(maskURLs, scores) {
                if let image = NSImage(contentsOf: url) {
                    masks.append((image: image, score: score, url: url))
                }
            }

            await MainActor.run {
                if index < segmentations.count {
                    segmentations[index].allMasks = masks
                    segmentations[index].selectedMaskIndices = [0]
                }
            }
        } catch {
            print("[Point] Error: \(error)")
        }
    }

    /// Select mask for a specific segmentation (shift to add/remove from selection)
    func selectMask(at maskIndex: Int, for segmentationIndex: Int, addToSelection: Bool = false) {
        guard segmentationIndex < segmentations.count else { return }
        guard maskIndex < segmentations[segmentationIndex].allMasks.count else { return }

        if addToSelection {
            if segmentations[segmentationIndex].selectedMaskIndices.contains(maskIndex) {
                if segmentations[segmentationIndex].selectedMaskIndices.count > 1 {
                    segmentations[segmentationIndex].selectedMaskIndices.remove(maskIndex)
                }
            } else {
                segmentations[segmentationIndex].selectedMaskIndices.insert(maskIndex)
            }
        } else {
            segmentations[segmentationIndex].selectedMaskIndices = [maskIndex]
        }
    }

    func createMaskFromAlpha() {
        guard let image = inputImage,
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }

        let width = cgImage.width
        let height = cgImage.height
        let colorSpace = CGColorSpaceCreateDeviceRGB()

        guard let sourceContext = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ), let sourceData = sourceContext.data else { return }

        sourceContext.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        guard let maskContext = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ), let maskData = maskContext.data else { return }

        let sourcePixels = sourceData.bindMemory(to: UInt8.self, capacity: width * height * 4)
        let maskPixels = maskData.bindMemory(to: UInt8.self, capacity: width * height * 4)

        for i in 0..<(width * height) {
            let offset = i * 4
            let alpha = sourcePixels[offset + 3]
            let white: UInt8 = alpha > 128 ? 255 : 0
            maskPixels[offset + 0] = white
            maskPixels[offset + 1] = white
            maskPixels[offset + 2] = white
            maskPixels[offset + 3] = white
        }

        guard let maskCGImage = maskContext.makeImage() else { return }
        let maskNSImage = NSImage(cgImage: maskCGImage, size: NSSize(width: width, height: height))

        let tempURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("alpha_mask_\(UUID().uuidString).png")

        if let tiff = maskNSImage.tiffRepresentation,
           let bitmap = NSBitmapImageRep(data: tiff),
           let png = bitmap.representation(using: .png, properties: [:]) {
            do {
                try png.write(to: tempURL)
            } catch {
                print("[Segmentation] Failed to write alpha mask: \(error)")
            }
        }

        segmentations.removeAll()
        var entry = SegmentationEntry(name: "From Alpha")
        entry.allMasks = [(image: maskNSImage, score: 1.0, url: tempURL)]
        entry.selectedMaskIndices = [0]
        entry.isSearchPerformed = true
        segmentations.append(entry)
        activeSegmentationIndex = 0
    }

    /// Clear all segmentations and start fresh
    func clearAllSegmentations() {
        segmentations.removeAll()
        editableMaskImage = nil
        addSegmentation()
    }

    /// Clear active segmentation only
    func clearActiveSegmentation() {
        guard activeSegmentationIndex < segmentations.count else { return }
        segmentations[activeSegmentationIndex].textPrompt = ""
        segmentations[activeSegmentationIndex].points.removeAll()
        segmentations[activeSegmentationIndex].allMasks.removeAll()
        segmentations[activeSegmentationIndex].selectedMaskIndices = [0]
        segmentations[activeSegmentationIndex].isSearchPerformed = false
    }

    /// Find which mask was clicked in active segmentation
    func findMaskAtPoint(_ normalized: CGPoint, displaySize: CGSize) -> Int? {
        guard activeSegmentationIndex < segmentations.count else { return nil }
        let masks = segmentations[activeSegmentationIndex].allMasks

        for (index, maskData) in masks.enumerated().reversed() {
            let image = maskData.image
            guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { continue }

            let pixelX = Int(normalized.x * CGFloat(cgImage.width))
            let pixelY = Int(normalized.y * CGFloat(cgImage.height))

            guard pixelX >= 0, pixelX < cgImage.width, pixelY >= 0, pixelY < cgImage.height else { continue }

            guard let dataProvider = cgImage.dataProvider,
                  let data = dataProvider.data,
                  let bytes = CFDataGetBytePtr(data) else { continue }

            let bytesPerPixel = cgImage.bitsPerPixel / 8
            let bytesPerRow = cgImage.bytesPerRow
            let pixelOffset = pixelY * bytesPerRow + pixelX * bytesPerPixel

            let alpha: UInt8
            if bytesPerPixel >= 4 {
                alpha = bytes[pixelOffset + 3]
            } else if bytesPerPixel >= 1 {
                alpha = bytes[pixelOffset]
            } else {
                continue
            }

            if alpha > 128 {
                return index
            }
        }
        return nil
    }
}
