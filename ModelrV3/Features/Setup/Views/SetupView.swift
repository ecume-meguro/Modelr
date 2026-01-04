import SwiftUI

// MARK: - Design System

private enum SetupDesign {
    static let accent = Color.accentColor
    static let textSecondary = Color.secondary
    static let textTertiary = Color.secondary.opacity(0.7) // Fallback for hierarchical color
}

// MARK: - Setup View

struct SetupView: View {
    @StateObject private var setupManager = SetupManager()
    @Binding var isSetupComplete: Bool

    @State private var hasAppeared = false

    var body: some View {
        ZStack {
            // Layered background
            backgroundStack

            // Content
            if !setupManager.setupStarted {
                WelcomeScreen(
                    hasAppeared: hasAppeared,
                    onStart: { modelChoice in
                        setupManager.startSetup(modelChoice: modelChoice)
                    }
                )
            } else {
                SetupProgressScreen(
                    setupManager: setupManager,
                    onComplete: {
                        withAnimation(.easeInOut(duration: 0.4)) {
                            isSetupComplete = true
                        }
                    }
                )
            }
        }
        .frame(minWidth: 800, minHeight: 600)
        .onAppear {
            withAnimation(.easeOut(duration: 1.2)) {
                hasAppeared = true
            }
        }
    }

    // MARK: - Background

