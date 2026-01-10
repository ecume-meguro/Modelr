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

    /// Apply snappy spring for micro-interactions (checkmarks, toggles)
    func withSnappySpring<V: Equatable>(value: V) -> some View {
        self.animation(
            .spring(response: 0.22, dampingFraction: 0.72),
            value: value
        )
    }

    /// Apply gentle spring for larger content transitions
    func withGentleSpring<V: Equatable>(value: V) -> some View {
        self.animation(
            .spring(response: 0.28, dampingFraction: 0.82),
            value: value
        )
    }

    /// Apply quick ease-out for fade transitions
    func withQuickFade<V: Equatable>(value: V) -> some View {
        self.animation(.easeOut(duration: 0.18), value: value)
    }

    /// Apply subtle ease-in-out for state changes
    func withSubtleTransition<V: Equatable>(value: V) -> some View {
        self.animation(.easeInOut(duration: 0.2), value: value)
    }
}

// MARK: - Standard Transitions

extension AnyTransition {
    /// Standard content insertion transition
    static var contentInsertion: AnyTransition {
        .asymmetric(
            insertion: .opacity.combined(with: .scale(scale: 0.98, anchor: .top))
                .animation(.spring(response: 0.25, dampingFraction: 0.85)),
            removal: .opacity.animation(.easeOut(duration: 0.12))
        )
    }

    /// Quick fade transition for overlays
    static var quickFade: AnyTransition {
        .opacity.animation(.easeOut(duration: 0.15))
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
    /// If the owner is deallocated before the task runs, the task is cancelled silently
    func start<Owner: AnyObject>(
        owner: Owner,
        operation: @escaping (Owner) async -> T?
    ) where T == Optional<Any> {
        cancel()
        task = Task { [weak owner] in
            guard let owner = owner else {
                // Owner deallocated - return nil instead of crashing
                return nil
            }
            return await operation(owner)
        }
    }

    /// Start a new task with weak self capture pattern (non-optional return)
    /// If the owner is deallocated before the task runs, the task completes with no effect
    func start<Owner: AnyObject>(
        owner: Owner,
        operation: @escaping (Owner) async -> Void
    ) where T == Void {
        cancel()
        task = Task { [weak owner] in
            guard let owner = owner else {
                // Owner deallocated - silently complete
                return
            }
            await operation(owner)
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
