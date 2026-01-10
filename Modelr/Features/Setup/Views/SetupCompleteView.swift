import SwiftUI

/// Completion step of the setup wizard
struct SetupCompleteView: View {
    @EnvironmentObject var viewModel: SetupWizardViewModel
    var onContinue: () -> Void

    @State private var showConfetti = false
    @State private var iconScale: CGFloat = 0.5
    @State private var iconOpacity: CGFloat = 0

    var body: some View {
        VStack(spacing: 32) {
            Spacer()

            // Success animation
            successAnimation

            // Title
            VStack(spacing: 8) {
                Text("You're All Set!")
                    .font(.largeTitle.bold())

                Text("Modelr is ready to transform your images into 3D")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }

            // What's next section
            whatNextSection
                .padding(.horizontal, 60)

            Spacer()

            // Continue button
            Button {
                onContinue()
            } label: {
                HStack(spacing: 8) {
                    Text("Start Creating")
                    Image(systemName: "arrow.right")
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .padding(.bottom, 40)
        }
        .onAppear {
            // Animate in
            withAnimation(.spring(response: 0.6, dampingFraction: 0.7).delay(0.1)) {
                iconScale = 1.0
                iconOpacity = 1.0
            }
            withAnimation(.easeOut(duration: 0.5).delay(0.3)) {
                showConfetti = true
            }
        }
    }

    // MARK: - Success Animation

    @ViewBuilder
    private var successAnimation: some View {
        ZStack {
            // Confetti particles (simplified)
            if showConfetti {
                ForEach(0..<12, id: \.self) { index in
                    confettiParticle(index: index)
                }
            }

            // Success checkmark
            ZStack {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [.green, .green.opacity(0.8)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 100, height: 100)
                    .shadow(color: .green.opacity(0.3), radius: 20, y: 10)

                Image(systemName: "checkmark")
                    .font(.system(size: 48, weight: .bold))
                    .foregroundStyle(.white)
            }
            .scaleEffect(iconScale)
            .opacity(iconOpacity)
        }
        .frame(width: 200, height: 200)
    }

    @ViewBuilder
    private func confettiParticle(index: Int) -> some View {
        let colors: [Color] = [.blue, .green, .orange, .purple, .pink, .yellow]
        let angle = Double(index) * (360.0 / 12.0)
        let distance: CGFloat = 80

        Circle()
            .fill(colors[index % colors.count])
            .frame(width: 8, height: 8)
            .offset(
                x: cos(angle * .pi / 180) * distance,
                y: sin(angle * .pi / 180) * distance
            )
            .opacity(showConfetti ? 0 : 1)
            .scaleEffect(showConfetti ? 0.3 : 1)
            .animation(
                .easeOut(duration: 0.8)
                .delay(Double(index) * 0.05),
                value: showConfetti
            )
    }

    // MARK: - What's Next Section

    @ViewBuilder
    private var whatNextSection: some View {
        VStack(spacing: 16) {
            Text("What's Next")
                .font(.headline)
                .foregroundStyle(.secondary)

            HStack(spacing: 24) {
                nextStepCard(
                    icon: "photo",
                    title: "Load an Image",
                    description: "Drop or select an image to start"
                )

                nextStepCard(
                    icon: "wand.and.stars",
                    title: "Segment Object",
                    description: "AI will detect your subject"
                )

                nextStepCard(
                    icon: "cube",
                    title: "Generate 3D",
                    description: "Create your 3D model"
                )
            }
        }
    }

    @ViewBuilder
    private func nextStepCard(icon: String, title: String, description: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: icon)
                .font(.title)
                .foregroundStyle(.blue)

            VStack(spacing: 4) {
                Text(title)
                    .font(.callout.weight(.medium))
                Text(description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .padding()
        .background(Color.primary.opacity(0.03))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

// MARK: - Preview

#Preview {
    SetupCompleteView {
        print("Continue tapped")
    }
    .environmentObject(SetupWizardViewModel())
    .frame(width: 700, height: 550)
}
