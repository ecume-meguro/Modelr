import SwiftUI

/// First-run setup view with slideshow and progress tracking
struct SetupView: View {
    @StateObject private var setupManager = SetupManager()
    @Binding var isSetupComplete: Bool

    var body: some View {
        ZStack {
            // Background gradient
            LinearGradient(
                colors: [
                    Color(red: 0.05, green: 0.05, blue: 0.1),
                    Color(red: 0.1, green: 0.08, blue: 0.15)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            if !setupManager.setupStarted {
                welcomeView
            } else {
                setupProgressView
            }
        }
        .frame(minWidth: 700, minHeight: 550)
    }

    // MARK: - Welcome View

    private var welcomeView: some View {
        VStack(spacing: 32) {
            Spacer()

            // App icon/logo
            ZStack {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [.blue, .purple],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 100, height: 100)

                Image(systemName: "cube.transparent.fill")
                    .font(.system(size: 50))
                    .foregroundColor(.white)
            }

            // Title
            VStack(spacing: 8) {
                Text("Welcome to Modelr")
                    .font(.system(size: 36, weight: .bold, design: .rounded))
                    .foregroundColor(.white)

                Text("Transform 2D images into 3D models")
                    .font(.title3)
                    .foregroundColor(.white.opacity(0.7))
            }

            // Features list
            VStack(alignment: .leading, spacing: 16) {
                FeatureRow(icon: "wand.and.stars", title: "AI-Powered Segmentation", description: "Automatically extract objects from images")
                FeatureRow(icon: "paintbrush.pointed", title: "Precision Touchup", description: "Refine masks with intuitive brush tools")
                FeatureRow(icon: "cube", title: "3D Generation", description: "Convert to high-quality 3D models")
            }
            .padding(.vertical, 24)

            Spacer()

            // Setup info
            VStack(spacing: 8) {
                Text("First-time setup will download AI models (~4 GB)")
                    .font(.caption)
                    .foregroundColor(.white.opacity(0.5))

                Text("Files will be stored in ~/Library/Application Support/ModelrV3")
                    .font(.caption)
                    .foregroundColor(.white.opacity(0.4))
            }

            // Get Started button
            Button(action: { setupManager.startSetup() }) {
                HStack(spacing: 8) {
                    Text("Get Started")
                        .font(.headline)
                    Image(systemName: "arrow.right")
                }
                .foregroundColor(.white)
                .padding(.horizontal, 32)
                .padding(.vertical, 14)
                .background(
                    LinearGradient(
                        colors: [.blue, .purple],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
                .cornerRadius(12)
            }
            .buttonStyle(.plain)
            .padding(.bottom, 40)
        }
        .padding(.horizontal, 60)
    }

    // MARK: - Setup Progress View

    private var setupProgressView: some View {
        VStack(spacing: 0) {
            // Top: Slideshow
            SlideshowView()
                .frame(maxHeight: .infinity)

            Divider()
                .background(Color.white.opacity(0.2))

            // Bottom: Progress
            setupProgressPanel
                .frame(height: 200)
                .background(Color.black.opacity(0.3))
        }
        .onChange(of: setupManager.isComplete) { _, complete in
            if complete {
                // Small delay before transitioning
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                    withAnimation {
                        isSetupComplete = true
                    }
                }
            }
        }
    }

    private var setupProgressPanel: some View {
        VStack(spacing: 16) {
            // Current stage
            HStack {
                if setupManager.isComplete {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)
                        .font(.title2)
                } else {
                    ProgressView()
                        .scaleEffect(0.8)
                }

                Text(setupManager.currentStage)
                    .font(.headline)
                    .foregroundColor(.white)

                Spacer()
            }

            // Progress bar
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.white.opacity(0.1))
                        .frame(height: 8)

                    RoundedRectangle(cornerRadius: 4)
                        .fill(
                            LinearGradient(
                                colors: [.blue, .purple],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(width: geo.size.width * setupManager.overallProgress, height: 8)
                        .animation(.easeInOut(duration: 0.3), value: setupManager.overallProgress)
                }
            }
            .frame(height: 8)

            // Stats grid
            HStack(spacing: 32) {
                StatItem(title: "Downloaded", value: setupManager.downloadedSize)
                StatItem(title: "Speed", value: setupManager.downloadSpeed)
                StatItem(title: "Elapsed", value: setupManager.elapsedTime)
                if !setupManager.isComplete {
                    StatItem(title: "Remaining", value: setupManager.estimatedRemaining)
                }
            }

            // Detailed status
            Text(setupManager.detailedStatus)
                .font(.caption)
                .foregroundColor(.white.opacity(0.5))
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(24)
    }
}

// MARK: - Feature Row

struct FeatureRow: View {
    let icon: String
    let title: String
    let description: String

    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundColor(.blue)
                .frame(width: 32)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(.white)
                Text(description)
                    .font(.caption)
                    .foregroundColor(.white.opacity(0.6))
            }
        }
    }
}

