import SwiftUI

// MARK: - Design System

private enum SetupDesign {
    // Warm industrial palette - amber/gold accent
    static let accentPrimary = Color(red: 1.0, green: 0.72, blue: 0.25)      // Amber gold
    static let accentSecondary = Color(red: 0.95, green: 0.55, blue: 0.15)   // Deep amber
    static let surfaceDark = Color(red: 0.06, green: 0.06, blue: 0.08)       // Near black
    static let surfaceMid = Color(red: 0.10, green: 0.10, blue: 0.12)        // Dark gray
    static let textPrimary = Color(red: 0.95, green: 0.95, blue: 0.92)       // Warm white
    static let textSecondary = Color(red: 0.55, green: 0.55, blue: 0.52)     // Muted
    static let gridLine = Color.white.opacity(0.03)
    static let wireframe = Color(red: 0.35, green: 0.35, blue: 0.38)
}

// MARK: - Setup View

struct SetupView: View {
    @StateObject private var setupManager = SetupManager()
    @Binding var isSetupComplete: Bool

    @State private var hasAppeared = false
    @State private var cubeRotation: Double = 0

    var body: some View {
        ZStack {
            // Layered background
            backgroundStack

            // Content
            if !setupManager.setupStarted {
                WelcomeScreen(
                    hasAppeared: hasAppeared,
                    cubeRotation: cubeRotation,
                    onStart: { setupManager.startSetup() }
                )
            } else {
                SetupProgressScreen(
                    setupManager: setupManager,
                    cubeRotation: cubeRotation,
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
            // Continuous cube rotation
            withAnimation(.linear(duration: 20).repeatForever(autoreverses: false)) {
                cubeRotation = 360
            }
        }
    }

    // MARK: - Background

    private var backgroundStack: some View {
        ZStack {
            // Base
            SetupDesign.surfaceDark
                .ignoresSafeArea()

            // Subtle radial gradient from center
            RadialGradient(
                colors: [
                    SetupDesign.surfaceMid.opacity(0.8),
                    SetupDesign.surfaceDark
                ],
                center: .center,
                startRadius: 0,
                endRadius: 600
            )
            .ignoresSafeArea()

            // Technical grid
            TechnicalGrid()
                .opacity(hasAppeared ? 1 : 0)

            // Noise texture overlay
            NoiseOverlay()
                .opacity(0.03)
                .blendMode(.overlay)
        }
    }
}

// MARK: - Welcome Screen

private struct WelcomeScreen: View {
    let hasAppeared: Bool
    let cubeRotation: Double
    let onStart: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            // Left: Visual
            leftPanel
                .frame(maxWidth: .infinity)

            // Right: Content
            rightPanel
                .frame(width: 380)
                .padding(.trailing, 60)
        }
    }

    private var leftPanel: some View {
        ZStack {
            // Wireframe cube hero
            WireframeCubeView(rotation: cubeRotation)
                .frame(width: 280, height: 280)
                .offset(x: hasAppeared ? 0 : -50, y: 0)
                .opacity(hasAppeared ? 1 : 0)

            // Floating geometric accents
            GeometricAccents(hasAppeared: hasAppeared)
        }
    }

    private var rightPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            Spacer()

            // Version tag
            versionTag
                .offset(y: hasAppeared ? 0 : 20)
                .opacity(hasAppeared ? 1 : 0)
                .animation(.easeOut(duration: 0.8).delay(0.2), value: hasAppeared)

            Spacer().frame(height: 20)

            // Title
            titleSection
                .offset(y: hasAppeared ? 0 : 30)
                .opacity(hasAppeared ? 1 : 0)
                .animation(.easeOut(duration: 0.8).delay(0.3), value: hasAppeared)

            Spacer().frame(height: 40)

            // Features
            featuresSection
                .offset(y: hasAppeared ? 0 : 30)
                .opacity(hasAppeared ? 1 : 0)
                .animation(.easeOut(duration: 0.8).delay(0.5), value: hasAppeared)

            Spacer().frame(height: 50)

            // CTA
            ctaSection
                .offset(y: hasAppeared ? 0 : 30)
                .opacity(hasAppeared ? 1 : 0)
                .animation(.easeOut(duration: 0.8).delay(0.7), value: hasAppeared)

