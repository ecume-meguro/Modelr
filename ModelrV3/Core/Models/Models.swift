import Foundation
import SwiftUI

// MARK: - Safe Array Subscript

extension Array {
    subscript(safe index: Index) -> Element? {
        return indices.contains(index) ? self[index] : nil
    }
}

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

// MARK: - Point Model (Supports positive and negative points)
struct SAMPoint: Hashable, Identifiable, Equatable, Codable {
    let id: UUID
    let normalizedCoords: CGPoint  // 0-1 range, relative to image
    let label: Int  // 1 = foreground (include), 0 = background (exclude)
    let dateAdded: Date

    init(normalizedCoords: CGPoint, label: Int = 1) {
        self.id = UUID()
        self.normalizedCoords = normalizedCoords
        self.label = label
        self.dateAdded = Date()
    }

    var isPositive: Bool { label == 1 }
    var isNegative: Bool { label == 0 }

    static func == (lhs: SAMPoint, rhs: SAMPoint) -> Bool {
        lhs.normalizedCoords.x == rhs.normalizedCoords.x &&
        lhs.normalizedCoords.y == rhs.normalizedCoords.y &&
        lhs.label == rhs.label
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(normalizedCoords.x)
        hasher.combine(normalizedCoords.y)
        hasher.combine(label)
    }

    /// Convert normalized coords to pixel coords for Python backend
    func pixelCoords(for imageSize: CGSize) -> (x: Int, y: Int) {
        (
            x: Int(normalizedCoords.x * imageSize.width),
            y: Int(normalizedCoords.y * imageSize.height)
        )
    }

    // Custom Codable for CGPoint
    enum CodingKeys: String, CodingKey {
        case id, label, dateAdded, coordX, coordY
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        label = try container.decode(Int.self, forKey: .label)
        dateAdded = try container.decode(Date.self, forKey: .dateAdded)
        let x = try container.decode(CGFloat.self, forKey: .coordX)
        let y = try container.decode(CGFloat.self, forKey: .coordY)
        normalizedCoords = CGPoint(x: x, y: y)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(label, forKey: .label)
        try container.encode(dateAdded, forKey: .dateAdded)
        try container.encode(normalizedCoords.x, forKey: .coordX)
        try container.encode(normalizedCoords.y, forKey: .coordY)
    }
}

// MARK: - Bounding Box Model
struct SAMBox: Hashable, Identifiable, Equatable, Codable {
    let id: UUID
    var startPoint: CGPoint  // Normalized 0-1
    var endPoint: CGPoint    // Normalized 0-1
    let dateAdded: Date

    init(startPoint: CGPoint, endPoint: CGPoint) {
        self.id = UUID()
        self.startPoint = startPoint
        self.endPoint = endPoint
        self.dateAdded = Date()
    }

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

    // Custom Codable for CGPoints
    enum CodingKeys: String, CodingKey {
        case id, dateAdded, startX, startY, endX, endY
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        dateAdded = try container.decode(Date.self, forKey: .dateAdded)
        let sx = try container.decode(CGFloat.self, forKey: .startX)
        let sy = try container.decode(CGFloat.self, forKey: .startY)
        let ex = try container.decode(CGFloat.self, forKey: .endX)
        let ey = try container.decode(CGFloat.self, forKey: .endY)
        startPoint = CGPoint(x: sx, y: sy)
        endPoint = CGPoint(x: ex, y: ey)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(dateAdded, forKey: .dateAdded)
        try container.encode(startPoint.x, forKey: .startX)
        try container.encode(startPoint.y, forKey: .startY)
        try container.encode(endPoint.x, forKey: .endX)
        try container.encode(endPoint.y, forKey: .endY)
    }
}

// MARK: - Tool Selection
enum SAMTool: String, CaseIterable, Identifiable {
    case point = "Point"
    case boundingBox = "Box"
    case lasso = "Lasso"
    case paint = "Paint"
    case polygon = "Polygon"

    var id: String { rawValue }

    var iconName: String {
        switch self {
        case .point: return "hand.point.up.left"
        case .boundingBox: return "rectangle.dashed"
        case .lasso: return "lasso"
        case .paint: return "paintbrush.pointed"
        case .polygon: return "pentagon"
        }
    }
}

// MARK: - Polygon Selection Model
struct PolygonSelection: Identifiable, Equatable, Codable {
    let id: UUID
    var vertices: [CGPoint]  // Normalized 0-1 coordinates
    var isClosed: Bool
    let dateAdded: Date

