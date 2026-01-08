import SwiftUI

// MARK: - Touchup
extension SimpleEditorViewModel {

    func startTouchup() {
        // Validate we have masks before transitioning
        guard totalValidMasks > 0 else { return }

        // Clear history immediately
        maskHistory.removeAll()

        // Capture masks on main actor before detaching
        let masks = segmentations.flatMap { $0.selectedMasks }

        // Animate step change FIRST for immediate UI response
        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
            currentStep = .touchup
        }

        // Merge masks async to avoid blocking the animation
        Task {
            let mergedMask = await Task.detached(priority: .userInitiated) {
                ImageService.shared.mergeMasks(masks)
            }.value

            await MainActor.run {
                if let mask = mergedMask {
                    withAnimation(.easeOut(duration: 0.15)) {
                        editableMaskImage = mask
                    }
                }
            }
        }
    }

    /// Merge all selected masks from all segmentations using OR operation
    func mergeAllSelectedMasks() -> NSImage? {
        let masks = segmentations.flatMap { $0.selectedMasks }
        return ImageService.shared.mergeMasks(masks)
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
}
