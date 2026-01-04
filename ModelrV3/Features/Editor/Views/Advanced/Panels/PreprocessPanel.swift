import SwiftUI

struct PreprocessPanel: View {
    @ObservedObject var viewModel: EditorViewModel
    
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            // Header
            VStack(alignment: .leading, spacing: 2) {
                Text("Refine Image")
                    .font(.title3.bold())
                Text("Optional: Crop or adjust before segmentation")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding()
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(.ultraThinMaterial)
            )
            
            // Tool Selection
            VStack(alignment: .leading, spacing: 10) {
                Text("Tool")
                    .font(.headline)
                    .foregroundColor(.secondary)
                
                Picker("Preprocess Tool", selection: $viewModel.selectedPreprocessTool) {
                    ForEach(PreprocessTool.allCases, id: \.self) { tool in
                        Label(tool.rawValue, systemImage: tool.iconName)
                            .tag(tool)
                    }
                }
                .pickerStyle(.segmented)
            }
            
            Divider()
            
            // Tool-specific actions
            if viewModel.selectedPreprocessTool == .crop {
                cropActions
            } else if viewModel.selectedPreprocessTool == .polygonCrop {
                polygonCropActions
            }
            
            Divider()
            
            // Instructions
            VStack(alignment: .leading, spacing: 8) {
                Text("Instructions")
                    .font(.headline)
                    .foregroundColor(.secondary)
                
                Group {
                    switch viewModel.selectedPreprocessTool {
                    case .crop:
                        Text("• Drag to draw a crop rectangle")
                        Text("• Click Apply to crop the image")
                        Text("• Use Cmd+Z to undo")
                    case .polygonCrop:
                        Text("• Drag to draw a selection")
                        Text("• Click Crop to keep only the selected area")
                        Text("• Use Cmd+Z to undo")
                    }
                }
                .font(.caption)
                .foregroundColor(.secondary)
            }
            
            Spacer()
            
            // Next step hint
            VStack(spacing: 8) {
                Text("When done refining, proceed to segmentation.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                
                Button(action: { viewModel.moveToNextStep() }) {
                    Label("Proceed to Segment", systemImage: "arrow.right")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(!viewModel.canMoveToNextStep)
            }
        }
        .padding()
    }
    
    private var cropActions: some View {
        VStack(spacing: 8) {
            if viewModel.cropRect != nil {
                Button(action: { viewModel.applyCrop() }) {
                    Label("Apply Crop", systemImage: "crop")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                
                Button(action: { viewModel.clearCrop() }) {
                    Label("Clear", systemImage: "xmark")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            } else {
                Text("Drag on the image to create a crop region")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .italic()
            }
        }
    }
    
    private var polygonCropActions: some View {
        VStack(spacing: 8) {
            if viewModel.preprocessLasso != nil {
                Button(action: { viewModel.applyPolygonCrop() }) {
                    Label("Apply Crop", systemImage: "crop")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                
                Button(action: { viewModel.clearPolygonCrop() }) {
                    Label("Clear", systemImage: "xmark")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            } else {
                Text("Drag on the image to draw a selection")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .italic()
            }
        }
    }
}
