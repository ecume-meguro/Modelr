import SwiftUI

/// Modify panel for voxelization and low poly reduction
struct ModifyPanel: View {
    @ObservedObject var viewModel: SimpleEditorViewModel

    /// Simplified modify type for picker (only voxelize or low poly)
    private enum ModifySelection: String, CaseIterable {
        case voxelize = "Voxelize"
        case lowPoly = "Low Poly"
    }

    @State private var selection: ModifySelection = .voxelize

    var body: some View {
        VStack(alignment: .leading, spacing: AppDesign.Spacing.p16) {
            // Header with info
            headerSection

            // Type picker (Voxelize or Low Poly) - left aligned
            // Note: macOS segmented controls have ~3pt internal leading padding,
            // so we use negative offset to align visually with text content
            Picker("", selection: $selection) {
                ForEach(ModifySelection.allCases, id: \.self) { type in
                    Text(type.rawValue).tag(type)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .fixedSize()
            .frame(maxWidth: .infinity, alignment: .leading)
            .offset(x: -3)
            .onChange(of: selection) { _, newValue in
                // Reset values when switching
                viewModel.voxelResolution = 0
                viewModel.lowPolyReduction = 0
                viewModel.modifiedModelURL = nil
                viewModel.modifyType = newValue == .voxelize ? .voxelize : .lowPoly
            }

            // Settings based on selected type
            if selection == .voxelize {
                voxelizeSettings
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                lowPolySettings
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            // Processing indicator
            if viewModel.isModifyingMesh {
                Divider()
                    .padding(.vertical, AppDesign.Spacing.p4)

                HStack(spacing: AppDesign.Spacing.p8) {
                    ProgressView()
                        .scaleEffect(0.7)
                    Text("Processing mesh...")
                        .font(.system(size: AppDesign.FontSize.caption))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: - Header

    @ViewBuilder
    private var headerSection: some View {
        Text("Modify your mesh with voxelization or polygon reduction.")
            .font(.system(size: AppDesign.FontSize.caption))
            .foregroundStyle(.secondary)
    }

    // MARK: - Voxelize Settings

    @ViewBuilder
    private var voxelizeSettings: some View {
        VStack(alignment: .leading, spacing: AppDesign.Spacing.p12) {
            // Slider (0 = off, up to 0.085 = voxel pitch)
            AppDesign.SliderRow(
                label: "Voxel Size",
                value: $viewModel.voxelResolution,
                range: 0...0.085,
                step: 0.001,
                format: "%.3f"
            )
            .onChange(of: viewModel.voxelResolution) { _, newValue in
                if newValue > 0 {
                    // Clear low poly when using voxelize
                    viewModel.lowPolyReduction = 0
                    viewModel.modifyType = .voxelize
                    Task { await viewModel.applyVoxelization() }
                } else if viewModel.modifyType == .voxelize {
                    viewModel.modifyType = .none
                    viewModel.modifiedModelURL = nil
                }
            }

            // Tip
            HStack(spacing: AppDesign.Spacing.p6) {
                Image(systemName: "info.circle")
                    .font(.system(size: AppDesign.FontSize.caption))
                    .foregroundStyle(.secondary)
                Text("Smaller values = more detail. Set to 0 to disable.")
                    .font(.system(size: AppDesign.FontSize.xs))
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Low Poly Settings

    @ViewBuilder
    private var lowPolySettings: some View {
        VStack(alignment: .leading, spacing: AppDesign.Spacing.p12) {
            // Slider (0 = off, up to 99.9% reduction for extremely low poly)
            AppDesign.SliderRow(
                label: "Reduction",
                value: $viewModel.lowPolyReduction,
                range: 0...99.9,
                step: 0.1,
                valueSuffix: "%"
            )
            .onChange(of: viewModel.lowPolyReduction) { _, newValue in
                if newValue > 0 {
                    // Clear voxelize when using low poly
                    viewModel.voxelResolution = 0
                    viewModel.modifyType = .lowPoly
                    Task { await viewModel.applyLowPoly() }
                } else if viewModel.modifyType == .lowPoly {
                    viewModel.modifyType = .none
                    viewModel.modifiedModelURL = nil
                }
            }

            // Tip
            HStack(spacing: AppDesign.Spacing.p6) {
                Image(systemName: "info.circle")
                    .font(.system(size: AppDesign.FontSize.caption))
                    .foregroundStyle(.secondary)
                Text("Higher = fewer polygons. At 99.9%, only 0.1% of faces remain.")
                    .font(.system(size: AppDesign.FontSize.xs))
                    .foregroundStyle(.secondary)
            }
        }
    }
}
