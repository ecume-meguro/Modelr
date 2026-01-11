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
                    .transition(.asymmetric(
                        insertion: .opacity.combined(with: .scale(scale: 0.95, anchor: .top)),
                        removal: .opacity
                    ))
                }

                // Add another object button
                if viewModel.totalValidMasks > 0 {
                    addAnotherButton
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }

                // Summary
                if viewModel.totalValidMasks > 1 {
                    summarySection
                        .transition(.opacity)
                }
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: viewModel.segmentations.count)
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: viewModel.totalValidMasks)
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
            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                viewModel.addSegmentation()
            }
        } label: {
            HStack(spacing: AppDesign.Spacing.p6) {
                Image(systemName: "plus.circle.fill")
                    .font(.system(size: AppDesign.FontSize.body))
                Text("Add Another Object")
                    .font(.system(size: AppDesign.FontSize.subheadline, weight: .medium))
                Spacer()
            }
            .foregroundStyle(AppDesign.accent)
            .padding(.vertical, AppDesign.Spacing.p8)
            .padding(.horizontal, AppDesign.Spacing.p10)
            .background(AppDesign.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
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
    @FocusState private var isTextFieldFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header - always visible
            entryHeader

            // Content - only when expanded
            if entry.isExpanded {
                entryContent
                    .padding(.top, AppDesign.Spacing.p8)
                    .transition(.asymmetric(
                        insertion: .opacity
                            .combined(with: .offset(y: -10))
                            .animation(.spring(response: 0.3, dampingFraction: 0.85)),
                        removal: .opacity
                            .animation(.easeOut(duration: 0.15))
                    ))
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
        .clipShape(RoundedRectangle(cornerRadius: 8))
        // "Click to interrupt" overlay when VLM is analyzing
        .overlay(
            Group {
                if viewModel.isAutoDetecting && isActive && entry.isExpanded {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(.ultraThinMaterial.opacity(0.8))
                        .overlay(
                            VStack(spacing: AppDesign.Spacing.p4) {
                                Image(systemName: "hand.tap.fill")
                                    .font(.system(size: 18))
                                    .foregroundStyle(.secondary)
                                Text("Click to interrupt")
                                    .font(.system(size: AppDesign.FontSize.caption, weight: .medium))
                                    .foregroundStyle(.secondary)
                            }
                        )
                        .contentShape(Rectangle())
                        .onTapGesture {
                            viewModel.cancelAutoDetection()
                        }
                        .transition(.opacity.animation(.easeOut(duration: 0.15)))
                }
            }
        )
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: entry.isExpanded)
        .animation(.spring(response: 0.25, dampingFraction: 0.85), value: isActive)
        .animation(.easeInOut(duration: 0.2), value: viewModel.isAutoDetecting)
        .onChange(of: isActive) { _, newValue in
            // Focus text field when this entry becomes active
            if newValue && entry.isExpanded {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    isTextFieldFocused = true
                }
            }
        }
        .onChange(of: entry.isExpanded) { _, newValue in
            // Focus text field when expanded while active
            if newValue && isActive {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    isTextFieldFocused = true
                }
            }
        }
    }

    private var segmentationColor: Color {
        viewModel.colorForSegmentation(index)
    }

    @ViewBuilder
    private var entryHeader: some View {
        HStack(spacing: AppDesign.Spacing.p8) {
            // Main clickable area - expands/collapses
            Button {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                    viewModel.expandSegmentation(at: index)
                }
            } label: {
                HStack(spacing: AppDesign.Spacing.p8) {
                    // Expand/collapse chevron with rotation animation
                    Image(systemName: "chevron.right")
                        .font(.system(size: AppDesign.FontSize.caption, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .frame(width: 12)
                        .rotationEffect(.degrees(entry.isExpanded ? 90 : 0))
                        .animation(.spring(response: 0.25, dampingFraction: 0.7), value: entry.isExpanded)

                    // Entry name
                    Text(entry.textPrompt.isEmpty ? "Object \(index + 1)" : entry.textPrompt)
                        .font(.system(size: AppDesign.FontSize.subheadline, weight: isActive ? .bold : .semibold))
                        .foregroundStyle(.primary)

                    Spacer()

                    // Status indicator
                    if entry.isProcessing {
                        ProgressView()
                            .controlSize(.small)
                            .scaleEffect(0.7)
                    } else if entry.hasValidMask {
                        // Thumbnail of selected mask
                        if let mask = entry.selectedMask {
                            Image(nsImage: mask)
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .frame(width: 24, height: 24)
                                .clipShape(RoundedRectangle(cornerRadius: 4))
                                .transition(.scale.combined(with: .opacity))
                        }
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: AppDesign.FontSize.caption))
                            .foregroundStyle(segmentationColor)
                            .transition(.scale.combined(with: .opacity))
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            // Remove button (only if more than one segmentation) - separate so it doesn't trigger expand
            if viewModel.segmentations.count > 1 {
                Button {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
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

    /// Whether this entry is currently being analyzed by VLM
    private var isAnalyzing: Bool {
        viewModel.isAutoDetecting && isActive
    }

    @ViewBuilder
    private var entryContent: some View {
        VStack(alignment: .leading, spacing: AppDesign.Spacing.p8) {
            // Text-guided detection section
            VStack(alignment: .leading, spacing: AppDesign.Spacing.p6) {
                HStack(spacing: AppDesign.Spacing.p8) {
                    ZStack(alignment: .leading) {
                        // Show "Analyzing..." when VLM is running
                        if isAnalyzing {
                            HStack(spacing: AppDesign.Spacing.p6) {
                                ProgressView()
                                    .controlSize(.small)
                                    .scaleEffect(0.6)
                                Text("Analyzing...")
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.horizontal, 6)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .frame(height: 22)
                            .background(Color.primary.opacity(0.05))
                            .clipShape(RoundedRectangle(cornerRadius: 5))
                            .overlay(
                                RoundedRectangle(cornerRadius: 5)
                                    .strokeBorder(Color.primary.opacity(0.1), lineWidth: 1)
                            )
                        } else {
                            TextField("what to detect? e.g. alpaca", text: textPromptBinding)
                                .textFieldStyle(.roundedBorder)
                                .focused($isTextFieldFocused)
                                .onSubmit {
                                    viewModel.runTextPrediction()
                                }
                        }
                    }

                    Button {
                        viewModel.runTextPrediction()
                    } label: {
                        HStack(spacing: 4) {
                            if entry.isProcessing {
                                ProgressView()
                                    .controlSize(.small)
                                    .scaleEffect(0.7)
                            } else {
                                Image(systemName: "sparkle.magnifyingglass")
                            }
                            Text("Detect")
                        }
                        .font(.system(size: AppDesign.FontSize.caption, weight: .medium))
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(entry.textPrompt.isEmpty || entry.isProcessing || isAnalyzing)
                }

                AppDesign.HintText("AI will find and segment the object you describe")
            }

            Divider().padding(.vertical, 2)

            // Alternative: bounding box selection
            VStack(alignment: .leading, spacing: AppDesign.Spacing.p4) {
                Text("Or draw a box around the object")
                    .font(.system(size: AppDesign.FontSize.caption))
                    .foregroundStyle(.secondary)
                AppDesign.HintText("Drag to draw a bounding box")
            }
            .onAppear {
                // Auto-focus when this entry appears expanded and active
                if isActive && entry.isExpanded {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        isTextFieldFocused = true
                    }
                }
            }

            // Warning if no results
            if entry.isSearchPerformed && entry.allMasks.isEmpty && !entry.isProcessing {
                AppDesign.WarningMessage(text: "No '\(entry.textPrompt)' found")
            }

            // Region selection (if multiple masks)
            if entry.allMasks.count > 1 {
                regionSelectionSection
            }

            // Bounding box indicator
            if entry.boundingBox != nil {
                HStack(spacing: AppDesign.Spacing.p4) {
                    Image(systemName: "rectangle.dashed")
                        .font(.system(size: AppDesign.FontSize.caption))
                        .foregroundStyle(.secondary)
                    Text("Bounding box set")
                        .font(.system(size: AppDesign.FontSize.caption))
                        .foregroundStyle(.secondary)
                }
            }

            // Clear button
            if entry.hasValidMask || entry.boundingBox != nil {
                HStack {
                    Button(action: viewModel.clearActiveSegmentation) {
                        HStack(spacing: AppDesign.Spacing.p6) {
                            Image(systemName: "trash")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(.secondary)
                            Text("Clear")
                                .font(.system(size: AppDesign.FontSize.caption))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
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
            HStack(alignment: .top, spacing: AppDesign.Spacing.p10) {
                // Mask preview thumbnail - acts as vertical indicator
                Image(nsImage: maskImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 32, height: 32)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .strokeBorder(isSelected ? color : Color.primary.opacity(0.2), lineWidth: isSelected ? 2 : 1)
                    )

                // Region info - wraps to multiple lines
                VStack(alignment: .leading, spacing: 2) {
                    // Header: region name + checkmark
                    HStack(spacing: AppDesign.Spacing.p6) {
                        Text("Region \(maskIndex + 1)")
                            .font(.system(size: AppDesign.FontSize.caption, weight: isSelected ? .semibold : .regular))
                            .foregroundStyle(isSelected ? color : .primary)

                        Spacer(minLength: 0)

                        // Checkmark if selected
                        if isSelected {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: AppDesign.FontSize.body))
                                .foregroundStyle(color)
                        }
                    }

                    // Confidence percentage
                    Text(String(format: "%.0f%% confidence", score * 100))
                        .font(.system(size: AppDesign.FontSize.xs, design: .monospaced))
                        .foregroundStyle(isSelected ? color : .secondary)
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
