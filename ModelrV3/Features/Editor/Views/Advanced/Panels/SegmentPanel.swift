import SwiftUI

struct SegmentPanel: View {
    @ObservedObject var viewModel: EditorViewModel
    
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            // Header with skip toggle
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Segmentation")
                        .font(.title3.bold())
                    Text("Select the object to extract")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                
                Spacer()
                
                Toggle("", isOn: $viewModel.skipSegmentation)
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .help("Skip segmentation if image is already cut out")
                    .onChange(of: viewModel.skipSegmentation) { _, newValue in
                        if newValue {
                            viewModel.createFullImageMask()
                        } else {
                            viewModel.maskImage = nil
                        }
                    }
            }
            .padding()
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(.ultraThinMaterial)
            )
            
            if !viewModel.skipSegmentation {
                // Tool Grid
                VStack(alignment: .leading, spacing: 10) {
                    Text("Tools")
                        .font(.headline)
                        .foregroundColor(.secondary)
                    
                    LazyVGrid(columns: [
                        GridItem(.flexible()),
                        GridItem(.flexible()),
                        GridItem(.flexible())
                    ], spacing: 8) {
                        ForEach(SAMTool.allCases) { tool in
                            ToolButton(
                                tool: tool,
                                isSelected: viewModel.selectedTool == tool,
                                action: { viewModel.selectedTool = tool }
                            )
                        }
                    }
                    
                    Text(viewModel.toolDescription)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 4)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                
                // Paint Tool Options
                if viewModel.selectedTool == .paint {
                    paintToolOptions
                }
                
                // Mask Visibility
                VStack(alignment: .leading, spacing: 8) {
                    Text("Mask")
                        .font(.headline)
                        .foregroundColor(.secondary)
                    
                    HStack(spacing: 12) {
                        Image(systemName: "eye.slash")
                            .font(.caption)
                        Slider(value: $viewModel.maskOpacity, in: 0...1)
                        Image(systemName: "eye")
                            .font(.caption)
                    }
                    .foregroundColor(.secondary)
                    
                    if !viewModel.maskScores.isEmpty {
                        Toggle(isOn: $viewModel.showConfidenceOverlay) {
                            Label("Confidence Overlay", systemImage: "chart.bar.fill")
                                .font(.subheadline)
                        }
                        .toggleStyle(.switch)
                        .tint(.orange)
                    }
                }
                
                // Annotations Summary
                annotationsSummary
                
            } else {
                // Skip mode indicator
                VStack(spacing: 16) {
                    ZStack {
                        Circle()
                            .fill(Color.green.opacity(0.15))
                            .frame(width: 80, height: 80)
                        
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 40))
                            .foregroundColor(.green)
                    }
                    
                    Text("Ready for Generation")
                        .font(.headline)
                    
                    Text("Using pre-cutout image directly")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 32)
            }
            
            Spacer()
            
            // Action buttons
            VStack(spacing: 12) {
                Button(action: { viewModel.moveToNextStep() }) {
                    HStack {
                        Text("Continue to Generate")
                        Image(systemName: "arrow.right")
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(!viewModel.canMoveToNextStep)
                
                Button(action: { viewModel.clearAll() }) {
                    Label("Start Over", systemImage: "arrow.counterclockwise")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .foregroundColor(.red)
            }
        }
        .padding()
    }
    
    private var paintToolOptions: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Brush")
                .font(.headline)
                .foregroundColor(.secondary)
            
            HStack {
                Image(systemName: "circle")
                    .font(.system(size: 8))
                Slider(value: $viewModel.brushSize, in: 0.01...0.15, step: 0.005)
                Image(systemName: "circle.fill")
                    .font(.system(size: 16))
            }
            .foregroundColor(.secondary)
            
            HStack {
                Button(action: { viewModel.isErasing = false }) {
                    Label("Add", systemImage: "plus.circle.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .tint(viewModel.isErasing ? .secondary : .blue)
                .opacity(viewModel.isErasing ? 0.6 : 1.0)
                
                Button(action: { viewModel.isErasing = true }) {
                    Label("Erase", systemImage: "minus.circle.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .tint(viewModel.isErasing ? .red : .secondary)
                .opacity(viewModel.isErasing ? 1.0 : 0.6)
            }
            .controlSize(.small)
            
            if !viewModel.paintStrokes.isEmpty {
                Button(action: { viewModel.clearPaintStrokes() }) {
                    Label("Clear Strokes", systemImage: "xmark.circle")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.secondary.opacity(0.1))
        )
    }
    
    private var annotationsSummary: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Annotations")
                    .font(.headline)
                    .foregroundColor(.secondary)
                
                Spacer()
                
                if viewModel.hasSelection {
                    Button(action: { viewModel.deleteSelectedAnnotation() }) {
                        Image(systemName: "trash")
                            .font(.caption)
                    }
                    .buttonStyle(.borderless)
                    .foregroundColor(.red)
                }
            }
            
            HStack(spacing: 16) {
                annotationBadge(
                    count: viewModel.selectedPoints.filter { $0.isPositive }.count,
                    icon: "plus.circle.fill",
                    color: .green
                )
                annotationBadge(
                    count: viewModel.selectedPoints.filter { $0.isNegative }.count,
                    icon: "minus.circle.fill",
                    color: .red
                )
                annotationBadge(
                    count: viewModel.boundingBoxes.count,
                    icon: "rectangle.dashed",
                    color: .blue
                )
                annotationBadge(
                    count: viewModel.lassoSelections.count + viewModel.paintStrokes.count,
                    icon: "scribble",
                    color: .purple
                )
            }
            
            if !viewModel.selectedPoints.isEmpty || !viewModel.boundingBoxes.isEmpty || !viewModel.lassoSelections.isEmpty || !viewModel.paintStrokes.isEmpty {
                Button(action: { viewModel.clearAnnotations() }) {
                    Label("Clear All", systemImage: "trash")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
    }
    
    private func annotationBadge(count: Int, icon: String, color: Color) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .foregroundColor(color)
            Text("\(count)")
                .font(.caption.bold())
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(color.opacity(0.1))
        .cornerRadius(6)
    }
}

// MARK: - ToolButton Component

struct ToolButton: View {
    let tool: SAMTool
    let isSelected: Bool
    let action: () -> Void
    
    @State private var isHovered = false
    
    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: tool.iconName)
                    .font(.system(size: 16, weight: isSelected ? .semibold : .regular))
                    .symbolRenderingMode(.hierarchical)
                
                Text(tool.rawValue)
                    .font(.caption2)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 50)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isSelected ? Color.accentColor.opacity(0.2) : (isHovered ? Color.secondary.opacity(0.1) : Color.clear))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(isSelected ? Color.accentColor : Color.clear, lineWidth: 1.5)
            )
        }
        .buttonStyle(.plain)
        .foregroundColor(isSelected ? .accentColor : .primary)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovered = hovering
            }
        }
    }
}
