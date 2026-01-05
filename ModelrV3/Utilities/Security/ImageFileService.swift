import Foundation
import AppKit

class ImageFileService {
    static let shared = ImageFileService()

    private let pathValidator = PathValidator.shared
    private let secureFileManager = SecureFileManager.shared
    private let logger = SecureLogger.shared

    private let allowedImageExtensions = [
        "png", "jpg", "jpeg", "tif", "tiff", "bmp", "gif", "webp"
    ]

    private let maxImageSize: Int64 = 100 * 1024 * 1024
    private let maxImageDimension = 16384

    private init() {}

    func readImage(from url: URL) throws -> NSImage {
        try pathValidator.validateURL(url)
        try pathValidator.validateFileExtension(url.path)
        try pathValidator.requirePathAllowed(url)

        guard allowedImageExtensions.contains(url.pathExtension.lowercased()) else {
            throw ValidationError.invalidFileExtension(url.pathExtension, allowed: allowedImageExtensions)
        }

        let data = try secureFileManager.readData(from: url)
        try validateImageFileSize(data.count, for: url)

        guard let image = NSImage(data: data) else {
            throw ValidationError.invalidImageFormat
        }

        try validateImageDimensions(image)

        try detectMaliciousImage(image, data: data)

        logger.info("Successfully loaded image from \(url.lastPathComponent)")

        return image
    }

    func writeImage(_ image: NSImage, to url: URL) throws {
        try pathValidator.validateURL(url)
        try pathValidator.requirePathAllowed(url)

        guard let tiffData = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData) else {
            throw ValidationError.invalidImageFormat
        }

        let ext = url.pathExtension.lowercased()
        guard let fileType = fileTypeForExtension(ext) else {
            throw ValidationError.invalidFileExtension(ext, allowed: allowedImageExtensions)
        }

        guard let imageData = bitmap.representation(using: fileType, properties: [:]) else {
            throw FileError.writeError(url.path, underlying: nil)
        }

        try validateImageFileSize(imageData.count, for: url)

        try secureFileManager.atomicWrite(to: url, data: imageData, permissions: 0o644)

        logger.info("Successfully saved image to \(url.lastPathComponent)")
    }

    func readImageMetadata(from url: URL) throws -> (width: Int, height: Int, size: Int64) {
        try pathValidator.validateURL(url)
        try pathValidator.requirePathAllowed(url)

        guard let imageSource = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            throw ValidationError.invalidImageFormat
        }

        guard let properties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [CFString: Any] else {
            throw ValidationError.invalidImageFormat
        }

        guard let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int else {
            throw ValidationError.malformedData(type: "image metadata")
        }

        let fileSize = try secureFileManager.getFileSize(url)

        try validateImageDimensions(width: width, height: height)
        try validateImageFileSize(Int(fileSize), for: url)

        return (width, height, fileSize)
    }

    private func validateImageFileSize(_ size: Int, for url: URL) throws {
        let size64 = Int64(size)
        guard size64 <= maxImageSize else {
            throw ValidationError.fileSizeExceeded(size64, max: maxImageSize)
        }
    }

    private func validateImageDimensions(_ image: NSImage) throws {
        guard let rep = image.representations.first else {
            throw ValidationError.invalidImageFormat
        }

        let width = rep.pixelsWide
        let height = rep.pixelsHigh

        try pathValidator.validateDimensions(width: width, height: height, maxDimension: maxImageDimension)
    }

    private func validateImageDimensions(width: Int, height: Int) throws {
        try pathValidator.validateDimensions(width: width, height: height, maxDimension: maxImageDimension)
    }

    private func detectMaliciousImage(_ image: NSImage, data: Data) throws {
        guard let tiffData = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData) else {
            throw ValidationError.invalidImageFormat
        }

        let width = bitmap.pixelsWide
        let height = bitmap.pixelsHigh
        let expectedSize = width * height * 4

        let ratio = Double(data.count) / Double(expectedSize)

        if ratio > 10.0 || ratio < 0.01 {
            logger.warning("Suspicious image size ratio: \(ratio)")
        }

        let maxPixelCount = maxImageDimension * maxImageDimension
        if width * height > maxPixelCount {
            throw ValidationError.imageDimensionsExceeded(width: width, height: height, max: maxImageDimension)
        }

        if data.count > 2 * 1024 * 1024 && width * height < 100 * 100 {
            logger.warning("Small image with large file size - potential malicious content")
        }
    }

    private func fileTypeForExtension(_ ext: String) -> NSBitmapImageRep.FileType? {
        switch ext.lowercased() {
        case "png":
            return .png
        case "jpg", "jpeg":
            return .jpeg
        case "tif", "tiff":
            return .tiff
        case "bmp":
            return .bmp
        case "gif":
            return .gif
        default:
            return nil
        }
    }

    func validateAndProcessImage(_ url: URL) throws -> NSImage {
        let metadata = try readImageMetadata(from: url)

        logger.debug("Image metadata: \(metadata.width)x\(metadata.height), size: \(metadata.size) bytes")

        let image = try readImage(from: url)

        return image
    }

    func safeCreateTemporaryFile(extension ext: String) throws -> URL {
        let tempDir = FileManager.default.temporaryDirectory
        let filename = "modelr_\(UUID().uuidString).\(ext)"

        var tempURL = tempDir.appendingPathComponent(filename)

        var counter = 1
        while FileManager.default.fileExists(atPath: tempURL.path) {
            tempURL = tempDir.appendingPathComponent("modelr_\(UUID().uuidString)_\(counter).\(ext)")
            counter += 1
        }

        return tempURL
    }
}
