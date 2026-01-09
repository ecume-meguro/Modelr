import XCTest
@testable import Modelr

final class PreviewTests: XCTestCase {

    // MARK: - HunyuanResponse Tests

    func testHunyuanResponseDecodesProgressMessage() throws {
        let json = """
        {
            "success": true,
            "messageId": "test-123",
            "type": "progress",
            "stage": "diffusion",
            "progress": 0.85,
            "detail": "Processing..."
        }
        """

        let data = json.data(using: .utf8)!
        let response = try JSONDecoder().decode(HunyuanResponse.self, from: data)

        XCTAssertTrue(response.success)
        XCTAssertEqual(response.type, "progress")
        XCTAssertEqual(response.stage, "diffusion")
        XCTAssertEqual(response.progress, 0.85)
        XCTAssertEqual(response.detail, "Processing...")
    }

    func testHunyuanResponseDecodesCompleteMessage() throws {
        let json = """
        {
            "success": true,
            "messageId": "test-456",
            "type": "complete",
            "outputPath": "/tmp/model.obj"
        }
        """

        let data = json.data(using: .utf8)!
        let response = try JSONDecoder().decode(HunyuanResponse.self, from: data)

        XCTAssertTrue(response.success)
        XCTAssertEqual(response.type, "complete")
        XCTAssertEqual(response.outputPath, "/tmp/model.obj")
    }

    func testHunyuanResponseDecodesErrorMessage() throws {
        let json = """
        {
            "success": false,
            "type": "error",
            "error": "Out of memory"
        }
        """

        let data = json.data(using: .utf8)!
        let response = try JSONDecoder().decode(HunyuanResponse.self, from: data)

        XCTAssertFalse(response.success)
        XCTAssertEqual(response.type, "error")
        XCTAssertEqual(response.error, "Out of memory")
    }

    func testHunyuanResponseDecodesReadyMessage() throws {
        let json = """
        {
            "success": true,
            "ready": true,
            "device": "mps",
            "server": "hunyuan",
            "variant": "mini"
        }
        """

        let data = json.data(using: .utf8)!
        let response = try JSONDecoder().decode(HunyuanResponse.self, from: data)

        XCTAssertTrue(response.success)
        XCTAssertEqual(response.ready, true)
        XCTAssertEqual(response.device, "mps")
        XCTAssertEqual(response.server, "hunyuan")
        XCTAssertEqual(response.variant, "mini")
    }

    // MARK: - Response Type Detection Tests

    func testResponseTypeDetection() throws {
        let progressJson = """
        {"success": true, "type": "progress", "progress": 0.5}
        """
        let completeJson = """
        {"success": true, "type": "complete", "outputPath": "/path/to/model.obj"}
        """
        let errorJson = """
        {"success": false, "type": "error", "error": "Something went wrong"}
        """

        let progressResponse = try JSONDecoder().decode(HunyuanResponse.self, from: progressJson.data(using: .utf8)!)
        let completeResponse = try JSONDecoder().decode(HunyuanResponse.self, from: completeJson.data(using: .utf8)!)
        let errorResponse = try JSONDecoder().decode(HunyuanResponse.self, from: errorJson.data(using: .utf8)!)

        XCTAssertEqual(progressResponse.type, "progress")
        XCTAssertEqual(completeResponse.type, "complete")
        XCTAssertEqual(errorResponse.type, "error")
    }

    // MARK: - Progress Mapping Tests

    func testProgressStages() throws {
        // Different stages should be distinguishable
        let loadingJson = """
        {"success": true, "type": "progress", "stage": "loading", "progress": 0.1}
        """
        let diffusionJson = """
        {"success": true, "type": "progress", "stage": "diffusion", "progress": 0.5}
        """
        let exportingJson = """
        {"success": true, "type": "progress", "stage": "exporting", "progress": 0.9}
        """

        let loading = try JSONDecoder().decode(HunyuanResponse.self, from: loadingJson.data(using: .utf8)!)
        let diffusion = try JSONDecoder().decode(HunyuanResponse.self, from: diffusionJson.data(using: .utf8)!)
        let exporting = try JSONDecoder().decode(HunyuanResponse.self, from: exportingJson.data(using: .utf8)!)

        XCTAssertEqual(loading.stage, "loading")
        XCTAssertEqual(diffusion.stage, "diffusion")
        XCTAssertEqual(exporting.stage, "exporting")
    }

    // MARK: - Edge Cases

    func testMinimalResponse() throws {
        let json = """
        {"success": true}
        """

        let response = try JSONDecoder().decode(HunyuanResponse.self, from: json.data(using: .utf8)!)
        XCTAssertTrue(response.success)
        XCTAssertNil(response.type)
        XCTAssertNil(response.stage)
        XCTAssertNil(response.progress)
    }

    func testNullOptionalFields() throws {
        let json = """
        {
            "success": true,
            "messageId": null,
            "type": "progress",
            "progress": 0.5
        }
        """

        let response = try JSONDecoder().decode(HunyuanResponse.self, from: json.data(using: .utf8)!)
        XCTAssertTrue(response.success)
        XCTAssertNil(response.messageId)
        XCTAssertEqual(response.type, "progress")
    }

    func testPongResponse() throws {
        let json = """
        {"success": true, "status": "pong"}
        """

        let response = try JSONDecoder().decode(HunyuanResponse.self, from: json.data(using: .utf8)!)
        XCTAssertTrue(response.success)
        XCTAssertEqual(response.status, "pong")
    }
}
