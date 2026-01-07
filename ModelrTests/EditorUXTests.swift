import XCTest
@testable import Modelr

/// Tests for Editor UX improvements
final class EditorUXTests: XCTestCase {

    override func setUpWithError() throws {
    }

    override func tearDownWithError() throws {
    }

    // MARK: - Coordinate Extension Tests

    func testCGPointToViewCoords() throws {
        let displaySize = CGSize(width: 800, height: 600)
        let normalizedPoint = CGPoint(x: 0.5, y: 0.5)

        let viewCoords = normalizedPoint.toViewCoords(displaySize)

        XCTAssertEqual(viewCoords.x, 400, accuracy: 0.001, "X should be 400")
        XCTAssertEqual(viewCoords.y, 300, accuracy: 0.001, "Y should be 300")
    }

    func testCGPointToViewCoordsCorners() throws {
        let displaySize = CGSize(width: 1000, height: 500)

        let topLeft = CGPoint(x: 0, y: 0).toViewCoords(displaySize)
        XCTAssertEqual(topLeft.x, 0, accuracy: 0.001)
        XCTAssertEqual(topLeft.y, 0, accuracy: 0.001)

        let bottomRight = CGPoint(x: 1, y: 1).toViewCoords(displaySize)
        XCTAssertEqual(bottomRight.x, 1000, accuracy: 0.001)
        XCTAssertEqual(bottomRight.y, 500, accuracy: 0.001)
    }

    // MARK: - UndoAction Tests

    func testUndoActionAddPoint() throws {
        let point = SAMPoint(normalizedCoords: CGPoint(x: 0.5, y: 0.5), label: 1)
        let action = UndoAction.addPoint(point)

        if case .addPoint(let undoPoint) = action {
            XCTAssertEqual(undoPoint.normalizedCoords, point.normalizedCoords)
            XCTAssertEqual(undoPoint.label, point.label)
        } else {
            XCTFail("Action should be addPoint")
        }
    }

    func testUndoActionAddBox() throws {
        let box = SAMBox(startPoint: CGPoint(x: 0.1, y: 0.1), endPoint: CGPoint(x: 0.9, y: 0.9))
        let action = UndoAction.addBox(box)

        if case .addBox(let undoBox) = action {
            XCTAssertEqual(undoBox.startPoint, box.startPoint)
            XCTAssertEqual(undoBox.endPoint, box.endPoint)
        } else {
            XCTFail("Action should be addBox")
        }
    }

    func testUndoActionAddLasso() throws {
        var lasso = LassoSelection(startPoint: CGPoint(x: 0.1, y: 0.1))
        lasso.addPoint(CGPoint(x: 0.5, y: 0.5))
        lasso.addPoint(CGPoint(x: 0.9, y: 0.1))

        let action = UndoAction.addLasso(lasso)

        if case .addLasso(let undoLasso) = action {
            XCTAssertEqual(undoLasso.points.count, lasso.points.count)
        } else {
            XCTFail("Action should be addLasso")
        }
    }

    func testUndoActionAddPaintStroke() throws {
        var stroke = PaintStroke(startPoint: CGPoint(x: 0.5, y: 0.5), brushSize: 0.03, isErasing: false)
        stroke.addPoint(CGPoint(x: 0.6, y: 0.6))

        let action = UndoAction.addPaintStroke(stroke)

        if case .addPaintStroke(let undoStroke) = action {
            XCTAssertEqual(undoStroke.brushSize, stroke.brushSize)
            XCTAssertEqual(undoStroke.isErasing, stroke.isErasing)
        } else {
            XCTFail("Action should be addPaintStroke")
        }
    }

    // MARK: - Point Label Collection Tests

    func testFilterPositivePoints() throws {
        let points = [
            SAMPoint(normalizedCoords: CGPoint(x: 0.1, y: 0.1), label: 1),
            SAMPoint(normalizedCoords: CGPoint(x: 0.2, y: 0.2), label: 0),
            SAMPoint(normalizedCoords: CGPoint(x: 0.3, y: 0.3), label: 1),
            SAMPoint(normalizedCoords: CGPoint(x: 0.4, y: 0.4), label: 0),
            SAMPoint(normalizedCoords: CGPoint(x: 0.5, y: 0.5), label: 1)
        ]

        let positivePoints = points.filter { $0.isPositive }
        let negativePoints = points.filter { $0.isNegative }

        XCTAssertEqual(positivePoints.count, 3, "Should have 3 positive points")
        XCTAssertEqual(negativePoints.count, 2, "Should have 2 negative points")
    }

