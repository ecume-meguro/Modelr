import SwiftUI

/// Multi-segmentation panel - allows selecting multiple objects to merge
struct SegmentationPanel: View {
    @ObservedObject var viewModel: SimpleEditorViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: AppDesign.Spacing.p12) {
            // Alpha toggle section
            if viewModel.imageHasAlpha {
                alphaToggleSection
                Divider().padding(.vertical, AppDesign.Spacing.p4)
            }

            if !viewModel.useExistingAlpha {
                // Segmentation entries list
                ForEach(Array(viewModel.segmentations.enumerated()), id: \.element.id) { index, entry in
                    SegmentationEntryView(
                        entry: entry,
                        index: index,
                        isActive: index == viewModel.activeSegmentationIndex,
                        viewModel: viewModel
                    )
                }

                // Add another object button
                if viewModel.totalValidMasks > 0 {
                    addAnotherButton
                }

                // Summary
                if viewModel.totalValidMasks > 1 {
                    summarySection
                }
            }
        }
    }

    @ViewBuilder
    private var alphaToggleSection: some View {
        VStack(alignment: .leading, spacing: AppDesign.Spacing.p8) {
            Toggle(isOn: $viewModel.useExistingAlpha) {
                Text("Already segmented")
                    .font(.system(size: AppDesign.FontSize.body))
            }
            .toggleStyle(.checkbox)
            .onChange(of: viewModel.useExistingAlpha) { _, newValue in
                if newValue {
                    viewModel.createMaskFromAlpha()
                } else {
                    viewModel.clearAllSegmentations()
                }
            }

            if viewModel.useExistingAlpha {
                AppDesign.CompletedRow("Using existing transparency")
            }
        }
    }

    @ViewBuilder
    private var addAnotherButton: some View {
        Button {
            withAnimation(.easeOut(duration: 0.2)) {
                viewModel.addSegmentation()
            }
        } label: {
            HStack(spacing: AppDesign.Spacing.p6) {
                Image(systemName: "plus.circle.fill")
                    .font(.system(size: AppDesign.FontSize.body))
                Text("Add Another Object")
                    .font(.system(size: AppDesign.FontSize.subheadline, weight: .medium))
            }
            .foregroundStyle(AppDesign.accent)
        }
        .buttonStyle(.plain)
        .padding(.top, AppDesign.Spacing.p4)
    }

    @ViewBuilder
    private var summarySection: some View {
        HStack(spacing: AppDesign.Spacing.p6) {
            Image(systemName: "square.stack.3d.up.fill")
                .font(.system(size: AppDesign.FontSize.caption))
                .foregroundStyle(.secondary)
            Text("\(viewModel.totalValidMasks) objects will be merged")
                .font(.system(size: AppDesign.FontSize.caption))
                .foregroundStyle(.secondary)
        }
        .padding(.top, AppDesign.Spacing.p4)
    }
}

// MARK: - Segmentation Entry View
struct SegmentationEntryView: View {
    let entry: SegmentationEntry
    let index: Int
    let isActive: Bool
    @ObservedObject var viewModel: SimpleEditorViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header - always visible
            entryHeader

