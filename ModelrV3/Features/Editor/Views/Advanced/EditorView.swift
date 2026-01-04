import SwiftUI

struct EditorView: View {
    @StateObject private var viewModel: EditorViewModel
    
    init(autoLoadLatest3DModel: Bool = false) {
        _viewModel = StateObject(wrappedValue: EditorViewModel(autoLoadLatest3DModel: autoLoadLatest3DModel))
    }
    
    var body: some View {
        VStack(spacing: 0) {
            // Workflow Progress Bar (Header)
            EditorHeader(viewModel: viewModel)
            
            Divider()
            
            // Main content
            HSplitView {
                // Left: Image area
                EditorCanvas(viewModel: viewModel)
                    .frame(minWidth: 500)
                
                // Right: Sidebar
                EditorSidebar(viewModel: viewModel)
                    .frame(minWidth: 280, maxWidth: 350)
            }
        }
        .frame(minWidth: 1000, minHeight: 700)
        .toolbar {
            editorToolbar
        }
        .onChange(of: viewModel.selectedPoints.count) { _, _ in
            viewModel.triggerReInference()
        }
        .onChange(of: viewModel.boundingBoxes.count) { _, _ in
            viewModel.triggerReInference()
        }
        .onChange(of: viewModel.lassoSelections.count) { _, _ in
            viewModel.triggerReInference()
        }
        .onChange(of: viewModel.currentStep) { oldStep, newStep in
            if oldStep == .segment && newStep != .segment {
                viewModel.saveSegmentationState()
            }
            if newStep == .segment && oldStep != .segment {
                viewModel.restoreSegmentationState()
            }
        }
        .background(keyboardShortcuts)
    }
    
    @ToolbarContentBuilder
    private var editorToolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            if viewModel.inputImage != nil {
                Button(action: { viewModel.clearAll() }) {
                    Label("New", systemImage: "plus")
                }
                .help("Clear current image")
            }
        }
        
        ToolbarItem(placement: .principal) {
            Text("Modelr")
                .font(.headline)
                .foregroundColor(.secondary)
        }
    }
    
    private var keyboardShortcuts: some View {
        Group {
            // Undo: Cmd+Z
            Button("") { viewModel.performUndo() }
                .keyboardShortcut("z", modifiers: .command)
                .opacity(0)
            
            // Redo: Cmd+Shift+Z
            Button("") { viewModel.performRedo() }
                .keyboardShortcut("z", modifiers: [.command, .shift])
                .opacity(0)
            
            // Tool shortcuts (1-5)
            Button("") { if viewModel.currentStep == .segment { viewModel.selectedTool = .point } }
                .keyboardShortcut("1", modifiers: [])
                .opacity(0)
            
            Button("") { if viewModel.currentStep == .segment { viewModel.selectedTool = .boundingBox } }
                .keyboardShortcut("2", modifiers: [])
                .opacity(0)
            
            Button("") { if viewModel.currentStep == .segment { viewModel.selectedTool = .lasso } }
                .keyboardShortcut("3", modifiers: [])
                .opacity(0)
            
            Button("") { if viewModel.currentStep == .segment { viewModel.selectedTool = .paint } }
                .keyboardShortcut("4", modifiers: [])
                .opacity(0)
            
            Button("") { if viewModel.currentStep == .segment { viewModel.selectedTool = .polygon } }
                .keyboardShortcut("5", modifiers: [])
                .opacity(0)
            
            // Delete selected annotation
            Button("") { viewModel.deleteSelectedAnnotation() }
                .keyboardShortcut(.delete, modifiers: [])
                .opacity(0)
            
            // Cancel polygon
            Button("") { viewModel.cancelPolygon() }
                .keyboardShortcut(.escape, modifiers: [])
                .opacity(0)
            
            // Toggle erase mode
            Button("") { if viewModel.selectedTool == .paint { viewModel.isErasing.toggle() } }
                .keyboardShortcut("e", modifiers: [])
                .opacity(0)
        }
    }
}

#Preview {
    EditorView()
}
