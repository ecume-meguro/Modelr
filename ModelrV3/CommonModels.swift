import SwiftUI

enum SidebarTab: String, CaseIterable {
    case preprocess = "Preprocess"
    case segment = "Segment"
    case generate = "Generate"
}

struct GenerationProgress: Equatable {
    var stage: String = ""
    var currentStep: Int = 0
    var totalSteps: Int = 0
    var iterationsPerSecond: Double = 0
    var elapsedTime: TimeInterval = 0
    var estimatedRemaining: TimeInterval = 0

    var isActive: Bool { totalSteps > 0 }

    var percentComplete: Double {
        guard totalSteps > 0 else { return 0 }
        return Double(currentStep) / Double(totalSteps) * 100
    }

    var formattedSpeed: String {
        if iterationsPerSecond >= 1 {
            return String(format: "%.1f it/s", iterationsPerSecond)
        } else if iterationsPerSecond > 0 {
            return String(format: "%.1f s/it", 1.0 / iterationsPerSecond)
        }
        return ""
    }

    var formattedETA: String {
        guard estimatedRemaining > 0 else { return "" }
        let minutes = Int(estimatedRemaining) / 60
        let seconds = Int(estimatedRemaining) % 60
        if minutes > 0 {
            return String(format: "%d:%02d remaining", minutes, seconds)
        } else {
            return String(format: "%ds remaining", seconds)
        }
    }

    var formattedElapsed: String {
        let minutes = Int(elapsedTime) / 60
        let seconds = Int(elapsedTime) % 60
        if minutes > 0 {
            return String(format: "%d:%02d elapsed", minutes, seconds)
        } else {
            return String(format: "%ds elapsed", seconds)
        }
    }
}

enum UndoAction: Equatable {
    case addPoint(SAMPoint)
    case addBox(SAMBox)
    case addLasso(LassoSelection)
    case addPaintStroke(PaintStroke)
    case crop(originalImage: NSImage, originalPath: String?)
}
