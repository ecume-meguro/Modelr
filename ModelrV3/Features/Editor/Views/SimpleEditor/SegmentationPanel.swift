import SwiftUI

/// Segmentation panel for ContentViewSimple
struct SegmentationPanel: View {
    @ObservedObject var viewModel: SimpleEditorViewModel
    
    var body: some View {
        VStack(alignment: .leading, spacing: AppDesign.Spacing.p12) {
            if viewModel.imageHasAlpha {
                alphaToggleSection
                Divider().padding(.vertical, AppDesign.Spacing.p4)
            }
            
            if !viewModel.useExistingAlpha {
                textPromptSection

                if viewModel.textSearchPerformed && viewModel.allMasks.isEmpty && !viewModel.isSegmenting {
                    AppDesign.WarningMessage(text: "No '\(viewModel.textPrompt)' found in image")
                }

                if viewModel.allMasks.count > 1 {
                    maskSelectionSection
                }

                // Show clear button right after region selectors
                if !viewModel.selectedPoints.isEmpty || !viewModel.allMasks.isEmpty {
                    clearSelectionButton
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
                    viewModel.allMasks.removeAll()
                    viewModel.selectedMaskIndex = 0
                }
            }
            
            if viewModel.useExistingAlpha {
                AppDesign.CompletedRow("Using existing transparency")
            }
        }
    }
    
    @ViewBuilder
    private var textPromptSection: some View {
        VStack(alignment: .leading, spacing: AppDesign.Spacing.p8) {
            AppDesign.SectionLabel("Text Prompt")
            
            HStack(spacing: AppDesign.Spacing.p8) {
                AppDesign.StyledTextField(placeholder: "e.g. dog, tree, person", text: $viewModel.textPrompt) {
                    viewModel.runTextPrediction()
                }
                
                Button(action: viewModel.runTextPrediction) {
                    Image(systemName: "magnifyingglass")
                }
                .buttonStyle(.bordered)
                .disabled(viewModel.textPrompt.isEmpty || viewModel.env.isProcessing)
            }
            
            AppDesign.HintText("Or right-click on the object in view")
        }
    }
    
    @ViewBuilder
    private var maskSelectionSection: some View {
        VStack(alignment: .leading, spacing: AppDesign.Spacing.p8) {
            AppDesign.SectionLabel("Select Region")
            
            ForEach(Array(viewModel.allMasks.enumerated()), id: \.offset) { index, maskData in
                maskRow(index: index, score: maskData.score)
            }
        }
    }
    
    @ViewBuilder
    private func maskRow(index: Int, score: Double) -> some View {
        let isSelected = index == viewModel.selectedMaskIndex
        let color = viewModel.colorForMask(index)
        
        Button(action: { viewModel.selectedMaskIndex = index }) {
            HStack(spacing: AppDesign.Spacing.p8) {
                Circle()
                    .fill(color)
                    .frame(width: 10, height: 10)
                    .shadow(color: color.opacity(0.6), radius: isSelected ? 4 : 0)
                
                Text("Region \(index + 1)")
                    .font(.system(size: AppDesign.FontSize.subheadline, weight: isSelected ? .semibold : .regular))
                
                Spacer()
                
                Text(String(format: "%.0f%%", score * 100))
                    .font(.system(size: AppDesign.FontSize.caption, design: .monospaced))
                    .foregroundColor(isSelected ? color : .secondary)
                
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: AppDesign.FontSize.caption))
                        .foregroundColor(color)
                }
            }
            .padding(.vertical, AppDesign.Spacing.p6)
            .padding(.horizontal, AppDesign.Spacing.p8)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isSelected ? color.opacity(0.12) : Color.primary.opacity(0.03))
            )
            .overlay {
                if isSelected {
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(color.opacity(0.3), lineWidth: 1)
                }
            }
        }
        .buttonStyle(.plain)
    }
    
    @ViewBuilder
    private var clearSelectionButton: some View {
        HStack(spacing: AppDesign.Spacing.p8) {
            AppDesign.InlineButton("Clear Selection", icon: "trash") {
                viewModel.clearSegmentation()
                viewModel.useExistingAlpha = false
            }
            if !viewModel.selectedPoints.isEmpty {
                Text("•")
                    .font(.system(size: AppDesign.FontSize.caption))
                    .foregroundStyle(.tertiary)
                AppDesign.HintText("\(viewModel.selectedPoints.count) point(s)")
            }
            Spacer()
        }
        .padding(.top, AppDesign.Spacing.p8)
    }
}
