import Foundation

/// Manages the initial setup process including Python environment and model downloads
///
/// Directory structure in ~/Library/Application Support/ModelrV3/:
/// ├── modelrv3_core/         # Shared Python module
/// ├── SAM/                   # Segmentation environment
/// ├── Tools/                 # Mesh processing environment
/// └── Hunyuan3D/             # 3D generation environment
@MainActor
class SetupManager: ObservableObject {
    @Published var setupStarted = false
    @Published var isComplete = false
    @Published var currentStage = "Preparing..."
    @Published var detailedStatus = ""
    @Published var overallProgress: Double = 0

    @Published var downloadedSize = "—"
    @Published var elapsedTime = "0:00"

    private var startTime: Date?
    private var monitorTask: Task<Void, Never>?
    private let appSupportDir: URL
    private var selectedModelChoice: SetupModelChoice = .fast
    
    private let env = PythonEnvironment()

    init() {
        let fm = FileManager.default
        let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        appSupportDir = appSupport.appendingPathComponent("ModelrV3")
    }

    func startSetup(modelChoice: SetupModelChoice = .fast) {
        setupStarted = true
        startTime = Date()
        selectedModelChoice = modelChoice

        // Start elapsed time timer
        Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] timer in
            guard let self = self else { timer.invalidate(); return }

            Task { @MainActor in
                if self.isComplete {
                    timer.invalidate()
                    return
                }

                if let start = self.startTime {
                    let elapsed = Date().timeIntervalSince(start)
                    let minutes = Int(elapsed) / 60
                    let seconds = Int(elapsed) % 60
                    self.elapsedTime = String(format: "%d:%02d", minutes, seconds)
                }
            }
        }

        // Start the actual setup
        Task {
            let success = await env.setup(
                modelChoice: modelChoice,
                onProgress: { [weak self] update in
                    Task { @MainActor in
                        self?.currentStage = update.stage.rawValue
                        self?.detailedStatus = update.status
                        self?.updateProgress(status: update.status)
                    }
                }
            )
            
            await MainActor.run {
                self.isComplete = success
                if success {
                    UserDefaults.standard.set(true, forKey: "SetupComplete")
                }
            }
        }
    }
    
    private func updateProgress(status: String) {
        // Approximate progress based on stage text
        if status.contains("Resources") { 
            overallProgress = 0.05 
        } else if status.contains("SAM environment") || status.contains("dependencies") { 
            overallProgress = 0.1 
        } else if status.contains("segmentation model") { 
            overallProgress = 0.4 // Progresses Step 1 (Environment) to Step 2 (Segmentation)
        } else if status.contains("3D generation environment") { 
            overallProgress = 0.6 // Progresses Step 2 (Segmentation) to Step 3 (3D Generation)
        } else if status.contains("3D generation model") { 
            overallProgress = 0.8 
        }
    }
}

