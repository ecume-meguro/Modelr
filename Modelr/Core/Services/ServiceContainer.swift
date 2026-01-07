import Foundation

/// Centralized container for application services to ensure single instances
@MainActor
class ServiceContainer {
    static let shared = ServiceContainer()
    
    /// Shared Python environment instance
    let pythonEnvironment: PythonEnvironment
    
    /// Shared generation service instance
    let generationService: GenerationService
    
    private init() {
        let env = PythonEnvironment()
        self.pythonEnvironment = env
        self.generationService = GenerationService(env: env)
    }
}
