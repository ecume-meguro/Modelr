import Foundation
import XCTest
@testable import Modelr

class TestHelpers {
    
    static func assertPointEqual(_ point1: CGPoint, _ point2: CGPoint, accuracy: CGFloat = 0.001, file: StaticString = #file, line: UInt = #line) {
        XCTAssertEqual(point1.x, point2.x, accuracy: accuracy, "X coordinates differ", file: file, line: line)
        XCTAssertEqual(point1.y, point2.y, accuracy: accuracy, "Y coordinates differ", file: file, line: line)
    }
    
    static func assertPointsEqual(_ points1: [CGPoint], _ points2: [CGPoint], accuracy: CGFloat = 0.001, file: StaticString = #file, line: UInt = #line) {
        XCTAssertEqual(points1.count, points2.count, "Point counts differ", file: file, line: line)
        for i in 0..<min(points1.count, points2.count) {
            assertPointEqual(points1[i], points2[i], accuracy: accuracy, file: file, line: line)
        }
    }
    
    static func createTempDirectory() throws -> URL {
        let tempDir = FileManager.default.temporaryDirectory
        let uniqueName = "ModelrTest_\(UUID().uuidString)"
        let testDir = tempDir.appendingPathComponent(uniqueName)
        try FileManager.default.createDirectory(at: testDir, withIntermediateDirectories: true)
        return testDir
    }
    
    static func cleanupTempDirectory(at url: URL) {
        try? FileManager.default.removeItem(at: url)
    }
    
    static func saveTestImage(_ image: NSImage, to url: URL) throws {
        guard let tiffData = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData),
              let pngData = bitmap.representation(using: .png, properties: [:]) else {
            throw NSError(domain: "TestHelpers", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to create PNG data"])
        }
        try pngData.write(to: url)
    }
    
    static func measureCode<T>(iterations: Int = 100, block: () -> T) -> (average: TimeInterval, results: [T]) {
        var results: [T] = []
        var totalTime: TimeInterval = 0
        
        for _ in 0..<iterations {
            let start = Date()
            let result = block()
            let elapsed = Date().timeIntervalSince(start)
            totalTime += elapsed
            results.append(result)
        }
        
        return (totalTime / Double(iterations), results)
    }
}

extension XCTestCase {
    
    func assertThrows<T: Error>(_ errorType: T.Type, block: () throws -> Void, file: StaticString = #file, line: UInt = #line) where T: Equatable {
        var caughtError: Error?
        
        do {
            try block()
        } catch {
            caughtError = error
        }
        
        XCTAssertNotNil(caughtError, "Expected to throw \(errorType) but no error was thrown", file: file, line: line)
        
        if let caught = caughtError as? T {
            XCTAssertEqual(caught, caught, file: file, line: line)
        }
    }
    
    func wait(for duration: TimeInterval) async {
        try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
    }
}