    private var backgroundStack: some View {
        ZStack {
            // Native macOS background style
            Color(NSColor.windowBackgroundColor)
                .ignoresSafeArea()

            // Subtle gradient
            LinearGradient(
                colors: [
                    Color.accentColor.opacity(0.05),
                    Color.clear
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            // Material overlay
            Rectangle()
                .fill(.ultraThinMaterial)
                .ignoresSafeArea()
        }
    }
}

// MARK: - Model Choice

enum SetupModelChoice: String, CaseIterable {
    case fast = "fast"
    case quality = "quality"

    var displayName: String {
        switch self {
        case .fast: return "Small, Fast"
        case .quality: return "Large, Higher Quality"
        }
    }

    var modelVariant: String {
        switch self {
        case .fast: return "mini"
        case .quality: return "std"
        }
    }

    var downloadSize: String {
        switch self {
        case .fast: return "~2 GB"
        case .quality: return "~4 GB"
        }
    }

    var modelName: String {
        switch self {
        case .fast: return "Hunyuan3D-2 Mini"
        case .quality: return "Hunyuan3D-2.1"
        }
    }
}

// MARK: - Welcome Screen

private struct WelcomeScreen: View {
    let hasAppeared: Bool
    let onStart: (SetupModelChoice) -> Void

    @State private var selectedModel: SetupModelChoice = .fast

    var body: some View {
        VStack(spacing: AppDesign.Spacing.p48) {
            Spacer()

            VStack(spacing: AppDesign.Spacing.p16) {
                Text("Modelr v3")
                    .font(.system(size: 72, weight: .bold))
                    .tracking(-2)
                    .foregroundStyle(.primary)

                Text("Professional Image to 3D Workflow")
                    .font(.system(size: AppDesign.FontSize.title3, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .offset(y: hasAppeared ? 0 : 20)
            .opacity(hasAppeared ? 1 : 0)
            .animation(.spring(response: 0.6, dampingFraction: 0.8).delay(0.2), value: hasAppeared)

            // Model Selection
            VStack(spacing: AppDesign.Spacing.p16) {
                Text("Choose your 3D model")
                    .font(.system(size: AppDesign.FontSize.headline, weight: .semibold))
                    .foregroundStyle(.primary)

                HStack(spacing: AppDesign.Spacing.p16) {
                    ForEach(SetupModelChoice.allCases, id: \.self) { choice in
                        ModelChoiceCard(
                            choice: choice,
                            isSelected: selectedModel == choice,
                            isRecommended: choice == .fast
                        ) {
                            withAnimation(.easeOut(duration: 0.15)) {
                                selectedModel = choice
                            }
                        }
                    }
                }

                // Fine print showing which model each option uses
                VStack(spacing: AppDesign.Spacing.p4) {
                    HStack(spacing: AppDesign.Spacing.p24) {
                        Text("Small, Fast → \(SetupModelChoice.fast.modelName)")
                        Text("Large, Higher Quality → \(SetupModelChoice.quality.modelName)")
                    }
                    .font(.system(size: AppDesign.FontSize.xs, design: .monospaced))
                    .foregroundStyle(.tertiary)
                }
                .padding(.top, AppDesign.Spacing.p8)
            }
            .offset(y: hasAppeared ? 0 : 20)
            .opacity(hasAppeared ? 1 : 0)
            .animation(.spring(response: 0.6, dampingFraction: 0.8).delay(0.3), value: hasAppeared)

            // CTA Section
            VStack(spacing: AppDesign.Spacing.p24) {
                AppDesign.GlassButton("Get Started", icon: "arrow.right") {
                    onStart(selectedModel)
                }
                .controlSize(.large)

                HStack(spacing: AppDesign.Spacing.p8) {
                    Image(systemName: "info.circle.fill")
                        .font(.system(size: AppDesign.FontSize.caption))
                    Text("Requires ~\(selectedModel == .fast ? "12" : "14") GB for initial download")
                        .font(.system(size: AppDesign.FontSize.caption, weight: .medium))
                }
                .foregroundStyle(.tertiary)
            }
            .offset(y: hasAppeared ? 0 : 20)
            .opacity(hasAppeared ? 1 : 0)
            .animation(.spring(response: 0.6, dampingFraction: 0.8).delay(0.4), value: hasAppeared)

            Spacer()
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Model Choice Card

private struct ModelChoiceCard: View {
    let choice: SetupModelChoice
    let isSelected: Bool
    let isRecommended: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            VStack(spacing: AppDesign.Spacing.p12) {
                HStack {
                    if isRecommended {
                        Text("Recommended")
                            .font(.system(size: AppDesign.FontSize.xs, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(AppDesign.accent, in: Capsule())
                    }
                    Spacer()
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: AppDesign.FontSize.title3))
                        .foregroundStyle(isSelected ? AppDesign.accent : .secondary.opacity(0.5))
                }

                VStack(spacing: AppDesign.Spacing.p4) {
                    Text(choice.displayName)
                        .font(.system(size: AppDesign.FontSize.headline, weight: .semibold))
                        .foregroundStyle(.primary)

                    Text(choice.downloadSize)
                        .font(.system(size: AppDesign.FontSize.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(AppDesign.Spacing.p16)
            .frame(width: 180)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(isSelected ? AppDesign.accent.opacity(0.1) : Color.primary.opacity(0.03))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(isSelected ? AppDesign.accent : Color.primary.opacity(0.1), lineWidth: isSelected ? 2 : 1)
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Setup Progress Screen

private struct SetupProgressScreen: View {
    @ObservedObject var setupManager: SetupManager
    let onComplete: () -> Void

    @State private var contentAppeared = false

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            VStack(alignment: .center, spacing: AppDesign.Spacing.p64) {
                // Header
                VStack(spacing: AppDesign.Spacing.p16) {
                    Text("Setting Up Modelr")
                        .font(.system(size: 48, weight: .bold))
                        .tracking(-1.5)
                        .foregroundStyle(.primary)
                    
                    Text("Preparing your professional 3D workspace")
                        .font(.system(size: AppDesign.FontSize.title3, weight: .medium))
                        .foregroundStyle(.secondary)
                }

                // Steps indicator
                HStack(spacing: AppDesign.Spacing.p32) {
                    StepItemCompact(title: "Environment", isDone: setupManager.overallProgress >= 0.3)
                    StepItemCompact(title: "Segmentation", isDone: setupManager.overallProgress >= 0.5)
                    StepItemCompact(title: "3D Generation", isDone: setupManager.isComplete)
                }
                .padding(.horizontal, AppDesign.Spacing.p32)
                .padding(.vertical, AppDesign.Spacing.p16)
                .background(.ultraThinMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.white.opacity(0.1), lineWidth: 1))

                // Progress Area
                VStack(spacing: AppDesign.Spacing.p32) {
                    VStack(spacing: AppDesign.Spacing.p12) {
                        Text(setupManager.currentStage)
                            .font(.system(size: AppDesign.FontSize.headline, weight: .semibold))
                        
                        ProgressView(value: setupManager.overallProgress)
                            .progressViewStyle(.linear)
                            .frame(width: 400)
                            .tint(AppDesign.accent)
                    }

                    VStack(spacing: AppDesign.Spacing.p12) {
                        Text(setupManager.detailedStatus)
                            .font(.system(size: AppDesign.FontSize.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .frame(height: 40)
                            .multilineTextAlignment(.center)
                        
                        HStack(spacing: AppDesign.Spacing.p24) {
                            StatLabel(label: "Downloaded", value: setupManager.downloadedSize)
                            StatLabel(label: "Time Elapsed", value: setupManager.elapsedTime)
                        }
                    }
                }

                // Action Area
                Group {
                    if setupManager.isComplete {
                        AppDesign.GlassButton("Start Using Modelr", icon: "checkmark.circle.fill", action: onComplete)
                            .controlSize(.large)
                            .transition(.scale.combined(with: .opacity))
                    } else {
                        HStack(spacing: AppDesign.Spacing.p12) {
                            ProgressView()
                                .controlSize(.small)
                            Text("Please keep the app open during installation")
                                .font(.system(size: AppDesign.FontSize.caption, weight: .medium))
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
                .frame(height: 44)
            }
            .frame(maxWidth: 600)
            
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .onAppear {
            withAnimation(.easeOut(duration: 0.6)) {
                contentAppeared = true
            }
        }
    }
}



private struct StepItemCompact: View {
    let title: String
    let isDone: Bool

    var body: some View {
        HStack(spacing: AppDesign.Spacing.p8) {
            Image(systemName: isDone ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(isDone ? AppDesign.success : Color.secondary.opacity(0.3))
            Text(title)
                .font(.system(size: AppDesign.FontSize.caption))
                .foregroundStyle(isDone ? .primary : .secondary)
        }
    }
}

private struct StatLabel: View {
    let label: String
    let value: String

    var body: some View {
        HStack(spacing: AppDesign.Spacing.p4) {
            Text("\(label):")
                .font(.system(size: AppDesign.FontSize.caption))
                .foregroundStyle(.tertiary)
            Text(value)
                .font(.system(size: AppDesign.FontSize.caption, design: .monospaced))
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Setup Manager

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
        await setupPythonEnvironment()

        // Stage 3: Download SAM model
        currentStage = "Downloading segmentation model..."
        overallProgress = 0.3
        await downloadSAMModel()

        // Stage 4: Setup Hunyuan environment
        currentStage = "Setting up 3D generation environment..."
        overallProgress = 0.5
        await setupHunyuanEnvironment()

        // Stage 5: Download Hunyuan model
        currentStage = "Downloading 3D generation model..."
        overallProgress = 0.7
        let modelTotalSize = selectedModelChoice == .fast ? "2.0G" : "4.0G"
        startMonitoring(directory: appSupportDir.appendingPathComponent("Hunyuan3D/hf_cache"), totalSize: modelTotalSize)
        await downloadHunyuanModel()
        stopMonitoring()

        // Complete
        overallProgress = 1.0
        currentStage = "Setup Complete"
        detailedStatus = "All models downloaded and ready"
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

        await runProcessAsync(process, parseOutput: true)
    }

    /// Runs a process without blocking the main thread, with output parsing
    private func runProcessAsync(_ process: Process, parseOutput: Bool = false) async {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                if parseOutput {
                    let pipe = Pipe()
                    let errorPipe = Pipe()
                    process.standardOutput = pipe
                    process.standardError = errorPipe

                    // Read stdout in background
                    pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
                        let data = handle.availableData
                        if !data.isEmpty {
                            // Pass through to terminal
                            FileHandle.standardOutput.write(data)
                            if let output = String(data: data, encoding: .utf8) {
                                Task { @MainActor in
                                    self?.parseProcessOutput(output)
                                }
                            }
                        }
                    }

                    // Read stderr in background (tqdm writes to stderr)
                    errorPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
                        let data = handle.availableData
                        if !data.isEmpty {
                            // Pass through to terminal
                            FileHandle.standardError.write(data)
                            if let output = String(data: data, encoding: .utf8) {
                                Task { @MainActor in
                                    self?.parseProcessOutput(output)
                                }
                            }
                        }
                    }
                }

                do {
                    try process.run()
                    process.waitUntilExit()
                } catch {
                    Task { @MainActor in
                        self.detailedStatus = "Error: \(error.localizedDescription)"
                    }
                }
                continuation.resume()
            }
        }
    }

    /// Parse process output for progress info
    private func parseProcessOutput(_ output: String) {
        // Handle carriage returns (tqdm uses \r for progress updates)
        let lines = output.replacingOccurrences(of: "\r", with: "\n").components(separatedBy: .newlines)

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }

            Task { @MainActor in
                // UV package installation: "+ package==version"
                if trimmed.hasPrefix("+ ") {
                    let package = String(trimmed.dropFirst(2))
                    if let name = package.split(separator: "=").first {
                        self.detailedStatus = "Installing \(name)..."
                    }
                }
                // HuggingFace download progress - show file being downloaded
                else if trimmed.contains("/") && trimmed.contains("%") {
                    if let colonIdx = trimmed.firstIndex(of: ":") {
                        let fileName = String(trimmed[..<colonIdx])
                        if fileName.contains("model") || fileName.contains("safetensor") || fileName.contains(".ckpt") {
                            self.detailedStatus = "Downloading \(fileName)..."
                        }
                    }
                }
                // Fetching files progress
                else if trimmed.contains("Fetching") && trimmed.contains("files") {
                    self.detailedStatus = trimmed.components(separatedBy: "|").first?.trimmingCharacters(in: .whitespaces) ?? trimmed
                }
                // Resolved/Prepared/Installed packages
                else if trimmed.hasPrefix("Resolved") || trimmed.hasPrefix("Prepared") || trimmed.hasPrefix("Installed") {
                    self.detailedStatus = trimmed
                }
                // Loading model
                else if trimmed.contains("Loading") && trimmed.contains("pipeline") {
                    self.detailedStatus = "Loading model..."
                }
                // Warming up
                else if trimmed.contains("Warming up") {
                    self.detailedStatus = trimmed
                }
            }
        }
    }

    // MARK: - Monitoring

    private func startMonitoring(directory: URL, totalSize: String) {
        stopMonitoring()
        monitorTask = Task {
            while !Task.isCancelled {
                let size = await getDiskUsage(at: directory)
                await MainActor.run {
                    self.downloadedSize = "\(size) / \(totalSize)"
                }
                try? await Task.sleep(nanoseconds: 1_000_000_000)  // 1 second
            }
        }
    }

    private func stopMonitoring() {
        monitorTask?.cancel()
        monitorTask = nil
        Task { @MainActor in
            self.downloadedSize = "—"
        }
    }

    private func getDiskUsage(at url: URL) async -> String {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let process = Process()
                let pipe = Pipe()

                process.executableURL = URL(fileURLWithPath: "/usr/bin/du")
                process.arguments = ["-sh", url.path]
                process.standardOutput = pipe
                process.standardError = nil

                do {
                    try process.run()
                    process.waitUntilExit()

                    let data = pipe.fileHandleForReading.readDataToEndOfFile()
                    if let output = String(data: data, encoding: .utf8),
                       let size = output.split(separator: "\t").first {
                        continuation.resume(returning: String(size))
                    } else {
                        continuation.resume(returning: "0")
                    }
                } catch {
                    continuation.resume(returning: "0")
                }
            }
        }
    }

    private func downloadSAMModel() async {
        guard let uvPath = Bundle.main.path(forResource: "uv", ofType: nil) ??
                          Bundle.main.path(forResource: "uv", ofType: nil, inDirectory: "Resources") else {
            detailedStatus = "Error: uv not found in bundle"
            return
        }

        detailedStatus = "Downloading SAM model..."

        let samWrapper = appSupportDir.appendingPathComponent("sam_wrapper.py")
        let venvDir = appSupportDir.appendingPathComponent(".venv")
        let samCacheDir = appSupportDir.appendingPathComponent("sam_cache")

        // Create cache directory
        try? FileManager.default.createDirectory(at: samCacheDir, withIntermediateDirectories: true)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: uvPath)
        process.arguments = ["run", samWrapper.path, "--test"]
        process.currentDirectoryURL = appSupportDir
        process.environment = [
            "UV_PROJECT_ENVIRONMENT": venvDir.path,
            "UV_PYTHON_INSTALL_DIR": appSupportDir.appendingPathComponent("python_runtimes").path,
            "UV_CACHE_DIR": appSupportDir.appendingPathComponent("uv_cache").path,
            "UV_PYTHON_PREFERENCE": "only-managed",
            "PYTHONUNBUFFERED": "1",
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "HF_HOME": samCacheDir.path
        ]

        startMonitoring(directory: samCacheDir, totalSize: "3.2G")
        await runProcessAsync(process, parseOutput: true)
        stopMonitoring()
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

        await runProcessAsync(process, parseOutput: true)
    }

    private func downloadHunyuanModel() async {
        guard let uvPath = Bundle.main.path(forResource: "uv", ofType: nil) ??
                          Bundle.main.path(forResource: "uv", ofType: nil, inDirectory: "Resources") else {
            return
        }

        detailedStatus = "Downloading \(selectedModelChoice.modelName) (\(selectedModelChoice.downloadSize))..."

        let hunyuanDir = appSupportDir.appendingPathComponent("Hunyuan3D")
        let venvDir = appSupportDir.appendingPathComponent(".venv_hunyuan")
        let hfCacheDir = hunyuanDir.appendingPathComponent("hf_cache")

        // Create cache directory for monitoring
        try? FileManager.default.createDirectory(at: hfCacheDir, withIntermediateDirectories: true)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: uvPath)
        process.arguments = ["run", hunyuanDir.appendingPathComponent("hunyuan_wrapper.py").path, "--warmup", "--model", selectedModelChoice.modelVariant]
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

        await runProcessAsync(process, parseOutput: true)

        // Save the selected model choice for later use
        UserDefaults.standard.set(selectedModelChoice.modelVariant, forKey: "SelectedHunyuanModel")
    }

}

// MARK: - Preview

#Preview {
    SetupView(isSetupComplete: .constant(false))
}
