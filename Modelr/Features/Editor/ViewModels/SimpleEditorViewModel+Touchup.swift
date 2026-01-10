import os.log
import SwiftUI

// MARK: - Touchup
extension SimpleEditorViewModel {

    func startTouchup() {
        // Validate we have masks before transitioning
        guard totalValidMasks > 0 else { return }

        // Clear history and reset edit tracking
        maskHistory.removeAll()
        hasMaskEdits = false

        // Try to use preloaded mask first (faster UX)
        let preloadedMask = preloadManager.getPreloadedComposite() != nil
            ? nil  // If composite is preloaded, we don't need the mask separately
            : preloadManager.preloadedMergedMask

        // Animate step change FIRST for immediate UI response
        withFastSpring {
            currentStep = .touchup
        }

        if let mask = preloadedMask {
            // Use preloaded mask immediately
            withAnimation(.easeOut(duration: 0.15)) {
                editableMaskImage = mask
            }
            // Trigger composite preloading for the next step
            triggerCompositePreload()
        } else {
            // Fall back to async merge
            let masks = segmentations.flatMap { $0.selectedMasks }

            Task {
                let mergedMask = await Task.detached(priority: .userInitiated) {
                    ImageService.shared.mergeMasks(masks)
                }.value

                await MainActor.run {
                    if let mask = mergedMask {
                        withAnimation(.easeOut(duration: 0.15)) {
                            editableMaskImage = mask
                        }
                        // Trigger composite preloading
                        triggerCompositePreload()
                    }
                }
            }
        }
    }

    /// Trigger preloading of composite image when mask is ready
    func triggerCompositePreload() {
        guard let source = inputImage, let mask = editableMaskImage else { return }
        preloadManager.preloadComposite(source: source, mask: mask)
    }

    /// Merge all selected masks from all segmentations using OR operation
    func mergeAllSelectedMasks() -> NSImage? {
        let masks = segmentations.flatMap { $0.selectedMasks }
        return ImageService.shared.mergeMasks(masks)
    }

    func saveUndoState() {
        guard let currentMask = editableMaskImage else { return }
        maskHistory.append(currentMask)
        // Limit history to 10 to prevent excessive memory usage with large images
        // Each mask image for a 4K image is ~64MB (4096x4096x4 bytes)
        if maskHistory.count > 10 {
            maskHistory.removeFirst()
        }
    }

    func undo() {
        guard !maskHistory.isEmpty else { return }
        editableMaskImage = maskHistory.removeLast()
    }

    /// Start a new paint stroke
    func startStroke(at point: CGPoint) {
        let normalizedBrushSize = brushSize / 1000.0
        currentStroke = PaintStroke(startPoint: point, brushSize: normalizedBrushSize, isErasing: brushMode == .remove)
    }

    /// Add a point to the current stroke (with interpolation for smooth lines)
    func addStrokePoint(_ point: CGPoint) {
        guard currentStroke != nil else { return }

        // Interpolate from last point if needed
        if let lastPoint = lastBrushPoint {
            let dx = point.x - lastPoint.x
            let dy = point.y - lastPoint.y
            let distance = sqrt(dx * dx + dy * dy)

            // Interpolation step size (relative to brush size for smooth coverage)
            let stepSize = (brushSize / 1000.0) * 0.3
            let steps = max(1, Int(distance / stepSize))

            for i in 1...steps {
                let t = CGFloat(i) / CGFloat(steps)
                let interpPoint = CGPoint(
                    x: lastPoint.x + dx * t,
                    y: lastPoint.y + dy * t
                )
                currentStroke?.addPoint(interpPoint)
            }
        } else {
            currentStroke?.addPoint(point)
        }

        lastBrushPoint = point
    }

    /// Finish the stroke and apply it to the mask
    func finishStroke() {
        guard let stroke = currentStroke, !stroke.points.isEmpty else {
            currentStroke = nil
            lastBrushPoint = nil
            return
        }

        // Apply all stroke points to mask at once (much faster than per-point)
        if let maskImage = editableMaskImage,
           let newImage = ImageService.shared.applyStroke(
               to: maskImage,
               points: stroke.points,
               size: stroke.brushSize,
               isErasing: stroke.isErasing
           ) {
            editableMaskImage = newImage
            hasMaskEdits = true  // User made an actual edit
        }

        currentStroke = nil
        lastBrushPoint = nil
        onMaskEditComplete()
    }

    /// Legacy single-point paint (kept for tap gestures)
    func paintOnMask(at normalized: CGPoint) {
        guard let maskImage = editableMaskImage else { return }

        let normalizedBrushSize = brushSize / 1000.0

        if let newImage = ImageService.shared.applyBrush(
            to: maskImage,
            at: normalized,
            size: normalizedBrushSize,
            isErasing: brushMode == .remove
        ) {
            editableMaskImage = newImage
        }
    }

    /// Called when mask editing is complete (stroke ended)
    /// Triggers preloading of composite for faster transition
    func onMaskEditComplete() {
        // Invalidate existing composite since mask changed
        compositeImage = nil
        // Invalidate previous preloaded composite since mask changed
        preloadManager.clearPreloadedComposite()
        // Start new composite preload
        triggerCompositePreload()
    }
}