            Spacer()
        }
    }

    private var versionTag: some View {
        HStack(spacing: 8) {
            Rectangle()
                .fill(SetupDesign.accentPrimary)
                .frame(width: 3, height: 14)

            Text("v3.0")
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundColor(SetupDesign.textSecondary)
                .tracking(2)
        }
    }

    private var titleSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("MODELR")
                .font(.system(size: 48, weight: .black, design: .default))
                .foregroundColor(SetupDesign.textPrimary)
                .tracking(4)

            Text("Easy Image to 3D")
                .font(.system(size: 20, weight: .medium))
                .foregroundColor(SetupDesign.textSecondary)

            Text("Open Source SOTA Models")
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundColor(SetupDesign.accentPrimary.opacity(0.8))
        }
    }

    private var featuresSection: some View {
        VStack(alignment: .leading, spacing: 18) {
            FeatureItem(
                number: "01",
                title: "SEGMENT",
                description: "Extract objects with SAM2"
            )
            FeatureItem(
                number: "02",
                title: "GENERATE",
                description: "SOTA open source 3D with Hunyuan3D"
            )
        }
    }

    private var ctaSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Button(action: onStart) {
                HStack(spacing: 12) {
                    Text("Get Started")
                        .font(.system(size: 14, weight: .semibold))

                    Image(systemName: "arrow.right")
                        .font(.system(size: 12, weight: .semibold))
                }
                .foregroundColor(SetupDesign.surfaceDark)
                .padding(.horizontal, 32)
                .padding(.vertical, 16)
                .background(
                    ZStack {
                        // Solid background
                        SetupDesign.accentPrimary

                        // Subtle gradient overlay
                        LinearGradient(
                            colors: [.white.opacity(0.2), .clear],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    }
                )
                .clipShape(RoundedRectangle(cornerRadius: 2))
                .shadow(color: SetupDesign.accentPrimary.opacity(0.4), radius: 20, y: 8)
            }
            .buttonStyle(.plain)

            // Setup info
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: "cable.connector")
                        .font(.system(size: 10))
                    Text("Ethernet recommended")
                        .font(.system(size: 11, weight: .medium))
                }
                .foregroundColor(SetupDesign.accentPrimary.opacity(0.9))

                Text("Downloads ~15 GB of AI models")
                    .font(.system(size: 10))
                    .foregroundColor(SetupDesign.textSecondary)
            }
        }
    }
}

// MARK: - Feature Item

private struct FeatureItem: View {
    let number: String
    let title: String
    let description: String

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            Text(number)
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundColor(SetupDesign.accentPrimary)
                .frame(width: 20, alignment: .trailing)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 12, weight: .semibold, design: .default))
                    .foregroundColor(SetupDesign.textPrimary)
                    .tracking(1)

                Text(description)
                    .font(.system(size: 11, design: .default))
                    .foregroundColor(SetupDesign.textSecondary)
            }
        }
    }
}

// MARK: - Setup Progress Screen

private struct SetupProgressScreen: View {
    @ObservedObject var setupManager: SetupManager
    let cubeRotation: Double
    let onComplete: () -> Void

    @State private var contentAppeared = false

    var body: some View {
        HStack(spacing: 0) {
            // Left: Slideshow
            slideshowPanel
                .frame(maxWidth: .infinity)

            // Right: Progress
            progressPanel
                .frame(width: 400)
        }
        .onAppear {
            withAnimation(.easeOut(duration: 0.6)) {
                contentAppeared = true
            }
        }
    }

    private var slideshowPanel: some View {
        ZStack {
            // Subtle rotating cube in background
            WireframeCubeView(rotation: cubeRotation)
                .frame(width: 200, height: 200)
                .opacity(0.15)

            // Slideshow content
            TechnicalSlideshow()
        }
        .opacity(contentAppeared ? 1 : 0)
    }

    private var progressPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            Spacer().frame(height: 60)

            // Header
            headerSection

            Spacer().frame(height: 40)

            // Progress section
            progressSection

            Spacer().frame(height: 30)

            // Stats
            statsSection

            Spacer()

            // Status
            statusSection

