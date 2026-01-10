import os.log
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
        // Capture values atomically to prevent race conditions
        let index = activeSegmentationIndex
        guard let entry = segmentations[safe: index] else { return }
        let text = entry.textPrompt
        guard !text.isEmpty else { return }
        guard isImageInitializedWithSAM else {
            print("[Segmentation] Cannot run text prediction - image not initialized with SAM")
            return
        }

        segmentations[index].isSearchPerformed = true
        segmentations[index].isProcessing = true

        // Cancel any previous segmentation task
        segmentationTask?.cancel()

        segmentationTask = Task { [weak self] in
            guard let self = self else { return }

            do {
                try Task.checkCancellation()
                await self.performPrediction(for: index, text: text, points: [], box: nil)

                try Task.checkCancellation()
                if self.segmentations[safe: index] != nil {
                    self.segmentations[index].isProcessing = false
                    self.segmentations[index].name = text.capitalized
                }
            } catch is CancellationError {
                // Cancelled, just reset processing state
                if self.segmentations[safe: index] != nil {
                    self.segmentations[index].isProcessing = false
                }
            } catch {
                print("[Segmentation] Error: \(error)")
                if self.segmentations[safe: index] != nil {
                    self.segmentations[index].isProcessing = false
                }
                self.lastError = AppError.imageProcessing(error.localizedDescription)
                self.showErrorAlert = true
            }
        }
    }

    /// Set bounding box for active segmentation and run prediction
    func setBoundingBox(_ box: SAMBox) {
        let index = activeSegmentationIndex
        guard segmentations[safe: index] != nil else { return }
        guard isImageInitializedWithSAM else {
            print("[Segmentation] Cannot set bounding box - image not initialized with SAM")
            return
        }

        segmentations[index].boundingBox = box
        segmentations[index].points.removeAll()  // Clear any points
        segmentations[index].isProcessing = true

        // Cancel any previous segmentation task
        segmentationTask?.cancel()

        segmentationTask = Task { [weak self] in
            guard let self = self else { return }

            do {
                try Task.checkCancellation()
                await self.performPrediction(for: index, text: nil, points: [], box: box)

                try Task.checkCancellation()
                if self.segmentations[safe: index] != nil {
                    self.segmentations[index].isProcessing = false
                }
            } catch is CancellationError {
                if self.segmentations[safe: index] != nil {
                    self.segmentations[index].isProcessing = false
                }
            } catch {
                print("[Segmentation] Error: \(error)")
                if self.segmentations[safe: index] != nil {
                    self.segmentations[index].isProcessing = false
                }
            }
        }
    }

    /// Add a point to active segmentation and run prediction (legacy, kept for compatibility)
    func addPoint(at normalized: CGPoint) {
        let index = activeSegmentationIndex
        guard segmentations[safe: index] != nil else { return }
        guard isImageInitializedWithSAM else {
            print("[Segmentation] Cannot add point - image not initialized with SAM")
            return
        }

        let point = SAMPoint(normalizedCoords: normalized.clamped, label: 1)
        segmentations[index].points.append(point)
        segmentations[index].isProcessing = true
        let points = segmentations[index].points

        // Cancel any previous segmentation task
        segmentationTask?.cancel()

        segmentationTask = Task { [weak self] in
            guard let self = self else { return }

            do {
                try Task.checkCancellation()
                await self.performPrediction(for: index, text: nil, points: points, box: nil)

                try Task.checkCancellation()
                if self.segmentations[safe: index] != nil {
                    self.segmentations[index].isProcessing = false
                }
            } catch is CancellationError {
                // Cancelled, just reset processing state
                if self.segmentations[safe: index] != nil {
                    self.segmentations[index].isProcessing = false
                }
            } catch {
                print("[Segmentation] Error: \(error)")
                if self.segmentations[safe: index] != nil {
                    self.segmentations[index].isProcessing = false
                }
            }
        }
    }

    /// Centralized prediction logic for points, box, and text
    func performPrediction(for index: Int, text: String?, points: [SAMPoint], box: SAMBox? = nil) async {
        do {
            let (maskURLs, _, scores, _) = try await env.predict(
                points: points,
                box: box,
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
                if segmentations[safe: index] != nil {
                    segmentations[index].allMasks = masks
                    segmentations[index].selectedMaskIndices = [0]
                }
                // Trigger preloading of merged mask for faster transition to touchup
                triggerMaskPreload()
            }
        } catch {
            print("[Prediction] Error: \(error)")
        }
    }

    /// Trigger preloading of merged mask when segmentations change
    func triggerMaskPreload() {
        preloadManager.preloadMergedMask(from: segmentations)
    }

    /// Select mask for a specific segmentation (shift to add/remove from selection)
    func selectMask(at maskIndex: Int, for segmentationIndex: Int, addToSelection: Bool = false) {
        guard let entry = segmentations[safe: segmentationIndex] else { return }
        guard entry.allMasks[safe: maskIndex] != nil else { return }

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

        // Trigger preloading when mask selection changes
        triggerMaskPreload()
    }

    func createMaskFromAlpha() {
        guard let image = inputImage else { return }
        guard let maskNSImage = ImageService.shared.createMaskFromAlpha(image: image) else { return }

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
        let index = activeSegmentationIndex
        guard segmentations[safe: index] != nil else { return }
        segmentations[index].textPrompt = ""
        segmentations[index].points.removeAll()
        segmentations[index].boundingBox = nil
        segmentations[index].allMasks.removeAll()
        segmentations[index].selectedMaskIndices = [0]
        segmentations[index].isSearchPerformed = false
    }

    /// Find which mask was clicked in active segmentation
    func findMaskAtPoint(_ normalized: CGPoint, displaySize: CGSize) -> Int? {
        let index = activeSegmentationIndex
        guard let entry = segmentations[safe: index] else { return nil }
        let masks = entry.allMasks

        for (maskIndex, maskData) in masks.enumerated().reversed() {
            if ImageService.shared.isPointInMask(normalized, mask: maskData.image) {
                return maskIndex
            }
        }
        return nil
    }
}
