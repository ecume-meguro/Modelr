import Foundation
import SwiftUI

enum ModelError: Error, LocalizedError {
    case invalidCommand(String)
    case missingRequiredField(String)
    case invalidPointValue
    case invalidBoxValue
    case versionMismatch(String)
    case unexpectedResponse(String)

    var errorDescription: String? {
        switch self {
        case .invalidCommand(let cmd):
            return "Invalid command: \(cmd)"
        case .missingRequiredField(let field):
            return "Missing required field: \(field)"
        case .invalidPointValue:
            return "Invalid point value"
        case .invalidBoxValue:
            return "Invalid box value"
        case .versionMismatch(let expected):
            return "Version mismatch: \(expected)"
        case .unexpectedResponse(let msg):
            return "Unexpected response: \(msg)"
        }
    }
}

// MARK: - Point Model (Positive points only)
struct SAMPoint: Hashable, Identifiable, Equatable {
    let id = UUID()
    let normalizedCoords: CGPoint  // 0-1 range, relative to image
    let dateAdded = Date()

    static func == (lhs: SAMPoint, rhs: SAMPoint) -> Bool {
        lhs.normalizedCoords.x == rhs.normalizedCoords.x &&
        lhs.normalizedCoords.y == rhs.normalizedCoords.y
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(normalizedCoords.x)
        hasher.combine(normalizedCoords.y)
    }

    /// Convert normalized coords to pixel coords for Python backend
    func pixelCoords(for imageSize: CGSize) -> (x: Int, y: Int) {
        (
            x: Int(normalizedCoords.x * imageSize.width),
            y: Int(normalizedCoords.y * imageSize.height)
        )
    }
}

// MARK: - Bounding Box Model
struct SAMBox: Hashable, Identifiable, Equatable {
    let id = UUID()
    var startPoint: CGPoint  // Normalized 0-1
    var endPoint: CGPoint    // Normalized 0-1
    let dateAdded = Date()

    static func == (lhs: SAMBox, rhs: SAMBox) -> Bool {
        lhs.startPoint.x == rhs.startPoint.x &&
        lhs.startPoint.y == rhs.startPoint.y &&
        lhs.endPoint.x == rhs.endPoint.x &&
        lhs.endPoint.y == rhs.endPoint.y
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(startPoint.x)
        hasher.combine(startPoint.y)
        hasher.combine(endPoint.x)
        hasher.combine(endPoint.y)
    }

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

    /// Check if box has meaningful size (> 5% of image in both dimensions)
    var isValid: Bool {
        let rect = normalizedRect
        return rect.width > 0.05 && rect.height > 0.05
    }
}

// MARK: - Tool Selection
enum SAMTool: String, CaseIterable, Identifiable {
    case point = "Point"
    case boundingBox = "Box"
    case lasso = "Lasso"
    case paint = "Paint"

    var id: String { rawValue }

    var iconName: String {
        switch self {
        case .point: return "hand.point.up.left"
        case .boundingBox: return "rectangle.dashed"
        case .lasso: return "lasso"
        case .paint: return "paintbrush.pointed"
        }
    }
}

// MARK: - Preprocess Tool Selection
enum PreprocessTool: String, CaseIterable, Identifiable {
    case crop = "Crop"
    case lassoDelete = "Lasso Delete"

    var id: String { rawValue }

    var iconName: String {
        switch self {
        case .crop: return "crop"
        case .lassoDelete: return "lasso.and.sparkles"
        }
    }
}

// MARK: - Lasso Selection Model
struct LassoSelection: Equatable, Identifiable {
    let id = UUID()
    var points: [CGPoint]  // Normalized 0-1 coordinates
    let dateAdded = Date()

    init(startPoint: CGPoint) {
        self.points = [startPoint]
    }

    mutating func addPoint(_ point: CGPoint) {
        // Only add if moved enough to avoid too many points
        if let last = points.last {
            let dx = point.x - last.x
            let dy = point.y - last.y
            let distance = sqrt(dx*dx + dy*dy)
            if distance > 0.003 {  // ~0.3% of image
                points.append(point)
            }
        } else {
            points.append(point)
        }
    }