// MARK: - Stat Item

struct StatItem: View {
    let title: String
    let value: String

    var body: some View {
        VStack(spacing: 4) {
            Text(value)
                .font(.system(.body, design: .monospaced))
                .fontWeight(.medium)
                .foregroundColor(.white)
            Text(title)
                .font(.caption2)
                .foregroundColor(.white.opacity(0.5))
        }
    }
}

// MARK: - Slideshow View

struct SlideshowView: View {
    @State private var currentSlide = 0
    private let timer = Timer.publish(every: 5, on: .main, in: .common).autoconnect()

    private let slides: [SlideContent] = [
        SlideContent(
            title: "1. Load Your Image",
            description: "Drag and drop any image, or click to browse. Modelr supports PNG, JPEG, and other common formats.",
            icon: "photo.on.rectangle",
            gradient: [.blue, .cyan]
        ),
        SlideContent(
            title: "2. Segment the Object",
            description: "Type what you're looking for, or right-click directly on the object. Our AI will identify and highlight it.",
            icon: "wand.and.stars",
            gradient: [.purple, .pink]
        ),
        SlideContent(
            title: "3. Refine the Mask",
            description: "Use the brush tools to add or remove areas. Zoom in for precision work on fine details.",
            icon: "paintbrush.pointed.fill",
            gradient: [.orange, .red]
        ),
        SlideContent(
            title: "4. Generate 3D Model",
            description: "Choose your quality preset and generate. The AI transforms your 2D selection into a full 3D model.",
            icon: "cube.fill",
            gradient: [.green, .mint]
        ),
        SlideContent(
            title: "5. Export & Use",
            description: "Your 3D model is saved as a GLB file, ready for use in games, AR apps, or 3D printing.",
            icon: "square.and.arrow.up",
            gradient: [.indigo, .purple]
        )
    ]

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            // Slide content
            let slide = slides[currentSlide]

            ZStack {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: slide.gradient,
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 80, height: 80)

                Image(systemName: slide.icon)
                    .font(.system(size: 36))
                    .foregroundColor(.white)
            }

            VStack(spacing: 12) {
                Text(slide.title)
                    .font(.title2.weight(.bold))
                    .foregroundColor(.white)

                Text(slide.description)
                    .font(.body)
                    .foregroundColor(.white.opacity(0.7))
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 500)
            }

            Spacer()

            // Slide indicators
            HStack(spacing: 8) {
                ForEach(0..<slides.count, id: \.self) { index in
                    Circle()
                        .fill(index == currentSlide ? Color.white : Color.white.opacity(0.3))
                        .frame(width: 8, height: 8)
                        .onTapGesture {
                            withAnimation { currentSlide = index }
                        }
                }
            }
            .padding(.bottom, 16)
        }
        .padding(.horizontal, 40)
        .onReceive(timer) { _ in
            withAnimation {
                currentSlide = (currentSlide + 1) % slides.count
            }
        }
    }
}