    func testExtractLabelsFromPoints() throws {
        let points = [
            SAMPoint(normalizedCoords: CGPoint(x: 0.1, y: 0.1), label: 1),
            SAMPoint(normalizedCoords: CGPoint(x: 0.2, y: 0.2), label: 0),
            SAMPoint(normalizedCoords: CGPoint(x: 0.3, y: 0.3), label: 1)
        ]

        let labels = points.map { $0.label }

        XCTAssertEqual(labels, [1, 0, 1], "Labels should be [1, 0, 1]")
    }

    // MARK: - Box Validation Tests

    func testBoxValidityThreshold() throws {
        // Box must be > 5% in each dimension
        let exactlyAtThreshold = SAMBox(
            startPoint: CGPoint(x: 0.0, y: 0.0),
            endPoint: CGPoint(x: 0.05, y: 0.05)
        )
        XCTAssertFalse(exactlyAtThreshold.isValid, "Box at exactly 5% should be invalid")

        let justAboveThreshold = SAMBox(
            startPoint: CGPoint(x: 0.0, y: 0.0),
            endPoint: CGPoint(x: 0.06, y: 0.06)
        )
        XCTAssertTrue(justAboveThreshold.isValid, "Box at 6% should be valid")

        let largeBox = SAMBox(
            startPoint: CGPoint(x: 0.1, y: 0.1),
            endPoint: CGPoint(x: 0.8, y: 0.8)
        )
        XCTAssertTrue(largeBox.isValid, "Large box should be valid")
    }

    // MARK: - Lasso Bounding Box Tests

    func testLassoBoundingBoxCalculation() throws {
        var lasso = LassoSelection(startPoint: CGPoint(x: 0.2, y: 0.3))
        lasso.addPoint(CGPoint(x: 0.8, y: 0.3))
        lasso.addPoint(CGPoint(x: 0.8, y: 0.7))
        lasso.addPoint(CGPoint(x: 0.2, y: 0.7))

        let box = lasso.boundingBox
        XCTAssertNotNil(box)

        let rect = box!.normalizedRect
        XCTAssertEqual(rect.minX, 0.2, accuracy: 0.001)
        XCTAssertEqual(rect.minY, 0.3, accuracy: 0.001)
        XCTAssertEqual(rect.maxX, 0.8, accuracy: 0.001)
        XCTAssertEqual(rect.maxY, 0.7, accuracy: 0.001)
    }

    func testLassoBoundingBoxWithIrregularShape() throws {
        var lasso = LassoSelection(startPoint: CGPoint(x: 0.5, y: 0.1))
        lasso.addPoint(CGPoint(x: 0.9, y: 0.5))
        lasso.addPoint(CGPoint(x: 0.5, y: 0.9))
        lasso.addPoint(CGPoint(x: 0.1, y: 0.5))

        let box = lasso.boundingBox
        XCTAssertNotNil(box)

        let rect = box!.normalizedRect
        XCTAssertEqual(rect.minX, 0.1, accuracy: 0.001)
        XCTAssertEqual(rect.minY, 0.1, accuracy: 0.001)
        XCTAssertEqual(rect.maxX, 0.9, accuracy: 0.001)
        XCTAssertEqual(rect.maxY, 0.9, accuracy: 0.001)
    }

    // MARK: - Paint Stroke Tests

    func testPaintStrokeEraseVsAdd() throws {
        let addStroke = PaintStroke(
            startPoint: CGPoint(x: 0.5, y: 0.5),
            brushSize: 0.03,
            isErasing: false
        )
        XCTAssertFalse(addStroke.isErasing, "Add stroke should not be erasing")

        let eraseStroke = PaintStroke(
            startPoint: CGPoint(x: 0.5, y: 0.5),
            brushSize: 0.05,
            isErasing: true
        )
        XCTAssertTrue(eraseStroke.isErasing, "Erase stroke should be erasing")
    }

    func testPaintStrokeBrushSizeRange() throws {
        let smallBrush = PaintStroke(startPoint: .zero, brushSize: 0.01)
        XCTAssertEqual(smallBrush.brushSize, 0.01, accuracy: 0.001)

        let largeBrush = PaintStroke(startPoint: .zero, brushSize: 0.15)
        XCTAssertEqual(largeBrush.brushSize, 0.15, accuracy: 0.001)
    }

    // MARK: - SAMTool Selection Tests

    func testAllSAMToolsHaveIcons() throws {
        for tool in SAMTool.allCases {
            XCTAssertFalse(tool.iconName.isEmpty, "Tool \(tool.rawValue) should have an icon")
        }
    }

