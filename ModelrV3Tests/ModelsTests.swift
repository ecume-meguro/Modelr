import XCTest
@testable import ModelrV3

final class ModelsTests: XCTestCase {
    
    override func setUpWithError() throws {
    }
    
    override func tearDownWithError() throws {
    }
    
    // MARK: - SAMPoint Tests
    
    func testSAMPointPixelCoords() throws {
        let imageSize = CGSize(width: 100, height: 100)
        
        let point = SAMPoint(normalizedCoords: CGPoint(x: 0.5, y: 0.5))
        let pixelCoords = point.pixelCoords(for: imageSize)
        
        XCTAssertEqual(pixelCoords.x, 50, "X coordinate should be 50")
        XCTAssertEqual(pixelCoords.y, 50, "Y coordinate should be 50")
    }
    
    func testSAMPointPixelCoordsCorner() throws {
        let imageSize = CGSize(width: 200, height: 150)
        
        let point = SAMPoint(normalizedCoords: CGPoint(x: 0.75, y: 0.66))
        let pixelCoords = point.pixelCoords(for: imageSize)
        
        XCTAssertEqual(pixelCoords.x, 150, "X coordinate should be 150")
        XCTAssertEqual(pixelCoords.y, 99, "Y coordinate should be 99 (150 * 0.66)")
    }
    
    func testSAMPointPixelCoordsBoundary() throws {
        let imageSize = CGSize(width: 100, height: 100)
        
        let topLeft = SAMPoint(normalizedCoords: CGPoint(x: 0, y: 0))
        let bottomRight = SAMPoint(normalizedCoords: CGPoint(x: 1, y: 1))
        
        XCTAssertEqual(topLeft.pixelCoords(for: imageSize).x, 0)
        XCTAssertEqual(topLeft.pixelCoords(for: imageSize).y, 0)
        XCTAssertEqual(bottomRight.pixelCoords(for: imageSize).x, 100)
        XCTAssertEqual(bottomRight.pixelCoords(for: imageSize).y, 100)
    }
    
    func testSAMPointIdentity() throws {
        let point1 = SAMPoint(normalizedCoords: CGPoint(x: 0.5, y: 0.5))
        let point2 = SAMPoint(normalizedCoords: CGPoint(x: 0.5, y: 0.5))
        
        XCTAssertEqual(point1, point2, "Equal points should be equal")
        XCTAssertTrue(point1.id == point2.id, "UUID should be unique per instance")
    }
    
    // MARK: - SAMBox Tests
    
    func testSAMBoxNormalizedRect() throws {
        let box = SAMBox(startPoint: CGPoint(x: 0.2, y: 0.3), endPoint: CGPoint(x: 0.8, y: 0.7))
        let rect = box.normalizedRect
        
        XCTAssertEqual(rect.minX, 0.2, accuracy: 0.001)
        XCTAssertEqual(rect.minY, 0.3, accuracy: 0.001)
        XCTAssertEqual(rect.maxX, 0.8, accuracy: 0.001)
        XCTAssertEqual(rect.maxY, 0.7, accuracy: 0.001)
    }
    
    func testSAMBoxInvertedDrag() throws {
        let box = SAMBox(startPoint: CGPoint(x: 0.8, y: 0.7), endPoint: CGPoint(x: 0.2, y: 0.3))
        let rect = box.normalizedRect
        
        XCTAssertEqual(rect.minX, 0.2, accuracy: 0.001, "Should normalize inverted X")
        XCTAssertEqual(rect.minY, 0.3, accuracy: 0.001, "Should normalize inverted Y")
        XCTAssertEqual(rect.maxX, 0.8, accuracy: 0.001)
        XCTAssertEqual(rect.maxY, 0.7, accuracy: 0.001)
    }
    
    func testSAMBoxPixelBox() throws {
        let imageSize = CGSize(width: 200, height: 150)
        let box = SAMBox(startPoint: CGPoint(x: 0.1, y: 0.2), endPoint: CGPoint(x: 0.9, y: 0.8))
        let pixelBox = box.pixelBox(for: imageSize)
        
        XCTAssertEqual(pixelBox[0], 20, "x1")
        XCTAssertEqual(pixelBox[1], 30, "y1")
        XCTAssertEqual(pixelBox[2], 180, "x2")
        XCTAssertEqual(pixelBox[3], 120, "y2")
    }
    
