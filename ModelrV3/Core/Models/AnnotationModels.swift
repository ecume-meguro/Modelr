import Foundation
import SwiftUI

enum WorkflowStep: Int, CaseIterable, Comparable, Codable {
    case input = 0
    case refine = 1
    case segment = 2
    case generate = 3

    var title: String {
        switch self {
        case .input: return "Input"
        case .refine: return "Refine"
        case .segment: return "Segment"
        case .generate: return "Generate"
        }
    }

    var icon: String {
        switch self {
        case .input: return "photo"
        case .refine: return "slider.horizontal.3"
        case .segment: return "square.dashed.inset.filled"
        case .generate: return "cube.transparent"
        }
    }

    static func < (lhs: WorkflowStep, rhs: WorkflowStep) -> Bool {
        return lhs.rawValue < rhs.rawValue
    }
}

enum UndoAction: Equatable {
    case addPoint(SAMPoint)
    case addBox(SAMBox)
    case addLasso(LassoSelection)
    case addPaintStroke(PaintStroke)
    case crop(originalImage: NSImage, originalPath: String?)
    case movePoint(from: SAMPoint, to: SAMPoint)
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
struct LassoSelection: Equatable, Identifiable, Codable {
    let id: UUID
    var points: [CGPoint]  // Normalized 0-1 coordinates
    let dateAdded: Date

    init(startPoint: CGPoint) {
        self.id = UUID()
        self.points = [startPoint]
        self.dateAdded = Date()
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
    
    // Custom Codable for [CGPoint] array
    enum CodingKeys: String, CodingKey {
        case id, dateAdded, points
    }

    struct CodablePoint: Codable {
        let x: CGFloat
        let y: CGFloat
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        dateAdded = try container.decode(Date.self, forKey: .dateAdded)
        let codablePoints = try container.decode([CodablePoint].self, forKey: .points)
        points = codablePoints.map { CGPoint(x: $0.x, y: $0.y) }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(dateAdded, forKey: .dateAdded)
        let codablePoints = points.map { CodablePoint(x: $0.x, y: $0.y) }
        try container.encode(codablePoints, forKey: .points)
    }
}

// MARK: - Paint Stroke Model
struct PaintStroke: Equatable, Identifiable, Codable {
    let id: UUID
    var points: [CGPoint]  // Normalized 0-1 coordinates
    let brushSize: CGFloat  // Normalized brush size (relative to image width)
    let isErasing: Bool     // true = erase, false = add to mask
    let dateAdded: Date

    init(startPoint: CGPoint, brushSize: CGFloat, isErasing: Bool = false) {
        self.id = UUID()
        self.points = [startPoint]
        self.brushSize = brushSize
        self.isErasing = isErasing
        self.dateAdded = Date()
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
    
    // Custom Codable for [CGPoint] array
    enum CodingKeys: String, CodingKey {
        case id, brushSize, isErasing, dateAdded, points
    }

    struct CodablePoint: Codable {
        let x: CGFloat
        let y: CGFloat
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        brushSize = try container.decode(CGFloat.self, forKey: .brushSize)
        isErasing = try container.decode(Bool.self, forKey: .isErasing)
        dateAdded = try container.decode(Date.self, forKey: .dateAdded)
        let codablePoints = try container.decode([CodablePoint].self, forKey: .points)
        points = codablePoints.map { CGPoint(x: $0.x, y: $0.y) }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(brushSize, forKey: .brushSize)
        try container.encode(isErasing, forKey: .isErasing)
        try container.encode(dateAdded, forKey: .dateAdded)
        let codablePoints = points.map { CodablePoint(x: $0.x, y: $0.y) }
        try container.encode(codablePoints, forKey: .points)
    }
}
