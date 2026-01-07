import Foundation

/// Centralized progress parsing utilities for Modelr
enum ProgressParser {

    /// Parse HuggingFace/tqdm byte progress like `3.82G/3.82G` (and optional speed like `25.8MB/s`).
    /// Returns nil if the string doesn't look like a byte progress line.
    static func parseHuggingFaceByteProgress(_ progressString: String) -> (downloadedBytes: Int64, totalBytes: Int64, speedBytesPerSecond: Double?)? {
        // Examples seen in logs:
        // - "config.yaml: 1.63kB [00:00, 1.86MB/s]"
        // - "...:  65%|...| 2.49G/3.82G [.., 25.8MB/s]"

        // Require a unit so we don't accidentally parse step counts like "1/2".
        let pairPattern = #"(\d+(?:\.\d+)?)(?:\s*)(KiB|MiB|GiB|TiB|kB|MB|GB|TB|B|[kKmMgGtT])\s*/\s*(\d+(?:\.\d+)?)(?:\s*)(KiB|MiB|GiB|TiB|kB|MB|GB|TB|B|[kKmMgGtT])"#
        guard
            let pairRegex = try? NSRegularExpression(pattern: pairPattern, options: []),
            let match = pairRegex.firstMatch(in: progressString, options: [], range: NSRange(progressString.startIndex..<progressString.endIndex, in: progressString))
        else {
            // Also support single-file lines that only show size (no `/total`).
            // We intentionally *don't* infer totals from these.
            return nil
        }

        func group(_ idx: Int) -> String? {
            guard idx < match.numberOfRanges else { return nil }
            let range = match.range(at: idx)
            guard range.location != NSNotFound, let swiftRange = Range(range, in: progressString) else { return nil }
            return String(progressString[swiftRange])
        }

        guard
            let downloadedValue = group(1),
            let downloadedUnit = group(2),
            let totalValue = group(3),
            let totalUnit = group(4),
            let downloaded = parseHumanBytes(value: downloadedValue, unit: downloadedUnit),
            let total = parseHumanBytes(value: totalValue, unit: totalUnit)
        else {
            return nil
        }

        let speedBytesPerSecond = parseSpeedBytesPerSecond(progressString)
        return (downloadedBytes: Int64(downloaded), totalBytes: Int64(total), speedBytesPerSecond: speedBytesPerSecond)
    }

    private static func parseSpeedBytesPerSecond(_ s: String) -> Double? {
        // Example: "25.8MB/s"
        let speedPattern = #"(\d+(?:\.\d+)?)(?:\s*)(KiB|MiB|GiB|TiB|kB|MB|GB|TB|B|[kKmMgGtT])\s*/s"#
        guard let regex = try? NSRegularExpression(pattern: speedPattern, options: []),
              let match = regex.firstMatch(in: s, options: [], range: NSRange(s.startIndex..<s.endIndex, in: s))
        else { return nil }

        func group(_ idx: Int) -> String? {
            guard idx < match.numberOfRanges else { return nil }
            let range = match.range(at: idx)
            guard range.location != NSNotFound, let swiftRange = Range(range, in: s) else { return nil }
            return String(s[swiftRange])
        }

        guard let value = group(1), let unit = group(2) else { return nil }
        return parseHumanBytes(value: value, unit: unit)
    }

    private static func parseHumanBytes(value: String, unit: String) -> Double? {
        guard let numeric = Double(value) else { return nil }

        // Use decimal multipliers to align with most progress bars/ByteCountFormatter(.file).
        switch unit {
        case "B":
            return numeric
        case "k", "K", "kB":
            return numeric * 1_000
        case "M", "MB":
            return numeric * 1_000_000
        case "G", "GB":
            return numeric * 1_000_000_000
        case "T", "TB":
            return numeric * 1_000_000_000_000
        case "KiB":
            return numeric * 1_024
        case "MiB":
            return numeric * 1_048_576
        case "GiB":
            return numeric * 1_073_741_824
        case "TiB":
            return numeric * 1_099_511_627_776
        default:
            return nil
        }
    }
    
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
        if progressString.contains("Extracting foreground") || progressString.contains("Applying mask") {
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
            return "Generating 3D shape"
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
        // Handle PROGRESS:20% pattern
        if let match = progressString.range(of: #"PROGRESS:(\d+)(?:\.\d+)?%"#, options: .regularExpression) {
            let pctMatch = progressString[match].range(of: #"(\d+)(?:\.\d+)?"#, options: .regularExpression)!
            return Double(progressString[match][pctMatch])
        }
        
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
