import SwiftUI

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

// MARK: - Preview

#Preview {
    SetupView(isSetupComplete: .constant(false))
}
