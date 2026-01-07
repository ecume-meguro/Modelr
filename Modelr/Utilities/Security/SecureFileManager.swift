import Foundation

class SecureFileManager {
    static let shared = SecureFileManager()

    private let fileManager = FileManager.default
    private let pathValidator = PathValidator.shared
    private let logger = SecureLogger.shared

    private let fileLocks = NSMapTable<NSString, NSLock>.strongToWeakObjects()
    private let lockQueue = DispatchQueue(label: "com.modelr.filelocks", attributes: .concurrent)

    private let directoryPermissions: UInt16 = 0o700
    private let privateFilePermissions: UInt16 = 0o600
    private let readableFilePermissions: UInt16 = 0o644

    private init() {}

    func verifyAppSupportPermissions() throws {
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let modelrDir = appSupport.appendingPathComponent(AppConstants.appSupportDirectoryName)

        if fileManager.fileExists(atPath: modelrDir.path) {
            let attributes = try fileManager.attributesOfItem(atPath: modelrDir.path)

            if let permissions = attributes[.posixPermissions] as? UInt16 {
                let expectedPermissions = directoryPermissions

                if (permissions & 0o777) != expectedPermissions {
                    logger.warning("Directory permissions incorrect: \(String(permissions, radix: 8)), fixing...")

                    try fileManager.setAttributes(
                        [.posixPermissions: expectedPermissions],
                        ofItemAtPath: modelrDir.path
                    )
                }
            }
        }
    }

    func createSecureDirectory(at url: URL) throws {
        try pathValidator.validateURL(url)
        try pathValidator.requirePathAllowed(url)

        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) {
            guard isDirectory.boolValue else {
                throw FileError.directoryCreationError(url.path, underlying: nil)
            }

            let attributes = try fileManager.attributesOfItem(atPath: url.path)
            if let permissions = attributes[.posixPermissions] as? UInt16 {
                let expectedPermissions = directoryPermissions
                if (permissions & 0o777) != expectedPermissions {
                    try fileManager.setAttributes([.posixPermissions: expectedPermissions], ofItemAtPath: url.path)
                }
            }
            return
        }

