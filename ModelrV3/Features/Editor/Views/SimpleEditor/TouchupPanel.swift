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
            
            AppDesign.SliderRow(
                label: "Brush Size",
                value: $viewModel.brushSize,
                range: 1...150,
                valueSuffix: "px"
            )
            
            HStack(alignment: .top, spacing: AppDesign.Spacing.p8) {
                AppDesign.HintText("Paint on the image to refine the mask edges")
                Spacer()
                AppDesign.InlineButton("Undo", icon: "arrow.uturn.backward") {
                    viewModel.undo()
                }
                .opacity(viewModel.maskHistory.isEmpty ? 0.4 : 1.0)
                .disabled(viewModel.maskHistory.isEmpty)
            }
        }
    }
}
