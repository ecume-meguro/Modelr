import Foundation
import os.log

/// Centralized logging system using OSLog for better performance and filtering
enum Log {
    // MARK: - Log Categories
    private static let subsystem = Bundle.main.bundleIdentifier ?? "com.modelr"

    static let general = Logger(subsystem: subsystem, category: "General")
    static let setup = Logger(subsystem: subsystem, category: "Setup")
    static let generation = Logger(subsystem: subsystem, category: "Generation")
    static let segmentation = Logger(subsystem: subsystem, category: "Segmentation")
    static let python = Logger(subsystem: subsystem, category: "Python")
    static let model = Logger(subsystem: subsystem, category: "Model")
    static let vlm = Logger(subsystem: subsystem, category: "VLM")
    static let ui = Logger(subsystem: subsystem, category: "UI")
    static let project = Logger(subsystem: subsystem, category: "Project")
    static let memory = Logger(subsystem: subsystem, category: "Memory")
    static let download = Logger(subsystem: subsystem, category: "Download")
    static let postProcess = Logger(subsystem: subsystem, category: "PostProcess")
}

// MARK: - Convenience Extensions

extension Logger {
    /// Log with automatic function/line info for debugging
    func trace(_ message: String, function: String = #function, line: Int = #line) {
        self.debug("[\(function):\(line)] \(message)")
    }
}
