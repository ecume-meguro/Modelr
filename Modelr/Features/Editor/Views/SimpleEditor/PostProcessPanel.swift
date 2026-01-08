import SwiftUI
import UniformTypeIdentifiers

/// Post-process panel with two-list drag-and-drop interface
struct PostProcessPanel: View {
    @ObservedObject var viewModel: SimpleEditorViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: AppDesign.Spacing.p16) {
            if viewModel.isAnalyzingMesh {
                analyzingView
            } else if viewModel.meshComponents.isEmpty {
                noComponentsView
            } else {
                // Isolation banner (if active)
                if viewModel.isolatedComponentIndex != nil {
                    isolationBanner
                }

                // Two-list interface
                twoListView

                Divider().padding(.vertical, AppDesign.Spacing.p4)

                // Export section
                exportSection
            }
        }
        .alert("Apply Changes?", isPresented: $viewModel.showApplyChangesConfirmation) {
            Button("Cancel", role: .cancel) { }
            Button("Delete \(viewModel.deleteIndices.count)", role: .destructive) {
                Task { await viewModel.applyChanges() }
            }
        } message: {
            Text("This will permanently delete \(viewModel.deleteIndices.count) component\(viewModel.deleteIndices.count == 1 ? "" : "s").")
        }
    }

    // MARK: - Isolation Banner

    @ViewBuilder
    private var isolationBanner: some View {
        if let isolatedIndex = viewModel.isolatedComponentIndex,
           let component = viewModel.meshComponents.first(where: { $0.index == isolatedIndex }) {
            HStack(spacing: AppDesign.Spacing.p8) {
                Image(systemName: "eye.circle.fill")
                    .foregroundStyle(AppDesign.accent)
                Text("Isolating: \(componentLabel(for: component))")
                    .font(.system(size: AppDesign.FontSize.caption, weight: .medium))
                Spacer()
                Button {
                    withAnimation(.easeOut(duration: 0.2)) {
                        viewModel.exitIsolation()
                    }
                } label: {
                    Text("Show All")
                        .font(.system(size: AppDesign.FontSize.xs, weight: .medium))
                        .foregroundStyle(AppDesign.accent)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, AppDesign.Spacing.p10)
            .padding(.vertical, AppDesign.Spacing.p8)
            .background(AppDesign.accent.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(AppDesign.accent.opacity(0.3), lineWidth: 1)
            )
        }
    }

    // MARK: - Two List Interface

    @ViewBuilder
    private var twoListView: some View {
        VStack(alignment: .leading, spacing: AppDesign.Spacing.p12) {
            // Keep List (green)
            keepListSection

            // Delete List (red)
            deleteListSection

            // Apply button
            if viewModel.hasPendingDeletions {
                applyButton
            }
        }
    }

    @ViewBuilder
    private var keepListSection: some View {
        VStack(alignment: .leading, spacing: AppDesign.Spacing.p6) {
            HStack {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(AppDesign.success)
                Text("Keep")
                    .font(.system(size: AppDesign.FontSize.caption, weight: .semibold))
                    .foregroundStyle(.primary)
                    .textCase(.uppercase)
                    .tracking(0.5)
                Text("(\(viewModel.keepIndices.count))")
                    .font(.system(size: AppDesign.FontSize.xs))
                    .foregroundStyle(.secondary)
                Spacer()
            }

            if viewModel.keepIndices.isEmpty {
                emptyListPlaceholder(text: "Drag items here to keep")
            } else {
                ForEach(keepComponents, id: \.index) { component in
                    componentRow(component, isKeep: true)
                }
            }
        }
        .padding(AppDesign.Spacing.p10)
        .background(AppDesign.success.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(AppDesign.success.opacity(0.2), lineWidth: 1)
        )
        .onDrop(of: [.text], delegate: KeepListDropDelegate(viewModel: viewModel))
    }

    @ViewBuilder
    private var deleteListSection: some View {
        VStack(alignment: .leading, spacing: AppDesign.Spacing.p6) {
            HStack {
                Image(systemName: "trash.fill")
                    .foregroundStyle(AppDesign.destructive)
                Text("Delete")
                    .font(.system(size: AppDesign.FontSize.caption, weight: .semibold))
                    .foregroundStyle(.primary)
                    .textCase(.uppercase)
                    .tracking(0.5)
                Text("(\(viewModel.deleteIndices.count))")
                    .font(.system(size: AppDesign.FontSize.xs))
                    .foregroundStyle(.secondary)
                Spacer()
            }

            if viewModel.deleteIndices.isEmpty {
                emptyListPlaceholder(text: "Drag items here to delete")
            } else {
                ForEach(deleteComponents, id: \.index) { component in
                    componentRow(component, isKeep: false)
                }
            }
        }
        .padding(AppDesign.Spacing.p10)
        .background(AppDesign.destructive.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(AppDesign.destructive.opacity(0.2), lineWidth: 1)
        )
        .onDrop(of: [.text], delegate: DeleteListDropDelegate(viewModel: viewModel))
    }

    @ViewBuilder
    private func emptyListPlaceholder(text: String) -> some View {
        Text(text)
            .font(.system(size: AppDesign.FontSize.caption))
            .foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, AppDesign.Spacing.p12)
    }

    @ViewBuilder
    private var applyButton: some View {
        AppDesign.GlassButtonSecondary(
            "Delete \(viewModel.deleteIndices.count) Component\(viewModel.deleteIndices.count == 1 ? "" : "s")",
            icon: "trash",
            destructive: true
        ) {
            viewModel.showApplyChangesConfirmation = true
        }
        .disabled(viewModel.isProcessingMesh)
    }

    // MARK: - Component Row

    @ViewBuilder
    private func componentRow(_ component: MeshComponent, isKeep: Bool) -> some View {
        let isHighlighted = viewModel.highlightedComponentIndex == component.index
        let isIsolated = viewModel.isolatedComponentIndex == component.index
        let baseColor = isKeep ? AppDesign.success : AppDesign.destructive
        let label = componentLabel(for: component)

        // Check if this is the only item in keep list (can't move to delete)
        let canMoveToDelete = isKeep && viewModel.keepIndices.count > 1

        HStack(spacing: AppDesign.Spacing.p8) {
            // Color indicator
            RoundedRectangle(cornerRadius: 3)
                .fill(isHighlighted ? Color.yellow : baseColor)
                .frame(width: 4)
                .frame(maxHeight: .infinity)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(label)
                        .font(.system(size: AppDesign.FontSize.subheadline, weight: isHighlighted ? .semibold : .regular))
                        .foregroundStyle(isHighlighted ? Color.yellow : .primary)

                    if isIsolated {
                        Image(systemName: "eye.fill")
                            .font(.system(size: 9))
                            .foregroundStyle(AppDesign.accent)
                    }
                }

                HStack(spacing: 6) {
                    Text("\(formatNumber(component.faceCount)) faces")
                        .font(.system(size: AppDesign.FontSize.xs, design: .monospaced))
                        .foregroundStyle(.secondary)

                    watertightBadge(component.isWatertight)
                }
            }

            Spacer()

            // Move button (larger click area)
            Button {
                withAnimation(.easeOut(duration: 0.2)) {
                    if isKeep {
                        if canMoveToDelete {
                            viewModel.moveToDelete(component.index)
                        }
                    } else {
                        viewModel.moveToKeep(component.index)
                    }
                }
            } label: {
                Image(systemName: isKeep ? "arrow.down" : "arrow.up")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(isKeep ? (canMoveToDelete ? AppDesign.destructive : Color.secondary.opacity(0.3)) : AppDesign.success)
                    .frame(width: 32, height: 32)
                    .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
            }
            .buttonStyle(.plain)
            .disabled(isKeep && !canMoveToDelete)
            .help(isKeep ? (canMoveToDelete ? "Move to Delete" : "Cannot delete last item") : "Move to Keep")
        }
        .padding(.vertical, AppDesign.Spacing.p8)
        .padding(.horizontal, AppDesign.Spacing.p10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isHighlighted ? Color.yellow.opacity(0.15) : Color.primary.opacity(0.03))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(isHighlighted ? Color.yellow.opacity(0.5) : Color.clear, lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.easeOut(duration: 0.15)) {
                if viewModel.highlightedComponentIndex == component.index {
                    viewModel.highlightComponent(nil)
                } else {
                    viewModel.highlightComponent(component.index)
                }
            }
        }
        .contextMenu {
            // Isolate option
            Button {
                withAnimation(.easeOut(duration: 0.2)) {
                    viewModel.toggleIsolation(component.index)
                }
            } label: {
                Label(isIsolated ? "Show All Components" : "Isolate Component", systemImage: isIsolated ? "eye.slash" : "eye")
            }

            Divider()

            // Move options
            if isKeep {
                Button(role: .destructive) {
                    withAnimation(.easeOut(duration: 0.2)) {
                        viewModel.moveToDelete(component.index)
                    }
                } label: {
                    Label("Move to Delete", systemImage: "trash")
                }
                .disabled(!canMoveToDelete)
            } else {
                Button {
                    withAnimation(.easeOut(duration: 0.2)) {
                        viewModel.moveToKeep(component.index)
                    }
                } label: {
                    Label("Move to Keep", systemImage: "checkmark.circle")
                }
            }
        }
        .onDrag {
            NSItemProvider(object: String(component.index) as NSString)
        }
    }

    // MARK: - Helpers

    private var keepComponents: [MeshComponent] {
        viewModel.meshComponents.filter { viewModel.keepIndices.contains($0.index) }
    }

    private var deleteComponents: [MeshComponent] {
        viewModel.meshComponents.filter { viewModel.deleteIndices.contains($0.index) }
    }

    private func componentLabel(for component: MeshComponent) -> String {
        let isMainMesh = component.faceCount >= 1000

        if isMainMesh {
            let mainMeshes = viewModel.meshComponents.filter { $0.faceCount >= 1000 }
            if mainMeshes.count == 1 {
                return "Main Mesh"
            } else {
                let index = mainMeshes.firstIndex(where: { $0.index == component.index }) ?? 0
                return "Main Mesh \(index + 1)"
            }
        } else {
            let artifacts = viewModel.meshComponents.filter { $0.faceCount < 1000 }
            if artifacts.count == 1 {
                return "Artifact"
            } else {
                let index = artifacts.firstIndex(where: { $0.index == component.index }) ?? 0
                return "Artifact \(index + 1)"
            }
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

    @ViewBuilder
    private func watertightBadge(_ isWatertight: Bool) -> some View {
        HStack(spacing: 2) {
            Image(systemName: isWatertight ? "checkmark.seal.fill" : "xmark.seal")
                .font(.system(size: 8))
            Text(isWatertight ? "Watertight" : "Open")
                .font(.system(size: 9))
        }
        .foregroundStyle(isWatertight ? AnyShapeStyle(AppDesign.success) : AnyShapeStyle(Color.secondary.opacity(0.6)))
    }

    // MARK: - Other Views

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
    private var exportSection: some View {
        VStack(alignment: .leading, spacing: AppDesign.Spacing.p8) {
            AppDesign.SectionLabel("Export")

            FlowLayout(spacing: AppDesign.Spacing.p6) {
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

// MARK: - Drop Delegates

struct KeepListDropDelegate: DropDelegate {
    let viewModel: SimpleEditorViewModel

    func performDrop(info: DropInfo) -> Bool {
        guard let item = info.itemProviders(for: [.text]).first else { return false }

        item.loadObject(ofClass: NSString.self) { object, _ in
            if let indexString = object as? String, let index = Int(indexString) {
                DispatchQueue.main.async {
                    withAnimation(.easeOut(duration: 0.2)) {
                        viewModel.moveToKeep(index)
                    }
                }
            }
        }
        return true
    }

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [.text])
    }
}

struct DeleteListDropDelegate: DropDelegate {
    let viewModel: SimpleEditorViewModel

    func performDrop(info: DropInfo) -> Bool {
        guard let item = info.itemProviders(for: [.text]).first else { return false }

        item.loadObject(ofClass: NSString.self) { object, _ in
            if let indexString = object as? String, let index = Int(indexString) {
                DispatchQueue.main.async {
                    // Only allow if it won't leave keep list empty
                    if viewModel.keepIndices.count > 1 || !viewModel.keepIndices.contains(index) {
                        withAnimation(.easeOut(duration: 0.2)) {
                            viewModel.moveToDelete(index)
                        }
                    }
                }
            }
        }
        return true
    }

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [.text])
    }
}