            Spacer().frame(height: 60)
        }
        .padding(.horizontal, 48)
        .background(
            Rectangle()
                .fill(SetupDesign.surfaceDark.opacity(0.5))
                .overlay(
                    Rectangle()
                        .fill(
                            LinearGradient(
                                colors: [SetupDesign.surfaceMid.opacity(0.3), .clear],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                )
        )
        .opacity(contentAppeared ? 1 : 0)
        .offset(x: contentAppeared ? 0 : 50)
        .animation(.easeOut(duration: 0.8), value: contentAppeared)
    }

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("SETUP")
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundColor(SetupDesign.accentPrimary)
                .tracking(3)

            Text(setupManager.isComplete ? "Complete" : "Installing")
                .font(.system(size: 32, weight: .bold))
                .foregroundColor(SetupDesign.textPrimary)
        }
    }

    private var progressSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Current stage
            HStack(spacing: 12) {
                if setupManager.isComplete {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(SetupDesign.surfaceDark)
                        .frame(width: 20, height: 20)
                        .background(SetupDesign.accentPrimary)
                        .clipShape(Circle())
                } else {
                    ProgressView()
                        .scaleEffect(0.6)
                        .tint(SetupDesign.accentPrimary)
                }

                Text(setupManager.currentStage)
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundColor(SetupDesign.textPrimary)
            }

            // Progress bar
            DimensionalProgressBar(progress: setupManager.overallProgress)

            // Begin button when complete
            if setupManager.isComplete {
                Button(action: onComplete) {
                    HStack(spacing: 10) {
                        Text("Begin")
                            .font(.system(size: 14, weight: .semibold))

                        Image(systemName: "arrow.right")
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .foregroundColor(SetupDesign.surfaceDark)
                    .padding(.horizontal, 28)
                    .padding(.vertical, 14)
                    .background(SetupDesign.accentPrimary)
                    .clipShape(RoundedRectangle(cornerRadius: 2))
                    .shadow(color: SetupDesign.accentPrimary.opacity(0.4), radius: 16, y: 6)
                }
                .buttonStyle(.plain)
                .padding(.top, 8)
                .transition(.opacity.combined(with: .offset(y: 10)))
                .animation(.easeOut(duration: 0.4), value: setupManager.isComplete)
            }
        }
    }

    private var statsSection: some View {
        HStack(spacing: 32) {
            StatBlock(label: "DOWNLOADED", value: setupManager.downloadedSize)
            StatBlock(label: "ELAPSED", value: setupManager.elapsedTime)
        }
    }

    private var statusSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Rectangle()
                .fill(SetupDesign.gridLine)
                .frame(height: 1)

            Text(setupManager.detailedStatus)
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(SetupDesign.textSecondary)
                .lineLimit(2)
        }
    }
}

// MARK: - Stat Block

private struct StatBlock: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundColor(SetupDesign.textSecondary)
                .tracking(1)

            Text(value)
                .font(.system(size: 14, weight: .semibold, design: .monospaced))
                .foregroundColor(SetupDesign.textPrimary)
        }
    }
}

// MARK: - Dimensional Progress Bar

private struct DimensionalProgressBar: View {
    let progress: Double

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                // Track with depth
                RoundedRectangle(cornerRadius: 1)
                    .fill(SetupDesign.surfaceMid)
                    .frame(height: 6)
                    .overlay(
                        RoundedRectangle(cornerRadius: 1)
                            .stroke(SetupDesign.gridLine, lineWidth: 1)
                    )

                // Fill with glow
                RoundedRectangle(cornerRadius: 1)
                    .fill(
                        LinearGradient(
                            colors: [SetupDesign.accentSecondary, SetupDesign.accentPrimary],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: max(0, geo.size.width * progress), height: 6)
                    .shadow(color: SetupDesign.accentPrimary.opacity(0.5), radius: 8, y: 0)
                    .animation(.easeInOut(duration: 0.4), value: progress)
            }
        }
        .frame(height: 6)
    }
}

// MARK: - Technical Slideshow

private struct TechnicalSlideshow: View {
    @State private var currentSlide = 0
    private let timer = Timer.publish(every: 6, on: .main, in: .common).autoconnect()

