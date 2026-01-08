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
            // Display mode toolbar - only in post-process step
            if viewModel.currentStep == .postProcess && !viewModel.meshComponents.isEmpty {
                ToolbarItemGroup(placement: .principal) {
                    displayModeToolbar
                }
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

    @ViewBuilder
    private var displayModeToolbar: some View {
        HStack(spacing: 2) {
            ForEach(SimpleEditorViewModel.MeshDisplayMode.allCases, id: \.self) { mode in
                Button {
                    withAnimation(.easeOut(duration: 0.15)) {
                        viewModel.meshDisplayMode = mode
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: iconForDisplayMode(mode))
                            .font(.system(size: 11))
                        Text(mode.rawValue)
                            .font(.system(size: 12, weight: viewModel.meshDisplayMode == mode ? .semibold : .regular))
                    }
                    .foregroundStyle(viewModel.meshDisplayMode == mode ? .primary : .secondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(
                        viewModel.meshDisplayMode == mode ? Color.primary.opacity(0.1) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 5)
                    )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 7))
    }

    private func iconForDisplayMode(_ mode: SimpleEditorViewModel.MeshDisplayMode) -> String {
        switch mode {
        case .solid: return "cube.fill"
        case .wireframe: return "cube"
        case .transparent: return "cube.transparent"
        }
    }
}

#Preview {
    SimpleEditorView()
}
