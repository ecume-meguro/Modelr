import SwiftUI

/// Post-process panel for mesh component management and export
struct PostProcessPanel: View {
    @ObservedObject var viewModel: SimpleEditorViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: AppDesign.Spacing.p16) {
            if viewModel.isAnalyzingMesh {
                analyzingView
            } else if viewModel.meshComponents.isEmpty {
                noComponentsView
            } else {
                componentListView

                // Only show action buttons section when multiple components
                if viewModel.meshComponents.count > 1 {
                    Divider().padding(.vertical, AppDesign.Spacing.p4)
                    actionButtonsView
                }

                Divider().padding(.vertical, AppDesign.Spacing.p4)
                exportSection
            }
        }
        // Confirmation alerts
        .alert("Delete Components?", isPresented: $viewModel.showDeleteSelectedConfirmation) {
            Button("Cancel", role: .cancel) { }
            Button("Delete", role: .destructive) {
                Task { await viewModel.deleteSelectedComponents() }
            }
        } message: {
            let count = viewModel.selectedComponentIndices.count
            Text("This will permanently delete \(count) component\(count == 1 ? "" : "s") from the mesh.")
        }
        .alert("Keep Only Selected?", isPresented: $viewModel.showKeepSelectedConfirmation) {
            Button("Cancel", role: .cancel) { }
            Button("Keep Only Selected", role: .destructive) {
                Task { await viewModel.keepSelectedComponents() }
            }
        } message: {
            let keepCount = viewModel.selectedComponentIndices.count
            let deleteCount = viewModel.meshComponents.count - keepCount
            Text("This will delete \(deleteCount) component\(deleteCount == 1 ? "" : "s") and keep only the \(keepCount) selected.")
        }
        .alert("Keep Largest \(viewModel.keepLargestCount)?", isPresented: $viewModel.showKeepLargestConfirmation) {
            Button("Cancel", role: .cancel) { }
            Button("Keep Largest", role: .destructive) {
                Task { await viewModel.keepLargestComponents(count: viewModel.keepLargestCount) }
            }
        } message: {
            let deleteCount = viewModel.meshComponents.count - viewModel.keepLargestCount
            Text("This will delete \(deleteCount) smaller component\(deleteCount == 1 ? "" : "s") and keep the \(viewModel.keepLargestCount) largest.")
        }
    }

    @ViewBuilder
    private var analyzingView: some View {
        HStack(spacing: AppDesign.Spacing.p8) {
            ProgressView()
                .controlSize(.small)
            Text("Analyzing mesh...")
                .font(.system(size: AppDesign.FontSize.body))
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var noComponentsView: some View {
        VStack(alignment: .leading, spacing: AppDesign.Spacing.p8) {
            HStack(spacing: AppDesign.Spacing.p6) {
                Image(systemName: "cube.transparent")
                    .font(.system(size: AppDesign.FontSize.body))
                    .foregroundStyle(.secondary)
                Text("No mesh components found")
                    .font(.system(size: AppDesign.FontSize.body))
                    .foregroundStyle(.secondary)
            }

            AppDesign.HintText("The mesh may be empty or failed to load.")

            AppDesign.InlineButton("Re-analyze", icon: "arrow.clockwise") {
                Task {
                    await viewModel.analyzeMesh()
                }
            }
        }
    }

    @ViewBuilder
    private var componentListView: some View {
        VStack(alignment: .leading, spacing: AppDesign.Spacing.p8) {
            HStack {
                AppDesign.SectionLabel("Components (\(viewModel.meshComponents.count))")
                Spacer()
                if !viewModel.selectedComponentIndices.isEmpty {
                    Text("\(viewModel.selectedComponentIndices.count) selected")
                        .font(.system(size: AppDesign.FontSize.xs, weight: .medium))
                        .foregroundStyle(AppDesign.accent)
                }
            }

            ForEach(viewModel.meshComponents) { component in
                componentRow(component)
            }

            if viewModel.meshComponents.count > 1 {
                HStack(spacing: AppDesign.Spacing.p12) {
                    AppDesign.InlineButton("Select All", icon: "checkmark.circle") {
                        viewModel.selectAllComponents()
                    }
                    AppDesign.InlineButton("Deselect", icon: "circle") {
                        viewModel.deselectAllComponents()
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func componentRow(_ component: MeshComponent) -> some View {
        let isSelected = viewModel.selectedComponentIndices.contains(component.index)
        let color = AppDesign.neonColors[component.index % AppDesign.neonColors.count]

        Button {
            withAnimation(.easeOut(duration: 0.15)) {
                viewModel.toggleComponentSelection(component.index)
            }
        } label: {
            HStack(spacing: AppDesign.Spacing.p10) {
                // Color indicator
                RoundedRectangle(cornerRadius: 4)
                    .fill(color)
                    .frame(width: 8, height: 24)

                // Component info
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: AppDesign.Spacing.p4) {
                        Text("Component \(component.index + 1)")
                            .font(.system(size: AppDesign.FontSize.subheadline, weight: isSelected ? .semibold : .regular))
                            .foregroundStyle(isSelected ? color : .primary)

                        if component.index == 0 {
                            Text("Largest")
                                .font(.system(size: AppDesign.FontSize.xs, weight: .medium))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(color.opacity(0.8), in: Capsule())
                        }
                    }

                    HStack(spacing: AppDesign.Spacing.p8) {
                        Label("\(formatNumber(component.vertexCount))", systemImage: "circle.grid.3x3")
                        Label("\(formatNumber(component.faceCount))", systemImage: "triangle")
                        if component.isWatertight {
                            Label("Watertight", systemImage: "checkmark.seal")
                                .foregroundStyle(AppDesign.success)
                        }
                    }
                    .font(.system(size: AppDesign.FontSize.xs, design: .monospaced))
                    .foregroundStyle(.secondary)
                }

                Spacer()

                // Selection indicator
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: AppDesign.FontSize.title3))
                    .foregroundStyle(isSelected ? color : Color.secondary.opacity(0.5))
            }
            .padding(.vertical, AppDesign.Spacing.p8)
            .padding(.horizontal, AppDesign.Spacing.p10)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isSelected ? color.opacity(0.15) : Color.primary.opacity(0.03))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(isSelected ? color.opacity(0.5) : Color.primary.opacity(0.1), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var actionButtonsView: some View {
        VStack(alignment: .leading, spacing: AppDesign.Spacing.p8) {
            // Keep Largest section with edit mode
            keepLargestSection

            // Selection-based actions
            if !viewModel.selectedComponentIndices.isEmpty {
                let count = viewModel.selectedComponentIndices.count
                let canDelete = count < viewModel.meshComponents.count
                let canKeep = count > 0 && count < viewModel.meshComponents.count

                HStack(spacing: AppDesign.Spacing.p8) {
                    // Only Keep Selected
                    if canKeep {
                        AppDesign.GlassButtonSecondary(
                            "Keep Only Selected",
                            icon: "checkmark.circle"
                        ) {
                            viewModel.showKeepSelectedConfirmation = true
                        }
                        .disabled(viewModel.isProcessingMesh)
                    }

                    // Delete Selected
                    if canDelete {
                        AppDesign.GlassButtonSecondary(
                            "Delete Selected",
                            icon: "trash",
                            destructive: true
                        ) {
                            viewModel.showDeleteSelectedConfirmation = true
                        }
                        .disabled(viewModel.isProcessingMesh)
                    }
                }

                if !canDelete && !canKeep {
                    AppDesign.HintText("Cannot delete all components")
                }
            }

            if viewModel.isProcessingMesh {
                HStack(spacing: AppDesign.Spacing.p8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Processing...")
                        .font(.system(size: AppDesign.FontSize.caption))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private var keepLargestSection: some View {
        if viewModel.isEditingKeepLargest {
            // Expanded edit mode
            HStack(spacing: AppDesign.Spacing.p8) {
                Text("Keep largest")
                    .font(.system(size: AppDesign.FontSize.subheadline))
                    .foregroundStyle(.secondary)

                // Number input
                HStack(spacing: 0) {
                    Button {
                        if viewModel.keepLargestCount > 1 {
                            viewModel.keepLargestCount -= 1
                        }
                    } label: {
                        Image(systemName: "minus")
                            .font(.system(size: AppDesign.FontSize.caption, weight: .medium))
                            .frame(width: 24, height: 24)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.primary)

                    Text("\(viewModel.keepLargestCount)")
                        .font(.system(size: AppDesign.FontSize.subheadline, weight: .semibold, design: .monospaced))
                        .frame(width: 32)

                    Button {
                        if viewModel.keepLargestCount < viewModel.meshComponents.count - 1 {
                            viewModel.keepLargestCount += 1
                        }
                    } label: {
                        Image(systemName: "plus")
                            .font(.system(size: AppDesign.FontSize.caption, weight: .medium))
                            .frame(width: 24, height: 24)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.primary)
                }
                .padding(.horizontal, AppDesign.Spacing.p4)
                .padding(.vertical, AppDesign.Spacing.p4)
                .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))

                Text("items")
                    .font(.system(size: AppDesign.FontSize.subheadline))
                    .foregroundStyle(.secondary)

                Spacer()

                // Apply button
                Button {
                    viewModel.showKeepLargestConfirmation = true
                } label: {
                    Text("Apply")
                        .font(.system(size: AppDesign.FontSize.caption, weight: .medium))
                        .padding(.horizontal, AppDesign.Spacing.p10)
                        .padding(.vertical, AppDesign.Spacing.p6)
                        .background(AppDesign.accent, in: RoundedRectangle(cornerRadius: 6))
                        .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
                .disabled(viewModel.isProcessingMesh || viewModel.keepLargestCount >= viewModel.meshComponents.count)

                // Cancel button
                Button {
                    withAnimation(.easeOut(duration: 0.15)) {
                        viewModel.isEditingKeepLargest = false
                        viewModel.keepLargestCount = 1
                    }
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: AppDesign.FontSize.caption, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.plain)
            }
            .padding(.vertical, AppDesign.Spacing.p4)
        } else {
            // Collapsed mode - button with edit
            HStack(spacing: AppDesign.Spacing.p8) {
                AppDesign.GlassButtonSecondary("Keep Largest Only", icon: "star.fill") {
                    viewModel.keepLargestCount = 1
                    viewModel.showKeepLargestConfirmation = true
                }
                .disabled(viewModel.isProcessingMesh || viewModel.meshComponents.count <= 1)

                // Edit button
                Button {
                    withAnimation(.easeOut(duration: 0.15)) {
                        viewModel.isEditingKeepLargest = true
                        viewModel.keepLargestCount = 1
                    }
                } label: {
                    Image(systemName: "pencil")
                        .font(.system(size: AppDesign.FontSize.caption, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 28, height: 28)
                        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
                .disabled(viewModel.meshComponents.count <= 2)
            }
        }
    }

    @ViewBuilder
    private var exportSection: some View {
        VStack(alignment: .leading, spacing: AppDesign.Spacing.p8) {
            AppDesign.SectionLabel("Export")

            // Format picker
            HStack(spacing: AppDesign.Spacing.p8) {
                ForEach(ExportFormat.allCases) { format in
                    formatButton(format)
                }
            }

            AppDesign.GlassButton("Export \(viewModel.selectedExportFormat.rawValue)", icon: "square.and.arrow.up") {
                exportMesh()
            }
            .disabled(viewModel.isProcessingMesh)
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
    }

    private func formatNumber(_ num: Int) -> String {
        if num >= 1_000_000 {
            return String(format: "%.1fM", Double(num) / 1_000_000)
        } else if num >= 1_000 {
            return String(format: "%.1fK", Double(num) / 1_000)
        }
        return "\(num)"
    }

    private func exportMesh() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.item]
        panel.nameFieldStringValue = "model.\(viewModel.selectedExportFormat.fileExtension)"
        panel.canCreateDirectories = true

        if panel.runModal() == .OK, let url = panel.url {
            Task {
                let success = await viewModel.exportMesh(to: url)
                if success {
                    NSWorkspace.shared.selectFile(url.path, inFileViewerRootedAtPath: url.deletingLastPathComponent().path)
                }
            }
        }
    }
}
