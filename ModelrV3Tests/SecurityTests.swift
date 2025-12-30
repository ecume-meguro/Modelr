import XCTest
@testable import ModelrV3

final class SecurityTests: XCTestCase {
    
    var validator: PathValidator!
    
    override func setUpWithError() throws {
        validator = PathValidator.shared
    }
    
    override func tearDownWithError() throws {
    }
    
    // MARK: - Path Validation Tests
    
    func testValidPath() throws {
        let validPath = "/tmp/test_image.png"
        
        let validatedURL = try validator.validatePath(validPath)
        
        XCTAssertEqual(validatedURL.path, validPath, "Should validate correct path")
    }
    
    func testEmptyPath() {
        let emptyPath = ""
        
        XCTAssertThrowsError(try validator.validatePath(emptyPath)) { error in
            XCTAssertTrue(error is ValidationError)
        }
    }
    
    func testPathTooLong() {
        let longPath = String(repeating: "a", count: 2000)
        
        XCTAssertThrowsError(try validator.validatePath(longPath)) { error in
            XCTAssertTrue(error is ValidationError)
            if let validationError = error as? ValidationError {
                switch validationError {
                case .invalidPath(let message):
                    XCTAssertTrue(message.contains("too long"), "Should indicate path is too long")
                default:
                    XCTFail("Wrong error type")
                }
            }
        }
    }
    
    // MARK: - Path Traversal Detection
    
    func testPathTraversalDetection() {
        let maliciousPaths = [
            "/tmp/../etc/passwd",
            "/var/log/../../home",
            "/safe/../../unsafe/file.txt"
        ]
        
        for path in maliciousPaths {
            XCTAssertThrowsError(try validator.validatePath(path)) { error in
                if let validationError = error as? ValidationError {
                    switch validationError {
                    case .pathTraversalAttempt:
                        XCTAssertTrue(true, "Should detect path traversal")
                    default:
                        XCTFail("Wrong error type for path: \(path)")
                    }
                } else {
                    XCTFail("Should throw ValidationError for path: \(path)")
                }
            }
        }
    }
    
    func testBackslashPathTraversal() {
        let windowsPath = "C:\\Users\\..\\Windows\\system32"
        
        XCTAssertThrowsError(try validator.validatePath(windowsPath)) { error in
            XCTAssertTrue(error is ValidationError)
        }
    }
    
    func testValidRelativePaths() throws {
        let safeRelativePaths = [
            "/tmp/normal_folder/file.png",
            "/tmp/another_folder/../file.png",
            "/tmp/subfolder/file.txt"
        ]
        
        for path in safeRelativePaths {
            let result = try? validator.validatePath(path)
            XCTAssertNotNil(result, "Should validate safe relative path: \(path)")
        }
    }
    
    // MARK: - Filename Validation
    
    func testValidFilenames() throws {
        let validFilenames = [
            "test_image.png",
            "image-001.jpg",
            "photo.png",
            "Screenshot 2024.png",
            "file_with_underscores.png"
        ]
        
        for filename in validFilenames {
            XCTAssertNoThrow(try validator.validateFilename(filename), "Should validate: \(filename)")
        }
    }
    
    func testInvalidFilenames() {
        let invalidFilenames = [
            "file/name.png",
            "file\\name.jpg",
            "file:name.png",
            "file*name.jpg",
            "file?name.png",
            "file\"name.jpg",
            "file<name>.png",
            "file>name.jpg",
            "file|name.png",
            "file\0name.png"
        ]
        
        for filename in invalidFilenames {
            XCTAssertThrowsError(try validator.validateFilename(filename)) { error in
                XCTAssertTrue(error is ValidationError, "Should reject: \(filename)")
            }
        }
    }
    
    func testDangerousPatternsInFilenames() {
        let dangerousFilenames = [
            "..hidden",
            "$home",
            "`cmd`",
            "file&command",
            "file;cmd",
            "file|pipe",
            "file>redirect",
            "file<redirect"
        ]
        
        for filename in dangerousFilenames {
            XCTAssertThrowsError(try validator.validateFilename(filename)) { error in
                XCTAssertTrue(error is ValidationError, "Should reject dangerous: \(filename)")
            }
        }
    }
    
    func testFilenameTooLong() {
        let longFilename = String(repeating: "a", count: 300) + ".png"
        
        XCTAssertThrowsError(try validator.validateFilename(longFilename)) { error in
            XCTAssertTrue(error is ValidationError)
        }
    }
    
    // MARK: - File Extension Validation
    
    func testValidExtensions() throws {
        let validFiles = [
            "image.png",
            "photo.jpg",
            "picture.jpeg",
            "file.tif",
            "scan.tiff",
            "bitmap.bmp",
            "animation.gif",
            "web.webp"
        ]
        
        for filename in validFiles {
            XCTAssertNoThrow(try validator.validateFileExtension(filename), "Should accept: \(filename)")
        }
    }
    
