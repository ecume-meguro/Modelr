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

// MARK: - Python Communication Errors

enum PythonCommunicationError: Error, LocalizedError {
    case invalidCommand(String)
    case missingRequiredField(String)
    case invalidPointValue
    case invalidBoxValue
    case versionMismatch(String)
    case unexpectedResponse(String)

    var errorDescription: String? {
        switch self {
        case .invalidCommand(let cmd):
            return "Invalid command: \(cmd)"
        case .missingRequiredField(let field):
            return "Missing required field: \(field)"
        case .invalidPointValue:
            return "Invalid point value"
        case .invalidBoxValue:
            return "Invalid box value"
        case .versionMismatch(let expected):
            return "Version mismatch: \(expected)"
        case .unexpectedResponse(let msg):
            return "Unexpected response: \(msg)"
        }
    }
}

// MARK: - Python Errors

enum PythonError: Error, LocalizedError {
    case uvNotFound
    case workerNotRunning
    case workerNotReady
    case encodingError
    case invalidResponse(String)
    case predictionFailed(String)
    case timeout
    case processTerminated
    case bufferOverflow(size: Int)

    var errorDescription: String? {
        switch self {
        case .uvNotFound:
            return "uv binary not found"
        case .workerNotRunning:
            return "Python worker is not running"
        case .workerNotReady:
            return "Python worker failed to start"
        case .encodingError:
            return "Failed to encode request"
        case .invalidResponse(let response):
            return "Invalid response from worker: \(response)"
        case .predictionFailed(let error):
            return "Prediction failed: \(error)"
        case .timeout:
            return "Request timed out"
        case .processTerminated:
            return "Python process terminated unexpectedly"
        case .bufferOverflow(let size):
            return "Response buffer overflow (\(size) bytes)"
        }
    }
}

// MARK: - General App Errors

enum AppError: Error, LocalizedError {
    case validation(field: String, message: String)
    case setup(message: String)
    case python(PythonError)
    case pythonComm(PythonCommunicationError)
    case system(Error)
    case imageProcessing(String)
    case generation(String)
    case meshProcessing(String)
    case cancelled
    case unknown

    var errorDescription: String? {
        switch self {
        case .validation(let field, let message):
            return "Validation error in '\(field)': \(message)"
        case .setup(let message):
            return "Setup error: \(message)"
        case .python(let error):
            return error.localizedDescription
        case .pythonComm(let error):
            return error.localizedDescription
        case .system(let error):
            return error.localizedDescription
        case .imageProcessing(let message):
            return "Image processing error: \(message)"
        case .generation(let message):
            return "3D generation error: \(message)"
        case .meshProcessing(let message):
            return "Mesh processing error: \(message)"
        case .cancelled:
            return "Operation was cancelled"
        case .unknown:
            return "An unknown error occurred"
        }
    }

    /// Whether this error is recoverable (can retry)
    var isRecoverable: Bool {
        switch self {
        case .imageProcessing, .generation, .meshProcessing:
            return true
        case .cancelled:
            return false
        case .validation, .setup, .python, .pythonComm, .system, .unknown:
            return false
        }
    }

    /// User-friendly suggested action
    var suggestedAction: String? {
        switch self {
        case .imageProcessing:
            return "Try loading a different image"
        case .generation:
            return "Try again or adjust generation settings"
        case .meshProcessing:
            return "Try exporting in a different format"
        case .setup:
            return "Restart the app and try setup again"
        case .cancelled:
            return nil
        case .validation, .python, .pythonComm, .system, .unknown:
            return "Please restart the app"
        }
    }

    /// User-friendly error message that translates technical errors into understandable language
    var userFriendlyDescription: String {
        // Get the raw error message
        let rawMessage = errorDescription ?? "An unknown error occurred"

        // Apply translations for known technical error patterns
        return AppError.translateToUserFriendly(rawMessage)
    }

    /// Translates technical error messages into user-friendly language
    static func translateToUserFriendly(_ technicalMessage: String) -> String {
        let lowercased = technicalMessage.lowercased()

        // Memory errors
        if lowercased.contains("cuda out of memory") || lowercased.contains("out of memory") || lowercased.contains("oom") {
            return "Not enough memory to generate. Try using the Mini model or closing other apps."
        }

        // GPU/CUDA errors
        if lowercased.contains("cuda") || lowercased.contains("mps") || lowercased.contains("gpu") {
            if lowercased.contains("not available") || lowercased.contains("not found") {
                return "GPU acceleration not available. Generation may be slower."
            }
            return "GPU error occurred. Try restarting the app."
        }

        // Network errors
        if lowercased.contains("connection") || lowercased.contains("network") || lowercased.contains("timeout") {
            return "Network connection issue. Check your internet and try again."
        }

        // Download errors
        if lowercased.contains("download") && (lowercased.contains("fail") || lowercased.contains("error")) {
            return "Model download failed. Check your internet connection and try again."
        }

        // Disk space errors
        if lowercased.contains("disk") || lowercased.contains("space") || lowercased.contains("storage") {
            return "Not enough disk space. Free up some space and try again."
        }

        // File permission errors
        if lowercased.contains("permission") || lowercased.contains("access denied") {
            return "Cannot access required files. Check app permissions."
        }

        // Model loading errors
        if lowercased.contains("load") && lowercased.contains("model") {
            return "Failed to load the AI model. Try restarting the app."
        }

        // Python/worker errors
        if lowercased.contains("worker") || lowercased.contains("process") {
            if lowercased.contains("not running") || lowercased.contains("terminated") {
                return "Background process stopped unexpectedly. Restart the app."
            }
        }

        // Encoding/decoding errors
        if lowercased.contains("encoding") || lowercased.contains("decoding") || lowercased.contains("invalid response") {
            return "Data processing error. Try again."
        }

        // Timeout errors
        if lowercased.contains("timeout") || lowercased.contains("timed out") {
            return "Operation took too long. Try again or use simpler settings."
        }

        // Return original if no translation matches
        return technicalMessage
    }
}

// MARK: - PythonError Extension

extension PythonError {
    var isRecoverable: Bool {
        switch self {
        case .timeout, .workerNotRunning, .bufferOverflow:
            return true
        case .uvNotFound, .invalidResponse, .predictionFailed, .encodingError, .workerNotReady, .processTerminated:
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
        case .processTerminated:
            return "Restart the application - Python process crashed"
        case .bufferOverflow:
            return "Restart the application - response buffer overflow"
        }
    }
}
