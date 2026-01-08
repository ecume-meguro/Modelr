import SwiftUI

// MARK: - Touchup
extension SimpleEditorViewModel {

    func startTouchup() {
        // Validate we have masks before transitioning
        guard totalValidMasks > 0 else { return }

        // Clear history immediately
        maskHistory.removeAll()

        // Try to use preloaded mask first (faster UX)
        let preloadedMask = preloadManager.getPreloadedComposite() != nil
            ? nil  // If composite is preloaded, we don't need the mask separately
            : preloadManager.preloadedMergedMask

        // Animate step change FIRST for immediate UI response
        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
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

    func paintOnMask(at normalized: CGPoint) {
        guard let maskImage = editableMaskImage else { return }

        // Normalize brush size relative to image (it was previously using / 1000.0)
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
        // Invalidate previous preloaded composite since mask changed
        preloadManager.clearPreloadedComposite()
        // Start new composite preload
        triggerCompositePreload()
    }
}
