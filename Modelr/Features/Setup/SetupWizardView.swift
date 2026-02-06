import SwiftUI

/// Native macOS setup wizard - functional desktop utility design
struct SetupWizardView: View {
    @StateObject private var viewModel = SetupWizardViewModel()
    @State private var showCancelConfirmation = false
    var onComplete: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            // Step progress indicator at the top
            stepProgressIndicator
                .padding(.top, 16)
                .padding(.horizontal, 32)

            contentView
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .onChange(of: viewModel.isComplete) { _, isComplete in
            if isComplete {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    onComplete()
                }
            }
        }
        .alert("Cancel Download?", isPresented: $showCancelConfirmation) {
            Button("Continue Download", role: .cancel) { }
            Button("Cancel", role: .destructive) {
                viewModel.cancelDownload()
                withAnimation(.easeInOut(duration: 0.2)) {
                    viewModel.goToPrevious()
                }
            }
        } message: {
            Text("Are you sure you want to cancel the download? You can resume later, but some progress may be lost.")
        }
    }

    // MARK: - Step Progress Indicator

    private var stepProgressIndicator: some View {
        HStack(spacing: 8) {
            ForEach(SetupWizardStep.allCases, id: \.rawValue) { step in
                if step != .complete {
                    stepDot(for: step)

                    // Show connector after each step except the last visible step (download)
                    if step.rawValue < SetupWizardStep.complete.rawValue - 1 {
                        stepConnector(isCompleted: viewModel.currentStep.rawValue > step.rawValue)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity)
        .fixedSize(horizontal: true, vertical: false)
    }

    private func stepDot(for step: SetupWizardStep) -> some View {
        let isActive = viewModel.currentStep == step
        let isCompleted = viewModel.currentStep.rawValue > step.rawValue

        // Accessibility hint based on step status
        let accessibilityHint: String = {
            if isCompleted {
                return "Completed"
            } else if isActive {
                return "Current step"
            } else {
                return "Not yet started"
            }
        }()

        return VStack(spacing: 4) {
            ZStack {
                Circle()
                    .fill(isCompleted ? Color.green : (isActive ? Color.accentColor : Color.primary.opacity(0.1)))
                    .frame(width: AppConstants.progressBarHeight * 2, height: AppConstants.progressBarHeight * 2)

                if isCompleted {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white)
                } else {
                    Text("\(step.rawValue + 1)")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(isActive ? .white : .secondary)
                }
            }
            .accessibilityLabel("Step \(step.rawValue + 1): \(step.title)")
            .accessibilityHint(accessibilityHint)

            Text(step.title)
                .font(.system(size: 10))
                .foregroundStyle(isActive ? .primary : .secondary)
        }
    }

    private func stepConnector(isCompleted: Bool) -> some View {
        Rectangle()
            .fill(isCompleted ? Color.green : Color.primary.opacity(0.15))
            .frame(width: 20, height: AppConstants.boundingBoxLineWidth)
            .offset(y: -8)
    }

    @ViewBuilder
    private var contentView: some View {
        Group {
            switch viewModel.currentStep {
            case .welcome:
                SetupWelcomeView {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        viewModel.goToNext()
                    }
                }
                .environmentObject(viewModel)

            case .download:
                SetupDownloadView(
                    onCancel: {
                        // Show confirmation dialog before cancelling during download
                        if viewModel.isDownloading {
                            showCancelConfirmation = true
                        } else {
                            // If not actively downloading (e.g., error state), go back directly
                            withAnimation(.easeInOut(duration: 0.2)) {
                                viewModel.goToPrevious()
                            }
                        }
                    }
                )
                .environmentObject(viewModel)

            case .complete:
                SetupCompleteView(onContinue: onComplete)
                    .environmentObject(viewModel)
            }
        }
        .transition(.opacity.animation(.easeInOut(duration: 0.2)))
    }
}

#Preview {
    SetupWizardView {
        print("Setup complete!")
    }
}
