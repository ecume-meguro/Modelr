import SwiftUI

/// Full-screen setup wizard for first-time users
struct SetupWizardView: View {
    @StateObject private var viewModel = SetupWizardViewModel()
    var onComplete: () -> Void

    var body: some View {
        ZStack {
            // Background gradient
            LinearGradient(
                colors: [
                    Color(nsColor: .windowBackgroundColor),
                    Color.accentColor.opacity(0.05)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            VStack(spacing: 0) {
                // Progress indicator
                progressIndicator
                    .padding(.top, 40)
                    .padding(.horizontal, 60)

                // Content area
                contentView
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                // Navigation buttons
                navigationButtons
                    .padding(.horizontal, 60)
                    .padding(.bottom, 40)
            }
        }
        .frame(minWidth: 700, minHeight: 550)
        .onChange(of: viewModel.isComplete) { _, isComplete in
            if isComplete {
                // Delay slightly before transitioning
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    onComplete()
                }
            }
        }
    }

    // MARK: - Progress Indicator

    @ViewBuilder
    private var progressIndicator: some View {
        HStack(spacing: 0) {
            ForEach(SetupWizardStep.allCases, id: \.self) { step in
                let isCurrent = step == viewModel.currentStep
                let isPast = step.rawValue < viewModel.currentStep.rawValue

                // Step circle
                ZStack {
                    Circle()
                        .fill(isPast ? Color.green : (isCurrent ? Color.accentColor : Color.primary.opacity(0.1)))
                        .frame(width: 32, height: 32)

                    if isPast {
                        Image(systemName: "checkmark")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(.white)
                    } else {
                        Text("\(step.rawValue + 1)")
                            .font(.system(size: 14, weight: .semibold, design: .rounded))
                            .foregroundStyle(isCurrent ? .white : .secondary)
                    }
                }

                // Connector line (except after last step)
                if step != SetupWizardStep.allCases.last {
                    Rectangle()
                        .fill(isPast ? Color.green : Color.primary.opacity(0.1))
                        .frame(height: 2)
                }
            }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: viewModel.currentStep)
    }

    // MARK: - Content View

    @ViewBuilder
    private var contentView: some View {
        ZStack {
            switch viewModel.currentStep {
            case .welcome:
                SetupWelcomeView()
                    .environmentObject(viewModel)
                    .transition(.asymmetric(
                        insertion: .opacity.combined(with: .move(edge: .trailing)),
                        removal: .opacity.combined(with: .move(edge: .leading))
                    ))

            case .modelSelection:
                SetupModelSelectionView(selectedChoice: $viewModel.selectedModelChoice)
                    .environmentObject(viewModel)
                    .transition(.asymmetric(
                        insertion: .opacity.combined(with: .move(edge: .trailing)),
                        removal: .opacity.combined(with: .move(edge: .leading))
                    ))

            case .download:
                SetupDownloadView()
                    .environmentObject(viewModel)
                    .transition(.asymmetric(
                        insertion: .opacity.combined(with: .move(edge: .trailing)),
                        removal: .opacity.combined(with: .move(edge: .leading))
                    ))

            case .complete:
                SetupCompleteView(onContinue: onComplete)
                    .environmentObject(viewModel)
                    .transition(.asymmetric(
                        insertion: .opacity.combined(with: .scale(scale: 0.95)),
                        removal: .opacity
                    ))
            }
        }
        .animation(.spring(response: 0.45, dampingFraction: 0.85), value: viewModel.currentStep)
    }

    // MARK: - Navigation Buttons

    @ViewBuilder
    private var navigationButtons: some View {
        HStack {
            // Back button
            if viewModel.currentStep != .welcome && viewModel.currentStep != .complete {
                Button {
                    viewModel.goToPrevious()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "chevron.left")
                        Text("Back")
                    }
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .disabled(viewModel.isDownloading && viewModel.currentStep == .download)
            }

            Spacer()

            // Next/Skip button
            if viewModel.currentStep == .welcome {
                Button {
                    viewModel.goToNext()
                } label: {
                    HStack(spacing: 6) {
                        Text("Get Started")
                        Image(systemName: "chevron.right")
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            } else if viewModel.currentStep == .modelSelection {
                Button {
                    viewModel.goToNext()
                } label: {
                    HStack(spacing: 6) {
                        Text("Download & Continue")
                        Image(systemName: "arrow.down.circle")
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(!viewModel.hasEnoughSpace)
            } else if viewModel.currentStep == .download && !viewModel.isComplete {
                // Show nothing or cancel during download
                if viewModel.isDownloading {
                    Button(role: .destructive) {
                        viewModel.cancelDownload()
                        viewModel.goToPrevious()
                    } label: {
                        Text("Cancel")
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
    }
}

// MARK: - Preview

#Preview {
    SetupWizardView {
        print("Setup complete!")
    }
}
