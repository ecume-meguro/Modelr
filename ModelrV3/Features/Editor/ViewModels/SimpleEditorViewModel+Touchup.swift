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
