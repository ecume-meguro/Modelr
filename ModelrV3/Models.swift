import Foundation
import SwiftUI

// MARK: - Point Model (Positive points only)
struct SAMPoint: Hashable, Identifiable {
    let id = UUID()
    let normalizedCoords: CGPoint  // 0-1 range, relative to image
    let dateAdded = Date()

    /// Convert normalized coords to pixel coords for Python backend
    func pixelCoords(for imageSize: CGSize) -> (x: Int, y: Int) {
        (
            x: Int(normalizedCoords.x * imageSize.width),
            y: Int(normalizedCoords.y * imageSize.height)
        )
    }
}

// MARK: - Bounding Box Model
struct SAMBox: Hashable, Identifiable {
    let id = UUID()
    var startPoint: CGPoint  // Normalized 0-1
    var endPoint: CGPoint    // Normalized 0-1
    let dateAdded = Date()

    /// Normalized rectangle (handles inverted drag directions)
    var normalizedRect: CGRect {
        let minX = min(startPoint.x, endPoint.x)
        let minY = min(startPoint.y, endPoint.y)
        let maxX = max(startPoint.x, endPoint.x)
        let maxY = max(startPoint.y, endPoint.y)
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    /// Convert to pixel coords for Python backend [x1, y1, x2, y2]
    func pixelBox(for imageSize: CGSize) -> [Int] {
        let rect = normalizedRect
        return [
            Int(rect.minX * imageSize.width),
            Int(rect.minY * imageSize.height),
            Int(rect.maxX * imageSize.width),
            Int(rect.maxY * imageSize.height)
        ]
    }

    /// Check if box has meaningful size (> 1% of image in both dimensions)
    var isValid: Bool {
        let rect = normalizedRect
        return rect.width > 0.01 && rect.height > 0.01
    }
}

// MARK: - Tool Selection
enum SAMTool: String, CaseIterable, Identifiable {
    case point = "Point"
    case boundingBox = "Bounding Box"

    var id: String { rawValue }

    var iconName: String {
        switch self {
        case .point: return "hand.point.up.left"
        case .boundingBox: return "rectangle.dashed"
        }
    }
}

// MARK: - Python Communication Protocol

struct SAMRequest: Codable {
    let command: String  // "set_image", "predict", "reset"
    let imagePath: String?
    let points: [[Int]]?  // [[x, y], [x, y], ...]
    let box: [Int]?       // [x1, y1, x2, y2]
    let model: String?

    init(command: String, imagePath: String? = nil, points: [[Int]]? = nil, box: [Int]? = nil, model: String? = nil) {
        self.command = command
        self.imagePath = imagePath
        self.points = points
        self.box = box
        self.model = model
    }
}

struct SAMResponse: Codable {
    let success: Bool
    let maskPath: String?
    let error: String?
    let inferenceTimeMs: Int?
    let ready: Bool?
    let score: Double?
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
