import Foundation

class PathValidator {
    static let shared = PathValidator()

    private let fileManager = FileManager.default

    private(set) var allowedDirectories: Set<URL> = []
    private let allowedExtensions: Set<String> = [
        "png", "jpg", "jpeg", "tif", "tiff", "bmp", "gif", "webp"
    ]

    private let maxPathLength = 1024
    let maxFilenameLength = 255

    private init() {
        setupAllowedDirectories()
    }

    private func setupAllowedDirectories() {
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent("ModelrV3", isDirectory: true)

        if let appSupport = appSupport {
            allowedDirectories.insert(appSupport)
            allowedDirectories.insert(appSupport.resolvingSymlinksInPath())
            allowedDirectories.insert(appSupport.appendingPathComponent("Hunyuan3D", isDirectory: true))
            allowedDirectories.insert(appSupport.appendingPathComponent("checkpoints", isDirectory: true))
        }

        let tempDir = fileManager.temporaryDirectory
        allowedDirectories.insert(tempDir)
        allowedDirectories.insert(tempDir.resolvingSymlinksInPath())
        
        // Also explicitly allow common temp paths to be robust
        allowedDirectories.insert(URL(fileURLWithPath: "/tmp", isDirectory: true))
        allowedDirectories.insert(URL(fileURLWithPath: "/private/tmp", isDirectory: true))
    }

    func validatePath(_ path: String) throws -> URL {
        let url = URL(fileURLWithPath: path)

        guard path.count <= maxPathLength else {
            throw ValidationError.invalidPath("Path too long")
        }

        // We check for traversal after standardization to see if it escapes

        let filename = url.lastPathComponent
        guard filename.count <= maxFilenameLength else {
            throw ValidationError.invalidPath("Filename too long")
        }

        guard !filename.isEmpty else {
            throw ValidationError.invalidPath("Empty filename")
        }

        try validateFilename(filename)

        let resolvedURL = try resolveAndValidateURL(url)

        return resolvedURL
    }

    func validateURL(_ url: URL) throws -> URL {
        guard url.isFileURL else {
            throw ValidationError.invalidPath("Not a file URL")
        }

        return try validatePath(url.path)
    }

    private func resolveAndValidateURL(_ url: URL) throws -> URL {
        let resolvedURL = url.resolvingSymlinksInPath()
        let standardizedURL = resolvedURL.standardized
        let standardizedPath = standardizedURL.path

        // Check for traversal attempt by comparing with original path
        if url.path.contains("..") {
            if !isPathAllowed(standardizedURL) {
                throw ValidationError.pathTraversalAttempt(url.path)
            }
        }

        for component in standardizedPath.components(separatedBy: "/") {
            guard !component.isEmpty || component == "." else { continue }

            if component.hasPrefix(".") && component != "." && component != ".." {
                guard !component.contains(" ") else {
                    throw ValidationError.maliciousFilename(component)
                }
            }
        }

        return resolvedURL
    }

    func isPathAllowed(_ url: URL) -> Bool {
        let standardizedURL = url.standardized

        for allowedDir in allowedDirectories {
            let standardizedAllowed = allowedDir.standardized

            if standardizedURL.path.hasPrefix(standardizedAllowed.path) {
                return true
            }
        }

        return false
    }

    func requirePathAllowed(_ url: URL) throws {
        guard isPathAllowed(url) else {
            throw ValidationError.invalidPath("Path not in allowed directories: \(url.path)")
        }
    }

    func validateFilename(_ filename: String) throws {
        let forbiddenCharacters: Set<Character> = [
            "\0", "/", "\\", ":", "*", "?", "\"", "<", ">", "|"
        ]

        if filename.contains(where: { forbiddenCharacters.contains($0) }) {
            throw ValidationError.maliciousFilename("Contains forbidden characters")
        }

        let dangerousPatterns = ["..", "~", "$", "`", "&", ";", "|", ">", "<"]
        for pattern in dangerousPatterns {
            if filename.contains(pattern) {
                throw ValidationError.maliciousFilename("Contains dangerous pattern: \(pattern)")
            }
        }

        if filename.hasPrefix("-") || filename.hasPrefix("@") {
            throw ValidationError.maliciousFilename("Starts with control character")
        }

        if filename.count > maxFilenameLength {
            throw ValidationError.maliciousFilename("Filename too long")
        }
    }

    func validateFileExtension(_ filename: String) throws {
        let ext = (filename as NSString).pathExtension.lowercased()

        guard !ext.isEmpty else {
            throw ValidationError.invalidFileExtension(ext, allowed: Array(allowedExtensions))
        }

        guard allowedExtensions.contains(ext) else {
            throw ValidationError.invalidFileExtension(ext, allowed: Array(allowedExtensions))
        }
    }

    func sanitizeFilename(_ filename: String) -> String {
        var sanitized = filename

        let forbiddenCharacters: Set<Character> = [
            "\0", "/", "\\", ":", "*", "?", "\"", "<", ">", "|"
        ]

        sanitized = sanitized.filter { !forbiddenCharacters.contains($0) }

        let dangerousPatterns = ["..", "~", "$", "`", "&", ";", "|", ">", "<"]
        for pattern in dangerousPatterns {
            sanitized = sanitized.replacingOccurrences(of: pattern, with: "_")
        }

        if sanitized.hasPrefix("-") || sanitized.hasPrefix("@") {
            sanitized = "_" + sanitized.dropFirst()
        }

        sanitized = String(sanitized.prefix(maxFilenameLength))

        if sanitized.isEmpty {
            sanitized = "unnamed_\(Int(Date().timeIntervalSince1970))"
        }

        return sanitized
    }

    func getSafeOutputPath(basename: String, extension: String, in directory: URL) throws -> URL {
        let sanitizedBasename = sanitizeFilename(basename)
        let sanitizedExtension = sanitizeFilename(`extension`)

        var outputPath = directory.appendingPathComponent("\(sanitizedBasename).\(sanitizedExtension)")

        var counter = 1
        while fileManager.fileExists(atPath: outputPath.path) {
            outputPath = directory.appendingPathComponent("\(sanitizedBasename)_\(counter).\(sanitizedExtension)")
            counter += 1
        }

        try requirePathAllowed(outputPath)

        return outputPath
    }

    func validateCoordinate(_ value: CGFloat) throws {
        guard !value.isNaN && !value.isInfinite else {
            throw ValidationError.invalidCoordinate(value: value)
        }

        guard value >= 0 && value <= 1 else {
            throw ValidationError.coordinateOutOfRange(value: value)
        }
    }

    func validatePoint(_ point: CGPoint) throws {
        try validateCoordinate(point.x)
        try validateCoordinate(point.y)
    }

    func validateDimensions(width: Int, height: Int, maxDimension: Int = 16384) throws {
        guard width > 0 && height > 0 else {
            throw ValidationError.imageDimensionsExceeded(width: width, height: height, max: maxDimension)
        }

        guard width <= maxDimension && height <= maxDimension else {
            throw ValidationError.imageDimensionsExceeded(width: width, height: height, max: maxDimension)
        }
    }
}
