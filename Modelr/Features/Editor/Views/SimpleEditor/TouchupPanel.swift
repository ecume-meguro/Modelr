import SwiftUI

/// Touchup panel for ContentViewSimple
struct TouchupPanel: View {
    @ObservedObject var viewModel: SimpleEditorViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: AppDesign.Spacing.p16) {
            VStack(alignment: .leading, spacing: AppDesign.Spacing.p8) {
                AppDesign.SectionLabel("Mode")
                HStack(spacing: AppDesign.Spacing.p8) {
                    AppDesign.GlassToggle(
                        title: "Add",
                        icon: "plus.circle.fill",
                        isSelected: viewModel.brushMode == .add,
                        tint: .green
                    ) {
                        viewModel.brushMode = .add
                    }
                    AppDesign.GlassToggle(
                        title: "Remove",
                        icon: "minus.circle.fill",
                        isSelected: viewModel.brushMode == .remove,
                        tint: .red
                    ) {
                        viewModel.brushMode = .remove
                    }
                }
            }

            // Brush size slider with visual preview
            VStack(alignment: .leading, spacing: AppDesign.Spacing.p8) {
                AppDesign.SliderRow(
                    label: "Brush Size",
                    value: $viewModel.brushSize,
                    range: 1...150,
                    valueSuffix: "px"
                )

                // Brush preview circle
                HStack {
                    Spacer()
                    ZStack {
                        // Background circle for contrast
                        Circle()
                            .fill(Color.primary.opacity(0.05))
                            .frame(width: 60, height: 60)

                        // Brush preview (scaled to fit in preview area)
                        let previewSize = min(viewModel.brushSize * 0.4, 50)
                        Circle()
                            .stroke(viewModel.brushMode == .add ? AppDesign.success : AppDesign.eraserColor, lineWidth: 2)
                            .frame(width: previewSize, height: previewSize)
                            .background(
                                Circle()
                                    .fill((viewModel.brushMode == .add ? AppDesign.success : AppDesign.eraserColor).opacity(0.15))
                            )
                    }
                    Spacer()
                }
            }

            HStack(alignment: .top, spacing: AppDesign.Spacing.p8) {
                AppDesign.HintText("Paint on the image to refine the mask edges")
                Spacer()
                // Undo button with keyboard shortcut hint
                Button {
                    viewModel.undo()
                } label: {
                    HStack(spacing: AppDesign.Spacing.p4) {
                        Image(systemName: "arrow.uturn.backward")
                            .font(.system(size: AppDesign.FontSize.caption))
                        Text("Undo")
                            .font(.system(size: AppDesign.FontSize.subheadline, weight: .medium))
                        // Keyboard shortcut hint
                        Text("Cmd+Z")
                            .font(.system(size: AppDesign.FontSize.xs, design: .monospaced))
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 2)
                            .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 3))
                    }
                    .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .opacity(viewModel.maskHistory.isEmpty ? 0.4 : 1.0)
                .disabled(viewModel.maskHistory.isEmpty)
            }
        }
    }
}
