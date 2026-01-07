import SwiftUI

/// Main container for the refactored ContentViewSimple
struct SimpleEditorView: View {
    @StateObject private var viewModel: SimpleEditorViewModel
    
    init() {
        let env = ServiceContainer.shared.pythonEnvironment
        _viewModel = StateObject(wrappedValue: SimpleEditorViewModel(env: env))
    }
    
    var body: some View {
        NavigationSplitView {
            SimpleEditorSidebar(viewModel: viewModel)
                .navigationSplitViewColumnWidth(min: 280, ideal: 360, max: 420)
        } detail: {
            ImageCanvas(viewModel: viewModel)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(NSColor.windowBackgroundColor))
        }
        .navigationSplitViewStyle(.balanced)
        .navigationTitle("")
        .toolbar {
            ToolbarItem(placement: .navigation) {
                EditorToolbarContent(viewModel: viewModel)
                    .frame(minWidth: 200)
            }
        }
        .frame(minWidth: 700, minHeight: 500)
        .background(
            Button("") {
                if viewModel.currentStep == .touchup {
                    viewModel.undo()
                }
            }
            .keyboardShortcut("z", modifiers: .command)
            .hidden()
        )
        .task {
            await viewModel.env.preloadSAMModel()
        }
    }
}

#Preview {
    SimpleEditorView()
}
