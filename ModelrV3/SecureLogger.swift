import Foundation
import os.log

enum LogLevel: Int, Comparable {
    case debug = 0
    case info = 1
    case warning = 2
    case error = 3

    static func < (lhs: LogLevel, rhs: LogLevel) -> Bool {
        return lhs.rawValue < rhs.rawValue
    }
}

struct LogEntry: Codable {
    let timestamp: Date
    let level: String
    let message: String
    let subsystem: String
    let category: String?
}

class SecureLogger {
    static let shared = SecureLogger()

    private let subsystem = "com.modelr.v3"
    private let queue = DispatchQueue(label: "com.modelr.logger")

    private var minimumLevel: LogLevel {
        #if DEBUG
        return .debug
        #else
        return .info
        #endif
    }

    private var logEntries: [LogEntry] = []
    private let maxEntries = 1000

    private lazy var osLog = OSLog(subsystem: subsystem, category: "App")

    private init() {}

    func debug(_ message: String, category: String? = nil) {
        log(message, level: .debug, category: category)
    }

    func info(_ message: String, category: String? = nil) {
        log(message, level: .info, category: category)
    }

    func warning(_ message: String, category: String? = nil) {
        log(message, level: .warning, category: category)
    }

    func error(_ message: String, category: String? = nil) {
        log(message, level: .error, category: category)
    }

    private func log(_ message: String, level: LogLevel, category: String?) {
        guard level >= minimumLevel else { return }

        let sanitizedMessage = sanitizeMessage(message)
        let timestamp = Date()

        let entry = LogEntry(
            timestamp: timestamp,
            level: levelString(level),
            message: sanitizedMessage,
            subsystem: subsystem,
            category: category
        )

        queue.async {
            self.logEntries.append(entry)
            if self.logEntries.count > self.maxEntries {
                self.logEntries.removeFirst(self.logEntries.count - self.maxEntries)
            }
        }

        switch level {
        case .debug:
            #if DEBUG
            os_log("%{public}@", log: self.osLog, type: .debug, sanitizedMessage)
            #endif
        case .info:
            os_log("%{public}@", log: self.osLog, type: .info, sanitizedMessage)
        case .warning:
            os_log("%{public}@", log: self.osLog, type: .default, "[WARNING] %{public}@", sanitizedMessage)
        case .error:
            os_log("%{public}@", log: self.osLog, type: .error, "[ERROR] %{public}@", sanitizedMessage)
        }
    }

    func logError(_ error: Error, category: String? = nil) {
        let message: String
        if let localizedError = error as? LocalizedError {
            message = localizedError.localizedDescription
        } else {
            message = String(describing: error)
        }

        self.error(message, category: category)

        #if DEBUG
        let debugInfo = """
        Error: \(type(of: error))
        Description: \(message)
        """

        if let nsError = error as NSError? {
            let debugDetails = """
            Code: \(nsError.code)
            Domain: \(nsError.domain)
            UserInfo: \(nsError.userInfo)
            """
            debug(debugDetails, category: category)
        } else {
            debug(debugInfo, category: category)
        }
        #endif
    }

    private func sanitizeMessage(_ message: String) -> String {
        var sanitized = message

        let patterns = [
            (#"(/Users/[^/]+/)"#, "~/"),
            (#"(/[Tt]emp/)"#, "/tmp/"),
            (#"(/private/var/)"#, "/var/"),
            (#"(Bearer [a-zA-Z0-9\-\._~+/]+=*)"#, "Bearer [REDACTED]"),
            (#"(api[_-]?key\s*[:=]\s*[a-zA-Z0-9\-\._~+/]+)"#, "api_key=[REDACTED]"),
            (#"(password\s*[:=]\s*[^\s]+)"#, "password=[REDACTED]"),
            (#"(token\s*[:=]\s*[a-zA-Z0-9\-\._~+/]+)"#, "token=[REDACTED]"),
            (#"(secret\s*[:=]\s*[^\s]+)"#, "secret=[REDACTED]"),
            (#"(/Library/Application Support/)"#, "~/Library/Application Support/")
        ]

        for (pattern, replacement) in patterns {
            let regex = try? NSRegularExpression(pattern: pattern, options: [])
            let range = NSRange(location: 0, length: sanitized.utf16.count)

            sanitized = regex?.stringByReplacingMatches(
                in: sanitized,
                options: [],
                range: range,
                withTemplate: replacement
            ) ?? sanitized
        }

        return sanitized
    }

    private func levelString(_ level: LogLevel) -> String {
        switch level {
        case .debug: return "DEBUG"
        case .info: return "INFO"
        case .warning: return "WARNING"
        case .error: return "ERROR"
        }
    }

    func getRecentEntries(count: Int = 100) -> [LogEntry] {
        return queue.sync {
            let recentCount = min(count, logEntries.count)
            return Array(logEntries.suffix(recentCount))
        }
    }

    func exportLogs() -> String {
        let entries = queue.sync { logEntries }

        var output = "ModelrV3 Logs\n"
        output += "Generated: \(Date())\n"
        output += "Total entries: \(entries.count)\n"
        output += String(repeating: "=", count: 50) + "\n\n"

        let dateFormatter = ISO8601DateFormatter()
        dateFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        for entry in entries {
            let timestamp = dateFormatter.string(from: entry.timestamp)
            let categoryStr = entry.category.map { " [\($0)]" } ?? ""
            output += "[\(timestamp)] [\(entry.level)]\(categoryStr) \(entry.message)\n"
        }

        return output
    }

    func clearLogs() {
        queue.async {
            self.logEntries.removeAll()
        }
    }

    func saveLogsToFile(url: URL) throws {
        let logs = exportLogs()
        let data = logs.data(using: .utf8)!
        
        try data.write(to: url)
    }
}

#if DEBUG
extension SecureLogger {
    func printDebug(_ message: String) {
        self.debug(message)
    }
}
#else
extension SecureLogger {
    func printDebug(_ message: String) {
    }
}
#endif
