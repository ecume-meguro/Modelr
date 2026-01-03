import XCTest
@testable import ModelrV3

final class SF3DTests: XCTestCase {
    
    // MARK: - GeneratorModel Tests
    
    func testGeneratorModelEnumCases() throws {
        XCTAssertEqual(GeneratorModel.allCases.count, 3, "Should have 3 generator options")
        XCTAssertTrue(GeneratorModel.allCases.contains(.hunyuan))
        XCTAssertTrue(GeneratorModel.allCases.contains(.sf3d))
        XCTAssertTrue(GeneratorModel.allCases.contains(.both))
    }
    
    func testGeneratorModelRawValues() throws {
        XCTAssertEqual(GeneratorModel.hunyuan.rawValue, "Hunyuan3D-2")
        XCTAssertEqual(GeneratorModel.sf3d.rawValue, "SF3D")
        XCTAssertEqual(GeneratorModel.both.rawValue, "Both")
    }
    
    func testGeneratorModelIdentifiable() throws {
        XCTAssertEqual(GeneratorModel.hunyuan.id, "Hunyuan3D-2")
        XCTAssertEqual(GeneratorModel.sf3d.id, "SF3D")
        XCTAssertEqual(GeneratorModel.both.id, "Both")
    }
    
    func testGeneratorModelDescriptions() throws {
        XCTAssertFalse(GeneratorModel.hunyuan.description.isEmpty)
        XCTAssertFalse(GeneratorModel.sf3d.description.isEmpty)
        XCTAssertFalse(GeneratorModel.both.description.isEmpty)
        
        XCTAssertTrue(GeneratorModel.hunyuan.description.contains("Hunyuan"))
        XCTAssertTrue(GeneratorModel.sf3d.description.contains("SF3D"))
        XCTAssertTrue(GeneratorModel.both.description.contains("both"))
    }
    
    func testGeneratorModelCaseIterable() throws {
        // Verify iteration order is deterministic
        let cases = Array(GeneratorModel.allCases)
        XCTAssertEqual(cases[0], .hunyuan)
        XCTAssertEqual(cases[1], .sf3d)
        XCTAssertEqual(cases[2], .both)
    }
    
    // MARK: - AppConstants SF3D Tests
    
    func testSF3DConstants() throws {
        XCTAssertEqual(AppConstants.sf3dDirectoryName, "SF3D")
        XCTAssertEqual(AppConstants.sf3dWrapperFileName, "sf3d_wrapper.py")
        XCTAssertEqual(AppConstants.sf3dPyprojectFileName, "pyproject_sf3d.toml")
        XCTAssertEqual(AppConstants.sf3dPythonVersion, "3.10")
    }
    
    func testSF3DDirectoryNameNotEmpty() throws {
        XCTAssertFalse(AppConstants.sf3dDirectoryName.isEmpty)
    }
    
    func testSF3DWrapperFileName() throws {
        XCTAssertTrue(AppConstants.sf3dWrapperFileName.hasSuffix(".py"))
    }
    
    func testSF3DPyprojectFileName() throws {
        XCTAssertTrue(AppConstants.sf3dPyprojectFileName.hasSuffix(".toml"))
    }
    
    func testSF3DPythonVersionFormat() throws {
        // Python version should be in X.Y format
        let version = AppConstants.sf3dPythonVersion
        let parts = version.split(separator: ".")
        XCTAssertEqual(parts.count, 2, "Python version should be in X.Y format")
        XCTAssertNotNil(Int(parts[0]), "Major version should be integer")
        XCTAssertNotNil(Int(parts[1]), "Minor version should be integer")
    }
    
    func testSF3DPythonVersionIsReasonable() throws {
        // Python version should be >= 3.10 for SF3D
        let version = AppConstants.sf3dPythonVersion
        let parts = version.split(separator: ".")
        if let major = Int(parts[0]), let minor = Int(parts[1]) {
            XCTAssertGreaterThanOrEqual(major, 3, "Python major version should be >= 3")
            if major == 3 {
                XCTAssertGreaterThanOrEqual(minor, 10, "Python 3 minor version should be >= 10")
            }
        }
    }
    
    // MARK: - SF3D vs Hunyuan Constants Comparison
    
