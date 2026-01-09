import SwiftUI

// NOTE: Safe subscript for Array is defined in CoreExtensions.swift
// Do not duplicate here to avoid ambiguous subscript errors

// MARK: - Standard Animations

extension View {
    /// Apply standard spring animation for step transitions
    func withStandardSpring<V: Equatable>(value: V) -> some View {
        self.animation(
            .spring(
                response: AppConstants.standardSpringResponse,
                dampingFraction: AppConstants.standardSpringDamping
            ),
            value: value
        )
    }

    /// Apply fast spring animation for quick interactions
    func withFastSpring<V: Equatable>(value: V) -> some View {
        self.animation(
            .spring(
                response: AppConstants.fastSpringResponse,
                dampingFraction: AppConstants.fastSpringDamping
            ),
            value: value
        )
    }
}

/// Execute a closure with standard spring animation
@discardableResult
func withStandardSpring<Result>(_ body: () throws -> Result) rethrows -> Result {
    try withAnimation(.spring(
        response: AppConstants.standardSpringResponse,
        dampingFraction: AppConstants.standardSpringDamping
    )) {
        try body()
    }
}

/// Execute a void closure with standard spring animation
func withStandardSpring(_ body: () -> Void) {
    withAnimation(.spring(
        response: AppConstants.standardSpringResponse,
        dampingFraction: AppConstants.standardSpringDamping
    )) {
        body()
    }
}

/// Execute a closure with fast spring animation
@discardableResult
func withFastSpring<Result>(_ body: () throws -> Result) rethrows -> Result {
    try withAnimation(.spring(
        response: AppConstants.fastSpringResponse,
        dampingFraction: AppConstants.fastSpringDamping
    )) {
        try body()
    }
}

/// Execute a void closure with fast spring animation
func withFastSpring(_ body: () -> Void) {
    withAnimation(.spring(
        response: AppConstants.fastSpringResponse,
        dampingFraction: AppConstants.fastSpringDamping
    )) {
        body()
    }
}

// MARK: - Cancellable Task Management

/// A wrapper for managing cancellable async tasks with proper cleanup
@MainActor
final class CancellableTask<T> {
    private var task: Task<T, Never>?

    /// Cancel the current task if any
    func cancel() {
        task?.cancel()
        task = nil
    }

    /// Start a new task, cancelling any existing one
    func start(_ operation: @escaping @Sendable () async -> T) {
        cancel()
        task = Task {
            await operation()
        }
    }

    /// Start a new task with weak self capture pattern
    func start<Owner: AnyObject>(
        owner: Owner,
        operation: @escaping (Owner) async -> T
    ) {
        cancel()
        task = Task { [weak owner] in
            guard let owner = owner else {
                // Return a default value - caller should handle this case
                fatalError("Owner deallocated before task could run")
            }
            return await operation(owner)
        }
    }

    /// Check if a task is currently running
    var isRunning: Bool {
        task != nil && task?.isCancelled == false
    }

    deinit {
        task?.cancel()
    }
}

// MARK: - Dictionary Extensions

extension Dictionary {
    /// Safely access or initialize a value for a key
    mutating func getOrCreate(_ key: Key, default defaultValue: @autoclosure () -> Value) -> Value {
        if let existing = self[key] {
            return existing
        }
        let newValue = defaultValue()
        self[key] = newValue
        return newValue
    }
}

// MARK: - String Extensions

extension String {
    /// Truncate string to a maximum length with ellipsis
    func truncated(to maxLength: Int) -> String {
        if count <= maxLength {
            return self
        }
        return String(prefix(maxLength - 3)) + "..."
    }
}

// MARK: - Optional Extensions

extension Optional where Wrapped: Collection {
    /// Returns true if the optional is nil or the collection is empty
    var isNilOrEmpty: Bool {
        self?.isEmpty ?? true
    }
}

// MARK: - FileManager Extensions

extension FileManager {
    /// Check if a file exists at the given URL and return it, or throw an error
    func ensureFileExists(at url: URL) throws -> URL {
        guard fileExists(atPath: url.path) else {
            throw NSError(
                domain: "FileManager",
                code: NSFileNoSuchFileError,
                userInfo: [NSLocalizedDescriptionKey: "File not found: \(url.path)"]
            )
        }
        return url
    }

    /// Check if a directory exists at the given URL, creating it if needed
    func ensureDirectoryExists(at url: URL) throws {
        if !fileExists(atPath: url.path) {
            try createDirectory(at: url, withIntermediateDirectories: true)
        }
    }
}
