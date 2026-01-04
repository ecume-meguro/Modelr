import Foundation

// MARK: - Validation Errors

enum ValidationError: Error, LocalizedError {
    case invalidPath(String)
    case pathTraversalAttempt(String)
    case maliciousFilename(String)
    case invalidFileExtension(String, allowed: [String])
    case fileSizeExceeded(Int64, max: Int64)
    case imageDimensionsExceeded(width: Int, height: Int, max: Int)
    case invalidImageFormat
    case maliciousImageContent
    case invalidCoordinate(value: CGFloat)
    case coordinateOutOfRange(value: CGFloat)
    case emptyValue(field: String)
    case malformedData(type: String)
    case versionMismatch(expected: String, actual: String?)

    var errorDescription: String? {
        switch self {
        case .invalidPath(let path):
            return "Invalid path: \(path)"
        case .pathTraversalAttempt(let path):
            return "Path traversal attempt detected: \(path)"
        case .maliciousFilename(let name):
            return "Potentially malicious filename: \(name)"
        case .invalidFileExtension(let ext, let allowed):
            return "Invalid file extension: .\(ext). Allowed: \(allowed.joined(separator: ", "))"
        case .fileSizeExceeded(let size, let max):
            return "File size \(size) bytes exceeds maximum \(max) bytes"
        case .imageDimensionsExceeded(let w, let h, let max):
            return "Image dimensions \(w)x\(h) exceed maximum \(max)"
        case .invalidImageFormat:
            return "Invalid or unsupported image format"
        case .maliciousImageContent:
            return "Malicious image content detected"
        case .invalidCoordinate(let value):
            return "Invalid coordinate value: \(value)"
        case .coordinateOutOfRange(let value):
            return "Coordinate \(value) is out of range (must be 0-1)"
        case .emptyValue(let field):
            return "\(field) cannot be empty"
        case .malformedData(let type):
            return "Malformed \(type) data"
        case .versionMismatch(let expected, let actual):
            return "Version mismatch: expected \(expected), got \(actual ?? "none")"
        }
    }
}

// MARK: - File Errors

enum FileError: Error, LocalizedError {
    case notFound(String)
    case permissionDenied(String)
    case readError(String, underlying: Error?)
    case writeError(String, underlying: Error?)
    case deleteError(String, underlying: Error?)
    case directoryCreationError(String, underlying: Error?)
    case invalidURL(URL)
    case concurrentAccess(String)
    case lockTimeout(String)
    case quotaExceeded
    case unsafeOperation(String)

    var errorDescription: String? {
        switch self {
        case .notFound(let path):
            return "File not found: \(path)"
        case .permissionDenied(let path):
            return "Permission denied: \(path)"
        case .readError(let path, let error):
            return "Failed to read \(path): \(error?.localizedDescription ?? "unknown error")"
        case .writeError(let path, let error):
            return "Failed to write \(path): \(error?.localizedDescription ?? "unknown error")"
        case .deleteError(let path, let error):
            return "Failed to delete \(path): \(error?.localizedDescription ?? "unknown error")"
        case .directoryCreationError(let path, let error):
            return "Failed to create directory \(path): \(error?.localizedDescription ?? "unknown error")"
        case .invalidURL(let url):
            return "Invalid URL: \(url.absoluteString)"
        case .concurrentAccess(let path):
            return "Concurrent access detected: \(path)"
        case .lockTimeout(let resource):
            return "Failed to acquire lock for \(resource)"
        case .quotaExceeded:
            return "Disk quota exceeded"
        case .unsafeOperation(let op):
            return "Unsafe operation blocked: \(op)"
        }
    }
}

// MARK: - Security Errors

enum SecurityError: Error, LocalizedError {
    case downloadChecksumMismatch(expected: String, actual: String)
    case downloadSizeExceeded(Int64, max: Int64)
    case insecureConnection(String)
    case verificationFailed(String)
    case signatureInvalid
    case corruptedData(String)
    case integrityCheckFailed(String)
    case unauthorizedAccess(String)
    case rateLimitExceeded
    case maliciousCodeDetected
    case modelTampered
    case dependencyMissing(String)
    case sandboxViolation(String)
    case processInjectionAttempt
    case invalidModelState

    var errorDescription: String? {
        switch self {
        case .downloadChecksumMismatch(let expected, let actual):
            return "Download checksum mismatch: expected \(expected), got \(actual)"
        case .downloadSizeExceeded(let size, let max):
            return "Download size \(size) bytes exceeds maximum \(max) bytes"
        case .insecureConnection(let url):
            return "Insecure connection to \(url)"
        case .verificationFailed(let resource):
            return "Verification failed for \(resource)"
        case .signatureInvalid:
            return "Invalid digital signature"
        case .corruptedData(let what):
            return "Corrupted data detected: \(what)"
        case .integrityCheckFailed(let what):
            return "Integrity check failed: \(what)"
        case .unauthorizedAccess(let resource):
            return "Unauthorized access to \(resource)"
        case .rateLimitExceeded:
            return "Rate limit exceeded"
        case .maliciousCodeDetected:
            return "Malicious code detected"
        case .modelTampered:
            return "Model file has been tampered with"
        case .dependencyMissing(let dep):
            return "Required dependency missing: \(dep)"
        case .sandboxViolation(let operation):
            return "Sandbox violation: \(operation)"
        case .processInjectionAttempt:
            return "Process injection attempt detected"
        case .invalidModelState:
            return "Invalid model state"
        }
    }
}

// MARK: - PythonError Extension

extension PythonError {
    var isRecoverable: Bool {
        switch self {
        case .timeout, .workerNotRunning:
            return true
        case .uvNotFound, .invalidResponse, .predictionFailed, .encodingError, .workerNotReady:
            return false
        }
    }

    var suggestedAction: String {
        switch self {
        case .uvNotFound:
            return "Please reinstall the application"
        case .workerNotRunning:
            return "Restart the application"
        case .workerNotReady:
            return "Check Python environment setup"
        case .encodingError:
            return "Try again with different input"
        case .invalidResponse:
            return "Check Python environment and logs"
        case .predictionFailed(let error):
            return error
        case .timeout:
            return "Try again or reduce image size"
        }
    }
}
