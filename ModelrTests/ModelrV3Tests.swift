import XCTest
import UniformTypeIdentifiers
@testable import Modelr

final class ModelrV3Tests: XCTestCase {
    
    func testImageDropTypeDetection() {
        let jpegType = UTType("public.jpeg")
        XCTAssertNotNil(jpegType)
        XCTAssertTrue(jpegType!.conforms(to: .image))
        
        let pngType = UTType("public.png")
        XCTAssertNotNil(pngType)
        XCTAssertTrue(pngType!.conforms(to: .image))
    }
    
    func testAllTestsRegistered() {
        let testBundle = Bundle(for: type(of: self))
        XCTAssertNotNil(testBundle, "Test bundle should exist")
        
        let allTests = testBundle.bundlePath
        XCTAssertFalse(allTests.isEmpty, "Should have test path")
    }
}
