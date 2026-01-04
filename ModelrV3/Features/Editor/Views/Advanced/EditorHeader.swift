import SwiftUI

struct EditorHeader: View {
    @ObservedObject var viewModel: EditorViewModel
    
    var body: some View {
        ZStack {
            Color(NSColor.windowBackgroundColor)
            
            WorkflowProgressBar(
                currentStep: $viewModel.currentStep,
                canMoveToNext: viewModel.canMoveToNextStep
            )
            .padding(.vertical, 12)
        }
        .frame(height: 100)
        .zIndex(1)
    }
}
