import SwiftUI

struct EditorSidebar: View {
    @ObservedObject var viewModel: EditorViewModel
    
    var body: some View {
        VStack(spacing: 0) {
            // Tab content
            ScrollView {
                switch viewModel.currentStep {
                case .input:
                    EmptyView()
                case .refine:
                    PreprocessPanel(viewModel: viewModel)
                case .segment:
                    SegmentPanel(viewModel: viewModel)
                case .generate:
                    GeneratePanel(viewModel: viewModel)
                }
            }
            .disabled(viewModel.inputImage == nil && viewModel.currentStep != .input)
            .opacity(viewModel.inputImage == nil && viewModel.currentStep != .input ? 0.6 : 1.0)
            
            Divider()
            
            // Status footer
            StatusFooter(viewModel: viewModel)
        }
    }
}

// MARK: - Status Footer

struct StatusFooter: View {
    @ObservedObject var viewModel: EditorViewModel
    
    var body: some View {
        HStack(spacing: 12) {
            // Undo button
            Button(action: { viewModel.performUndo() }) {
                Image(systemName: "arrow.uturn.backward")
                    .font(.system(size: 14))
            }
            .buttonStyle(.borderless)
            .help("Undo (⌘Z)")
            .disabled(viewModel.undoStack.isEmpty)
            .opacity(viewModel.undoStack.isEmpty ? 0.3 : 1.0)
            
            // Redo button
            Button(action: { viewModel.performRedo() }) {
                Image(systemName: "arrow.uturn.forward")
                    .font(.system(size: 14))
            }
            .buttonStyle(.borderless)
            .help("Redo (⌘⇧Z)")
            .disabled(viewModel.redoStack.isEmpty)
            .opacity(viewModel.redoStack.isEmpty ? 0.3 : 1.0)
            
            Divider()
                .frame(height: 16)
            
            // Status text
            HStack(spacing: 4) {
                if viewModel.env.isProcessing {
                    ProgressView()
                        .scaleEffect(0.7)
                        .frame(width: 16, height: 16)
                }
                
                Text(viewModel.env.status)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            
            // Next step button
            if viewModel.canMoveToNextStep {
                Button(action: { viewModel.moveToNextStep() }) {
                    HStack {
                        Text(viewModel.nextStepButtonTitle)
                        Image(systemName: "chevron.right")
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 4)
                }
                .buttonStyle(.borderedProminent)
                .tint(.blue)
                .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}
