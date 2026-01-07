import SwiftUI

/// Represents a single segmentation with its own prompt and mask selection
struct SegmentationEntry: Identifiable {
    let id: UUID
    var name: String
    var textPrompt: String = ""
    var points: [SAMPoint] = []
    var allMasks: [(image: NSImage, score: Double, url: URL)] = []
    var selectedMaskIndices: Set<Int> = [0]  // Support multiple selections
    var isExpanded: Bool = true
    var isSearchPerformed: Bool = false
    var isProcessing: Bool = false

    init(name: String) {
        self.id = UUID()
        self.name = name
    }

    /// Returns the first selected mask (for single selection compatibility)
    var selectedMask: NSImage? {
        guard let firstIndex = selectedMaskIndices.sorted().first,
              firstIndex < allMasks.count else { return nil }
        return allMasks[firstIndex].image
    }

    /// Returns all selected masks
    var selectedMasks: [NSImage] {
        selectedMaskIndices.sorted().compactMap { index in
            guard index < allMasks.count else { return nil }
            return allMasks[index].image
        }
    }

    var hasValidMask: Bool {
        !allMasks.isEmpty && selectedMaskIndices.contains(where: { $0 < allMasks.count })
    }

    /// For backwards compatibility - returns first selected index
    var selectedMaskIndex: Int {
        selectedMaskIndices.sorted().first ?? 0
    }

    var promptDescription: String {
        if !textPrompt.isEmpty {
            return "\"\(textPrompt)\""
        } else if !points.isEmpty {
            return "\(points.count) point(s)"
        }
        return "Empty"
    }
}