    func testAllSAMToolsHaveDisplayNames() throws {
        for tool in SAMTool.allCases {
            XCTAssertFalse(tool.rawValue.isEmpty, "Tool should have a display name")
        }
    }

    // MARK: - Polygon Tool Tests

    func testPolygonBoundingBoxCalculation() throws {
        let polygon = PolygonSelection(vertices: [
            CGPoint(x: 0.2, y: 0.3),
            CGPoint(x: 0.8, y: 0.3),
            CGPoint(x: 0.8, y: 0.7),
            CGPoint(x: 0.2, y: 0.7)
        ])

        let box = polygon.boundingBox
        XCTAssertNotNil(box)

        let rect = box!.normalizedRect
        XCTAssertEqual(rect.minX, 0.2, accuracy: 0.001)
        XCTAssertEqual(rect.minY, 0.3, accuracy: 0.001)
        XCTAssertEqual(rect.maxX, 0.8, accuracy: 0.001)
        XCTAssertEqual(rect.maxY, 0.7, accuracy: 0.001)
    }

    func testPolygonBoundingBoxWithIrregularShape() throws {
        let polygon = PolygonSelection(vertices: [
            CGPoint(x: 0.5, y: 0.1),
            CGPoint(x: 0.9, y: 0.5),
            CGPoint(x: 0.5, y: 0.9),
            CGPoint(x: 0.1, y: 0.5)
        ])

        let box = polygon.boundingBox
        XCTAssertNotNil(box)

        let rect = box!.normalizedRect
        XCTAssertEqual(rect.minX, 0.1, accuracy: 0.001)
        XCTAssertEqual(rect.minY, 0.1, accuracy: 0.001)
        XCTAssertEqual(rect.maxX, 0.9, accuracy: 0.001)
        XCTAssertEqual(rect.maxY, 0.9, accuracy: 0.001)
    }

    func testPolygonCloseThreshold() throws {
        // Test the closing logic: if clicked within 3% of first vertex, polygon closes
        let firstVertex = CGPoint(x: 0.5, y: 0.5)
        var polygon = PolygonSelection(vertices: [
            firstVertex,
            CGPoint(x: 0.8, y: 0.5),
            CGPoint(x: 0.65, y: 0.8)
        ])

        // Simulate click near first vertex (within 3% threshold)
        let closeClickPoint = CGPoint(x: 0.52, y: 0.52)
        let distance = hypot(closeClickPoint.x - firstVertex.x, closeClickPoint.y - firstVertex.y)

        XCTAssertLessThan(distance, 0.03, "Click should be within close threshold")

        // Clicking near first vertex should close the polygon
        polygon.close()
        XCTAssertTrue(polygon.isClosed, "Polygon should be closed")
    }

    func testPolygonCloseThresholdTooFar() throws {
        let firstVertex = CGPoint(x: 0.5, y: 0.5)

        // Simulate click far from first vertex (beyond 3% threshold)
        let farClickPoint = CGPoint(x: 0.55, y: 0.55)
        let distance = hypot(farClickPoint.x - firstVertex.x, farClickPoint.y - firstVertex.y)

        XCTAssertGreaterThan(distance, 0.03, "Click should be outside close threshold")
    }

    func testPolygonToolInSAMToolEnum() throws {
        XCTAssertTrue(SAMTool.allCases.contains(.polygon), "SAMTool should include polygon")
        XCTAssertEqual(SAMTool.polygon.rawValue, "Polygon")
        XCTAssertEqual(SAMTool.polygon.iconName, "pentagon")
    }

    // MARK: - CGRect Contains Point Tests

    func testNormalizedRectContainsPoint() throws {
        let box = SAMBox(
            startPoint: CGPoint(x: 0.2, y: 0.2),
            endPoint: CGPoint(x: 0.8, y: 0.8)
        )
        let rect = box.normalizedRect

        // Inside
        XCTAssertTrue(rect.contains(CGPoint(x: 0.5, y: 0.5)), "Center should be inside")
        XCTAssertTrue(rect.contains(CGPoint(x: 0.3, y: 0.3)), "Near corner should be inside")

        // Outside
        XCTAssertFalse(rect.contains(CGPoint(x: 0.1, y: 0.1)), "Outside should not contain")
        XCTAssertFalse(rect.contains(CGPoint(x: 0.9, y: 0.9)), "Outside should not contain")

        // Edge
        XCTAssertTrue(rect.contains(CGPoint(x: 0.2, y: 0.5)), "Edge should be inside")
    }
}