    func testInvalidExtensions() {
        let invalidFiles = [
            "script.py",
            "document.pdf",
            "archive.zip",
            "executable.exe",
            "unknown.xyz"
        ]
        
        for filename in invalidFiles {
            XCTAssertThrowsError(try validator.validateFileExtension(filename)) { error in
                XCTAssertTrue(error is ValidationError, "Should reject: \(filename)")
                if let validationError = error as? ValidationError {
                    switch validationError {
                    case .invalidFileExtension(_, let allowed):
                        XCTAssertFalse(allowed.isEmpty, "Should list allowed extensions")
                    default:
                        XCTFail("Wrong error type")
                    }
                }
            }
        }
    }
    
    func testExtensionCaseInsensitivity() throws {
        let uppercaseExt = "IMAGE.PNG"
        let mixedCase = "Photo.JpEg"
        
        XCTAssertNoThrow(try validator.validateFileExtension(uppercaseExt))
        XCTAssertNoThrow(try validator.validateFileExtension(mixedCase))
    }
    
    // MARK: - Filename Sanitization
    
    func testSanitizeFilename() {
        let inputFilename = "bad/file\\name:with*dangerous?chars.jpg"
        let sanitized = validator.sanitizeFilename(inputFilename)
        
        for char in ["/", "\\", ":", "*", "?"] {
            XCTAssertFalse(sanitized.contains(char), "Should remove dangerous character: \(char)")
        }
    }
    
    func testSanitizeDangerousPatterns() {
        let dangerousFilenames = [
            ("file..name", "file_.name"),
            ("file$home", "file_home"),
            ("file`cmd`", "file_cmd_"),
            ("file&command", "file_command"),
        ]
        
        for (input, expected) in dangerousFilenames {
            let sanitized = validator.sanitizeFilename(input)
            XCTAssertTrue(sanitized.contains(expected), "Should sanitize: \(input)")
        }
    }
    
    func testSanitizeControlCharacters() {
        let controlFiles = [
            "-evil.png",
            "@malicious.jpg",
            "--file.png"
        ]
        
        for filename in controlFiles {
            let sanitized = validator.sanitizeFilename(filename)
            XCTAssertFalse(sanitized.hasPrefix("-"), "Should not start with dash")
            XCTAssertFalse(sanitized.hasPrefix("@"), "Should not start with @")
        }
    }
    
    func testSanitizeEmptyResult() {
        let emptyInput = "////\\\\??**"
        let sanitized = validator.sanitizeFilename(emptyInput)
        
        XCTAssertFalse(sanitized.isEmpty, "Should generate fallback name")
        XCTAssertTrue(sanitized.contains("unnamed"), "Should use fallback pattern")
    }
    
    func testSanitizeTruncation() {
        let veryLongName = String(repeating: "a", count: 500)
        let sanitized = validator.sanitizeFilename(veryLongName)
        
        XCTAssertLessThanOrEqual(sanitized.count, PathValidator.shared.maxFilenameLength)
    }
    
    // MARK: - Directory Whitelisting
    
    func testIsPathAllowedForAllowedDirectories() throws {
        let allowedPaths = [
            try validator.validatePath("/tmp/test.png"),
            try validator.validatePath("/private/tmp/file.jpg")
        ]
        
        for path in allowedPaths {
            let isAllowed = validator.isPathAllowed(path)
            XCTAssertTrue(isAllowed, "Should allow path: \(path.path)")
        }
    }
    
    func testRequirePathAllowedSuccess() throws {
        let validPath = URL(fileURLWithPath: "/tmp/test.png")
        let validated = try validator.validateURL(validPath)
        XCTAssertNotNil(validated)
    }
    
    func testRequirePathAllowedFailure() throws {
        let systemPath = URL(fileURLWithPath: "/etc/passwd")
        
        XCTAssertThrowsError(try validator.requirePathAllowed(systemPath)) { error in
            XCTAssertTrue(error is ValidationError)
        }
    }
    
    // MARK: - Coordinate Validation
    
    func testValidCoordinates() throws {
        let validCoords: [CGFloat] = [0, 0.5, 1, 0.123, 0.999]
        
        for coord in validCoords {
            XCTAssertNoThrow(try validator.validateCoordinate(coord))
        }
    }
    
    func testInvalidCoordinates() {
        let invalidCoords: [CGFloat] = [-0.1, -1, 1.5, 2, -0.001, 1.001]
        
        for coord in invalidCoords {
            XCTAssertThrowsError(try validator.validateCoordinate(coord)) { error in
                XCTAssertTrue(error is ValidationError)
            }
        }
    }
    
    func testNaNCoordinate() {
        let nanCoord: CGFloat = .nan
        
        XCTAssertThrowsError(try validator.validateCoordinate(nanCoord)) { error in
            if let validationError = error as? ValidationError {
                switch validationError {
                case .invalidCoordinate:
                    XCTAssertTrue(true, "Should catch NaN")
                default:
                    XCTFail("Wrong error type")
                }
            }
        }
    }
    
