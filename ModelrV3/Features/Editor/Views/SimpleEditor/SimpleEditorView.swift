import SwiftUI

/// Main container for the refactored ContentViewSimple
struct SimpleEditorView: View {
    @StateObject private var viewModel: SimpleEditorViewModel
    
    init() {
        let env = PythonEnvironment()
        _viewModel = StateObject(wrappedValue: SimpleEditorViewModel(env: env))
    }
    
    var body: some View {
        NavigationSplitView {
            SimpleEditorSidebar(viewModel: viewModel)
                .navigationSplitViewColumnWidth(min: 280, ideal: 300, max: 350)
        } detail: {
            ImageCanvas(viewModel: viewModel)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(NSColor.windowBackgroundColor))
        }
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 1000, minHeight: 700)
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
