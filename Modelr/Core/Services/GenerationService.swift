import Foundation
import SwiftUI
import Combine

/// Status of the generation process
enum GenerationStatus: Equatable {
    case idle
    case preparing
    case inProgress(stage: String, percent: Double)
    case completed(URL)
    case failed(String)
}

/// Centralized service for 3D model generation
@MainActor
class GenerationService: ObservableObject {
    @Published var status: GenerationStatus = .idle
    @Published var startTime: Date?
    @Published var duration: TimeInterval?
    @Published var previewImage: NSImage?  // Real-time preview during volume decoding

    private let env: PythonEnvironment
    
    init(env: PythonEnvironment = PythonEnvironment()) {
        self.env = env
    }
    
    func generate(
        imagePath: String,
        maskPath: String,
        steps: Int,
        resolution: Int,
        modelVariant: String = "std"
    ) async {
        status = .preparing
        startTime = Date()
        duration = nil
        previewImage = nil  // Clear any previous preview

        await env.generate3DModel(
            imagePath: imagePath,
            maskPath: maskPath,
            steps: steps,
            resolution: resolution,
            modelVariant: modelVariant,
            progress: { [weak self] progressString in
                Task { @MainActor in
                    self?.handleProgressUpdate(progressString)
                }
            },
            preview: { [weak self] imageData in
                // Update preview image from PNG data
                Task { @MainActor in
                    if let image = NSImage(data: imageData) {
                        self?.previewImage = image
                    }
                }
            },
            completion: { [weak self] result in
                Task { @MainActor in
                    self?.handleCompletion(result)
                }
            }
        )
    }
    
    func cancel() {
        env.cancelGeneration()
        status = .idle
    }
    
    private func handleProgressUpdate(_ progressString: String) {
        print("[GenerationService] Received: \(progressString)")
        if let parsed = ProgressParser.parseProgress(progressString) {
            // Include step numbers in the stage display (e.g., "Diffusion Sampling (5/25)")
            var displayStage = parsed.stage
            if parsed.currentStep > 0 && parsed.totalSteps > 0 {
                displayStage = "\(parsed.stage) (\(parsed.currentStep)/\(parsed.totalSteps))"
            }
            let pct = parsed.percentComplete / 100.0
            print("[GenerationService] Parsed: stage=\(displayStage) percent=\(pct) steps=\(parsed.currentStep)/\(parsed.totalSteps)")
            status = .inProgress(stage: displayStage, percent: pct)
        } else if let stage = ProgressParser.extractStage(progressString) {
            // Try to extract steps even without full progress parse
            if let steps = ProgressParser.extractSteps(progressString) {
                let displayStage = "\(stage) (\(steps.current)/\(steps.total))"
                let percent = Double(steps.current) / Double(steps.total) * 100.0
                status = .inProgress(stage: displayStage, percent: percent / 100.0)
            } else {
                status = .inProgress(stage: stage, percent: 0)
            }
        } else {
            // Fallback for simple status messages
            status = .inProgress(stage: progressString, percent: 0)
        }
    }
    
    private func handleCompletion(_ result: Result<URL, Error>) {
        if let start = startTime {
            duration = Date().timeIntervalSince(start)
        }
        
        switch result {
        case .success(let url):
            status = .completed(url)
        case .failure(let error):
            status = .failed(error.localizedDescription)
        }
    }
}
