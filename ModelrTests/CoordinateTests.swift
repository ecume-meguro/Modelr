import XCTest
@testable import Modelr

final class CoordinateTests: XCTestCase {
    
    override func setUpWithError() throws {
    }
    
    override func tearDownWithError() throws {
    }
    
    // MARK: - Normalized to Pixel Conversions
    
    func testNormalizedToPixelBasic() throws {
        let imageSize = CGSize(width: 100, height: 100)
        let normalized = CGPoint(x: 0.5, y: 0.5)
        let pixel = normalized.toViewCoords(imageSize)
        
        XCTAssertEqual(pixel.x, 50, accuracy: 0.1)
        XCTAssertEqual(pixel.y, 50, accuracy: 0.1)
    }
    
    func testNormalizedToPixelZero() throws {
        let imageSize = CGSize(width: 100, height: 100)
        let normalized = CGPoint(x: 0, y: 0)
        let pixel = normalized.toViewCoords(imageSize)
        
        XCTAssertEqual(pixel.x, 0, accuracy: 0.1)
        XCTAssertEqual(pixel.y, 0, accuracy: 0.1)
    }
    
    func testNormalizedToPixelOne() throws {
        let imageSize = CGSize(width: 100, height: 100)
        let normalized = CGPoint(x: 1, y: 1)
        let pixel = normalized.toViewCoords(imageSize)
        
        XCTAssertEqual(pixel.x, 100, accuracy: 0.1)
        XCTAssertEqual(pixel.y, 100, accuracy: 0.1)
    }
    
    func testNormalizedToPixelNonSquare() throws {
        let imageSize = CGSize(width: 200, height: 100)
        let normalized = CGPoint(x: 0.5, y: 0.5)
        let pixel = normalized.toViewCoords(imageSize)
        
        XCTAssertEqual(pixel.x, 100, accuracy: 0.1, "X should scale to 200 width")
        XCTAssertEqual(pixel.y, 50, accuracy: 0.1, "Y should scale to 100 height")
    }
    
    func testNormalizedToPixelLargeImage() throws {
        let imageSize = CGSize(width: 4000, height: 3000)
        let normalized = CGPoint(x: 0.75, y: 0.66)
        let pixel = normalized.toViewCoords(imageSize)
        
        XCTAssertEqual(pixel.x, 3000, accuracy: 1)
        XCTAssertEqual(pixel.y, 1980, accuracy: 1)
    }
    
    // MARK: - Pixel to Normalized Conversions
    
    func testPixelToNormalizedBasic() throws {
        let viewSize = CGSize(width: 100, height: 100)
        let pixel = CGPoint(x: 50, y: 50)
        let normalized = pixel.toNormalized(viewSize)
        
        XCTAssertEqual(normalized.x, 0.5, accuracy: 0.01)
        XCTAssertEqual(normalized.y, 0.5, accuracy: 0.01)
    }
    
    func testPixelToNormalizedZero() throws {
        let viewSize = CGSize(width: 100, height: 100)
        let pixel = CGPoint(x: 0, y: 0)
        let normalized = pixel.toNormalized(viewSize)
        
        XCTAssertEqual(normalized.x, 0, accuracy: 0.01)
        XCTAssertEqual(normalized.y, 0, accuracy: 0.01)
    }
    
    func testPixelToNormalizedEdge() throws {
        let viewSize = CGSize(width: 100, height: 100)
        let pixel = CGPoint(x: 100, y: 100)
        let normalized = pixel.toNormalized(viewSize)
        
        XCTAssertEqual(normalized.x, 1, accuracy: 0.01)
        XCTAssertEqual(normalized.y, 1, accuracy: 0.01)
    }
    
    func testPixelToNormalizedNonSquare() throws {
        let viewSize = CGSize(width: 200, height: 100)
        let pixel = CGPoint(x: 100, y: 50)
        let normalized = pixel.toNormalized(viewSize)
        
        XCTAssertEqual(normalized.x, 0.5, accuracy: 0.01)
        XCTAssertEqual(normalized.y, 0.5, accuracy: 0.01)
    }
    
    // MARK: - Round-trip Conversions
    
    func testRoundTripConversion() throws {
        let size = CGSize(width: 100, height: 100)
        let original = CGPoint(x: 0.75, y: 0.33)
        
        let pixel = original.toViewCoords(size)
        let normalized = pixel.toNormalized(size)
        
        XCTAssertEqual(original.x, normalized.x, accuracy: 0.01)
        XCTAssertEqual(original.y, normalized.y, accuracy: 0.01)
    }
    
    func testRoundTripConversionLarge() throws {
        let size = CGSize(width: 1920, height: 1080)
        let original = CGPoint(x: 0.423, y: 0.761)
        
        let pixel = original.toViewCoords(size)
        let normalized = pixel.toNormalized(size)
        
        XCTAssertEqual(original.x, normalized.x, accuracy: 0.001)
        XCTAssertEqual(original.y, normalized.y, accuracy: 0.001)
    }
    
