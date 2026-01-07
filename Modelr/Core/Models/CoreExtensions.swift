import Foundation
import CoreGraphics

// MARK: - Safe Array Subscript

extension Array {
    subscript(safe index: Index) -> Element? {
        return indices.contains(index) ? self[index] : nil
    }
}

// MARK: - Coordinate Extensions

extension CGPoint {
    /// Convert normalized (0-1) coords to view coords
    func toViewCoords(_ viewSize: CGSize) -> CGPoint {
        CGPoint(x: x * viewSize.width, y: y * viewSize.height)
    }

    /// Convert view coords to normalized (0-1) coords
    func toNormalized(_ viewSize: CGSize) -> CGPoint {
        CGPoint(x: x / viewSize.width, y: y / viewSize.height)
    }

    /// Clamp to 0-1 range
    var clamped: CGPoint {
        CGPoint(
            x: max(0, min(1, x)),
            y: max(0, min(1, y))
        )
    }
}