    private let slides: [TechSlide] = [
        TechSlide(
            step: "01",
            title: "LOAD",
            subtitle: "Drop in any image",
            detail: "PNG, JPEG, WebP"
        ),
        TechSlide(
            step: "02",
            title: "SEGMENT",
            subtitle: "Click to extract objects",
            detail: "Powered by SAM2"
        ),
        TechSlide(
            step: "03",
            title: "GENERATE",
            subtitle: "One click to 3D",
            detail: "Powered by Hunyuan3D"
        ),
        TechSlide(
            step: "04",
            title: "EXPORT",
            subtitle: "Ready to use",
            detail: "GLB format"
        )
    ]

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            // Step indicator
            HStack(spacing: 4) {
                ForEach(0..<slides.count, id: \.self) { index in
                    Rectangle()
                        .fill(index == currentSlide ? SetupDesign.accentPrimary : SetupDesign.wireframe)
                        .frame(width: index == currentSlide ? 24 : 12, height: 2)
                        .animation(.easeInOut(duration: 0.3), value: currentSlide)
                }
            }

            // Content
            let slide = slides[currentSlide]

            VStack(spacing: 16) {
                // Step number
                Text(slide.step)
                    .font(.system(size: 64, weight: .thin, design: .monospaced))
                    .foregroundColor(SetupDesign.wireframe)

                // Title
                Text(slide.title)
                    .font(.system(size: 32, weight: .black))
                    .foregroundColor(SetupDesign.textPrimary)
                    .tracking(6)

                // Subtitle
                Text(slide.subtitle)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(SetupDesign.textSecondary)

                // Detail
                Text(slide.detail)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(SetupDesign.accentPrimary.opacity(0.8))
            }
            .id(currentSlide)
            .transition(.asymmetric(
                insertion: .opacity.combined(with: .offset(y: 20)),
                removal: .opacity.combined(with: .offset(y: -20))
            ))

            Spacer()
        }
        .padding(40)
        .onReceive(timer) { _ in
            withAnimation(.easeInOut(duration: 0.5)) {
                currentSlide = (currentSlide + 1) % slides.count
            }
        }
    }
}

private struct TechSlide {
    let step: String
    let title: String
    let subtitle: String
    let detail: String
}

// MARK: - Wireframe Cube

private struct WireframeCubeView: View {
    let rotation: Double

    var body: some View {
        TimelineView(.animation) { timeline in
            Canvas { context, size in
                let center = CGPoint(x: size.width / 2, y: size.height / 2)
                let scale = min(size.width, size.height) * 0.35

                // Rotation angles
                let angleX = rotation * .pi / 180
                let angleY = rotation * 0.7 * .pi / 180

                // Cube vertices (centered at origin)
                let vertices: [(Double, Double, Double)] = [
                    (-1, -1, -1), (1, -1, -1), (1, 1, -1), (-1, 1, -1),
                    (-1, -1, 1), (1, -1, 1), (1, 1, 1), (-1, 1, 1)
                ]

                // Project 3D to 2D with rotation
                func project(_ v: (Double, Double, Double)) -> CGPoint {
                    // Rotate around Y axis
                    let x1 = v.0 * cos(angleY) - v.2 * sin(angleY)
                    let z1 = v.0 * sin(angleY) + v.2 * cos(angleY)
                    let y1 = v.1

                    // Rotate around X axis
                    let y2 = y1 * cos(angleX) - z1 * sin(angleX)
                    let z2 = y1 * sin(angleX) + z1 * cos(angleX)
                    let x2 = x1

                    // Simple perspective projection
                    let perspective = 3.0 / (3.0 - z2 * 0.3)

                    return CGPoint(
                        x: center.x + x2 * scale * perspective,
                        y: center.y + y2 * scale * perspective
                    )
                }

                let projected = vertices.map { project($0) }

                // Cube edges
                let edges = [
                    (0, 1), (1, 2), (2, 3), (3, 0), // Front face
                    (4, 5), (5, 6), (6, 7), (7, 4), // Back face
                    (0, 4), (1, 5), (2, 6), (3, 7)  // Connecting edges
                ]

                // Draw edges
                for (i, j) in edges {
                    var path = Path()
                    path.move(to: projected[i])
                    path.addLine(to: projected[j])

                    context.stroke(
                        path,
                        with: .color(SetupDesign.wireframe),
                        lineWidth: 1.5
                    )
                }

                // Draw vertices as small dots
                for point in projected {
                    let dotPath = Path(ellipseIn: CGRect(
                        x: point.x - 3,
                        y: point.y - 3,
                        width: 6,
                        height: 6
                    ))
                    context.fill(dotPath, with: .color(SetupDesign.accentPrimary))
                }
            }
        }
    }
}