struct SlideContent {
    let title: String
    let description: String
    let icon: String
    let gradient: [Color]
}

// MARK: - Setup Manager

@MainActor
class SetupManager: ObservableObject {
    @Published var setupStarted = false
    @Published var isComplete = false
    @Published var currentStage = "Preparing..."
    @Published var detailedStatus = ""
    @Published var overallProgress: Double = 0

    @Published var downloadedSize = "0 MB"
    @Published var downloadSpeed = "-- MB/s"
    @Published var elapsedTime = "0:00"
    @Published var estimatedRemaining = "Calculating..."

    private var startTime: Date?
    private var monitorTask: Task<Void, Never>?
    private let appSupportDir: URL

    init() {
        let fm = FileManager.default
        let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        appSupportDir = appSupport.appendingPathComponent("ModelrV3")
    }

    func startSetup() {
        setupStarted = true
        startTime = Date()

        // Start elapsed time timer
        Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] timer in
            guard let self = self else { timer.invalidate(); return }
            if self.isComplete { timer.invalidate(); return }

            if let start = self.startTime {
                let elapsed = Date().timeIntervalSince(start)
                let minutes = Int(elapsed) / 60
                let seconds = Int(elapsed) % 60
                Task { @MainActor in
                    self.elapsedTime = String(format: "%d:%02d", minutes, seconds)
                }
            }
        }

        // Start the actual setup
        Task {
            await runSetup()
        }
    }

    private func runSetup() async {
        let fm = FileManager.default

        // Create directory
        try? fm.createDirectory(at: appSupportDir, withIntermediateDirectories: true)

        // Stage 1: Copy resources
        currentStage = "Copying resources..."
        overallProgress = 0.05
        await copyResources()

        // Stage 2: Setup Python environment
        currentStage = "Setting up Python environment..."
        overallProgress = 0.1
        startMonitoring(prefix: "Python environment")
        await setupPythonEnvironment()

        // Stage 3: Download SAM model
        currentStage = "Downloading segmentation model..."
        overallProgress = 0.3
        startMonitoring(prefix: "SAM model")
        await downloadSAMModel()

        // Stage 4: Setup Hunyuan environment
        currentStage = "Setting up 3D generation environment..."
        overallProgress = 0.5
        startMonitoring(prefix: "Hunyuan environment")
        await setupHunyuanEnvironment()

        // Stage 5: Download Hunyuan model
        currentStage = "Downloading 3D generation model..."
        overallProgress = 0.7
        startMonitoring(prefix: "Hunyuan model")
        await downloadHunyuanModel()

        // Complete
        stopMonitoring()
        overallProgress = 1.0
        currentStage = "Setup Complete!"
        detailedStatus = "All models downloaded and ready to use"
        isComplete = true

        // Mark setup as complete in UserDefaults
        UserDefaults.standard.set(true, forKey: "SetupComplete")
    }

    private func copyResources() async {
        let resources = ["sam_wrapper.py", "pyproject.toml"]

        for (index, res) in resources.enumerated() {
            detailedStatus = "Copying \(res)..."

            let targetPath = appSupportDir.appendingPathComponent(res)
            if let sourcePath = Bundle.main.path(forResource: res, ofType: nil) ??
                                Bundle.main.path(forResource: res, ofType: nil, inDirectory: "Resources") {
                try? FileManager.default.removeItem(at: targetPath)
                try? FileManager.default.copyItem(at: URL(fileURLWithPath: sourcePath), to: targetPath)
            }

            overallProgress = 0.05 + (0.05 * Double(index + 1) / Double(resources.count))
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
    }

    private func setupPythonEnvironment() async {
        guard let uvPath = Bundle.main.path(forResource: "uv", ofType: nil) ??
                          Bundle.main.path(forResource: "uv", ofType: nil, inDirectory: "Resources") else {
            detailedStatus = "Error: uv not found in bundle"
            return
        }

        detailedStatus = "Installing Python 3.13 and dependencies..."

        let venvDir = appSupportDir.appendingPathComponent(".venv")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: uvPath)
        process.arguments = ["sync", "--python", "3.13"]
        process.currentDirectoryURL = appSupportDir
        process.environment = [
            "UV_PROJECT_ENVIRONMENT": venvDir.path,
            "UV_PYTHON_INSTALL_DIR": appSupportDir.appendingPathComponent("python_runtimes").path,
            "UV_CACHE_DIR": appSupportDir.appendingPathComponent("uv_cache").path,
            "UV_PYTHON_PREFERENCE": "only-managed",
            "PYTHONUNBUFFERED": "1",
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin"
        ]

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            detailedStatus = "Error: \(error.localizedDescription)"
        }
    }

    private func downloadSAMModel() async {
        // SAM model is downloaded on first use via HuggingFace
        // We'll trigger a warmup to download it
        detailedStatus = "SAM model will be downloaded on first use..."
        try? await Task.sleep(nanoseconds: 500_000_000)
    }

    private func setupHunyuanEnvironment() async {
        guard let uvPath = Bundle.main.path(forResource: "uv", ofType: nil) ??
                          Bundle.main.path(forResource: "uv", ofType: nil, inDirectory: "Resources") else {
            return
        }

        // Copy Hunyuan resources
        let hunyuanDir = appSupportDir.appendingPathComponent("Hunyuan3D")
        try? FileManager.default.createDirectory(at: hunyuanDir, withIntermediateDirectories: true)

        // Copy pyproject_hunyuan.toml
        if let sourcePath = Bundle.main.path(forResource: "pyproject_hunyuan.toml", ofType: nil) ??
                           Bundle.main.path(forResource: "pyproject_hunyuan.toml", ofType: nil, inDirectory: "Resources") {
            let targetPath = hunyuanDir.appendingPathComponent("pyproject.toml")
            try? FileManager.default.removeItem(at: targetPath)
            try? FileManager.default.copyItem(at: URL(fileURLWithPath: sourcePath), to: targetPath)
        }

        // Copy hunyuan_wrapper.py
        if let sourcePath = Bundle.main.path(forResource: "hunyuan_wrapper.py", ofType: nil) ??
                           Bundle.main.path(forResource: "hunyuan_wrapper.py", ofType: nil, inDirectory: "Resources") {
            let targetPath = hunyuanDir.appendingPathComponent("hunyuan_wrapper.py")
            try? FileManager.default.removeItem(at: targetPath)
            try? FileManager.default.copyItem(at: URL(fileURLWithPath: sourcePath), to: targetPath)
        }

        detailedStatus = "Installing Hunyuan3D dependencies..."

        let venvDir = appSupportDir.appendingPathComponent(".venv_hunyuan")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: uvPath)
        process.arguments = ["sync", "--python", "3.10"]
        process.currentDirectoryURL = hunyuanDir
        process.environment = [
            "UV_PROJECT_ENVIRONMENT": venvDir.path,
            "UV_PYTHON_INSTALL_DIR": appSupportDir.appendingPathComponent("python_runtimes").path,
            "UV_CACHE_DIR": appSupportDir.appendingPathComponent("uv_cache").path,
            "UV_PYTHON_PREFERENCE": "only-managed",
            "PYTHONUNBUFFERED": "1",
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin"
        ]

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            detailedStatus = "Error: \(error.localizedDescription)"
        }
    }

    private func downloadHunyuanModel() async {
        guard let uvPath = Bundle.main.path(forResource: "uv", ofType: nil) ??
                          Bundle.main.path(forResource: "uv", ofType: nil, inDirectory: "Resources") else {
            return
        }

        detailedStatus = "Downloading Hunyuan3D model from HuggingFace..."

        let hunyuanDir = appSupportDir.appendingPathComponent("Hunyuan3D")
        let venvDir = appSupportDir.appendingPathComponent(".venv_hunyuan")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: uvPath)
        process.arguments = ["run", hunyuanDir.appendingPathComponent("hunyuan_wrapper.py").path, "--warmup"]
        process.currentDirectoryURL = hunyuanDir
        process.environment = [
            "UV_PROJECT_ENVIRONMENT": venvDir.path,
            "UV_PYTHON_INSTALL_DIR": appSupportDir.appendingPathComponent("python_runtimes").path,
            "UV_CACHE_DIR": appSupportDir.appendingPathComponent("uv_cache").path,
            "UV_PYTHON_PREFERENCE": "only-managed",
            "PYTHONUNBUFFERED": "1",
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "HF_HOME": hunyuanDir.appendingPathComponent("hf_cache").path
        ]

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            detailedStatus = "Error: \(error.localizedDescription)"
        }
    }

    // MARK: - Monitoring

    private var lastSize: UInt64 = 0
    private var lastCheckTime: Date = Date()

    private func startMonitoring(prefix: String) {
        stopMonitoring()

        lastSize = directorySize(at: appSupportDir)
        lastCheckTime = Date()

        monitorTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)

                let currentSize = directorySize(at: appSupportDir)
                let now = Date()
                let elapsed = now.timeIntervalSince(lastCheckTime)

                if elapsed > 0 {
                    let bytesDownloaded = currentSize > lastSize ? currentSize - lastSize : 0
                    let throughput = Double(bytesDownloaded) / elapsed

                    await MainActor.run {
                        self.downloadedSize = self.formatBytes(currentSize)
                        self.downloadSpeed = self.formatThroughput(throughput)

                        // Estimate remaining (rough approximation)
                        if throughput > 0 && self.overallProgress > 0 && self.overallProgress < 1 {
                            let remainingProgress = 1.0 - self.overallProgress
                            // Assume roughly 4GB total, estimate based on current progress
                            let estimatedTotalBytes: Double = 4_000_000_000
                            let estimatedRemaining = (remainingProgress * estimatedTotalBytes) / throughput

                            if estimatedRemaining < 3600 {
                                let mins = Int(estimatedRemaining) / 60
                                let secs = Int(estimatedRemaining) % 60
                                self.estimatedRemaining = String(format: "%d:%02d", mins, secs)
                            } else {
                                self.estimatedRemaining = ">1 hour"
                            }
                        }
                    }

                    lastSize = currentSize
                    lastCheckTime = now
                }
            }
        }
    }

    private func stopMonitoring() {
        monitorTask?.cancel()
        monitorTask = nil
    }

    private func directorySize(at url: URL) -> UInt64 {
        let fm = FileManager.default
        var totalSize: UInt64 = 0

        guard let enumerator = fm.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey], options: [.skipsHiddenFiles]) else {
            return 0
        }

        for case let fileURL as URL in enumerator {
            if let fileSize = try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                totalSize += UInt64(fileSize)
            }
        }

        return totalSize
    }

    private func formatBytes(_ bytes: UInt64) -> String {
        let mb = Double(bytes) / 1_048_576
        let gb = mb / 1024

        if gb >= 1 {
            return String(format: "%.2f GB", gb)
        } else {
            return String(format: "%.0f MB", mb)
        }
    }

    private func formatThroughput(_ bytesPerSecond: Double) -> String {
        let mbps = bytesPerSecond / 1_048_576

        if mbps >= 1 {
            return String(format: "%.1f MB/s", mbps)
        } else if bytesPerSecond > 1024 {
            return String(format: "%.0f KB/s", bytesPerSecond / 1024)
        } else {
            return "Connecting..."
        }
    }
}

// MARK: - Preview

#Preview {
    SetupView(isSetupComplete: .constant(false))
}
