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
        // Error alert for user feedback
        .alert("Error", isPresented: $viewModel.showErrorAlert) {
            Button("OK") {
                viewModel.lastError = nil
            }
            if viewModel.lastError?.isRecoverable == true {
                Button("Retry") {
                    // For now just dismiss - specific retry logic can be added per error type
                    viewModel.lastError = nil
                }
            }
        } message: {
            if let error = viewModel.lastError {
                VStack {
                    Text(error.localizedDescription)
                    if let suggestion = error.suggestedAction {
                        Text(suggestion)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

}

#Preview {
    SimpleEditorView()
}
