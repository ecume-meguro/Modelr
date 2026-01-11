import Foundation
import SwiftUI
import Combine
import os.log

/// Status of the generation process - now scoped by projectId to prevent cross-talk
enum GenerationStatus: Equatable {
    case idle
    case preparing(projectId: UUID)
    case inProgress(projectId: UUID, stage: String, percent: Double)
    case completed(projectId: UUID, url: URL)
    case failed(projectId: UUID, error: String)

    /// Extract projectId if present (for filtering)
    var projectId: UUID? {
        switch self {
        case .idle: return nil
        case .preparing(let id): return id
        case .inProgress(let id, _, _): return id
        case .completed(let id, _): return id
        case .failed(let id, _): return id
        }
    }
}

/// Centralized service for 3D model generation
@MainActor
class GenerationService: ObservableObject {
    @Published var status: GenerationStatus = .idle
    @Published var startTime: Date?
    @Published var duration: TimeInterval?
    
    private let env: PythonEnvironment
    
    init(env: PythonEnvironment = PythonEnvironment()) {
        self.env = env
    }
    
    func generate(
        projectId: UUID,
        imagePath: String,
        maskPath: String,
        steps: Int,
        resolution: Int,
        modelVariant: String = "std",
        guidanceScale: Double = 5.0,
        boxV: Double = 1.01,
        mcLevel: Double = 0.0
    ) async {
        status = .preparing(projectId: projectId)
        startTime = Date()
        duration = nil

        await env.generate3DModel(
            imagePath: imagePath,
            maskPath: maskPath,
            steps: steps,
            resolution: resolution,
            modelVariant: modelVariant,
            guidanceScale: guidanceScale,
            boxV: boxV,
            mcLevel: mcLevel,
            progress: { [weak self, projectId] progressString in
                Task { @MainActor in
                    self?.handleProgressUpdate(progressString, projectId: projectId)
                }
            },
            completion: { [weak self, projectId] result in
                Task { @MainActor in
                    self?.handleCompletion(result, projectId: projectId)
                }
            }
        )
    }
    
    func cancel() {
        env.cancelGeneration()
        status = .idle
    }
    
    private func handleProgressUpdate(_ progressString: String, projectId: UUID) {
        print("[GenerationService] Received for project \(projectId.uuidString.prefix(8)): \(progressString)")
        if let parsed = ProgressParser.parseProgress(progressString) {
            // Include step numbers in the stage display (e.g., "Diffusion Sampling (5/25)")
            var displayStage = parsed.stage
            if parsed.currentStep > 0 && parsed.totalSteps > 0 {
                displayStage = "\(parsed.stage) (\(parsed.currentStep)/\(parsed.totalSteps))"
            }
            let pct = parsed.percentComplete / 100.0
            print("[GenerationService] Parsed: stage=\(displayStage) percent=\(pct) steps=\(parsed.currentStep)/\(parsed.totalSteps)")
            status = .inProgress(projectId: projectId, stage: displayStage, percent: pct)
        } else if let stage = ProgressParser.extractStage(progressString) {
            // Try to extract steps even without full progress parse
            if let steps = ProgressParser.extractSteps(progressString) {
                let displayStage = "\(stage) (\(steps.current)/\(steps.total))"
                let percent = Double(steps.current) / Double(steps.total) * 100.0
                status = .inProgress(projectId: projectId, stage: displayStage, percent: percent / 100.0)
            } else {
                status = .inProgress(projectId: projectId, stage: stage, percent: 0)
            }
        } else {
            // Fallback for simple status messages
            status = .inProgress(projectId: projectId, stage: progressString, percent: 0)
        }
    }

    private func handleCompletion(_ result: Result<URL, Error>, projectId: UUID) {
        if let start = startTime {
            duration = Date().timeIntervalSince(start)
        }

        switch result {
        case .success(let url):
            status = .completed(projectId: projectId, url: url)
        case .failure(let error):
            status = .failed(projectId: projectId, error: error.localizedDescription)
        }
    }
}
