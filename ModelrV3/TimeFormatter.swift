import Foundation

/// Centralized time formatting utilities for ModelrV3
enum TimeFormatter {
    
    /// Format time duration in seconds to a readable string
    /// - Parameter seconds: Time duration in seconds
    /// - Returns: Formatted string like "1:30" or "45s"
    static func formatDuration(_ seconds: TimeInterval) -> String {
        guard seconds >= 0 else { return "0s" }
        
        let minutes = Int(seconds) / 60
        let remainingSeconds = Int(seconds) % 60
        
        if minutes > 0 {
            return String(format: "%d:%02d", minutes, remainingSeconds)
        } else {
            return String(format: "%ds", remainingSeconds)
        }
    }
    
    /// Format elapsed time with label
    /// - Parameter seconds: Elapsed time in seconds
    /// - Returns: Formatted string like "Elapsed: 1:30" or "Elapsed: 45s"
    static func formatElapsedTime(_ seconds: TimeInterval) -> String {
        let duration = formatDuration(seconds)
        return "Elapsed: \(duration)"
    }
    
    /// Format remaining time with label
    /// - Parameter seconds: Estimated remaining time in seconds
    /// - Returns: Formatted string like "1:30 remaining" or "45s remaining"
    static func formatRemainingTime(_ seconds: TimeInterval) -> String {
        guard seconds > 0 else { return "" }
        
        let duration = formatDuration(seconds)
        return "\(duration) remaining"
    }
    
    /// Format iterations per second or seconds per iteration
    /// - Parameter iterationsPerSecond: Speed in iterations per second (0 for unknown)
    /// - Returns: Formatted string like "2.5 it/s" or "0.4 s/it"
    static func formatSpeed(_ iterationsPerSecond: Double) -> String {
        guard iterationsPerSecond > 0 else { return "" }
        
        if iterationsPerSecond >= 1 {
            return String(format: "%.1f it/s", iterationsPerSecond)
        } else {
            let secondsPerIteration = 1.0 / iterationsPerSecond
            return String(format: "%.1f s/it", secondsPerIteration)
        }
    }
    
    /// Calculate estimated time remaining based on progress
    /// - Parameters:
    ///   - currentStep: Current step number
    ///   - totalSteps: Total number of steps
    ///   - elapsedTime: Time elapsed so far in seconds
    /// - Returns: Estimated remaining time in seconds, or nil if cannot calculate
    static func calculateETA(currentStep: Int, totalSteps: Int, elapsedTime: TimeInterval) -> TimeInterval? {
        guard totalSteps > 0, currentStep > 0, elapsedTime > 0 else { return nil }
        guard currentStep <= totalSteps else { return 0 }
        
        let averageTimePerStep = elapsedTime / Double(currentStep)
        let remainingSteps = totalSteps - currentStep
        
        return averageTimePerStep * Double(remainingSteps)
    }
    
    /// Calculate iterations per second
    /// - Parameters:
    ///   - currentStep: Current step number
    ///   - elapsedTime: Time elapsed in seconds
    /// - Returns: Iterations per second, or nil if cannot calculate
    static func calculateIterationsPerSecond(currentStep: Int, elapsedTime: TimeInterval) -> Double? {
        guard currentStep > 0, elapsedTime > 0 else { return nil }
        return Double(currentStep) / elapsedTime
    }
}