    func testSAMBoxValidity() throws {
        let validBox = SAMBox(startPoint: CGPoint(x: 0.1, y: 0.1), endPoint: CGPoint(x: 0.9, y: 0.9))
        XCTAssertTrue(validBox.isValid, "Box with 80% size should be valid")
        
        let invalidBox = SAMBox(startPoint: CGPoint(x: 0.49, y: 0.49), endPoint: CGPoint(x: 0.51, y: 0.51))
        XCTAssertFalse(invalidBox.isValid, "Box with 2% size should be invalid")
        
        let tinyBox = SAMBox(startPoint: CGPoint(x: 0.5, y: 0.5), endPoint: CGPoint(x: 0.5005, y: 0.5005))
        XCTAssertFalse(tinyBox.isValid, "Tiny box should be invalid")
    }
    
    func testSAMBoxIdentity() throws {
        let box1 = SAMBox(startPoint: CGPoint(x: 0.1, y: 0.1), endPoint: CGPoint(x: 0.9, y: 0.9))
        let box2 = SAMBox(startPoint: CGPoint(x: 0.1, y: 0.1), endPoint: CGPoint(x: 0.9, y: 0.9))
        
        XCTAssertEqual(box1, box2, "Equal boxes should be equal")
        XCTAssertNotEqual(box1.id, box2.id, "UUID should be unique")
    }
    
    // MARK: - LassoSelection Tests
    
    func testLassoInitialization() throws {
        let startPoint = CGPoint(x: 0.5, y: 0.5)
        let lasso = LassoSelection(startPoint: startPoint)
        
        XCTAssertEqual(lasso.points.count, 1, "Should start with one point")
        XCTAssertEqual(lasso.points.first, startPoint, "First point should match")
        XCTAssertFalse(lasso.isValid, "Single point lasso should be invalid")
    }
    
    func testLassoAddPoint() throws {
        var lasso = LassoSelection(startPoint: CGPoint(x: 0.5, y: 0.5))
        
        lasso.addPoint(CGPoint(x: 0.6, y: 0.5))
        XCTAssertEqual(lasso.points.count, 2, "Should have 2 points after adding")
        
        lasso.addPoint(CGPoint(x: 0.6, y: 0.6))
        XCTAssertEqual(lasso.points.count, 3, "Should have 3 points")
    }
    
    func testLassoPointFiltering() throws {
        var lasso = LassoSelection(startPoint: CGPoint(x: 0.5, y: 0.5))
        let initialCount = lasso.points.count
        
        let nearPoint = CGPoint(x: 0.5001, y: 0.5)
        lasso.addPoint(nearPoint)
        
        XCTAssertEqual(lasso.points.count, initialCount, "Very close point should be filtered")
        
        let farPoint = CGPoint(x: 0.6, y: 0.6)
        lasso.addPoint(farPoint)
        
        XCTAssertEqual(lasso.points.count, initialCount + 1, "Far point should be added")
    }
    
    func testLassoBoundingBox() throws {
        let points = [
            CGPoint(x: 0.2, y: 0.2),
            CGPoint(x: 0.8, y: 0.3),
            CGPoint(x: 0.5, y: 0.9)
        ]
        var lasso = LassoSelection(startPoint: points[0])
        for point in points.dropFirst() {
            lasso.addPoint(point)
        }
        
        let box = lasso.boundingBox
        XCTAssertNotNil(box, "Should generate bounding box")
        XCTAssertEqual(box!.normalizedRect.minX, 0.2, accuracy: 0.001)
        XCTAssertEqual(box!.normalizedRect.maxX, 0.8, accuracy: 0.001)
    }
    
    func testLassoValidity() throws {
        let twoPoints = [CGPoint(x: 0.1, y: 0.1), CGPoint(x: 0.2, y: 0.2)]
        var smallLasso = LassoSelection(startPoint: twoPoints[0])
        smallLasso.addPoint(twoPoints[1])
        XCTAssertFalse(smallLasso.isValid, "2 points should be invalid")
        
        let threePoints = [
            CGPoint(x: 0.1, y: 0.1),
            CGPoint(x: 0.5, y: 0.5),
            CGPoint(x: 0.9, y: 0.1)
        ]
        var validLasso = LassoSelection(startPoint: threePoints[0])
        for point in threePoints.dropFirst() {
            validLasso.addPoint(point)
        }
        XCTAssertTrue(validLasso.isValid, "3+ points should be valid")
    }
    
