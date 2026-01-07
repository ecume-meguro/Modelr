import SwiftUI

/// Toolbar content for the editor window
struct EditorToolbarContent: View {
    @ObservedObject var viewModel: SimpleEditorViewModel

    var body: some View {
        HStack(spacing: AppDesign.Spacing.p16) {
            // Resolution badge (when image loaded)
            if viewModel.inputImage != nil {
                resolutionBadge
            }

            Spacer()

            // View mode picker (only when 3D model is ready)
            if viewModel.generated3DModelURL != nil {
                viewModePicker
            }
        }
    }

    @ViewBuilder
    private var resolutionBadge: some View {
        let width = Int(viewModel.imagePixelSize.width)
        let height = Int(viewModel.imagePixelSize.height)

        HStack(spacing: AppDesign.Spacing.p4) {
            Image(systemName: "photo")
                .font(.system(size: AppDesign.FontSize.caption))
                .foregroundStyle(.tertiary)

            Text("\(width) × \(height)")
                .font(.system(size: AppDesign.FontSize.caption, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var viewModePicker: some View {
        HStack(spacing: 2) {
            ForEach(SimpleEditorViewModel.ViewMode.allCases, id: \.self) { mode in
                Button {
                    viewModel.viewMode = mode
                } label: {
                    Text(mode.rawValue)
                        .font(.system(size: AppDesign.FontSize.caption, weight: viewModel.viewMode == mode ? .semibold : .regular))
                        .foregroundStyle(viewModel.viewMode == mode ? .primary : .secondary)
                        .padding(.horizontal, AppDesign.Spacing.p8)
                        .padding(.vertical, AppDesign.Spacing.p4)
                        .background(
                            viewModel.viewMode == mode ? Color.primary.opacity(0.1) : Color.clear,
                            in: RoundedRectangle(cornerRadius: 4)
                        )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
    }
}