    init(vertices: [CGPoint] = [], isClosed: Bool = false) {
        self.id = UUID()
        self.vertices = vertices
        self.isClosed = isClosed
        self.dateAdded = Date()
    }

    mutating func addVertex(_ point: CGPoint) {
        vertices.append(point)
    }

    mutating func close() {
        isClosed = true
    }

    /// Check if polygon is valid (has at least 3 vertices)
    var isValid: Bool {
        vertices.count >= 3
    }

    /// Get bounding box of polygon for SAM
    var boundingBox: SAMBox? {
        guard isValid else { return nil }
        let xs = vertices.map { $0.x }
        let ys = vertices.map { $0.y }
        guard let minX = xs.min(), let maxX = xs.max(),
              let minY = ys.min(), let maxY = ys.max() else { return nil }
        return SAMBox(startPoint: CGPoint(x: minX, y: minY), endPoint: CGPoint(x: maxX, y: maxY))
    }

    /// Convert polygon to a mask image using Core Graphics
    func toMask(size: CGSize) -> NSImage? {
        guard isValid else { return nil }

        let image = NSImage(size: size)
        image.lockFocus()

        // Fill with transparent
        NSColor.clear.setFill()
        NSBezierPath(rect: NSRect(origin: .zero, size: size)).fill()

        // Draw polygon filled with white
        let path = NSBezierPath()
        let scaledVertices = vertices.map { CGPoint(x: $0.x * size.width, y: (1 - $0.y) * size.height) }

        if let first = scaledVertices.first {
            path.move(to: first)
            for vertex in scaledVertices.dropFirst() {
                path.line(to: vertex)
            }
            path.close()
        }

        NSColor.white.setFill()
        path.fill()

        image.unlockFocus()
        return image
    }

    // Custom Codable for [CGPoint] array
    enum CodingKeys: String, CodingKey {
        case id, isClosed, dateAdded, vertices
    }

    struct CodablePoint: Codable {
        let x: CGFloat
        let y: CGFloat
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        isClosed = try container.decode(Bool.self, forKey: .isClosed)
        dateAdded = try container.decode(Date.self, forKey: .dateAdded)
        let codableVertices = try container.decode([CodablePoint].self, forKey: .vertices)
        vertices = codableVertices.map { CGPoint(x: $0.x, y: $0.y) }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(isClosed, forKey: .isClosed)
        try container.encode(dateAdded, forKey: .dateAdded)
        let codableVertices = vertices.map { CodablePoint(x: $0.x, y: $0.y) }
        try container.encode(codableVertices, forKey: .vertices)
    }
}

// MARK: - Preprocess Tool Selection
enum PreprocessTool: String, CaseIterable, Identifiable {
    case crop = "Crop"
    case polygonCrop = "Polygon Crop"

    var id: String { rawValue }

    var iconName: String {
        switch self {
        case .crop: return "crop"
        case .polygonCrop: return "lasso.and.sparkles"
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
    let labels: [Int]?    // [1, 1, 0, ...] - 1=foreground, 0=background
    let box: [Int]?       // [x1, y1, x2, y2]
    let text: String?     // Text prompt for SAM3 (e.g., "dog", "person")
    let model: String?

    init(command: String, imagePath: String? = nil, points: [[Int]]? = nil, labels: [Int]? = nil, box: [Int]? = nil, text: String? = nil, model: String? = nil) {
        self.messageId = UUID().uuidString
        self.version = Self.version
        self.command = command
        self.imagePath = imagePath
        self.points = points
        self.labels = labels
        self.box = box
        self.text = text
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
    let masks: [String]?      // Multiple mask paths
    let scores: [Double]?     // Confidence scores for each mask
    let selectedIndex: Int?   // Currently selected mask index
    let maskPath: String?     // Legacy single mask path
    let imagePath: String?    // Path to processed image (e.g. background removed)
    let error: String?
    let inferenceTimeMs: Int?
    let ready: Bool?
    let score: Double?        // Legacy field, use scores instead
    let confidenceMapPath: String?  // Per-pixel confidence heatmap
    let width: Int?           // Image width from set_image
    let height: Int?          // Image height from set_image

    var primaryMaskPath: String? {
        return masks?.first ?? maskPath
    }

    var primaryScore: Double? {
        return scores?.first ?? score
    }

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