    // MARK: - PaintStroke Tests
    
    func testPaintStrokeInitialization() throws {
        let startPoint = CGPoint(x: 0.5, y: 0.5)
        let stroke = PaintStroke(startPoint: startPoint, brushSize: 0.03, isErasing: false)
        
        XCTAssertEqual(stroke.points.count, 1, "Should start with one point")
        XCTAssertEqual(stroke.brushSize, 0.03, accuracy: 0.001)
        XCTAssertFalse(stroke.isErasing, "Should not be in erase mode")
    }
    
    func testPaintStrokeEraseMode() throws {
        let stroke = PaintStroke(startPoint: CGPoint(x: 0.5, y: 0.5), brushSize: 0.05, isErasing: true)
        
        XCTAssertTrue(stroke.isErasing, "Should be in erase mode")
        XCTAssertEqual(stroke.brushSize, 0.05, accuracy: 0.001)
    }
    
    func testPaintStrokeAddPoint() throws {
        var stroke = PaintStroke(startPoint: CGPoint(x: 0.5, y: 0.5), brushSize: 0.03)
        stroke.addPoint(CGPoint(x: 0.6, y: 0.6))
        stroke.addPoint(CGPoint(x: 0.7, y: 0.7))
        
        XCTAssertEqual(stroke.points.count, 3, "Should have 3 points")
    }
    
    func testPaintStrokePointFiltering() throws {
        var stroke = PaintStroke(startPoint: CGPoint(x: 0.5, y: 0.5), brushSize: 0.03)
        let initialCount = stroke.points.count
        
        stroke.addPoint(CGPoint(x: 0.5001, y: 0.5))
        XCTAssertEqual(stroke.points.count, initialCount, "Close point should be filtered")
        
        stroke.addPoint(CGPoint(x: 0.55, y: 0.55))
        XCTAssertEqual(stroke.points.count, initialCount + 1, "Far point should be added")
    }
    
    func testEmptyCollections() throws {
        let emptyPoint = SAMPoint(normalizedCoords: .zero)
        XCTAssertNotNil(emptyPoint, "Should create point at origin")
        
        let box = SAMBox(startPoint: .zero, endPoint: .zero)
        XCTAssertFalse(box.isValid, "Zero-size box should be invalid")
        
        let lasso = LassoSelection(startPoint: .zero)
        XCTAssertEqual(lasso.points.count, 1, "Lasso should have initial point")
        XCTAssertFalse(lasso.isValid, "Single-point lasso should be invalid")
        
        let stroke = PaintStroke(startPoint: .zero, brushSize: 0.03)
        XCTAssertEqual(stroke.points.count, 1, "Stroke should have initial point")
    }
    
    // MARK: - SAMTool and PreprocessTool Tests
    
    func testSAMToolCases() throws {
        XCTAssertEqual(SAMTool.allCases.count, 4, "Should have 4 tools")
        XCTAssertTrue(SAMTool.allCases.contains(.point))
        XCTAssertTrue(SAMTool.allCases.contains(.boundingBox))
        XCTAssertTrue(SAMTool.allCases.contains(.lasso))
        XCTAssertTrue(SAMTool.allCases.contains(.paint))
    }
    
    func testSAMToolIcons() throws {
        XCTAssertFalse(SAMTool.point.iconName.isEmpty)
        XCTAssertFalse(SAMTool.boundingBox.iconName.isEmpty)
        XCTAssertFalse(SAMTool.lasso.iconName.isEmpty)
        XCTAssertFalse(SAMTool.paint.iconName.isEmpty)
    }
    
    func testPreprocessToolCases() throws {
        XCTAssertEqual(PreprocessTool.allCases.count, 2, "Should have 2 preprocess tools")
        XCTAssertTrue(PreprocessTool.allCases.contains(.crop))
        XCTAssertTrue(PreprocessTool.allCases.contains(.lassoDelete))
    }
}
