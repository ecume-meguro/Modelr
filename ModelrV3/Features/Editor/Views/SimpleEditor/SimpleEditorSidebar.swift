import SwiftUI

/// Sidebar for ContentViewSimple
struct SimpleEditorSidebar: View {
    @ObservedObject var viewModel: SimpleEditorViewModel
    
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            titleArea
            
            Divider()
                .padding(.horizontal, AppDesign.Spacing.p16)
            
            ScrollView {
                VStack(alignment: .leading, spacing: AppDesign.Spacing.p16) {
                    inputStep
                    segmentStep
                    touchupStep
                    generateStep
                    postProcessStep

                    if viewModel.inputImage != nil {
                        startOverButton
                    }
                }
                .padding(AppDesign.Spacing.p16)
            }
            
            if viewModel.env.isProcessing {
                statusFooter
            }
        }
        .background(.ultraThinMaterial)
    }
    
    @ViewBuilder
    private var titleArea: some View {
        VStack(alignment: .leading, spacing: AppDesign.Spacing.p4) {
            AppDesign.HeaderText(text: "Modelr", size: AppDesign.FontSize.title2)
            AppDesign.SubheaderText(text: "V3 Professional")
        }
        .padding(.horizontal, AppDesign.Spacing.p16)
        .padding(.top, AppDesign.Spacing.p24)
        .padding(.bottom, AppDesign.Spacing.p16)
    }
    
    @ViewBuilder
    private var inputStep: some View {
        stepSection(
            number: 1,
            title: "Input",
            isActive: viewModel.currentStep == .input,
            isDone: viewModel.inputImage != nil
        ) {
            VStack(alignment: .leading, spacing: AppDesign.Spacing.p12) {
                if viewModel.inputImage != nil {
                    AppDesign.CompletedRow("Image loaded")
                } else {
                    AppDesign.HintText("Drop an image or click 'Select Image' in the center area to begin.")
                }
            }
        }
    }
    
    @ViewBuilder
    private var segmentStep: some View {
        stepSection(
            number: 2,
            title: "Segment",
            isActive: viewModel.currentStep == .segment,
            isDone: viewModel.currentStep == .touchup || viewModel.currentStep == .generate
        ) {
            VStack(alignment: .leading, spacing: AppDesign.Spacing.p12) {
                if viewModel.currentStep == .segment {
                    SegmentationPanel(viewModel: viewModel)
                    
                    sectionFooter {
                        AppDesign.GlassButton("Next: Touchup", icon: "wand.and.stars", disabled: viewModel.totalValidMasks == 0) {
                            viewModel.startTouchup()
                        }

                        AppDesign.InlineButton("Back to Input", icon: "arrow.left") {
                            viewModel.handleBackAction()
                        }
                    }
                } else {
                    AppDesign.CompletedRow("\(viewModel.totalValidMasks) \(viewModel.totalValidMasks == 1 ? "object" : "objects") selected")
                }
            }
        }
        .alert("Discard Image?", isPresented: $viewModel.showDiscardImageWarning) {
            Button("Cancel", role: .cancel) { }
            Button("Discard", role: .destructive) { viewModel.goBack() }
        } message: {
            Text("This will return to the input screen and you'll need to reload the image.")
        }
    }
    
    @ViewBuilder
    private var touchupStep: some View {
        stepSection(
            number: 3,
            title: "Touchup",
            isActive: viewModel.currentStep == .touchup,
            isDone: viewModel.currentStep == .generate
        ) {
            VStack(alignment: .leading, spacing: AppDesign.Spacing.p12) {
                if viewModel.currentStep == .touchup {
                    TouchupPanel(viewModel: viewModel)
                    
                    sectionFooter {
                        AppDesign.GlassButton("Next: Generate 3D", icon: "cube.fill") {
                            viewModel.transitionToGenerate()
                        }
                        
                        AppDesign.InlineButton("Back to Segment", icon: "arrow.left") {
                            viewModel.handleBackAction()
                        }
                    }
                } else {
                    AppDesign.CompletedRow("Mask refined")
                }
            }
        }
        .alert("Lose Touchup Changes?", isPresented: $viewModel.showBackWarning) {
            Button("Cancel", role: .cancel) { }
            Button("Go Back", role: .destructive) { viewModel.goBack() }
        } message: {
            Text("You'll return to segmentation and can select a different region or add more points.")
        }
    }
    
    @ViewBuilder
    private var generateStep: some View {
        stepSection(
            number: 4,
            title: "Generate 3D",
            isActive: viewModel.currentStep == .generate,
            isDone: viewModel.currentStep == .postProcess || viewModel.generated3DModelURL != nil
        ) {
            VStack(alignment: .leading, spacing: AppDesign.Spacing.p12) {
                if viewModel.currentStep == .generate {
                    GenerationPanel(viewModel: viewModel)

                    if !viewModel.isGenerating && viewModel.generated3DModelURL == nil {
                        sectionFooter {
                            AppDesign.GlassButton("Generate Model", icon: "sparkles") {
                                viewModel.generate3D()
                            }
                            AppDesign.InlineButton("Back to Touchup", icon: "arrow.left") {
                                viewModel.handleBackAction()
                            }
                        }
                    } else if viewModel.isGenerating {
                        sectionFooter {
                            AppDesign.GlassButtonSecondary("Stop Generation", icon: "stop.fill", destructive: true) {
                                viewModel.stopGeneration()
                            }
                        }
                    } else if viewModel.generated3DModelURL != nil {
                        sectionFooter {
                            AppDesign.GlassButton("Next: Post-Process", icon: "slider.horizontal.3") {
                                viewModel.transitionToPostProcess()
                            }
                            AppDesign.InlineButton("Back to Touchup", icon: "arrow.left") {
                                viewModel.handleBackAction()
                            }
                        }
                    }
                } else if viewModel.currentStep == .postProcess {
                    AppDesign.CompletedRow("Model generated")
                }
            }
        }
        .alert("Discard 3D Model?", isPresented: $viewModel.showDiscardModelWarning) {
            Button("Cancel", role: .cancel) { }
            Button("Discard", role: .destructive) { viewModel.goBack() }
        } message: {
            Text("The generated 3D model will be kept on disk, but you'll return to touchup mode.")
        }
    }

    @ViewBuilder
    private var postProcessStep: some View {
        stepSection(
            number: 5,
            title: "Post-Process",
            isActive: viewModel.currentStep == .postProcess,
            isDone: false
        ) {
            VStack(alignment: .leading, spacing: AppDesign.Spacing.p12) {
                if viewModel.currentStep == .postProcess {
                    PostProcessPanel(viewModel: viewModel)

                    sectionFooter {
                        AppDesign.InlineButton("Back to Generate", icon: "arrow.left") {
                            viewModel.handleBackAction()
                        }
                    }
                }
            }
        }
    }
    
    @ViewBuilder
    private var startOverButton: some View {
        Divider().padding(.vertical, AppDesign.Spacing.p4)

        HStack {
            Spacer()
            AppDesign.InlineButton("Start Over", icon: "arrow.counterclockwise") {
                viewModel.showStartOverWarning = true
            }
        }
        .alert("Start Over?", isPresented: $viewModel.showStartOverWarning) {
            Button("Cancel", role: .cancel) { }
            Button("Start Over", role: .destructive) { viewModel.clearAll() }
        } message: {
            Text("This will discard all progress and return to the home screen.")
        }
    }
    
    @ViewBuilder
    private var statusFooter: some View {
        VStack(spacing: 0) {
            Divider()
            AppDesign.LoadingIndicator(text: viewModel.env.status)
                .padding(AppDesign.Spacing.p16)
        }
        .background(.ultraThinMaterial)
    }
    
    @ViewBuilder
    private func stepSection(
        number: Int,
        title: String,
        isActive: Bool,
        isDone: Bool,
        @ViewBuilder content: () -> some View
    ) -> some View {
        VStack(alignment: .leading, spacing: AppDesign.Spacing.p8) {
            AppDesign.StepIndicator(number: number, title: title, isActive: isActive, isDone: isDone)
                .animation(.easeInOut(duration: 0.25), value: isActive)
                .animation(.easeInOut(duration: 0.25), value: isDone)

            if isActive || isDone {
                content()
                    .padding(.leading, 36)
            }
        }
        .padding(.vertical, isActive ? AppDesign.Spacing.p4 : 0)
        .animation(.easeInOut(duration: 0.25), value: isActive)
    }
    
    @ViewBuilder
    private func sectionFooter(@ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: AppDesign.Spacing.p8) {
            content()
        }
        .padding(.top, AppDesign.Spacing.p12)
    }
}
