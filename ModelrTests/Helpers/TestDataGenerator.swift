import Foundation
import AppKit
@testable import Modelr

class TestDataGenerator {
    
    static func randomPoint() -> CGPoint {
        CGPoint(x: CGFloat.random(in: 0...1), y: CGFloat.random(in: 0...1))
    }
    
    static func randomPoint(in rect: CGRect) -> CGPoint {
        CGPoint(
            x: CGFloat.random(in: rect.minX...rect.maxX),
            y: CGFloat.random(in: rect.minY...rect.maxY)
        )
    }
    
    static func createSAMPoint(normalizedX: CGFloat, normalizedY: CGFloat) -> SAMPoint {
        SAMPoint(normalizedCoords: CGPoint(x: normalizedX, y: normalizedY))
    }
    
    static func createSAMBox(start: CGPoint, end: CGPoint) -> SAMBox {
        SAMBox(startPoint: start, endPoint: end)
    }
    
    static func createLassoSelection(points: [CGPoint]) -> LassoSelection {
        guard let firstPoint = points.first else {
            fatalError("LassoSelection requires at least one point")
        }
        var lasso = LassoSelection(startPoint: firstPoint)
        for point in points.dropFirst() {
            lasso.addPoint(point)
        }
        return lasso
    }
    
    static func createPaintStroke(points: [CGPoint], brushSize: CGFloat = 0.03, isErasing: Bool = false) -> PaintStroke {
        guard let firstPoint = points.first else {
            fatalError("PaintStroke requires at least one point")
        }
        var stroke = PaintStroke(startPoint: firstPoint, brushSize: brushSize, isErasing: isErasing)
        for point in points.dropFirst() {
            stroke.addPoint(point)
        }
        return stroke
    }
    
    static func createTestImage(width: Int = 100, height: Int = 100) -> NSImage {
        MockFileSystem.createTestImage(width: width, height: height)
    }
    
    static func createTestMask(width: Int = 100, height: Int = 100, opaqueRect: CGRect = .zero) -> NSImage {
        let rect = opaqueRect == .zero ? CGRect(x: 25, y: 25, width: 50, height: 50) : opaqueRect
        return MockFileSystem.createTestMask(width: width, height: height, opaqueRegion: rect)
    }
    
    static func createComplexLasso() -> LassoSelection {
        let center = CGPoint(x: 0.5, y: 0.5)
        let radius: CGFloat = 0.3
        let points: [CGPoint] = (0..<12).map { i in
            let angle = Double(i) * Double.pi / 6
            return CGPoint(
                x: center.x + CGFloat(cos(angle)) * radius,
                y: center.y + CGFloat(sin(angle)) * radius
            )
        }
        return createLassoSelection(points: points)
    }
}
