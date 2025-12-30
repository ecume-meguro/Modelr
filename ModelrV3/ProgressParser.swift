import Foundation

/// Centralized progress parsing utilities for ModelrV3
enum ProgressParser {
    
    /// Parse progress information from a progress string
    /// - Parameter progressString: The progress string to parse
    /// - Returns: Parsed progress information
    static func parseProgress(_ progressString: String) -> (stage: String, percentComplete: Double, currentStep: Int, totalSteps: Int, speed: Double)? {
        let info = parseDetailedProgress(progressString)
        guard let stage = info.stage else { return nil }
        
        return (
            stage: stage,
            percentComplete: info.percentComplete,
            currentStep: info.currentStep,
            totalSteps: info.totalSteps,
            speed: info.iterationsPerSecond
        )
    }
    
    /// Extract stage name from progress string
    /// - Parameter progressString: The progress string
    /// - Returns: Stage name or nil
    static func extractStage(_ progressString: String) -> String? {
        if progressString.contains("Extracting foreground") {
            return "Extracting Foreground"
        } else if progressString.contains("Loading") {
            return "Loading Model"
        } else if progressString.contains("Diffusion Sampling") {
            return "Diffusion Sampling"
        } else if progressString.contains("Volume Decoding") {
            return "Volume Decoding"
        } else if progressString.contains("Saving") {
            return "Saving Model"
        } else if progressString.contains("Generating 3D shape") {
            return "Generating 3D Shape"
        } else if progressString.contains("Loading Hunyuan3D pipeline") {
            return "Loading Model"
        } else if progressString.contains("download from huggingface") || progressString.contains("Downloading Hunyuan3D model") {
            return "Downloading Hunyuan3D Model"
        }
        return nil
    }
    
    /// Extract percentage from progress string
    /// - Parameter progressString: The progress string
    /// - Returns: Percentage value (0-100) or nil
    static func extractPercentage(_ progressString: String) -> Double? {
        if let match = progressString.range(of: #"(\d+)(?:\.\d+)?%"#, options: .regularExpression) {
            let pctStr = String(progressString[match])
                .replacingOccurrences(of: "%", with: "")
            return Double(pctStr)
        }
        
        if let match = progressString.range(of: #"(\d+)%.*?(\d+)/(\d+)"#, options: .regularExpression) {
            let pctMatch = progressString.range(of: #"\d+%"#, options: .regularExpression)
            if let pctRange = pctMatch {
                let pctStr = String(progressString[pctRange])
                    .replacingOccurrences(of: "%", with: "")
                return Double(pctStr)
            }
        }
        
        return nil
    }
    
    /// Extract step count from progress string
    /// - Parameter progressString: The progress string
    /// - Returns: Tuple of (currentStep, totalSteps) or nil
    static func extractSteps(_ progressString: String) -> (current: Int, total: Int)? {
        if let match = progressString.range(of: #"(\d+)/(\d+)"#, options: .regularExpression) {
            let stepStr = String(progressString[match])
            let parts = stepStr.split(separator: "/")
            if parts.count == 2,
               let current = Int(parts[0]),
               let total = Int(parts[1]) {
                return (current: current, total: total)
            }
        }
        
        if let match = progressString.range(of: #"\|\s*(\d+)/(\d+)"#, options: .regularExpression) {
            let stepPart = String(progressString[match])
            if let numMatch = stepPart.range(of: #"\d+/\d+"#, options: .regularExpression) {
                let numStr = String(stepPart[numMatch])
                let parts = numStr.split(separator: "/")
                if parts.count == 2,
                   let current = Int(parts[0]),
                   let total = Int(parts[1]) {
                    return (current: current, total: total)
                }
            }
        }
        
        return nil
    }
    
    /// Extract speed from progress string
    /// - Parameter progressString: The progress string
    /// - Returns: Speed in iterations per second or nil
    static func extractSpeed(_ progressString: String) -> Double? {
        if let match = progressString.range(of: #"(\d+\.?\d*)\s*it/s"#, options: .regularExpression) {
            let speedStr = String(progressString[match])
            if let numMatch = speedStr.range(of: #"\d+\.?\d*"#, options: .regularExpression) {
                return Double(speedStr[numMatch])
            }
        }
        
        if let sitMatch = progressString.range(of: #"(\d+\.?\d*)\s*s/it"#, options: .regularExpression) {
            let sitStr = String(progressString[sitMatch])
            if let numMatch = sitStr.range(of: #"\d+\.?\d*"#, options: .regularExpression) {
                if let secsPerIt = Double(sitStr[numMatch]), secsPerIt > 0 {
                    return 1.0 / secsPerIt
                }
            }
        }
        
        return nil
    }
    
    /// Parse detailed progress information from a string
    /// - Parameter progressString: The progress string to parse
    /// - Returns: Progress information
    static func parseDetailedProgress(_ progressString: String) -> ProgressInfo {
        var info = ProgressInfo()
        
        if let stage = extractStage(progressString) {
            info.stage = stage
        }
        
        if let percent = extractPercentage(progressString) {
            info.percentComplete = percent
        }
        
        if let steps = extractSteps(progressString) {
            info.currentStep = steps.current
            info.totalSteps = steps.total
        }
        
        if let speed = extractSpeed(progressString) {
            info.iterationsPerSecond = speed
        }
        
        return info
    }
    
    /// Progress information structure
    struct ProgressInfo {
        var stage: String? = nil
        var percentComplete: Double = 0
        var currentStep: Int = 0
        var totalSteps: Int = 0
        var iterationsPerSecond: Double = 0
        
        var isActive: Bool {
            totalSteps > 0
        }
        
        var formattedSpeed: String {
            TimeFormatter.formatSpeed(iterationsPerSecond)
        }
        
        var formattedETA: String {
            if currentStep > 0, totalSteps > 0, iterationsPerSecond > 0 {
                let remaining = Double(totalSteps - currentStep) / iterationsPerSecond
                return TimeFormatter.formatRemainingTime(remaining)
            }
            return ""
        }
    }
}
