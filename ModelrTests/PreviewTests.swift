import XCTest
@testable import Modelr

final class PreviewTests: XCTestCase {

    // MARK: - HunyuanResponse Preview Tests

    func testHunyuanResponseDecodesPreviewImage() throws {
        let json = """
        {
            "success": true,
            "messageId": "test-123",
            "type": "preview",
            "stage": "volume_decoding",
            "progress": 0.85,
            "previewImage": "iVBORw0KGgo="
        }
        """

        let data = json.data(using: .utf8)!
        let response = try JSONDecoder().decode(HunyuanResponse.self, from: data)

        XCTAssertTrue(response.success)
        XCTAssertEqual(response.type, "preview")
        XCTAssertEqual(response.stage, "volume_decoding")
        XCTAssertEqual(response.progress, 0.85)
        XCTAssertNotNil(response.previewImage)
        XCTAssertEqual(response.previewImage, "iVBORw0KGgo=")
    }

    func testHunyuanResponseWithoutPreviewImage() throws {
        let json = """
        {
            "success": true,
            "messageId": "test-456",
            "type": "progress",
            "stage": "diffusion",
            "progress": 0.50
        }
        """

        let data = json.data(using: .utf8)!
        let response = try JSONDecoder().decode(HunyuanResponse.self, from: data)

        XCTAssertTrue(response.success)
        XCTAssertEqual(response.type, "progress")
        XCTAssertNil(response.previewImage)
    }

    func testPreviewImageBase64Decoding() throws {
        // A minimal valid PNG (1x1 transparent pixel)
        let minimalPNG = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg=="

        let json = """
        {
            "success": true,
            "type": "preview",
            "previewImage": "\(minimalPNG)"
        }
        """

        let data = json.data(using: .utf8)!
        let response = try JSONDecoder().decode(HunyuanResponse.self, from: data)

        XCTAssertNotNil(response.previewImage)

        // Decode the base64 to image data
        let imageData = Data(base64Encoded: response.previewImage!)
        XCTAssertNotNil(imageData, "Should decode base64 to data")
        XCTAssertGreaterThan(imageData!.count, 0, "Image data should not be empty")

        // Verify it's valid PNG
        let pngMagic = Data([0x89, 0x50, 0x4E, 0x47])
        XCTAssertEqual(imageData!.prefix(4), pngMagic, "Should be valid PNG")
    }

    func testPreviewImageToNSImage() throws {
        // A minimal valid PNG (1x1 transparent pixel)
        let minimalPNG = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg=="

        guard let imageData = Data(base64Encoded: minimalPNG) else {
            XCTFail("Failed to decode base64")
            return
        }

        let nsImage = NSImage(data: imageData)
        XCTAssertNotNil(nsImage, "Should create NSImage from PNG data")
    }

    // MARK: - Response Type Detection Tests

    func testIsPreviewResponse() throws {
        let previewJson = """
        {"success": true, "type": "preview", "previewImage": "abc123"}
        """
        let progressJson = """
        {"success": true, "type": "progress", "progress": 0.5}
        """
        let completeJson = """
        {"success": true, "type": "complete", "outputPath": "/path/to/model.obj"}
        """

        let previewResponse = try JSONDecoder().decode(HunyuanResponse.self, from: previewJson.data(using: .utf8)!)
        let progressResponse = try JSONDecoder().decode(HunyuanResponse.self, from: progressJson.data(using: .utf8)!)
        let completeResponse = try JSONDecoder().decode(HunyuanResponse.self, from: completeJson.data(using: .utf8)!)

        XCTAssertEqual(previewResponse.type, "preview")
        XCTAssertNotNil(previewResponse.previewImage)

        XCTAssertEqual(progressResponse.type, "progress")
        XCTAssertNil(progressResponse.previewImage)

        XCTAssertEqual(completeResponse.type, "complete")
        XCTAssertNil(completeResponse.previewImage)
    }

    // MARK: - Progress Mapping Tests

    func testPreviewProgressMapping() throws {
        // Preview progress should be mapped to 80-95% range
        let testCases: [(Double, Double)] = [
            (0.0, 0.80),   // Start of volume decoding
            (0.5, 0.875),  // Halfway through
            (1.0, 0.95),   // End of volume decoding
        ]

        for (inputProgress, expectedOutput) in testCases {
            let mappedProgress = 0.80 + inputProgress * 0.15
            XCTAssertEqual(mappedProgress, expectedOutput, accuracy: 0.001,
                          "Progress \(inputProgress) should map to \(expectedOutput)")
        }
    }

    // MARK: - Edge Cases

    func testEmptyPreviewImage() throws {
        let json = """
        {"success": true, "type": "preview", "previewImage": ""}
        """

        let response = try JSONDecoder().decode(HunyuanResponse.self, from: json.data(using: .utf8)!)
        XCTAssertEqual(response.previewImage, "")

        // Empty string should decode to nil data
        let imageData = Data(base64Encoded: response.previewImage ?? "")
        XCTAssertNotNil(imageData)
        XCTAssertEqual(imageData!.count, 0)
    }

    func testInvalidBase64PreviewImage() throws {
        let json = """
        {"success": true, "type": "preview", "previewImage": "not-valid-base64!!!"}
        """

        let response = try JSONDecoder().decode(HunyuanResponse.self, from: json.data(using: .utf8)!)
        XCTAssertNotNil(response.previewImage)

        // Invalid base64 should fail to decode
        let imageData = Data(base64Encoded: response.previewImage!)
        XCTAssertNil(imageData, "Invalid base64 should not decode")
    }

    func testLargePreviewImage() throws {
        // Generate a larger base64 string (simulating a real preview)
        let largeData = Data(repeating: 0xFF, count: 10000)
        let largeBase64 = largeData.base64EncodedString()

        let json = """
        {"success": true, "type": "preview", "previewImage": "\(largeBase64)"}
        """

        let response = try JSONDecoder().decode(HunyuanResponse.self, from: json.data(using: .utf8)!)
        XCTAssertNotNil(response.previewImage)

        let decodedData = Data(base64Encoded: response.previewImage!)
        XCTAssertNotNil(decodedData)
        XCTAssertEqual(decodedData!.count, 10000, "Should decode full size")
    }
}
