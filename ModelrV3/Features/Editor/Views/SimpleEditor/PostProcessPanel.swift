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
                actionButtonsView
                exportSection
            }
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
    private func componentRow(_ component: SimpleEditorViewModel.MeshComponent) -> some View {
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
            Divider().padding(.vertical, AppDesign.Spacing.p4)

            if viewModel.meshComponents.count > 1 {
                // Keep Largest button
                AppDesign.GlassButtonSecondary("Keep Largest Only", icon: "star.fill") {
                    Task {
                        await viewModel.keepLargestComponent()
                    }
                }
                .disabled(viewModel.isProcessingMesh || viewModel.meshComponents.count <= 1)

                // Delete selected button
                if !viewModel.selectedComponentIndices.isEmpty {
                    let count = viewModel.selectedComponentIndices.count
                    let canDelete = count < viewModel.meshComponents.count

                    AppDesign.GlassButtonSecondary(
                        "Delete \(count) Component\(count == 1 ? "" : "s")",
                        icon: "trash",
                        destructive: true
                    ) {
                        Task {
                            await viewModel.deleteSelectedComponents()
                        }
                    }
                    .disabled(viewModel.isProcessingMesh || !canDelete)

                    if !canDelete {
                        AppDesign.HintText("Cannot delete all components")
                    }
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
    private var exportSection: some View {
        VStack(alignment: .leading, spacing: AppDesign.Spacing.p8) {
            Divider().padding(.vertical, AppDesign.Spacing.p4)

            AppDesign.SectionLabel("Export")

            // Format picker
            HStack(spacing: AppDesign.Spacing.p8) {
                ForEach(SimpleEditorViewModel.ExportFormat.allCases) { format in
                    formatButton(format)
                }
            }

            AppDesign.GlassButton("Export \(viewModel.selectedExportFormat.rawValue)", icon: "square.and.arrow.up") {
                exportMesh()
            }
            .disabled(viewModel.isProcessingMesh)

            // Show in Finder for current mesh
            if let url = viewModel.currentMeshURL {
                AppDesign.InlineButton("Show in Finder", icon: "folder") {
                    NSWorkspace.shared.selectFile(url.path, inFileViewerRootedAtPath: url.deletingLastPathComponent().path)
                }
            }
        }
    }

    @ViewBuilder
    private func formatButton(_ format: SimpleEditorViewModel.ExportFormat) -> some View {
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