    // MARK: - Edge Cases
    
    func testZeroSizeView() throws {
        let size = CGSize(width: 0, height: 0)
        let point = CGPoint(x: 0.5, y: 0.5)
        
        let pixel = point.toViewCoords(size)
        
        XCTAssertTrue(pixel.x.isNaN || pixel.x == 0, "Should handle zero width")
        XCTAssertTrue(pixel.y.isNaN || pixel.y == 0, "Should handle zero height")
    }
    
    func testNegativeCoordinate() throws {
        let size = CGSize(width: 100, height: 100)
        let point = CGPoint(x: -0.1, y: -0.1)
        
        let pixel = point.toViewCoords(size)
        XCTAssertEqual(pixel.x, -10, accuracy: 0.1)
        XCTAssertEqual(pixel.y, -10, accuracy: 0.1)
    }
    
    func testGreaterThanOneCoordinate() throws {
        let size = CGSize(width: 100, height: 100)
        let point = CGPoint(x: 1.5, y: 1.5)
        
        let pixel = point.toViewCoords(size)
        XCTAssertEqual(pixel.x, 150, accuracy: 0.1)
        XCTAssertEqual(pixel.y, 150, accuracy: 0.1)
    }
    
    // MARK: - Clamping Behavior
    
    func testClampingWithinRange() throws {
        let point = CGPoint(x: 0.5, y: 0.5)
        let clamped = point.clamped
        
        XCTAssertEqual(clamped.x, 0.5, accuracy: 0.001)
        XCTAssertEqual(clamped.y, 0.5, accuracy: 0.001)
    }
    
    func testClampingBelowRange() throws {
        let point = CGPoint(x: -0.5, y: -0.2)
        let clamped = point.clamped
        
        XCTAssertEqual(clamped.x, 0, accuracy: 0.001)
        XCTAssertEqual(clamped.y, 0, accuracy: 0.001)
    }
    
    func testClampingAboveRange() throws {
        let point = CGPoint(x: 1.5, y: 2.0)
        let clamped = point.clamped
        
        XCTAssertEqual(clamped.x, 1, accuracy: 0.001)
        XCTAssertEqual(clamped.y, 1, accuracy: 0.001)
    }
    
    func testClampingMixed() throws {
        let point = CGPoint(x: -0.3, y: 1.7)
        let clamped = point.clamped
        
        XCTAssertEqual(clamped.x, 0, accuracy: 0.001)
        XCTAssertEqual(clamped.y, 1, accuracy: 0.001)
    }
    
    func testClampingExactlyAtBoundaries() throws {
        let minPoint = CGPoint(x: 0, y: 0)
        let maxPoint = CGPoint(x: 1, y: 1)
        
        XCTAssertEqual(minPoint.clamped.x, 0, accuracy: 0.001)
        XCTAssertEqual(minPoint.clamped.y, 0, accuracy: 0.001)
        XCTAssertEqual(maxPoint.clamped.x, 1, accuracy: 0.001)
        XCTAssertEqual(maxPoint.clamped.y, 1, accuracy: 0.001)
    }
    
    // MARK: - Precision Tests
    
    func testPrecisionSmallCoordinates() throws {
        let size = CGSize(width: 10000, height: 10000)
        let point = CGPoint(x: 0.001, y: 0.001)
        
        let pixel = point.toViewCoords(size)
        
        XCTAssertEqual(pixel.x, 10, accuracy: 0.1)
        XCTAssertEqual(pixel.y, 10, accuracy: 0.1)
    }
    
    func testPrecisionLargeCoordinates() throws {
        let size = CGSize(width: 1, height: 1)
        let point = CGPoint(x: 0.9999, y: 0.9999)
        
        let pixel = point.toViewCoords(size)
        
        XCTAssertEqual(pixel.x, 0.9999, accuracy: 0.0001)
        XCTAssertEqual(pixel.y, 0.9999, accuracy: 0.0001)
    }
    
    // MARK: - Aspect Ratio Tests
    
    func testWideImage() throws {
        let size = CGSize(width: 200, height: 100)
        let point = CGPoint(x: 0.5, y: 0.5)
        
        let pixel = point.toViewCoords(size)
        XCTAssertEqual(pixel.x, 100, accuracy: 0.1)
        XCTAssertEqual(pixel.y, 50, accuracy: 0.1)
    }
    
    func testTallImage() throws {
        let size = CGSize(width: 100, height: 200)
        let point = CGPoint(x: 0.5, y: 0.5)
        
        let pixel = point.toViewCoords(size)
        XCTAssertEqual(pixel.x, 50, accuracy: 0.1)
        XCTAssertEqual(pixel.y, 100, accuracy: 0.1)
    }
}