        try fileManager.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: directoryPermissions])

        logger.debug("Created secure directory: \(sanitizedPath(url.path))")
    }

    func atomicWrite(to url: URL, data: Data, permissions: UInt16? = nil) throws {
        try pathValidator.validateURL(url)
        try pathValidator.requirePathAllowed(url)

        let tempDir = url.deletingLastPathComponent()
        let tempFilename = ".tmp_\(UUID().uuidString)_\(url.lastPathComponent)"
        let tempURL = tempDir.appendingPathComponent(tempFilename)

        do {
            try data.write(to: tempURL, options: .atomic)

            let finalPermissions = permissions ?? privateFilePermissions
            try fileManager.setAttributes([.posixPermissions: finalPermissions], ofItemAtPath: tempURL.path)

            try fileManager.replaceItem(at: url, withItemAt: tempURL, backupItemName: nil, options: [], resultingItemURL: nil)

            logger.debug("Atomically wrote \(data.count) bytes to \(sanitizedPath(url.path))")
        } catch {
            try? fileManager.removeItem(at: tempURL)
            throw FileError.writeError(url.path, underlying: error)
        }
    }

    func atomicWriteString(to url: URL, string: String, encoding: String.Encoding = .utf8, permissions: UInt16? = nil) throws {
        guard let data = string.data(using: encoding) else {
            throw FileError.writeError(url.path, underlying: nil)
        }
        try atomicWrite(to: url, data: data, permissions: permissions)
    }

    func readData(from url: URL) throws -> Data {
        try pathValidator.validateURL(url)
        try pathValidator.requirePathAllowed(url)

        guard fileManager.fileExists(atPath: url.path) else {
            throw FileError.notFound(url.path)
        }

        guard fileManager.isReadableFile(atPath: url.path) else {
            throw FileError.permissionDenied(url.path)
        }

        do {
            let data = try Data(contentsOf: url, options: .mappedIfSafe)

            let fileSize = Int64(data.count)
            try validateFileSize(fileSize, for: url)

            logger.debug("Read \(data.count) bytes from \(sanitizedPath(url.path))")
            return data
        } catch {
            throw FileError.readError(url.path, underlying: error)
        }
    }

    func readString(from url: URL, encoding: String.Encoding = .utf8) throws -> String {
        let data = try readData(from: url)
        guard let string = String(data: data, encoding: encoding) else {
            throw FileError.readError(url.path, underlying: nil)
        }
        return string
    }

    func fileExists(at url: URL) -> Bool {
        return fileManager.fileExists(atPath: url.path)
    }

    func removeIfExists(at url: URL) throws {
        try pathValidator.validateURL(url)
        try pathValidator.requirePathAllowed(url)
        
        if fileManager.fileExists(atPath: url.path) {
            try fileManager.removeItem(at: url)
            logger.debug("Removed file if existed: \(sanitizedPath(url.path))")
        }
    }

    func ensureDirectoryExists(at url: URL) throws {
        try createSecureDirectory(at: url)
    }

    func deleteFile(at url: URL) throws {
        try pathValidator.validateURL(url)
        try pathValidator.requirePathAllowed(url)

        guard fileManager.fileExists(atPath: url.path) else {
            return
        }

        do {
            try fileManager.removeItem(at: url)
            logger.debug("Deleted file: \(sanitizedPath(url.path))")
        } catch {
            throw FileError.deleteError(url.path, underlying: error)
        }
    }

    func moveFile(from source: URL, to destination: URL) throws {
        try pathValidator.validateURL(source)
        try pathValidator.validateURL(destination)
        try pathValidator.requirePathAllowed(source)
        try pathValidator.requirePathAllowed(destination)

        guard fileManager.fileExists(atPath: source.path) else {
            throw FileError.notFound(source.path)
        }

        do {
            try fileManager.moveItem(at: source, to: destination)
            logger.debug("Moved file from \(sanitizedPath(source.path)) to \(sanitizedPath(destination.path))")
        } catch {
            throw FileError.writeError(destination.path, underlying: error)
        }
    }

    func copyFile(from source: URL, to destination: URL, overwrite: Bool = true) throws {
        try pathValidator.validateURL(source)
        try pathValidator.validateURL(destination)
        try pathValidator.requirePathAllowed(source)
        try pathValidator.requirePathAllowed(destination)

        guard fileManager.fileExists(atPath: source.path) else {
            throw FileError.notFound(source.path)
        }

        if overwrite && fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }

        do {
            try fileManager.copyItem(at: source, to: destination)
            try setPermissions(for: destination, permissions: privateFilePermissions)
            logger.debug("Copied file from \(sanitizedPath(source.path)) to \(sanitizedPath(destination.path))")
        } catch {
            throw FileError.writeError(destination.path, underlying: error)
        }
    }

    func validateFileSize(_ size: Int64, for url: URL) throws {
        let maxImageSize: Int64 = 100 * 1024 * 1024
        let maxModelSize: Int64 = 2 * 1024 * 1024 * 1024

        let pathExtension = url.pathExtension.lowercased()

        let maxSize: Int64
        if ["obj", "glb", "gltf"].contains(pathExtension) {
            maxSize = maxModelSize
        } else {
            maxSize = maxImageSize
        }

        guard size <= maxSize else {
            throw ValidationError.fileSizeExceeded(size, max: maxSize)
        }
    }

    func getFileSize(_ url: URL) throws -> Int64 {
        try pathValidator.validateURL(url)

        let attributes = try fileManager.attributesOfItem(atPath: url.path)

        guard let fileSize = attributes[.size] as? UInt64 else {
            throw FileError.readError(url.path, underlying: nil)
        }

        return Int64(fileSize)
    }

    func setPermissions(for url: URL, permissions: UInt16) throws {
        try fileManager.setAttributes([.posixPermissions: permissions], ofItemAtPath: url.path)
    }

    func acquireLock(for url: URL, timeout: TimeInterval = 10.0) throws -> NSLock {
        let path = url.path

        let lock = lockQueue.sync { () -> NSLock in
            if let existingLock = fileLocks.object(forKey: path as NSString) {
                return existingLock
            }

            let newLock = NSLock()
            newLock.name = "com.modelr.lock.\(path)"
            fileLocks.setObject(newLock, forKey: path as NSString)
            return newLock
        }

        let deadline = Date().addingTimeInterval(timeout)
        while !lock.try() {
            if Date() > deadline {
                throw FileError.lockTimeout(url.lastPathComponent)
            }
            Thread.sleep(forTimeInterval: 0.01)
        }

        return lock
    }

    func releaseLock(for url: URL) {
        let path = url.path
        if let lock = fileLocks.object(forKey: path as NSString) {
            lock.unlock()
        }
    }

    private func sanitizedPath(_ path: String) -> String {
        if path.contains("Application Support") {
            return path.replacingOccurrences(
                of: "/Users/[^/]+/Library/Application Support/(ModelrV3|Modelr)/",
                with: "~/Library/Application Support/$1/",
                options: .regularExpression
            )
        }
        return path
    }
}