    func testInfiniteCoordinate() {
        let infCoord: CGFloat = .infinity
        
        XCTAssertThrowsError(try validator.validateCoordinate(infCoord)) { error in
            if let validationError = error as? ValidationError {
                switch validationError {
                case .invalidCoordinate:
                    XCTAssertTrue(true, "Should catch infinity")
                default:
                    XCTFail("Wrong error type")
                }
            }
        }
    }
    
    func testValidPoint() throws {
        let validPoints = [
            CGPoint(x: 0, y: 0),
            CGPoint(x: 0.5, y: 0.5),
            CGPoint(x: 1, y: 1),
            CGPoint(x: 0.25, y: 0.75)
        ]
        
        for point in validPoints {
            XCTAssertNoThrow(try validator.validatePoint(point))
        }
    }
    
    func testInvalidPoint() {
        let invalidPoints = [
            CGPoint(x: -0.1, y: 0.5),
            CGPoint(x: 0.5, y: 1.5),
            CGPoint(x: -1, y: -1),
            CGPoint(x: .nan, y: 0.5)
        ]
        
        for point in invalidPoints {
            XCTAssertThrowsError(try validator.validatePoint(point)) { error in
                XCTAssertTrue(error is ValidationError)
            }
        }
    }
    
    // MARK: - Dimension Validation
    
    func testValidDimensions() throws {
        let validSizes = [
            (1, 1),
            (100, 100),
            (1920, 1080),
            (16384, 16384)
        ]
        
        for (width, height) in validSizes {
            XCTAssertNoThrow(try validator.validateDimensions(width: width, height: height))
        }
    }
    
    func testInvalidZeroDimensions() {
        let zeroSizes = [
            (0, 100),
            (100, 0),
            (0, 0)
        ]
        
        for (width, height) in zeroSizes {
            XCTAssertThrowsError(try validator.validateDimensions(width: width, height: height)) { error in
                XCTAssertTrue(error is ValidationError)
            }
        }
    }
    
    func testInvalidNegativeDimensions() {
        let negativeSizes = [
            (-100, 100),
            (100, -100),
            (-1, -1)
        ]
        
        for (width, height) in negativeSizes {
            XCTAssertThrowsError(try validator.validateDimensions(width: width, height: height)) { error in
                XCTAssertTrue(error is ValidationError)
            }
        }
    }
    
    func testDimensionsTooLarge() {
        let tooLarge = [
            (16385, 100),
            (100, 16385),
            (20000, 20000)
        ]
        
        for (width, height) in tooLarge {
            XCTAssertThrowsError(try validator.validateDimensions(width: width, height: height)) { error in
                if let validationError = error as? ValidationError {
                    switch validationError {
                    case .imageDimensionsExceeded(_, _, let max):
                        XCTAssertEqual(max, 16384)
                    default:
                        XCTFail("Wrong error type")
                    }
                }
            }
        }
    }
    
    // MARK: - Safe Output Path Tests
    
    func testGetSafeOutputPath() throws {
        let tempDir = try TestHelpers.createTempDirectory()
        defer { TestHelpers.cleanupTempDirectory(at: tempDir) }
        
        let path1 = try validator.getSafeOutputPath(basename: "test", extension: "png", in: tempDir)
        let path2 = try validator.getSafeOutputPath(basename: "test", extension: "png", in: tempDir)
        let path3 = try validator.getSafeOutputPath(basename: "test", extension: "png", in: tempDir)
        
        XCTAssertEqual(path1.deletingLastPathComponent(), tempDir)
        XCTAssertEqual(path2.deletingLastPathComponent(), tempDir)
        XCTAssertEqual(path3.deletingLastPathComponent(), tempDir)
        
        XCTAssertNotEqual(path1, path2, "Should generate unique paths")
        XCTAssertNotEqual(path2, path3, "Should generate unique paths")
        
        XCTAssertTrue(path1.lastPathComponent.hasPrefix("test"))
        XCTAssertTrue(path2.lastPathComponent.hasPrefix("test"))
        XCTAssertTrue(path3.lastPathComponent.hasPrefix("test"))
    }
    
    func testGetSafeOutputPathSanitizes() throws {
        let tempDir = try TestHelpers.createTempDirectory()
        defer { TestHelpers.cleanupTempDirectory(at: tempDir) }
        
        let path = try validator.getSafeOutputPath(
            basename: "bad/file:name",
            extension: "png",
            in: tempDir
        )
        
        XCTAssertFalse(path.lastPathComponent.contains("/"))
        XCTAssertFalse(path.lastPathComponent.contains(":"))
        XCTAssertTrue(path.lastPathComponent.hasSuffix(".png"))
    }
}
