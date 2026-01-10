import SwiftUI

/// Model selection step of the setup wizard (Hunyuan-only)
struct SetupModelSelectionView: View {
    @Binding var selectedChoice: SetupModelChoice

    var body: some View {
        VStack(spacing: 24) {
            // Header
            VStack(spacing: 8) {
                Text("Choose a Model")
                    .font(.title.bold())
                Text("Select which Hunyuan3D model to download")
                    .font(.body)
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 32)

            // Model cards
            ScrollView {
                VStack(spacing: 12) {
                    ForEach(SetupModelChoice.allCases, id: \.self) { choice in
                        ModelChoiceCard(
                            choice: choice,
                            isSelected: selectedChoice == choice,
                            onSelect: {
                                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                                    selectedChoice = choice
                                }
                            }
                        )
                    }
                }
                .padding(.horizontal, 60)
            }

            Spacer()
        }
    }
}

// MARK: - Model Choice Card

private struct ModelChoiceCard: View {
    let choice: SetupModelChoice
    let isSelected: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 16) {
                // Selection indicator
                ZStack {
                    Circle()
                        .stroke(isSelected ? Color.accentColor : Color.primary.opacity(0.2), lineWidth: 2)
                        .frame(width: 24, height: 24)

                    if isSelected {
                        Circle()
                            .fill(Color.accentColor)
                            .frame(width: 14, height: 14)
                            .transition(.scale.combined(with: .opacity))
                    }
                }

                // Model icon
                ZStack {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.blue.opacity(0.15))
                        .frame(width: 44, height: 44)

                    Image(systemName: "cube.transparent")
                        .font(.title2)
                        .foregroundStyle(.blue)
                }

                // Model info
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(choice.displayName)
                            .font(.headline)
                            .foregroundStyle(.primary)

                        if choice == .fast {
                            Text("Recommended")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(Color.green, in: Capsule())
                        }
                    }

                    Text(choice.description)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                Spacer()

                // Size
                VStack(alignment: .trailing, spacing: 2) {
                    Text(choice.formattedSize)
                        .font(.callout.weight(.medium))
                        .foregroundStyle(.primary)
                }
            }
            .padding()
            .background(isSelected ? Color.accentColor.opacity(0.08) : Color.primary.opacity(0.03))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(isSelected ? Color.accentColor : Color.primary.opacity(0.08), lineWidth: isSelected ? 2 : 1)
            )
        }
        .buttonStyle(.plain)
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: isSelected)
    }
}

// MARK: - Preview

#Preview {
    SetupModelSelectionView(selectedChoice: .constant(.fast))
        .frame(width: 700, height: 550)
}
