import SwiftUI

/// Completion step - clean success state
struct SetupCompleteView: View {
    @EnvironmentObject var viewModel: SetupWizardViewModel
    var onContinue: () -> Void
    @State private var hasAppeared = false

    // MARK: - Constants
    private enum Constants {
        static let successCircleSize: CGFloat = 80
        static let checkmarkSize: CGFloat = 36
        static let initialScale: CGFloat = 0.6
        static let animationOffset: CGFloat = 8
        static let buttonMinWidth: CGFloat = 120
    }

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            // Success content
            VStack(spacing: AppDesign.Spacing.p24) {
                successIcon
                titleSection
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Setup complete. Modelr is ready to use.")

            Spacer()

            continueButton
        }
        .onAppear {
            hasAppeared = true
        }
    }

    // MARK: - Success Icon

    private var successIcon: some View {
        ZStack {
            Circle()
                .fill(AppDesign.success.opacity(AppDesign.Opacity.medium))
                .frame(width: Constants.successCircleSize, height: Constants.successCircleSize)
                .scaleEffect(hasAppeared ? 1 : Constants.initialScale)
                .opacity(hasAppeared ? 1 : 0)

            Image(systemName: "checkmark")
                .font(.system(size: Constants.checkmarkSize, weight: .medium))
                .foregroundStyle(AppDesign.success)
                .scaleEffect(hasAppeared ? 1 : Constants.initialScale)
                .opacity(hasAppeared ? 1 : 0)
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.65).delay(0.1), value: hasAppeared)
        .accessibilityHidden(true)
    }

    // MARK: - Title Section

    private var titleSection: some View {
        VStack(spacing: AppDesign.Spacing.p6) {
            Text("Ready")
                .font(.system(size: AppDesign.FontSize.title2, weight: .semibold))
                .lineLimit(1)
                .opacity(hasAppeared ? 1 : 0)
                .offset(y: hasAppeared ? 0 : Constants.animationOffset)

            Text("Modelr is set up and ready to use")
                .font(.system(size: AppDesign.FontSize.headline))
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .opacity(hasAppeared ? 1 : 0)
                .offset(y: hasAppeared ? 0 : Constants.animationOffset)
        }
        .animation(.easeOut(duration: 0.3).delay(0.25), value: hasAppeared)
    }

    // MARK: - Continue Button

    private var continueButton: some View {
        Button {
            onContinue()
        } label: {
            Text("Start Using Modelr")
                .frame(minWidth: Constants.buttonMinWidth)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .opacity(hasAppeared ? 1 : 0)
        .animation(.easeOut(duration: 0.25).delay(0.4), value: hasAppeared)
        .padding(.bottom, AppDesign.Spacing.p32)
        .accessibilityLabel("Start Using Modelr")
        .accessibilityHint("Opens the main application")
    }
}

// MARK: - Preview

#Preview {
    SetupCompleteView(onContinue: {})
        .environmentObject(SetupWizardViewModel())
        .frame(width: 560, height: 420)
        .background(Color(nsColor: .windowBackgroundColor))
}