    /// Get bounding box of the lasso selection (for SAM2)
    var boundingBox: SAMBox? {
        guard points.count >= 3 else { return nil }
        var minX = CGFloat.greatestFiniteMagnitude
        var maxX = -CGFloat.greatestFiniteMagnitude
        var minY = CGFloat.greatestFiniteMagnitude
        var maxY = -CGFloat.greatestFiniteMagnitude

        for point in points {
            minX = min(minX, point.x)
            maxX = max(maxX, point.x)
            minY = min(minY, point.y)
            maxY = max(maxY, point.y)
        }

        return SAMBox(startPoint: CGPoint(x: minX, y: minY),
                      endPoint: CGPoint(x: maxX, y: maxY))
    }

    /// Check if lasso has enough points to be valid
    var isValid: Bool {
        points.count >= 3
    }
}

// MARK: - Paint Stroke Model
struct PaintStroke: Equatable, Identifiable {
    let id = UUID()
    var points: [CGPoint]  // Normalized 0-1 coordinates
    let brushSize: CGFloat  // Normalized brush size (relative to image width)
    let isErasing: Bool     // true = erase, false = add to mask

    init(startPoint: CGPoint, brushSize: CGFloat, isErasing: Bool = false) {
        self.points = [startPoint]
        self.brushSize = brushSize
        self.isErasing = isErasing
    }

    mutating func addPoint(_ point: CGPoint) {
        // Only add if moved enough (to avoid too many points)
        if let last = points.last {
            let dx = point.x - last.x
            let dy = point.y - last.y
            let distance = sqrt(dx*dx + dy*dy)
            // Add point if moved at least 0.5% of image
            if distance > 0.005 {
                points.append(point)
            }
        } else {
            points.append(point)
        }
    }
}

// MARK: - Python Communication Protocol

struct SAMRequest: Codable {
    static let version = "1.0"
    static let maxPoints = 100

    let messageId: String
    let version: String
    let command: String  // "set_image", "predict", "reset"
    let imagePath: String?
    let points: [[Int]]?  // [[x, y], [x, y], ...]
    let box: [Int]?       // [x1, y1, x2, y2]
    let model: String?

    init(command: String, imagePath: String? = nil, points: [[Int]]? = nil, box: [Int]? = nil, model: String? = nil) {
        self.messageId = UUID().uuidString
        self.version = Self.version
        self.command = command
        self.imagePath = imagePath
        self.points = points
        self.box = box
        self.model = model
    }

    func validate() throws {
        let validCommands = ["set_image", "predict", "reset"]
        guard validCommands.contains(command) else {
            throw ModelError.invalidCommand(command)
        }

        switch command {
        case "set_image":
            guard imagePath != nil && !imagePath!.isEmpty else {
                throw ModelError.missingRequiredField("imagePath")
            }

        case "predict":
            guard points != nil || box != nil else {
                throw ModelError.missingRequiredField("points or box")
            }

            if let points = points {
                guard points.count <= Self.maxPoints else {
                    throw ModelError.invalidPointValue
                }

                for point in points {
                    guard point.count == 2 else {
                        throw ModelError.invalidPointValue
                    }
                    guard point[0] >= 0 && point[1] >= 0 else {
                        throw ModelError.invalidPointValue
                    }
                }
            }

            if let box = box {
                guard box.count == 4 else {
                    throw ModelError.invalidBoxValue
                }
                guard box[0] >= 0 && box[1] >= 0 && box[2] > box[0] && box[3] > box[1] else {
                    throw ModelError.invalidBoxValue
                }
            }

        case "reset":
            break
        default:
            break
        }
    }
}

struct SAMResponse: Codable {
    let messageId: String?
    let version: String?
    let success: Bool
    let maskPath: String?
    let error: String?
    let inferenceTimeMs: Int?
    let ready: Bool?
    let score: Double?

    func validate() throws {
        if version != nil && version != SAMRequest.version {
            throw ModelError.versionMismatch(SAMRequest.version)
        }

        if !success {
            guard error != nil && !error!.isEmpty else {
                throw ModelError.unexpectedResponse("Error message required on failure")
            }
        }
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
