import XCTest
import UniformTypeIdentifiers
@testable import ModelrV3

final class ModelrV3Tests: XCTestCase {
    func testPythonEnvironmentSetup() async {
        let env = PythonEnvironment()
        // Point to the local resources since we're not in an app bundle during tests
        env.resourcePathOverride = "/Users/zimengx/Code/MacOS_Utilities/Modelr/v3/Resources"
        
        await env.setup()
        XCTAssertTrue(env.canProceed, "Python environment should be prepared for segmentation")
    }
    
    func testImageDropTypeDetection() {
        // This test verifies that we can correctly identify image types from identifiers
        let jpegType = UTType("public.jpeg")
        XCTAssertNotNil(jpegType)
        XCTAssertTrue(jpegType!.conforms(to: .image))
        
        let pngType = UTType("public.png")
        XCTAssertNotNil(pngType)
        XCTAssertTrue(pngType!.conforms(to: .image))
    }
}