            // Content - only when expanded
            if entry.isExpanded {
                entryContent
                    .padding(.top, AppDesign.Spacing.p8)
            }
        }
        .padding(AppDesign.Spacing.p10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isActive ? Color.primary.opacity(0.05) : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(
                    isActive ? AppDesign.accent.opacity(0.3) : Color.primary.opacity(0.1),
                    lineWidth: 1
                )
        )
        .animation(.easeOut(duration: 0.2), value: entry.isExpanded)
    }

    private var segmentationColor: Color {
        viewModel.colorForSegmentation(index)
    }

    @ViewBuilder
    private var entryHeader: some View {
        HStack(spacing: AppDesign.Spacing.p8) {
            // Expand/collapse button
            Button {
                withAnimation(.easeOut(duration: 0.2)) {
                    viewModel.expandSegmentation(at: index)
                }
            } label: {
                Image(systemName: entry.isExpanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: AppDesign.FontSize.caption, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .frame(width: 12)
            }
            .buttonStyle(.plain)

            // Clickable entry name - switches to this object
            Button {
                withAnimation(.easeOut(duration: 0.2)) {
                    viewModel.expandSegmentation(at: index)
                }
            } label: {
                HStack(spacing: AppDesign.Spacing.p6) {
                    Circle()
                        .fill(segmentationColor)
                        .frame(width: 8, height: 8)
                    Text(entry.name)
                        .font(.system(size: AppDesign.FontSize.subheadline, weight: isActive ? .bold : .semibold))
                        .foregroundStyle(isActive ? segmentationColor : .primary)
                }
            }
            .buttonStyle(.plain)

            Spacer()

            // Status indicator
            if entry.isProcessing {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.7)
            } else if entry.hasValidMask {
                // Thumbnail of selected mask with neon color border
                if let mask = entry.selectedMask {
                    Image(nsImage: mask)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 24, height: 24)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                        .overlay(
                            RoundedRectangle(cornerRadius: 4)
                                .strokeBorder(segmentationColor, lineWidth: 2)
                        )
                }
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: AppDesign.FontSize.caption))
                    .foregroundStyle(segmentationColor)
            }

            // Remove button (only if more than one segmentation)
            if viewModel.segmentations.count > 1 {
                Button {
                    withAnimation(.easeOut(duration: 0.2)) {
                        viewModel.removeSegmentation(at: index)
                    }
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: AppDesign.FontSize.body))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
        }
    }

    @ViewBuilder
    private var entryContent: some View {
        VStack(alignment: .leading, spacing: AppDesign.Spacing.p8) {
            // Text prompt input
            HStack(spacing: AppDesign.Spacing.p8) {
                TextField("e.g. dog, tree, person", text: textPromptBinding)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit {
                        viewModel.runTextPrediction()
                    }

                Button(action: viewModel.runTextPrediction) {
                    Image(systemName: "magnifyingglass")
                }
                .buttonStyle(.bordered)
                .disabled(entry.textPrompt.isEmpty || entry.isProcessing)
            }

            AppDesign.HintText("Or right-click on the object in view")

            // Warning if no results
            if entry.isSearchPerformed && entry.allMasks.isEmpty && !entry.isProcessing {
                AppDesign.WarningMessage(text: "No '\(entry.textPrompt)' found")
            }

            // Region selection (if multiple masks)
            if entry.allMasks.count > 1 {
                regionSelectionSection
            }

            // Points indicator
            if !entry.points.isEmpty {
                HStack(spacing: AppDesign.Spacing.p4) {
                    Image(systemName: "hand.point.up.left.fill")
                        .font(.system(size: AppDesign.FontSize.caption))
                        .foregroundStyle(.secondary)
                    Text("\(entry.points.count) point(s) placed")
                        .font(.system(size: AppDesign.FontSize.caption))
                        .foregroundStyle(.secondary)
                }
            }

            // Clear button
            if entry.hasValidMask || !entry.points.isEmpty {
                HStack {
                    AppDesign.InlineButton("Clear", icon: "trash") {
                        viewModel.clearActiveSegmentation()
                    }
                    Spacer()
                }
            }
        }
    }

    @ViewBuilder
    private var regionSelectionSection: some View {
        VStack(alignment: .leading, spacing: AppDesign.Spacing.p6) {
            HStack {
                AppDesign.SectionLabel("Select Region")
                Spacer()
                if entry.selectedMaskIndices.count > 1 {
                    Text("\(entry.selectedMaskIndices.count) selected")
                        .font(.system(size: AppDesign.FontSize.xs, weight: .medium))
                        .foregroundStyle(segmentationColor)
                }
            }

            ForEach(Array(entry.allMasks.enumerated()), id: \.offset) { maskIndex, maskData in
                regionRow(maskIndex: maskIndex, score: maskData.score)
            }

            AppDesign.HintText("Shift-click to select multiple regions")
        }
    }

    @ViewBuilder
    private func regionRow(maskIndex: Int, score: Double) -> some View {
        let isSelected = entry.selectedMaskIndices.contains(maskIndex)
        let color = viewModel.colorForMask(maskIndex)
        let maskImage = entry.allMasks[maskIndex].image

        RegionRowButton(
            isSelected: isSelected,
            color: color,
            maskImage: maskImage,
            maskIndex: maskIndex,
            score: score,
            onSelect: { addToSelection in
                viewModel.selectMask(at: maskIndex, for: index, addToSelection: addToSelection)
            }
        )
    }
}

// MARK: - Region Row Button (handles shift-click)
struct RegionRowButton: View {
    let isSelected: Bool
    let color: Color
    let maskImage: NSImage
    let maskIndex: Int
    let score: Double
    let onSelect: (Bool) -> Void

    var body: some View {
        Button {
            // Check if shift is held
            let shiftHeld = NSEvent.modifierFlags.contains(.shift)
            onSelect(shiftHeld)
        } label: {
            HStack(spacing: AppDesign.Spacing.p10) {
                // Mask preview thumbnail
                Image(nsImage: maskImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 32, height: 32)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .strokeBorder(isSelected ? color : Color.primary.opacity(0.2), lineWidth: isSelected ? 2 : 1)
                    )

                // Region name
                Text("Region \(maskIndex + 1)")
                    .font(.system(size: AppDesign.FontSize.caption, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected ? color : .primary)

                Spacer()

                // Confidence percentage
                Text(String(format: "%.0f%%", score * 100))
                    .font(.system(size: AppDesign.FontSize.xs, design: .monospaced))
                    .foregroundStyle(isSelected ? color : .secondary)

                // Checkmark if selected
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: AppDesign.FontSize.body))
                        .foregroundStyle(color)
                }
            }
            .padding(.vertical, AppDesign.Spacing.p6)
            .padding(.horizontal, AppDesign.Spacing.p8)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isSelected ? color.opacity(0.15) : Color.primary.opacity(0.03))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(isSelected ? color.opacity(0.5) : Color.clear, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - SegmentationEntryView continued
extension SegmentationEntryView {
    // Binding to update the text prompt in the segmentations array
    var textPromptBinding: Binding<String> {
        Binding(
            get: { entry.textPrompt },
            set: { newValue in
                if index < viewModel.segmentations.count {
                    viewModel.segmentations[index].textPrompt = newValue
                }
            }
        )
    }
}