// MARK: - Geometric Accents

private struct GeometricAccents: View {
    let hasAppeared: Bool

    var body: some View {
        ZStack {
            // Floating squares at various depths
            FloatingSquare(size: 40, rotation: 12)
                .offset(x: -120, y: -100)
                .opacity(hasAppeared ? 0.3 : 0)
                .animation(.easeOut(duration: 1).delay(0.4), value: hasAppeared)

            FloatingSquare(size: 20, rotation: -8)
                .offset(x: 100, y: 80)
                .opacity(hasAppeared ? 0.2 : 0)
                .animation(.easeOut(duration: 1).delay(0.6), value: hasAppeared)

            FloatingSquare(size: 60, rotation: 45)
                .offset(x: -80, y: 120)
                .opacity(hasAppeared ? 0.15 : 0)
                .animation(.easeOut(duration: 1).delay(0.8), value: hasAppeared)

            // Horizontal lines
            HStack(spacing: 4) {
                ForEach(0..<5, id: \.self) { i in
                    Rectangle()
                        .fill(SetupDesign.wireframe)
                        .frame(width: CGFloat(30 - i * 5), height: 1)
                }
            }
            .offset(x: -150, y: 50)
            .opacity(hasAppeared ? 0.4 : 0)
            .animation(.easeOut(duration: 1).delay(0.5), value: hasAppeared)
        }
    }
}

private struct FloatingSquare: View {
    let size: CGFloat
    let rotation: Double

    var body: some View {
        Rectangle()
            .stroke(SetupDesign.wireframe, lineWidth: 1)
            .frame(width: size, height: size)
            .rotationEffect(.degrees(rotation))
    }
}

// MARK: - Technical Grid

private struct TechnicalGrid: View {
    var body: some View {
        Canvas { context, size in
            let spacing: CGFloat = 40

            // Vertical lines
            var x: CGFloat = 0
            while x < size.width {
                var path = Path()
                path.move(to: CGPoint(x: x, y: 0))
                path.addLine(to: CGPoint(x: x, y: size.height))
                context.stroke(path, with: .color(SetupDesign.gridLine), lineWidth: 0.5)
                x += spacing
            }

            // Horizontal lines
            var y: CGFloat = 0
            while y < size.height {
                var path = Path()
                path.move(to: CGPoint(x: 0, y: y))
                path.addLine(to: CGPoint(x: size.width, y: y))
                context.stroke(path, with: .color(SetupDesign.gridLine), lineWidth: 0.5)
                y += spacing
            }
        }
    }
}

// MARK: - Noise Overlay

private struct NoiseOverlay: View {
    var body: some View {
        Canvas { context, size in
            for _ in 0..<Int(size.width * size.height / 100) {
                let x = CGFloat.random(in: 0..<size.width)
                let y = CGFloat.random(in: 0..<size.height)
                let opacity = Double.random(in: 0.1...0.3)

                let rect = CGRect(x: x, y: y, width: 1, height: 1)
                context.fill(Path(rect), with: .color(.white.opacity(opacity)))
            }
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
        startMonitoring(directory: appSupportDir.appendingPathComponent("Hunyuan3D/hf_cache"), totalSize: "7.1G")
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
                                self?.parseProcessOutput(output)
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
                                self?.parseProcessOutput(output)
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

        detailedStatus = "Downloading Hunyuan3D model (~4 GB)..."

        let hunyuanDir = appSupportDir.appendingPathComponent("Hunyuan3D")
        let venvDir = appSupportDir.appendingPathComponent(".venv_hunyuan")
        let hfCacheDir = hunyuanDir.appendingPathComponent("hf_cache")

        // Create cache directory for monitoring
        try? FileManager.default.createDirectory(at: hfCacheDir, withIntermediateDirectories: true)

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

        await runProcessAsync(process, parseOutput: true)
    }

}

// MARK: - Preview

#Preview {
    SetupView(isSetupComplete: .constant(false))
}
