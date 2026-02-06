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

    // Debounce tasks to prevent concurrent mesh operations during slider drag
    @State private var voxelDebounceTask: Task<Void, Never>?
    @State private var lowPolyDebounceTask: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: AppDesign.Spacing.p16) {
            // Header with info
            headerSection

            // Type picker and clear button row
            HStack(alignment: .center, spacing: AppDesign.Spacing.p12) {
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
                .offset(x: -3)
                .onChange(of: selection) { _, newValue in
                    // Reset values when switching
                    viewModel.voxelResolution = 0
                    viewModel.lowPolyReduction = 0
                    viewModel.modifiedModelURL = nil
                    viewModel.modifyType = newValue == .voxelize ? .voxelize : .lowPoly
                }

                // Clear modifications button (show when modifications are active)
                if viewModel.modifiedModelURL != nil {
                    Button {
                        viewModel.voxelResolution = 0
                        viewModel.lowPolyReduction = 0
                        viewModel.modifyType = .none
                        viewModel.modifiedModelURL = nil
                        viewModel.originalFaceCount = 0
                        viewModel.modifiedFaceCount = 0
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 16))
                            .symbolRenderingMode(.hierarchical)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Clear modifications")
                }

                Spacer()
            }
            .frame(maxWidth: .infinity, alignment: .leading)

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

            // Export section (show when there's a model to export)
            if viewModel.modifiedModelURL != nil || viewModel.processedModelURL != nil || viewModel.generated3DModelURL != nil {
                Divider()
                    .padding(.vertical, AppDesign.Spacing.p4)

                exportSection
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
            // Slider with editable text field (0 = off, 0.015-0.085 = voxel pitch, minimum 0.015 to prevent timeouts)
            VStack(alignment: .leading, spacing: AppDesign.Spacing.p4) {
                EditableSliderRow(
                    label: "Voxel Size",
                    value: $viewModel.voxelResolution,
                    range: 0...0.085,
                    step: 0.001,
                    format: "%.3f",
                    minimumValue: 0.015
                )

                // Semantic detail level indicator
                HStack(spacing: AppDesign.Spacing.p6) {
                    Text(voxelDetailLabel)
                        .font(.system(size: AppDesign.FontSize.xs, weight: .medium))
                        .foregroundStyle(voxelDetailColor)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(voxelDetailColor.opacity(0.15), in: RoundedRectangle(cornerRadius: 4))
                }
            }
            .onChange(of: viewModel.voxelResolution) { _, newValue in
                // Snap to 0.015 minimum if user tries to set below (but allow 0 for disabled)
                if newValue > 0 && newValue < 0.015 {
                    viewModel.voxelResolution = 0.015
                    return
                }

                // Cancel previous debounce task
                voxelDebounceTask?.cancel()

                if newValue >= 0.015 {
                    // Clear low poly when using voxelize
                    viewModel.lowPolyReduction = 0
                    viewModel.modifyType = .voxelize

                    // Debounce with 300ms delay to prevent concurrent processes during slider drag
                    voxelDebounceTask = Task {
                        try? await Task.sleep(nanoseconds: 300_000_000) // 300ms
                        guard !Task.isCancelled else { return }

                        await viewModel.applyVoxelization()
                    }
                } else if viewModel.modifyType == .voxelize {
                    viewModel.modifyType = .none
                    viewModel.modifiedModelURL = nil
                }
            }

            // Tip with tooltip
            HStack(spacing: AppDesign.Spacing.p6) {
                Image(systemName: "info.circle")
                    .font(.system(size: AppDesign.FontSize.caption))
                    .foregroundStyle(.secondary)
                    .help("Voxel size controls the resolution of voxelization. Smaller values create more detailed voxels but take longer to process. Values: 0.015-0.030 = Very detailed, 0.030-0.050 = Medium detail, 0.050-0.085 = Low detail (blocky).")
                Text("Smaller = more detail. Minimum 0.015. Set to 0 to disable.")
                    .font(.system(size: AppDesign.FontSize.xs))
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// Semantic label for voxel detail level
    private var voxelDetailLabel: String {
        let v = viewModel.voxelResolution
        if v == 0 { return "Disabled" }
        if v <= 0.025 { return "Very Detailed" }
        if v <= 0.040 { return "Medium Detail" }
        if v <= 0.060 { return "Low Detail" }
        return "Very Blocky"
    }

    /// Color for voxel detail level
    private var voxelDetailColor: Color {
        let v = viewModel.voxelResolution
        if v == 0 { return .secondary }
        if v <= 0.025 { return AppDesign.success }
        if v <= 0.040 { return AppDesign.accent }
        if v <= 0.060 { return AppDesign.warning }
        return AppDesign.destructive
    }

    // MARK: - Low Poly Settings

    @ViewBuilder
    private var lowPolySettings: some View {
        VStack(alignment: .leading, spacing: AppDesign.Spacing.p12) {
            // Slider with editable text field (0 = off, up to 99.9% reduction for extremely low poly)
            EditableSliderRow(
                label: "Reduction",
                value: $viewModel.lowPolyReduction,
                range: 0...99.9,
                step: 0.1,
                format: "%.1f",
                valueSuffix: "%"
            )
            .onChange(of: viewModel.lowPolyReduction) { _, newValue in
                // Cancel previous debounce task
                lowPolyDebounceTask?.cancel()

                if newValue > 0 {
                    // Clear voxelize when using low poly
                    viewModel.voxelResolution = 0
                    viewModel.modifyType = .lowPoly

                    // Debounce with 300ms delay to prevent concurrent processes during slider drag
                    lowPolyDebounceTask = Task {
                        try? await Task.sleep(nanoseconds: 300_000_000) // 300ms
                        guard !Task.isCancelled else { return }

                        await viewModel.applyLowPoly()
                    }
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
                Text("Higher = fewer polygons. Uses exponential scaling for better control at lower values.")
                    .font(.system(size: AppDesign.FontSize.xs))
                    .foregroundStyle(.secondary)
            }

            // Face count preview (real-time estimate while dragging)
            if viewModel.lowPolyReduction > 0 {
                faceCountPreview
            }

            // Face count stats (show when modified)
            if viewModel.modifiedFaceCount > 0 {
                faceCountStats
            }
        }
    }

    // MARK: - Face Count Preview (Real-time Estimate)

    @ViewBuilder
    private var faceCountPreview: some View {
        if viewModel.originalFaceCount > 0 {
            // Calculate estimated face count based on reduction percentage
            // Using exponential scaling similar to the actual reduction algorithm
            let reductionFactor = pow(viewModel.lowPolyReduction / 100.0, 1.5)
            let estimatedFaces = Int(Double(viewModel.originalFaceCount) * (1.0 - reductionFactor))
            let displayFaces = max(100, estimatedFaces) // Minimum reasonable face count

            HStack(spacing: AppDesign.Spacing.p8) {
                Image(systemName: "chart.line.downtrend.xyaxis")
                    .font(.system(size: AppDesign.FontSize.caption))
                    .foregroundStyle(AppDesign.accent)
                Text("Estimated: ~\(formatNumber(displayFaces)) faces")
                    .font(.system(size: AppDesign.FontSize.xs, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, AppDesign.Spacing.p8)
            .padding(.vertical, AppDesign.Spacing.p6)
            .background(AppDesign.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
            .animation(.easeOut(duration: 0.15), value: viewModel.lowPolyReduction)
        }
    }

    // MARK: - Face Count Stats

    @ViewBuilder
    private var faceCountStats: some View {
        VStack(alignment: .leading, spacing: AppDesign.Spacing.p6) {
            HStack(spacing: AppDesign.Spacing.p12) {
                statItem(label: "Original", value: formatNumber(viewModel.originalFaceCount))
                Image(systemName: "arrow.right")
                    .font(.system(size: AppDesign.FontSize.caption))
                    .foregroundStyle(.tertiary)
                statItem(label: "Modified", value: formatNumber(viewModel.modifiedFaceCount))
            }

            if viewModel.originalFaceCount > 0 {
                let reductionPercent = Double(viewModel.originalFaceCount - viewModel.modifiedFaceCount) / Double(viewModel.originalFaceCount) * 100
                Text("Reduced by \(String(format: "%.1f", reductionPercent))%")
                    .font(.system(size: AppDesign.FontSize.xs))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(AppDesign.Spacing.p8)
        .background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        )
    }

    @ViewBuilder
    private func statItem(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.system(size: AppDesign.FontSize.body, weight: .medium, design: .monospaced))
            Text(label)
                .font(.system(size: AppDesign.FontSize.xs))
                .foregroundStyle(.tertiary)
        }
    }

    private func formatNumber(_ num: Int) -> String {
        if num >= 1_000_000 {
            return String(format: "%.1fM", Double(num) / 1_000_000)
        } else if num >= 1_000 {
            return String(format: "%.1fK", Double(num) / 1_000)
        }
        return "\(num)"
    }

    // MARK: - Export Section

    @ViewBuilder
    private var exportSection: some View {
        VStack(alignment: .leading, spacing: AppDesign.Spacing.p8) {
            // Export header with format info button
            HStack {
                AppDesign.SectionLabel("Export")
                Spacer()
                // Format comparison info button
                Button {
                    // Shows tooltip on hover, this is the visual indicator
                } label: {
                    Image(systemName: "info.circle")
                        .font(.system(size: AppDesign.FontSize.caption))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help(formatComparisonTooltip)
            }

            FlowLayout(spacing: AppDesign.Spacing.p6) {
                ForEach(ExportFormat.allCases) { format in
                    formatButton(format)
                }
            }

            // Selected format description
            Text(formatDescription(for: viewModel.selectedExportFormat))
                .font(.system(size: AppDesign.FontSize.xs))
                .foregroundStyle(.tertiary)
                .padding(.top, AppDesign.Spacing.p2)

            AppDesign.GlassButton("Export \(viewModel.selectedExportFormat.rawValue)", icon: "square.and.arrow.up") {
                exportMesh()
            }
            .disabled(viewModel.isProcessingMesh || viewModel.isModifyingMesh)
        }
    }

    /// Tooltip explaining format differences
    private var formatComparisonTooltip: String {
        """
        Format Comparison:

        OBJ - Universal compatibility, separate texture files. Best for: most 3D software, game engines.

        GLB - Single file with embedded textures, efficient. Best for: web/AR, Unity, Unreal.

        STL - Geometry only, no textures/colors. Best for: 3D printing, CAD software.

        PLY - Point cloud and mesh support. Best for: scientific visualization, photogrammetry.
        """
    }

    /// Brief description for selected format
    private func formatDescription(for format: ExportFormat) -> String {
        switch format {
        case .obj: return "Universal format - works with most 3D software"
        case .glb: return "Single file with textures - great for web/AR"
        case .stl: return "Geometry only - ideal for 3D printing"
        case .ply: return "Mesh/point cloud - scientific visualization"
        }
    }

    @ViewBuilder
    private func formatButton(_ format: ExportFormat) -> some View {
        let isSelected = viewModel.selectedExportFormat == format

        Button {
            viewModel.selectedExportFormat = format
        } label: {
            Text(format.rawValue)
                .font(.system(size: AppDesign.FontSize.caption, weight: isSelected ? .semibold : .regular))
                .padding(.horizontal, AppDesign.Spacing.p10)
                .padding(.vertical, AppDesign.Spacing.p6)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(isSelected ? AppDesign.accent.opacity(0.2) : Color.primary.opacity(0.05))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(isSelected ? AppDesign.accent : Color.primary.opacity(0.1), lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .foregroundStyle(isSelected ? AppDesign.accent : .primary)
        .help(formatDescription(for: format))
    }

    private func exportMesh() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.item]

        // Use project name if available, otherwise fallback to "model"
        let defaultName: String
        if let projectId = viewModel.projectId,
           let project = try? ProjectManager.shared.loadProject(id: projectId) {
            defaultName = project.name
        } else {
            defaultName = "model"
        }
        panel.nameFieldStringValue = "\(defaultName).\(viewModel.selectedExportFormat.fileExtension)"
        panel.canCreateDirectories = true

        if panel.runModal() == .OK, let url = panel.url {
            Task { @MainActor in
                let success = await viewModel.exportMesh(to: url)
                if success {
                    NSWorkspace.shared.selectFile(url.path, inFileViewerRootedAtPath: url.deletingLastPathComponent().path)
                } else {
                    // Show error alert on failure
                    viewModel.handleError(AppError.meshProcessing("Failed to export mesh to \(url.lastPathComponent)"))
                }
            }
        }
    }
}

// MARK: - Editable Slider Row

/// A slider with an editable text field for precise value input
struct EditableSliderRow: View {
    let label: String
    @Binding var value: CGFloat
    let range: ClosedRange<CGFloat>
    var step: CGFloat = 1
    var format: String = "%.1f"
    var valueSuffix: String = ""
    var minimumValue: CGFloat? = nil  // Optional minimum value enforcement (for voxelization)

    @State private var textValue: String = ""
    @FocusState private var isTextFieldFocused: Bool

    private var formattedValue: String {
        String(format: format, Double(value)) + valueSuffix
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppDesign.Spacing.p4) {
            HStack {
                Text(label)
                    .font(.system(size: AppDesign.FontSize.subheadline))
                    .foregroundStyle(.secondary)
                Spacer()

                // Editable text field
                TextField("", text: $textValue)
                    .font(.system(size: AppDesign.FontSize.subheadline, weight: .medium, design: .monospaced))
                    .multilineTextAlignment(.trailing)
                    .frame(width: 60)
                    .textFieldStyle(.plain)
                    .focused($isTextFieldFocused)
                    .onAppear {
                        textValue = formattedValue
                    }
                    .onChange(of: value) { (oldValue: CGFloat, newValue: CGFloat) in
                        // If user is dragging slider while text field is focused, blur it
                        if isTextFieldFocused && oldValue != newValue {
                            isTextFieldFocused = false
                        }
                        // Update text display when not focused
                        if !isTextFieldFocused {
                            textValue = formattedValue
                        }
                    }
                    .onSubmit {
                        commitTextValue()
                        isTextFieldFocused = false
                    }
                    .onChange(of: isTextFieldFocused) { _, focused in
                        if !focused {
                            commitTextValue()
                        } else {
                            // When focused, remove suffix for easier editing
                            textValue = String(format: format, Double(value))
                        }
                    }
            }

            Slider(value: $value, in: range, step: step)
                .controlSize(.small)
                .simultaneousGesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { _ in
                            // Blur text field when user starts dragging slider
                            if isTextFieldFocused {
                                isTextFieldFocused = false
                            }
                        }
                )
        }
    }

    private func commitTextValue() {
        // Parse the text input
        let cleanedText = textValue.replacingOccurrences(of: valueSuffix, with: "").trimmingCharacters(in: .whitespaces)

        if let parsedValue = Double(cleanedText) {
            var newValue = CGFloat(parsedValue)

            // Apply minimum value constraint if set (for voxelization 0.015 minimum)
            if let minValue = minimumValue, newValue > 0 && newValue < minValue {
                newValue = minValue
            }

            // Clamp to range
            newValue = min(max(newValue, range.lowerBound), range.upperBound)

            value = newValue
            textValue = formattedValue
        } else {
            // Invalid input - revert to current value
            textValue = formattedValue
        }
    }
}