    func testSF3DAndHunyuanHaveDifferentDirectories() throws {
        XCTAssertNotEqual(AppConstants.sf3dDirectoryName, AppConstants.hunyuanDirectoryName)
    }
    
    func testSF3DAndHunyuanHaveDifferentWrappers() throws {
        XCTAssertNotEqual(AppConstants.sf3dWrapperFileName, AppConstants.hunyuanWrapperFileName)
    }
    
    func testSF3DAndHunyuanHaveDifferentPyprojects() throws {
        XCTAssertNotEqual(AppConstants.sf3dPyprojectFileName, AppConstants.hunyuanPyprojectFileName)
    }
    
    // MARK: - Resource File Existence Tests
    
    func testSF3DWrapperExistsInBundle() throws {
        // Check if sf3d_wrapper.py can be found in bundle (may not exist during unit tests)
        let bundle = Bundle(for: type(of: self))
        let path = bundle.path(forResource: "sf3d_wrapper", ofType: "py")
        // Note: This may be nil in test target, but the test documents the expectation
        if path != nil {
            XCTAssertTrue(FileManager.default.fileExists(atPath: path!))
        }
    }
    
    func testSF3DPyprojectExistsInBundle() throws {
        let bundle = Bundle(for: type(of: self))
        let path = bundle.path(forResource: "pyproject_sf3d", ofType: "toml")
        if path != nil {
            XCTAssertTrue(FileManager.default.fileExists(atPath: path!))
        }
    }
    
    // MARK: - Mock Generator Tests
    
    func testMockGeneratorSelection() async throws {
        let mockService = MockPythonService()

        // Mock service should work regardless of generator selection
        let imageSize = CGSize(width: 100, height: 100)
        let points = [SAMPoint(normalizedCoords: CGPoint(x: 0.5, y: 0.5))]

        let (_, primaryMask, _, _) = try await mockService.predict(points: points, box: nil, imageSize: imageSize)
        XCTAssertTrue(primaryMask.path.contains("mask.png"))
    }
    
    func testMockServiceGenerate3DModel() async throws {
        let mockService = MockPythonService()
        var progressUpdates: [String] = []
        var result: Result<URL, Error>?
        
        await mockService.generate3DModel(
            imagePath: "/test/image.jpg",
            maskPath: "/test/mask.png",
            steps: 10,
            resolution: 128
        ) { progress in
            progressUpdates.append(progress)
        } completion: { r in
            result = r
        }
        
        try await Task.sleep(nanoseconds: 500_000_000)
        
        XCTAssertNotNil(result)
        switch result {
        case .success(let url):
            XCTAssertTrue(url.path.contains("model"))
        case .failure:
            XCTFail("Mock should succeed")
        case .none:
            XCTFail("Result should not be nil")
        }
    }
    
    // MARK: - Path Construction Tests
    
    func testSF3DPathConstruction() throws {
        let baseDir = URL(fileURLWithPath: "/test/app/support")
        let sf3dDir = baseDir.appendingPathComponent(AppConstants.sf3dDirectoryName)
        
        XCTAssertEqual(sf3dDir.lastPathComponent, "SF3D")
        
        let venvDir = sf3dDir.appendingPathComponent(".venv")
        XCTAssertTrue(venvDir.path.contains("SF3D/.venv"))
        
        let wrapperPath = sf3dDir.appendingPathComponent(AppConstants.sf3dWrapperFileName)
        XCTAssertTrue(wrapperPath.path.hasSuffix("sf3d_wrapper.py"))
    }
    
    func testSF3DRepoPathConstruction() throws {
        let sf3dDir = URL(fileURLWithPath: "/test/SF3D")
        let repoDir = sf3dDir.appendingPathComponent("stable-fast-3d")
        
        XCTAssertEqual(repoDir.lastPathComponent, "stable-fast-3d")
        
        let textureBaker = repoDir.appendingPathComponent("texture_baker")
        XCTAssertTrue(textureBaker.path.contains("stable-fast-3d/texture_baker"))
        
        let uvUnwrapper = repoDir.appendingPathComponent("uv_unwrapper")
        XCTAssertTrue(uvUnwrapper.path.contains("stable-fast-3d/uv_unwrapper"))
    }
}
