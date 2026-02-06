import Foundation
import os.log

/// Centralized error reporting and logging
/// Replaces scattered print statements with structured error handling
enum ErrorReporter {

    /// Log levels for error reporting
    enum Level: String {
        case debug = "DEBUG"
        case info = "INFO"
        case warning = "WARNING"
        case error = "ERROR"
        case critical = "CRITICAL"
    }

    /// Subsystem categories for log organization
    enum Subsystem: String {
        case setup = "Setup"
        case segmentation = "Segmentation"
        case generation = "Generation"
        case postProcess = "PostProcess"
        case modify = "Modify"
        case python = "Python"
        case network = "Network"
        case fileSystem = "FileSystem"
        case ui = "UI"
        case general = "General"
    }

    // MARK: - Logging

    /// Log a message with subsystem and level
    static func log(
        _ message: String,
        subsystem: Subsystem = .general,
        level: Level = .info,
        file: String = #file,
        function: String = #function,
        line: Int = #line
    ) {
        let filename = (file as NSString).lastPathComponent
        let prefix = "[\(subsystem.rawValue)][\(level.rawValue)]"
        print("\(prefix) \(message)")

        #if DEBUG
        if level == .error || level == .critical {
            print("  at \(filename):\(line) in \(function)")
        }
        #endif
    }

    /// Log an error with optional context
    static func logError(
        _ error: Error,
        subsystem: Subsystem = .general,
        context: String? = nil,
        file: String = #file,
        function: String = #function,
        line: Int = #line
    ) {
        var message = error.localizedDescription
        if let ctx = context {
            message = "\(ctx): \(message)"
        }
        log(message, subsystem: subsystem, level: .error, file: file, function: function, line: line)
    }

    // MARK: - Convenience Methods

    /// Log a debug message
    static func debug(_ message: String, subsystem: Subsystem = .general) {
        log(message, subsystem: subsystem, level: .debug)
    }

    /// Log an info message
    static func info(_ message: String, subsystem: Subsystem = .general) {
        log(message, subsystem: subsystem, level: .info)
    }

    /// Log a warning
    static func warning(_ message: String, subsystem: Subsystem = .general) {
        log(message, subsystem: subsystem, level: .warning)
    }

    /// Log an error message
    static func error(_ message: String, subsystem: Subsystem = .general) {
        log(message, subsystem: subsystem, level: .error)
    }

    /// Log a critical error
    static func critical(_ message: String, subsystem: Subsystem = .general) {
        log(message, subsystem: subsystem, level: .critical)
    }

    // MARK: - Process Errors

    /// Report a Python process error
    static func pythonError(_ message: String, processName: String? = nil) {
        let ctx = processName.map { "[\($0)]" } ?? ""
        error("\(ctx) \(message)", subsystem: .python)
    }

    /// Report a network error
    static func networkError(_ error: Error, operation: String) {
        logError(error, subsystem: .network, context: operation)
    }

    /// Report a file system error
    static func fileError(_ error: Error, path: String) {
        logError(error, subsystem: .fileSystem, context: "Path: \(path)")
    }
}
