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

    // MARK: - SAMPoint Label Tests (Positive/Negative Points)

    func testSAMPointDefaultLabelIsPositive() throws {
        let point = SAMPoint(normalizedCoords: CGPoint(x: 0.5, y: 0.5))
        XCTAssertEqual(point.label, 1, "Default label should be 1 (foreground)")
        XCTAssertTrue(point.isPositive, "Default point should be positive")
        XCTAssertFalse(point.isNegative, "Default point should not be negative")
    }

    func testSAMPointPositiveLabel() throws {
        let point = SAMPoint(normalizedCoords: CGPoint(x: 0.5, y: 0.5), label: 1)
        XCTAssertEqual(point.label, 1, "Label should be 1")
        XCTAssertTrue(point.isPositive, "Point should be positive")
        XCTAssertFalse(point.isNegative, "Point should not be negative")
    }

    func testSAMPointNegativeLabel() throws {
        let point = SAMPoint(normalizedCoords: CGPoint(x: 0.5, y: 0.5), label: 0)
        XCTAssertEqual(point.label, 0, "Label should be 0")
        XCTAssertFalse(point.isPositive, "Point should not be positive")
        XCTAssertTrue(point.isNegative, "Point should be negative")
    }

    func testSAMPointEqualityIncludesLabel() throws {
        let positive = SAMPoint(normalizedCoords: CGPoint(x: 0.5, y: 0.5), label: 1)
        let negative = SAMPoint(normalizedCoords: CGPoint(x: 0.5, y: 0.5), label: 0)

        XCTAssertNotEqual(positive, negative, "Points with different labels should not be equal")

        let positive2 = SAMPoint(normalizedCoords: CGPoint(x: 0.5, y: 0.5), label: 1)
        XCTAssertEqual(positive, positive2, "Points with same coords and label should be equal")
    }

    func testSAMPointHashIncludesLabel() throws {
        var set = Set<SAMPoint>()
        let positive = SAMPoint(normalizedCoords: CGPoint(x: 0.5, y: 0.5), label: 1)
        let negative = SAMPoint(normalizedCoords: CGPoint(x: 0.5, y: 0.5), label: 0)

        set.insert(positive)
        set.insert(negative)

        XCTAssertEqual(set.count, 2, "Set should contain both points as they have different labels")
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
        XCTAssertNotEqual(point1.id, point2.id, "UUID should be unique per instance")
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
    
    // MARK: - PolygonSelection Tests

    func testPolygonInitialization() throws {
        let polygon = PolygonSelection()

        XCTAssertEqual(polygon.vertices.count, 0, "Should start with no vertices")
        XCTAssertFalse(polygon.isClosed, "Should not be closed initially")
        XCTAssertFalse(polygon.isValid, "Empty polygon should be invalid")
    }

    func testPolygonWithInitialVertices() throws {
        let vertices = [
            CGPoint(x: 0.1, y: 0.1),
            CGPoint(x: 0.5, y: 0.1),
            CGPoint(x: 0.3, y: 0.5)
        ]
        let polygon = PolygonSelection(vertices: vertices)

        XCTAssertEqual(polygon.vertices.count, 3, "Should have 3 vertices")
        XCTAssertFalse(polygon.isClosed, "Should not be closed by default")
        XCTAssertTrue(polygon.isValid, "Triangle should be valid")
    }

    func testPolygonAddVertex() throws {
        var polygon = PolygonSelection()

        polygon.addVertex(CGPoint(x: 0.1, y: 0.1))
        XCTAssertEqual(polygon.vertices.count, 1)
        XCTAssertFalse(polygon.isValid, "1 vertex should be invalid")

        polygon.addVertex(CGPoint(x: 0.5, y: 0.1))
        XCTAssertEqual(polygon.vertices.count, 2)
        XCTAssertFalse(polygon.isValid, "2 vertices should be invalid")

        polygon.addVertex(CGPoint(x: 0.3, y: 0.5))
        XCTAssertEqual(polygon.vertices.count, 3)
        XCTAssertTrue(polygon.isValid, "3 vertices should be valid")
    }

    func testPolygonClose() throws {
        var polygon = PolygonSelection(vertices: [
            CGPoint(x: 0.1, y: 0.1),
            CGPoint(x: 0.9, y: 0.1),
            CGPoint(x: 0.5, y: 0.9)
        ])

        XCTAssertFalse(polygon.isClosed, "Should not be closed initially")

        polygon.close()

        XCTAssertTrue(polygon.isClosed, "Should be closed after calling close()")
    }

    func testPolygonBoundingBox() throws {
        let polygon = PolygonSelection(vertices: [
            CGPoint(x: 0.2, y: 0.3),
            CGPoint(x: 0.8, y: 0.3),
            CGPoint(x: 0.8, y: 0.7),
            CGPoint(x: 0.2, y: 0.7)
        ])

        let box = polygon.boundingBox
        XCTAssertNotNil(box, "Should generate bounding box")

        let rect = box!.normalizedRect
        XCTAssertEqual(rect.minX, 0.2, accuracy: 0.001)
        XCTAssertEqual(rect.minY, 0.3, accuracy: 0.001)
        XCTAssertEqual(rect.maxX, 0.8, accuracy: 0.001)
        XCTAssertEqual(rect.maxY, 0.7, accuracy: 0.001)
    }

    func testPolygonBoundingBoxInvalidPolygon() throws {
        let polygon = PolygonSelection(vertices: [
            CGPoint(x: 0.5, y: 0.5),
            CGPoint(x: 0.6, y: 0.6)
        ])

        XCTAssertNil(polygon.boundingBox, "Invalid polygon should not have bounding box")
    }

    func testPolygonValidity() throws {
        let emptyPolygon = PolygonSelection()
        XCTAssertFalse(emptyPolygon.isValid, "Empty polygon should be invalid")

        let oneVertex = PolygonSelection(vertices: [CGPoint(x: 0.5, y: 0.5)])
        XCTAssertFalse(oneVertex.isValid, "1 vertex should be invalid")

        let twoVertices = PolygonSelection(vertices: [
            CGPoint(x: 0.1, y: 0.1),
            CGPoint(x: 0.9, y: 0.9)
        ])
        XCTAssertFalse(twoVertices.isValid, "2 vertices should be invalid")

        let threeVertices = PolygonSelection(vertices: [
            CGPoint(x: 0.1, y: 0.1),
            CGPoint(x: 0.9, y: 0.1),
            CGPoint(x: 0.5, y: 0.9)
        ])
        XCTAssertTrue(threeVertices.isValid, "3 vertices should be valid")
    }

    func testPolygonEquality() throws {
        let vertices = [
            CGPoint(x: 0.1, y: 0.1),
            CGPoint(x: 0.5, y: 0.1),
            CGPoint(x: 0.3, y: 0.5)
        ]

        let polygon1 = PolygonSelection(vertices: vertices)
        let polygon2 = PolygonSelection(vertices: vertices)

        // Different IDs means not equal
        XCTAssertNotEqual(polygon1.id, polygon2.id, "Each polygon should have unique ID")
    }

    func testPolygonToMask() throws {
        let polygon = PolygonSelection(vertices: [
            CGPoint(x: 0.2, y: 0.2),
            CGPoint(x: 0.8, y: 0.2),
            CGPoint(x: 0.8, y: 0.8),
            CGPoint(x: 0.2, y: 0.8)
        ], isClosed: true)

        let maskSize = CGSize(width: 100, height: 100)
        let mask = polygon.toMask(size: maskSize)

        XCTAssertNotNil(mask, "Valid polygon should generate mask")
        XCTAssertEqual(mask!.size.width, 100, accuracy: 0.001)
        XCTAssertEqual(mask!.size.height, 100, accuracy: 0.001)
    }

    func testPolygonToMaskInvalid() throws {
        let invalidPolygon = PolygonSelection(vertices: [
            CGPoint(x: 0.5, y: 0.5)
        ])

        let mask = invalidPolygon.toMask(size: CGSize(width: 100, height: 100))
        XCTAssertNil(mask, "Invalid polygon should not generate mask")
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
        XCTAssertEqual(SAMTool.allCases.count, 5, "Should have 5 tools")
        XCTAssertTrue(SAMTool.allCases.contains(.point))
        XCTAssertTrue(SAMTool.allCases.contains(.boundingBox))
        XCTAssertTrue(SAMTool.allCases.contains(.lasso))
        XCTAssertTrue(SAMTool.allCases.contains(.paint))
        XCTAssertTrue(SAMTool.allCases.contains(.polygon))
    }
    
    func testSAMToolIcons() throws {
        XCTAssertFalse(SAMTool.point.iconName.isEmpty)
        XCTAssertFalse(SAMTool.boundingBox.iconName.isEmpty)
        XCTAssertFalse(SAMTool.lasso.iconName.isEmpty)
        XCTAssertFalse(SAMTool.paint.iconName.isEmpty)
        XCTAssertFalse(SAMTool.polygon.iconName.isEmpty)
    }
    
    func testPreprocessToolCases() throws {
        XCTAssertEqual(PreprocessTool.allCases.count, 2, "Should have 2 preprocess tools")
        XCTAssertTrue(PreprocessTool.allCases.contains(.crop))
        XCTAssertTrue(PreprocessTool.allCases.contains(.lassoDelete))
    }

    // MARK: - SAMRequest Tests

    func testSAMRequestWithLabels() throws {
        let points = [[50, 50], [100, 100]]
        let labels = [1, 0]  // First positive, second negative

        let request = SAMRequest(
            command: "predict",
            points: points,
            labels: labels,
            box: nil
        )

        XCTAssertEqual(request.command, "predict")
        XCTAssertEqual(request.points?.count, 2)
        XCTAssertEqual(request.labels?.count, 2)
        XCTAssertEqual(request.labels?[0], 1, "First label should be positive")
        XCTAssertEqual(request.labels?[1], 0, "Second label should be negative")
    }

    func testSAMRequestWithoutLabels() throws {
        let points = [[50, 50]]

        let request = SAMRequest(
            command: "predict",
            points: points,
            labels: nil,
            box: nil
        )

        XCTAssertNil(request.labels, "Labels should be nil when not provided")
        XCTAssertEqual(request.points?.count, 1)
    }

    func testSAMRequestSetImageCommand() throws {
        let request = SAMRequest(
            command: "set_image",
            imagePath: "/path/to/image.png"
        )

        XCTAssertEqual(request.command, "set_image")
        XCTAssertEqual(request.imagePath, "/path/to/image.png")
        XCTAssertNil(request.points)
        XCTAssertNil(request.labels)
        XCTAssertNil(request.box)
    }

    func testSAMRequestWithBox() throws {
        let box = [10, 20, 100, 200]

        let request = SAMRequest(
            command: "predict",
            points: nil,
            labels: nil,
            box: box
        )

        XCTAssertEqual(request.box?.count, 4)
        XCTAssertEqual(request.box?[0], 10, "x1")
        XCTAssertEqual(request.box?[1], 20, "y1")
        XCTAssertEqual(request.box?[2], 100, "x2")
        XCTAssertEqual(request.box?[3], 200, "y2")
    }

    func testSAMRequestValidation() throws {
        // Predict requires points or box
        let validPredictRequest = SAMRequest(command: "predict", points: [[50, 50]], labels: [1], box: nil)
        XCTAssertNoThrow(try validPredictRequest.validate())

        let setImageRequest = SAMRequest(command: "set_image", imagePath: "/path/to/image.png")
        XCTAssertNoThrow(try setImageRequest.validate())

        let resetRequest = SAMRequest(command: "reset")
        XCTAssertNoThrow(try resetRequest.validate())

        // Predict without points or box should throw
        let invalidPredictRequest = SAMRequest(command: "predict")
        XCTAssertThrowsError(try invalidPredictRequest.validate())
    }
}
